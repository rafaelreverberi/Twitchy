import Foundation
import Observation
import Security

public protocol SecretStore: Sendable {
    func read(_ key: String) throws -> Data?
    func write(_ data: Data, key: String) throws
    func delete(_ key: String) throws
}
public struct KeychainStore: SecretStore {
    private let service: String
    public init(service: String) { self.service = service }
    private func query(_ key: String) -> [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key] }
    public func read(_ key: String) throws -> Data? {
        var q = query(key); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?; let status = SecItemCopyMatching(q as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw ClientError.message("Keychain access failed (\(status)).") }
        return value as? Data
    }
    public func write(_ data: Data, key: String) throws {
        let q = query(key)
        let status = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = q; item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw ClientError.message("Could not save credentials in Keychain.") }
        } else if status != errSecSuccess { throw ClientError.message("Could not update credentials in Keychain.") }
    }
    public func delete(_ key: String) throws {
        let status = SecItemDelete(query(key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw ClientError.message("Could not remove Keychain credentials.") }
    }
}
public struct WatchEntry: Codable, Identifiable, Sendable, Equatable {
    public var id: String { login }
    public var login: String
    public var title: String
    public var watchedAt: Date
    public var contentType: String?
    public var contentID: String?
    public var position: Double
    public init(login: String, title: String, position: Double = 0, contentType: String? = nil, contentID: String? = nil) { self.login = login; self.title = title; self.position = position; self.contentType = contentType; self.contentID = contentID; watchedAt = .now }
}
public struct Preferences: Codable, Sendable, Equatable {
    public var darkTheme = true
    public var showChat = true
    public var chatFontSize = 15.0
    public var timestamps = false
    public var emotes = true
    public var autoscroll = true
    public var reduceMotion = false
    public var preferredQuality = "auto"
    public var autoplay = false
    public var pictureInPicture = true
    public var retryPlayback = true
    public init() {}
}
public struct PersonalData: Codable, Sendable {
    public var favorites: [String] = []
    public var history: [WatchEntry] = []
    public var recentSearches: [String] = []
    public var preferences = Preferences()
    public var onboardingComplete = false
    public var modifiedAt = Date()
    public init() {}
}
@MainActor @Observable public final class PersonalStore {
    public var data: PersonalData { didSet { save() } }
    public private(set) var error: String?
    private let url: URL
    public init(url: URL = PersonalStore.defaultURL) {
        self.url = url
        data = PersonalData()
        do {
            if FileManager.default.fileExists(atPath: url.path) { data = try JSONDecoder().decode(PersonalData.self, from: Data(contentsOf: url)) }
        } catch { self.error = "Saved preferences could not be read. The existing file has been preserved." }
    }
    public static var defaultURL: URL { URL.applicationSupportDirectory.appendingPathComponent("Twitchy/personal.json") }
    private func save() {
        do { try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true); try JSONEncoder().encode(data).write(to: url, options: .atomic); error = nil }
        catch { self.error = "Your preferences could not be saved. \(error.localizedDescription)" }
    }
    public func favorite(_ login: String) { if data.favorites.contains(login) { data.favorites.removeAll { $0 == login } } else { data.favorites.append(login) }; data.modifiedAt = .now }
    public func watched(_ entry: WatchEntry) { data.history.removeAll { $0.login == entry.login }; data.history.insert(entry, at: 0); data.history = Array(data.history.prefix(100)); data.modifiedAt = .now }
    public func searched(_ text: String) { guard !text.isEmpty else { return }; data.recentSearches.removeAll { $0 == text }; data.recentSearches.insert(text, at: 0); data.recentSearches = Array(data.recentSearches.prefix(20)) }
}
