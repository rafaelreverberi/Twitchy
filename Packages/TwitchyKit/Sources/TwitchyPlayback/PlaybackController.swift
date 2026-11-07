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
    public private(set) var resolved: ResolvedPlayback?
    public var hasMedia: Bool { resolved != nil || session != nil }
    public var playbackID: String? { session?.sessionId ?? (resolved == nil ? nil : generation.uuidString) }
    public var qualities: [String] { resolved?.qualities ?? session?.qualities ?? [] }
    public var providerName: String? { resolved?.providerName }
    public var activeSourceID: UUID? { resolved?.sourceID }
    private var canAdvanceProvider: Bool { resolved?.sourceID != nil || !usingProxy }
    public var usingProxy: Bool { if case .proxy = resolved { true } else { false } }
    public var fallbackNotice: String? { usingProxy ? "Playing via your configured Twitch Proxy." : nil }
    public var managesRecovery: Bool { resolvePlayback != nil }
    @ObservationIgnored public var recoveryEnabled: () -> Bool = { true }
    @ObservationIgnored public var recoveryLimit: () -> Int = { 3 }
    @ObservationIgnored private var recoveryTask: Task<Void, Never>?
    private var recoveryAttempts = 0
    @ObservationIgnored public var resolvePlayback: ((PlaybackRequest, Set<UUID>, Bool) async throws -> ResolvedPlayback)?
    @ObservationIgnored private var watchdog: Task<Void, Never>?
    private var failedSources: Set<UUID> = []
    private var proxyAttempted = false
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
            let observedItem = player.currentItem
            Task { @MainActor [weak self] in
                guard let self, player.currentItem === observedItem, player.timeControlStatus == value else { return }
                isPaused = value == .paused
                guard hasMedia || localFile != nil else { return }
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
            Task { @MainActor [weak self] in
                self?.isMuted = muted
            }
        }
    }
    public func togglePlayPause() {
        guard hasMedia || localFile != nil, player.currentItem != nil else { return }
        if player.timeControlStatus == .paused { player.play(); isPaused = false }
        else { player.pause(); isPaused = true }
    }
    public func toggleMute() { player.isMuted.toggle(); isMuted = player.isMuted }
    public func startOffline(url: URL, type: String, contentID: String, expectedDuration: Double? = nil) async {
        guard !Task.isCancelled else { return }
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
    public func start(client: StreamingSourceClient? = nil, request: PlaybackRequest, failedSourceID: UUID? = nil, recovering: Bool = false) async {
        guard !Task.isCancelled else { return }
        if !recovering { failedSources = []; proxyAttempted = false; recoveryAttempts = 0 }
        if let failedSourceID { failedSources.insert(failedSourceID) }
        let wasPaused = player.rate == 0 && player.timeControlStatus == .paused && state != .failed && player.currentItem != nil
        let hadPiP = pictureInPictureActive
        let current = UUID()
        await reset(nextState: .loading, generationID: current, preservePresentation: recovering)
        guard generation == current, !Task.isCancelled else { return }
        self.client = client; self.request = request; state = .loading; error = nil
        failureIsRetryable = false
        do {
            let media: ResolvedPlayback
            if let resolvePlayback {
                media = try await resolvePlayback(request, failedSources, proxyAttempted)
            } else {
                guard var selected = client else { throw ClientError.noSource }
                if let resolveClient { selected = try await resolveClient(request, failedSourceID) }
                var session: PlaybackSession
                do { session = try await selected.createSession(request) }
                catch {
                    guard Self.canRecover(error), let resolveClient else { throw error }
                    let backup = try await resolveClient(request, selected.source.id)
                    guard backup.source.id != selected.source.id else { throw error }
                    selected = backup; session = try await backup.createSession(request)
                }
                media = .source(selected, session)
            }
            guard generation == current, !Task.isCancelled else {
                if case .source(let source, let session) = media { Task { try? await source.endSession(session.sessionId) } }
                return
            }
            failedSources.formUnion(media.failedSourceIDs)
            resolved = media; quality = request.requestedQuality
            if case .proxy = media { proxyAttempted = true; self.client = nil }
            if case .source(let source, let session) = media { self.client = source; self.session = session }
            switch self.session?.state {
            case "paused_by_server": state = .pausedByServer
            case "ad_break": state = .adBreak
            case "unavailable": state = .unavailable
            case "unsupported": state = .unsupported; error = "The source cannot play this content."
            case "server_error": state = .failed; error = "The source reported a playback error."
            default: state = .buffering
            }
            if state == .unavailable { error = "This stream is unavailable. The channel may be offline."; return }
            if state == .unsupported { return }
            if state == .failed { failureIsRetryable = true; scheduleRecovery(); return }
            let playableURL: URL
            if case .proxy(let proxy) = media, let variant = proxy.variants[request.requestedQuality] { playableURL = variant }
            else { playableURL = media.url; if case .proxy = media { quality = "auto" } }
            let item = AVPlayerItem(url: playableURL)
            // Zero lets AVFoundation choose a buffer suited to the source HLS.
            item.preferredForwardBufferDuration = 0
            observeItem(item, generationID: current)
            player.replaceCurrentItem(with: item)
            #if os(iOS) || os(tvOS)
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try AVAudioSession.sharedInstance().setActive(true)
            #endif
            pictureInPictureActive = recovering ? hadPiP : false
            if [.buffering, .playing].contains(state), !(recovering && wasPaused) { player.play() }
            startWatchdog(generationID: current)
        } catch is CancellationError { if generation == current { state = .idle } }
        catch { if generation == current, !Task.isCancelled {
            self.error = error.localizedDescription; state = .failed
            failureIsRetryable = Self.canRecover(error)
            if let sourceError = error as? SourceAPIError {
                failureIsRetryable = Self.canRecover(sourceError)
                if ["stream_unavailable", "content_unavailable", "unavailable"].contains(sourceError.problem.code), !sourceError.problem.retryable {
                    state = .unavailable; self.error = "This stream is currently unavailable. It may be offline."
                }
            }

            scheduleRecovery()
        } }
    }
    public func changeQuality(_ value: String) async {
        guard value == "auto" || qualities.contains(value), var request else { return }
        if case .proxy(let media) = resolved {
            guard let url = value == "auto" ? media.url : media.variants[value] else { return }
            let paused = isPaused
            quality = value; request.requestedQuality = value; self.request = request
            // Keep the provider and player; re-resolve on Retry if the signed URL expires.
            let item = AVPlayerItem(url: url)
            observeItem(item, generationID: generation)
            player.replaceCurrentItem(with: item)
            if !paused { player.play() }
            startWatchdog(generationID: generation)
            return
        }
        guard let client else { return }
        let seconds = player.currentTime().seconds
        request.requestedQuality = value; await start(client: client, request: request, recovering: true)
        if request.contentType != "live", seconds.isFinite, seconds > 0 { await player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600)) }
    }
    public func retry(automatic: Bool = false) async {
        if let localFile, let request { await startOffline(url: localFile, type: request.contentType, contentID: request.contentId ?? "", expectedDuration: offlineExpectedDuration); return }
        guard let request else { return }
        let seconds = player.currentTime().seconds
        let failed = state == .failed && failureIsRetryable ? resolved?.sourceID ?? client?.source.id : nil
        if automatic, usingProxy, resolved?.sourceID == nil { failureIsRetryable = false; return }
        await start(client: client, request: request, failedSourceID: failed, recovering: automatic)
        if request.contentType != "live", seconds.isFinite, seconds > 0, session != nil, self.request?.contentId == request.contentId, self.request?.contentType == request.contentType {
            await player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
        }
    }
    public static func canRecover(_ error: Error) -> Bool {
        PlaybackFailurePolicy.canRecover(error)
    }
    /// A sustained startup/buffering stall enters the same bounded UI retry path as item failure.
    private func startWatchdog(generationID: UUID) {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            var waiting = 0
            var previousTime: Double?
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)); try Task.checkCancellation() } catch { return }
                guard let self, generation == generationID, hasMedia, let item = player.currentItem else { return }
                if item.status == .failed { state = .failed; failureIsRetryable = canAdvanceProvider && (usingProxy || Self.itemFailureCanRecover(item)); error = "Video playback failed. Retry or check streaming proxy settings."; scheduleRecovery(); return }
                if state == .failed || state == .unavailable || state == .unsupported { return }
                let time = player.currentTime().seconds
                let advancing = time.isFinite && previousTime.map { time > $0 } == true
                previousTime = time
                if player.timeControlStatus == .waitingToPlayAtSpecifiedRate || (!isPaused && !advancing) { waiting += 1 } else { waiting = 0 }
                if waiting >= 25 {
                    state = .failed; failureIsRetryable = canAdvanceProvider
                    error = "Video did not begin or resume within 25 seconds. Retry or check streaming proxy settings."
                    player.pause(); scheduleRecovery(); return
                }
            }
        }
    }
    public static func itemFailureCanRecover(_ item: AVPlayerItem) -> Bool {
        let status = item.errorLog()?.events.last?.errorStatusCode
        if let status, [401, 403, 404].contains(status) { return false }
        if let error = item.error as? AVError,
           [.contentIsProtected, .fileFormatNotRecognized, .decoderNotFound, .fileFailedToParse].contains(error.code) { return false }
        return true
    }
    private func observeItem(_ item: AVPlayerItem, generationID: UUID) {
        if let failureNotification { NotificationCenter.default.removeObserver(failureNotification) }
        failureNotification = NotificationCenter.default.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, generation == generationID, player.currentItem === item else { return }
                failureIsRetryable = canAdvanceProvider && (usingProxy || Self.itemFailureCanRecover(item))
                state = .failed; error = "Video playback was interrupted. Retry or check streaming proxy settings."; scheduleRecovery()
            }
        }
        itemObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            let failed = item.status == .failed
            Task { @MainActor [weak self] in
                guard failed, let self, generation == generationID, player.currentItem === item else { return }
                state = .failed; failureIsRetryable = canAdvanceProvider && (usingProxy || Self.itemFailureCanRecover(item)); error = "Video playback failed. Retry or check streaming proxy settings."
                scheduleRecovery()
            }
        }
    }
    private func scheduleRecovery() {
        guard managesRecovery, recoveryEnabled(), failureIsRetryable, canAdvanceProvider,
              recoveryTask == nil, recoveryAttempts < recoveryLimit() else { return }
        let current = generation
        recoveryAttempts += 1
        recoveryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(1)); try Task.checkCancellation() } catch { return }
            guard let self, generation == current, state == .failed, recoveryEnabled() else { self?.recoveryTask = nil; return }
            recoveryTask = nil
            await retry(automatic: true)
        }
    }
    public func stop() async { await reset(nextState: .idle, generationID: UUID()) }
    private func reset(nextState: PlayerState, generationID: UUID, preservePresentation: Bool = false) async {
        generation = generationID; recoveryTask?.cancel(); recoveryTask = nil; watchdog?.cancel(); watchdog = nil
        if !preservePresentation { pictureInPictureActive = false }
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = false
        #endif
        if let failureNotification { NotificationCenter.default.removeObserver(failureNotification); self.failureNotification = nil }
        itemObservation = nil; isPaused = true; player.pause()
        // Retain the old item while resolving recovery/quality changes so PiP keeps its surface.
        if !preservePresentation { player.replaceCurrentItem(with: nil) }
        let old = session; let oldClient = client; session = nil; resolved = nil; localFile = nil; state = nextState; error = nil; client = nil; request = nil
        offlineExpectedDuration = nil
        #if os(iOS) || os(tvOS)
        if !preservePresentation { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
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
