import Foundation
import Testing
import AVFoundation
import TwitchyCore
import TwitchySources
@testable import TwitchyPlayback
private var mockURL: URL? { ProcessInfo.processInfo.environment["TWITCHY_MOCK_URL"].flatMap(URL.init(string:)) }
private func fixtureClient() throws -> StreamingSourceClient {
    try StreamingSourceClient(source: .init(name: "Explicit test fixture", baseURL: #require(mockURL), allowLocalHTTP: true))
}
@Test(.enabled(if: mockURL != nil, "Run with TWITCHY_MOCK_URL and the localhost mock server"))
func mockDiscoverySessionAndCleanup() async throws {
    let client = try fixtureClient()
    #expect(try await client.health().serverVersion == "mock-1.0.0")
    #expect(try await client.capabilities().qualitySelection)
    let session = try await client.createSession(.init(channelLogin: "fixture"))
    #expect(session.qualities == ["auto", "360p"])
    try await client.endSession(session.sessionId)
}
@Test(.enabled(if: mockURL != nil, "Run with TWITCHY_MOCK_URL and the localhost mock server"))
func mockDownloadRightsAndFile() async throws {
    let client = try fixtureClient()
    await #expect(throws: SourceAPIError.self) { try await client.createDownload(contentType: "vod", contentID: "fixture", authorizationReference: "invalid") }
    let job = try await client.createDownload(contentType: "vod", contentID: "fixture", authorizationReference: "fixture-owner")
    #expect(job.status == .ready)
    let file = try await HTTPClient().response(client.downloadFileRequest(job.id))
    #expect(file.data.count > 10_000); #expect(String(decoding: file.data[4..<8], as: UTF8.self) == "ftyp")
    try await client.cancelDownload(job.id)
}
@Test(.enabled(if: mockURL != nil, "Run with TWITCHY_MOCK_URL and the localhost mock server")) @MainActor
func mockNativeHLSPlaybackAndStop() async throws {
    let controller = PlaybackController()
    await controller.start(client: try fixtureClient(), request: .init(channelLogin: "fixture"))
    for _ in 0..<40 {
        if controller.player.currentItem?.status == .readyToPlay { break }
        try await Task.sleep(for: .milliseconds(250))
    }
    #expect(controller.player.currentItem?.status == .readyToPlay)
    #expect(controller.session?.sessionId == "fixture-session")
    await controller.stop(); #expect(controller.player.currentItem == nil)
}
@Test(.enabled(if: mockURL != nil, "Run with TWITCHY_MOCK_URL and the localhost mock server"), arguments: ["clip", "vod"]) @MainActor
func mockDownloadTransferPersistenceAndDelete(type: String) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let manager = DownloadManager(directory: directory)
    await manager.enqueue(client: try fixtureClient(), type: type, contentID: "fixture", permission: "fixture-owner", metadata: .init(title: "Fixture video", channel: "Fixture channel", duration: "0:06"))
    for _ in 0..<40 { if manager.items.first?.job.status == .completed { break }; try await Task.sleep(for: .milliseconds(100)) }
    let item = try #require(manager.items.first)
    #expect(item.job.status == .completed)
    #expect(FileManager.default.fileExists(atPath: try #require(manager.file(for: item)).path))
    for _ in 0..<40 {
        if let current = manager.items.first, manager.thumbnailFile(for: current) != nil { break }
        try await Task.sleep(for: .milliseconds(100))
    }
    let withArtwork = try #require(manager.items.first)
    #expect(manager.thumbnailFile(for: withArtwork) != nil)
    let restored = DownloadManager(directory: directory); #expect(restored.items.first?.job.status == .completed)
    #expect(restored.items.first?.metadata?.title == "Fixture video")
    #expect(restored.thumbnailFile(for: withArtwork) != nil)
    let restoredItem = try #require(restored.items.first)
    let local = try #require(restored.file(for: restoredItem))
    if let fixture = ProcessInfo.processInfo.environment["TWITCHY_DELAY_MOOV_INTEGRATION"] {
        try await verifyDelayMoovMovie(local, audio: fixture != "video-only")
    }
    let controller = PlaybackController()
    controller.player.isMuted = true
    await controller.startOffline(url: local, type: type, contentID: "fixture", expectedDuration: 6)
    for _ in 0..<100 {
        if controller.player.currentTime().seconds >= 5.9 || controller.state == .failed { break }
        try await Task.sleep(for: .milliseconds(100))
    }
    #expect(controller.isOffline && controller.session == nil)
    #expect(controller.player.currentItem?.status == .readyToPlay && controller.player.currentTime().seconds >= 5.9)
    await controller.stop()
    try restored.delete(item.id); #expect(restored.items.isEmpty)
}

@Test(.enabled(if: mockURL != nil, "Run with TWITCHY_MOCK_URL and the localhost mock server")) @MainActor
func mockRetryFailedLocalTransfer() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let client = try fixtureClient()
    var item = LocalDownload(sourceID: client.source.id, job: try await client.createDownload(contentType: "vod", contentID: "fixture", authorizationReference: "fixture-owner"), contentType: "vod", contentID: "fixture", authorizationReference: "fixture-owner")
    item.job.status = .failed
    try JSONEncoder().encode([item]).write(to: directory.appendingPathComponent("index.json"))
    let manager = DownloadManager(directory: directory)
    manager.resume(item.id, client: client)
    for _ in 0..<40 { if manager.items.first?.job.status == .completed { break }; try await Task.sleep(for: .milliseconds(100)) }
    #expect(manager.items.first?.job.status == .completed)
    #expect(manager.storageBytes > 10_000)
}
