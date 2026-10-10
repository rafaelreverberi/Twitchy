import Foundation
import Testing
import AVFoundation
import TwitchySources
@testable import TwitchyPlayback

private var recordedTokenFile: String? { ProcessInfo.processInfo.environment["TWITCHY_RECORDED_TOKEN_FILE"] }
@Test(.enabled(if: recordedTokenFile != nil, "Opt-in integration against the local recorded source")) @MainActor
func recordedClientDownloadAndOfflinePlayback() async throws {
    let tokens = try JSONDecoder().decode([String:String].self, from: Data(contentsOf: URL(fileURLWithPath: #require(recordedTokenFile))))
    let client = try StreamingSourceClient(source: .init(name: "Recorded integration", baseURL: URL(string: "http://localhost:8080")!, allowLocalHTTP: true, usesAuthentication: true), authentication: .bearer(#require(tokens.values.first)))
    let capabilities = try await client.capabilities()
    #expect(capabilities.vod && capabilities.clips && capabilities.clientSideDownloads == true)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let manager = DownloadManager(directory: directory)
    await manager.enqueue(client: client, type: "clip", contentID: ProcessInfo.processInfo.environment["TWITCHY_RECORDED_CLIP_ID"] ?? "EndearingHonestTriangleStrawBeary-WVupXff47gjWlcJQ", quality: ProcessInfo.processInfo.environment["TWITCHY_RECORDED_QUALITY"] ?? "360p30")
    for _ in 0..<120 { if let status = manager.items.first?.job.status, status == .completed || status == .failed { break }; try await Task.sleep(for: .seconds(1)) }
    let item = try #require(manager.items.first)
    #expect(item.job.status == .completed)
    let file = try #require(manager.file(for: item))
    let player = AVPlayer(url: file); player.isMuted = true; player.play()
    for _ in 0..<20 { if player.currentTime().seconds >= 2 || player.status == .failed { break }; try await Task.sleep(for: .seconds(1)) }
    #expect(player.status == .readyToPlay && player.currentTime().seconds >= 2)
    player.pause(); player.replaceCurrentItem(with: nil)
    let restored = DownloadManager(directory: directory)
    #expect(restored.items.first?.job.status == .completed)
    try await client.cancelDownload(item.job.id)
    try restored.delete(item.id)
    #expect(restored.items.isEmpty)
    // A restored failed transfer may outlive the source's metadata job TTL.
    var expired = item
    expired.localFilename = nil
    expired.job.status = .failed
    expired.job.id = "expired-" + UUID().uuidString
    try JSONEncoder().encode([expired]).write(to: directory.appendingPathComponent("index.json"))
    let retried = DownloadManager(directory: directory)
    retried.resume(expired.id, client: client)
    for _ in 0..<120 { if let status = retried.items.first?.job.status, status == .completed { break }; try await Task.sleep(for: .seconds(1)) }
    let retryItem = try #require(retried.items.first)
    #expect(retryItem.job.status == .completed && retryItem.job.id != expired.job.id)
    try await client.cancelDownload(retryItem.job.id)
    try retried.delete(retryItem.id)
}
