#if os(iOS)
import SwiftUI
import AVKit
import TwitchyCore
import TwitchyPlayback
import TwitchySources

/// iOS playback belongs to the app, never to a channel page or a presentation.
@MainActor @Observable final class MobilePlaybackCoordinator {
    enum Presentation { case mini, watch, fullscreen }
    private unowned let model: AppModel
    var selection: ChannelSelection?
    var title = ""
    var category = ""
    var avatar: URL?
    var thumbnailURL: URL?
    var duration: String?
    var presentation: Presentation = .mini
    var error: String?
    var recovering = false
    var isComposing = false
    var inBackground = false
    var pipActivationCount = 0
    var pipPossible = false
    @ObservationIgnored lazy var surface = MobilePlayerSurface(owner: self, player: model.playback.player)
    @ObservationIgnored private var playbackTask: Task<Void, Never>?
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var backgroundTask: Task<Void, Never>?
    private var sourceID: UUID?
    private var sourceURL: URL?
    private var chatKey: String?
    private var retryAttempt = 0
    private var resumeAfterBackground = false
    private var generation = UUID()

    init(model: AppModel) { self.model = model }
    var expanded: Bool { selection != nil && presentation != .mini }
    var fullscreen: Bool { presentation == .fullscreen }
    var pipEnabled: Bool { model.personal.data.preferences.pictureInPicture }
    var player: AVPlayer { model.playback.player }
    var state: PlayerState { model.playback.state }
    let surfaceID = UUID().uuidString
    var identity: String { (selection?.login ?? "") + ":" + (selection?.contentType ?? "") + ":" + (selection?.contentID ?? "") }

    func start(_ channel: ChannelSelection, type: String = "live", id: String? = nil, title: String? = nil, category: String? = nil, avatar: URL? = nil, thumbnailURL: URL? = nil, duration: String? = nil) {
        model.offlineDownload = nil
        presentation = .watch
        surface.configure(automaticPiP: pipEnabled)
        // Opening the same content is a presentation change, including while it is loading.
        if let current = selection, current.login == channel.login, current.contentType == type, current.contentID == id,
           sourceID == model.sources.activeID, sourceURL == model.sources.active?.baseURL,
           playbackTask != nil || model.playback.player.currentItem != nil {
            self.thumbnailURL = thumbnailURL ?? self.thumbnailURL
            self.duration = duration ?? self.duration
            return
        }
        savePosition(); playbackTask?.cancel(); retryTask?.cancel()
        generation = UUID(); let current = generation
        retryAttempt = 0; error = nil; recovering = false; model.error = nil
        var active = channel; active.contentType = type; active.contentID = id; active.returnToPlayback = true
        selection = active; self.title = title ?? channel.name; self.category = category ?? ""; self.avatar = avatar; self.thumbnailURL = thumbnailURL; self.duration = duration
        sourceID = model.sources.activeID; sourceURL = model.sources.active?.baseURL
        connectChat()
        playbackTask = Task { [weak self] in
            guard let self else { return }
            await model.play(active, contentType: type, contentID: id)
            guard !Task.isCancelled, generation == current else { return }
            if type != "live", active.resumePosition > 0, model.playback.player.currentItem != nil {
                await player.seek(to: CMTime(seconds: active.resumePosition, preferredTimescale: 600))
            }
            playbackTask = nil
            if model.playback.session == nil { error = model.error ?? model.playback.error ?? "The stream could not be started." }
            handleState()
        }
    }
    func startOffline(_ channel: ChannelSelection, item: LocalDownload, url: URL) {
        savePosition(); playbackTask?.cancel(); retryTask?.cancel(); generation = UUID()
        let current = generation
        selection = channel; title = item.displayTitle; category = "Offline video"; avatar = nil
        thumbnailURL = model.downloads.thumbnailFile(for: item) ?? item.metadata?.thumbnailURL; duration = item.metadata?.duration
        error = nil; recovering = false; retryAttempt = 0; presentation = .watch; disconnectChat()
        surface.configure(automaticPiP: pipEnabled)
        playbackTask = Task { [weak self] in
            guard let self else { return }
            await model.playback.startOffline(url: url, type: item.contentType, contentID: item.contentID, expectedDuration: item.metadata?.expectedDuration)
            guard generation == current, !Task.isCancelled else { return }
            playbackTask = nil; error = model.playback.error; handleState()
        }
    }
    func updateChannel(login: String, broadcasterID: String?, avatar: URL?, category: String?) {
        guard selection?.login == login else { return }
        selection?.broadcasterID = broadcasterID; self.avatar = avatar ?? self.avatar
        if let category { self.category = category }
        connectChat()
    }
    func expand() {
        presentation = .watch
        surface.configure(automaticPiP: pipEnabled)
        if model.playback.pictureInPictureActive { surface.pip?.stopPictureInPicture() }
        connectChat()
    }
    func collapse() {
        presentation = .mini; isComposing = false; savePosition()
        surface.configure(automaticPiP: false)
    }
    func toggleFullscreen() {
        isComposing = false
        presentation = fullscreen ? .watch : .fullscreen
        surface.configure(automaticPiP: pipEnabled)
    }
    func openChannel() {
        guard var channel = selection else { return }
        collapse(); channel.offlineDownloadID = nil; channel.contentType = nil; channel.contentID = nil; channel.resumePosition = 0
        // A navigation destination must not autoplay when reopening the active channel.
        channel.returnToPlayback = true
        model.selectedChannel = channel
    }
    func stop() {
        savePosition(); generation = UUID(); playbackTask?.cancel(); playbackTask = nil
        retryTask?.cancel(); retryTask = nil; backgroundTask?.cancel(); backgroundTask = nil
        surface.configure(automaticPiP: false); surface.pip?.stopPictureInPicture()
        selection = nil; model.offlineDownload = nil; error = nil; recovering = false; isComposing = false; presentation = .mini; disconnectChat()
        model.playback.player.pause()
        let stoppedGeneration = generation
        playbackTask = Task { [weak self] in
            guard let self else { return }
            await model.playback.stop()
            if generation == stoppedGeneration { playbackTask = nil }
        }
    }
    func sourceChanged() {
        guard !model.isOfflinePlayback, selection != nil, sourceID != model.sources.activeID || sourceURL != model.sources.active?.baseURL else { return }
        stop()
    }
    func retry() {
        guard let channel = selection else { return }
        retryTask?.cancel(); retryTask = nil; playbackTask?.cancel(); error = nil; model.error = nil
        let current = generation
        playbackTask = Task { [weak self] in
            guard let self else { return }
            if model.playback.currentRequest != nil { await model.playback.retry() }
            else { await model.play(channel, contentType: channel.contentType ?? "live", contentID: channel.contentID) }
            guard !Task.isCancelled, generation == current else { return }
            playbackTask = nil; handleState()
        }
    }
    func changeQuality(_ quality: String) {
        savePosition(); retryTask?.cancel(); retryTask = nil; playbackTask?.cancel()
        let current = generation
        playbackTask = Task { [weak self] in
            guard let self else { return }
            await model.playback.changeQuality(quality)
            guard !Task.isCancelled, generation == current else { return }
            playbackTask = nil; handleState()
        }
    }
    func handleState() {
        guard selection != nil else { return }
        if state == .playing { error = nil; recovering = false; retryAttempt = 0; surface.preparePiP() }
        if state == .failed, retryTask == nil, playbackTask == nil { recovering = false }
        guard state == .failed, model.playback.failureIsRetryable, model.personal.data.preferences.retryPlayback,
              retryAttempt < 2, retryTask == nil, playbackTask == nil else { return }
        recovering = true; retryAttempt += 1; let delay = retryAttempt; let current = generation
        retryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self, generation == current, state == .failed, selection != nil else { return }
            retryTask = nil; retry()
        }
    }
    func loadWatchingProfile() async {
        guard !model.isOfflinePlayback, avatar == nil, let channel = selection, let api = model.api else { return }
        let current = generation
        do {
            let profile = try await api.users(logins: [channel.login]).data.first
            guard !Task.isCancelled, generation == current, let profile else { return }
            avatar = URL(string: profile.profileImageUrl); selection?.broadcasterID = profile.id; connectChat()
        } catch { /* Optional channel metadata never interrupts playback. */ }
    }
    func savePosition() {
        guard let channel = selection, channel.contentType != "live", let id = channel.contentID else { return }
        let seconds = player.currentTime().seconds
        if seconds.isFinite && seconds > 0 { model.personal.watched(.init(login: channel.login, title: title, position: seconds, contentType: channel.contentType, contentID: id)) }
    }
    func connectChat() {
        guard !model.isOfflinePlayback else { disconnectChat(); return }
        guard !inBackground, let id = selection?.broadcasterID, let api = model.api,
              let session = model.auth.session, session.scopes.contains("user:read:chat") else { return }
        let key = id + ":" + session.accessToken
        guard chatKey != key else { return }
        chatKey = key; model.chat.connect(api: api, broadcasterID: id, userID: session.userID)
    }
    private func disconnectChat() { chatKey = nil; model.chat.disconnect() }
    func enterBackground() {
        inBackground = true; savePosition(); disconnectChat(); backgroundTask?.cancel()
        // Give AVKit its automatic PiP transition. Do not delete the source session.
        backgroundTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(1.5)) } catch { return }
            guard let self, inBackground, !model.playback.pictureInPictureActive else { return }
            resumeAfterBackground = resumeAfterBackground || player.timeControlStatus != .paused
            player.pause()
        }
    }
    func enterForeground() {
        inBackground = false; backgroundTask?.cancel(); backgroundTask = nil
        if resumeAfterBackground, selection != nil { player.play() }
        resumeAfterBackground = false; connectChat()
    }
    func pipChanged(active: Bool) {
        guard selection != nil || !active else { surface.pip?.stopPictureInPicture(); return }
        model.playback.pictureInPictureActive = active
        if !active, inBackground { resumeAfterBackground = resumeAfterBackground || player.timeControlStatus != .paused; player.pause() }
    }
}

@MainActor final class MobilePlayerSurface: NSObject, @preconcurrency AVPictureInPictureControllerDelegate {
    unowned let owner: MobilePlaybackCoordinator
    let view: MobileVideoUIView
    private(set) var pip: AVPictureInPictureController?
    private var automaticPiP = false
    private var possibleObservation: NSKeyValueObservation?
    private var readyObservation: NSKeyValueObservation?
    init(owner: MobilePlaybackCoordinator, player: AVPlayer) {
        self.owner = owner; view = MobileVideoUIView()
        view.playerLayer.player = player; view.playerLayer.videoGravity = .resizeAspect
        super.init()
        readyObservation = view.playerLayer.observe(\.isReadyForDisplay, options: [.new]) { [weak self] layer, _ in
            let ready = layer.isReadyForDisplay
            Task { @MainActor [weak self] in if ready { self?.preparePiP() } }
        }
    }
    func preparePiP() {
        guard pip == nil, AVPictureInPictureController.isPictureInPictureSupported(), view.window != nil, view.playerLayer.isReadyForDisplay else { return }
        pip = AVPictureInPictureController(playerLayer: view.playerLayer)
        pip?.delegate = self
        pip?.canStartPictureInPictureAutomaticallyFromInline = automaticPiP
        possibleObservation = pip?.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] controller, _ in
            let possible = controller.isPictureInPicturePossible
            Task { @MainActor [weak self] in self?.owner.pipPossible = possible }
        }
    }
    func configure(automaticPiP: Bool) { self.automaticPiP = automaticPiP; preparePiP(); pip?.canStartPictureInPictureAutomaticallyFromInline = automaticPiP }
    func togglePiP() {
        if pip?.isPictureInPictureActive == true { pip?.stopPictureInPicture() }
        else if owner.pipEnabled { pip?.startPictureInPicture() }
    }
    func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) { owner.pipChanged(active: true) }
    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) { owner.pipActivationCount += 1; owner.pipChanged(active: true) }
    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) { owner.pipChanged(active: false) }
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) { owner.pipChanged(active: false) }
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        owner.presentation = .watch; completionHandler(true)
    }
}
@MainActor final class MobileVideoUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}
struct MobileVideoSurface: UIViewRepresentable {
    let surface: MobilePlayerSurface
    func makeUIView(context: Context) -> MobileVideoUIView { surface.view }
    func updateUIView(_ view: MobileVideoUIView, context: Context) { }
}
#endif
