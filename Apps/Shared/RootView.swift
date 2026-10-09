import SwiftUI
import AVKit
import TwitchyCore
import TwitchyAPI
import TwitchyDesignSystem

enum Destination: String, CaseIterable, Identifiable {
    case home = "Home", channels = "Channels", search = "Search", downloads = "Downloads", profile = "Profile"
    var id: String { rawValue }
    var icon: String { switch self { case .home: "house"; case .channels: "person.2"; case .search: "magnifyingglass"; case .downloads: "arrow.down.circle"; case .profile: "person.crop.circle" } }
}
struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var destination: Destination? = .home
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        @Bindable var model = model
        Group {
            #if os(macOS)
            split
            #elseif os(tvOS)
            tabs
            #else
            if sizeClass == .regular { split } else { tabs }
            #endif
        }
        .background(TwitchyTheme.background)
        .sheet(isPresented: $model.showingSettings) { SettingsView().environment(model) }
        .sheet(item: $model.selectedChannel) { selection in ChannelDetail(selection: selection).environment(model) }
        .sheet(isPresented: Binding(get: { !model.personal.data.onboardingComplete }, set: { if !$0 { model.personal.data.onboardingComplete = true } })) { WelcomeView().environment(model) }
        .sheet(isPresented: Binding(get: { model.localPlayback != nil }, set: { if !$0 { model.localPlayback = nil } })) { if let url = model.localPlayback { OfflinePlayer(url: url) } }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { do { try await model.auth.validate() } catch { model.error = error.localizedDescription } } }
            if phase == .background {
                model.chat.disconnect()
                #if os(iOS)
                UIApplication.shared.isIdleTimerDisabled = false
                #endif
                if !model.playback.pictureInPictureActive { Task { await model.playback.stop() } }
            }
        }
        .onChange(of: model.auth.status) { _, _ in Task { await model.refresh() } }
        .onChange(of: model.auth.session?.accessToken) { _, _ in Task { await model.refresh() } }
        .onChange(of: model.sources.active?.baseURL) { _, _ in Task { await model.playback.stop() } }
        .onChange(of: model.sources.activeID) { _, _ in model.personal.data.preferences.preferredQuality = "auto"; Task { await model.playback.stop() } }
    }
    #if !os(tvOS)
    private var split: some View {
        NavigationSplitView {
            List(selection: $destination) {
                Section { HStack { BrandMark(); Text("Twitchy").font(.title2.bold()) }.padding(.vertical, 14) }
                Section { ForEach(Destination.allCases) { item in Label(item.rawValue, systemImage: item.icon).tag(item).accessibilityIdentifier("nav.\(item.rawValue.lowercased())") } }
                Section("Streaming source") { Label(model.sources.active?.name ?? "No source selected", systemImage: "server.rack").font(.caption).foregroundStyle(.secondary) }
            }.navigationTitle("Twitchy").listStyle(.sidebar).navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 300)
        } detail: { NavigationStack { screen(destination ?? .home) } }
    }
    #endif
    private var tabs: some View {
        TabView { ForEach(Destination.allCases) { item in NavigationStack { screen(item) }.tabItem { Label(item.rawValue, systemImage: item.icon) }.accessibilityIdentifier("nav.\(item.rawValue.lowercased())") } }
    }
    @ViewBuilder private func screen(_ item: Destination) -> some View {
        Group {
            switch item { case .home: HomeView(); case .channels: ChannelsView(); case .search: SearchView(); case .downloads: DownloadsView(); case .profile: ProfileView() }
        }.navigationTitle(item.rawValue)
        .toolbar { ToolbarItem { Button { model.showingSettings = true } label: { Image(systemName: "gearshape") }.accessibilityLabel("Settings").accessibilityIdentifier("settings.open") } }
    }
}
struct WelcomeView: View {
    @Environment(AppModel.self) private var model
    @State private var sources = false
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    BrandMark().padding(.top, 30)
                    Text("Twitchy").font(.system(size: 54, weight: .bold, design: .rounded))
                    Text("Your streams. Your way.").font(.title2).foregroundStyle(TwitchyTheme.muted)
                    Divider()
                    Label("Connect your Twitch account", systemImage: "person.crop.circle").font(.headline)
                    Text("Browse live channels, keep up with your follows, and join chat directly through Twitch.").foregroundStyle(.secondary)
                    Label("Bring your streaming source", systemImage: "server.rack").font(.headline)
                    Text("Video comes from your own compatible server. You can connect Twitch and browse before adding a source.").foregroundStyle(.secondary)
                    Button("Configure Twitch & sign in") { model.personal.data.onboardingComplete = true; model.showingSettings = true }.buttonStyle(.borderedProminent)
                    Button("Add a streaming source") { sources = true }.buttonStyle(.bordered)
                    Button("Start browsing") { model.personal.data.onboardingComplete = true }.accessibilityIdentifier("onboarding.complete")
                    Text("An independent third-party client. Not affiliated with Twitch.").font(.caption).foregroundStyle(.secondary)
                }.padding(36).frame(maxWidth: 600, alignment: .leading)
            }.sheet(isPresented: $sources) { NavigationStack { SourcesView() }.environment(model) }
        }.interactiveDismissDisabled()
        #if os(macOS)
        .frame(width: 640, height: 760)
        #endif
    }
}
struct LoginPrompt: View {
    @Environment(AppModel.self) private var model
    var body: some View { VStack { EmptyState("Connect with Twitch", detail: "Twitch requires an access token for discovery. Sign in to browse channels and categories, even without a streaming source.", symbol: "person.crop.circle.badge.checkmark"); Button("Set up Twitch") { model.showingSettings = true }.buttonStyle(.borderedProminent) }.padding(.bottom, 32) }
}
struct HomeView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack(alignment: .bottom) { VStack(alignment: .leading, spacing: 8) { Text("Your live lineup").font(.largeTitle.bold()); Text("Find a stream. Settle in.").foregroundStyle(.secondary) }; Spacer(); if model.loading { ProgressView() } else { Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }.accessibilityLabel("Refresh streams") } }
                if let error = model.error { Notice(error) }
                if model.api == nil { LoginPrompt() }
                else {
                    if !model.followedStreams.isEmpty { StreamSection(title: "Following · Live now", streams: model.followedStreams) }
                    if !model.personal.data.favorites.isEmpty { localSection("Favorites", logins: model.personal.data.favorites) }
                    let resumable = model.personal.data.history.filter { $0.contentID != nil && $0.position > 0 }
                    if !resumable.isEmpty {
                        Text("Continue Watching").font(.title2.bold())
                        ForEach(resumable) { entry in Button { model.selectedChannel = .init(login: entry.login, name: entry.title, contentType: entry.contentType, contentID: entry.contentID, resumePosition: entry.position) } label: { Label("\(entry.title) · \(Int(entry.position))s", systemImage: "play.circle") } }
                    }
                    if !model.personal.data.history.isEmpty { localSection("Recently watched", logins: model.personal.data.history.prefix(8).map(\.login)) }
                    StreamSection(title: "Popular right now", streams: model.streams)
                    if model.streamsCursor != nil { Button("Load more streams") { Task { await model.moreStreams() } } }
                    Text("Popular categories").font(.title2.bold())
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 130, maximum: 190))], spacing: 20) { ForEach(model.categories) { category in NavigationLink { CategoryDetail(category: category) } label: { VStack(alignment: .leading) { RemoteImage(URL(string: category.boxArtUrl.replacingOccurrences(of: "{width}", with: "285").replacingOccurrences(of: "{height}", with: "380"))).aspectRatio(0.75, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 10)); Text(category.name).font(.headline).lineLimit(1) } }.buttonStyle(.plain) } }
                    if model.streams.isEmpty && !model.loading { EmptyState("No streams loaded", detail: "Refresh to try Twitch again.") }
                }
            }.padding(24)
        }.refreshable { await model.refresh() }
    }
    private func localSection(_ title: String, logins: [String]) -> some View { VStack(alignment: .leading, spacing: 12) { Text(title).font(.title2.bold()); ScrollView(.horizontal) { HStack { ForEach(logins, id: \.self) { login in Button { model.open(login: login, name: login) } label: { Label(login, systemImage: "person.crop.circle").padding(14).background(TwitchyTheme.secondary, in: RoundedRectangle(cornerRadius: 10)) }.buttonStyle(.plain) } } } } }
}
struct StreamSection: View {
    var title: String; var streams: [TwitchStream]
    var body: some View { VStack(alignment: .leading, spacing: 16) { Text(title).font(.title2.bold()); LazyVGrid(columns: [GridItem(.adaptive(minimum: 270, maximum: 440))], spacing: 24) { ForEach(streams) { StreamCard(stream: $0) } } } }
}
struct StreamCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let stream: TwitchStream
    @State private var hovered = false
    var body: some View {
        Button { model.open(login: stream.userLogin, name: stream.userName, id: stream.userId) } label: {
            VStack(alignment: .leading, spacing: 10) {
                RemoteImage(stream.thumbnail).aspectRatio(16 / 9, contentMode: .fit).overlay(alignment: .topLeading) { Text("LIVE").font(.caption.bold()).padding(.horizontal, 8).padding(.vertical, 5).background(TwitchyTheme.live, in: RoundedRectangle(cornerRadius: 5)).foregroundStyle(.black).padding(10) }.overlay(alignment: .bottomLeading) { Text("\(stream.viewerCount.formatted()) viewers").font(.caption).padding(6).background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 4)).padding(10) }.clipShape(RoundedRectangle(cornerRadius: 12))
                Text(stream.userName).font(.headline).foregroundStyle(.primary)
                Text(stream.title).lineLimit(2).font(.subheadline).foregroundStyle(.primary)
                Text(stream.gameName).font(.caption).foregroundStyle(.secondary)
            }.contentShape(Rectangle()).scaleEffect(hovered && !reduceMotion && !model.personal.data.preferences.reduceMotion ? 1.015 : 1)
        }.buttonStyle(.plain)
        #if !os(tvOS)
        .onHover { value in withAnimation(.easeOut(duration: 0.15)) { hovered = value } }
        #endif
        .accessibilityLabel("\(stream.userName), live, \(stream.title), \(stream.viewerCount) viewers")
    }
}
struct ChannelsView: View {
    @Environment(AppModel.self) private var model
    @State private var filter = ""
    var body: some View {
        Group {
            if model.api == nil { LoginPrompt() }
            else {
                List {
                    if let error = model.error { Notice(error) }
                    if model.channels.isEmpty { EmptyState("Your followed channels", detail: "Follow channels on Twitch to see them here.", symbol: "person.2") }
                    ForEach(model.channels.filter { filter.isEmpty || $0.broadcasterName.localizedCaseInsensitiveContains(filter) }) { channel in
                        let live = model.followedStreams.first { $0.userId == channel.id }
                        Button { model.open(login: channel.broadcasterLogin, name: channel.broadcasterName, id: channel.id) } label: {
                            HStack { RemoteImage(model.avatars[channel.id], symbol: "person.crop.circle").frame(width: 44, height: 44).clipShape(Circle()); VStack(alignment: .leading) { Text(channel.broadcasterName).font(.headline); Text(live?.gameName ?? "Offline").font(.caption).foregroundStyle(.secondary) }; Spacer(); if let live { Text("LIVE · \(live.viewerCount.formatted())").font(.caption.bold()).foregroundStyle(TwitchyTheme.live) }; if model.personal.data.favorites.contains(channel.broadcasterLogin) { Image(systemName: "star.fill").foregroundStyle(TwitchyTheme.accent) } }
                        }.buttonStyle(.plain).padding(.vertical, 6)
                    }
                    if model.channelsCursor != nil { Button("Load more channels") { Task { await model.moreChannels() } } }
                }.searchable(text: $filter, prompt: "Filter followed channels").refreshable { await model.refresh() }
            }
        }
    }
}
struct CategoryDetail: View {
    @Environment(AppModel.self) private var model
    let category: TwitchCategory
    @State private var streams: [TwitchStream] = []
    @State private var cursor: String?
    @State private var error: String?
    var body: some View { ScrollView { VStack(alignment: .leading) { if let error { Notice(error) }; StreamSection(title: category.name, streams: streams); if cursor != nil { Button("Load more") { Task { await load(more: true) } } } }.padding(24) }.navigationTitle(category.name).task { await load(more: false) } }
    private func load(more: Bool) async { do { guard let api = model.api else { return }; let page = try await api.streams(gameID: category.id, after: more ? cursor : nil); streams = more ? streams + page.data : page.data; cursor = page.pagination?.cursor } catch { self.error = error.localizedDescription } }
}
struct OfflinePlayer: View {
    let url: URL
    @State private var player = AVPlayer()
    var body: some View { VideoPlayer(player: player).frame(minWidth: 300, minHeight: 240).onAppear { player.replaceCurrentItem(with: AVPlayerItem(url: url)); player.play() }.onDisappear { player.pause(); player.replaceCurrentItem(with: nil) } }
}
#Preview { RootView().environment(AppModel()) }
