import Foundation
import Testing
@testable import TwitchyCore
@testable import TwitchyAPI
@testable import TwitchyAuth
@testable import TwitchySources
@testable import TwitchyPlayback
@testable import TwitchyChat

actor FixtureTransport: HTTPTransport {
    var responses: [HTTPResult]
    var requests: [URLRequest] = []
    init(_ bodies: [String], statuses: [Int] = []) { responses = bodies.enumerated().map { HTTPResult(data: Data($0.element.utf8), status: statuses.indices.contains($0.offset) ? statuses[$0.offset] : 200) } }
    init(results: [HTTPResult]) { responses = results }
    func send(_ request: URLRequest) async throws -> HTTPResult { requests.append(request); guard !responses.isEmpty else { throw URLError(.notConnectedToInternet) }; return responses.removeFirst() }
}
final class MemorySecrets: SecretStore, @unchecked Sendable {
    private let lock = NSLock(); private var items: [String: Data] = [:]
    func read(_ key: String) throws -> Data? { lock.withLock { items[key] } }
    func write(_ data: Data, key: String) throws { lock.withLock { items[key] = data } }
    func delete(_ key: String) throws { lock.withLock { items[key] = nil } }
}
let capabilities = """
{"api_version":"v1","playback_protocols":["hls"],"live":true,"vod":true,"clips":true,"quality_selection":true,"downloads":false,"authorized_downloads_only":true}
"""
let streamPage = """
{"data":[{"id":"s1","user_id":"1","user_login":"alice","user_name":"Alice","game_id":"2","game_name":"Art","title":"Drawing","viewer_count":25,"thumbnail_url":"https://example.com/{width}x{height}.jpg"}],"pagination":{"cursor":"next"}}
"""
@Test func streamDecodingAndPagination() throws {
    let page = try JSONCoding.decoder().decode(Page<TwitchStream>.self, from: Data(streamPage.utf8))
    #expect(page.data.first?.userLogin == "alice"); #expect(page.pagination?.cursor == "next"); #expect(page.data.first?.thumbnail?.absoluteString == "https://example.com/640x360.jpg")
}
@Test func validHTTPSAndTailscaleSource() throws {
    #expect(try SourceURL.validate("https://example.tailnet.ts.net").host == "example.tailnet.ts.net")
}
@Test(arguments: ["https://user:password@example.com", "https://example.com?token=bad", "https://example.com/#token", "file:///etc/passwd", "http://example.com", "javascript:alert(1)"])
func rejectedSourceURLs(_ value: String) { #expect(throws: (any Error).self) { try SourceURL.validate(value, allowLocalHTTP: true) } }
@Test func developmentSourceMustBeExplicit() throws {
    #expect(throws: ClientError.insecureURL) { try SourceURL.validate("http://localhost:8181") }
    #expect(try SourceURL.validate("http://127.0.0.1:8181", allowLocalHTTP: true).port == 8181)
    #expect(throws: ClientError.insecureURL) { try SourceURL.validate("http://192.168.evil.com", allowLocalHTTP: true) }
}
@Test func mediaURLAllowsSignatureButNotCredentials() throws {
    #expect(try SourceURL.media(URL(string: "https://cdn.example.com/a.m3u8?signature=short")!, allowLocalHTTP: false).query != nil)
    #expect(throws: ClientError.invalidURL) { try SourceURL.media(URL(string: "https://secret@cdn.example.com/a.m3u8")!, allowLocalHTTP: false) }
}
@Test func oauthStateAndCallback() throws {
    let config = OAuthConfiguration(clientID: "public-id", redirectURI: URL(string: "https://login.example.com/twitchy/callback")!)
    let attempt = try OAuthAttempt(configuration: config, scopes: ["user:read:follows"])
    #expect(try attempt.token(from: URL(string: "twitchy://oauth#access_token=test-only&state=\(attempt.state)")!) == "test-only")
    #expect(throws: (any Error).self) { try attempt.token(from: URL(string: "twitchy://oauth#access_token=test-only&state=wrong")!) }
    #expect(throws: ClientError.invalidURL) { try attempt.token(from: URL(string: "other://oauth#access_token=test-only&state=\(attempt.state)")!) }
    #expect(!attempt.url.absoluteString.contains("client_secret")); #expect(!attempt.url.absoluteString.contains("code_challenge"))
}
@Test @MainActor func sourcePersistenceSwitchingAndSecrets() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("sources.json"); let secrets = MemorySecrets()
    let manager = StreamingSourceManager(url: file, secrets: secrets)
    let first = StreamingSource(name: "First", baseURL: URL(string: "https://first.example")!, usesAuthentication: true)
    let second = StreamingSource(name: "Second", baseURL: URL(string: "https://second.example")!)
    try manager.upsert(first, credential: "source-test-secret"); try manager.upsert(second); try manager.select(second.id)
    let restored = StreamingSourceManager(url: file, secrets: secrets)
    #expect(restored.active?.id == second.id); #expect(restored.sources.count == 2)
    #expect(!String(decoding: try Data(contentsOf: file), as: UTF8.self).contains("source-test-secret"))
    try restored.remove(second.id); #expect(restored.active?.id == first.id)
    try restored.remove(first.id); #expect(try secrets.read(first.id.uuidString) == nil)
}
@Test @MainActor func preferencesHistoryAndSearchPersistence() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("settings.json")
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let store = PersonalStore(url: file); store.favorite("alice"); store.watched(.init(login: "alice", title: "Alice")); store.searched("art"); store.data.preferences.showChat = false
    let restored = PersonalStore(url: file)
    #expect(restored.data.favorites == ["alice"]); #expect(restored.data.history.count == 1); #expect(restored.data.recentSearches == ["art"]); #expect(!restored.data.preferences.showChat)
}
@Test func credentialIsolationAndHelixQuery() async throws {
    let twitchTransport = FixtureTransport([streamPage]); let api = TwitchAPIClient(clientID: "public-id", token: "twitch-test-only", transport: twitchTransport)
    _ = try await api.streams(after: "cursor")
    let twitchRequest = try #require(await twitchTransport.requests.first)
    #expect(twitchRequest.url?.host == "api.twitch.tv"); #expect(twitchRequest.value(forHTTPHeaderField: "Authorization") == "Bearer twitch-test-only"); #expect(twitchRequest.url?.query?.contains("after=cursor") == true)
    let sourceTransport = FixtureTransport([capabilities]); let source = StreamingSource(name: "Source", baseURL: URL(string: "https://source.example")!)
    let client = try StreamingSourceClient(source: source, authentication: .bearer("source-test-only"), transport: sourceTransport); _ = try await client.capabilities()
    let request = try #require(await sourceTransport.requests.first)
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer source-test-only"); #expect(request.value(forHTTPHeaderField: "Client-Id") == nil)
}
@Test func capabilityGatingPreventsSession() async throws {
    let transport = FixtureTransport(["{\"api_version\":\"v1\",\"playback_protocols\":[],\"live\":false,\"vod\":false,\"clips\":false,\"quality_selection\":false,\"downloads\":false,\"authorized_downloads_only\":true}"])
    let client = try StreamingSourceClient(source: .init(name: "No video", baseURL: URL(string: "https://source.example")!), transport: transport)
    await #expect(throws: ClientError.unsupported) { try await client.createSession(.init(channelLogin: "alice")) }
    #expect(await transport.requests.count == 1)
}
@Test func sessionContractDecodingAndOptionalFields() throws {
    let value = try JSONCoding.decoder().decode(PlaybackSession.self, from: Data("{\"session_id\":\"s1\",\"hls_url\":\"https://cdn.example/a.m3u8\",\"qualities\":[\"auto\",\"720p\"]}".utf8))
    #expect(value.qualities == ["auto", "720p"]); #expect(value.expiresAt == nil)
}
@Test func incompatibleSourceRejected() async throws {
    let transport = FixtureTransport(["{\"status\":\"ok\",\"server_version\":\"1.0\",\"api_version\":\"v2\"}"])
    let client = try StreamingSourceClient(source: .init(name: "Future", baseURL: URL(string: "https://source.example")!), transport: transport)
    await #expect(throws: ClientError.incompatibleAPI) { try await client.health() }
}
@Test func structuredSourceError() async throws {
    let transport = FixtureTransport(["{\"error\":{\"code\":\"permission_required\",\"message\":\"sensitive detail\",\"retryable\":false}}"], statuses: [403])
    let client = try StreamingSourceClient(source: .init(name: "Private", baseURL: URL(string: "https://source.example")!), transport: transport)
    do { _ = try await client.health(); Issue.record("Expected error") } catch let error as SourceAPIError { #expect(error.problem.code == "permission_required"); #expect(!error.localizedDescription.contains("sensitive detail")) }
}
@Test func offlineAndAuthFailures() async throws {
    let offline = HTTPClient(transport: FixtureTransport([])); let r = URLRequest(url: URL(string: "https://example.com")!)
    await #expect(throws: URLError.self) { try await offline.response(r) }
    let unauthorized = HTTPClient(transport: FixtureTransport(["{}"], statuses: [401]))
    await #expect(throws: ClientError.unauthorized) { try await unauthorized.response(r) }
}
@Test func mutatingRequestsAreNotRetried() async throws {
    let transport = FixtureTransport(["{}"], statuses: [429]); var r = URLRequest(url: URL(string: "https://example.com")!); r.httpMethod = "POST"
    await #expect(throws: ClientError.rateLimited) { try await HTTPClient(transport: transport).response(r) }
    #expect(await transport.requests.count == 1)
}
@Test func safeGETBackoffRetries() async throws {
    let transport = FixtureTransport(["{}", "{}"], statuses: [503, 200])
    let response = try await HTTPClient(transport: transport).response(URLRequest(url: URL(string: "https://example.com")!))
    #expect(response.status == 200); #expect(await transport.requests.count == 2)
}
@Test @MainActor func revokedTokenRestorationClearsKeychain() async throws {
    let secrets = MemorySecrets(); let session = AuthSession(accessToken: "test", refreshToken: nil, clientID: "id", userID: "1", login: "alice", scopes: [], expiresAt: .distantPast)
    try secrets.write(JSONEncoder().encode(session), key: "session")
    let manager = TwitchAuthManager(secrets: secrets, transport: FixtureTransport(["{}"], statuses: [401])); await manager.restore()
    #expect(manager.session == nil); #expect(try secrets.read("session") == nil)
}
@Test @MainActor func tokenValidationIdentityAndExpiry() async throws {
    let secrets = MemorySecrets(); let session = AuthSession(accessToken: "test", refreshToken: nil, clientID: "id", userID: "1", login: "alice", scopes: [], expiresAt: .distantPast)
    try secrets.write(JSONEncoder().encode(session), key: "session")
    let manager = TwitchAuthManager(secrets: secrets, transport: FixtureTransport(["{\"client_id\":\"id\",\"user_id\":\"1\",\"login\":\"alice\",\"scopes\":[\"user:read:follows\"],\"expires_in\":3600}"])); await manager.restore()
    #expect(manager.session?.isExpired == false); #expect(manager.session?.scopes == ["user:read:follows"])
}
@Test func eventSubWelcomeKeepaliveMigrationAndChat() throws {
    let welcome = "{\"metadata\":{\"message_id\":\"1\",\"message_type\":\"session_welcome\",\"message_timestamp\":\"now\"},\"payload\":{\"session\":{\"id\":\"s\",\"keepalive_timeout_seconds\":10}}}"
    let e = try JSONCoding.decoder().decode(EventSubEnvelope.self, from: Data(welcome.utf8)); #expect(e.payload.session?.keepaliveTimeoutSeconds == 10)
    #expect(try EventSubPolicy.reconnectURL("wss://eventsub.wss.twitch.tv/ws?session=test").host == "eventsub.wss.twitch.tv")
    #expect(throws: ClientError.invalidURL) { try EventSubPolicy.reconnectURL("wss://evil.example/ws") }; #expect(EventSubPolicy.backoff(attempt: 20) == 30)
    let chat = "{\"chatter_user_name\":\"Alice\",\"chatter_user_login\":\"alice\",\"color\":\"#FFFFFF\",\"message_id\":\"m1\",\"message\":{\"text\":\"Hello 🌍\",\"fragments\":[{\"type\":\"text\",\"text\":\"Hello 🌍\"}]},\"badges\":[]}"
    #expect(try JSONCoding.decoder().decode(ChatMessage.self, from: Data(chat.utf8)).message.text == "Hello 🌍")
}
@Test func badgeDecoding() throws {
    let json = "{\"data\":[{\"set_id\":\"moderator\",\"versions\":[{\"id\":\"1\",\"image_url_1x\":\"https://example.com/badge.png\",\"title\":\"Moderator\"}]}]}"
    #expect(try JSONCoding.decoder().decode(Page<BadgeSet>.self, from: Data(json.utf8)).data.first?.setId == "moderator")
}
@Test func downloadProgressAndFailuresDecode() throws {
    let json = "{\"id\":\"d1\",\"status\":\"failed\",\"progress\":0.5,\"transferred_bytes\":1024,\"error\":{\"code\":\"expired\",\"message\":\"Expired\",\"retryable\":true}}"
    let job = try JSONCoding.decoder().decode(DownloadJob.self, from: Data(json.utf8)); #expect(job.status == .failed); #expect(job.transferredBytes == 1024); #expect(job.error?.retryable == true)
}
@Test @MainActor func playerHasNoDirectFallback() async {
    let player = PlaybackController(); #expect(player.state == .idle); #expect(player.player.currentItem == nil); await player.stop(); #expect(player.session == nil)
}

actor ValidationGate: HTTPTransport {
    var waiting = false
    var pending: CheckedContinuation<HTTPResult, Never>?
    func send(_ request: URLRequest) async throws -> HTTPResult {
        if request.url?.path == "/oauth2/revoke" { return HTTPResult(data: Data(), status: 200) }
        waiting = true
        return await withCheckedContinuation { pending = $0 }
    }
    func release() { pending?.resume(returning: HTTPResult(data: Data("{\"client_id\":\"id\",\"user_id\":\"1\",\"login\":\"alice\",\"scopes\":[],\"expires_in\":3600}".utf8), status: 200)); pending = nil }
}
@Test @MainActor func logoutCannotBeUndoneByInFlightValidation() async throws {
    let secrets = MemorySecrets(); let session = AuthSession(accessToken: "test", refreshToken: nil, clientID: "id", userID: "1", login: "alice", scopes: [], expiresAt: .distantFuture)
    try secrets.write(JSONEncoder().encode(session), key: "session")
    let transport = ValidationGate(); let manager = TwitchAuthManager(secrets: secrets, transport: transport)
    let restoration = Task { await manager.restore() }
    for _ in 0..<100 { if await transport.waiting { break }; await Task.yield() }
    #expect(await transport.waiting)
    await manager.logout(); await transport.release(); await restoration.value
    #expect(manager.session == nil); #expect(try secrets.read("session") == nil)
}
@Test @MainActor func deviceRefreshRotatesSecretWithoutClientSecret() async throws {
    let secrets = MemorySecrets(); let session = AuthSession(accessToken: "old-test", refreshToken: "old-refresh", clientID: "device-id", userID: "1", login: "alice", scopes: [], expiresAt: .distantPast)
    try secrets.write(JSONEncoder().encode(session), key: "session")
    let transport = FixtureTransport(["{}", "{\"access_token\":\"new-test\",\"refresh_token\":\"rotated-test\"}", "{\"client_id\":\"device-id\",\"user_id\":\"1\",\"login\":\"alice\",\"scopes\":[],\"expires_in\":3600}"], statuses: [401,200,200])
    let manager = TwitchAuthManager(secrets: secrets, transport: transport); await manager.restore()
    #expect(manager.session?.refreshToken == "rotated-test")
    let requests = await transport.requests
    #expect(!String(decoding: requests[1].httpBody ?? Data(), as: UTF8.self).contains("client_secret"))
    let saved = try #require(try secrets.read("session"))
    #expect(try JSONDecoder().decode(AuthSession.self, from: saved).refreshToken == "rotated-test")
}
@Test func emoteImageWireKeys() throws {
    let fixture = "{\"data\":[{\"id\":\"25\",\"name\":\"Kappa\",\"images\":{\"url_1x\":\"https://example.com/1.png\",\"url_2x\":\"https://example.com/2.png\",\"url_4x\":\"https://example.com/4.png\"}}]}"
    #expect(try JSONCoding.decoder().decode(Page<Emote>.self, from: Data(fixture.utf8)).data.first?.images.url1x == "https://example.com/1.png")
}

@Test func rateLimitWindowIsNeverShortened() async throws {
    let transport = FixtureTransport(results: [HTTPResult(data: Data(), status: 429, headers: ["retry-after": "90"])])
    await #expect(throws: ClientError.rateLimited) { try await HTTPClient(transport: transport).response(URLRequest(url: URL(string: "https://example.com")!)) }
    #expect(await transport.requests.count == 1)
}
@Test @MainActor func sourceOriginEditRequiresNewCredential() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("sources.json")
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let manager = StreamingSourceManager(url: file, secrets: MemorySecrets())
    var source = StreamingSource(name: "Private", baseURL: URL(string: "https://first.example")!, usesAuthentication: true)
    try manager.upsert(source, credential: "source-test")
    source.baseURL = URL(string: "https://second.example")!
    #expect(throws: ClientError.self) { try manager.upsert(source) }
    #expect(manager.active?.baseURL.host == "first.example")
}

@Test @MainActor func downloadCancellationNeverContactsAnotherSource() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let job = try JSONCoding.decoder().decode(DownloadJob.self, from: Data("{\"id\":\"job-1\",\"status\":\"queued\",\"progress\":0,\"transferred_bytes\":0}".utf8))
    let item = LocalDownload(sourceID: UUID(), job: job, contentType: "vod", contentID: "fixture", authorizationReference: "fixture-owner")
    try JSONEncoder().encode([item]).write(to: directory.appendingPathComponent("index.json"))
    let manager = DownloadManager(directory: directory)
    let transport = FixtureTransport([])
    let wrong = try StreamingSourceClient(source: .init(name: "Other source", baseURL: URL(string: "https://other.example")!), transport: transport)
    await manager.cancel(item.id, client: wrong)
    #expect(manager.items.first?.job.status == .cancelled)
    #expect(await transport.requests.isEmpty)
}

@Test @MainActor func rotatedRefreshSurvivesOfflineValidationAndRestart() async throws {
    let secrets = MemorySecrets()
    let old = AuthSession(accessToken: "old", refreshToken: "old-refresh", clientID: "id", userID: "1", login: "alice", scopes: [], expiresAt: .distantPast)
    try secrets.write(JSONEncoder().encode(old), key: "session")
    let first = TwitchAuthManager(secrets: secrets, transport: FixtureTransport(["{}", "{\"access_token\":\"new\",\"refresh_token\":\"rotated\"}"], statuses: [401,200]))
    await first.restore()
    #expect(first.session?.refreshToken == "rotated")
    #expect(first.status != "Connected")
    let second = TwitchAuthManager(secrets: secrets, transport: FixtureTransport(["{\"client_id\":\"id\",\"user_id\":\"1\",\"login\":\"alice\",\"scopes\":[],\"expires_in\":3600}"]))
    await second.restore()
    #expect(second.status == "Connected")
    #expect(second.session?.accessToken == "new")
    #expect(second.session?.refreshToken == "rotated")
}
@Test @MainActor func configurationErrorDoesNotDestroyRefreshCredentials() async throws {
    let secrets = MemorySecrets()
    let old = AuthSession(accessToken: "old", refreshToken: "refresh", clientID: "id", userID: "1", login: "alice", scopes: [], expiresAt: .distantPast)
    try secrets.write(JSONEncoder().encode(old), key: "session")
    let manager = TwitchAuthManager(secrets: secrets, transport: FixtureTransport(["{}", "{\"message\":\"invalid client secret\"}"], statuses: [401,400]))
    await manager.restore()
    #expect(manager.session?.refreshToken == "refresh")
    #expect(try secrets.read("session") != nil)
    #expect(manager.error?.contains("Public Twitch application") == true)
}
@Test @MainActor func invalidRefreshClearsCredentialsWithActionableMessage() async throws {
    let secrets = MemorySecrets()
    let old = AuthSession(accessToken: "old", refreshToken: "revoked", clientID: "id", userID: "1", login: "alice", scopes: [], expiresAt: .distantPast)
    try secrets.write(JSONEncoder().encode(old), key: "session")
    let manager = TwitchAuthManager(secrets: secrets, transport: FixtureTransport(["{}", "{\"error\":\"Bad Request\",\"message\":\"Invalid refresh token\"}"], statuses: [401,400]))
    await manager.restore()
    #expect(manager.session == nil)
    #expect(try secrets.read("session") == nil)
    #expect(manager.error?.contains("Sign in again") == true)
}
actor RefreshGate: HTTPTransport {
    var tokenCalls = 0
    var started = false
    var releaseToken: CheckedContinuation<HTTPResult, Never>?
    func send(_ request: URLRequest) async throws -> HTTPResult {
        if request.url?.path == "/oauth2/token" {
            tokenCalls += 1; started = true
            return await withCheckedContinuation { releaseToken = $0 }
        }
        if request.value(forHTTPHeaderField: "Authorization") == "OAuth old" { return HTTPResult(data: Data(), status: 401) }
        return HTTPResult(data: Data("{\"client_id\":\"id\",\"user_id\":\"1\",\"login\":\"alice\",\"scopes\":[],\"expires_in\":3600}".utf8), status: 200)
    }
    func release() { releaseToken?.resume(returning: HTTPResult(data: Data("{\"access_token\":\"new\",\"refresh_token\":\"rotated\"}".utf8), status: 200)); releaseToken = nil }
}
@Test @MainActor func foregroundAndRestoreShareOneRefresh() async throws {
    let secrets = MemorySecrets()
    try secrets.write(JSONEncoder().encode(AuthSession(accessToken: "old", refreshToken: "refresh", clientID: "id", userID: "1", login: "alice", scopes: [], expiresAt: .distantPast)), key: "session")
    let transport = RefreshGate(); let manager = TwitchAuthManager(secrets: secrets, transport: transport)
    let restore = Task { await manager.restore() }
    while !(await transport.started) { await Task.yield() }
    let foreground = Task { try await manager.validate() }
    await Task.yield(); await transport.release()
    await restore.value; try await foreground.value
    #expect(await transport.tokenCalls == 1)
    #expect(manager.status == "Connected")
}

@Test @MainActor func defaultSignInPollsAndRestoresRefreshableSession() async throws {
    let secrets = MemorySecrets()
    let transport = FixtureTransport([
        "{\"device_code\":\"device-test\",\"user_code\":\"TEST\",\"verification_uri\":\"https://www.twitch.tv/activate?device-code=TEST\",\"expires_in\":60,\"interval\":1}",
        "{\"message\":\"authorization_pending\"}",
        "{\"access_token\":\"device-access\",\"refresh_token\":\"device-refresh\"}",
        "{\"client_id\":\"id\",\"user_id\":\"1\",\"login\":\"alice\",\"scopes\":[\"user:read:follows\"],\"expires_in\":3600}"
    ], statuses: [200,400,200,200])
    let manager = TwitchAuthManager(secrets: secrets, transport: transport)
    await manager.login(configuration: .init(clientID: "legacy", redirectURI: URL(string: "https://example.com")!, deviceClientID: "id"))
    #expect(manager.deviceCode?.userCode == "TEST")
    let deadline = Date().addingTimeInterval(5)
    while manager.status != "Connected", Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
    #expect(manager.status == "Connected")
    #expect(manager.session?.refreshToken == "device-refresh")
    #expect(manager.deviceCode == nil)
    let requests = await transport.requests
    #expect(requests.count == 4)
    #expect(String(decoding: requests[0].httpBody ?? Data(), as: UTF8.self).contains("client_id=id"))
    #expect(!String(decoding: requests[0].httpBody ?? Data(), as: UTF8.self).contains("user%3Awrite%3Achat"))
    let restarted = TwitchAuthManager(secrets: secrets, transport: FixtureTransport(["{\"client_id\":\"id\",\"user_id\":\"1\",\"login\":\"alice\",\"scopes\":[],\"expires_in\":3500}"]))
    await restarted.restore()
    #expect(restarted.status == "Connected")
    #expect(restarted.session?.refreshToken == "device-refresh")
}
@Test @MainActor func cancelDeviceSignInStopsPolling() async throws {
    let transport = FixtureTransport(["{\"device_code\":\"device-test\",\"user_code\":\"TEST\",\"verification_uri\":\"https://www.twitch.tv/activate\",\"expires_in\":60,\"interval\":1}"])
    let manager = TwitchAuthManager(secrets: MemorySecrets(), transport: transport)
    await manager.startDeviceLogin(clientID: "id")
    manager.cancelLogin()
    try await Task.sleep(for: .milliseconds(1100))
    #expect(await transport.requests.count == 1)
    #expect(manager.deviceCode == nil)
    #expect(manager.session == nil)
    #expect(manager.status == "Not connected")
}

@Test func playbackCreationHasPrerollBudgetWithoutSlowingDiscovery() async throws {
    let transport = FixtureTransport([capabilities, "{\"session_id\":\"session\",\"hls_url\":\"https://source.example/media/master.m3u8\",\"qualities\":[\"auto\",\"720p60\"]}"])
    let client = try StreamingSourceClient(source: .init(name: "Source", baseURL: URL(string: "https://source.example")!), transport: transport)
    _ = try await client.createSession(.init(channelLogin: "alice", requestedQuality: "720p60"))
    let requests = await transport.requests
    #expect(requests.count == 2)
    #expect(requests[0].timeoutInterval == 20)
    #expect(requests[1].timeoutInterval == 110)
    #expect(requests[1].httpMethod == "POST")
    let body = try #require(requests[1].httpBody)
    #expect(String(decoding: body, as: UTF8.self).contains("720p60"))
}

@Test func bestQualityUsesServerSelectionAndSupportsOlderSources() throws {
    let data = Data(#"{"session_id":"s1","hls_url":"https://cdn.example/a.m3u8","qualities":["auto","720p60","1080p60"],"selected_quality":"720p60"}"#.utf8)
    let value = try JSONCoding.decoder().decode(PlaybackSession.self, from: data)
    #expect(value.qualityLabel(requested: "auto") == "Best (720p60)")
    #expect(value.qualityLabel(requested: "1080p60") == "1080p60")
    let old = try JSONCoding.decoder().decode(PlaybackSession.self, from: Data(#"{"session_id":"s1","hls_url":"https://cdn.example/a.m3u8","qualities":["auto","1080p60"]}"#.utf8))
    #expect(old.qualityLabel(requested: "auto") == "Best")
}

@Test func clientDownloadsRequireExplicitCapabilityAndPreserveLegacyPermission() async throws {
    let source = StreamingSource(name: "Fixture", baseURL: URL(string: "https://source.example")!)
    let publicCaps = capabilities.replacingOccurrences(of: "\"downloads\":false", with: "\"downloads\":true").replacingOccurrences(of: "\"authorized_downloads_only\":true", with: "\"authorized_downloads_only\":false")
    let denied = try StreamingSourceClient(source: source, transport: FixtureTransport([publicCaps]))
    await #expect(throws: ClientError.unsupported) { try await denied.createDownload(contentType: "vod", contentID: "123") }
    let legacyCaps = capabilities.replacingOccurrences(of: "\"downloads\":false", with: "\"downloads\":true")
    let legacy = try StreamingSourceClient(source: source, transport: FixtureTransport([legacyCaps]))
    await #expect(throws: (any Error).self) { try await legacy.createDownload(contentType: "vod", contentID: "123") }
    let optedIn = publicCaps.dropLast() + ",\"client_side_downloads\":true}"
    let transport = FixtureTransport([String(optedIn), "{\"id\":\"job\",\"status\":\"ready\",\"progress\":0,\"transferred_bytes\":0}"])
    let client = try StreamingSourceClient(source: source, transport: transport)
    #expect(try await client.createDownload(contentType: "vod", contentID: "123", requestedQuality: "720p60").status == .ready)
    let request = try #require(await transport.requests.last)
    let body = try #require(request.httpBody)
    #expect(String(decoding: body, as: UTF8.self).contains("720p60"))
    #expect(try client.downloadFileRequest("job").timeoutInterval == 110)
}
