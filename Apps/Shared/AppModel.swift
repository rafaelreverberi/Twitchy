import SwiftUI
import TwitchyCore
import TwitchyAPI
import TwitchyAuth
import TwitchySources
import TwitchyPlayback
import TwitchyChat

@MainActor @Observable final class AppModel {
    let auth = TwitchAuthManager()
    let sources = StreamingSourceManager()
    let personal = PersonalStore()
    let playback = PlaybackController()
    let chat = ChatController()
    let downloads = DownloadManager()
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
    var clientID = UserDefaults.standard.string(forKey: "oauth.clientID") ?? "" { didSet { UserDefaults.standard.set(clientID, forKey: "oauth.clientID") } }
    var deviceClientID = UserDefaults.standard.string(forKey: "oauth.deviceClientID") ?? "" { didSet { UserDefaults.standard.set(deviceClientID, forKey: "oauth.deviceClientID") } }
    var redirect = UserDefaults.standard.string(forKey: "oauth.redirect").flatMap { $0.isEmpty ? nil : $0 } ?? "https://rafaelreverberi.github.io/Twitchy/oauth-callback.html" { didSet { UserDefaults.standard.set(redirect, forKey: "oauth.redirect") } }
    private var cachedAPI: TwitchAPIClient?
    private var cachedToken: String?
    var api: TwitchAPIClient? {
        guard let session = auth.session, !session.isExpired, auth.status == "Connected" else { return nil }
        if cachedToken != session.accessToken { cachedAPI = TwitchAPIClient(clientID: session.clientID, token: session.accessToken); cachedToken = session.accessToken }
        return cachedAPI
    }
    var configuration: OAuthConfiguration { .init(clientID: clientID, redirectURI: URL(string: redirect) ?? URL(string: "https://rafaelreverberi.github.io/Twitchy/oauth-callback.html")!, deviceClientID: deviceClientID) }
    func startup() async { await auth.restore(); await refresh() }
    func login(chat: Bool = false) async { await auth.login(configuration: configuration, chat: chat); await refresh() }
    private var refreshID = UUID()
    func refresh() async {
        let current = UUID(); refreshID = current
        guard let api, let session = auth.session else { cachedAPI = nil; cachedToken = nil; streams = []; followedStreams = []; channels = []; categories = []; user = nil; avatars = [:]; loading = false; return }
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
        do {
            let client = try sources.client()
            await playback.start(client: client, request: .init(contentType: contentType, channelLogin: contentType == "live" ? selection.login : nil, contentId: contentID, requestedQuality: personal.data.preferences.preferredQuality))
            if playback.session != nil { personal.watched(.init(login: selection.login, title: selection.name, contentType: contentType, contentID: contentID)) }
        } catch { self.error = error.localizedDescription }
    }
}
struct ChannelSelection: Identifiable { let id = UUID(); var login: String; var name: String; var broadcasterID: String?; var contentType: String? = nil; var contentID: String? = nil; var resumePosition: Double = 0 }
