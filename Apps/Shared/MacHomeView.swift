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
                        Text("Your favorites. New discoveries. Always something live.").foregroundStyle(.secondary)
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
                    if !model.personal.data.favorites.isEmpty { channelRow("Your favorites", logins: model.personal.data.favorites) }
                    let history = model.personal.data.history.filter { $0.contentID != nil && $0.position > 0 }
                    if !history.isEmpty {
                        VStack(alignment: .leading, spacing: 16) {
                            Text("Pick up where you left off").font(.title2.bold())
                            ScrollView(.horizontal) {
                                HStack(spacing: 14) {
                                    ForEach(history) { entry in
                                        Button {
                                            model.selectedChannel = .init(login: entry.login, name: entry.title, contentType: entry.contentType, contentID: entry.contentID, resumePosition: entry.position)
                                        } label: {
                                            VStack(alignment: .leading, spacing: 10) {
                                                Image(systemName: "play.circle.fill").font(.title).foregroundStyle(TwitchyTheme.highlight)
                                                Text(entry.title).font(.headline).lineLimit(1)
                                                Text("Resume at \(Int(entry.position) / 60):\(String(format: "%02d", Int(entry.position) % 60))").font(.caption).foregroundStyle(.secondary)
                                            }.padding(20).frame(width: 230, alignment: .leading).macSurface()
                                        }.buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                    }
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
    private func channelRow(_ title: String, logins: [String]) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.title2.bold())
            ScrollView(.horizontal) {
                HStack(spacing: 12) {
                    ForEach(logins, id: \.self) { login in
                        Button { model.open(login: login, name: login) } label: {
                            Label(login, systemImage: "star.fill").font(.headline).padding(18).macSurface()
                        }.buttonStyle(.plain)
                    }
                }
            }
        }
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

/// Retain the native player view and PiP delegate independently of navigation.
@MainActor final class DesktopPlayerSurface: NSObject, @preconcurrency AVPlayerViewPictureInPictureDelegate {
    private(set) var view = AVPlayerView()
    let playback: PlaybackController
    init(playback: PlaybackController) {
        self.playback = playback
        super.init()
        view.player = playback.player
        view.controlsStyle = .inline
        view.showsFullScreenToggleButton = true
        view.pictureInPictureDelegate = self
    }
    func attach(pictureInPicture: Bool) -> AVPlayerView {
        // AVKit tears down its PiP controller when an inline view leaves the window.
        // Recreate the presentation when returning, while retaining the AVPlayer/session.
        // Keep the original view while PiP is running so navigation cannot dismiss it.
        if !playback.pictureInPictureActive {
            view.player = nil
            view = AVPlayerView()
            view.player = playback.player
        }
        configure(view, pictureInPicture: pictureInPicture)
        return view
    }
    func configure(_ view: AVPlayerView, pictureInPicture: Bool) {
        if view.controlsStyle != .inline { view.controlsStyle = .inline }
        view.showsFullScreenToggleButton = true
        if view.pictureInPictureDelegate !== self { view.pictureInPictureDelegate = self }
        if view.allowsPictureInPicturePlayback != pictureInPicture { view.allowsPictureInPicturePlayback = pictureInPicture }
    }
    func playerViewWillStartPicture(inPicture playerView: AVPlayerView) { playback.pictureInPictureActive = true }
    func playerViewDidStopPicture(inPicture playerView: AVPlayerView) { playback.pictureInPictureActive = false }
    func playerView(_ playerView: AVPlayerView, failedToStartPictureInPictureWithError error: Error) { playback.pictureInPictureActive = false }
    func playerViewShouldAutomaticallyDismissAtPicture(inPictureStart playerView: AVPlayerView) -> Bool { false }
}
struct DesktopNativePlayer: NSViewRepresentable {
    let surface: DesktopPlayerSurface
    var pictureInPicture: Bool
    func makeNSView(context: Context) -> AVPlayerView {
        surface.attach(pictureInPicture: pictureInPicture)
    }
    func updateNSView(_ view: AVPlayerView, context: Context) {
        surface.configure(view, pictureInPicture: pictureInPicture)
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
