#if os(iOS)
import SwiftUI
import TwitchyAPI
import TwitchyCore
import TwitchyDesignSystem
import TwitchyPlayback

struct MobileRootView: View {
    @Environment(AppModel.self) private var model
    @State private var tab: Destination = .home
    @State private var showingCompanion = false
    var body: some View {
        TabView(selection: $tab) {
            ForEach(Destination.allCases) { destination in
                NavigationStack {
                    MobileTabContent(destination: destination, goToDownloads: { tab = .downloads })
                        .navigationTitle(destination.rawValue)
                        .navigationBarTitleDisplayMode(.large)
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                if destination == .home {
                                    Button { showingCompanion = true } label: { Image(systemName: "tv") }
                                        .accessibilityLabel("Companion Mode").accessibilityIdentifier("companion.open")
                                }
                            }
                            ToolbarItem(placement: .topBarTrailing) {
                            Button { model.showingSettings = true } label: { Image(systemName: "gearshape") }
                                .accessibilityLabel("Settings").accessibilityIdentifier("settings.open")
                        } }
                        .navigationDestination(item: channelBinding(for: destination)) { selection in
                            MobileChannelView(selection: selection)
                                .toolbar(.visible, for: .navigationBar)
                                .toolbar(.hidden, for: .tabBar)
                        }
                }
                .tabItem { Label(destination.rawValue, systemImage: destination.icon) }.tag(destination)
            }
        }
        .defaultAppStorage(settingsStore)
        .overlay { MobilePlaybackOverlay() }
        .fullScreenCover(isPresented: $showingCompanion) { CompanionView().environment(model) }
        .statusBarHidden(model.mobile.fullscreen)
        .persistentSystemOverlays(model.mobile.fullscreen ? .hidden : .automatic)
        .onChange(of: model.playback.state) { _, _ in model.mobile.handleState() }
        .task(id: (model.mobile.selection?.broadcasterID ?? "") + (model.auth.session?.accessToken ?? "")) { model.mobile.connectChat() }
        .task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(10)); try Task.checkCancellation(); model.mobile.savePosition() }
                catch { return }
            }
        }
    }
    private func channelBinding(for destination: Destination) -> Binding<ChannelSelection?> {
        Binding(get: { tab == destination ? model.selectedChannel : nil }, set: { selection in
            guard tab == destination else { return }
            model.selectedChannel = selection
        })
    }
    private var settingsStore: UserDefaults {
        #if DEBUG && targetEnvironment(simulator)
        if MobileFixtures.enabled { return UserDefaults(suiteName: "Twitchy-ui-" + String(ProcessInfo.processInfo.processIdentifier))! }
        #endif
        return .standard
    }

}
private struct MobileTabContent: View {
    @Environment(AppModel.self) private var model
    let destination: Destination
    var goToDownloads: () -> Void
    var body: some View {
        Group {
            if model.isOffline && [.home, .channels, .search].contains(destination) {
                OfflineDiscoveryView(goToDownloads: goToDownloads)
            } else {
            switch destination {
            case .home: HomeView()
            case .channels: ChannelsView()
            case .search: SearchView()
            case .downloads: DownloadsView()
            case .profile: ProfileView()
            }
            }
        }
        .safeAreaInset(edge: .bottom) { if model.mobile.selection != nil { Color.clear.frame(height: 70) } }

    }
}

struct MobileChannelView: View {
    @Environment(AppModel.self) private var model
    let selection: ChannelSelection
    @State private var profile: TwitchUser?
    @State private var info: ChannelInfo?
    @State private var live: TwitchStream?
    @State private var videos: [Video] = []
    @State private var archives: [Video] = []
    @State private var clips: [Clip] = []
    @State private var videoCursor: String?
    @State private var archiveCursor: String?
    @State private var clipCursor: String?
    @State private var loadingSections: Set<String> = ["Videos", "Broadcasts", "Clips"]
    @State private var loading = true
    @State private var loadingMore = false
    @State private var error: String?
    @State private var tab = "Videos"
    @State private var libraryOrder = VideoSort.recent
    @State private var libraryGeneration = UUID()
    @State private var recentClipBefore: Date?
    @State private var recentClipSince = Date.now
    @State private var didAutoPlay = false
    @AppStorage("mobile.channel.grid") private var grid = false
    private var broadcasterID: String? { profile?.id ?? selection.broadcasterID }
    private var avatar: URL? { profile.flatMap { URL(string: $0.profileImageUrl) } ?? broadcasterID.flatMap { model.avatars[$0] } }
    private var channelLive: TwitchStream? { live ?? (model.streams + model.followedStreams + model.interestStreams).first { $0.userLogin == selection.login } }
    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                channelHeader
                VStack(alignment: .leading, spacing: 20) {
                channelActions
                libraryTabs
                if tab != "About" {
                    Text(libraryOrder == .recent ? (tab == "Clips" ? "Most recent · Last 30 days" : "Most recent") : "Most viewed")
                        .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("channel.sortLabel")
                }
                if tab == "About" {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(profile?.description ?? "This channel hasn’t added a description.").font(.subheadline).foregroundStyle(.secondary)
                        if let live = channelLive { Text(live.title).font(.headline); Text(live.gameName).font(.subheadline).foregroundStyle(.secondary) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                } else if loading || loadingSections.contains(tab) {
                    VStack(alignment: .leading, spacing: 14) {
                        RoundedRectangle(cornerRadius: 12).fill(Color(uiColor: .secondarySystemFill)).aspectRatio(16 / 9, contentMode: .fit)
                        Text("Channel videos").font(.headline).redacted(reason: .placeholder)
                        ProgressView().frame(maxWidth: .infinity)
                    }.accessibilityLabel("Loading channel videos")
                } else {
                    library
                    if empty { ContentUnavailableView("No \(tab.lowercased())", systemImage: "play.rectangle", description: Text("Published content from this channel will appear here.")) }
                    if hasMore { Button("Load more") { Task { await more() } }.frame(maxWidth: .infinity).disabled(loadingMore) }
                }
                if let error { HStack(alignment: .top) { Text(error).font(.footnote).foregroundStyle(.secondary); Spacer(); Button("Retry") { Task { await load() } } } }
                }.padding(20)
            }
        }
        .coordinateSpace(name: "mobileChannelScroll")
        .safeAreaInset(edge: .bottom) { if model.mobile.selection != nil { Color.clear.frame(height: 70) } }
        .background(Color(uiColor: .systemBackground))
        .navigationTitle(selection.name).navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("channel.page")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Sort by", selection: $libraryOrder) {
                        Text("Most recent").tag(VideoSort.recent)
                        Text("Most viewed").tag(VideoSort.views)
                    }.pickerStyle(.inline)
                    Divider()
                    Button(grid ? "List layout" : "Grid layout", systemImage: grid ? "list.bullet" : "square.grid.2x2") { grid.toggle() }
                    Link("Open on Twitch", destination: URL(string: "https://www.twitch.tv/\(selection.login)")!)
                } label: { Image(systemName: "ellipsis.circle") }.accessibilityLabel("Channel options").accessibilityIdentifier("channel.options")
            }
        }
        .refreshable { await load() }
        .task(id: selection.id.uuidString + "|" + libraryOrder.rawValue) {
            await load()
            guard !Task.isCancelled, !selection.returnToPlayback, !didAutoPlay else { return }
            didAutoPlay = true
            if let type = selection.contentType, let id = selection.contentID { watch(type: type, id: id, title: selection.name) }
        }
    }
    private var cover: URL? {
        if let text = profile?.offlineImageUrl, !text.isEmpty, let url = URL(string: text) { return url }
        return channelLive?.thumbnail
    }
    private var channelHeader: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                if let cover = cover {
                    RemoteImage(cover).frame(width: geometry.size.width, height: 260).clipped()
                } else { Color(uiColor: .secondarySystemBackground) }
                LinearGradient(colors: [.black.opacity(0.1), .black.opacity(0.75)], startPoint: .top, endPoint: .bottom)
                VStack(spacing: 8) {
                    RemoteImage(avatar, symbol: "person.fill").frame(width: 80, height: 80).clipShape(Circle())
                        .overlay { Circle().stroke(.white.opacity(0.85), lineWidth: 3) }.shadow(radius: 8, y: 4)
                    Text(profile?.displayName ?? selection.name).font(.title2.bold()).foregroundStyle(.white)
                    Text("@\(selection.login)").font(.caption).foregroundStyle(.white.opacity(0.8))
                }.padding(.bottom, 24)
            }
        }.frame(height: 260)
    }
    private var channelActions: some View {
        HStack(spacing: 12) {
            if let live = channelLive {
                Button { watch() } label: { Label("Watch live", systemImage: "play.fill").lineLimit(1).fixedSize(horizontal: true, vertical: false) }
                    .buttonStyle(.borderedProminent).clipShape(Capsule()).accessibilityIdentifier("channel.watchLive")
                Text("\(live.viewerCount.formatted()) viewers").font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
            } else if loading { ProgressView().frame(height: 36); Text("Loading channel…").font(.caption).foregroundStyle(.secondary) }
            else { Label("Offline", systemImage: "moon").font(.subheadline).foregroundStyle(.secondary) }
            Spacer(minLength: 0)

        }
    }
    private var libraryTabs: some View {
        Picker("Channel content", selection: $tab) {
            ForEach(["About", "Videos", "Broadcasts", "Clips"], id: \.self) { item in
                Text(item).tag(item).accessibilityIdentifier("channel.tab.\(item.lowercased())")
            }
        }.pickerStyle(.segmented)
    }
    @ViewBuilder private var library: some View {
        if grid {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 155))], spacing: 20) { libraryItems }
        } else {
            LazyVStack(alignment: .leading, spacing: 20) { libraryItems }
        }
    }
    @ViewBuilder private var libraryItems: some View {
        if tab == "Clips" {
            ForEach(clips) { clip in videoRow(title: clip.title, thumbnail: clip.thumbnailUrl, detail: clip.broadcasterName, badge: clip.duration.map(clipDuration) ?? "Clip", type: "clip", id: clip.id) }
        } else {
            ForEach(tab == "Broadcasts" ? archives : videos) { video in videoRow(title: video.title, thumbnail: video.thumbnailUrl, detail: video.viewCount.map { "\($0.formatted()) views" } ?? selection.name, badge: video.duration, type: "vod", id: video.id) }
        }
    }
    private func videoRow(title: String, thumbnail: String, detail: String, badge: String, type: String, id: String) -> some View {
        Button { watch(type: type, id: id, title: title, thumbnail: thumbnail, duration: badge) } label: {
            VStack(alignment: .leading, spacing: 10) {
                RemoteImage(URL(string: thumbnail.replacingOccurrences(of: "%{width}", with: "640").replacingOccurrences(of: "%{height}", with: "360")))
                    .aspectRatio(16 / 9, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(alignment: .bottomTrailing) { Text(badge).font(.caption.bold()).padding(5).background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 4)).foregroundStyle(.white).padding(8) }
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(2)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }.buttonStyle(.plain)
        .contextMenu {
            Button("Watch", systemImage: "play") { watch(type: type, id: id, title: title, thumbnail: thumbnail, duration: badge) }
            if model.sources.active?.capabilities?.clientSideDownloads == true {
                Button("Download", systemImage: "arrow.down.circle") { Task {
                    do { await model.downloads.enqueue(client: try model.sources.client(), type: type, contentID: id, quality: model.personal.data.preferences.preferredQuality, metadata: .init(title: title, channel: selection.name, thumbnailURL: thumbnailURL(thumbnail), duration: badge)) }
                    catch { self.error = error.localizedDescription }
                } }
            }
        }
    }
    private var empty: Bool { tab == "Clips" ? clips.isEmpty : tab == "Broadcasts" ? archives.isEmpty : videos.isEmpty }
    private var hasMore: Bool { (tab == "Clips" ? (libraryOrder == .recent ? recentClipBefore.map { _ in "recent" } : clipCursor) : tab == "Broadcasts" ? archiveCursor : videoCursor) != nil }
    private func watch(type: String = "live", id: String? = nil, title: String? = nil, thumbnail: String? = nil, duration: String? = nil) {
        var channel = selection; channel.broadcasterID = broadcasterID
        model.mobile.start(channel, type: type, id: id, title: title ?? channelLive?.title ?? info?.title, category: channelLive?.gameName ?? info?.gameName, avatar: avatar, thumbnailURL: thumbnail.flatMap { thumbnailURL($0) }, duration: duration)
    }
    private func clipDuration(_ duration: Double) -> String {
        guard duration.isFinite, duration >= 0, duration < Double(Int32.max) else { return "Clip" }
        let seconds = Int(duration.rounded())
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
    private func thumbnailURL(_ value: String) -> URL? {
        URL(string: value.replacingOccurrences(of: "%{width}", with: "320").replacingOccurrences(of: "%{height}", with: "180"))
    }
    private func sortedVideos(_ values: [Video]) -> [Video] {
        values.sorted {
            if libraryOrder == .views, $0.viewCount != $1.viewCount { return ($0.viewCount ?? 0) > ($1.viewCount ?? 0) }
            if $0.createdAt != $1.createdAt { return ($0.createdAt ?? "") > ($1.createdAt ?? "") }
            return $0.id < $1.id
        }
    }
    private func load() async {
        let generation = UUID(); libraryGeneration = generation
        let order = libraryOrder
        loading = true; loadingSections = ["Videos", "Broadcasts", "Clips"]; loadingMore = false; error = nil
        videos = []; archives = []; clips = []
        videoCursor = nil; archiveCursor = nil; clipCursor = nil; recentClipBefore = nil
        defer { if generation == libraryGeneration { loading = false; loadingSections = [] } }
        #if DEBUG && targetEnvironment(simulator)
        if MobileFixtures.enabled {
            profile = MobileFixtures.profile; live = MobileFixtures.stream
            videos = sortedVideos(MobileFixtures.videos); archives = videos; clips = MobileFixtures.clips
            model.mobile.updateChannel(login: selection.login, broadcasterID: profile?.id, avatar: avatar, category: live?.gameName)
            return
        }
        #endif
        guard let api = model.api else { error = "Sign in to Twitch to load this channel."; return }
        do {
            let profilePage = try await api.users(logins: [selection.login])
            try Task.checkCancellation(); guard generation == libraryGeneration else { return }
            profile = profilePage.data.first
            let livePage = try await api.streams(login: selection.login)
            try Task.checkCancellation(); guard generation == libraryGeneration else { return }
            live = livePage.data.first
            guard let id = broadcasterID else { error = "This channel could not be found."; return }
            loading = false
            model.mobile.updateChannel(login: selection.login, broadcasterID: id, avatar: avatar, category: live?.gameName)
            do {
                let page = try await api.channel(id: id)
                try Task.checkCancellation(); guard generation == libraryGeneration else { return }
                info = page.data.first
            } catch is CancellationError { return } catch { }
            do {
                let page = try await api.videos(userID: id, sort: order)
                try Task.checkCancellation(); guard generation == libraryGeneration else { return }
                videos = sortedVideos(page.data); videoCursor = page.pagination?.cursor
            } catch is CancellationError { return } catch { if generation == libraryGeneration { self.error = "Videos could not be loaded." } }
            guard generation == libraryGeneration, !Task.isCancelled else { return }
            loadingSections.remove("Videos")
            do {
                let page = try await api.videos(userID: id, type: "archive", sort: order)
                try Task.checkCancellation(); guard generation == libraryGeneration else { return }
                archives = sortedVideos(page.data); archiveCursor = page.pagination?.cursor
            } catch is CancellationError { return } catch { if generation == libraryGeneration { self.error = "Broadcasts could not be loaded." } }
            guard generation == libraryGeneration, !Task.isCancelled else { return }
            loadingSections.remove("Broadcasts")
            do {
                if order == .recent {
                    let end = Date(timeIntervalSince1970: floor(Date.now.timeIntervalSince1970)), since = end.addingTimeInterval(-30 * 86400)
                    let page = try await api.recentClips(broadcasterID: id, since: since, before: end)
                    try Task.checkCancellation(); guard generation == libraryGeneration else { return }
                    clips = page.data; recentClipBefore = page.nextBefore; recentClipSince = since
                } else {
                    let page = try await api.clips(broadcasterID: id)
                    try Task.checkCancellation(); guard generation == libraryGeneration else { return }
                    clips = page.data; clipCursor = page.pagination?.cursor
                }
            } catch is CancellationError { return } catch { if generation == libraryGeneration { self.error = "Clips could not be loaded." } }
        } catch is CancellationError { }
        catch { if generation == libraryGeneration { self.error = error.localizedDescription } }
    }
    private func more() async {
        guard !loadingMore, let api = model.api, let id = broadcasterID else { return }
        let selected = tab, generation = libraryGeneration, order = libraryOrder
        loadingMore = true
        defer { if generation == libraryGeneration { loadingMore = false } }
        do {
            if selected == "Clips" {
                let values: [Clip]
                if order == .recent, let before = recentClipBefore {
                    let page = try await api.recentClips(broadcasterID: id, since: recentClipSince, before: before)
                    try Task.checkCancellation(); guard generation == libraryGeneration else { return }
                    values = page.data; recentClipBefore = page.nextBefore
                } else if let cursor = clipCursor {
                    let page = try await api.clips(broadcasterID: id, after: cursor)
                    try Task.checkCancellation(); guard generation == libraryGeneration else { return }
                    values = page.data; clipCursor = page.pagination?.cursor
                } else { return }
                let existing = Set(clips.map(\.id)); clips += values.filter { !existing.contains($0.id) }
            } else {
                guard let cursor = selected == "Broadcasts" ? archiveCursor : videoCursor else { return }
                let page = try await api.videos(userID: id, after: cursor, type: selected == "Broadcasts" ? "archive" : nil, sort: order)
                try Task.checkCancellation(); guard generation == libraryGeneration else { return }
                if selected == "Broadcasts" { let existing = Set(archives.map(\.id)); archives = sortedVideos(archives + page.data.filter { !existing.contains($0.id) }); archiveCursor = page.pagination?.cursor }
                else { let existing = Set(videos.map(\.id)); videos = sortedVideos(videos + page.data.filter { !existing.contains($0.id) }); videoCursor = page.pagination?.cursor }
            }
        } catch { if generation == libraryGeneration && !Task.isCancelled { self.error = error.localizedDescription } }
    }
}
#endif
