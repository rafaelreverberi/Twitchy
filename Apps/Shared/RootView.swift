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
    #if os(macOS)
    @State private var showingCompanion = false
    #endif
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        @Bindable var model = model
        Group {
            #if os(macOS)
            macSplit
            #elseif os(tvOS)
            TVRootView()
            #else
            MobileRootView()
            #endif
        }
        .background(TwitchyTheme.background)
        .task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)); try Task.checkCancellation(); model.sampleViewing() }
                catch { return }
            }
        }
        .task {
            guard !model.isDiscoveryFixture else { return }
            #if DEBUG && os(macOS)
            guard ProcessInfo.processInfo.environment["TWITCHY_UI_COMPANION_FIXTURE"] == nil else { return }
            #endif
            #if os(iOS)
            guard !model.isMobileFixture else { return }
            #endif
            #if os(tvOS)
            guard !TVFixtures.enabled else { return }
            #endif
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(45)); try Task.checkCancellation(); await model.sync.sync() }
                catch { return }
            }
        }
        .onChange(of: model.personal.data.oauthSettings) { _, _ in model.applyOAuthSettings() }
        .onChange(of: model.playback.isPaused) { _, _ in model.sampleViewing() }
        .onChange(of: model.playback.state) { _, _ in model.sampleViewing() }
        .task(id: model.personal.interests.map(\.login)) { await model.refreshInterests() }
        #if !os(tvOS)
        .sheet(isPresented: $model.showingSettings) { SettingsView().environment(model) }
        .sheet(isPresented: Binding(get: { !model.personal.data.onboardingComplete }, set: { if !$0 { model.personal.data.onboardingComplete = true } })) { WelcomeView().environment(model) }
        #endif
        .onChange(of: scenePhase) { _, phase in
            #if os(iOS)
            if phase == .active { model.mobile.enterForeground() }
            #endif
            if phase == .active { Task {
                guard model.startupComplete, !model.isDiscoveryFixture else { return }
                await model.restoreLibrary()
                await model.sync.sync()
                await model.refreshInterests()
            } }
            if phase == .background {
                model.chat.disconnect()
                #if os(iOS)
                UIApplication.shared.isIdleTimerDisabled = false
                #endif
                #if os(iOS)
                model.mobile.enterBackground()
                #elseif os(tvOS)
                if !model.playback.pictureInPictureActive { Task { await model.playback.stop() } }
                #endif
            }
        }
        .onChange(of: model.playback.pictureInPictureActive) { _, active in
            #if os(tvOS)
            if !active, scenePhase == .background { Task { await model.playback.stop() } }
            #endif
        }
        .onChange(of: model.auth.status) { _, _ in Task { if model.startupComplete { await model.refresh() } } }
        .onChange(of: model.auth.session?.accessToken) { _, _ in Task { if model.startupComplete { await model.refresh() } } }
        .onChange(of: model.sources.selected?.baseURL) { _, _ in
            #if os(macOS)
            if !model.isOfflinePlayback { model.stopDesktopPlayback() }
            #elseif os(iOS)
            model.mobile.sourceChanged()
            #else
            Task { await model.playback.stop() }
            #endif
        }
        .onChange(of: model.sources.activeID) { _, _ in
            model.personal.data.preferences.preferredQuality = "auto"
            #if os(macOS)
            if !model.isOfflinePlayback { model.stopDesktopPlayback() }
            #elseif os(iOS)
            model.mobile.sourceChanged()
            #else
            Task { await model.playback.stop() }
            #endif
        }
    }
    #if os(macOS)
    private var macSplit: some View {
        NavigationSplitView {
            List(selection: Binding(get: { model.selectedChannel == nil ? destination : nil }, set: { value in
                // List deselects its row when a watch/channel route opens. That
                // nil write must not dismiss the route that triggered it.
                guard let value else { return }
                model.selectedChannel = nil; destination = value
            })) {
                Section { HStack { BrandMark(); Text("Twitchy").font(.title2.bold()) }.padding(.vertical, 14) }
                Section {
                    ForEach(Destination.allCases) { item in
                        Label(item.rawValue, systemImage: item.icon).tag(item)
                            .accessibilityIdentifier("nav.\(item.rawValue.lowercased())")
                    }
                }
            }
            .listStyle(.sidebar).navigationTitle("Twitchy")
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 14) {
                    if model.nowPlaying != nil { DesktopNowPlayingView() }
                    HStack {
                        Button { model.showingSettings = true } label: {
                            Label("Settings", systemImage: "gearshape").frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(.plain).accessibilityIdentifier("settings.open")
                        Button { showingCompanion = true } label: { Image(systemName: "tv") }
                            .buttonStyle(.plain).accessibilityLabel("Companion Mode").accessibilityIdentifier("companion.open")
                    }
                }.padding(16).background(.bar)
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 300)
        } detail: {
            NavigationStack {
                Group {
                    if let selection = model.selectedChannel {
                        if let item = model.offlineDownload, selection.offlineDownloadID == item.id { DesktopOfflineWatchView(item: item) }
                        else { ChannelDetail(selection: selection).id(selection.id) }
                    } else if model.isOffline && (destination == nil || [.home, .channels, .search].contains(destination!)) {
                        OfflineDiscoveryView { destination = .downloads }
                    } else if destination == .home || destination == nil {
                        MacHomeView()
                    } else { screen(destination!) }
                }
                .toolbar {
                    if destination != .search || model.selectedChannel != nil {
                    ToolbarItem(placement: .automatic) {
                        Button { model.selectedChannel = nil; destination = .search } label: {
                            Label("Search streamers, games or categories", systemImage: "magnifyingglass")
                        }.keyboardShortcut("k", modifiers: .command).accessibilityIdentifier("search.open")
                    }
                    }
                }
            }
        }
        .opacity(showingCompanion ? 0 : 1)
        .accessibilityHidden(model.desktopFullscreen || showingCompanion)
        .allowsHitTesting(!model.desktopFullscreen && !showingCompanion)
        .overlay {
            if model.desktopFullscreen {
                DesktopWatchPlayer(theater: Binding(get: { model.desktopTheater }, set: { model.desktopTheater = $0 }), fullscreenPresentation: true)
                    .background(.black).ignoresSafeArea()
            }
        }
        .overlay {
            if showingCompanion {
                CompanionView(close: { showingCompanion = false })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .windowBackgroundColor))
            }
        }
        .toolbar(model.desktopFullscreen || showingCompanion ? .hidden : .automatic, for: .windowToolbar)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { notification in
            guard let window = notification.object as? NSWindow, window === model.desktopPlayerSurface.view.window else { return }
            model.desktopFullscreen = false
        }
        .frame(minWidth: 940, minHeight: 640)
        .task(id: model.playback.session?.sessionId) {
            while model.nowPlaying != nil && !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(10)); try Task.checkCancellation(); model.saveDesktopPosition() }
                catch { return }
            }
        }
        .onChange(of: model.playback.state) { _, state in if state == .failed { model.retryDesktopPlaybackIfNeeded() } }
        .onDisappear { model.stopDesktopPlayback() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in model.stopDesktopPlayback() }
    }
    #endif
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
        #if !os(macOS)
        .toolbar { ToolbarItem { Button { model.showingSettings = true } label: { Image(systemName: "gearshape") }.accessibilityLabel("Settings").accessibilityIdentifier("settings.open") } }
        #endif
    }
}
#if !os(tvOS)
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
                    Button("Sign in with Twitch") { model.personal.data.onboardingComplete = true; Task { await model.login() } }.buttonStyle(.borderedProminent)
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
#endif
struct LoginPrompt: View {
    @Environment(AppModel.self) private var model
    var body: some View { VStack { EmptyState("Connect with Twitch", detail: "Twitch requires an access token for discovery. Sign in to browse channels and categories, even without a streaming source.", symbol: "person.crop.circle.badge.checkmark"); Button(model.auth.session == nil ? "Sign in with Twitch" : "Reconnect") { Task { if model.auth.session != nil { try? await model.auth.validate(); await model.refresh() }; if model.auth.session == nil { await model.login() } else if model.api == nil { model.showingSettings = true } } }.buttonStyle(.borderedProminent) }.padding(.bottom, 32) }
}
struct HomeView: View {
    @Environment(AppModel.self) private var model
    private var showingSkeleton: Bool {
        model.libraryLoading
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Your live lineup").font(.title.bold())
                        Text("Your channels. New discoveries.").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { Task { await model.restoreLibrary() } } label: { Image(systemName: "arrow.clockwise") }
                        .accessibilityLabel("Refresh streams").disabled(model.loading || showingSkeleton)
                }
                if showingSkeleton { DiscoverySkeleton() }
                if !showingSkeleton {
                if let error = model.error { Notice(error) }
                if model.api == nil { LoginPrompt() }
                else {
                    #if os(iOS)
                    if let featured = model.recommendedStreams.first ?? model.followedStreams.first ?? model.streams.first {
                        VStack(alignment: .leading, spacing: 12) {
                            StreamCard(stream: featured)
                        }
                    }
                    #endif
                    if !model.recommendedStreams.isEmpty { StreamSection(title: "For you · Live now", streams: model.recommendedStreams) }
                    if !model.followedStreams.isEmpty { StreamSection(title: "Following · Live now", streams: model.followedStreams) }
                    #if os(tvOS)
                    let resumable = model.personal.data.history.filter { $0.contentID != nil && $0.position > 0 }
                    if !resumable.isEmpty {
                        Text("Continue Watching").font(.title2.bold())
                        ForEach(resumable) { entry in Button { model.selectedChannel = .init(login: entry.login, name: entry.title, contentType: entry.contentType, contentID: entry.contentID, resumePosition: entry.position) } label: { Label("\(entry.title) · \(Int(entry.position))s", systemImage: "play.circle") } }
                    }
                    if !model.personal.data.history.isEmpty { localSection("Recently watched", logins: model.personal.data.history.prefix(8).map(\.login)) }
                    #else
                    if !model.personal.data.history.isEmpty { WatchHistoryRow() }
                    #endif
                    StreamSection(title: "Popular right now", streams: model.streams)
                    if model.streamsCursor != nil { Button("Load more streams") { Task { await model.moreStreams() } } }
                    Text("Popular categories").font(.title2.bold())
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 130, maximum: 190))], spacing: 20) { ForEach(model.categories) { category in NavigationLink { CategoryDetail(category: category) } label: { VStack(alignment: .leading) { DiscoveryImage(URL(string: category.boxArtUrl.replacingOccurrences(of: "{width}", with: "285").replacingOccurrences(of: "{height}", with: "380"))).aspectRatio(0.75, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 10)); Text(category.name).font(.headline).lineLimit(1) } }.buttonStyle(.plain) } }
                    if model.streams.isEmpty && !model.loading { EmptyState("No streams loaded", detail: "Refresh to try Twitch again.") }
                }
                }
            }.padding(24)
        }.refreshable { await model.restoreLibrary() }
    }

    #if os(tvOS)
    private func localSection(_ title: String, logins: [String]) -> some View { VStack(alignment: .leading, spacing: 12) { Text(title).font(.title2.bold()); ScrollView(.horizontal) { HStack { ForEach(logins, id: \.self) { login in Button { model.open(login: login, name: login) } label: { Label(login, systemImage: "person.crop.circle").padding(14).background(TwitchyTheme.secondary, in: RoundedRectangle(cornerRadius: 10)) }.buttonStyle(.plain) } } } } }
    #endif
}
struct StreamSection: View {
    var title: String; var streams: [TwitchStream]
    var onSelect: ((TwitchStream) -> Void)? = nil
    private var columns: [GridItem] {
        #if os(iOS)
        [GridItem(.adaptive(minimum: 155, maximum: 440))]
        #else
        [GridItem(.adaptive(minimum: 270, maximum: 440))]
        #endif
    }
    var body: some View { VStack(alignment: .leading, spacing: 16) { Text(title).font(.title2.bold()); LazyVGrid(columns: columns, spacing: 24) { ForEach(streams) { StreamCard(stream: $0, onSelect: onSelect) } } } }
}
struct StreamCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let stream: TwitchStream
    var onSelect: ((TwitchStream) -> Void)? = nil
    @State private var hovered = false
    var body: some View {
        Button {
            if let onSelect { onSelect(stream); return }
            #if os(iOS)
            model.mobile.start(.init(login: stream.userLogin, name: stream.userName, broadcasterID: stream.userId), title: stream.title, category: stream.gameName, avatar: model.avatars[stream.userId])
            #else
            model.open(login: stream.userLogin, name: stream.userName, id: stream.userId)
            #endif
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                DiscoveryImage(stream.thumbnail).aspectRatio(16 / 9, contentMode: .fit).overlay(alignment: .topLeading) { Text("LIVE").font(.caption.bold()).padding(.horizontal, 8).padding(.vertical, 5).background(TwitchyTheme.live, in: RoundedRectangle(cornerRadius: 5)).foregroundStyle(.black).padding(10) }.overlay(alignment: .bottomLeading) { Text("\(stream.viewerCount.formatted()) viewers").font(.caption).padding(6).background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 4)).padding(10) }.clipShape(RoundedRectangle(cornerRadius: 12))
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
            if !model.startupComplete || (model.loading && model.channels.isEmpty) { DiscoverySkeleton(style: .channels).padding(24) }
            else if model.api == nil { LoginPrompt() }
            else {
                List {
                    if let error = model.error { Notice(error) }
                    if model.channels.isEmpty { EmptyState("Your followed channels", detail: "Follow channels on Twitch to see them here.", symbol: "person.2") }
                    ForEach(model.channels.filter { filter.isEmpty || $0.broadcasterName.localizedCaseInsensitiveContains(filter) }) { channel in
                        let live = model.followedStreams.first { $0.userId == channel.id }
                        Button { model.open(login: channel.broadcasterLogin, name: channel.broadcasterName, id: channel.id) } label: {
                            HStack { DiscoveryImage(model.avatars[channel.id], symbol: "person.crop.circle").frame(width: 44, height: 44).clipShape(Circle()); VStack(alignment: .leading) { Text(channel.broadcasterName).font(.headline); Text(live?.gameName ?? "Offline").font(.caption).foregroundStyle(.secondary) }; Spacer(); if let live { Text("LIVE · \(live.viewerCount.formatted())").font(.caption.bold()).foregroundStyle(TwitchyTheme.live) } }
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
#Preview { RootView().environment(AppModel()) }

struct DiscoveryImage: View {
    let url: URL?
    var symbol = "play.rectangle"
    init(_ url: URL?, symbol: String = "play.rectangle") { self.url = url; self.symbol = symbol }
    var body: some View {
        AsyncImage(url: url) { phase in
            if let image = phase.image { image.resizable().scaledToFill() }
            else if phase.error != nil || url == nil {
                Rectangle().fill(TwitchyTheme.secondary)
                    .overlay { Image(systemName: symbol).foregroundStyle(.secondary) }
            } else {
                Rectangle().fill(TwitchyTheme.secondary).modifier(DiscoveryShimmer())
            }
        }.clipped()
    }
}

struct DiscoverySkeleton: View {
    enum Style { case home, channels }
    var style: Style = .home
    private var minimumWidth: CGFloat {
        #if os(tvOS)
        380
        #elseif os(macOS)
        270
        #else
        155
        #endif
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            if style == .home {
                #if os(iOS)
            card
                #else
                HStack(alignment: .center, spacing: 32) {
                    mediaPlaceholder.frame(maxWidth: 850)
                    VStack(alignment: .leading, spacing: 20) {
                        Text("Channel name").font(.title.bold())
                        Text("Stream title goes here").font(.headline)
                        Text("Category").font(.subheadline)
                    }.redacted(reason: .placeholder).modifier(DiscoveryShimmer())
                    Spacer()
                }
                #endif
            Text("Popular right now").font(.title2.bold())
            LazyVGrid(columns: [GridItem(.adaptive(minimum: minimumWidth, maximum: 520))], spacing: 24) {
                ForEach(0..<4) { _ in card }
            }
            Text("Popular categories").font(.title2.bold())
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130, maximum: 190))], spacing: 20) {
                ForEach(0..<3) { _ in
                    RoundedRectangle(cornerRadius: 10).fill(TwitchyTheme.secondary)
                        .aspectRatio(0.75, contentMode: .fit).modifier(DiscoveryShimmer())
                }
            }
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: minimumWidth))], spacing: 24) {
                    ForEach(0..<8) { _ in
                        HStack(spacing: 16) {
                            Circle().fill(TwitchyTheme.secondary).frame(width: 64, height: 64)
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Channel name").font(.headline)
                                Text("Channel details").font(.subheadline)
                            }.redacted(reason: .placeholder)
                            Spacer()
                        }.modifier(DiscoveryShimmer())
                    }
                }
            }
        }.accessibilityElement(children: .ignore)
            .accessibilityLabel(style == .home ? "Loading streams" : "Loading channels")
            .accessibilityIdentifier(style == .home ? "home.skeleton" : "channels.skeleton")
    }
    private var card: some View {
        VStack(alignment: .leading, spacing: 10) {
            RoundedRectangle(cornerRadius: 12).fill(TwitchyTheme.secondary).aspectRatio(16 / 9, contentMode: .fit)
            Text("Channel name").font(.headline)
            Text("Stream title goes here").font(.subheadline).lineLimit(2)
            Text("Category").font(.caption)
        }.redacted(reason: .placeholder).modifier(DiscoveryShimmer())
    }
    private var mediaPlaceholder: some View {
        RoundedRectangle(cornerRadius: 12).fill(TwitchyTheme.secondary)
            .aspectRatio(16 / 9, contentMode: .fit).modifier(DiscoveryShimmer())
    }
}

struct OfflineDiscoveryView: View {
    @Environment(AppModel.self) private var model
    var goToDownloads: (() -> Void)? = nil
    var body: some View {
        VStack(spacing: 24) {
            Text("You’re offline").font(.largeTitle.bold()).multilineTextAlignment(.center)
                .accessibilityIdentifier("discovery.offline")
            #if os(tvOS)
            Button("Try again") { Task { await model.restoreLibrary() } }
                .buttonStyle(.borderedProminent).accessibilityIdentifier("discovery.retry")
            #else
            if let goToDownloads {
                Button("Go to Downloads", action: goToDownloads)
                    .buttonStyle(.borderedProminent).accessibilityIdentifier("home.downloads")
            }
            #endif
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(32)
            .background(TwitchyTheme.background).accessibilityElement(children: .contain)
    }
}

struct DiscoveryShimmer: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var moving = false
    private var animated: Bool { !reduceMotion && !model.personal.data.preferences.reduceMotion }
    func body(content: Content) -> some View {
        content.overlay {
            if animated {
                GeometryReader { geometry in
                    LinearGradient(colors: [.clear, .white.opacity(0.12), .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: geometry.size.width * 0.6)
                        .offset(x: moving ? geometry.size.width : -geometry.size.width * 0.6)
                        .animation(.linear(duration: 1.35).repeatForever(autoreverses: false), value: moving)
                        .onAppear { moving = true }
                }.mask(content).allowsHitTesting(false)
            }
        }
    }
}
