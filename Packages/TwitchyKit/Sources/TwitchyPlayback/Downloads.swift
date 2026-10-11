import Foundation
import Observation
import TwitchyCore
import TwitchySources
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

public struct DownloadMetadata: Codable, Sendable {
    public var title: String
    public var channel: String?
    public var thumbnailURL: URL?
    public var duration: String?
    public var expectedDuration: Double? {
        guard let duration else { return nil }
        let parts = duration.split(separator: ":").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        if parts.count == 2 { return parts[0] * 60 + parts[1] }
        if parts.count == 3 { return parts[0] * 3600 + parts[1] * 60 + parts[2] }
        guard let regex = try? NSRegularExpression(pattern: "([0-9]+)\\s*([hms])") else { return nil }
        let matches = regex.matches(in: duration, range: NSRange(duration.startIndex..., in: duration))
        guard !matches.isEmpty else { return nil }
        return matches.reduce(0) { result, match in
            guard let amountRange = Range(match.range(at: 1), in: duration), let unitRange = Range(match.range(at: 2), in: duration), let amount = Double(duration[amountRange]) else { return result }
            let unit = duration[unitRange]; return result + amount * (unit == "h" ? 3600 : unit == "m" ? 60 : 1)
        }
    }
    public init(title: String, channel: String? = nil, thumbnailURL: URL? = nil, duration: String? = nil) {
        self.title = title; self.channel = channel; self.thumbnailURL = thumbnailURL; self.duration = duration
    }
}
public struct LocalDownload: Codable, Identifiable, Sendable {
    public var metadata: DownloadMetadata? = nil
    public var localThumbnailFilename: String? = nil
    public var lastProgressAt: Date? = nil
    public var id: UUID = UUID(); public var sourceID: UUID; public var job: DownloadJob; public var localFilename: String?; public var bytesPerSecond: Double?; public var contentType: String; public var contentID: String; public var authorizationReference: String; public var requestedQuality: String?
    public var displayTitle: String { metadata?.title ?? job.filename ?? (contentType == "clip" ? "Clip download" : "Video download") }
    public func estimatedSecondsRemaining(at date: Date = .now) -> Double? {
        guard job.status == .transferring, let total = job.totalBytes, total > job.transferredBytes,
              let speed = bytesPerSecond, speed.isFinite, speed > 0,
              let updated = lastProgressAt, (0..<15).contains(date.timeIntervalSince(updated)) else { return nil }
        return Double(total - max(0, job.transferredBytes)) / speed
    }
}
private final class TransferDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let progress: @Sendable (Int64, Int64) -> Void
    var completion: CheckedContinuation<URL, any Error>?
    let destination: URL
    private var lastProgress = Date.distantPast
    init(destination: URL, progress: @escaping @Sendable (Int64, Int64) -> Void) { self.destination = destination; self.progress = progress }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let response = downloadTask.response as? HTTPURLResponse, response.statusCode == 200, response.mimeType == "video/mp4" else { return }
        if Date().timeIntervalSince(lastProgress) >= 0.25 || totalBytesWritten == totalBytesExpectedToWrite { lastProgress = .now; progress(totalBytesWritten, totalBytesExpectedToWrite) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            guard let response = downloadTask.response as? HTTPURLResponse, response.statusCode == 200, response.mimeType == "video/mp4" else { throw ClientError.invalidResponse }
            try FileManager.default.moveItem(at: location, to: destination); completion?.resume(returning: destination); completion = nil
        } catch { completion?.resume(throwing: error); completion = nil }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) { if let error { completion?.resume(throwing: error); completion = nil } }
}
@MainActor @Observable public final class DownloadManager {
    public private(set) var items: [LocalDownload] = []
    public private(set) var error: String?
    private let directory: URL
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var transfers: [UUID: URLSessionDownloadTask] = [:]
    private var thumbnailTasks: [UUID: Task<Void, Never>] = [:]
    public init(directory: URL = TwitchyStoragePaths.directory.appendingPathComponent("Downloads")) {
        self.directory = directory
        #if !os(tvOS)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("index.json")
            if FileManager.default.fileExists(atPath: file.path) { items = try JSONDecoder().decode([LocalDownload].self, from: Data(contentsOf: file)); for index in items.indices where items[index].job.status == .transferring { items[index].job.status = .failed } }
        } catch { self.error = "Downloads could not be restored." }
        #endif
    }
    public var storageBytes: Int64 { items.filter { $0.localFilename != nil }.reduce(0) { $0 + $1.job.transferredBytes } }
    public func file(for item: LocalDownload) -> URL? {
        guard let filename = item.localFilename, filename == item.id.uuidString + ".mp4" else { return nil }
        return directory.appendingPathComponent(filename)
    }
    public func enqueue(client: StreamingSourceClient, type: String, contentID: String, permission: String = "", quality: String = "auto", metadata: DownloadMetadata? = nil) async {
        #if os(tvOS)
        error = "Persistent downloads are unavailable on Apple TV."
        #else
        do {
            error = nil
            let job = try await client.createDownload(contentType: type, contentID: contentID, authorizationReference: permission, requestedQuality: quality)
            let item = LocalDownload(metadata: metadata, sourceID: client.source.id, job: job, contentType: type, contentID: contentID, authorizationReference: permission, requestedQuality: quality)
            items.insert(item, at: 0); save(); cacheThumbnail(item.id, allowLocalHTTP: client.source.allowLocalHTTP); run(item.id, client: client)
        } catch { self.error = error.localizedDescription }
        #endif
    }
    public func resume(_ id: UUID, client: StreamingSourceClient) { guard let item = items.first(where: { $0.id == id }), item.sourceID == client.source.id else { error = "Select the original source to resume this download."; return }; run(id, client: client) }
    private func run(_ id: UUID, client: StreamingSourceClient) {
        guard tasks[id] == nil else { return }
        error = nil
        tasks[id] = Task { [weak self] in
            guard let self, let original = items.first(where: { $0.id == id }) else { return }
            defer { tasks[id] = nil; transfers[id] = nil; save() }
            do {
                var job = original.job
                if job.status == .failed || job.status == .cancelled {
                    do {
                        let remote = try await client.download(job.id)
                        if remote.status == .failed || remote.status == .cancelled {
                            job = try await client.createDownload(contentType: original.contentType, contentID: original.contentID, authorizationReference: original.authorizationReference, requestedQuality: original.requestedQuality ?? "auto")
                        } else { job = remote }
                    } catch let error as SourceAPIError where error.status == 404 {
                        job = try await client.createDownload(contentType: original.contentType, contentID: original.contentID, authorizationReference: original.authorizationReference, requestedQuality: original.requestedQuality ?? "auto")
                    }
                    update(id) { $0.job = job }
                }
                let preparationDeadline = Date().addingTimeInterval(900)
                while job.status == .queued || job.status == .preparing {
                    guard Date() < preparationDeadline else { throw ClientError.message("Download preparation timed out. Retry when your source is ready.") }
                    try await Task.sleep(for: .seconds(2)); job = try await client.download(job.id); update(id) { $0.job = job }
                }
                guard job.status == .ready || job.status == .completed else { throw ClientError.message("The source could not prepare this authorized download.") }
                try Task.checkCancellation()
                let destination = directory.appendingPathComponent(id.uuidString + ".mp4")
                if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
                update(id) { $0.job.status = .transferring; $0.job.transferredBytes = 0; $0.job.progress = 0; $0.bytesPerSecond = nil; $0.lastProgressAt = nil }
                let started = Date()
                let delegate = TransferDelegate(destination: destination) { [weak self] written, total in
                    Task { @MainActor [weak self] in self?.update(id) { item in guard item.job.status == .transferring else { return }; item.job.transferredBytes = written; item.job.totalBytes = total > 0 ? total : nil; item.job.progress = total > 0 ? Double(written) / Double(total) : 0; item.lastProgressAt = .now; let elapsed = Date().timeIntervalSince(started); item.bytesPerSecond = elapsed >= 2 ? Double(written) / elapsed : nil } }
                }
                let config = URLSessionConfiguration.ephemeral; config.urlCredentialStorage = nil; config.httpCookieStorage = nil
                config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 43200
                let delegateQueue = OperationQueue(); delegateQueue.maxConcurrentOperationCount = 1
                let session = URLSession(configuration: config, delegate: delegate, delegateQueue: delegateQueue)
                defer { session.invalidateAndCancel() }
                let request = try client.downloadFileRequest(job.id)
                _ = try await withCheckedThrowingContinuation { continuation in
                    delegate.completion = continuation
                    let task = session.downloadTask(with: request); transfers[id] = task; task.resume()
                }
                if Task.isCancelled { try? FileManager.default.removeItem(at: destination); throw CancellationError() }
                try await OfflineMP4.prepare(destination, expectedDuration: original.metadata?.expectedDuration)
                try Task.checkCancellation()
                let size = (try FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.int64Value ?? 0
                update(id) { $0.localFilename = destination.lastPathComponent; $0.job.status = .completed; $0.job.progress = 1; $0.job.transferredBytes = size; $0.job.totalBytes = size; $0.bytesPerSecond = nil }
                cacheThumbnail(id, allowLocalHTTP: client.source.allowLocalHTTP)
            } catch {
                if original.localFilename == nil {
                    try? FileManager.default.removeItem(at: directory.appendingPathComponent(id.uuidString + ".mp4"))
                }
                if items.first(where: { $0.id == id })?.job.status != .cancelled { update(id) { $0.job.status = .failed }; self.error = error.localizedDescription }
            }
        }
    }
    public func isRunning(_ id: UUID) -> Bool { tasks[id] != nil }
    public func thumbnailFile(for item: LocalDownload) -> URL? {
        guard item.localThumbnailFilename == item.id.uuidString + ".jpg" else { return nil }
        let file = directory.appendingPathComponent(item.id.uuidString + ".jpg")
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
    }
    public func prepareThumbnails() {
        for item in items where thumbnailFile(for: item) == nil {
            cacheThumbnail(item.id, allowLocalHTTP: false)
        }
    }
    private func cacheThumbnail(_ id: UUID, allowLocalHTTP: Bool) {
        #if !os(tvOS)
        guard thumbnailTasks[id] == nil, let item = items.first(where: { $0.id == id }), thumbnailFile(for: item) == nil else { return }
        thumbnailTasks[id] = Task { [weak self] in
            guard let self else { return }
            defer { thumbnailTasks[id] = nil }
            var image: CGImage?
            if let url = item.metadata?.thumbnailURL, (try? SourceURL.media(url, allowLocalHTTP: allowLocalHTTP)) != nil {
                let config = URLSessionConfiguration.ephemeral
                config.httpCookieStorage = nil; config.urlCredentialStorage = nil
                config.timeoutIntervalForRequest = 10; config.timeoutIntervalForResource = 15
                let session = URLSession(configuration: config)
                defer { session.invalidateAndCancel() }
                if let (data, response) = try? await session.data(from: url), data.count <= 5_000_000,
                   (response as? HTTPURLResponse)?.statusCode == 200,
                   let source = CGImageSourceCreateWithData(data as CFData, nil) {
                    image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 640] as CFDictionary)
                }
            }
            if image == nil, let current = items.first(where: { $0.id == id }), let localFile = file(for: current), FileManager.default.fileExists(atPath: localFile.path) {
                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: localFile))
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: 640, height: 360)
                image = try? await generator.image(at: .zero).image
            }
            guard !Task.isCancelled, items.contains(where: { $0.id == id }), let image else { return }
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { return }
            let filename = id.uuidString + ".jpg"
            do {
                try (data as Data).write(to: directory.appendingPathComponent(filename), options: .atomic)
                update(id) { $0.localThumbnailFilename = filename }; save()
            } catch { /* Artwork failure must never interrupt the video download. */ }
        }
        #endif
    }
    private func update(_ id: UUID, action: (inout LocalDownload) -> Void) { if let index = items.firstIndex(where: { $0.id == id }) { action(&items[index]) } }
    public func cancel(_ id: UUID, client: StreamingSourceClient? = nil) async {
        tasks[id]?.cancel(); transfers[id]?.cancel(); update(id) { $0.job.status = .cancelled }; save()
        guard let item = items.first(where: { $0.id == id }) else { return }
        guard let client, client.source.id == item.sourceID else { error = "Cancelled locally. The original source is unavailable for server cleanup."; return }
        do { try await client.cancelDownload(item.job.id) } catch { self.error = "Cancelled locally. Source cancellation failed." }
    }
    public func delete(_ id: UUID) throws {
        guard tasks[id] == nil else { throw ClientError.message("Cancel this download before deleting it.") }
        let file = directory.appendingPathComponent(id.uuidString + ".mp4")
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        thumbnailTasks[id]?.cancel(); thumbnailTasks[id] = nil
        if let item = items.first(where: { $0.id == id }), let thumbnail = thumbnailFile(for: item) { try FileManager.default.removeItem(at: thumbnail) }
        items.removeAll { $0.id == id }; save()
    }
    private func save() { do { try JSONEncoder().encode(items).write(to: directory.appendingPathComponent("index.json"), options: .atomic) } catch { self.error = "Download metadata could not be saved." } }
}
