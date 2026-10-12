import Foundation
import AVFoundation
import Observation
import TwitchyCore
import TwitchySources
#if os(iOS) || os(tvOS)
import UIKit
#endif

public enum PlayerState: String, Sendable { case idle, loading, playing, buffering, reconnecting, unavailable, pausedByServer, adBreak, unsupported, failed }
@MainActor @Observable public final class PlaybackController {
    public let player = AVPlayer()
    public private(set) var state: PlayerState = .idle
    public private(set) var session: PlaybackSession?
    public private(set) var localFile: URL?
    public var isOffline: Bool { localFile != nil }
    public private(set) var error: String?
    public private(set) var quality = "auto"
    public var qualityLabel: String { session?.qualityLabel(requested: quality) ?? (quality == "auto" ? "Best" : quality) }
    public private(set) var isPaused = true
    public private(set) var isMuted = false
    public var pictureInPictureActive = false
    public private(set) var failureIsRetryable = false
    @ObservationIgnored public var resolveClient: ((PlaybackRequest, UUID?) async throws -> StreamingSourceClient)?
    private var client: StreamingSourceClient?
    private var request: PlaybackRequest?
    private var offlineExpectedDuration: Double?
    public var currentRequest: PlaybackRequest? { request }
    private var observation: NSKeyValueObservation?
    private var muteObservation: NSKeyValueObservation?
    private var itemObservation: NSKeyValueObservation?
    @ObservationIgnored private var failureNotification: (any NSObjectProtocol)?
    private var generation = UUID()
    public init() {
        // Use the same adaptive stall prevention on every platform.
        player.automaticallyWaitsToMinimizeStalling = true
        observation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            let value = player.timeControlStatus
            Task { @MainActor [weak self] in
                guard let self else { return }
                isPaused = value == .paused
                guard session != nil || localFile != nil else { return }
                #if os(iOS)
                guard player.timeControlStatus == value, player.currentItem != nil else { return }
                #endif
                if value == .playing {
                    state = .playing
                    #if os(iOS)
                    UIApplication.shared.isIdleTimerDisabled = true
                    #endif
                }
                else if value == .waitingToPlayAtSpecifiedRate { state = .buffering }
            }
        }
        muteObservation = player.observe(\.isMuted, options: [.initial, .new]) { [weak self] player, _ in
            let muted = player.isMuted
            Task { @MainActor [weak self] in self?.isMuted = muted }
        }
    }
    public func togglePlayPause() {
        guard session != nil || localFile != nil, player.currentItem != nil else { return }
        if player.timeControlStatus == .paused { player.play(); isPaused = false }
        else { player.pause(); isPaused = true }
    }
    public func toggleMute() { player.isMuted.toggle(); isMuted = player.isMuted }
    public func startOffline(url: URL, type: String, contentID: String, expectedDuration: Double? = nil) async {
        let current = UUID()
        await reset(nextState: .loading, generationID: current)
        guard generation == current, !Task.isCancelled else { return }
        localFile = url; request = .init(contentType: type, contentId: contentID, requestedQuality: "auto")
        offlineExpectedDuration = expectedDuration
        do {
            guard url.isFileURL, FileManager.default.fileExists(atPath: url.path) else { throw ClientError.message("The downloaded video is missing. Download it again.") }
            try await OfflineMP4.prepare(url, expectedDuration: expectedDuration)
            guard generation == current, !Task.isCancelled else { return }
            let item = AVPlayerItem(url: url)
            itemObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
                let failed = item.status == .failed
                Task { @MainActor [weak self] in
                    guard let self, generation == current else { return }
                    if failed { state = .failed; error = "This offline video could not be played. Download it again." }
                }
            }
            #if os(iOS) || os(tvOS)
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try AVAudioSession.sharedInstance().setActive(true)
            #endif
            state = .buffering; player.replaceCurrentItem(with: item); player.play()
        } catch { if generation == current { state = .failed; self.error = error.localizedDescription } }
    }
    public func start(client: StreamingSourceClient, request: PlaybackRequest, failedSourceID: UUID? = nil) async {
        let current = UUID()
        await reset(nextState: .loading, generationID: current)
        guard generation == current, !Task.isCancelled else { return }
        self.client = client; self.request = request; state = .loading; error = nil
        failureIsRetryable = false
        do {
            var client = client
            if let resolveClient { client = try await resolveClient(request, failedSourceID) }
            guard generation == current, !Task.isCancelled else { return }
            self.client = client
            let session: PlaybackSession
            do { session = try await client.createSession(request) }
            catch {
                guard Self.canRecover(error), let resolveClient else { throw error }
                let backup = try await resolveClient(request, client.source.id)
                guard generation == current, !Task.isCancelled else { return }
                guard backup.source.id != client.source.id else { throw error }
                client = backup; self.client = backup
                session = try await backup.createSession(request)
            }
            guard generation == current, !Task.isCancelled else { try await client.endSession(session.sessionId); return }
            self.session = session; quality = request.requestedQuality
            switch session.state {
            case "paused_by_server": state = .pausedByServer
            case "ad_break": state = .adBreak
            case "unavailable": state = .unavailable
            case "unsupported": state = .unsupported; error = "The source cannot play this content."
            case "server_error": state = .failed; error = "The source reported a playback error."
            default: state = .buffering
            }
            if state == .unavailable { error = "This stream is unavailable. The channel may be offline."; return }
            if state == .unsupported { return }
            if state == .failed { failureIsRetryable = true; return }
            let item = AVPlayerItem(url: session.hlsUrl)
            // Zero lets AVFoundation choose a buffer suited to the source HLS.
            item.preferredForwardBufferDuration = 0
            itemObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
                let failed = item.status == .failed
                Task { @MainActor [weak self] in if failed, let self, self.generation == current { self.state = .failed; self.error = "Video playback failed. Retry or check your streaming source."
                    self.failureIsRetryable = true
                } }
            }
            failureNotification = NotificationCenter.default.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, generation == current else { return }
                    failureIsRetryable = true; state = .failed; error = "Video playback was interrupted."
                }
            }
            player.replaceCurrentItem(with: item)
            #if os(iOS) || os(tvOS)
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try AVAudioSession.sharedInstance().setActive(true)
            #endif
            if [.buffering, .playing].contains(state) { player.play() }
        } catch is CancellationError { if generation == current { state = .idle } }
        catch { if generation == current {
            self.error = error.localizedDescription; state = .failed
            failureIsRetryable = Self.canRecover(error)
            if let sourceError = error as? SourceAPIError {
                failureIsRetryable = sourceError.problem.retryable
                if ["stream_unavailable", "content_unavailable", "unavailable"].contains(sourceError.problem.code), !sourceError.problem.retryable {
                    state = .unavailable; self.error = "This stream is currently unavailable. It may be offline."
                }
            }

        } }
    }
    public func changeQuality(_ value: String) async {
        guard let session, value == "auto" || session.qualities.contains(value), let client, var request else { return }
        let seconds = player.currentTime().seconds
        request.requestedQuality = value; await start(client: client, request: request)
        if request.contentType != "live", seconds.isFinite, seconds > 0 { await player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600)) }
    }
    public func retry() async {
        if let localFile, let request { await startOffline(url: localFile, type: request.contentType, contentID: request.contentId ?? "", expectedDuration: offlineExpectedDuration); return }
        guard let client, let request else { return }
        let seconds = player.currentTime().seconds
        let failed = state == .failed && failureIsRetryable ? client.source.id : nil
        await start(client: client, request: request, failedSourceID: failed)
        if request.contentType != "live", seconds.isFinite, seconds > 0, session != nil, self.request?.contentId == request.contentId, self.request?.contentType == request.contentType {
            await player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
        }
    }
    public static func canRecover(_ error: Error) -> Bool {
        if let error = error as? SourceAPIError { return error.problem.retryable && (error.status >= 500 || error.status == 429) }
        if let error = error as? URLError {
            return [.timedOut, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .notConnectedToInternet].contains(error.code)
        }
        if case ClientError.server(let status) = error { return status >= 500 }
        return false
    }
    public func stop() async { await reset(nextState: .idle, generationID: UUID()) }
    private func reset(nextState: PlayerState, generationID: UUID) async {
        generation = generationID; pictureInPictureActive = false
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = false
        #endif
        if let failureNotification { NotificationCenter.default.removeObserver(failureNotification); self.failureNotification = nil }
        itemObservation = nil; isPaused = true; player.pause(); player.replaceCurrentItem(with: nil)
        let old = session; let oldClient = client; session = nil; localFile = nil; state = nextState; error = nil; client = nil; request = nil
        offlineExpectedDuration = nil
        #if os(iOS) || os(tvOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
        if let old, let oldClient {
            // Server cleanup must not hold up local stop, navigation or a new movie.
            Task { [weak self] in
                do { try await oldClient.endSession(old.sessionId) }
                catch {
                    guard let self, generation == generationID, state == .idle else { return }
                    self.error = "Playback stopped. The source session will expire; cleanup could not reach the source."
                }
            }
        }
    }
}
