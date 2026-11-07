import SwiftUI
import TwitchyCore
import TwitchyAPI
import TwitchyAuth
import TwitchySources
import TwitchyPlayback
import TwitchyChat
import AVKit
import Network

@MainActor @Observable final class AppModel {
    #if DEBUG
    let auth = TwitchAuthManager(secrets: ProcessInfo.processInfo.environment["TWITCHY_UI_DISCOVERY_FIXTURE"] != nil ? DiscoveryFixtureSecrets() : KeychainStore(service: "com.rafaelreverberi.Twitchy.twitch"))
    #else
    let auth = TwitchAuthManager()
    #endif
    #if DEBUG && os(tvOS) && targetEnvironment(simulator)
    let sources = StreamingSourceManager(url: TVFixtures.enabled ? URL.temporaryDirectory.appendingPathComponent("TV-sources-" + UUID().uuidString + ".json") : TwitchyStoragePaths.directory.appendingPathComponent("sources.json"), secrets: TVFixtures.sourceSecrets)
    #elseif DEBUG
    let sources = StreamingSourceManager(url: (ProcessInfo.processInfo.environment["TWITCHY_UI_SOURCES_FIXTURE"] == "1") ? URL.temporaryDirectory.appendingPathComponent("sources-ui-" + UUID().uuidString + ".json") : TwitchyStoragePaths.directory.appendingPathComponent("sources.json"), secrets: ProcessInfo.processInfo.environment["TWITCHY_UI_SOURCES_FIXTURE"] == "1" ? SourceFixtureSecrets() as any SecretStore : KeychainStore(service: "com.rafaelreverberi.Twitchy.sources"))
    #else
    let sources = StreamingSourceManager()
    #endif
    #if DEBUG && os(iOS) && targetEnvironment(simulator)
    let personal = PersonalStore(url: (MobileFixtures.enabled) ? URL.temporaryDirectory.appendingPathComponent("Twitchy-ui-" + UUID().uuidString + ".json") : PersonalStore.defaultURL)
    #elseif DEBUG && os(tvOS) && targetEnvironment(simulator)
    let personal = PersonalStore(url: TVFixtures.enabled ? URL.temporaryDirectory.appendingPathComponent("TV-personal-" + UUID().uuidString + ".json") : PersonalStore.defaultURL)
    #elseif DEBUG && os(macOS)
    let personal = PersonalStore(url: (ProcessInfo.processInfo.environment["TWITCHY_UI_COMPANION_FIXTURE"] != nil || ProcessInfo.processInfo.environment["TWITCHY_UI_DISCOVERY_FIXTURE"] != nil) ? URL.temporaryDirectory.appendingPathComponent("Twitchy-companion-ui-" + UUID().uuidString + ".json") : PersonalStore.defaultURL)
    #else
    let personal = PersonalStore()
    #endif
    let playback = PlaybackController()
    @ObservationIgnored lazy var playbackResolver = PlaybackFallbackCoordinator(sources: sources)
    var downloadSource: StreamingSource? {
        let source = playback.hasMedia && playback.activeSourceID != nil ? sources.sources.first { $0.id == playback.activeSourceID } : sources.active
        guard let source, source.enabled, source.playbackKind == .twitchyServer,
              source.capabilities?.downloads == true, source.capabilities?.clientSideDownloads == true,
              playback.activeSourceID == source.id || sources.availability[source.id] == true else { return nil }
        return source
    }
    var canDownload: Bool { downloadSource != nil }
    let chat = ChatController()
    #if DEBUG && os(iOS) && targetEnvironment(simulator)
    let downloads = DownloadManager(directory: MobileFixtures.enabled ? URL.temporaryDirectory.appendingPathComponent("UI-downloads-" + UUID().uuidString) : TwitchyStoragePaths.directory.appendingPathComponent("Downloads"))
    #else
    let downloads = DownloadManager()
    #endif
    #if os(tvOS)
    var tvCompanionBroadcasterID: String?
    #endif
    #if os(iOS)
    var isMobileFixture: Bool {
        #if DEBUG && targetEnvironment(simulator)
        MobileFixtures.enabled
        #else
        false
        #endif
    }
    @ObservationIgnored lazy var mobile = MobilePlaybackCoordinator(model: self)
    #endif
    var startupComplete = false
    var isOffline: Bool { networkOffline || auth.connectionUnavailable || libraryUnavailable }
    var accountSignedIn: Bool { auth.session != nil }
    var accountStatus: String { accountSignedIn && isOffline ? "Signed in · Offline" : auth.status }
    var libraryLoading: Bool { !startupComplete || (loading && streams.isEmpty && followedStreams.isEmpty) }
    var isDiscoveryFixture: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.environment["TWITCHY_UI_DISCOVERY_FIXTURE"] != nil { return true }
        #endif
        #if os(iOS)
        return isMobileFixture
        #elseif os(tvOS)
        return TVFixtures.enabled
        #else
        return ProcessInfo.processInfo.environment["TWITCHY_UI_COMPANION_FIXTURE"] != nil
        #endif
    }
    private var libraryUnavailable = false
    var networkOffline = false
    @ObservationIgnored private var connectivityMonitor: NWPathMonitor?
    @ObservationIgnored private var pendingReconnect = false
    @ObservationIgnored private var sourceCheckTask: Task<Void, Never>?
    private func checkSourcesAfterNetworkChange() {
        sourceCheckTask?.cancel()
        sourceCheckTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(1)); try Task.checkCancellation() } catch { return }
            guard let self, !networkOffline, !isDiscoveryFixture else { return }
            await sources.refreshAvailability(force: true)
        }
    }
    private func startConnectivityMonitoring() {
        guard connectivityMonitor == nil, !isDiscoveryFixture else { return }
        let monitor = NWPathMonitor()
        connectivityMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            let offline = path.status != .satisfied
            Task { @MainActor [weak self] in
                guard let self else { return }
                let reconnecting = self.networkOffline && !offline
                self.networkOffline = offline
                if !offline { self.checkSourcesAfterNetworkChange() }
                if reconnecting {
                    if self.startupComplete { await self.restoreLibrary() }
                    else { self.pendingReconnect = true }
                }
            }
        }
        monitor.start(queue: DispatchQueue(label: "Twitchy.connectivity"))
    }
    func restoreLibrary() async {
        guard !networkOffline, !loading else { return }
        libraryUnavailable = false
        if auth.session == nil { await auth.restore(explicitDeviceClientID: explicitDeviceClientID) }
        else { do { try await auth.validate() } catch { noteConnectionError(error) } }
        await refresh()
    }
    func noteConnectionError(_ error: Error) {
        if let error = error as? URLError, [.notConnectedToInternet, .networkConnectionLost].contains(error.code) { libraryUnavailable = true }
    }
    private var accountCache: AccountProfileCache {
        AccountProfileCache(url: TwitchyStoragePaths.directory.appendingPathComponent("account-profile.json"))
    }
    @ObservationIgnored lazy var sync = AppDataSync(personal: personal, sources: sources, cloud: makeCloudStore())
    private func makeCloudStore() -> CloudSyncStore {
        #if DEBUG && os(tvOS) && targetEnvironment(simulator)
        if TVFixtures.enabled { return CloudSyncStore(transport: nil, file: URL.temporaryDirectory.appendingPathComponent("TV-sync-" + UUID().uuidString), secrets: TVFixtureSecrets()) }
        #endif
        return CloudSyncStore(transport: PrivateCloudTransport())
    }
    @ObservationIgnored private var syncStarted = false
    @ObservationIgnored private var applyingOAuthSettings = false
    @ObservationIgnored private var viewingLogin: String?
    @ObservationIgnored private var viewing: WatchSession?
    @ObservationIgnored private var viewingTick = ProcessInfo.processInfo.systemUptime
    @ObservationIgnored private var wasPlaying = false
    var interestStreams: [TwitchStream] = []
    var recommendedStreams: [TwitchStream] {
        let scores = Dictionary(uniqueKeysWithValues: personal.interests.map { ($0.login, $0.score) })
        var unique: [String: TwitchStream] = [:]
        for stream in streams + followedStreams + interestStreams where scores[stream.userLogin.lowercased()] != nil { unique[stream.userLogin.lowercased()] = stream }
        return unique.values.sorted {
            let a = scores[$0.userLogin.lowercased()] ?? 0, b = scores[$1.userLogin.lowercased()] ?? 0
            return a == b ? $0.userLogin < $1.userLogin : a > b
        }
    }
    func sampleViewing() {
        let tick = ProcessInfo.processInfo.systemUptime, elapsed = tick - viewingTick
        viewingTick = tick
        let playing = playback.player.timeControlStatus == .playing && playback.hasMedia
        defer { wasPlaying = playing }
        if viewing == nil, playing, let login = viewingLogin {
            viewing = WatchSession(login: login); wasPlaying = false
        }
        guard var session = viewing else { return }
        if wasPlaying && elapsed > 0 && elapsed < 15 {
            session.seconds += elapsed; session.watchedAt = .now; viewing = session
            personal.recordViewing(session)
        }
        if playback.state == .idle { viewing = nil; viewingLogin = nil }
    }
    func refreshInterests() async {
        guard let api else { interestStreams = []; return }
        let logins = Array(personal.interests.prefix(100).map(\.login))
        guard !logins.isEmpty else { interestStreams = []; return }
        do {
            let page = try await api.streams(logins: logins)
            try Task.checkCancellation()
            guard self.api === api else { return }
            interestStreams = page.data
        } catch { /* Discovery remains usable when the personalized request fails. */ }
    }
    #if os(macOS)
    @ObservationIgnored let discordPresence = DiscordPresence()
    var desktopAvatarURL: URL?
    var discordViewing: DiscordPresence.Viewing? {
        guard !isOfflinePlayback, let active = nowPlaying else { return nil }
        let selection = active.selection
        let request = playback.currentRequest
        let matchesSelection = request?.contentType == selection.contentType && (
            selection.contentType == "live" ? request?.channelLogin == selection.login : request?.contentId == selection.contentID
        )
        let streamTitle = active.title == selection.name ? nil : active.title
        let sourceTitle = matchesSelection ? playback.session?.title : nil
        let recordingKind = selection.contentType == "clip" ? "Clip" : selection.contentType == "vod" ? "VOD" : nil
        return .init(id: active.id, channel: selection.name, channelLogin: selection.login, title: streamTitle ?? sourceTitle,
                     recordingKind: recordingKind, avatarURL: desktopAvatarURL,
                     playing: matchesSelection && playback.hasMedia && playback.state == .playing && !playback.isPaused)
    }
    var nowPlaying: DesktopNowPlaying?
    var desktopFullscreen = false
    var desktopTheater = false
    @ObservationIgnored private var desktopPlaybackTask: Task<Void, Never>?
    @ObservationIgnored private var desktopRetryTask: Task<Void, Never>?
    private var desktopRetryAttempt = 0
    @ObservationIgnored lazy var desktopPlayerSurface: DesktopPlayerSurface = {
        let surface = DesktopPlayerSurface(playback: playback)
        surface.restorePlayback = { [weak self] in self?.reopenDesktopPlayback() }
        return surface
    }()
    func startDesktopPlayback(_ selection: ChannelSelection, type: String = "live", contentID: String? = nil, title: String? = nil, thumbnail: URL? = nil) {
        offlineDownload = nil
        saveDesktopPosition()
        desktopPlaybackTask?.cancel(); desktopRetryTask?.cancel(); desktopRetryAttempt = 0
        var active = selection
        active.contentType = type; active.contentID = contentID; active.returnToPlayback = true
        desktopAvatarURL = nil
        let presentation = DesktopNowPlaying(selection: active, title: title ?? selection.name, thumbnail: thumbnail)
        nowPlaying = presentation
        error = nil
        desktopPlaybackTask = Task {
            await play(selection, contentType: type, contentID: contentID)
            guard !Task.isCancelled else { return }
            if type != "live", selection.resumePosition > 0 {
                await playback.player.seek(to: CMTime(seconds: selection.resumePosition, preferredTimescale: 600))
            }
            if type == "live", title == nil, let api,
               let page = try? await api.streams(login: selection.login),
               let streamTitle = page.data.first?.title,
               !Task.isCancelled, nowPlaying?.id == presentation.id {
                nowPlaying?.title = streamTitle
            }
        }
    }
    func reopenDesktopPlayback() {
        guard let active = nowPlaying else { return }
        selectedChannel = active.selection
    }
    func saveDesktopPosition() {
        guard let active = nowPlaying, let request = playback.currentRequest, request.contentType != "live", let id = request.contentId, active.selection.contentID == id, active.selection.contentType == request.contentType else { return }
        let seconds = playback.player.currentTime().seconds
        if seconds.isFinite && seconds > 0 {
            personal.watched(.init(login: active.selection.login, title: active.title, position: seconds, contentType: request.contentType, contentID: id))
        }
    }
    func retryDesktopPlaybackIfNeeded() {
        guard !playback.managesRecovery, !isOfflinePlayback, nowPlaying != nil, playback.failureIsRetryable, personal.data.preferences.retryPlayback, desktopRetryAttempt < 2 else { return }
        desktopRetryAttempt += 1
        let delay = desktopRetryAttempt * 2
        desktopRetryTask = Task {
            do { try await Task.sleep(for: .seconds(delay)); try Task.checkCancellation(); await playback.retry(automatic: true) }
            catch { }
        }
    }
    func toggleDesktopFullscreen() {
        guard let window = desktopPlayerSurface.view.window else { return }
        desktopFullscreen = !window.styleMask.contains(.fullScreen); window.toggleFullScreen(nil)
    }
    func stopDesktopPlayback() {
        sampleViewing(); saveDesktopPosition(); desktopPlaybackTask?.cancel(); desktopPlaybackTask = nil; desktopRetryTask?.cancel(); desktopRetryTask = nil
        desktopPlayerSurface.stopPiP()
        if desktopFullscreen { (desktopPlayerSurface.view.window)?.toggleFullScreen(nil); desktopFullscreen = false }
        desktopTheater = false
        nowPlaying = nil; offlineDownload = nil; playback.player.pause(); chat.disconnect()
        discordPresence.stopWatching()
        Task { await playback.stop() }
    }
    #endif
    var avatars: [String: URL] = [:]
    var user: TwitchUser?
    var streams: [TwitchStream] = []
    var followedStreams: [TwitchStream] = []
    var channels: [FollowedChannel] = []
    var categories: [TwitchCategory] = []
    var channelsCursor: String?
    var streamsCursor: String?
    var error: String?
    var loading = false
    var showingSettings = false
    var selectedChannel: ChannelSelection?
    var offlineDownload: LocalDownload?
    var isOfflinePlayback: Bool { offlineDownload != nil }
    func playOffline(_ item: LocalDownload, url: URL) {
        offlineDownload = item; chat.disconnect()
        let channel = ChannelSelection(login: (item.metadata?.channel ?? "offline").lowercased(), name: item.metadata?.channel ?? "Downloads", contentType: item.contentType, contentID: item.contentID, returnToPlayback: true, offlineDownloadID: item.id)
        #if os(macOS)
        saveDesktopPosition(); desktopPlaybackTask?.cancel(); desktopRetryTask?.cancel()
        desktopAvatarURL = nil
        nowPlaying = .init(selection: channel, title: item.displayTitle, thumbnail: downloads.thumbnailFile(for: item) ?? item.metadata?.thumbnailURL)
        selectedChannel = channel
        desktopPlaybackTask = Task { await playback.startOffline(url: url, type: item.contentType, contentID: item.contentID, expectedDuration: item.metadata?.expectedDuration) }
        #elseif os(iOS)
        mobile.startOffline(channel, item: item, url: url)
        #endif
    }
    static let twitchCallback = "https://rafaelreverberi.github.io/Twitchy/oauth-callback.html"

    private static func savedClientID(forKey key: String) -> String {
        let id = OAuthAppSettings.usableClientID(UserDefaults.standard.string(forKey: key) ?? "")
        return OAuthAppSettings.isFormerBundledClientID(id) ? "" : id
    }

    @ObservationIgnored private var deviceClientIDWasEntered = false
    var clientID = AppModel.savedClientID(forKey: "oauth.clientID") { didSet { UserDefaults.standard.set(clientID, forKey: "oauth.clientID"); saveOAuthSettings() } }
    var deviceClientID = AppModel.savedClientID(forKey: "oauth.deviceClientID") {
        didSet {
            if !isDiscoveryFixture { UserDefaults.standard.set(deviceClientID, forKey: "oauth.deviceClientID") }
            saveOAuthSettings()
        }
    }
    var redirect = UserDefaults.standard.string(forKey: "oauth.redirect").flatMap { $0.isEmpty ? nil : $0 } ?? AppModel.twitchCallback { didSet { UserDefaults.standard.set(redirect, forKey: "oauth.redirect"); saveOAuthSettings() } }
    private func saveOAuthSettings() {
        guard !applyingOAuthSettings else { return }
        personal.data.oauthSettings = OAuthAppSettings(clientID: clientID, deviceClientID: deviceClientID, redirect: redirect, deviceClientIDWasEntered: deviceClientIDWasEntered ? true : nil).usingOwnRegistration
    }
    func applyOAuthSettings() {
        let settings = personal.data.oauthSettings?.usingOwnRegistration
        applyingOAuthSettings = true; defer { applyingOAuthSettings = false }
        deviceClientIDWasEntered = settings?.deviceClientIDWasEntered == true
        clientID = settings?.clientID ?? ""
        deviceClientID = settings?.deviceClientID ?? ""
        if let settings { redirect = settings.redirect }
    }
    private var explicitDeviceClientID: String? { deviceClientIDWasEntered ? deviceClientID : nil }
    var hasTwitchRegistration: Bool { !configuration.deviceClientID.isEmpty }
    var twitchConnectTitle: String { hasTwitchRegistration ? "Sign in with Twitch" : "Set Up Twitch Connection" }

    func saveTwitchRegistration(_ input: String) {
        let id = OAuthAppSettings.usableClientID(input)
        guard !id.isEmpty else { return }
        deviceClientIDWasEntered = true
        deviceClientID = id
    }

    private var cachedAPI: TwitchAPIClient?
    private var cachedToken: String?
    var api: TwitchAPIClient? {
        guard !isOffline, let session = auth.session, !session.isExpired, auth.status == "Connected" else { return nil }
        if cachedToken != session.accessToken { cachedAPI = TwitchAPIClient(clientID: session.clientID, token: session.accessToken); cachedToken = session.accessToken }
        return cachedAPI
    }
    var configuration: OAuthConfiguration { .init(clientID: OAuthAppSettings.usableClientID(clientID), redirectURI: URL(string: redirect) ?? URL(string: Self.twitchCallback)!, deviceClientID: OAuthAppSettings.usableClientID(deviceClientID)) }
    func startup() async {
        startConnectivityMonitoring()
        defer { startupComplete = true }
        #if DEBUG
        if ProcessInfo.processInfo.environment["TWITCHY_UI_SOURCES_FIXTURE"] == "1" {
            personal.data.onboardingComplete = true
            personal.data.preferences.reduceMotion = true // Keep source-order UI fixtures deterministic.
            try? sources.upsert(.init(name: "Primary", baseURL: URL(string: "http://127.0.0.1:18181")!, allowLocalHTTP: true))
            try? sources.upsert(.init(name: "Backup", baseURL: URL(string: "http://127.0.0.1:18182")!, allowLocalHTTP: true))
            showingSettings = true
            return
        }
        if let fixture = ProcessInfo.processInfo.environment["TWITCHY_UI_DISCOVERY_FIXTURE"] {
            personal.data.onboardingComplete = true
            networkOffline = fixture == "offline"
            if networkOffline {
                // Move the preceding Advanced-only custom proxy into the explicit source list once.
        if let legacy = personal.data.proxyConfiguration, legacy.useCustom, !legacy.address.isEmpty {
            do {
                let id = UUID(uuidString: "532C91A1-9BBC-4A20-A42D-A6A83E61C888")!
                if !sources.sources.contains(where: { $0.id == id }) {
                    var source = try StreamingSource.proxy(name: legacy.name, configuration: legacy, id: id)
                    source.enabled = legacy.enabled; try sources.upsert(source)
                }
                personal.data.proxyConfiguration = nil
            } catch { self.error = "The previous proxy could not be migrated. Add it again in Sources." }
        }
        await auth.restore(validateOnline: false)
                user = try? JSONCoding.decoder().decode(TwitchUser.self, from: Data(#"{"id":"fixture-account","login":"offlineviewer","display_name":"Offline viewer","profile_image_url":"","description":""}"#.utf8))
            } else { try? await Task.sleep(for: .seconds(20)) }
            return
        }
        #endif
        #if DEBUG && os(macOS)
        if ProcessInfo.processInfo.environment["TWITCHY_UI_COMPANION_FIXTURE"] != nil {
            personal.data.onboardingComplete = true
            return
        }
        #endif
        #if DEBUG && os(tvOS) && targetEnvironment(simulator)
        if TVFixtures.enabled { TVFixtures.load(self); return }
        #endif
        #if DEBUG && os(iOS) && targetEnvironment(simulator)
        if let home = ProcessInfo.processInfo.environment["TWITCHY_UI_HOME_FIXTURE"] {
            personal.data.onboardingComplete = true
            networkOffline = home == "offline"
            try? await Task.sleep(for: .seconds(home == "offline" ? 30 : 8))
            return
        }
        if ProcessInfo.processInfo.environment["TWITCHY_UI_COMPANION_FIXTURE"] != nil {
            personal.data.onboardingComplete = true
            return
        }
        if ProcessInfo.processInfo.environment["TWITCHY_UI_PLAYBACK_FIXTURE"] == "1" {
            personal.data.onboardingComplete = true
            personal.data.preferences.autoplay = true
            personal.data.preferences.showChat = true
            personal.data.preferences.pictureInPicture = true
            let scenario = ProcessInfo.processInfo.environment["TWITCHY_UI_PLAYBACK_SCENARIO"]
            if ProcessInfo.processInfo.environment["TWITCHY_UI_SEARCH_FIXTURE"] != "1" {
                selectedChannel = .init(login: scenario.map { "fixture-" + $0 } ?? "fixture", name: "Playback test")
            }
            if ProcessInfo.processInfo.environment["TWITCHY_UI_OFFLINE_FIXTURE"] == "1" {
                let client = try? StreamingSourceClient(source: .init(name: "Offline fixture", baseURL: URL(string: "http://localhost:8181")!, allowLocalHTTP: true))
                if let client {
                    await downloads.enqueue(client: client, type: "clip", contentID: "fixture-clip", permission: "fixture-owner", metadata: .init(title: "Saved clip", channel: "Playback test", duration: "0:06"))
                    for _ in 0..<100 {
                        if downloads.items.first?.job.status == .completed || downloads.items.first?.job.status == .failed { break }
                        try? await Task.sleep(for: .milliseconds(50))
                    }
                }
            }
            return
        }
        #endif
        playback.recoveryEnabled = { [weak self] in self?.personal.data.preferences.retryPlayback == true }
        playback.recoveryLimit = { [weak self] in (self?.sources.sources.filter(\.enabled).count ?? 0) + 1 }
        playback.resolvePlayback = { [weak self] request, failedIDs, _ in
            guard let self else { throw CancellationError() }
            return try await playbackResolver.resolveOrdered(request, excluding: failedIDs)
        }
        if !syncStarted {
            syncStarted = true
            if let saved = personal.data.oauthSettings {
                personal.data.oauthSettings = saved.usingOwnRegistration
            }
            if personal.data.oauthSettings == nil { saveOAuthSettings() }
            UserDefaults.standard.set(clientID, forKey: "oauth.clientID")
            UserDefaults.standard.set(deviceClientID, forKey: "oauth.deviceClientID")
            do { try sync.start(); applyOAuthSettings() } catch { self.error = "Local sync data could not be applied." }
        }
        // Move the preceding Advanced-only custom proxy into the explicit source list once.
        if let legacy = personal.data.proxyConfiguration, legacy.useCustom, !legacy.address.isEmpty {
            do {
                let id = UUID(uuidString: "532C91A1-9BBC-4A20-A42D-A6A83E61C888")!
                if !sources.sources.contains(where: { $0.id == id }) {
                    var source = try StreamingSource.proxy(name: legacy.name, configuration: legacy, id: id)
                    source.enabled = legacy.enabled; try sources.upsert(source)
                }
                personal.data.proxyConfiguration = nil
            } catch { self.error = "The previous proxy could not be migrated. Add it again in Sources." }
        }
        await auth.restore(validateOnline: false, explicitDeviceClientID: explicitDeviceClientID)
        if let session = auth.session, !isDiscoveryFixture { user = accountCache.load(userID: session.userID) }
        if !networkOffline {
            do { try await auth.validate() } catch { noteConnectionError(error) }
        }
        await refresh()
        startupComplete = true
        if pendingReconnect {
            pendingReconnect = false
            await restoreLibrary()
        }
        Task { await sources.refreshAvailability() }
        await sync.sync()
    }
    func login(chat: Bool = false, presentSettings: Bool = true) async {
        guard !auth.isSigningIn else {
            #if !os(tvOS)
            if presentSettings { showingSettings = true }
            #endif
            return
        }
        #if !os(tvOS)
        if presentSettings { showingSettings = true }
        #endif
        guard hasTwitchRegistration else { return }
        await auth.login(configuration: configuration, chat: chat)
        #if os(macOS)
        if let value = auth.deviceCode?.verificationUri, let url = URL(string: value), url.scheme == "https", url.host == "www.twitch.tv" || url.host == "twitch.tv" { NSWorkspace.shared.open(url) }
        #elseif os(iOS)
        if let value = auth.deviceCode?.verificationUri, let url = URL(string: value), url.scheme == "https", url.host == "www.twitch.tv" || url.host == "twitch.tv" { await UIApplication.shared.open(url) }
        #endif
    }
    private var refreshID = UUID()
    func refresh() async {
        let current = UUID(); refreshID = current
        guard !isOffline, let api, let session = auth.session else {
            if auth.session == nil {
                cachedAPI = nil; cachedToken = nil; streams = []; followedStreams = []; interestStreams = []; channels = []; categories = []; user = nil; avatars = [:]
                if !isDiscoveryFixture { accountCache.clear() }
            }
            loading = false
            return
        }
        loading = true; error = nil; defer { if refreshID == current { loading = false } }
        do {
            async let profile = api.currentUser()
            async let popular = api.streams()
            async let games = api.topCategories()
            let newUser = try await profile
            guard refreshID == current, auth.session?.accessToken == session.accessToken else { return }
            user = newUser
            if !isDiscoveryFixture { try? accountCache.save(newUser) }
            let popularPage = try await popular
            let categoryPage = try await games
            var newChannels: [FollowedChannel] = []
            var newLive: [TwitchStream] = []
            var nextChannels: String?
            var newAvatars: [String: URL] = [:]
            if session.scopes.contains("user:read:follows") {
                async let live = api.followedStreams(userID: session.userID)
                async let following = api.followedChannels(userID: session.userID)
                let livePage = try await live; newLive = livePage.data
                var liveCursor = livePage.pagination?.cursor
                while let cursor = liveCursor {
                    let page = try await api.followedStreams(userID: session.userID, after: cursor)
                    newLive += page.data; liveCursor = page.pagination?.cursor
                    try Task.checkCancellation()
                }
                let followed = try await following; newChannels = followed.data; nextChannels = followed.pagination?.cursor
                if !newChannels.isEmpty {
                    let profiles = try await api.users(logins: newChannels.map(\.broadcasterLogin))
                    for profile in profiles.data { newAvatars[profile.id] = URL(string: profile.profileImageUrl) }
                }
            }
            try Task.checkCancellation()
            guard refreshID == current, auth.session?.accessToken == session.accessToken else { return }
            streams = popularPage.data; streamsCursor = popularPage.pagination?.cursor; categories = categoryPage.data
            channels = newChannels; followedStreams = newLive; channelsCursor = nextChannels; avatars = newAvatars
            await refreshInterests()
        } catch is CancellationError { }
        catch { if refreshID == current, auth.session?.accessToken == session.accessToken { self.error = error.localizedDescription; noteConnectionError(error) } }
    }
    func moreChannels() async {
        guard let cursor = channelsCursor, let api, let user = auth.session else { return }
        do { let page = try await api.followedChannels(userID: user.userID, after: cursor); let existing = Set(channels.map(\.id)); channels += page.data.filter { !existing.contains($0.id) }; channelsCursor = page.pagination?.cursor } catch { self.error = error.localizedDescription }
    }
    func moreStreams() async {
        guard let cursor = streamsCursor, let api else { return }
        do { let page = try await api.streams(after: cursor); let existing = Set(streams.map(\.id)); streams += page.data.filter { !existing.contains($0.id) }; streamsCursor = page.pagination?.cursor } catch { self.error = error.localizedDescription }
    }
    func open(login: String, name: String, id: String? = nil) { selectedChannel = .init(login: login, name: name, broadcasterID: id) }
    func play(_ selection: ChannelSelection, contentType: String = "live", contentID: String? = nil, qualityOverride: String? = nil) async {
        #if os(iOS)
        guard !Task.isCancelled else { return }
        #endif
        do {
            sampleViewing(); self.error = nil
            let client: StreamingSourceClient?
            #if DEBUG && os(iOS) && targetEnvironment(simulator)
            if ProcessInfo.processInfo.environment["TWITCHY_UI_PLAYBACK_FIXTURE"] == "1" {
                client = try StreamingSourceClient(source: .init(name: "Local fixture", baseURL: URL(string: "http://localhost:8181")!, allowLocalHTTP: true))
            } else { client = playback.managesRecovery ? nil : try sources.client() }
            #else
            client = playback.managesRecovery ? nil : try sources.client()
            #endif
            viewing = nil; viewingLogin = selection.login; wasPlaying = false; viewingTick = ProcessInfo.processInfo.systemUptime
            await playback.start(client: client, request: .init(contentType: contentType, channelLogin: contentType == "live" ? selection.login : nil, contentId: contentID, requestedQuality: qualityOverride ?? personal.data.preferences.preferredQuality))
            #if os(iOS)
            guard !Task.isCancelled else { return }
            #endif
            if playback.hasMedia {
                personal.watched(.init(login: selection.login, title: selection.name, contentType: contentType, contentID: contentID))
                if viewing == nil { viewing = WatchSession(login: selection.login) }
                viewingTick = ProcessInfo.processInfo.systemUptime
                wasPlaying = playback.player.timeControlStatus == .playing
            }
        } catch {
            #if os(iOS)
            guard !Task.isCancelled else { return }
            #endif
            self.error = error.localizedDescription
        }
    }
}
struct ChannelSelection: Identifiable { let id = UUID(); var login: String; var name: String; var broadcasterID: String?; var contentType: String? = nil; var contentID: String? = nil; var resumePosition: Double = 0; var returnToPlayback = false; var offlineDownloadID: UUID? = nil }

#if os(macOS)
struct DesktopNowPlaying: Identifiable {
    let id = UUID()
    var selection: ChannelSelection
    var title: String
    var thumbnail: URL?
}
#endif

#if os(iOS)
extension ChannelSelection: Hashable {}
#endif

#if DEBUG
private final class SourceFixtureSecrets: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func read(_ key: String) throws -> Data? { lock.withLock { values[key] } }
    func write(_ data: Data, key: String) throws { lock.withLock { values[key] = data } }
    func delete(_ key: String) throws { lock.withLock { values[key] = nil } }
}
private final class DiscoveryFixtureSecrets: SecretStore, @unchecked Sendable {
    private var session: Data? = Data(#"{"accessToken":"fixture-only","clientID":"fixture","userID":"fixture-account","login":"offlineviewer","scopes":[],"expiresAt":2000000000}"#.utf8)
    func read(_ key: String) throws -> Data? { key == "session" ? session : nil }
    func write(_ data: Data, key: String) throws { if key == "session" { session = data } }
    func delete(_ key: String) throws { if key == "session" { session = nil } }
}
#endif
