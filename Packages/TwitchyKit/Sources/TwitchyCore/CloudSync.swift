import Foundation
import CloudKit
import CryptoKit
import Observation
import Security

/// A record per independently editable value. Nil payloads are durable deletion tombstones.
public struct SyncValue: Codable, Sendable, Equatable {
    public var key: String
    public var payload: Data?
    public var modifiedAt: Date
    public var revision: String
    public init(key: String, payload: Data?, modifiedAt: Date = .now, revision: String = UUID().uuidString) {
        self.key = key; self.payload = payload; self.modifiedAt = modifiedAt; self.revision = revision
    }
    public func supersedes(_ other: SyncValue) -> Bool {
        modifiedAt == other.modifiedAt ? revision > other.revision : modifiedAt > other.modifiedAt
    }
}
public protocol CloudSyncTransport: Sendable {
    func accountID() async throws -> String
    func fetch() async throws -> [SyncValue]
    /// Returns the accepted server version, including when a concurrent edit won.
    func save(_ value: SyncValue) async throws -> SyncValue
}

public actor PrivateCloudTransport: CloudSyncTransport {
    public static let containerID = "iCloud.ch.hivenet.twitchy"
    private let container: CKContainer
    private let database: CKDatabase
    private let zoneID = CKRecordZone.ID(zoneName: "TwitchyPersonal")
    private var ready = false
    private var changeToken: CKServerChangeToken?
    private var fetchedValues: [String: SyncValue] = [:]
    public init() {
        let container = CKContainer(identifier: Self.containerID)
        self.container = container; database = container.privateCloudDatabase
    }
    public func accountID() async throws -> String {
        guard try await container.accountStatus() == .available else { throw ClientError.message("Sign in to iCloud to sync Twitchy.") }
        return try await container.userRecordID().recordName
    }
    private func prepare() async throws {
        guard !ready else { return }
        _ = try await database.save(CKRecordZone(zoneID: zoneID)); ready = true
    }
    public func fetch() async throws -> [SyncValue] {
        try await prepare()
        var values = fetchedValues, token = changeToken
        repeat {
            let page = try await database.recordZoneChanges(inZoneWith: zoneID, since: token)
            for result in page.modificationResultsByID.values {
                let record = try result.get().record
                if let data = record.encryptedValues["value"] as? Data { let value = try JSONDecoder().decode(SyncValue.self, from: data); values[value.key] = value }
            }
            token = page.changeToken
            if !page.moreComing { fetchedValues = values; changeToken = token; return Array(values.values) }
        } while true
    }
    public func save(_ value: SyncValue) async throws -> SyncValue {
        try await prepare()
        let name = SHA256.hash(data: Data(value.key.utf8)).map { String(format: "%02x", $0) }.joined()
        let id = CKRecord.ID(recordName: name, zoneID: zoneID)
        for _ in 0..<3 {
            let record: CKRecord
            do { record = try await database.record(for: id) }
            catch let error as CKError where error.code == .unknownItem { record = CKRecord(recordType: "TwitchyValue", recordID: id) }
            if let data = record.encryptedValues["value"] as? Data {
                let remote = try JSONDecoder().decode(SyncValue.self, from: data)
                if !value.supersedes(remote) { return remote }
            }
            record.encryptedValues["value"] = try JSONEncoder().encode(value) as NSData
            do { _ = try await database.save(record); return value }
            catch let error as CKError where error.code == .serverRecordChanged { continue }
        }
        throw ClientError.message("An iCloud edit is still being updated. Twitchy will retry.")
    }
    /// CloudKit throws an Objective-C exception for an unsigned executable without its entitlement.
    public nonisolated static var isConfigured: Bool {
        #if targetEnvironment(simulator)
        return false
        #elseif os(macOS)
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return false }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return false }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dictionary = info as? [String: Any], let entitlements = dictionary[kSecCodeInfoEntitlementsDict as String] as? [String: Any],
              let containers = entitlements["com.apple.developer.icloud-container-identifiers"] as? [String] else { return false }
        return containers.contains(containerID)
        #else
        return Bundle.main.object(forInfoDictionaryKey: "TwitchyCloudEnabled") as? Bool == true
        #endif
    }
}

@MainActor @Observable public final class CloudSyncStore {
    public private(set) var status = "Waiting for iCloud"
    public private(set) var lastSyncedAt: Date?
    public private(set) var isSyncing = false
    public private(set) var values: [String: SyncValue] = [:]
    @ObservationIgnored public var onRemoteChange: (([SyncValue]) throws -> Void)?
    @ObservationIgnored private let transport: (any CloudSyncTransport)?
    @ObservationIgnored private let file: URL
    @ObservationIgnored private let secrets: any SecretStore
    @ObservationIgnored private var dirty: Set<String> = []
    @ObservationIgnored private var account: String?
    @ObservationIgnored private var cacheKey: SymmetricKey?
    @ObservationIgnored private var debounce: Task<Void, Never>?
    @ObservationIgnored private var storageFailed = false
    private struct Journal: Codable { var values: [String: SyncValue]; var dirty: Set<String>; var account: String? }
    public init(transport: (any CloudSyncTransport)?, file: URL = TwitchyStoragePaths.directory.appendingPathComponent("sync.sealed"), secrets: any SecretStore = KeychainStore(service: "com.rafaelreverberi.Twitchy.sync")) {
        self.transport = transport; self.file = file; self.secrets = secrets
        do {
            if let raw = try secrets.read("cacheKey") { cacheKey = SymmetricKey(data: raw) }
            if FileManager.default.fileExists(atPath: file.path) {
                guard let cacheKey else { throw ClientError.message("The local sync encryption key is unavailable.") }
                let data = try AES.GCM.open(AES.GCM.SealedBox(combined: Data(contentsOf: file)), using: cacheKey)
                let journal = try JSONDecoder().decode(Journal.self, from: data)
                values = journal.values; dirty = journal.dirty; account = journal.account
            }
        } catch { status = "Local sync data could not be read; the file has been preserved."; storageFailed = true }
        if transport == nil, !storageFailed { status = "iCloud requires an Apple-signed build with the Twitchy container." }
    }
    public func put(_ key: String, payload: Data?, seed: Bool = false, refresh: Bool = false) {
        guard !storageFailed else { return }
        if seed, values[key] != nil { return }
        if !refresh, let existing = values[key], existing.payload == payload { return }
        values[key] = SyncValue(key: key, payload: payload, modifiedAt: seed ? Date(timeIntervalSince1970: 0) : .now, revision: seed ? "" : UUID().uuidString)
        dirty.insert(key); persist()
        debounce?.cancel()
        debounce = Task { try? await Task.sleep(for: .seconds(8)); guard !Task.isCancelled else { return }; await sync() }
    }
    public func sync() async {
        guard !isSyncing, !storageFailed, let transport else { return }
        isSyncing = true; status = "Syncing…"; defer { isSyncing = false }
        do {
            let currentAccount = try await transport.accountID()
            guard account == nil || account == currentAccount else {
                status = "The iCloud account changed. Sync is paused to keep the previous account's data separate."; return
            }
            account = currentAccount; persist()
            for remote in try await transport.fetch() { try merge(remote) }
            // Snapshot keys; edits made during awaits remain queued by revision.
            for key in dirty.sorted() {
                guard let local = values[key] else { continue }
                let accepted = try await transport.save(local)
                try merge(accepted)
                if values[key]?.revision == accepted.revision { dirty.remove(key) }
                persist()
            }
            lastSyncedAt = .now; status = dirty.isEmpty ? "Up to date" : "Changes queued"
        } catch let error as CKError {
            switch error.code {
            case .notAuthenticated: status = "Sign in to iCloud to sync Twitchy."
            case .badContainer, .missingEntitlement, .permissionFailure: status = "iCloud is not configured for this build."
            case .quotaExceeded: status = "iCloud storage is full. Changes are saved on this device."
            default: status = "iCloud is unavailable. Changes are saved on this device and will retry."
            }
        } catch { status = "Sync is pending. \(error.localizedDescription)" }
    }
    private func merge(_ remote: SyncValue) throws {
        if let local = values[remote.key], local.revision != "", !remote.supersedes(local) { return }
        if values[remote.key] == remote { return }
        // Apply first; a failed Keychain write must remain retryable on the next fetch.
        try onRemoteChange?([remote])
        values[remote.key] = remote; dirty.remove(remote.key); persist()
    }
    public func reportLocalFailure(_ message: String) { status = message }
    public func applyCached() throws { try onRemoteChange?(Array(values.values)) }
    private func persist() {
        do {
            if cacheKey == nil {
                let key = SymmetricKey(size: .bits256)
                try secrets.write(key.withUnsafeBytes { Data($0) }, key: "cacheKey"); cacheKey = key
            }
            let encoded = try JSONEncoder().encode(Journal(values: values, dirty: dirty, account: account))
            let sealed = try AES.GCM.seal(encoded, using: cacheKey!).combined!
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try sealed.write(to: file, options: .atomic)
            var resourceURL = file, resources = URLResourceValues()
            resources.isExcludedFromBackup = true; try resourceURL.setResourceValues(resources)
        } catch { status = "Sync changes could not be saved locally." }
    }
}
