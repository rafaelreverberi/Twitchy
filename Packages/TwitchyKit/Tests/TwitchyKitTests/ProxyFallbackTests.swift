import Foundation
import Testing
import AVFoundation
import TwitchyCore
@testable import TwitchySources
import TwitchyPlayback

private let master = "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1000000,RESOLUTION=1280x720\nhttps://media.example/variant.m3u8\n"
private let variant = "#EXTM3U\n#EXT-X-TARGETDURATION:2\n#EXTINF:2.0,\nhttps://media.example/segment.ts\n"
private func proxyConfiguration(_ address: String = "https://proxy.example/live/{channel}.m3u8") -> StreamingProxyConfiguration {
    var value = StreamingProxyConfiguration(); value.enabled = true; value.useCustom = true; value.address = address; return value
}
private actor ProxyFixture: HTTPTransport {
    var requests: [URLRequest] = []
    var unavailable: Set<String> = []
    var sessionErrors: [String: Int] = [:]
    var sessionState = "unavailable"
    func setSessionState(_ value: String) { sessionState = value }
    var proxyStatus = 200
    var broken = false
    var timeout = false
    var redirect: String?
    func fail(_ hosts: Set<String>) { unavailable = hosts }
    func sessionError(_ host: String, status: Int) { sessionErrors[host] = status }
    func setProxy(status: Int = 200, broken: Bool = false, timeout: Bool = false, redirect: String? = nil) { proxyStatus = status; self.broken = broken; self.timeout = timeout; self.redirect = redirect }
    func send(_ request: URLRequest) async throws -> HTTPResult {
        requests.append(request)
        try Task.checkCancellation()
        let host = request.url!.host!, path = request.url!.path
        if unavailable.contains(host) { throw URLError(.cannotConnectToHost) }
        if host == "proxy.example" || host == "media.example" || host == "custom.example" {
            if timeout { throw URLError(.timedOut) }
            if let redirect { return .init(data: Data(), status: 302, headers: ["location": redirect]) }
            return .init(data: Data((broken ? "<html>oops</html>" : path.contains("variant") ? variant : master).utf8), status: proxyStatus)
        }
        if path.hasSuffix("health") { return .init(data: Data(#"{"status":"ok","server_version":"fixture","api_version":"v1"}"#.utf8), status: 200) }
        if path.hasSuffix("capabilities") { return .init(data: Data(capabilities.utf8), status: 200) }
        if request.httpMethod == "DELETE" { return .init(data: Data(), status: 204) }
        if let status = sessionErrors[host] {
            return .init(data: Data("{\"error\":{\"code\":\"fixture\",\"message\":\"fixture\",\"retryable\":\(status >= 500)}}".utf8), status: status)
        }
        let body = #"{"session_id":"fixture","hls_url":"https://media.example/variant.m3u8","qualities":["auto"],"state":"STATE"}"#.replacingOccurrences(of: "STATE", with: sessionState)
        return .init(data: Data(body.utf8), status: 200)
    }
}

@MainActor private func fixtureManager(_ transport: ProxyFixture) -> StreamingSourceManager {
    StreamingSourceManager(url: URL.temporaryDirectory.appendingPathComponent("proxy-tests-" + UUID().uuidString + "/sources.json"), secrets: MemorySecrets(), probeTransport: transport, playbackTransport: transport)
}

@Test @MainActor func proxyRoutingHasOneFinalProviderAndSourcesAlwaysWin() async throws {
    let transport = ProxyFixture(), manager = fixtureManager(ProxyFixture())
    let coordinator = PlaybackFallbackCoordinator(sources: manager, proxy: .init(transport: transport))
    let request = PlaybackRequest(channelLogin: "Channel_1")
    let noSource = try await coordinator.resolve(request, configuration: proxyConfiguration())
    #expect(noSource.providerName == "Custom proxy")
    #expect(noSource.qualities == ["auto", "720p"])
    #expect(await transport.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil && $0.value(forHTTPHeaderField: "Cookie") == nil })
    let sourceTransport = ProxyFixture(), sources = fixtureManager(sourceTransport)
    let primary = StreamingSource(name: "Primary", baseURL: URL(string: "https://primary.example")!, usesAuthentication: true)
    let backup = StreamingSource(name: "Backup", baseURL: URL(string: "https://backup.example")!, usesAuthentication: true)
    let third = StreamingSource(name: "Third", baseURL: URL(string: "https://third.example")!)
    try sources.upsert(primary, credential: "primary-only"); try sources.upsert(backup, credential: "backup-only"); try sources.upsert(third)
    let resolver = PlaybackFallbackCoordinator(sources: sources, proxy: .init(transport: sourceTransport))
    #expect(try await resolver.resolve(request, configuration: proxyConfiguration()).providerName == "Primary")
    await sourceTransport.fail(["primary.example"])
    #expect(try await resolver.resolve(request, configuration: proxyConfiguration()).providerName == "Backup")
    await sourceTransport.fail(["primary.example", "backup.example", "third.example"])
    #expect(try await resolver.resolve(request, configuration: proxyConfiguration()).providerName == "Custom proxy")
    let calls = await sourceTransport.requests
    #expect(calls.filter { $0.url?.host == "primary.example" }.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer primary-only" })
    #expect(calls.filter { $0.url?.host == "backup.example" }.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer backup-only" })
    #expect(calls.filter { ["proxy.example", "media.example"].contains($0.url?.host ?? "") }.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil })
    #expect(sources.activeID == primary.id)
}

@Test @MainActor func recoverableSessionFailuresExhaustEverySourceBeforeProxy() async throws {
    let transport = ProxyFixture(), manager = fixtureManager(transport)
    for host in ["first", "second", "third"] {
        try manager.upsert(.init(name: host, baseURL: URL(string: "https://\(host).example")!))
        await transport.sessionError("\(host).example", status: 503)
    }
    let result = try await PlaybackFallbackCoordinator(sources: manager, proxy: .init(transport: transport)).resolve(.init(channelLogin: "channel"), configuration: proxyConfiguration())
    if case .proxy = result {} else { Issue.record("Expected proxy after all three sessions failed") }
    let calls = await transport.requests
    #expect(calls.filter { $0.httpMethod == "POST" }.compactMap { $0.url?.host } == ["first.example", "second.example", "third.example"])
    #expect(calls.last?.url?.host == "media.example")
}

@Test @MainActor func disabledAndUnverifiedDefaultsNeverMakeProxyRequests() async throws {
    let transport = ProxyFixture(), manager = fixtureManager(transport)
    let resolver = PlaybackFallbackCoordinator(sources: manager, proxy: .init(transport: transport))
    var config = proxyConfiguration(); config.enabled = false
    await #expect(throws: ProxyError.disabled) { try await resolver.resolve(.init(channelLogin: "channel"), configuration: config) }
    config.enabled = true; config.useCustom = false
    #expect(DefaultProxyConfiguration.verified == nil)
    await #expect(throws: ProxyError.noVerifiedDefault) { try await resolver.resolve(.init(channelLogin: "channel"), configuration: config) }
    #expect(await transport.requests.isEmpty)
}

@Test @MainActor func customReplacesDefaultAndNeverRotatesOnFailure() async throws {
    let transport = ProxyFixture(), manager = fixtureManager(transport)
    await transport.setProxy(status: 503)
    let resolver = PlaybackFallbackCoordinator(sources: manager, proxy: .init(transport: transport))
    await #expect(throws: ProxyError.http(503)) { try await resolver.resolve(.init(channelLogin: "channel"), configuration: proxyConfiguration("https://custom.example/{channel}")) }
    #expect(await transport.requests.count == 1)
    #expect(await transport.requests.first?.url?.host == "custom.example")
    await #expect(throws: ProxyError.exhausted) { try await resolver.resolve(.init(channelLogin: "channel"), configuration: proxyConfiguration(), proxyAttempted: true) }
    #expect(await transport.requests.count == 1)
}

@Test @MainActor func contentAndPermissionErrorsNeverReachProxy() async throws {
    let transport = ProxyFixture(), manager = fixtureManager(transport)
    let source = StreamingSource(name: "Source", baseURL: URL(string: "https://source.example")!)
    try manager.upsert(source)
    let resolver = PlaybackFallbackCoordinator(sources: manager, proxy: .init(transport: transport))
    // A real offline state is a source result, never an infrastructure failure.
    let offline = try await resolver.resolve(.init(channelLogin: "channel"), configuration: proxyConfiguration())
    if case .source(_, let session) = offline { #expect(session.state == "unavailable") } else { Issue.record("Offline content reached proxy") }
    for status in [401, 403, 404] {
        await transport.sessionError("source.example", status: status)
        await #expect(throws: SourceAPIError.self) { try await resolver.resolve(.init(channelLogin: "channel"), configuration: proxyConfiguration()) }
    }
    #expect(await transport.requests.allSatisfy { $0.url?.host == "source.example" })
    await #expect(throws: ClientError.unsupported) { try await ProxyPlaybackProvider(transport: transport).resolve(configuration: proxyConfiguration(), request: .init(contentType: "vod", contentId: "123")) }
}

@Test(arguments: [403, 404, 429, 500, 502, 503]) func proxyHTTPErrorsAreActionableAndNotCalledOffline(_ status: Int) async throws {
    let transport = ProxyFixture(); await transport.setProxy(status: status)
    await #expect(throws: ProxyError.http(status)) { try await ProxyPlaybackProvider(transport: transport).resolve(configuration: proxyConfiguration(), request: .init(channelLogin: "channel")) }
    #expect(await transport.requests.count == 1)
}

@Test func brokenManifestAndTimeoutAreBounded() async throws {
    let transport = ProxyFixture()
    await transport.setProxy(broken: true)
    await #expect(throws: ProxyError.invalidPlaylist) { try await ProxyPlaybackProvider(transport: transport).resolve(configuration: proxyConfiguration(), request: .init(channelLogin: "channel")) }
    await transport.setProxy(timeout: true)
    await #expect(throws: URLError(.timedOut)) { try await ProxyPlaybackProvider(transport: transport).resolve(configuration: proxyConfiguration(), request: .init(channelLogin: "channel")) }
    #expect(await transport.requests.count == 2)
}

@Test(arguments: ["http://public.example/{channel}", "https://user:pass@host.example/{channel}", "https://host.example/no-placeholder", "https://{channel}.example/live", "https://host.example/{channel}#fragment", "https://host.example/{channel}?token=secret", "https://host.example/{channel}/{channel}"])
func unsafeProxyConfigurationsAreRejected(_ address: String) throws {
    #expect(throws: (any Error).self) { try ProxyEndpoint(configuration: proxyConfiguration(address)).url(channel: "channel") }
}

@Test func channelNormalizationLocalOptInAndQueryPaths() throws {
    let url = try ProxyEndpoint(configuration: proxyConfiguration("https://proxy.example/prefix/hls?login={channel}&mode=live")).url(channel: " Channel_1 ")
    #expect(url.absoluteString == "https://proxy.example/prefix/hls?login=channel_1&mode=live")
    #expect(try ProxyEndpoint(configuration: proxyConfiguration("https://proxy.example?channel={channel}")).url(channel: "channel").query == "channel=channel")
    for login in ["a/b", "a?secret", "", "abc-123", String(repeating: "a", count: 26)] {
        #expect(throws: ProxyError.invalidChannel) { try ProxyEndpoint(configuration: proxyConfiguration()).url(channel: login) }
    }
    var local = proxyConfiguration("http://localhost:8181/{channel}")
    #expect(throws: ProxyError.unsafeURL) { try ProxyEndpoint(configuration: local).url(channel: "channel") }
    local.allowLocalHTTP = true
    #expect(try ProxyEndpoint(configuration: local).url(channel: "channel").scheme == "http")
    local.contract = .luminous; local.address = "https://proxy.example/prefix?mode=live"
    #expect(try ProxyEndpoint(configuration: local).url(channel: "channel").path == "/prefix/live/channel")
    #expect(try ProxyEndpoint(configuration: local).url(channel: "channel").query == "mode=live")
}

@Test func manifestRejectsUnsafeChildrenKeysAndUnsupportedFormats() throws {
    for text in ["<html>error</html>", "#EXTM3U\n", "#EXTM3U\n#EXTINF:1,\nfile:///etc/passwd", "#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI=\"http://public.example/key\"\n#EXTINF:1,\nhttps://media.example/segment.ts", "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1\n"] {
        #expect(throws: (any Error).self) { try HLSManifest(data: Data(text.utf8), base: URL(string: "https://proxy.example/master")!, allowLocalHTTP: false) }
    }
}

@Test(arguments: ["http://public.example/playlist", "https://user:pass@media.example/playlist", "https://169.254.169.254/latest", "file:///etc/passwd"])
func unsafeProxyRedirectsNeverReceiveRequests(_ target: String) async throws {
    let transport = ProxyFixture(); await transport.setProxy(redirect: target)
    await #expect(throws: ProxyError.unsafeURL) { try await ProxyPlaybackProvider(transport: transport).resolve(configuration: proxyConfiguration(), request: .init(channelLogin: "channel")) }
    #expect(await transport.requests.count == 1)
}

@Test @MainActor func proxyConfigurationMigratesAndSyncsWithoutChangingPreferences() async throws {
    let dir = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    var legacy = PersonalData(); legacy.preferences.preferredQuality = "720p"; legacy.favorites = ["channel"]
    var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as! [String: Any]
    json.removeValue(forKey: "proxyConfiguration")
    let decoded = try JSONDecoder().decode(PersonalData.self, from: JSONSerialization.data(withJSONObject: json))
    #expect(decoded.proxyConfiguration == nil); #expect(decoded.preferences.preferredQuality == "720p")
    let transport = FixtureCloud(), keys = MemorySecrets()
    let a = PersonalStore(url: dir.appendingPathComponent("a/personal.json")), b = PersonalStore(url: dir.appendingPathComponent("b/personal.json"))
    a.data = decoded
    let sourceA = StreamingSourceManager(url: dir.appendingPathComponent("a/sources.json"), secrets: keys)
    let sourceB = StreamingSourceManager(url: dir.appendingPathComponent("b/sources.json"), secrets: keys)
    let cloudA = CloudSyncStore(transport: transport, file: dir.appendingPathComponent("a/sealed"), secrets: keys)
    let cloudB = CloudSyncStore(transport: transport, file: dir.appendingPathComponent("b/sealed"), secrets: keys)
    let syncA = AppDataSync(personal: a, sources: sourceA, cloud: cloudA), syncB = AppDataSync(personal: b, sources: sourceB, cloud: cloudB)
    try syncA.start(); try syncB.start()
    a.data.proxyConfiguration = proxyConfiguration()
    await syncA.sync(); await syncB.sync()
    #expect(b.data.proxyConfiguration == a.data.proxyConfiguration)
    let restored = PersonalStore(url: dir.appendingPathComponent("a/personal.json"))
    #expect(restored.data.proxyConfiguration == proxyConfiguration())
    #expect(restored.data.favorites == ["channel"])
    #expect(restored.data.preferences.preferredQuality == "720p")
}

private actor GatedProxy: HTTPTransport {
    var gate: CheckedContinuation<Void, Never>?
    var started = false
    func release() { gate?.resume(); gate = nil }
    func send(_ request: URLRequest) async throws -> HTTPResult {
        started = true
        await withCheckedContinuation { gate = $0 }
        // Deliberately ignore cancellation, exercising the controller's generation guard.
        return .init(data: Data(variant.utf8), status: 200)
    }
}
@Test @MainActor func rapidChannelChangesAndStopRejectStaleProxyResults() async throws {
    let transport = GatedProxy(), manager = fixtureManager(ProxyFixture())
    let resolver = PlaybackFallbackCoordinator(sources: manager, proxy: .init(transport: transport))
    let player = PlaybackController()
    player.resolvePlayback = { request, excluded, attempted in try await resolver.resolve(request, configuration: proxyConfiguration(), excluding: excluded, proxyAttempted: attempted) }
    let first = Task { await player.start(request: .init(channelLogin: "first")) }
    while !(await transport.started) { await Task.yield() }
    first.cancel()
    // Switch to an immediately terminal second request without any network traffic.
    player.resolvePlayback = { _, _, _ in throw ProxyError.disabled }
    await player.start(request: .init(channelLogin: "second"))
    await transport.release(); await first.value
    #expect(player.currentRequest?.channelLogin == "second")
    #expect(player.player.currentItem == nil)
    #expect(player.error == ProxyError.disabled.localizedDescription)
    await player.stop()
    #expect(player.state == .idle); #expect(player.currentRequest == nil)
}

// Opt-in only: this contacts the exact permitted endpoint supplied by the developer.
@Test(.enabled(if: ProcessInfo.processInfo.environment["TWITCHY_LIVE_PROXY_TEMPLATE"] != nil))
@MainActor func liveProxyNativePlaybackIntegration() async throws {
    let template = try #require(ProcessInfo.processInfo.environment["TWITCHY_LIVE_PROXY_TEMPLATE"])
    let channel = try #require(ProcessInfo.processInfo.environment["TWITCHY_LIVE_PROXY_CHANNEL"])
    let manager = fixtureManager(ProxyFixture())
    let resolver = PlaybackFallbackCoordinator(sources: manager)
    let controller = PlaybackController()
    controller.resolvePlayback = { request, excluded, attempted in
        try await resolver.resolve(request, configuration: proxyConfiguration(template), excluding: excluded, proxyAttempted: attempted)
    }
    let playerID = ObjectIdentifier(controller.player)
    controller.player.isMuted = true; controller.player.volume = 0.25
    await controller.start(request: .init(channelLogin: channel))
    var advanced = false
    for _ in 0..<40 {
        try await Task.sleep(for: .milliseconds(500))
        if controller.state == .failed { break }
        if controller.state == .playing, controller.player.currentTime().seconds > 1 { advanced = true; break }
    }
    #expect(advanced, "Native AVPlayer must advance its media clock; a playlist alone is insufficient.")
    #expect(controller.usingProxy)
    #expect(controller.player.isMuted)
    #expect(controller.player.volume == 0.25)
    #expect(ObjectIdentifier(controller.player) == playerID)
    controller.togglePlayPause()
    #expect(controller.isPaused)
    if controller.qualities.contains("160p") {
        await controller.changeQuality("160p")
        #expect(controller.quality == "160p")
        #expect(controller.player.rate == 0) // Quality changes preserve deliberate pause.
        #expect(ObjectIdentifier(controller.player) == playerID)
    }
    await controller.stop()
}

@Test @MainActor func playbackRecoveryExcludesPreviouslyFailedServersAndHonorsDisable() async throws {
    let transport = ProxyFixture(), manager = fixtureManager(transport)
    let primary = StreamingSource(name: "Primary", baseURL: URL(string: "https://primary.example")!)
    let backup = StreamingSource(name: "Backup", baseURL: URL(string: "https://backup.example")!)
    try manager.upsert(primary); try manager.upsert(backup)
    let resolver = PlaybackFallbackCoordinator(sources: manager, proxy: .init(transport: transport))
    let result = try await resolver.resolve(.init(channelLogin: "channel"), configuration: proxyConfiguration(), excluding: [primary.id, backup.id])
    if case .proxy = result {} else { Issue.record("Expected direct proxy after failed source items") }
    #expect(await transport.requests.allSatisfy { ["proxy.example", "media.example"].contains($0.url?.host ?? "") })
    let player = PlaybackController()
    player.resolvePlayback = { _, _, _ in throw URLError(.cannotConnectToHost) }
    player.recoveryEnabled = { false }
    await player.start(request: .init(channelLogin: "channel"))
    #expect(player.state == .failed); #expect(player.failureIsRetryable)
    await player.stop()
    try await Task.sleep(for: .milliseconds(20))
    #expect(player.state == .idle)
}

@Test @MainActor func stopWhileProxyIsResolvingCannotInstallMedia() async throws {
    let transport = GatedProxy(), resolver = PlaybackFallbackCoordinator(sources: fixtureManager(ProxyFixture()), proxy: .init(transport: transport))
    let player = PlaybackController()
    player.resolvePlayback = { request, _, _ in try await resolver.resolve(request, configuration: proxyConfiguration()) }
    let task = Task { await player.start(request: .init(channelLogin: "channel")) }
    while !(await transport.started) { await Task.yield() }
    await player.stop(); await transport.release(); await task.value
    #expect(player.state == .idle); #expect(player.player.currentItem == nil); #expect(!player.hasMedia)
}

@Test @MainActor func automaticRecoveryBudgetTerminatesAndStopCancelsRetry() async throws {
    let player = PlaybackController()
    var calls = 0
    player.resolvePlayback = { _, _, _ in calls += 1; throw URLError(.cannotConnectToHost) }
    player.recoveryLimit = { 1 }
    await player.start(request: .init(channelLogin: "channel"))
    let deadline = ContinuousClock.now + .seconds(5)
    while calls < 2, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(50))
    }
    #expect(calls == 2)
    try await Task.sleep(for: .milliseconds(1100))
    #expect(calls == 2)
    await player.start(request: .init(channelLogin: "channel"))
    await player.stop()
    let stoppedCalls = calls
    try await Task.sleep(for: .milliseconds(1100))
    #expect(calls == stoppedCalls); #expect(player.state == .idle)
}

@Test @MainActor func authenticationProbeFailuresCannotBeMistakenForInfrastructureFailure() async throws {
    let transport = FixtureTransport(["{}"], statuses: [401])
    let client = try StreamingSourceClient(source: .init(name: "Auth", baseURL: URL(string: "https://source.example")!), transport: transport)
    await #expect(throws: ClientError.unauthorized) { try await client.probe() }
    #expect(!PlaybackFailurePolicy.canRecover(ClientError.unauthorized))
    #expect(!PlaybackFailurePolicy.canRecover(ClientError.missingScope))
    #expect(!PlaybackFailurePolicy.canRecover(CancellationError()))
    #expect(!PlaybackFailurePolicy.canRecover(URLError(.cancelled)))
}

@Test(arguments: ["https://127.0.0.1/live/{channel}", "https://192.168.1.1/live/{channel}", "https://[::1]/live/{channel}", "https://host.local/live/{channel}"])
func privateProxyAddressesRequireExplicitTrust(_ address: String) throws {
    var config = proxyConfiguration(address)
    #expect(throws: ProxyError.unsafeURL) { try ProxyEndpoint(configuration: config).url(channel: "channel") }
    config.allowLocalHTTP = true
    #expect(try ProxyEndpoint(configuration: config).url(channel: "channel").scheme == "https")
}

@Test @MainActor func runtimeServerErrorsRecoverThroughEveryBackupThenStopAtProxyError() async throws {
    let transport = ProxyFixture(), manager = fixtureManager(transport)
    for host in ["primary", "backup", "third"] {
        try manager.upsert(.init(name: host, baseURL: URL(string: "https://\(host).example")!))
    }
    await transport.setSessionState("server_error")
    await transport.setProxy(broken: true)
    let resolver = PlaybackFallbackCoordinator(sources: manager, proxy: .init(transport: transport))
    let controller = PlaybackController(), player = controller.player
    controller.player.isMuted = true; controller.player.volume = 0.25
    controller.recoveryLimit = { 4 }
    controller.resolvePlayback = { request, excluded, attempted in
        try await resolver.resolve(request, configuration: proxyConfiguration(), excluding: excluded, proxyAttempted: attempted)
    }
    await controller.start(request: .init(channelLogin: "channel"))
    for _ in 0..<80 {
        if controller.error == ProxyError.invalidPlaylist.localizedDescription { break }
        try await Task.sleep(for: .milliseconds(100))
    }
    #expect(controller.error == ProxyError.invalidPlaylist.localizedDescription)
    #expect(controller.state == .failed); #expect(!controller.failureIsRetryable)
    #expect(controller.player === player); #expect(controller.player.isMuted); #expect(controller.player.volume == 0.25)
    let calls = await transport.requests
    #expect(calls.filter { $0.httpMethod == "POST" }.compactMap { $0.url?.host } == ["primary.example", "backup.example", "third.example"])
    #expect(calls.filter { $0.url?.host == "proxy.example" }.count == 1)
    await controller.stop()
}

private actor RedirectFixture: HTTPTransport {
    var requests: [URLRequest] = []
    let loop: Bool
    init(loop: Bool) { self.loop = loop }
    func send(_ request: URLRequest) async throws -> HTTPResult {
        requests.append(request)
        if loop || request.url?.host == "proxy.example" {
            return .init(data: Data(), status: 302, headers: ["location": "https://redirect.example/playlist?sig=short-lived"])
        }
        return .init(data: Data(variant.utf8), status: 200)
    }
}
@Test func safeProxyRedirectsUseFreshUnauthenticatedRequestsAndLoopsAreBounded() async throws {
    let transport = RedirectFixture(loop: false)
    let media = try await ProxyPlaybackProvider(transport: transport).resolve(configuration: proxyConfiguration(), request: .init(channelLogin: "channel"))
    #expect(media.url.query == "sig=short-lived") // Media signatures are allowed transiently, never in settings.
    #expect(await transport.requests.count == 2)
    #expect(await transport.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil && $0.value(forHTTPHeaderField: "Cookie") == nil })
    let loop = RedirectFixture(loop: true)
    await #expect(throws: ProxyError.unsafeURL) { try await ProxyPlaybackProvider(transport: loop).resolve(configuration: proxyConfiguration(), request: .init(channelLogin: "channel")) }
    #expect(await loop.requests.count == 4)
}

@Test @MainActor func explicitSourceOrderCanPutProxyBeforeServers() async throws {
    let transport = ProxyFixture(), manager = fixtureManager(transport)
    var configuration = proxyConfiguration(); configuration.contract = .automatic; configuration.address = "proxy.example"
    let proxy = try StreamingSource.proxy(name: "My proxy", configuration: configuration)
    let server = StreamingSource(name: "Server", baseURL: URL(string: "https://server.example")!)
    try manager.upsert(proxy); try manager.upsert(server)
    let resolver = PlaybackFallbackCoordinator(sources: manager, proxy: .init(transport: transport))
    let first = try await resolver.resolveOrdered(.init(channelLogin: "bastighg"))
    #expect(first.sourceID == proxy.id)
    #expect(await transport.requests.allSatisfy { ["proxy.example", "media.example"].contains($0.url?.host ?? "") })
    await transport.setProxy(status: 503)
    let fallback = try await resolver.resolveOrdered(.init(channelLogin: "bastighg"))
    #expect(fallback.sourceID == server.id)
    #expect(await transport.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil })
    #expect(throws: (any Error).self) { try manager.client(for: proxy) }
}

@Test @MainActor func orderedSourcesPersistKindsAndPrivateCloudOrderTogether() async throws {
    let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let transport = FixtureCloud(), keysA = MemorySecrets(), keysB = MemorySecrets()
    let a = StreamingSourceManager(url: directory.appendingPathComponent("a/sources.json"), secrets: keysA)
    let b = StreamingSourceManager(url: directory.appendingPathComponent("b/sources.json"), secrets: keysB)
    let personalA = PersonalStore(url: directory.appendingPathComponent("a/personal.json")), personalB = PersonalStore(url: directory.appendingPathComponent("b/personal.json"))
    let cloudA = CloudSyncStore(transport: transport, file: directory.appendingPathComponent("a/sealed"), secrets: keysA)
    let cloudB = CloudSyncStore(transport: transport, file: directory.appendingPathComponent("b/sealed"), secrets: keysB)
    let syncA = AppDataSync(personal: personalA, sources: a, cloud: cloudA), syncB = AppDataSync(personal: personalB, sources: b, cloud: cloudB)
    try syncA.start(); try syncB.start()
    let server = StreamingSource(name: "Server", baseURL: URL(string: "https://server.example")!, usesAuthentication: true)
    let proxy = try StreamingSource.proxy(name: "Proxy", configuration: proxyConfiguration())
    try a.upsert(server, credential: "server-private-token"); try a.upsert(proxy)
    try a.move(proxy.id, by: -1)
    await syncA.sync(); await syncB.sync()
    #expect(b.sources.map(\.id) == [proxy.id, server.id])
    #expect(b.sources.map(\.playbackKind) == [.twitchProxy, .twitchyServer])
    #expect(b.activeID == proxy.id)
    #expect(try b.credential(for: server.id) == "server-private-token")
    #expect(try b.credential(for: proxy.id) == nil)
    let restored = StreamingSourceManager(url: directory.appendingPathComponent("b/sources.json"), secrets: keysB)
    #expect(restored.sources == b.sources)
    try b.move(server.id, by: -1); await syncB.sync(); await syncA.sync()
    #expect(a.sources.map(\.id) == [server.id, proxy.id])
    let sealed = try Data(contentsOf: directory.appendingPathComponent("a/sealed"))
    #expect(!String(decoding: sealed, as: UTF8.self).contains("server-private-token"))
}

@Test @MainActor func legacySourcesMigrateSelectedServerToTopWithoutLosingCredentials() throws {
    let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let first = StreamingSource(name: "First", baseURL: URL(string: "https://first.example")!)
    let preferred = StreamingSource(name: "Preferred", baseURL: URL(string: "https://preferred.example")!, usesAuthentication: true)
    let sourceObjects = try [first,preferred].map { source -> [String: Any] in
        var value = try JSONSerialization.jsonObject(with: JSONEncoder().encode(source)) as! [String: Any]
        value.removeValue(forKey: "kind"); value.removeValue(forKey: "proxyConfiguration"); return value
    }
    let file = directory.appendingPathComponent("sources.json")
    try JSONSerialization.data(withJSONObject: ["sources":sourceObjects,"activeID":preferred.id.uuidString]).write(to: file)
    let keys = MemorySecrets(); try keys.write(Data("legacy-secret".utf8), key: preferred.id.uuidString)
    let manager = StreamingSourceManager(url: file, secrets: keys)
    #expect(manager.sources.map(\.id) == [preferred.id,first.id]); #expect(manager.sources.allSatisfy { $0.playbackKind == .twitchyServer })
    #expect(try manager.client().source.id == preferred.id)
}

@Test func automaticProxyContractsAcceptBaseURLsAndTemplatesWithoutGuessingForwardProxies() throws {
    var configuration = proxyConfiguration(); configuration.contract = .automatic; configuration.address = "proxy.example/prefix"
    #expect(try ProxyEndpoint(configuration: configuration).url(channel: "BastiGHG").absoluteString == "https://proxy.example/prefix/live/bastighg?allow_source=true&allow_audio_only=true")
    configuration.address = "https://proxy.example/hls?channel={channel}&mode=live"
    #expect(try ProxyEndpoint(configuration: configuration).url(channel: "bastighg").query == "channel=bastighg&mode=live")
    configuration.address = "socks5://proxy.example:1080"
    #expect(throws: (any Error).self) { try ProxyEndpoint(configuration: configuration).url(channel: "bastighg") }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["TWITCHY_LIVE_ORDERED_PROXY"] != nil))
@MainActor func liveOrderedProxyNativeIntegration() async throws {
    var configuration = StreamingProxyConfiguration()
    configuration.name = "Explicit test proxy"; configuration.contract = .automatic
    configuration.address = try #require(ProcessInfo.processInfo.environment["TWITCHY_LIVE_ORDERED_PROXY"])
    let login = try #require(ProcessInfo.processInfo.environment["TWITCHY_LIVE_PROXY_CHANNEL"])
    let manager = fixtureManager(ProxyFixture()), source = try StreamingSource.proxy(name: configuration.name, configuration: configuration)
    try manager.upsert(source)
    let resolver = PlaybackFallbackCoordinator(sources: manager), controller = PlaybackController()
    controller.resolvePlayback = { request, excluded, _ in try await resolver.resolveOrdered(request, excluding: excluded) }
    controller.player.isMuted = true
    await controller.start(request: .init(channelLogin: login))
    var played = false
    for _ in 0..<40 {
        try await Task.sleep(for: .milliseconds(500))
        if controller.state == .playing && controller.player.currentTime().seconds > 1 { played = true; break }
        if controller.state == .failed { break }
    }
    #expect(played); #expect(controller.activeSourceID == source.id); #expect(controller.usingProxy)
    await controller.stop()
}

@Test @MainActor func failedSourceContextSurvivesProxyStartupSoRecoveryContinuesForward() async throws {
    let transport = ProxyFixture(), manager = fixtureManager(transport)
    let first = StreamingSource(name: "First", baseURL: URL(string: "https://first.example")!)
    let second = StreamingSource(name: "Second", baseURL: URL(string: "https://second.example")!)
    let proxy = try StreamingSource.proxy(name: "Proxy", configuration: proxyConfiguration())
    try manager.upsert(first); try manager.upsert(second); try manager.upsert(proxy)
    await transport.fail(["first.example","second.example"])
    let resolver = PlaybackFallbackCoordinator(sources: manager, proxy: .init(transport: transport))
    let resolved = try await resolver.resolveOrdered(.init(channelLogin: "bastighg"))
    #expect(resolved.sourceID == proxy.id); #expect(resolved.failedSourceIDs == [first.id,second.id])
    let count = await transport.requests.count
    await #expect(throws: (any Error).self) {
        try await resolver.resolveOrdered(.init(channelLogin: "bastighg"), excluding: resolved.failedSourceIDs.union([proxy.id]))
    }
    #expect(await transport.requests.count == count) // No repeated failed-server probes.
    // Runtime context must not enter the Source API JSON contract.
    let client = try StreamingSourceClient(source: first, transport: ProxyFixture())
    var session = try await client.createSession(.init(channelLogin: "bastighg"))
    session.priorFailedSourceIDs = [second.id]
    #expect(!String(decoding: try JSONCoding.encoder().encode(session), as: UTF8.self).contains(second.id.uuidString))
}

private struct NoSourceSecretAccess: SecretStore {
    func read(_ key: String) throws -> Data? { throw ClientError.message("Unexpected source credential read") }
    func write(_ data: Data, key: String) throws { throw ClientError.message("Unexpected source credential write") }
    func delete(_ key: String) throws { throw ClientError.message("Unexpected source credential deletion") }
}
@Test @MainActor func publicProvidersNeverNeedOrTouchSourceKeychain() throws {
    let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let manager = StreamingSourceManager(url: directory.appendingPathComponent("sources.json"), secrets: NoSourceSecretAccess())
    let proxy = try StreamingSource.proxy(name: "Proxy", configuration: proxyConfiguration())
    try manager.upsert(proxy)
    #expect(try manager.credential(for: proxy.id) == nil)
    try manager.remove(proxy.id)
    let publicServer = StreamingSource(name: "Public server", baseURL: URL(string: "https://public.example")!)
    try manager.upsert(publicServer)
    #expect(try manager.client(for: publicServer).source.id == publicServer.id)
}

@Test @MainActor func removedEmbedDoesNotReplaceOrBlockSavedSources() async throws {
    let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("sources.json")
    var removed = StreamingSource(name: "Old embed", baseURL: URL(string: "https://embed.example")!)
    removed.kind = .removedEmbed
    let proxy = try StreamingSource.proxy(name: "Proxy", configuration: proxyConfiguration())
    let server = StreamingSource(name: "Server", baseURL: URL(string: "https://server.example")!)
    let entries = try JSONSerialization.jsonObject(with: JSONEncoder().encode([proxy, removed, server]))
    try JSONSerialization.data(withJSONObject: ["sources": entries, "activeID": removed.id.uuidString, "ordered": true]).write(to: url)
    let manager = StreamingSourceManager(url: url, secrets: NoSourceSecretAccess())
    #expect(manager.sources == [proxy, server])
    #expect(manager.activeID == proxy.id)
    #expect(throws: ClientError.unsupported) { try manager.upsert(removed) }

    let transport = FixtureCloud()
    let remote = CloudSyncStore(transport: transport, file: directory.appendingPathComponent("remote"), secrets: MemorySecrets())
    remote.put("source/" + removed.id.uuidString, payload: try JSONEncoder().encode(["source": removed]))
    remote.put("activeSource", payload: try JSONEncoder().encode(removed.id))
    remote.put("sourceOrder", payload: try JSONEncoder().encode([removed.id, server.id, proxy.id]))
    await remote.sync()

    let local = CloudSyncStore(transport: transport, file: directory.appendingPathComponent("local"), secrets: MemorySecrets())
    let personal = PersonalStore(url: directory.appendingPathComponent("personal.json"))
    let sync = AppDataSync(personal: personal, sources: manager, cloud: local)
    await sync.sync()
    #expect(local.status == "Up to date")
    #expect(manager.sources == [server, proxy])
    #expect(manager.activeID == server.id)
}
