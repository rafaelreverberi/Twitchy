import Foundation
import AVFoundation
import Testing
@testable import TwitchyPlayback

@Test func fragmentedOfflineMovieIndexesEveryFragmentAndTrack() async throws {
    let source = try #require(Bundle.module.url(forResource: "fragmented-8s", withExtension: "mp4", subdirectory: "Fixtures"))
    let url = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
    defer { try? FileManager.default.removeItem(at: url) }
    try FileManager.default.copyItem(at: source, to: url)
    try await OfflineMP4.prepare(url)
    let asset = AVURLAsset(url: url)
    #expect(try await asset.load(.duration).seconds >= 7.9)
    #expect(try await asset.loadTracks(withMediaType: .video).count == 1)
    #expect(try await asset.loadTracks(withMediaType: .audio).count == 1)
    let generator = AVAssetImageGenerator(asset: asset)
    generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
    let frame = try await generator.image(at: CMTime(seconds: 7, preferredTimescale: 600))
    #expect(frame.actualTime.seconds > 6.5)
    let size = try Data(contentsOf: url).count
    try await OfflineMP4.prepare(url)
    #expect(try Data(contentsOf: url).count == size, "An indexed file must not be rewritten again")
}
@Test func truncatedFragmentedDownloadPreservesTheOriginalForRetry() async throws {
    let source = try #require(Bundle.module.url(forResource: "fragmented-8s", withExtension: "mp4", subdirectory: "Fixtures"))
    let data = try Data(contentsOf: source).dropLast(4096)
    let url = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
    defer { try? FileManager.default.removeItem(at: url) }
    try data.write(to: url)
    await #expect(throws: (any Error).self) { try await OfflineMP4.prepare(url) }
    #expect(try Data(contentsOf: url) == data)
}
@Test(.enabled(if: ProcessInfo.processInfo.environment["TWITCHY_OFFLINE_REGRESSION_FILE"] != nil))
func recordedClipRegressionIncludesTheLastFrame() async throws {
    let source = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["TWITCHY_OFFLINE_REGRESSION_FILE"]))
    let url = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
    defer { try? FileManager.default.removeItem(at: url) }
    try FileManager.default.copyItem(at: source, to: url)
    try await OfflineMP4.prepare(url)
    let asset = AVURLAsset(url: url)
    #expect(try await asset.load(.duration).seconds > 59)
    let frame = try await AVAssetImageGenerator(asset: asset).image(at: CMTime(seconds: 55, preferredTimescale: 600))
    #expect(frame.actualTime.seconds > 54)
}

@Test func downloadDurationRejectsAnIncompleteButPlayableFile() async throws {
    let source = try #require(Bundle.module.url(forResource: "fragmented-8s", withExtension: "mp4", subdirectory: "Fixtures"))
    let url = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
    defer { try? FileManager.default.removeItem(at: url) }
    try FileManager.default.copyItem(at: source, to: url)
    await #expect(throws: (any Error).self) { try await OfflineMP4.prepare(url, expectedDuration: 60) }
    #expect(DownloadMetadata(title: "Clip", duration: "1:00").expectedDuration == 60)
    #expect(DownloadMetadata(title: "Video", duration: "1h24m5s").expectedDuration == 5045)
}

@Test @MainActor func offlineRetryKeepsTheCompletenessCheck() async throws {
    let source = try #require(Bundle.module.url(forResource: "fragmented-8s", withExtension: "mp4", subdirectory: "Fixtures"))
    let url = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
    defer { try? FileManager.default.removeItem(at: url) }
    try FileManager.default.copyItem(at: source, to: url)
    let controller = PlaybackController()
    await controller.startOffline(url: url, type: "clip", contentID: "fixture", expectedDuration: 60)
    #expect(controller.state == .failed && controller.player.currentItem == nil)
    await controller.retry()
    #expect(controller.state == .failed && controller.player.currentItem == nil)
    await controller.stop()
}
