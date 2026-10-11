#if os(iOS)
import SwiftUI
import AVKit
import TwitchyDesignSystem
import TwitchyPlayback

struct MobilePlaybackOverlay: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var controlsVisible = true
    @State private var panel = "Chat"
    @State private var downloadNotice: String?
    @State private var preparingDownload = false
    var body: some View {
        let mobile = model.mobile
        GeometryReader { geometry in
            let fullscreen = mobile.fullscreen
            let expanded = mobile.expanded
            let bottomBar: CGFloat = model.selectedChannel == nil ? 49 : 0
            let videoSize = CGSize(width: expanded ? geometry.size.width : 88,
                                   height: expanded ? (fullscreen ? geometry.size.height : min(geometry.size.width * 9 / 16, geometry.size.height * (mobile.isComposing ? 0.3 : 0.42))) : 49.5)
            let videoCenter = CGPoint(x: expanded ? geometry.size.width / 2 : 62,
                                      y: expanded ? videoSize.height / 2 : geometry.size.height - bottomBar - 38)
            ZStack(alignment: .topLeading) {
                if expanded { Color(uiColor: .systemBackground).ignoresSafeArea() }
                if mobile.selection != nil, !expanded {
                    miniPlayer.frame(width: geometry.size.width - 16, height: 66)
                        .position(x: geometry.size.width / 2, y: videoCenter.y)
                }
                // This UIView and AVPlayerLayer stay mounted for the lifetime of the root.
                MobileVideoSurface(surface: mobile.surface)
                    .frame(width: videoSize.width, height: videoSize.height)
                    .background(.black).clipShape(RoundedRectangle(cornerRadius: expanded ? 0 : 8))
                    .position(videoCenter).opacity(mobile.selection == nil ? 0 : 1)
                    .accessibilityIdentifier("watch.video")
                    .accessibilityValue(playbackIdentity)
                    .onTapGesture { if mobile.isComposing { mobile.isComposing = false } else if expanded { controlsVisible.toggle() } else { mobile.expand() } }
                    .simultaneousGesture(DragGesture(minimumDistance: 25).onEnded { drag in
                        guard drag.translation.height > 45, abs(drag.translation.width) < drag.translation.height else { return }
                        if fullscreen { mobile.toggleFullscreen() } else { mobile.collapse() }
                    })
                if expanded {
                    videoOverlay(size: videoSize).position(x: videoSize.width / 2, y: videoSize.height / 2)
                    if !fullscreen {
                        VStack(spacing: 0) {
                            streamDetails
                            Divider()
                            panelHeader
                            if panel == "Chat" { MobileChatView() }
                            else { detailsPanel }
                        }
                        .frame(width: geometry.size.width, height: max(0, geometry.size.height - videoSize.height))
                        .position(x: geometry.size.width / 2, y: videoSize.height + (geometry.size.height - videoSize.height) / 2)
                    }
                }
            }
        }
        .ignoresSafeArea(edges: mobile.fullscreen ? .all : [])
        .allowsHitTesting(mobile.selection != nil)
        .alert("Download", isPresented: Binding(get: { downloadNotice != nil }, set: { if !$0 { downloadNotice = nil } })) {
            Button("OK") { downloadNotice = nil }
        } message: { Text(downloadNotice ?? "") }
        .task(id: mobile.identity) { await mobile.loadWatchingProfile() }
        .onChange(of: mobile.identity) { _, _ in controlsVisible = true; panel = model.personal.data.preferences.showChat ? "Chat" : "Details" }
        .onChange(of: mobile.presentation) { _, _ in controlsVisible = true }
        .animation(reduceMotion || model.personal.data.preferences.reduceMotion ? nil : .easeInOut(duration: 0.22), value: mobile.presentation)
        .task(id: "\(mobile.expanded)-\(controlsVisible)-\(model.playback.isPaused)-\(model.playback.state.rawValue)") {
            guard mobile.expanded, controlsVisible, !model.playback.isPaused, model.playback.state == .playing else { return }
            do { try await Task.sleep(for: .seconds(4)); try Task.checkCancellation(); controlsVisible = false } catch { }
        }
    }
    private var playbackIdentity: String {
        #if DEBUG && targetEnvironment(simulator)
        if MobileFixtures.enabled {
            return model.playback.state.rawValue + "|" + (model.playback.session?.sessionId ?? "none") + "|" + model.mobile.surfaceID + "|" + (model.playback.player.currentItem.map { String(ObjectIdentifier($0).hashValue) } ?? "none") + "|" + (model.playback.pictureInPictureActive ? "pip" : "inline") + "|" + String(model.mobile.pipActivationCount) + "|" + (model.mobile.pipPossible ? "possible" : "unavailable") + "|" + (AVPictureInPictureController.isPictureInPictureSupported() ? "supported" : "unsupported")
        }
        #endif
        return model.playback.state.rawValue
    }
    private func videoOverlay(size: CGSize) -> some View {
        ZStack {
            if model.playback.pictureInPictureActive {
                VStack(spacing: 8) { Image(systemName: "pip.fill").font(.title); Text("Playing in Picture in Picture").font(.subheadline) }
                    .foregroundStyle(.white).frame(maxWidth: .infinity, maxHeight: .infinity).background(.black)
            }
            if controlsVisible || model.playback.isPaused || model.playback.state != .playing {
                LinearGradient(colors: [.black.opacity(0.6), .clear, .black.opacity(0.65)], startPoint: .top, endPoint: .bottom).allowsHitTesting(false)
                VStack {
                    HStack {
                        playerButton("chevron.down", label: model.mobile.fullscreen ? "Exit fullscreen" : "Minimize player", identifier: "watch.close") {
                            if model.mobile.fullscreen { model.mobile.toggleFullscreen() } else { model.mobile.collapse() }
                        }
                        Spacer()
                        if model.mobile.pipEnabled, AVPictureInPictureController.isPictureInPictureSupported() {
                            playerButton("pip.enter", label: "Picture in Picture", identifier: "watch.pip") { model.mobile.surface.togglePiP() }.disabled(!model.mobile.pipPossible)
                        }
                        AirPlayPicker().frame(width: 44, height: 44).accessibilityLabel("AirPlay")
                        Menu {
                            Button("Best") { model.mobile.changeQuality("auto") }
                            ForEach(model.playback.session?.qualities.filter { $0 != "auto" } ?? [], id: \.self) { quality in Button(quality) { model.mobile.changeQuality(quality) } }
                            Button(model.playback.isMuted ? "Unmute" : "Mute", systemImage: model.playback.isMuted ? "speaker.wave.2" : "speaker.slash") { model.playback.toggleMute() }
                        } label: { Image(systemName: "gearshape").frame(width: 44, height: 44) }.accessibilityLabel("Playback options")
                    }
                    Spacer(minLength: 4)
                    playbackCenter
                    Spacer(minLength: 4)
                    HStack {
                        if model.mobile.selection?.contentType == "live" {
                            Label("LIVE", systemImage: "circle.fill").font(.caption.bold()).foregroundStyle(model.playback.state == .playing ? TwitchyTheme.live : .white)
                        } else { MobilePlaybackTimeline() }
                        Spacer(minLength: 12)
                        Text(model.playback.qualityLabel).font(.caption.weight(.medium))
                        playerButton(model.mobile.fullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                                     label: model.mobile.fullscreen ? "Exit fullscreen" : "Fullscreen",
                                     identifier: model.mobile.fullscreen ? "watch.exitFullscreen" : "watch.fullscreen") { model.mobile.toggleFullscreen() }
                    }
                }.padding(.horizontal, model.mobile.fullscreen ? 18 : 8).padding(.vertical, 6)
            } else {
                Color.clear.contentShape(Rectangle()).onTapGesture { model.mobile.isComposing = false; controlsVisible = true }
            }
        }.foregroundStyle(.white).tint(.white).frame(width: size.width, height: size.height)
        .simultaneousGesture(DragGesture(minimumDistance: 25).onEnded { drag in
            if drag.translation.height > 45, abs(drag.translation.width) < drag.translation.height {
                if model.mobile.fullscreen { model.mobile.toggleFullscreen() } else { model.mobile.collapse() }
            }
        })
    }
    @ViewBuilder private var playbackCenter: some View {
        let failure = model.mobile.error ?? model.playback.error
        if model.mobile.recovering || [.loading, .buffering, .reconnecting].contains(model.playback.state) {
            VStack(spacing: 8) {
                ProgressView().tint(.white).controlSize(.large)
                if model.mobile.recovering { Text("Reconnecting…").font(.caption) }
            }.accessibilityLabel(model.mobile.recovering ? "Reconnecting stream" : "Loading stream")
        } else if let failure {
            VStack(spacing: 10) {
                Text(model.playback.state == .unavailable ? "Stream unavailable" : "Couldn’t start playback").font(.headline)
                Text(failure).font(.caption).multilineTextAlignment(.center).lineLimit(3)
                Button("Retry") { model.mobile.retry() }.buttonStyle(.bordered).accessibilityIdentifier("watch.retry")
            }.padding(.horizontal, 20)

        } else if [.pausedByServer, .adBreak].contains(model.playback.state) {
            Text("Waiting for your source…").font(.subheadline)
        } else {
            HStack(spacing: 38) {
                if model.mobile.selection?.contentType != "live" { seekButton(-10) }
                playerButton(model.playback.isPaused ? "play.fill" : "pause.fill", label: model.playback.isPaused ? "Play" : "Pause", identifier: "watch.playPause", size: 30) { model.playback.togglePlayPause() }
                if model.mobile.selection?.contentType != "live" { seekButton(10) }
            }
        }
    }
    private func playerButton(_ symbol: String, label: String, identifier: String, size: CGFloat = 19, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: size, weight: .semibold)).frame(width: 44, height: 44).contentShape(Rectangle()) }
            .buttonStyle(.plain).accessibilityLabel(label).accessibilityIdentifier(identifier)
    }
    private func seekButton(_ offset: Double) -> some View {
        playerButton(offset < 0 ? "gobackward.10" : "goforward.10", label: offset < 0 ? "Back 10 seconds" : "Forward 10 seconds", identifier: offset < 0 ? "watch.back" : "watch.forward", size: 26) {
            let time = model.playback.player.currentTime().seconds
            guard time.isFinite else { return }
            let item = model.playback.player.currentItem
            Task {
                guard model.playback.player.currentItem === item else { return }
                await model.playback.player.seek(to: CMTime(seconds: max(0, time + offset), preferredTimescale: 600))
            }
        }
    }
    private var streamDetails: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !model.mobile.isComposing { Text(model.mobile.title).font(.headline).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading) }
            HStack(spacing: 10) {
                Button { model.mobile.openChannel() } label: {
                    HStack(spacing: 10) {
                        RemoteImage(model.mobile.avatar, symbol: "person.fill").frame(width: 34, height: 34).clipShape(Circle())
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.mobile.selection?.name ?? "").font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                            if !model.mobile.category.isEmpty { Text(model.mobile.category).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                        }
                    }
                }.buttonStyle(.plain).accessibilityLabel("Open channel")
                Spacer()
                Menu {
                    Button("View channel", systemImage: "person.crop.circle") { model.mobile.openChannel() }
                        .accessibilityIdentifier("watch.channelLibrary")
                    if !model.isOfflinePlayback, let selection = model.mobile.selection, let id = selection.contentID, let type = selection.contentType,
                       type == "vod" || type == "clip" {
                        Button("Download", systemImage: "arrow.down.circle") {
                            download(type: type, id: id)
                        }.disabled(preparingDownload).accessibilityIdentifier("watch.download")
                    }
                } label: { Image(systemName: "ellipsis").font(.system(size: 20, weight: .semibold)).frame(width: 44, height: 44) }
                    .accessibilityLabel("Stream options").accessibilityIdentifier("watch.options")
            }
        }.padding(.horizontal, 16).padding(.vertical, 14).background(Color(uiColor: .systemBackground))
    }
    private func download(type: String, id: String) {
        guard ["vod", "clip"].contains(type), !preparingDownload else { return }
        preparingDownload = true
        let metadata = DownloadMetadata(title: model.mobile.title, channel: model.mobile.selection?.name, thumbnailURL: model.mobile.thumbnailURL, duration: model.mobile.duration)
        Task {
            defer { preparingDownload = false }
            do {
                let client = try model.sources.client()
                let capabilities = try await client.capabilities()
                guard capabilities.downloads, capabilities.clientSideDownloads == true else {
                    downloadNotice = "Your streaming source does not support downloads for this content."
                    return
                }
                await model.downloads.enqueue(client: client, type: type, contentID: id, quality: model.personal.data.preferences.preferredQuality, metadata: metadata)
                downloadNotice = model.downloads.error ?? "Download added. See Downloads for progress and offline playback."
            } catch { downloadNotice = error.localizedDescription }
        }
    }
    private var panelHeader: some View {
        HStack(spacing: 20) {
            Button { panel = "Chat" } label: { Label("Live chat", systemImage: "bubble.left.and.bubble.right").font(.subheadline.weight(.semibold)).foregroundStyle(panel == "Chat" ? Color.primary : .secondary) }
                .accessibilityIdentifier("watch.chat")
            Button { panel = "Details" } label: { Text("Details").font(.subheadline.weight(.semibold)).foregroundStyle(panel == "Details" ? Color.primary : .secondary) }.accessibilityIdentifier("watch.details")
            Spacer()
            if panel == "Chat" {
                Menu {
                    Toggle("Timestamps", isOn: Binding(get: { model.personal.data.preferences.timestamps }, set: { model.personal.data.preferences.timestamps = $0 }))
                    Toggle("Emotes", isOn: Binding(get: { model.personal.data.preferences.emotes }, set: { model.personal.data.preferences.emotes = $0 }))
                    Toggle("Auto-scroll", isOn: Binding(get: { model.personal.data.preferences.autoscroll }, set: { model.personal.data.preferences.autoscroll = $0 }))
                } label: { Image(systemName: "ellipsis").frame(width: 32, height: 32) }.accessibilityLabel("Chat options")
            }
        }.buttonStyle(.plain).padding(.horizontal, 16).padding(.vertical, 6)
    }
    private var detailsPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(model.mobile.title).font(.title3.bold())
                Text(model.mobile.category).foregroundStyle(.secondary)
                Button("View channel", systemImage: "person.crop.circle") { model.mobile.openChannel() }
                if let login = model.mobile.selection?.login { Link("Open on Twitch", destination: URL(string: "https://www.twitch.tv/\(login)")!) }
                Button("Stop playback", systemImage: "stop.fill", role: .destructive) { model.mobile.stop() }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
        }
    }
    private var miniPlayer: some View {
        HStack(spacing: 10) {
            Color.clear.frame(width: 88, height: 49.5)
            Button { model.mobile.expand() } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.mobile.title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
                    Text(model.mobile.selection?.name ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(.plain).accessibilityIdentifier("nowPlaying.open")
            Button { model.playback.togglePlayPause() } label: { Image(systemName: model.playback.isPaused ? "play.fill" : "pause.fill").frame(width: 36, height: 44) }
                .accessibilityLabel(model.playback.isPaused ? "Play" : "Pause")
            Button { model.mobile.stop() } label: { Image(systemName: "xmark").frame(width: 36, height: 44) }.accessibilityLabel("Stop stream").accessibilityIdentifier("nowPlaying.stop")
        }.padding(.leading, 10).padding(.trailing, 4).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14)).overlay { RoundedRectangle(cornerRadius: 14).stroke(.quaternary, lineWidth: 0.5) }
    }
}
private struct AirPlayPicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView { let view = AVRoutePickerView(); view.tintColor = .white; view.activeTintColor = .systemPurple; view.prioritizesVideoDevices = true; return view }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) { }
}
private struct MobilePlaybackTimeline: View {
    @Environment(AppModel.self) private var model
    @State private var scrubbing = false
    @State private var position: Double = 0
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let seconds = model.playback.player.currentTime().seconds
            let duration = model.playback.player.currentItem?.duration.seconds ?? 0
            let current = seconds.isFinite ? max(0, seconds) : 0
            HStack(spacing: 8) {
                Text(time(scrubbing ? position : current)).font(.caption.monospacedDigit()).accessibilityIdentifier("watch.elapsed")
                if duration.isFinite, duration > 0 {
                    Slider(value: Binding(get: { scrubbing ? position : min(current, duration) }, set: { position = $0 }), in: 0...duration, onEditingChanged: { editing in
                        if editing { scrubbing = true }
                        else {
                            let item = model.playback.player.currentItem
                            let target = position
                            Task {
                                guard model.playback.player.currentItem === item else { scrubbing = false; return }
                                await model.playback.player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
                                scrubbing = false
                            }
                        }
                    }).tint(.white).accessibilityLabel("Playback position").accessibilityIdentifier("watch.position")
                    Text(time(duration)).font(.caption.monospacedDigit())
                }
            }
        }
    }
    private func time(_ seconds: Double) -> String { String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60) }
}
#endif
