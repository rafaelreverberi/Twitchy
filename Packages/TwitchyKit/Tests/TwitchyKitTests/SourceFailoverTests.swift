import Foundation
import Testing
import TwitchyCore
@testable import TwitchySources
import TwitchyPlayback

private actor FailoverTransport: HTTPTransport {
    var unhealthy: Set<String> = []
    var sessionFailure: Set<String> = []
    var requests: [URLRequest] = []
    func setUnhealthy(_ hosts: Set<String>) { unhealthy = hosts }
    func setSessionFailure(_ hosts: Set<String>) { sessionFailure = hosts }
    func send(_ request: URLRequest) async throws -> HTTPResult {
        requests.append(request)
        let host = request.url!.host!, path = request.url!.path
        if path.hasSuffix("/health") {
            if unhealthy.contains(host) { throw URLError(.cannotConnectToHost) }
            return HTTPResult(data: Data(#"{"status":"ok","server_version":"fixture","api_version":"v1"}"#.utf8), status: 200)
        }
        if path.hasSuffix("/capabilities") { return HTTPResult(data: Data(capabilities.utf8), status: 200) }
        if request.httpMethod == "DELETE" { return HTTPResult(data: Data(), status: 204) }
        if sessionFailure.contains(host) {
            return HTTPResult(data: Data(#"{"error":{"code":"server_error","message":"fixture","retryable":true}}"#.utf8), status: 503)
        }
        // No real media requests are needed to verify session routing.
        return HTTPResult(data: Data(#"{"session_id":"fixture-session","hls_url":"https://media.example/test.m3u8","qualities":["auto"],"state":"unavailable"}"#.utf8), status: 200)
    }
}

@Test @MainActor func unavailablePrimaryUsesBackupWithoutChangingSavedPreference() async throws {
    let file = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("sources.json")
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let transport = FailoverTransport(), secrets = MemorySecrets()
    let manager = StreamingSourceManager(url: file, secrets: secrets, probeTransport: transport, playbackTransport: transport)
    let primary = StreamingSource(name: "Primary", baseURL: URL(string: "https://primary.example")!, usesAuthentication: true)
    let backup = StreamingSource(name: "Backup", baseURL: URL(string: "https://backup.example")!, usesAuthentication: true)
    try manager.upsert(primary, credential: "primary-test"); try manager.upsert(backup, credential: "backup-test")
    await transport.setUnhealthy(["primary.example"])
    let client = try await manager.readyClient(for: .init(channelLogin: "fixture"))
    #expect(client.source.id == backup.id); #expect(manager.activeID == primary.id); #expect(manager.active?.id == backup.id)
    let restored = StreamingSourceManager(url: file, secrets: secrets)
    #expect(restored.activeID == primary.id); #expect(restored.fallbackID == nil)
    let requests = await transport.requests
    #expect(requests.count == 2)
    #expect(requests.allSatisfy { $0.timeoutInterval == 3 && $0.url?.path == "/v1/health" })
    #expect(requests.first { $0.url?.host == "primary.example" }?.value(forHTTPHeaderField: "Authorization") == "Bearer primary-test")
    #expect(requests.first { $0.url?.host == "backup.example" }?.value(forHTTPHeaderField: "Authorization") == "Bearer backup-test")
    await transport.setUnhealthy([])
    await manager.refreshAvailability(force: true)
    #expect(manager.active?.id == backup.id) // Health checks alone don't bounce an ongoing stream.
    let recovered = try await manager.readyClient(for: .init(channelLogin: "next"))
    #expect(recovered.source.id == primary.id)
}

@Test @MainActor func disabledBackupsAreNeverProbedAndNoHealthyServerIsReported() async throws {
    let file = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("sources.json")
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let transport = FailoverTransport()
    let manager = StreamingSourceManager(url: file, secrets: MemorySecrets(), probeTransport: transport)
    let primary = StreamingSource(name: "Primary", baseURL: URL(string: "https://primary.example")!)
    var backup = StreamingSource(name: "Backup", baseURL: URL(string: "https://backup.example")!); backup.enabled = false
    try manager.upsert(primary); try manager.upsert(backup)
    await transport.setUnhealthy(["primary.example"])
    await #expect(throws: URLError.self) { try await manager.readyClient(for: .init(channelLogin: "fixture")) }
    #expect(await transport.requests.count == 1)
    #expect(manager.fallbackID == nil)
}

@Test @MainActor func playbackSessionErrorRoutesToBackupAndOfflineContentDoesNotLoop() async throws {
    let file = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("sources.json")
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let transport = FailoverTransport()
    let manager = StreamingSourceManager(url: file, secrets: MemorySecrets(), probeTransport: transport, playbackTransport: transport)
    let primary = StreamingSource(name: "Primary", baseURL: URL(string: "https://primary.example")!)
    let backup = StreamingSource(name: "Backup", baseURL: URL(string: "https://backup.example")!)
    try manager.upsert(primary); try manager.upsert(backup)
    await transport.setSessionFailure(["primary.example"])
    let controller = PlaybackController()
    controller.resolveClient = { request, failed in try await manager.readyClient(for: request, failedSourceID: failed) }
    await controller.start(client: try manager.client(), request: .init(contentType: "vod", contentId: "video-1", requestedQuality: "720p"))
    #expect(controller.state == .unavailable)
    #expect(manager.active?.id == backup.id); #expect(manager.activeID == primary.id)
    let posts = await transport.requests.filter { $0.httpMethod == "POST" }
    #expect(posts.map { $0.url!.host! } == ["primary.example", "backup.example"])
    #expect(posts.allSatisfy { String(decoding: $0.httpBody!, as: UTF8.self).contains("video-1") && String(decoding: $0.httpBody!, as: UTF8.self).contains("720p") })
    #expect(!PlaybackController.canRecover(ClientError.unauthorized))
    #expect(!PlaybackController.canRecover(ClientError.unsupported))
    #expect(!PlaybackController.canRecover(SourceAPIError(status: 404, problem: .init(code: "stream_unavailable", message: "offline", retryable: false))))
    await controller.stop()
}

@Test func probeDoesNotRetryServerErrors() async throws {
    let transport = FixtureTransport(["{}"], statuses: [503])
    let client = try StreamingSourceClient(source: .init(name: "Probe", baseURL: URL(string: "https://probe.example")!), transport: transport)
    await #expect(throws: ClientError.server(503)) { try await client.probe() }
    #expect(await transport.requests.count == 1)
}

private actor GatedProbeTransport: HTTPTransport {
    var calls = 0
    var gates: [CheckedContinuation<Void, Never>] = []
    var started: CheckedContinuation<Void, Never>?
    var released = false
    func waitUntilStarted() async {
        if calls == 2 { return }
        await withCheckedContinuation { started = $0 }
    }
    func release() { released = true; for gate in gates { gate.resume() }; gates = [] }
    func send(_ request: URLRequest) async throws -> HTTPResult {
        calls += 1
        if calls == 2 { started?.resume(); started = nil }
        if !released { await withCheckedContinuation { gates.append($0) } }
        return HTTPResult(data: Data(#"{"status":"ok","server_version":"fixture","api_version":"v1"}"#.utf8), status: 200)
    }
}

@Test @MainActor func concurrentProbesAreCoalescedAndManualSelectionRejectsStaleResults() async throws {
    let file = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("sources.json")
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let transport = GatedProbeTransport()
    let manager = StreamingSourceManager(url: file, secrets: MemorySecrets(), probeTransport: transport)
    let primary = StreamingSource(name: "Primary", baseURL: URL(string: "https://primary.example")!)
    let backup = StreamingSource(name: "Backup", baseURL: URL(string: "https://backup.example")!)
    try manager.upsert(primary); try manager.upsert(backup)
    let first = Task { await manager.refreshAvailability() }
    await transport.waitUntilStarted()
    var secondStarted = false
    let second = Task { secondStarted = true; await manager.refreshAvailability(force: true) }
    while !secondStarted { await Task.yield() }
    try manager.select(backup.id)
    await transport.release()
    await first.value; await second.value
    #expect(await transport.calls == 2)
    #expect(manager.activeID == backup.id); #expect(manager.fallbackID == nil)
    #expect(manager.availability.isEmpty)
    #expect(!manager.isChecking)
}
