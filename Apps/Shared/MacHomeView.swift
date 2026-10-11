#if os(macOS)
import SwiftUI
import TwitchyAPI
import TwitchyDesignSystem

/// Desktop discovery keeps the same account, history and source as the shared app.
struct MacHomeView: View {
    @Environment(AppModel.self) private var model
    private var featured: TwitchStream? { model.recommendedStreams.first ?? model.followedStreams.first ?? model.streams.first }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                HStack {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Home").font(.system(size: 34, weight: .bold))
                        Text("Your channels. New discoveries. Always something live.").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.bordered).disabled(model.loading).accessibilityLabel("Refresh streams")
                }
                if let error = model.error { Notice(error) }
                if model.api == nil {
                    VStack(alignment: .leading, spacing: 16) {
                        Label("Make yourself at home", systemImage: "sparkles").font(.title2.bold())
                        Text("A place for the channels you love and the streams you haven't found yet.").foregroundStyle(.secondary)
                        LoginPrompt()
                    }.padding(28).macSurface()
                } else {
                    if let featured { feature(featured) }
                    if model.loading { ProgressView("Updating your lineup…") }
                    if !model.recommendedStreams.isEmpty { StreamSection(title: "For you · Live now", streams: model.recommendedStreams) }
                    if !model.followedStreams.isEmpty { StreamSection(title: "Following · Live now", streams: model.followedStreams) }
                    if !model.personal.data.history.isEmpty { WatchHistoryRow() }
                    StreamSection(title: "Popular right now", streams: model.streams)
                    if model.streamsCursor != nil { Button("Discover more streams") { Task { await model.moreStreams() } }.buttonStyle(.bordered) }
                    if !model.categories.isEmpty {
                        VStack(alignment: .leading, spacing: 16) {
                            Text("Explore categories").font(.title2.bold())
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130, maximum: 190))], spacing: 20) {
                                ForEach(model.categories) { category in
                                    NavigationLink { CategoryDetail(category: category) } label: {
                                        VStack(alignment: .leading, spacing: 10) {
                                            RemoteImage(URL(string: category.boxArtUrl.replacingOccurrences(of: "{width}", with: "285").replacingOccurrences(of: "{height}", with: "380")))
                                                .aspectRatio(0.75, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 14))
                                            Text(category.name).font(.headline).lineLimit(1)
                                        }
                                    }.buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    if model.streams.isEmpty && !model.loading { EmptyState("Your lineup is quiet", detail: "Refresh to find live streams on Twitch.") }
                }
            }.padding(30).frame(maxWidth: 1500, alignment: .leading).frame(maxWidth: .infinity)
        }.background(TwitchyTheme.background).navigationTitle("Home")
    }
    private func feature(_ stream: TwitchStream) -> some View {
        HStack(spacing: 0) {
            Button { model.open(login: stream.userLogin, name: stream.userName, id: stream.userId) } label: {
                RemoteImage(stream.thumbnail).aspectRatio(16 / 9, contentMode: .fit)
                    .overlay(alignment: .topLeading) { MacLiveBadge().padding(18) }
                    .overlay(alignment: .center) { Image(systemName: "play.circle.fill").font(.system(size: 54)).foregroundStyle(.white).shadow(radius: 12) }
            }.buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 16) {
                Text(!model.recommendedStreams.isEmpty ? "PICKED FOR YOU" : model.followedStreams.isEmpty ? "IN THE SPOTLIGHT" : "FROM YOUR FOLLOWING")
                    .font(.caption.bold()).tracking(2).foregroundStyle(TwitchyTheme.highlight)
                Text(stream.userName).font(.title.bold())
                Text(stream.title).font(.headline).lineLimit(3)
                Text(stream.gameName).foregroundStyle(.secondary)
                Label("\(stream.viewerCount.formatted()) watching", systemImage: "person.2").font(.caption).foregroundStyle(.secondary)
                Button("Explore channel", systemImage: "arrow.right") { model.open(login: stream.userLogin, name: stream.userName, id: stream.userId) }.buttonStyle(.borderedProminent)
            }.padding(26).frame(width: 285, alignment: .leading)
        }.macSurface().clipShape(RoundedRectangle(cornerRadius: 18))
    }

}

struct MacLiveBadge: View {
    var body: some View {
        Text("LIVE").font(.caption.bold()).foregroundStyle(.white).padding(.horizontal, 9).padding(.vertical, 5)
            .background(Color(hex: 0xFF315C), in: RoundedRectangle(cornerRadius: 6))
    }
}
extension View {
    func macSurface() -> some View {
        background(TwitchyTheme.secondary, in: RoundedRectangle(cornerRadius: 16))
            .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(.primary.opacity(0.08), lineWidth: 1) }
    }
}
#endif

#if os(macOS)
import TwitchyChat

/// Words and image attachments share the available line width instead of squeezing
/// every fragment into its own narrow text column.
struct MacChatMessage: View {
    @Environment(AppModel.self) private var model
    let message: TwitchyChat.ChatMessage
    let timestamp: Date
    private struct Token {
        var text: String
        var emoteID: String?
    }
    private var tokens: [Token] {
        if !model.personal.data.preferences.emotes {
            return message.message.text.split(whereSeparator: \.isWhitespace).map { Token(text: String($0)) }
        }
        return message.message.fragments.flatMap { fragment -> [Token] in
            if let emote = fragment.emote { return [Token(text: fragment.text, emoteID: emote.id)] }
            return fragment.text.split(whereSeparator: \.isWhitespace).map { Token(text: String($0)) }
        }
    }
    private var nameColor: Color {
        guard let hex = UInt32(message.color.replacingOccurrences(of: "#", with: ""), radix: 16) else { return TwitchyTheme.highlight }
        return Color(hex: hex)
    }
    var body: some View {
        MacChatFlow(spacing: 4) {
            if model.personal.data.preferences.timestamps { Text(timestamp.formatted(date: .omitted, time: .shortened)).font(.caption2).foregroundStyle(.secondary) }
            ForEach(message.badges, id: \.setId) { badge in
                if let url = model.chat.badgeImages["\(badge.setId)/\(badge.id)"] {
                    AsyncImage(url: url) { image in image.resizable().scaledToFit() } placeholder: { Color.clear }
                        .frame(width: 18, height: 18).accessibilityLabel(badge.setId)
                }
            }
            Text(message.chatterUserName).bold().foregroundStyle(nameColor)
            ForEach(Array(tokens.enumerated()), id: \.offset) { _, token in
                if let id = token.emoteID {
                    AsyncImage(url: URL(string: "https://static-cdn.jtvnw.net/emoticons/v2/\(id)/default/dark/1.0")) { image in image.resizable().scaledToFit() } placeholder: { Text(token.text).lineLimit(1) }
                        .frame(width: 24, height: 24).accessibilityLabel(token.text)
                } else { Text(token.text) }
            }
        }.font(.system(size: model.personal.data.preferences.chatFontSize))
    }
}
struct MacChatFlow: Layout {
    var spacing: CGFloat
    private func arrangement(width: CGFloat, subviews: Subviews) -> (CGSize, [CGRect]) {
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        var frames: [CGRect] = []
        for view in subviews {
            var size = view.sizeThatFits(.unspecified)
            if size.width > width { size = view.sizeThatFits(ProposedViewSize(width: width, height: nil)) }
            if x > 0 && x + size.width > width {
                x = 0; y += rowHeight + spacing; rowHeight = 0
            }
            frames.append(CGRect(x: x, y: y, width: size.width, height: size.height))
            x += size.width + spacing; rowHeight = max(rowHeight, size.height)
        }
        return (CGSize(width: width, height: y + rowHeight), frames)
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrangement(width: max(1, proposal.width ?? 280), subviews: subviews).0
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = arrangement(width: max(1, bounds.width), subviews: subviews).1
        for (view, frame) in zip(subviews, frames) {
            view.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(frame.size))
        }
    }
}
#endif

#if os(macOS)
import AVKit
import TwitchyPlayback
import Observation

/// Keep one video layer and PiP controller alive across channel navigation and fullscreen.
@MainActor @Observable final class DesktopPlayerSurface: NSObject, @preconcurrency AVPictureInPictureControllerDelegate {
    let view = DesktopVideoView()
    let playback: PlaybackController
    private var pip: AVPictureInPictureController?
    private var pipObservation: NSKeyValueObservation?
    private var volumeObservation: NSKeyValueObservation?
    var pipPossible = false
    var volume: Double = 1
    var restorePlayback: (() -> Void)?

    init(playback: PlaybackController) {
        self.playback = playback
        super.init()
        view.videoLayer.player = playback.player
        pip = AVPictureInPictureController(playerLayer: view.videoLayer)
        pip?.delegate = self
        pipObservation = pip?.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] controller, _ in
            let possible = controller.isPictureInPicturePossible
            Task { @MainActor [weak self] in self?.pipPossible = possible }
        }
        volumeObservation = playback.player.observe(\.volume, options: [.initial, .new]) { [weak self] player, _ in
            let volume = Double(player.volume)
            Task { @MainActor [weak self] in self?.volume = volume }
        }
    }
    func setVolume(_ value: Double) {
        volume = value
        playback.player.volume = Float(value)
        if value > 0, playback.isMuted { playback.toggleMute() }
    }
    func togglePiP() {
        guard let pip else { return }
        if pip.isPictureInPictureActive { pip.stopPictureInPicture() }
        else if pip.isPictureInPicturePossible { pip.startPictureInPicture() }
    }
    func stopPiP() { pip?.stopPictureInPicture() }
    func pictureInPictureControllerWillStartPictureInPicture(_ controller: AVPictureInPictureController) { playback.pictureInPictureActive = true }
    func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) { playback.pictureInPictureActive = false }
    func pictureInPictureController(_ controller: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) { playback.pictureInPictureActive = false }
    func pictureInPictureController(_ controller: AVPictureInPictureController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        restorePlayback?()
        completionHandler(true)
    }
}

@MainActor final class DesktopVideoView: NSView {
    let videoLayer = AVPlayerLayer()
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        videoLayer.videoGravity = .resizeAspect
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(videoLayer)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        videoLayer.frame = bounds
        CATransaction.commit()
    }
}

struct DesktopNativePlayer: NSViewRepresentable {
    let surface: DesktopPlayerSurface
    func makeNSView(context: Context) -> DesktopVideoView { surface.view }
    func updateNSView(_ view: DesktopVideoView, context: Context) { }
}

struct DesktopAirPlayPicker: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.player = player
        view.isRoutePickerButtonBordered = false
        view.setRoutePickerButtonColor(.white, for: .normal)
        view.setAccessibilityLabel("AirPlay")
        return view
    }
    func updateNSView(_ view: AVRoutePickerView, context: Context) { view.player = player }
}

struct DesktopWatchPlayer: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var theater: Bool
    @State private var controlsVisible = true
    @State private var controlsHovered = false
    @State private var lastMovement = Date.now
    var fullscreenPresentation = false
    private var showControls: Bool { controlsVisible || model.playback.isPaused || model.playback.state != .playing }

    var body: some View {
        ZStack(alignment: .bottom) {
            if model.desktopFullscreen == fullscreenPresentation {
                DesktopNativePlayer(surface: model.desktopPlayerSurface)
                    .accessibilityIdentifier("player.video")
            }
            if model.playback.pictureInPictureActive {
                Label("Playing in Picture in Picture", systemImage: "pip.fill")
                    .frame(maxWidth: .infinity, maxHeight: .infinity).background(.black)
            }
            VStack(spacing: 8) {
                Spacer()
                if model.playback.currentRequest?.contentType != "live" { DesktopPlaybackTimeline() }
                controlBar
            }
            .padding(.horizontal, 12).padding(.bottom, 10).padding(.top, 65)
            .background(alignment: .bottom) {
                LinearGradient(colors: [.clear, .black.opacity(0.8)], startPoint: .top, endPoint: .bottom).frame(height: 105).allowsHitTesting(false)
            }
            .opacity(showControls ? 1 : 0).allowsHitTesting(showControls).accessibilityHidden(!showControls)
            Color.clear.contentShape(Rectangle())
                .gesture(TapGesture(count: 2).exclusively(before: TapGesture(count: 1)).onEnded { gesture in
                    switch gesture {
                    case .first: toggleFullscreen()
                    case .second: model.playback.togglePlayPause()
                    }
                    revealControls()
                })
                .padding(.bottom, model.playback.currentRequest?.contentType == "live" ? 54 : 90)
        }
        .foregroundStyle(.white).tint(.white)
        .onContinuousHover { phase in
            switch phase {
            case .active: revealControls()
            case .ended: if !model.playback.isPaused { controlsVisible = false }
            }
        }
        .task(id: lastMovement) {
            do {
                try await Task.sleep(for: .seconds(3))
                try Task.checkCancellation()
                if !controlsHovered { controlsVisible = false }
            } catch { }
        }
        .animation(reduceMotion || model.personal.data.preferences.reduceMotion ? nil : .easeOut(duration: 0.18), value: showControls)
    }
    private var controlBar: some View {
        HStack(spacing: 4) {
            control(model.playback.isPaused ? "play.fill" : "pause.fill", model.playback.isPaused ? "Play" : "Pause", "player.playPause") { model.playback.togglePlayPause() }
                .keyboardShortcut(.space, modifiers: [])
            control(model.playback.isMuted || model.desktopPlayerSurface.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill", model.playback.isMuted ? "Unmute" : "Mute", "player.mute") { model.playback.toggleMute() }
            Slider(value: Binding(get: { model.playback.isMuted ? 0 : model.desktopPlayerSurface.volume }, set: { model.desktopPlayerSurface.setVolume($0) }), in: 0...1)
                .frame(width: 72).controlSize(.small).accessibilityLabel("Volume").accessibilityIdentifier("player.volume")
            if model.playback.currentRequest?.contentType == "live" {
                Label("LIVE", systemImage: "circle.fill").font(.system(size: 10, weight: .bold)).foregroundStyle(TwitchyTheme.live).padding(.leading, 8)
            }
            Spacer(minLength: 4)
            Menu {
                Text("Quality · \(model.playback.qualityLabel)")
                Button { Task { await model.playback.changeQuality("auto") } } label: {
                    Label("Best · Auto", systemImage: model.playback.quality == "auto" ? "checkmark" : "")
                }
                ForEach(model.playback.session?.qualities.filter { $0 != "auto" } ?? [], id: \.self) { quality in
                    Button { Task { await model.playback.changeQuality(quality) } } label: {
                        Label(quality, systemImage: model.playback.quality == quality ? "checkmark" : "")
                    }
                }
            } label: { Image(systemName: "gearshape").font(.system(size: 20, weight: .semibold)).frame(width: 32, height: 32).contentShape(Rectangle()) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Quality: \(model.playback.qualityLabel)").accessibilityLabel("Playback quality").accessibilityIdentifier("player.quality")
            DesktopAirPlayPicker(player: model.playback.player).frame(width: 32, height: 32).help("AirPlay")
            if model.personal.data.preferences.pictureInPicture, AVPictureInPictureController.isPictureInPictureSupported() {
                control(model.playback.pictureInPictureActive ? "pip.exit" : "pip.enter", "Picture in Picture", "player.pip") { model.desktopPlayerSurface.togglePiP() }
                    .disabled(!model.desktopPlayerSurface.pipPossible && !model.playback.pictureInPictureActive)
            }
            control(model.personal.data.preferences.showChat && !theater ? "bubble.left.and.bubble.right.fill" : "bubble.left.and.bubble.right", model.personal.data.preferences.showChat && !theater ? "Hide chat" : "Open chat", "player.chat") {
                model.personal.data.preferences.showChat.toggle()
                if theater { theater = false; model.personal.data.preferences.showChat = true }
            }
            control(theater ? "rectangle.compress.vertical" : "rectangle.expand.vertical", theater ? "Exit theater" : "Theater", "player.theater") { theater.toggle() }
            control(model.desktopFullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right", model.desktopFullscreen ? "Exit fullscreen" : "Fullscreen", "player.fullscreen") {
                toggleFullscreen()
            }
        }
        .onHover { controlsHovered = $0; revealControls() }
    }
    private func toggleFullscreen() {
        guard let window = model.desktopPlayerSurface.view.window else { return }
        model.desktopFullscreen.toggle()
        window.toggleFullScreen(nil)
    }
    private func revealControls() { controlsVisible = true; lastMovement = .now }
    private func control(_ symbol: String, _ label: String, _ identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 15, weight: .semibold)).frame(width: 32, height: 32).contentShape(Rectangle()) }
            .buttonStyle(.plain).help(label).accessibilityLabel(label).accessibilityIdentifier(identifier)
    }
}

struct DesktopPlaybackTimeline: View {
    @Environment(AppModel.self) private var model
    @State private var scrub: Double?
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            let seconds = model.playback.player.currentTime().seconds
            let duration = model.playback.player.currentItem?.duration.seconds ?? 0
            if duration.isFinite, duration > 0 {
                HStack(spacing: 10) {
                    Text(timestamp(scrub ?? (seconds.isFinite ? seconds : 0)))
                    Slider(value: Binding(get: { scrub ?? (seconds.isFinite ? min(max(seconds, 0), duration) : 0) }, set: { scrub = $0 }), in: 0...duration) { editing in
                        if !editing, let target = scrub {
                            let item = model.playback.player.currentItem
                            model.playback.player.seek(to: CMTime(seconds: target, preferredTimescale: 600)) { _ in
                                Task { @MainActor in if model.playback.player.currentItem === item { scrub = nil } }
                            }
                        }
                    }.controlSize(.small).accessibilityLabel("Playback position")
                    Text(timestamp(duration))
                }.font(.caption.monospacedDigit())
            }
        }.onChange(of: model.playback.session?.sessionId) { _, _ in scrub = nil }
    }
    private func timestamp(_ seconds: Double) -> String {
        let value = Int(max(0, seconds))
        return value >= 3600 ? String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60) : String(format: "%d:%02d", value / 60, value % 60)
    }
}

struct DesktopNowPlayingView: View {
    @Environment(AppModel.self) private var model
    @State private var avatarURL: URL?
    var body: some View {
        if let active = model.nowPlaying {
            HStack(spacing: 8) {
                Button { model.reopenDesktopPlayback() } label: {
                    HStack(spacing: 8) {
                        RemoteImage(avatarURL, symbol: "person.crop.circle")
                            .frame(width: 32, height: 32).clipShape(Circle())
                        Text(active.selection.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).layoutPriority(1)
                    .accessibilityLabel("Open \(active.selection.name)").accessibilityIdentifier("nowPlaying.open")
                Button { model.playback.togglePlayPause() } label: {
                    Image(systemName: model.playback.isPaused ? "play.fill" : "pause.fill").frame(width: 24, height: 28)
                }.disabled(model.playback.player.currentItem == nil)
                    .accessibilityLabel(model.playback.isPaused ? "Resume stream" : "Pause stream").accessibilityIdentifier("nowPlaying.playPause")
                Button { model.playback.toggleMute() } label: {
                    Image(systemName: model.playback.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill").frame(width: 24, height: 28)
                }.accessibilityLabel(model.playback.isMuted ? "Unmute stream" : "Mute stream").accessibilityIdentifier("nowPlaying.mute")
                Button { model.stopDesktopPlayback() } label: {
                    Image(systemName: "stop.fill").frame(width: 24, height: 28)
                }.help("Stop stream").accessibilityLabel("Stop stream").accessibilityIdentifier("nowPlaying.stop")
            }.buttonStyle(.borderless)
                .accessibilityElement(children: .contain).accessibilityLabel("Now Playing")
                .contextMenu {
                    Button("Open stream") { model.reopenDesktopPlayback() }
                    Button("Stop stream", systemImage: "stop.fill") { model.stopDesktopPlayback() }
                    if model.playback.error != nil { Button("Retry playback") { Task { await model.playback.retry() } } }
                }
                .task(id: active.selection.login) {
                    avatarURL = active.selection.broadcasterID.flatMap { model.avatars[$0] }
                    guard avatarURL == nil, let api = model.api else { return }
                    do {
                        let profile = try await api.users(logins: [active.selection.login]).data.first
                        try Task.checkCancellation()
                        avatarURL = profile.flatMap { URL(string: $0.profileImageUrl) }
                    } catch { }
                }
        }
    }
}

#endif

#if os(macOS)
struct DesktopOfflineWatchView: View {
    @Environment(AppModel.self) private var model
    let item: LocalDownload
    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 18) {
                DesktopWatchPlayer(theater: Binding(get: { model.desktopTheater }, set: { model.desktopTheater = $0 }))
                    .aspectRatio(16 / 9, contentMode: .fit).background(.black)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                Text(item.displayTitle).font(.title2.bold())
                HStack {
                    Text(item.metadata?.channel ?? "Downloads").font(.headline)
                    Label("Offline", systemImage: "arrow.down.circle.fill").foregroundStyle(.secondary)
                }
                if let error = model.playback.error { Notice(error) }
                Spacer(minLength: 0)
            }.frame(maxWidth: .infinity, alignment: .leading)
            if model.personal.data.preferences.showChat && !model.desktopTheater {
                OfflineChatNotice().frame(width: 320).background(TwitchyTheme.secondary, in: RoundedRectangle(cornerRadius: 12))
            }
        }.padding(24).navigationTitle(item.displayTitle)
    }
}
#endif
