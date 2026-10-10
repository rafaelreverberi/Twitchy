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
    public private(set) var error: String?
    public private(set) var quality = "auto"
    public var qualityLabel: String { session?.qualityLabel(requested: quality) ?? (quality == "auto" ? "Best" : quality) }
    public private(set) var isPaused = true
    public private(set) var isMuted = false
    public var pictureInPictureActive = false
    private var client: StreamingSourceClient?
    private var request: PlaybackRequest?
    public var currentRequest: PlaybackRequest? { request }
    private var observation: NSKeyValueObservation?
    private var muteObservation: NSKeyValueObservation?
    private var itemObservation: NSKeyValueObservation?
    private var generation = UUID()
    public init() {
        observation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            let value = player.timeControlStatus
            Task { @MainActor [weak self] in
                guard let self else { return }
                isPaused = value == .paused
                guard session != nil else { return }
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
        guard session != nil, player.currentItem != nil else { return }
        if player.timeControlStatus == .paused { player.play(); isPaused = false }
        else { player.pause(); isPaused = true }
    }
    public func toggleMute() { player.isMuted.toggle(); isMuted = player.isMuted }
    public func start(client: StreamingSourceClient, request: PlaybackRequest) async {
        let current = UUID()
        await reset(nextState: .loading, generationID: current)
        guard generation == current, !Task.isCancelled else { return }
        self.client = client; self.request = request; state = .loading; error = nil
        do {
            let session = try await client.createSession(request)
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
            let item = AVPlayerItem(url: session.hlsUrl)
            itemObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
                let failed = item.status == .failed
                Task { @MainActor [weak self] in if failed { self?.state = .failed; self?.error = "Video playback failed. Retry or check your streaming source." } }
            }
            player.replaceCurrentItem(with: item)
            #if os(iOS) || os(tvOS)
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try AVAudioSession.sharedInstance().setActive(true)
            #endif
            if [.buffering, .playing].contains(state) { player.play() }
        } catch is CancellationError { if generation == current { state = .idle } }
        catch { if generation == current { self.error = error.localizedDescription; state = .failed } }
    }
    public func changeQuality(_ value: String) async {
        guard let session, value == "auto" || session.qualities.contains(value), let client, var request else { return }
        let seconds = player.currentTime().seconds
        request.requestedQuality = value; await start(client: client, request: request)
        if request.contentType != "live", seconds.isFinite, seconds > 0 { await player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600)) }
    }
    public func retry() async { guard let client, let request else { return }; await start(client: client, request: request) }
    public func stop() async { await reset(nextState: .idle, generationID: UUID()) }
    private func reset(nextState: PlayerState, generationID: UUID) async {
        generation = generationID; pictureInPictureActive = false
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = false
        #endif
        itemObservation = nil; isPaused = true; player.pause(); player.replaceCurrentItem(with: nil)
        let old = session; let oldClient = client; session = nil; state = nextState; error = nil; client = nil; request = nil
        #if os(iOS) || os(tvOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
        if let old, let oldClient { do { try await oldClient.endSession(old.sessionId) } catch { self.error = "Playback stopped. The source session will expire; cleanup could not reach the source." } }
    }
}
