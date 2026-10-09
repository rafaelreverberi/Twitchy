import SwiftUI
import AVKit
import TwitchyAPI
import TwitchyCore
import TwitchyChat
import TwitchyDesignSystem

struct ChannelDetail: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let selection: ChannelSelection
    @State private var broadcasterID: String?
    @State private var videos: [Video] = []
    @State private var clips: [Clip] = []
    @State private var stream: TwitchStream?
    @State private var error: String?
    @State private var fullscreen = false
    @State private var attempt = 0
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 20) {
                            playerArea.frame(minWidth: 500)
                            if model.personal.data.preferences.showChat { ChatPanel(broadcasterID: broadcasterID).frame(width: 320, height: 400) }
                        }
                        VStack(spacing: 20) {
                            playerArea
                            if model.personal.data.preferences.showChat { ChatPanel(broadcasterID: broadcasterID).frame(height: 360) }
                        }
                    }
                    HStack { VStack(alignment: .leading) { Text(selection.name).font(.title.bold()); Text(stream?.title ?? "Channel details").foregroundStyle(.secondary); if let stream { Text("\(stream.gameName) · \(stream.viewerCount.formatted()) viewers").font(.caption) } }; Spacer(); Button { model.personal.favorite(selection.login) } label: { Image(systemName: model.personal.data.favorites.contains(selection.login) ? "star.fill" : "star") }.accessibilityLabel("Toggle favorite") }
                    HStack { Button("Watch live") { Task { await model.play(selection) } }.buttonStyle(.borderedProminent); Link("Follow on Twitch", destination: URL(string: "https://www.twitch.tv/\(selection.login)")!); Button("Fullscreen") { fullscreen = true }.disabled(model.playback.session == nil) }
                    if let error { Notice(error) }
                    if let error = model.error { Notice(error) }
                    if let session = model.playback.session {
                        HStack {
                            Menu("Quality: " + model.playback.quality) {
                                Button("Auto") { Task { await model.playback.changeQuality("auto") } }
                                ForEach(session.qualities.filter { $0 != "auto" }, id: \.self) { quality in Button(quality) { Task { await model.playback.changeQuality(quality) } } }
                            }
                            Button(model.playback.player.isMuted ? "Unmute" : "Mute") { model.playback.player.isMuted.toggle() }
                            Text(model.playback.state.rawValue).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if !videos.isEmpty { Text("Recent videos").font(.title2.bold()); ForEach(videos) { video in HStack { VStack(alignment: .leading) { Text(video.title); Text(video.duration).font(.caption).foregroundStyle(.secondary) }; Spacer(); Button("Watch") { Task { await model.play(selection, contentType: "vod", contentID: video.id) } }; if let url = URL(string: video.url) { Link("Twitch", destination: url) } } } }
                    if !clips.isEmpty { Text("Channel clips").font(.title2.bold()); ForEach(clips) { clip in HStack { Text(clip.title); Spacer(); Button("Watch") { Task { await model.play(selection, contentType: "clip", contentID: clip.id) } }; if let url = URL(string: clip.url) { Link("Twitch", destination: url) } } } }
                }.padding(24)
            }.navigationTitle(selection.name).toolbar { ToolbarItem { Button("Done") { dismiss() } } }
        }
        .task {
            broadcasterID = selection.broadcasterID
            do {
                guard let api = model.api else { return }
                if broadcasterID == nil { broadcasterID = try await api.users(logins: [selection.login]).data.first?.id }
                stream = try await api.streams(login: selection.login).data.first
                if let id = broadcasterID { async let v = api.videos(userID: id); async let c = api.clips(broadcasterID: id); videos = try await v.data; clips = try await c.data }
                if let type = selection.contentType, let id = selection.contentID {
                    await model.play(selection, contentType: type, contentID: id)
                    await model.playback.player.seek(to: CMTime(seconds: selection.resumePosition, preferredTimescale: 600))
                } else if model.personal.data.preferences.autoplay { await model.play(selection) }
            } catch is CancellationError { }
            catch { self.error = error.localizedDescription }
        }
        .task(id: model.playback.session?.sessionId) {
            while model.playback.session != nil && !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(10)); try Task.checkCancellation(); savePosition() } catch { return }
            }
        }
        .onDisappear { savePosition(); model.chat.disconnect(); if !model.playback.pictureInPictureActive { Task { await model.playback.stop() } } }
        .onChange(of: model.playback.state) { _, state in
            if state == .failed, model.personal.data.preferences.retryPlayback, attempt < 2 { attempt += 1; Task { try? await Task.sleep(for: .seconds(2 * attempt)); guard !Task.isCancelled else { return }; await model.playback.retry() } }
        }
        .sheet(isPresented: $fullscreen) { nativePlayer.frame(minWidth: 300, minHeight: 240) }
        #if os(macOS)
        .frame(minWidth: 800, minHeight: 720)
        #endif
    }
    private var nativePlayer: some View {
        NativePlayer(player: model.playback.player, pictureInPicture: model.personal.data.preferences.pictureInPicture) { active in
            model.playback.pictureInPictureActive = active
            if !active, model.selectedChannel == nil { Task { await model.playback.stop() } }
        }
    }
    private func savePosition() {
        guard let request = model.playback.currentRequest, request.contentType != "live", let id = request.contentId else { return }
        let seconds = model.playback.player.currentTime().seconds
        if seconds.isFinite && seconds > 0 { model.personal.watched(.init(login: selection.login, title: selection.name, position: seconds, contentType: request.contentType, contentID: id)) }
    }
    private var playerArea: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12).fill(.black)
            if model.playback.session != nil { nativePlayer }
            else { VStack(spacing: 12) { Image(systemName: "play.rectangle").font(.largeTitle).foregroundStyle(TwitchyTheme.accent); Text(model.sources.active == nil ? "A streaming source is required" : "Ready when you are").font(.headline); Text(model.sources.active?.name ?? "Configure a source in Profile → Settings").font(.caption).foregroundStyle(.secondary) } }
            if model.playback.state == .loading || model.playback.state == .buffering { ProgressView().padding().background(.black.opacity(0.7), in: Capsule()) }
            if model.playback.state == .adBreak || model.playback.state == .pausedByServer { Text("Playback paused by your source").padding().background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 10)) }
            if let error = model.playback.error { VStack { Notice(error); Button("Retry playback") { attempt = 0; Task { await model.playback.retry() } } }.padding(20) }
        }.foregroundStyle(.white).aspectRatio(16 / 9, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
#if os(macOS)
struct NativePlayer: NSViewRepresentable {
    var player: AVPlayer; var pictureInPicture: Bool; var onPictureInPictureChange: (Bool) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onPictureInPictureChange) }
    func makeNSView(context: Context) -> AVPlayerView { let view = AVPlayerView(); view.player = player; view.controlsStyle = .inline; view.showsFullScreenToggleButton = true; view.allowsPictureInPicturePlayback = pictureInPicture; view.pictureInPictureDelegate = context.coordinator; return view }
    func updateNSView(_ view: AVPlayerView, context: Context) { view.player = player; view.allowsPictureInPicturePlayback = pictureInPicture }
    final class Coordinator: NSObject, AVPlayerViewPictureInPictureDelegate {
        let changed: (Bool) -> Void
        init(_ changed: @escaping (Bool) -> Void) { self.changed = changed }
        func playerViewWillStartPicture(inPicture playerView: AVPlayerView) { changed(true) }
        func playerViewDidStopPicture(inPicture playerView: AVPlayerView) { changed(false) }
        func playerView(_ playerView: AVPlayerView, failedToStartPictureInPictureWithError error: Error) { changed(false) }
        func playerViewShouldAutomaticallyDismissAtPicture(inPictureStart playerView: AVPlayerView) -> Bool { false }
    }
}
#else
struct NativePlayer: UIViewControllerRepresentable {
    var player: AVPlayer; var pictureInPicture: Bool; var onPictureInPictureChange: (Bool) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onPictureInPictureChange) }
    func makeUIViewController(context: Context) -> AVPlayerViewController { let view = AVPlayerViewController(); view.player = player; view.allowsPictureInPicturePlayback = pictureInPicture; view.delegate = context.coordinator; return view }
    func updateUIViewController(_ view: AVPlayerViewController, context: Context) { view.player = player; view.allowsPictureInPicturePlayback = pictureInPicture }
    final class Coordinator: NSObject, AVPlayerViewControllerDelegate {
        let changed: (Bool) -> Void
        init(_ changed: @escaping (Bool) -> Void) { self.changed = changed }
        func playerViewControllerWillStartPictureInPicture(_ playerViewController: AVPlayerViewController) { changed(true) }
        func playerViewControllerDidStopPictureInPicture(_ playerViewController: AVPlayerViewController) { changed(false) }
        func playerViewController(_ playerViewController: AVPlayerViewController, failedToStartPictureInPictureWithError error: Error) { changed(false) }
        func playerViewControllerShouldAutomaticallyDismissAtPictureInPictureStart(_ playerViewController: AVPlayerViewController) -> Bool { false }
    }
}
#endif
struct ChatPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let broadcasterID: String?
    @State private var text = ""
    @State private var follow = true
    @State private var sending = false
    @State private var receivedAt: [String: Date] = [:]
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("Chat").font(.title2.bold()); Spacer(); Text(model.chat.status).font(.caption).foregroundStyle(.secondary) }
            if model.auth.session?.scopes.contains("user:read:chat") != true {
                Text("Connect with chat permissions to join this channel.").foregroundStyle(.secondary)
                Button("Authorize chat") { Task { await model.login(chat: true) } }
            } else {
                if let error = model.chat.error { Notice(error) }
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(model.chat.messages) { message in HStack(alignment: .top, spacing: 5) {
                                if model.personal.data.preferences.timestamps { Text((receivedAt[message.id] ?? .now).formatted(date: .omitted, time: .shortened)).font(.caption2).foregroundStyle(.secondary) }
                                ForEach(message.badges, id: \.setId) { badge in if let url = model.chat.badgeImages["\(badge.setId)/\(badge.id)"] { AsyncImage(url: url) { image in image.resizable().scaledToFit() } placeholder: { Color.clear }.frame(width: 18, height: 18).accessibilityLabel(badge.setId) } }
                                Text(message.chatterUserName).bold().foregroundStyle(chatColor(message.color))
                                if model.personal.data.preferences.emotes { MessageFragments(message: message) } else { Text(message.message.text) }
                            }.font(.system(size: model.personal.data.preferences.chatFontSize)).id(message.id) }
                        }.padding(.vertical, 8)
                    }
                    #if os(tvOS)
                    .onMoveCommand { _ in follow = false }
                    #else
                    .simultaneousGesture(DragGesture().onChanged { _ in follow = false })
                    #endif
                    .onChange(of: model.chat.messages.last?.id) { _, _ in
                        for message in model.chat.messages where receivedAt[message.id] == nil { receivedAt[message.id] = .now }
                        let retained = Set(model.chat.messages.map(\.id)); receivedAt = receivedAt.filter { retained.contains($0.key) }
                        if follow, model.personal.data.preferences.autoscroll, let last = model.chat.messages.last { if reduceMotion || model.personal.data.preferences.reduceMotion { proxy.scrollTo(last.id, anchor: .bottom) } else { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(last.id, anchor: .bottom) } } }
                    }
                    Button("Jump to latest") { follow = true; if let last = model.chat.messages.last { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
                HStack { TextField("Send a message", text: $text).onSubmit { send() }.accessibilityIdentifier("chat.input"); Button { send() } label: { Image(systemName: "paperplane.fill") }.disabled(text.isEmpty || sending || model.chat.status != "Connected").accessibilityLabel("Send message") }
            }
        }.padding(16).background(TwitchyTheme.secondary, in: RoundedRectangle(cornerRadius: 12))
        .task(id: (broadcasterID ?? "") + (model.auth.session?.accessToken ?? "")) {
            guard let id = broadcasterID, let api = model.api, let session = model.auth.session, session.scopes.contains("user:read:chat") else { return }
            model.chat.connect(api: api, broadcasterID: id, userID: session.userID)
        }.onDisappear { model.chat.disconnect() }
    }
    private func send() { guard let id = broadcasterID, let api = model.api, let session = model.auth.session else { return }; sending = true; Task { if await model.chat.send(api: api, broadcasterID: id, userID: session.userID, text: text) { text = "" }; sending = false } }
    private func chatColor(_ value: String) -> Color { guard let hex = UInt32(value.replacingOccurrences(of: "#", with: ""), radix: 16) else { return TwitchyTheme.highlight }; return Color(hex: hex) }
}
struct MessageFragments: View {
    var message: TwitchyChat.ChatMessage
    var body: some View {
        // Fragment images remain in a horizontal flow; text keeps native Unicode shaping.
        HStack(alignment: .top, spacing: 2) { ForEach(Array(message.message.fragments.enumerated()), id: \.offset) { _, fragment in if let emote = fragment.emote { AsyncImage(url: URL(string: "https://static-cdn.jtvnw.net/emoticons/v2/\(emote.id)/default/dark/1.0")) { image in image.resizable().scaledToFit() } placeholder: { Text(fragment.text) }.frame(width: 28, height: 28).accessibilityLabel(fragment.text) } else { Text(fragment.text).fixedSize(horizontal: false, vertical: true) } } }
    }
}

#Preview { ChannelDetail(selection: .init(login: "preview", name: "Preview channel")).environment(AppModel()) }
