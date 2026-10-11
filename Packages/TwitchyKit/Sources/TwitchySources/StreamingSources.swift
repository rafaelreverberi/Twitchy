import Foundation
import Observation
import TwitchyCore

public enum SourceURL {
    public static func validate(_ text: String, allowLocalHTTP: Bool = false) throws -> URL {
        guard let c = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), let host = c.host?.lowercased(), !host.isEmpty, c.user == nil, c.password == nil, c.query == nil, c.fragment == nil, let url = c.url else { throw ClientError.invalidURL }
        let privateHost = host == "localhost" || host == "127.0.0.1" || host == "[::1]" || host.hasSuffix(".local") || isPrivateIPv4(host)
        guard c.scheme == "https" || (c.scheme == "http" && allowLocalHTTP && privateHost) else { throw ClientError.insecureURL }
        return url
    }
    private static func isPrivateIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ 0...255 ~= $0 }) else { return false }
        return parts[0] == 10 || (parts[0] == 192 && parts[1] == 168) || (parts[0] == 172 && 16...31 ~= parts[1])
    }
    public static func media(_ url: URL, allowLocalHTTP: Bool) throws -> URL {
        guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false), c.user == nil, c.password == nil else { throw ClientError.invalidURL }
        // Short-lived media query signatures are allowed, long-lived source tokens are never added.
        c.query = nil; c.fragment = nil
        _ = try validate(c.string ?? "", allowLocalHTTP: allowLocalHTTP); return url
    }
}
public struct Capabilities: Codable, Sendable, Equatable {
    public var apiVersion: String
    public var playbackProtocols: [String]
    public var live: Bool
    public var vod: Bool
    public var clips: Bool
    public var qualitySelection: Bool
    public var downloads: Bool
    public var authorizedDownloadsOnly: Bool
    public var clientSideDownloads: Bool?
    public var adHandling: String?
    public init(apiVersion: String = "v1", playbackProtocols: [String] = ["hls"], live: Bool = true, vod: Bool = false, clips: Bool = false, qualitySelection: Bool = false, downloads: Bool = false, authorizedDownloadsOnly: Bool = true, adHandling: String? = nil, clientSideDownloads: Bool? = nil) { self.apiVersion = apiVersion; self.playbackProtocols = playbackProtocols; self.live = live; self.vod = vod; self.clips = clips; self.qualitySelection = qualitySelection; self.downloads = downloads; self.authorizedDownloadsOnly = authorizedDownloadsOnly; self.adHandling = adHandling; self.clientSideDownloads = clientSideDownloads }
}
public struct Health: Codable, Sendable { public var status: String; public var serverVersion: String; public var apiVersion: String }
public struct StreamingSource: Codable, Identifiable, Sendable, Equatable {
    public var id: UUID; public var name: String; public var baseURL: URL; public var enabled: Bool; public var allowLocalHTTP: Bool
    public var usesAuthentication: Bool; public var serverVersion: String?; public var capabilities: Capabilities?; public var lastSuccessfulCheck: Date?; public var connectionStatus: String
    public init(id: UUID = UUID(), name: String, baseURL: URL, allowLocalHTTP: Bool = false, usesAuthentication: Bool = false) { self.id = id; self.name = name; self.baseURL = baseURL; enabled = true; self.allowLocalHTTP = allowLocalHTTP; self.usesAuthentication = usesAuthentication; connectionStatus = "Not tested" }
}
public struct PlaybackRequest: Codable, Sendable {
    public var contentType: String; public var channelLogin: String?; public var contentId: String?; public var requestedQuality: String; public var preferences: Preferences?
    public init(contentType: String = "live", channelLogin: String? = nil, contentId: String? = nil, requestedQuality: String = "auto", preferences: Preferences? = nil) { self.contentType = contentType; self.channelLogin = channelLogin; self.contentId = contentId; self.requestedQuality = requestedQuality; self.preferences = preferences }
    public struct Preferences: Codable, Sendable { public var lowLatency: Bool; public init(lowLatency: Bool = true) { self.lowLatency = lowLatency } }
}
public struct PlaybackSession: Codable, Sendable {
    public var sessionId: String; public var hlsUrl: URL; public var qualities: [String]; public var expiresAt: Date?; public var title: String?; public var playerCapabilities: [String]?; public var filteringStatus: String?; public var state: String?; public var selectedQuality: String?
    public func qualityLabel(requested: String) -> String {
        guard requested == "auto" else { return requested }
        guard let selectedQuality, !selectedQuality.isEmpty else { return "Best" }
        return "Best (\(selectedQuality))"
    }
}
public enum DownloadState: String, Codable, Sendable { case queued, preparing, ready, transferring, paused, completed, failed, cancelled }
public struct DownloadJob: Codable, Identifiable, Sendable {
    public var id: String; public var status: DownloadState; public var progress: Double; public var transferredBytes: Int64; public var totalBytes: Int64?; public var error: APIProblem?; public var fileUrl: URL?; public var filename: String?; public var controls: [String]?
}
public struct APIProblem: Codable, Sendable { public var code: String; public var message: String; public var retryable: Bool }
public struct APIErrorEnvelope: Codable, Sendable { public var error: APIProblem }
public enum SourceAuthentication: Sendable { case none, bearer(String) }
public struct StreamingSourceClient: Sendable {
    public let source: StreamingSource
    private let authentication: SourceAuthentication
    private let http: HTTPClient
    public init(source: StreamingSource, authentication: SourceAuthentication = .none, transport: any HTTPTransport = NetworkTransport(requestTimeout: 110, resourceTimeout: 120)) throws {
        _ = try SourceURL.validate(source.baseURL.absoluteString, allowLocalHTTP: source.allowLocalHTTP)
        self.source = source; self.authentication = authentication; http = HTTPClient(transport: transport)
    }
    private func request(_ path: String, method: String = "GET", body: Data? = nil) throws -> URLRequest {
        guard source.enabled else { throw ClientError.noSource }
        let url = source.baseURL.appendingPathComponent("v1").appendingPathComponent(path)
        var r = URLRequest(url: url); r.timeoutInterval = ((method == "POST" && path == "playback/sessions") || (path.hasPrefix("downloads/") && path.hasSuffix("/file"))) ? 110 : 20; r.httpMethod = method; r.httpBody = body; r.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { r.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if case .bearer(let token) = authentication { r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return r
    }
    private func decode<T: Decodable & Sendable>(_ type: T.Type, _ request: URLRequest) async throws -> T {
        let result = try await http.exchange(request)
        guard 200..<300 ~= result.status else {
            if let problem = try? JSONCoding.decoder().decode(APIErrorEnvelope.self, from: result.data) { throw SourceAPIError(status: result.status, problem: problem.error) }
            if result.status == 401 { throw ClientError.unauthorized }; throw ClientError.server(result.status)
        }
        return try JSONCoding.decoder().decode(type, from: result.data)
    }
    public func health() async throws -> Health { let value = try await decode(Health.self, request("health")); guard value.apiVersion == "v1", value.status == "ok" else { throw ClientError.incompatibleAPI }; return value }
    public func capabilities() async throws -> Capabilities { let value = try await decode(Capabilities.self, request("capabilities")); guard value.apiVersion == "v1" else { throw ClientError.incompatibleAPI }; return value }
    public func createSession(_ body: PlaybackRequest) async throws -> PlaybackSession {
        let caps = try await capabilities()
        guard caps.playbackProtocols.contains("hls"), (body.contentType == "live" ? caps.live : body.contentType == "vod" ? caps.vod : caps.clips) else { throw ClientError.unsupported }
        let session = try await decode(PlaybackSession.self, request("playback/sessions", method: "POST", body: JSONCoding.encoder().encode(body)))
        _ = try SourceURL.media(session.hlsUrl, allowLocalHTTP: source.allowLocalHTTP)
        guard session.expiresAt.map({ $0 > .now }) ?? true else { throw ClientError.invalidResponse }; return session
    }
    private func identifier(_ id: String) throws -> String { guard !id.isEmpty, id.utf8.count < 200, id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { throw ClientError.invalidResponse }; return id }
    public func endSession(_ id: String) async throws { _ = try await http.response(request("playback/sessions/\(identifier(id))", method: "DELETE")) }
    public func createDownload(contentType: String, contentID: String, authorizationReference: String = "", requestedQuality: String = "auto") async throws -> DownloadJob {
        let caps = try await capabilities(); guard caps.downloads, caps.authorizedDownloadsOnly || caps.clientSideDownloads == true else { throw ClientError.unsupported }
        if caps.authorizedDownloadsOnly && authorizationReference.isEmpty { throw ClientError.message("This source requires a permission reference.") }
        struct Body: Codable { var contentType: String; var contentId: String; var authorizationReference: String; var requestedQuality: String? }
        return try await decode(DownloadJob.self, request("downloads", method: "POST", body: JSONCoding.encoder().encode(Body(contentType: contentType, contentId: contentID, authorizationReference: authorizationReference, requestedQuality: caps.clientSideDownloads == true ? requestedQuality : nil))))
    }
    public func download(_ id: String) async throws -> DownloadJob { try await decode(DownloadJob.self, request("downloads/\(identifier(id))")) }
    public func cancelDownload(_ id: String) async throws { _ = try await http.response(request("downloads/\(identifier(id))", method: "DELETE")) }
    public func downloadFileRequest(_ id: String) throws -> URLRequest { try request("downloads/\(identifier(id))/file") }
}
public struct SourceAPIError: Error, LocalizedError, Sendable { public var status: Int; public var problem: APIProblem; public var errorDescription: String? { "Source error: \(problem.code). \(problem.retryable ? "Try again shortly." : "Check source settings or content permissions.")" } }
@MainActor @Observable public final class StreamingSourceManager {
    public private(set) var sources: [StreamingSource] = []
    public private(set) var activeID: UUID?
    public private(set) var error: String?
    @ObservationIgnored public var onChange: (() -> Void)?
    @ObservationIgnored private var applyingRemote = false
    private let url: URL; private let secrets: any SecretStore
    private struct Saved: Codable { var sources: [StreamingSource]; var activeID: UUID? }
    public init(url: URL = TwitchyStoragePaths.directory.appendingPathComponent("sources.json"), secrets: any SecretStore = KeychainStore(service: "com.rafaelreverberi.Twitchy.sources")) {
        self.url = url; self.secrets = secrets
        do { if FileManager.default.fileExists(atPath: url.path) { let saved = try JSONDecoder().decode(Saved.self, from: Data(contentsOf: url)); sources = saved.sources; activeID = saved.activeID } } catch { self.error = "Saved sources could not be read." }
    }
    public var active: StreamingSource? { sources.first { $0.id == activeID && $0.enabled } }
    public func upsert(_ source: StreamingSource, credential: String? = nil) throws {
        _ = try SourceURL.validate(source.baseURL.absoluteString, allowLocalHTTP: source.allowLocalHTTP)
        if source.usesAuthentication, let old = sources.first(where: { $0.id == source.id }), old.baseURL != source.baseURL, credential?.isEmpty != false { throw ClientError.message("Enter a new source credential when changing an authenticated source URL.") }
        if let credential { if credential.isEmpty { try secrets.delete(source.id.uuidString) } else { try secrets.write(Data(credential.utf8), key: source.id.uuidString) } }
        if let index = sources.firstIndex(where: { $0.id == source.id }) { sources[index] = source } else { sources.append(source) }
        if activeID == nil, source.enabled { activeID = source.id }; try persist()
    }
    public func select(_ id: UUID) throws { guard sources.contains(where: { $0.id == id && $0.enabled }) else { throw ClientError.noSource }; activeID = id; try persist() }
    public func remove(_ id: UUID) throws { try secrets.delete(id.uuidString); sources.removeAll { $0.id == id }; if activeID == id { activeID = sources.first(where: \.enabled)?.id }; try persist() }
    public func client(for source: StreamingSource? = nil) throws -> StreamingSourceClient {
        guard let source = source ?? active else { throw ClientError.noSource }
        let secret = try secrets.read(source.id.uuidString).flatMap { String(data: $0, encoding: .utf8) }
        guard !source.usesAuthentication || secret?.isEmpty == false else { throw ClientError.unauthorized }
        return try StreamingSourceClient(source: source, authentication: source.usesAuthentication ? .bearer(secret!) : .none)
    }
    public func test(_ id: UUID) async {
        guard let source = sources.first(where: { $0.id == id }) else { return }
        do {
            let client = try client(for: source); let health = try await client.health(); let caps = try await client.capabilities()
            guard var current = sources.first(where: { $0.id == id }), current.baseURL == source.baseURL, current.enabled == source.enabled else { return }
            current.capabilities = caps; current.serverVersion = health.serverVersion; current.lastSuccessfulCheck = .now; current.connectionStatus = "Connected"
            try upsert(current)
        } catch {
            guard let i = sources.firstIndex(where: { $0.id == id && $0.baseURL == source.baseURL }) else { return }
            sources[i].connectionStatus = error.localizedDescription; self.error = error.localizedDescription
            do { try persist() } catch { self.error = "Source status could not be saved." }
        }
    }
    public func credential(for id: UUID) throws -> String? { try secrets.read(id.uuidString).flatMap { String(data: $0, encoding: .utf8) } }
    public func applySynced(source: StreamingSource?, id: UUID, credential: String?) throws {
        applyingRemote = true; defer { applyingRemote = false }
        if var source {
            if let local = sources.first(where: { $0.id == id && $0.baseURL == source.baseURL }) {
                source.capabilities = local.capabilities; source.serverVersion = local.serverVersion
                source.lastSuccessfulCheck = local.lastSuccessfulCheck; source.connectionStatus = local.connectionStatus
            }
            try upsert(source, credential: credential ?? "")
        }
        else { try remove(id) }
    }
    public func applySyncedSelection(_ id: UUID?) throws {
        applyingRemote = true; defer { applyingRemote = false }
        activeID = id.flatMap { id in sources.contains { $0.id == id && $0.enabled } ? id : nil }
        if activeID == nil { activeID = sources.first(where: \.enabled)?.id }; try persist()
    }
    private func persist() throws { do { try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true); try JSONEncoder().encode(Saved(sources: sources, activeID: activeID)).write(to: url, options: .atomic); error = nil; if !applyingRemote { onChange?() } } catch { self.error = "Sources could not be saved."; throw error } }
}
