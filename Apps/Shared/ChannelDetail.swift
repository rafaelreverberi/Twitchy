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
    @State private var downloadNotice: String?
    @State private var fullscreen = false
    @State private var attempt = 0
    #if os(macOS)
    @State private var watching = false
    @State private var theater = false
    @State private var profile: TwitchUser?
    @State private var channelInfo: ChannelInfo?
    @State private var library = "Recent videos"
    @State private var archives: [Video] = []
    @State private var videoCursor: String?
    @State private var archiveCursor: String?
    @State private var clipCursor: String?
    @State private var metadataLoading = true
    @State private var libraryLoading = false
    @State private var playingTitle: String?
    #endif
    var body: some View {
        Group {
            #if os(macOS)
            macContent
            #else
            legacyContent
            #endif
        }
        .task { await loadMetadata() }
        .task(id: selection.id) {
            #if os(macOS)
            if selection.returnToPlayback, let active = model.nowPlaying, active.selection.id == selection.id {
                watching = true; playingTitle = active.title
            } else if let type = selection.contentType, let id = selection.contentID {
                watching = true
                model.startDesktopPlayback(selection, type: type, contentID: id)
            }
            #else
            if let type = selection.contentType, let id = selection.contentID {
                await model.play(selection, contentType: type, contentID: id)
                await model.playback.player.seek(to: CMTime(seconds: selection.resumePosition, preferredTimescale: 600))
            } else if model.personal.data.preferences.autoplay { await model.play(selection) }
            #endif
        }
        #if !os(macOS)
        .task(id: model.playback.session?.sessionId) {
            while model.playback.session != nil && !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(10)); try Task.checkCancellation(); savePosition() } catch { return }
            }
        }
        #endif
        .onDisappear {
            savePosition(); model.chat.disconnect()
            #if !os(macOS)
            if !model.playback.pictureInPictureActive { Task { await model.playback.stop() } }
            #endif
        }
        #if !os(macOS)
        .onChange(of: model.playback.state) { _, state in
            if state == .failed, model.personal.data.preferences.retryPlayback, attempt < 2 { attempt += 1; Task { try? await Task.sleep(for: .seconds(2 * attempt)); guard !Task.isCancelled else { return }; await model.playback.retry() } }
        }
        #endif
        .sheet(isPresented: $fullscreen) {
            #if os(macOS)
            NativePlayer(player: model.playback.player, pictureInPicture: false) { _ in }.frame(minWidth: 800, minHeight: 450)
            #else
            nativePlayer.frame(minWidth: 300, minHeight: 240)
            #endif
        }
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
                    HStack { VStack(alignment: .leading) { Text(selection.name).font(.title.bold()); Text(stream?.title ?? "Channel details").foregroundStyle(.secondary); if let stream { Text("\(stream.gameName) · \(stream.viewerCount.formatted()) viewers").font(.caption) } }; Spacer(); Button { model.personal.favorite(selection.login) } label: { Image(systemName: model.personal.data.favorites.contains(selection.login) ? "star.fill" : "star") }.accessibilityLabel("Toggle favorite") }
                    HStack { Button("Watch live") { Task { await model.play(selection) } }.buttonStyle(.borderedProminent); Link("Follow on Twitch", destination: URL(string: "https://www.twitch.tv/\(selection.login)")!); Button("Fullscreen") { fullscreen = true }.disabled(model.playback.session == nil) }
                    if let downloadNotice { Text(downloadNotice).foregroundStyle(.secondary) }
                    if let error { Notice(error) }
                    if let error = model.error { Notice(error) }
                    if let session = model.playback.session {
                        HStack {
                            Menu("Quality: " + model.playback.qualityLabel) {
                                Button("Best") { Task { await model.playback.changeQuality("auto") } }
                                ForEach(session.qualities.filter { $0 != "auto" }, id: \.self) { quality in Button(quality) { Task { await model.playback.changeQuality(quality) } } }
                            }
                            Button(model.playback.player.isMuted ? "Unmute" : "Mute") { model.playback.player.isMuted.toggle() }
                            Text(model.playback.state.rawValue).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if !videos.isEmpty { Text("Recent videos").font(.title2.bold()); ForEach(videos) { video in HStack { VStack(alignment: .leading) { Text(video.title); Text(video.duration).font(.caption).foregroundStyle(.secondary) }; Spacer(); Button("Watch") { Task { await model.play(selection, contentType: "vod", contentID: video.id) } }; downloadButton(type: "vod", id: video.id); if let url = URL(string: video.url) { Link("Twitch", destination: url) } } } }
                    if !clips.isEmpty { Text("Channel clips").font(.title2.bold()); ForEach(clips) { clip in HStack { Text(clip.title); Spacer(); Button("Watch") { Task { await model.play(selection, contentType: "clip", contentID: clip.id) } }; downloadButton(type: "clip", id: clip.id); if let url = URL(string: clip.url) { Link("Twitch", destination: url) } } } }
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
                do { let page = try await api.videos(userID: id); videos = page.data; videoCursor = page.pagination?.cursor } catch { self.error = error.localizedDescription }
                do { let page = try await api.videos(userID: id, type: "archive"); archives = page.data; archiveCursor = page.pagination?.cursor } catch { self.error = error.localizedDescription }
                do { let page = try await api.clips(broadcasterID: id); clips = page.data; clipCursor = page.pagination?.cursor } catch { self.error = error.localizedDescription }
                #else
                async let v = api.videos(userID: id); async let c = api.clips(broadcasterID: id)
                videos = try await v.data; clips = try await c.data
                #endif
            }
        } catch is CancellationError { }
        catch { self.error = error.localizedDescription }
    }
    @ViewBuilder private func downloadButton(type: String, id: String) -> some View {
        #if !os(tvOS)
        if model.sources.active?.capabilities?.clientSideDownloads == true {
            Button("Download") { Task {
                do { let client = try model.sources.client(); await model.downloads.enqueue(client: client, type: type, contentID: id, quality: model.personal.data.preferences.preferredQuality); downloadNotice = model.downloads.error ?? "Download added. See Downloads for progress and offline playback." }
                catch { downloadNotice = error.localizedDescription }
            } }
        }
        #endif
    }
    @ViewBuilder private var nativePlayer: some View {
        #if os(macOS)
        DesktopNativePlayer(surface: model.desktopPlayerSurface, pictureInPicture: model.personal.data.preferences.pictureInPicture)
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
            if model.auth.session?.scopes.contains("user:read:chat") != true {
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

#if os(macOS)
extension ChannelDetail {
    private var macContent: some View {
        GeometryReader { geometry in
            HStack(alignment: .top, spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        if watching { desktopPlayer; desktopIdentity; playerActions }
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
        .onChange(of: model.nowPlaying?.id) { _, id in if id == nil { watching = false; theater = false } }
        .navigationTitle(selection.name)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    if watching {
                        savePosition(); watching = false; theater = false
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
            RemoteImage(URL(string: profile?.profileImageUrl ?? ""), symbol: "person.crop.circle")
                .frame(width: watching ? 62 : 82, height: watching ? 62 : 82).clipShape(Circle())
                .overlay { Circle().strokeBorder(TwitchyTheme.accent.opacity(0.7), lineWidth: 3) }
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Text(profile?.displayName ?? selection.name).font(watching ? .title2.bold() : .largeTitle.bold())
                    if stream != nil && (!watching || model.playback.currentRequest?.contentType == "live") { MacLiveBadge() }
                    Spacer()
                    Button { model.personal.favorite(selection.login) } label: {
                        Image(systemName: model.personal.data.favorites.contains(selection.login) ? "star.fill" : "star")
                    }.buttonStyle(.bordered).help("Save channel to your favorites").accessibilityLabel("Toggle favorite")
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
    private var channelActions: some View {
        HStack(spacing: 12) {
            if stream != nil {
                Button { startWatching() } label: { Label("Watch live", systemImage: "play.fill").padding(.horizontal, 12).padding(.vertical, 5) }
                    .buttonStyle(.borderedProminent).accessibilityIdentifier("channel.watchLive")
            } else if metadataLoading { ProgressView("Loading channel…") }
            else { Label("Currently offline", systemImage: "moon").foregroundStyle(.secondary) }
            Link(destination: channelURL) { Label("Follow on Twitch", systemImage: "heart") }.buttonStyle(.bordered)
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
    private var playerActions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { playbackButtons; Spacer(); Link("Follow on Twitch", destination: channelURL).buttonStyle(.bordered) }
            VStack(alignment: .leading, spacing: 12) { HStack { playbackButtons }; Link("Follow on Twitch", destination: channelURL).buttonStyle(.bordered) }
        }
    }
    @ViewBuilder private var playbackButtons: some View {
        Button {
            model.personal.data.preferences.showChat.toggle()
            if theater { theater = false }
        } label: { Label(model.personal.data.preferences.showChat && !theater ? "Hide chat" : "Open chat", systemImage: "bubble.left.and.bubble.right") }.buttonStyle(.bordered)
        Button { theater.toggle() } label: { Label(theater ? "Exit theater" : "Theater", systemImage: "rectangle.expand.vertical") }.buttonStyle(.bordered)
        if let session = model.playback.session {
            Button { model.playback.toggleMute() } label: { Image(systemName: model.playback.isMuted ? "speaker.slash" : "speaker.wave.2") }.buttonStyle(.bordered).accessibilityLabel(model.playback.isMuted ? "Unmute" : "Mute")
            Button("Stop stream", systemImage: "stop.fill") { model.stopDesktopPlayback(); watching = false; theater = false }.buttonStyle(.bordered).accessibilityIdentifier("player.stop")
            Menu(model.playback.qualityLabel) {
                Button("Best · Auto") { Task { await model.playback.changeQuality("auto") } }
                ForEach(session.qualities.filter { $0 != "auto" }, id: \.self) { quality in Button(quality) { Task { await model.playback.changeQuality(quality) } } }
            }.menuStyle(.borderlessButton).fixedSize().padding(8).background(TwitchyTheme.elevated, in: RoundedRectangle(cornerRadius: 8))
            Button { fullscreen = true } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }.buttonStyle(.bordered).accessibilityLabel("Fullscreen")
        }
    }
    private var desktopLibrary: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(watching ? "More from \(selection.name)" : "Channel library").font(.title2.bold())
                Spacer()
                if metadataLoading || libraryLoading { ProgressView().controlSize(.small) }
            }
            Picker("Channel library", selection: $library) {
                Text("Recent videos").tag("Recent videos")
                Text("Past broadcasts").tag("Past broadcasts")
                Text("Clips").tag("Clips")
            }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 470).accessibilityIdentifier("channel.library")
            if library == "Clips" {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: watching ? 190 : 250))], alignment: .leading, spacing: 22) {
                    ForEach(clips) { clip in
                        libraryCard(title: clip.title, thumbnail: clip.thumbnailUrl, badge: "CLIP", detail: clip.broadcasterName, type: "clip", id: clip.id, url: clip.url)
                    }
                }
            } else {
                let items = library == "Past broadcasts" ? archives : videos
                LazyVGrid(columns: [GridItem(.adaptive(minimum: watching ? 190 : 250))], alignment: .leading, spacing: 22) {
                    ForEach(items) { video in
                        libraryCard(title: video.title, thumbnail: video.thumbnailUrl, badge: video.duration, detail: videoDetail(video), type: "vod", id: video.id, url: video.url)
                    }
                }
            }
            if !metadataLoading && (library == "Clips" ? clips.isEmpty : library == "Past broadcasts" ? archives.isEmpty : videos.isEmpty) {
                EmptyState("No \(library.lowercased()) available", detail: "Published videos and clips will appear here when Twitch makes them available.")
            }
            if (library == "Clips" ? clipCursor : library == "Past broadcasts" ? archiveCursor : videoCursor) != nil {
                Button("Load more") { Task { await moreLibrary() } }.buttonStyle(.bordered).disabled(libraryLoading)
            }
        }
    }
    private func libraryCard(title: String, thumbnail: String, badge: String, detail: String, type: String, id: String, url: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Button { startWatching(type: type, id: id, title: title) } label: {
                VStack(alignment: .leading, spacing: 10) {
                    RemoteImage(URL(string: thumbnail.replacingOccurrences(of: "%{width}", with: "640").replacingOccurrences(of: "%{height}", with: "360").replacingOccurrences(of: "{width}", with: "640").replacingOccurrences(of: "{height}", with: "360")))
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .overlay(alignment: .bottomLeading) { Text(badge).font(.caption.bold()).foregroundStyle(.white).padding(6).background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 5)).padding(10) }
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    Text(title).font(.headline).lineLimit(2).frame(height: 40, alignment: .topLeading)
                }
            }.buttonStyle(.plain).accessibilityLabel("Watch \(title)")
            HStack {
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Menu {
                    Button("Watch") { startWatching(type: type, id: id, title: title) }
                    downloadButton(type: type, id: id)
                    if let url = URL(string: url) { Link("Open on Twitch", destination: url) }
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Options for \(title)")
            }
        }
    }
    private func videoDetail(_ video: Video) -> String {
        var parts: [String] = []
        if let views = video.viewCount { parts.append("\(views.formatted()) views") }
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
    private func moreLibrary() async {
        guard let api = model.api, let id = broadcasterID else { return }
        let tab = library; libraryLoading = true; defer { libraryLoading = false }
        do {
            if tab == "Clips", let cursor = clipCursor {
                let page = try await api.clips(broadcasterID: id, after: cursor)
                let existing = Set(clips.map(\.id)); clips += page.data.filter { !existing.contains($0.id) }; clipCursor = page.pagination?.cursor
            } else if tab == "Past broadcasts", let cursor = archiveCursor {
                let page = try await api.videos(userID: id, after: cursor, type: "archive")
                let existing = Set(archives.map(\.id)); archives += page.data.filter { !existing.contains($0.id) }; archiveCursor = page.pagination?.cursor
            } else if let cursor = videoCursor {
                let page = try await api.videos(userID: id, after: cursor)
                let existing = Set(videos.map(\.id)); videos += page.data.filter { !existing.contains($0.id) }; videoCursor = page.pagination?.cursor
            }
        } catch is CancellationError { }
        catch { self.error = error.localizedDescription }
    }
}
#endif
