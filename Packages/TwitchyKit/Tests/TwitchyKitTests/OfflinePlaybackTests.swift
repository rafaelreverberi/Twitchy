import Foundation
import AVFoundation
import Testing
import AudioToolbox
import CoreMedia
@testable import TwitchyPlayback

@Test(arguments: ["clip-audio-true", "vod-audio-true", "clip-audio-false", "vod-audio-false"])
func delayMoovServerDownloadIsIndexed(name: String) async throws {
    let source = try #require(Bundle.module.url(forResource: name, withExtension: "mp4", subdirectory: "Fixtures"))
    let url = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
    defer { try? FileManager.default.removeItem(at: url) }
    try FileManager.default.copyItem(at: source, to: url)
    try await OfflineMP4.prepare(url, expectedDuration: 6)
    try await verifyDelayMoovMovie(url, audio: name.hasSuffix("true"))
    let indexed = try Data(contentsOf: url)
    try await OfflineMP4.prepare(url, expectedDuration: 6)
    #expect(try Data(contentsOf: url) == indexed)
    if let output = ProcessInfo.processInfo.environment["TWITCHY_INDEXED_FIXTURE_DIR"] {
        try indexed.write(to: URL(fileURLWithPath: output).appendingPathComponent(name + ".mp4"))
    }
}

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

// Decode both complete tracks after indexing; merely finding AAC metadata is insufficient.
@discardableResult
@MainActor
func verifyDelayMoovMovie(_ url: URL, audio expectsAudio: Bool) async throws -> Int {
    let asset = AVURLAsset(url: url)
    let duration = try await asset.load(.duration).seconds
    #expect(duration >= 6.08 && duration <= 6.10)
    let video = try #require(try await asset.loadTracks(withMediaType: .video).first)
    let audio = try await asset.loadTracks(withMediaType: .audio)
    #expect(audio.count == (expectsAudio ? 1 : 0))
    let videoReader = try AVAssetReader(asset: asset)
    let videoOutput = AVAssetReaderTrackOutput(track: video, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    videoReader.add(videoOutput)
    #expect(videoReader.startReading())
    var frames = 0; var firstVideo = Double.infinity; var lastVideo = 0.0
    while let sample = videoOutput.copyNextSampleBuffer() {
        guard CMSampleBufferGetImageBuffer(sample) != nil else { continue }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
        firstVideo = min(firstVideo, pts); lastVideo = max(lastVideo, pts); frames += 1
    }
    // AVFoundation fills the 80 ms empty edit with an initial image at zero.
    #expect(videoReader.status == .completed && frames == 151)
    #expect(firstVideo == 0 && lastVideo >= 6.039)
    let generator = AVAssetImageGenerator(asset: asset)
    generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
    let frame = try await generator.image(at: CMTime(seconds: 6.04, preferredTimescale: 90000))
    #expect(frame.actualTime.seconds >= 6.0)
    guard expectsAudio else { return 0 }
    let track = try #require(audio.first)
    let descriptions = try await track.load(.formatDescriptions)
    let format = try #require(descriptions.first)
    let asbd = try #require(CMAudioFormatDescriptionGetStreamBasicDescription(format))
    #expect(asbd.pointee.mFormatID == kAudioFormatMPEG4AAC && asbd.pointee.mSampleRate == 48000 && asbd.pointee.mChannelsPerFrame == 2)
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
        AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false
    ])
    reader.add(output); #expect(reader.startReading())
    var energy = [Double](repeating: 0, count: 7), counts = [Int](repeating: 0, count: 7)
    var samples = 0; var firstAudio = Double.infinity; var end = 0.0
    while let sample = output.copyNextSampleBuffer() {
        let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
        let n = CMSampleBufferGetNumSamples(sample)
        samples += n; firstAudio = min(firstAudio, pts); end = max(end, pts + Double(n) / 48000)
        let block = try #require(CMSampleBufferGetDataBuffer(sample))
        let bytes = CMBlockBufferGetDataLength(block)
        var values = [Float](repeating: 0, count: bytes / 4)
        let status = values.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes, destination: $0.baseAddress!) }
        #expect(status == kCMBlockBufferNoErr && values.count == n * 2)
        for (i, value) in values.enumerated() {
            let second = min(6, max(0, Int(pts + Double(i / 2) / 48000)))
            energy[second] += Double(value) * Double(value); counts[second] += 1
        }
    }
    #expect(reader.status == .completed && samples >= 283200 && samples <= 297600)
    #expect(firstAudio == 0 && end >= 6.0 && abs(end - (lastVideo + 0.04)) < 0.05)
    for second in 0..<6 {
        let rms = sqrt(energy[second] / Double(max(1, counts[second])))
        #expect(counts[second] > 0 && rms > 0.02 && rms < 0.2)
    }
    print("Indexed fixture: duration=\(duration), video=\(frames) [\(firstVideo), \(lastVideo)], audio=\(samples) [\(firstAudio), \(end)], tone in all six seconds")
    return samples
}

@Test(arguments: ["clip-audio-true", "vod-audio-true", "clip-audio-false", "vod-audio-false"])
func truncatedDelayMoovDownloadKeepsOriginal(name: String) async throws {
    let source = try #require(Bundle.module.url(forResource: name, withExtension: "mp4", subdirectory: "Fixtures"))
    let original = try Data(contentsOf: source).dropLast(4096)
    let url = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
    defer { try? FileManager.default.removeItem(at: url) }
    try original.write(to: url)
    await #expect(throws: (any Error).self) { try await OfflineMP4.prepare(url, expectedDuration: 6) }
    #expect(try Data(contentsOf: url) == original)
}

private func bigEndian<T: FixedWidthInteger>(_ value: T) -> Data {
    var v = value.bigEndian
    return withUnsafeBytes(of: &v) { Data($0) }
}
private func fixtureBoxPayload(_ data: Data, type: String, after: Int = 0) throws -> Int {
    let range = try #require(data.range(of: Data(type.utf8), in: after..<data.count))
    return range.upperBound
}
@Test(arguments: ["duration", "offset", "tfdt", "edit-rate"])
func rejectedDelayMoovReplacementPreservesOriginal(reason: String) async throws {
    let source = try #require(Bundle.module.url(forResource: "clip-audio-true", withExtension: "mp4", subdirectory: "Fixtures"))
    var original = try Data(contentsOf: source)
    if reason == "offset" {
        let p = try fixtureBoxPayload(original, type: "trun")
        original.replaceSubrange(p+8..<p+12, with: bigEndian(UInt32(0)))
    } else if reason == "tfdt" {
        let first = try fixtureBoxPayload(original, type: "tfdt")
        let second = try fixtureBoxPayload(original, type: "tfdt", after: first)
        original.replaceSubrange(second+4..<second+12, with: bigEndian(UInt64(1)))
    } else if reason == "edit-rate" {
        let p = try fixtureBoxPayload(original, type: "elst")
        original.replaceSubrange(p+16..<p+20, with: bigEndian(UInt32(0x00020000)))
    }
    let url = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
    defer { try? FileManager.default.removeItem(at: url) }
    try original.write(to: url)
    await #expect(throws: (any Error).self) { try await OfflineMP4.prepare(url, expectedDuration: reason == "duration" ? 30 : 6) }
    #expect(try Data(contentsOf: url) == original)
}

@Test(arguments: [false, true])
func editListUsesMovieScaleAndPreservesFiniteEdits(finite: Bool) async throws {
    let source = try #require(Bundle.module.url(forResource: "clip-audio-true", withExtension: "mp4", subdirectory: "Fixtures"))
    var data = try Data(contentsOf: source)
    let mvhd = try fixtureBoxPayload(data, type: "mvhd")
    data.replaceSubrange(mvhd+12..<mvhd+16, with: bigEndian(UInt32(2000)))
    var after = 0
    for (empty, segment) in [(UInt32(160), UInt32(12000)), (UInt32(116), UInt32(12075))] {
        let p = try fixtureBoxPayload(data, type: "elst", after: after); after = p
        data.replaceSubrange(p+8..<p+12, with: bigEndian(empty))
        if finite { data.replaceSubrange(p+20..<p+24, with: bigEndian(segment)) }
    }
    let url = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
    defer { try? FileManager.default.removeItem(at: url) }
    try data.write(to: url)
    try await OfflineMP4.prepare(url, expectedDuration: 6)
    try await verifyDelayMoovMovie(url, audio: true)
    let indexed = try Data(contentsOf: url)
    // The appended moov follows all original bytes. Its edit media_time/rate is unchanged.
    let p = try fixtureBoxPayload(indexed, type: "elst", after: data.count)
    #expect(indexed[p+12..<p+20] == data[(try fixtureBoxPayload(data, type: "elst"))+12..<(try fixtureBoxPayload(data, type: "elst"))+20])
    #expect(indexed[p+20..<p+24] == bigEndian(UInt32(12000)))
}

@Test func audioPrimingEditRemainsEffectiveAfterIndexing() async throws {
    let source = try #require(Bundle.module.url(forResource: "clip-audio-true", withExtension: "mp4", subdirectory: "Fixtures"))
    let original = try Data(contentsOf: source)
    let firstEdit = try fixtureBoxPayload(original, type: "elst")
    let audioEdit = try fixtureBoxPayload(original, type: "elst", after: firstEdit)
    let baselineURL = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
    let trimmedURL = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
    defer { try? FileManager.default.removeItem(at: baselineURL); try? FileManager.default.removeItem(at: trimmedURL) }
    try original.write(to: baselineURL)
    var trimmed = original
    // A one-AAC-frame media-time trim in 48 kHz track ticks, not movie ticks.
    trimmed.replaceSubrange(audioEdit+24..<audioEdit+28, with: bigEndian(UInt32(1024)))
    try trimmed.write(to: trimmedURL)
    try await OfflineMP4.prepare(baselineURL, expectedDuration: 6)
    try await OfflineMP4.prepare(trimmedURL, expectedDuration: 6)
    let baselineCount = try await verifyDelayMoovMovie(baselineURL, audio: true)
    let trimmedCount = try await verifyDelayMoovMovie(trimmedURL, audio: true)
    #expect(baselineCount - trimmedCount == 1024)
    let indexed = try Data(contentsOf: trimmedURL)
    let videoEdit = try fixtureBoxPayload(indexed, type: "elst", after: original.count)
    let savedEdit = try fixtureBoxPayload(indexed, type: "elst", after: videoEdit)
    #expect(indexed[savedEdit+24..<savedEdit+28] == bigEndian(UInt32(1024)))
}

// Promote the real fixture's edit lists to version 1 without changing media samples.
private func versionOneEdits(_ data: Data) throws -> Data {
    var p = 0; var result = Data()
    while p < data.count {
        let n = Int(data[p..<p+4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
        let type = String(decoding: data[p+4..<p+8], as: UTF8.self)
        var payload = Data(data[p+8..<p+n])
        if ["moov", "trak", "edts"].contains(type) { payload = try versionOneEdits(payload) }
        if type == "elst" {
            var wide = bigEndian(UInt32(0x01000000)) + bigEndian(UInt32(2))
            for at in [8, 20] {
                let duration = payload[at..<at+4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                let start = Int32(bitPattern: payload[at+4..<at+8].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
                wide += bigEndian(UInt64(duration)) + bigEndian(Int64(start)) + payload[at+8..<at+12]
            }
            payload = wide
        }
        result += bigEndian(UInt32(payload.count + 8)) + Data(type.utf8) + payload
        p += n
    }
    return result
}
@Test func versionOneEditListsPreserveTheServerTimeline() async throws {
    let source = try #require(Bundle.module.url(forResource: "clip-audio-true", withExtension: "mp4", subdirectory: "Fixtures"))
    let url = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
    defer { try? FileManager.default.removeItem(at: url) }
    try versionOneEdits(Data(contentsOf: source)).write(to: url)
    try await OfflineMP4.prepare(url, expectedDuration: 6)
    try await verifyDelayMoovMovie(url, audio: true)
}
