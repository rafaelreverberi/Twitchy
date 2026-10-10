import SwiftUI
import TwitchyCore
import TwitchyAPI
import TwitchyAuth
import TwitchySources
import TwitchyPlayback
import TwitchyChat
import AVKit

@MainActor @Observable final class AppModel {
    let auth = TwitchAuthManager()
    let sources = StreamingSourceManager()
    #if DEBUG && os(iOS) && targetEnvironment(simulator)
    let personal = PersonalStore(url: MobileFixtures.enabled ? URL.temporaryDirectory.appendingPathComponent("Twitchy-ui-" + UUID().uuidString + ".json") : PersonalStore.defaultURL)
    #else
    let personal = PersonalStore()
    #endif
    let playback = PlaybackController()
    let chat = ChatController()
    let downloads = DownloadManager()
    #if os(iOS)
    var isMobileFixture: Bool {
        #if DEBUG && targetEnvironment(simulator)
        MobileFixtures.enabled
        #else
        false
        #endif
    }
    var startupComplete = false
    @ObservationIgnored lazy var mobile = MobilePlaybackCoordinator(model: self)
    #endif
    @ObservationIgnored lazy var sync = AppDataSync(personal: personal, sources: sources, cloud: CloudSyncStore(transport: PrivateCloudTransport.isConfigured ? PrivateCloudTransport() : nil))
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
        let playing = playback.player.timeControlStatus == .playing && playback.session != nil
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
    var nowPlaying: DesktopNowPlaying?
    @ObservationIgnored private var desktopPlaybackTask: Task<Void, Never>?
    @ObservationIgnored private var desktopRetryTask: Task<Void, Never>?
    private var desktopRetryAttempt = 0
    @ObservationIgnored lazy var desktopPlayerSurface = DesktopPlayerSurface(playback: playback)
    func startDesktopPlayback(_ selection: ChannelSelection, type: String = "live", contentID: String? = nil, title: String? = nil, thumbnail: URL? = nil) {
        saveDesktopPosition()
        desktopPlaybackTask?.cancel(); desktopRetryTask?.cancel(); desktopRetryAttempt = 0
        var active = selection
        active.contentType = type; active.contentID = contentID; active.returnToPlayback = true
        nowPlaying = DesktopNowPlaying(selection: active, title: title ?? selection.name, thumbnail: thumbnail)
        error = nil
        desktopPlaybackTask = Task {
            await play(selection, contentType: type, contentID: contentID)
            guard !Task.isCancelled else { return }
            if type != "live", selection.resumePosition > 0 {
                await playback.player.seek(to: CMTime(seconds: selection.resumePosition, preferredTimescale: 600))
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
        guard nowPlaying != nil, personal.data.preferences.retryPlayback, desktopRetryAttempt < 2 else { return }
        desktopRetryAttempt += 1
        let delay = desktopRetryAttempt * 2
        desktopRetryTask = Task {
            do { try await Task.sleep(for: .seconds(delay)); try Task.checkCancellation(); await playback.retry() }
            catch { }
        }
    }
    func stopDesktopPlayback() {
        sampleViewing(); saveDesktopPosition(); desktopPlaybackTask?.cancel(); desktopPlaybackTask = nil; desktopRetryTask?.cancel(); desktopRetryTask = nil
        nowPlaying = nil; playback.player.pause(); chat.disconnect()
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
    var localPlayback: URL?
    var clientID = UserDefaults.standard.string(forKey: "oauth.clientID") ?? "fvgm8ut01pboy0rvn1f6dkdqxw6rft" { didSet { UserDefaults.standard.set(clientID, forKey: "oauth.clientID"); saveOAuthSettings() } }
    var deviceClientID = UserDefaults.standard.string(forKey: "oauth.deviceClientID").flatMap { $0.isEmpty ? nil : $0 } ?? "fvgm8ut01pboy0rvn1f6dkdqxw6rft" { didSet { UserDefaults.standard.set(deviceClientID, forKey: "oauth.deviceClientID"); saveOAuthSettings() } }
    var redirect = UserDefaults.standard.string(forKey: "oauth.redirect").flatMap { $0.isEmpty ? nil : $0 } ?? "https://rafaelreverberi.github.io/Twitchy/oauth-callback.html" { didSet { UserDefaults.standard.set(redirect, forKey: "oauth.redirect"); saveOAuthSettings() } }
    private func saveOAuthSettings() {
        guard !applyingOAuthSettings else { return }
        personal.data.oauthSettings = .init(clientID: clientID, deviceClientID: deviceClientID, redirect: redirect)
    }
    func applyOAuthSettings() {
        guard let settings = personal.data.oauthSettings else { return }
        applyingOAuthSettings = true; defer { applyingOAuthSettings = false }
        clientID = settings.clientID; deviceClientID = settings.deviceClientID; redirect = settings.redirect
    }
    private var cachedAPI: TwitchAPIClient?
    private var cachedToken: String?
    var api: TwitchAPIClient? {
        guard let session = auth.session, !session.isExpired, auth.status == "Connected" else { return nil }
        if cachedToken != session.accessToken { cachedAPI = TwitchAPIClient(clientID: session.clientID, token: session.accessToken); cachedToken = session.accessToken }
        return cachedAPI
    }
    var configuration: OAuthConfiguration { .init(clientID: clientID, redirectURI: URL(string: redirect) ?? URL(string: "https://rafaelreverberi.github.io/Twitchy/oauth-callback.html")!, deviceClientID: deviceClientID) }
    func startup() async {
        #if os(iOS)
        defer { startupComplete = true }
        #endif
        #if DEBUG && os(iOS) && targetEnvironment(simulator)
        if ProcessInfo.processInfo.environment["TWITCHY_UI_PLAYBACK_FIXTURE"] == "1" {
            personal.data.onboardingComplete = true
            personal.data.preferences.autoplay = true
            personal.data.preferences.showChat = true
            personal.data.preferences.pictureInPicture = true
            let scenario = ProcessInfo.processInfo.environment["TWITCHY_UI_PLAYBACK_SCENARIO"]
            if ProcessInfo.processInfo.environment["TWITCHY_UI_SEARCH_FIXTURE"] != "1" {
                selectedChannel = .init(login: scenario.map { "fixture-" + $0 } ?? "fixture", name: "Playback test")
            }
            return
        }
        #endif
        if !syncStarted {
            syncStarted = true
            if personal.data.oauthSettings == nil { saveOAuthSettings() }
            do { try sync.start(); applyOAuthSettings() } catch { self.error = "Local sync data could not be applied." }
        }
        await auth.restore()
        await sync.sync()
        await refresh()
    }
    func login(chat: Bool = false) async {
        guard !auth.isSigningIn else { showingSettings = true; return }
        showingSettings = true
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
        guard let api, let session = auth.session else { cachedAPI = nil; cachedToken = nil; streams = []; followedStreams = []; interestStreams = []; channels = []; categories = []; user = nil; avatars = [:]; loading = false; return }
        loading = true; error = nil; defer { if refreshID == current { loading = false } }
        do {
            async let profile = api.currentUser()
            async let popular = api.streams()
            async let games = api.topCategories()
            let newUser = try await profile
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
            user = newUser; streams = popularPage.data; streamsCursor = popularPage.pagination?.cursor; categories = categoryPage.data
            channels = newChannels; followedStreams = newLive; channelsCursor = nextChannels; avatars = newAvatars
            await refreshInterests()
        } catch is CancellationError { }
        catch { if refreshID == current, auth.session?.accessToken == session.accessToken { self.error = error.localizedDescription } }
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
    func play(_ selection: ChannelSelection, contentType: String = "live", contentID: String? = nil) async {
        #if os(iOS)
        guard !Task.isCancelled else { return }
        #endif
        do {
            sampleViewing()
            let client: StreamingSourceClient
            #if DEBUG && os(iOS) && targetEnvironment(simulator)
            if ProcessInfo.processInfo.environment["TWITCHY_UI_PLAYBACK_FIXTURE"] == "1" {
                client = try StreamingSourceClient(source: .init(name: "Local fixture", baseURL: URL(string: "http://localhost:8181")!, allowLocalHTTP: true))
            } else { client = try sources.client() }
            #else
            client = try sources.client()
            #endif
            viewing = nil; viewingLogin = selection.login; wasPlaying = false; viewingTick = ProcessInfo.processInfo.systemUptime
            await playback.start(client: client, request: .init(contentType: contentType, channelLogin: contentType == "live" ? selection.login : nil, contentId: contentID, requestedQuality: personal.data.preferences.preferredQuality))
            #if os(iOS)
            guard !Task.isCancelled else { return }
            #endif
            if playback.session != nil {
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
struct ChannelSelection: Identifiable { let id = UUID(); var login: String; var name: String; var broadcasterID: String?; var contentType: String? = nil; var contentID: String? = nil; var resumePosition: Double = 0; var returnToPlayback = false }

#if os(macOS)
struct DesktopNowPlaying: Identifiable {
    var id: UUID { selection.id }
    var selection: ChannelSelection
    var title: String
    var thumbnail: URL?
}
#endif

#if os(iOS)
extension ChannelSelection: Hashable {}
#endif
