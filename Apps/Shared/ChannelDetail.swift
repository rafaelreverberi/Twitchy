import SwiftUI
import AVKit
import TwitchyAPI
import TwitchyCore
import TwitchyChat
import TwitchyDesignSystem
import TwitchyPlayback

struct ChannelDetail: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let selection: ChannelSelection
    @State private var broadcasterID: String?
    @State private var videos: [Video] = []
    @State private var clips: [Clip] = []
    @State private var stream: TwitchStream?
    @State private var error: String?
    @State private var downloadNotice: String?
    @State private var fullscreen = false
    @State private var attempt = 0
    #if os(macOS)
    @State private var watching = false
    private var theater: Bool { get { model.desktopTheater } nonmutating set { model.desktopTheater = newValue } }
    @State private var profile: TwitchUser?
    @State private var channelInfo: ChannelInfo?
    @State private var library = "Recent videos"
    @State private var archives: [Video] = []
    @State private var videoCursor: String?
    @State private var archiveCursor: String?
    @State private var clipCursor: String?
    @State private var metadataLoading = true
    @State private var libraryLoading = false
    @State private var libraryOrder = VideoSort.recent
    @State private var libraryError: String?
    @State private var libraryGeneration = UUID()
    @State private var recentClipBefore: Date?
    @State private var recentClipSince = Date.now
    @State private var libraryLoaded = false
    @State private var playingTitle: String?
    #endif
    var body: some View {
        Group {
            #if os(macOS)
            macContent
            #elseif os(iOS)
            MobileChannelView(selection: selection)
            #else
            legacyContent
            #endif
        }
        #if !os(iOS)
        .task { await loadMetadata() }
        #endif
        .task(id: selection.id) {
            #if os(macOS)
            if selection.returnToPlayback, let active = model.nowPlaying, active.selection.id == selection.id {
                watching = true; playingTitle = active.title
            } else if let type = selection.contentType, let id = selection.contentID {
                watching = true
                model.startDesktopPlayback(selection, type: type, contentID: id)
            }
            #elseif os(iOS)
            // iOS channel and player lifecycle are owned by MobileRootView.
            #elseif os(iOS)
            if selection.contentID != nil || model.personal.data.preferences.autoplay {
                mobilePlay(type: selection.contentType ?? "live", id: selection.contentID)
                await mobilePlaybackTask?.value
                if selection.resumePosition > 0 { await model.playback.player.seek(to: CMTime(seconds: selection.resumePosition, preferredTimescale: 600)) }
            }
            #else
            if let type = selection.contentType, let id = selection.contentID {
                await model.play(selection, contentType: type, contentID: id)
                await model.playback.player.seek(to: CMTime(seconds: selection.resumePosition, preferredTimescale: 600))
            } else if model.personal.data.preferences.autoplay { await model.play(selection) }
            #endif
        }
        #if os(tvOS)
        .task(id: model.playback.session?.sessionId) {
            while model.playback.session != nil && !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(10)); try Task.checkCancellation(); savePosition() } catch { return }
            }
        }
        #endif
        .onDisappear {
            savePosition()
            #if !os(iOS)
            model.chat.disconnect()
            #endif
            #if os(tvOS)
            if !model.playback.pictureInPictureActive { Task { await model.playback.stop() } }
            #endif
        }
        #if os(tvOS)
        .onChange(of: model.playback.state) { _, state in
            if state == .failed, model.personal.data.preferences.retryPlayback, attempt < 2 { attempt += 1; Task { try? await Task.sleep(for: .seconds(2 * attempt)); guard !Task.isCancelled else { return }; await model.playback.retry() } }
        }
        #endif
        #if !os(iOS)
        .sheet(isPresented: $fullscreen) {
            #if os(macOS)
            NativePlayer(player: model.playback.player, pictureInPicture: false) { _ in }.frame(minWidth: 800, minHeight: 450)
            #else
            nativePlayer.frame(minWidth: 300, minHeight: 240)
            #endif
        }
        #endif
    }
    private var legacyContent: some View {
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
                    HStack { VStack(alignment: .leading) { Text(selection.name).font(.title.bold()); Text(stream?.title ?? "Channel details").foregroundStyle(.secondary); if let stream { Text("\(stream.gameName) · \(stream.viewerCount.formatted()) viewers").font(.caption) } } }
                    HStack { Button("Watch live") { Task { await model.play(selection) } }.buttonStyle(.borderedProminent); Button("Fullscreen") { fullscreen = true }.disabled(model.playback.session == nil) }
                    if let downloadNotice { Text(downloadNotice).foregroundStyle(.secondary) }
                    if let error { Notice(error) }
                    if let error = model.error { Notice(error) }
                    if let session = model.playback.session {
                        HStack {
                            Menu("Quality: " + model.playback.qualityLabel) {
                                Button("Best") { Task { await model.playback.changeQuality("auto") } }
                                ForEach(session.qualities.filter { $0 != "auto" }, id: \.self) { quality in Button(quality) { Task { await model.playback.changeQuality(quality) } } }
                            }
                            Button(model.playback.isMuted ? "Unmute" : "Mute") { model.playback.toggleMute() }
                            Text(model.playback.state.rawValue).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if !videos.isEmpty { Text("Recent videos").font(.title2.bold()); ForEach(videos) { video in HStack { VStack(alignment: .leading) { Text(video.title); Text(video.duration).font(.caption).foregroundStyle(.secondary) }; Spacer(); Button("Watch") { Task { await model.play(selection, contentType: "vod", contentID: video.id) } }; downloadButton(type: "vod", id: video.id, title: video.title, thumbnail: video.thumbnailUrl, duration: video.duration); if let url = URL(string: video.url) { Link("Twitch", destination: url) } } } }
                    if !clips.isEmpty { Text("Channel clips").font(.title2.bold()); ForEach(clips) { clip in HStack { Text(clip.title); Spacer(); Button("Watch") { Task { await model.play(selection, contentType: "clip", contentID: clip.id) } }; downloadButton(type: "clip", id: clip.id, title: clip.title, thumbnail: clip.thumbnailUrl); if let url = URL(string: clip.url) { Link("Twitch", destination: url) } } } }
                }.padding(24)
            }.navigationTitle(selection.name).toolbar { ToolbarItem { Button("Done") { dismiss() } } }
        }
    }
    private func loadMetadata() async {
        broadcasterID = selection.broadcasterID
        #if os(macOS)
        defer { metadataLoading = false }
        #else
        if let id = model.sources.activeID { await model.sources.test(id) }
        #endif
        do {
            guard let api = model.api else { return }
            #if os(macOS)
            profile = try await api.users(logins: [selection.login]).data.first
            broadcasterID = profile?.id ?? broadcasterID
            #else
            if broadcasterID == nil { broadcasterID = try await api.users(logins: [selection.login]).data.first?.id }
            #endif
            stream = try await api.streams(login: selection.login).data.first
            if let id = broadcasterID {
                #if os(macOS)
                do { channelInfo = try await api.channel(id: id).data.first } catch { self.error = error.localizedDescription }
                #else
                async let v = api.videos(userID: id); async let c = api.clips(broadcasterID: id)
                videos = try await v.data; clips = try await c.data
                #endif
            }
        } catch is CancellationError { }
        catch { self.error = error.localizedDescription }
    }
    @ViewBuilder private func downloadButton(type: String, id: String, title: String? = nil, thumbnail: String? = nil, duration: String? = nil) -> some View {
        #if !os(tvOS)
        if model.sources.active?.capabilities?.clientSideDownloads == true {
            Button("Download") { Task {
                do { let client = try model.sources.client(); await model.downloads.enqueue(client: client, type: type, contentID: id, quality: model.personal.data.preferences.preferredQuality, metadata: .init(title: title ?? selection.name, channel: selection.name, thumbnailURL: thumbnail.flatMap { URL(string: $0.replacingOccurrences(of: "%{width}", with: "320").replacingOccurrences(of: "%{height}", with: "180")) }, duration: duration)); downloadNotice = model.downloads.error ?? "Download added. See Downloads for progress and offline playback." }
                catch { downloadNotice = error.localizedDescription }
            } }
        }
        #endif
    }
    @ViewBuilder private var nativePlayer: some View {
        #if os(macOS)
        DesktopWatchPlayer(theater: Binding(get: { theater }, set: { theater = $0 }))
        #else
        NativePlayer(player: model.playback.player, pictureInPicture: model.personal.data.preferences.pictureInPicture) { active in
            model.playback.pictureInPictureActive = active
            if !active, model.selectedChannel == nil { Task { await model.playback.stop() } }
        }
        #endif
    }
    private func savePosition() {
        #if os(macOS)
        model.saveDesktopPosition()
        #else
        guard let request = model.playback.currentRequest, request.contentType != "live", let id = request.contentId else { return }
        let seconds = model.playback.player.currentTime().seconds
        if seconds.isFinite && seconds > 0 { model.personal.watched(.init(login: selection.login, title: selection.name, position: seconds, contentType: request.contentType, contentID: id)) }
        #endif
    }
    private var playerArea: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12).fill(.black)
            if model.playback.session != nil { nativePlayer }
            else { VStack(spacing: 12) { Image(systemName: "play.rectangle").font(.largeTitle).foregroundStyle(TwitchyTheme.accent); Text(model.playback.state == .loading ? "Starting stream…" : model.sources.active == nil ? "A streaming source is required" : "Ready when you are").font(.headline); Text(model.sources.active?.name ?? "Configure a source in Profile → Settings").font(.caption).foregroundStyle(.secondary) } }
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
            HStack {
                #if os(macOS)
                Label("Stream chat", systemImage: "bubble.left.and.bubble.right").font(.headline)
                #else
                Text("Chat").font(.title2.bold())
                #endif
                Spacer(); Text(model.chat.status).font(.caption).foregroundStyle(.secondary)
            }
            #if os(macOS)
            Divider()
            if model.playback.currentRequest?.contentType != "live" { Text("Live channel chat · no replay").font(.caption).foregroundStyle(.secondary) }
            #endif
            if model.isOfflinePlayback { OfflineChatNotice() } else if model.auth.session?.scopes.contains("user:read:chat") != true {
                Text("Connect with chat permissions to join this channel.").foregroundStyle(.secondary)
                Button("Authorize chat") { Task { await model.login(chat: true) } }
            } else {
                if let error = model.chat.error { Notice(error) }
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(model.chat.messages) { message in
                                #if os(macOS)
                                MacChatMessage(message: message, timestamp: receivedAt[message.id] ?? .now).id(message.id)
                                #else
                                HStack(alignment: .top, spacing: 5) {
                                if model.personal.data.preferences.timestamps { Text((receivedAt[message.id] ?? .now).formatted(date: .omitted, time: .shortened)).font(.caption2).foregroundStyle(.secondary) }
                                ForEach(message.badges, id: \.setId) { badge in if let url = model.chat.badgeImages["\(badge.setId)/\(badge.id)"] { AsyncImage(url: url) { image in image.resizable().scaledToFit() } placeholder: { Color.clear }.frame(width: 18, height: 18).accessibilityLabel(badge.setId) } }
                                Text(message.chatterUserName).bold().foregroundStyle(chatColor(message.color))
                                if model.personal.data.preferences.emotes { MessageFragments(message: message) } else { Text(message.message.text) }
                                }.font(.system(size: model.personal.data.preferences.chatFontSize)).id(message.id)
                                #endif
                            }
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
                    #if os(macOS)
                    if !follow { Button("Jump to latest") { follow = true; if let last = model.chat.messages.last { proxy.scrollTo(last.id, anchor: .bottom) } } }
                    #else
                    Button("Jump to latest") { follow = true; if let last = model.chat.messages.last { proxy.scrollTo(last.id, anchor: .bottom) } }
                    #endif
                }
                #if os(iOS)
                Spacer(minLength: 0)
                #endif
                HStack { TextField("Send a message", text: $text).onSubmit { send() }.accessibilityIdentifier("chat.input"); Button { send() } label: { Image(systemName: "paperplane.fill") }.disabled(text.isEmpty || sending || model.chat.status != "Connected").accessibilityLabel("Send message") }
            }
        }
        #if os(iOS)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        #endif
        .padding(16)
        #if os(iOS)
        .background(TwitchyTheme.secondary)
        #else
        .background(TwitchyTheme.secondary, in: RoundedRectangle(cornerRadius: 12))
        #endif
        .task(id: (broadcasterID ?? "") + (model.auth.session?.accessToken ?? "")) {
            guard !model.isOfflinePlayback, let id = broadcasterID, let api = model.api, let session = model.auth.session, session.scopes.contains("user:read:chat") else { return }
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

#if os(macOS)
extension ChannelDetail {
    private var macContent: some View {
        GeometryReader { geometry in
            HStack(alignment: .top, spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        if watching { desktopPlayer; desktopIdentity }
                        else { channelHero; channelActions; aboutChannel }
                        if let error { Notice(error) }
                        if let error = model.error { Notice(error) }
                        if let downloadNotice { Notice(downloadNotice) }
                        if !theater { desktopLibrary }
                    }.padding(theater ? 16 : 28).frame(maxWidth: .infinity, alignment: .leading)
                }
                if watching && model.personal.data.preferences.showChat && !theater {
                    ChatPanel(broadcasterID: broadcasterID)
                        .frame(width: geometry.size.width > 1100 ? 320 : 280)
                        .frame(maxHeight: .infinity).padding(.vertical, 20).padding(.trailing, 20)
                }
            }
        }
        .background(TwitchyTheme.background)
        .task(id: "\(broadcasterID ?? "")|\(library)|\(libraryOrder.rawValue)") { await reloadLibrary() }
        .onChange(of: model.nowPlaying?.id) { _, id in if id == nil { watching = false; theater = false } }
        .navigationTitle(selection.name)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    if watching {
                        showDesktopChannel()
                    } else { model.selectedChannel = nil }
                } label: { Label(watching ? "Channel" : "Back", systemImage: "chevron.left") }
                .accessibilityIdentifier("channel.back")
            }
        }
    }
    private var channelHero: some View {
        VStack(alignment: .leading, spacing: 0) {
            GeometryReader { geometry in
                ZStack(alignment: .bottomLeading) {
                    LinearGradient(colors: [TwitchyTheme.accent.opacity(0.65), TwitchyTheme.elevated, TwitchyTheme.background], startPoint: .topLeading, endPoint: .bottomTrailing)
                    if let stream {
                        RemoteImage(stream.thumbnail).frame(width: geometry.size.width, height: 210)
                    } else if let value = profile?.offlineImageUrl, !value.isEmpty, let url = URL(string: value) {
                        RemoteImage(url).frame(width: geometry.size.width, height: 210)
                    }
                    LinearGradient(colors: [.clear, .black.opacity(0.72)], startPoint: .top, endPoint: .bottom)
                    HStack { Label(stream == nil ? "OFFLINE" : "NOW LIVE", systemImage: stream == nil ? "moon" : "dot.radiowaves.left.and.right").font(.caption.bold()).tracking(2); Spacer(); Text("twitch.tv/\(selection.login)").font(.caption) }
                        .foregroundStyle(.white).padding(24)
                }.clipShape(RoundedRectangle(cornerRadius: 18))
            }.frame(height: 210)
            desktopIdentity.padding(.top, 22)
        }
    }
    private var desktopIdentity: some View {
        HStack(alignment: .top, spacing: 16) {
            Group {
                if watching {
                    Button { showDesktopChannel() } label: { desktopAvatar }
                        .buttonStyle(.plain).help("View channel")
                        .accessibilityLabel("View \(profile?.displayName ?? selection.name)'s channel")
                        .accessibilityIdentifier("player.channelAvatar")
                } else { desktopAvatar }
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    if watching {
                        Button { showDesktopChannel() } label: {
                            Text(profile?.displayName ?? selection.name).font(.title2.bold()).foregroundStyle(.primary)
                        }.buttonStyle(.plain).help("View channel").accessibilityIdentifier("player.channelName")
                    } else { Text(profile?.displayName ?? selection.name).font(.largeTitle.bold()) }
                    if stream != nil && (!watching || model.playback.currentRequest?.contentType == "live") { MacLiveBadge() }
                    Spacer()

                }
                Text(watching ? (playingTitle ?? stream?.title ?? channelInfo?.title ?? "Stream playback") : (stream?.title ?? channelInfo?.title ?? "Welcome to the channel"))
                    .font(.headline).lineLimit(2)
                HStack(spacing: 10) {
                    let game = stream?.gameName ?? channelInfo?.gameName ?? ""
                    if !game.isEmpty { Text(game).font(.caption).padding(.horizontal, 10).padding(.vertical, 6).background(TwitchyTheme.elevated, in: Capsule()) }
                    if let stream, !watching || model.playback.currentRequest?.contentType == "live" { Label("\(stream.viewerCount.formatted()) viewers", systemImage: "person.2").font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
    }
    private var desktopAvatar: some View {
        RemoteImage(URL(string: profile?.profileImageUrl ?? ""), symbol: "person.crop.circle")
            .frame(width: watching ? 62 : 82, height: watching ? 62 : 82).clipShape(Circle())
            .overlay { Circle().strokeBorder(TwitchyTheme.accent.opacity(0.7), lineWidth: 3) }
    }
    private func showDesktopChannel() {
        savePosition()
        watching = false
        theater = false
    }
    private var channelActions: some View {
        HStack(spacing: 12) {
            if stream != nil {
                Button { startWatching() } label: { Label("Watch live", systemImage: "play.fill").padding(.horizontal, 12).padding(.vertical, 5) }
                    .buttonStyle(.borderedProminent).accessibilityIdentifier("channel.watchLive")
            } else if metadataLoading { ProgressView("Loading channel…") }
            else { Label("Currently offline", systemImage: "moon").foregroundStyle(.secondary) }
            ShareLink(item: channelURL) { Label("Share", systemImage: "square.and.arrow.up") }.buttonStyle(.bordered)
            Spacer()
        }
    }
    private var aboutChannel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("About \(profile?.displayName ?? selection.name)").font(.title2.bold())
            Text(profile?.description.isEmpty == false ? profile!.description : "This channel hasn't added a description yet.")
                .foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }.padding(22).frame(maxWidth: .infinity, alignment: .leading).macSurface()
    }
    private var channelURL: URL { URL(string: "https://www.twitch.tv/\(selection.login)")! }
    private var desktopPlayer: some View {
        VStack(spacing: 0) {
            playerArea
            if model.playback.session == nil && model.playback.state != .loading {
                HStack {
                    Text(model.sources.active == nil ? "Connect a source to watch this stream." : "Start playback when you're ready.").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    if model.sources.active == nil {
                        Button("Configure source") { model.showingSettings = true }.buttonStyle(.borderedProminent)
                    } else {
                        Button("Retry") { startWatching(type: model.playback.currentRequest?.contentType ?? selection.contentType ?? "live", id: model.playback.currentRequest?.contentId ?? selection.contentID, title: playingTitle) }.buttonStyle(.borderedProminent)
                    }
                }.padding(.top, 14)
            }
        }
    }
    private var desktopLibrary: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(watching ? "More from \(selection.name)" : "Channel library").font(.title2.bold())
                Spacer()
                if metadataLoading || libraryLoading { ProgressView().controlSize(.small) }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 22) { libraryTabs; librarySortMenu }
                VStack(alignment: .leading, spacing: 14) { libraryTabs; librarySortMenu }
            }
            if library == "Clips" {
                Text(libraryOrder == .recent ? "Newest clips · Last 30 days" : "Most viewed clips · All time")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let libraryError { Notice(libraryError); Button("Retry") { Task { await reloadLibrary() } }.disabled(libraryLoading) }
            if library == "Clips" {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: watching ? 220 : 260), spacing: 18)], alignment: .leading, spacing: 22) {
                    ForEach(clips) { clip in
                        libraryCard(title: clip.title, thumbnail: clip.thumbnailUrl, badge: clip.duration.map { clipDuration($0) } ?? "CLIP", detail: clipDetail(clip), type: "clip", id: clip.id, url: clip.url)
                    }
                }
            } else {
                let items = library == "Past broadcasts" ? archives : videos
                LazyVGrid(columns: [GridItem(.adaptive(minimum: watching ? 220 : 260), spacing: 18)], alignment: .leading, spacing: 22) {
                    ForEach(items) { video in
                        libraryCard(title: video.title, thumbnail: video.thumbnailUrl, badge: video.duration, detail: videoDetail(video), type: "vod", id: video.id, url: video.url)
                    }
                }
            }
            if libraryLoaded && !libraryLoading && libraryError == nil && (library == "Clips" ? clips.isEmpty : library == "Past broadcasts" ? archives.isEmpty : videos.isEmpty) {
                EmptyState("No \(library.lowercased()) available", detail: library == "Clips" && libraryOrder == .recent ? "No clips were created in the last 30 days. Try Most viewed for older highlights." : "Published videos and clips will appear here when Twitch makes them available.")
            }
            if (library == "Clips" ? (libraryOrder == .recent ? recentClipBefore.map { _ in "recent" } : clipCursor) : library == "Past broadcasts" ? archiveCursor : videoCursor) != nil {
                Button("Load more") { Task { await moreLibrary() } }.buttonStyle(.bordered).disabled(libraryLoading)
            }
        }
    }
    private func libraryCard(title: String, thumbnail: String, badge: String, detail: String, type: String, id: String, url: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Button { startWatching(type: type, id: id, title: title) } label: {
                VStack(alignment: .leading, spacing: 10) {
                    Color.clear.aspectRatio(16 / 9, contentMode: .fit).overlay { RemoteImage(URL(string: thumbnail.replacingOccurrences(of: "%{width}", with: "320").replacingOccurrences(of: "%{height}", with: "180").replacingOccurrences(of: "{width}", with: "320").replacingOccurrences(of: "{height}", with: "180"))) }
                        .overlay(alignment: .bottomLeading) { Text(badge).font(.caption.bold()).foregroundStyle(.white).padding(6).background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 5)).padding(10) }
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(alignment: .topTrailing) {
                            Image(systemName: "play.fill").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                                .frame(width: 32, height: 32).background(.black.opacity(0.6), in: Circle()).padding(10)
                        }
                    Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading).frame(height: 40, alignment: .topLeading)
                }
            }.buttonStyle(DesktopLibraryButtonStyle()).accessibilityLabel("Watch \(title)")
            HStack {
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Menu {
                    Button("Watch") { startWatching(type: type, id: id, title: title) }
                    downloadButton(type: type, id: id, title: title, thumbnail: thumbnail, duration: badge)
                    if let url = URL(string: url) { Link("Open on Twitch", destination: url) }
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel("Options for \(title)")
            }
        }.padding(12).background(TwitchyTheme.secondary, in: RoundedRectangle(cornerRadius: 16))
    }
    private func videoDetail(_ video: Video) -> String {
        var parts: [String] = []
        if let views = video.viewCount { parts.append("\(views.formatted()) \(views == 1 ? "view" : "views")") }
        if let value = video.createdAt, let date = ISO8601DateFormatter().date(from: value) { parts.append(date.formatted(.relative(presentation: .named))) }
        return parts.isEmpty ? selection.name : parts.joined(separator: " · ")
    }
    private func startWatching(type: String = "live", id: String? = nil, title: String? = nil) {
        savePosition(); watching = true; playingTitle = title; attempt = 0; model.error = nil
        if let active = model.nowPlaying, model.playback.session != nil, active.selection.login == selection.login, active.selection.contentType == type, active.selection.contentID == id {
            playingTitle = active.title
        } else {
            model.startDesktopPlayback(selection, type: type, contentID: id, title: title ?? stream?.title, thumbnail: stream?.thumbnail)
        }
    }
    private var libraryTabs: some View {
        HStack(spacing: 4) {
            ForEach(["Recent videos", "Past broadcasts", "Clips"], id: \.self) { tab in
                Button { library = tab } label: {
                    Text(tab).font(.subheadline.weight(.semibold)).lineLimit(1)
                        .foregroundStyle(library == tab ? .primary : .secondary)
                        .padding(.horizontal, 14).padding(.vertical, 12).frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                        .background(library == tab ? TwitchyTheme.elevated : .clear, in: RoundedRectangle(cornerRadius: 9))
                        .overlay(alignment: .bottom) { Capsule().fill(library == tab ? TwitchyTheme.accent : .clear).frame(height: 3).padding(.horizontal, 14) }
                }.buttonStyle(.plain).accessibilityValue(library == tab ? "Selected" : "")
                    .accessibilityIdentifier("channel.library.\(tab)")
            }
        }.padding(4).background(TwitchyTheme.secondary, in: RoundedRectangle(cornerRadius: 12)).accessibilityElement(children: .contain).accessibilityLabel("Channel library").accessibilityIdentifier("channel.library")
    }
    private var librarySortMenu: some View {
        Menu {
            Picker("Sort by", selection: $libraryOrder) {
                Text("Most recent").tag(VideoSort.recent)
                Text("Most viewed").tag(VideoSort.views)
            }.pickerStyle(.inline)
        } label: {
            Label(libraryOrder == .recent ? "Most recent" : "Most viewed", systemImage: "arrow.up.arrow.down")
                .font(.subheadline.weight(.medium)).padding(.vertical, 8)
        }.fixedSize().accessibilityLabel("Sort library").accessibilityIdentifier("channel.library.sort")
    }
    private func clipDuration(_ duration: Double) -> String {
        guard duration.isFinite, duration >= 0, duration < Double(Int.max) else { return "CLIP" }
        let seconds = Int(duration.rounded())
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
    private func clipDetail(_ clip: Clip) -> String {
        var parts: [String] = []
        if let views = clip.viewCount { parts.append("\(views.formatted()) \(views == 1 ? "view" : "views")") }
        if clip.creationDate != .distantPast { parts.append(clip.creationDate.formatted(.relative(presentation: .named))) }
        return parts.isEmpty ? clip.broadcasterName : parts.joined(separator: " · ")
    }
    private func sortedVideos(_ items: [Video]) -> [Video] {
        items.sorted { left, right in
            if libraryOrder == .views, left.viewCount != right.viewCount { return (left.viewCount ?? 0) > (right.viewCount ?? 0) }
            if left.createdAt != right.createdAt { return (left.createdAt ?? "") > (right.createdAt ?? "") }
            return left.id < right.id
        }
    }
    private func reloadLibrary() async {
        let generation = UUID(); libraryGeneration = generation
        libraryLoading = true; libraryLoaded = false; libraryError = nil
        defer { if libraryGeneration == generation { libraryLoading = false } }
        clips = []; archives = []; videos = []
        clipCursor = nil; archiveCursor = nil; videoCursor = nil; recentClipBefore = nil
        guard let api = model.api, let id = broadcasterID else { return }
        let tab = library, order = libraryOrder
        do {
            if tab == "Clips" {
                if order == .recent {
                    // Freeze the upper boundary so Load more cannot skip or duplicate new clips.
                    let end = Date(timeIntervalSince1970: floor(Date.now.timeIntervalSince1970))
                    let since = end.addingTimeInterval(-30 * 86400)
                    let page = try await api.recentClips(broadcasterID: id, since: since, before: end)
                    try Task.checkCancellation(); guard generation == libraryGeneration else { return }
                    clips = page.data; recentClipBefore = page.nextBefore; recentClipSince = since
                } else {
                    let page = try await api.clips(broadcasterID: id)
                    try Task.checkCancellation(); guard generation == libraryGeneration else { return }
                    clips = page.data; clipCursor = page.pagination?.cursor
                }
            } else {
                let page = try await api.videos(userID: id, type: tab == "Past broadcasts" ? "archive" : nil, sort: order)
                try Task.checkCancellation(); guard generation == libraryGeneration else { return }
                if tab == "Past broadcasts" { archives = sortedVideos(page.data); archiveCursor = page.pagination?.cursor }
                else { videos = sortedVideos(page.data); videoCursor = page.pagination?.cursor }
            }
            libraryLoaded = true
        } catch is CancellationError { }
        catch { if generation == libraryGeneration && !Task.isCancelled { libraryError = error.localizedDescription } }
    }
    private func moreLibrary() async {
        guard !libraryLoading, let api = model.api, let id = broadcasterID else { return }
        let generation = libraryGeneration, tab = library, order = libraryOrder
        libraryLoading = true; libraryError = nil
        defer { if generation == libraryGeneration { libraryLoading = false } }
        do {
            if tab == "Clips" {
                let newClips: [Clip]
                if order == .recent, let before = recentClipBefore {
                    let page = try await api.recentClips(broadcasterID: id, since: recentClipSince, before: before)
                    try Task.checkCancellation(); guard generation == libraryGeneration else { return }
                    newClips = page.data; recentClipBefore = page.nextBefore
                } else if let cursor = clipCursor {
                    let page = try await api.clips(broadcasterID: id, after: cursor)
                    try Task.checkCancellation(); guard generation == libraryGeneration else { return }
                    newClips = page.data; clipCursor = page.pagination?.cursor
                } else { return }
                let existing = Set(clips.map(\.id)); clips += newClips.filter { !existing.contains($0.id) }
            } else {
                guard let cursor = tab == "Past broadcasts" ? archiveCursor : videoCursor else { return }
                let page = try await api.videos(userID: id, after: cursor, type: tab == "Past broadcasts" ? "archive" : nil, sort: order)
                try Task.checkCancellation(); guard generation == libraryGeneration else { return }
                if tab == "Past broadcasts" {
                    let existing = Set(archives.map(\.id)); archives = sortedVideos(archives + page.data.filter { !existing.contains($0.id) }); archiveCursor = page.pagination?.cursor
                } else {
                    let existing = Set(videos.map(\.id)); videos = sortedVideos(videos + page.data.filter { !existing.contains($0.id) }); videoCursor = page.pagination?.cursor
                }
            }
        } catch is CancellationError { }
        catch { if generation == libraryGeneration && !Task.isCancelled { libraryError = error.localizedDescription } }
    }
}

private struct DesktopLibraryButtonStyle: ButtonStyle {
    @State private var hovered = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.75 : 1)
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(hovered ? TwitchyTheme.accent.opacity(0.7) : .clear, lineWidth: 2) }
            .onHover { hovered = $0 }
    }
}
#endif
