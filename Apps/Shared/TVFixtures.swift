#if os(tvOS)
import Foundation
import TwitchyCore
import TwitchyAPI
import TwitchySources
import TwitchyAuth

final class TVFixtureSecrets: SecretStore, @unchecked Sendable {
    private var values: [String: Data] = [:]
    func read(_ key: String) throws -> Data? { values[key] }
    func write(_ data: Data, key: String) throws { values[key] = data }
    func delete(_ key: String) throws { values.removeValue(forKey: key) }
}
enum TVFixtures {
    static var deviceCode: DeviceCode? {
        #if DEBUG && targetEnvironment(simulator)
        guard screen == "onboarding-code" else { return nil }
        return try! JSONCoding.decoder().decode(DeviceCode.self, from: Data(#"{"device_code":"fixture-device-code","user_code":"TVTEST42","verification_uri":"https://www.twitch.tv/activate","expires_in":1800,"interval":5}"#.utf8))
        #else
        return nil
        #endif
    }
    static var sourceSecrets: any SecretStore { enabled ? TVFixtureSecrets() : KeychainStore(service: "com.rafaelreverberi.Twitchy.sources") }
    static var screen: String? {
        #if DEBUG && targetEnvironment(simulator)
        ProcessInfo.processInfo.environment["TWITCHY_TV_SCREEN"]
        #else
        nil
        #endif
    }
    static var enabled: Bool {
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.environment["TWITCHY_UI_DISCOVERY_FIXTURE"] != nil { return true }
        #endif
        return screen != nil
    }
    #if DEBUG && targetEnvironment(simulator)
    private static func decode<T: Decodable>(_ text: String) -> T { try! JSONCoding.decoder().decode(T.self, from: Data(text.utf8)) }
    static var streams: [TwitchStream] { (0..<8).map { i in decode("""
        {"id":"tv-\(i)","user_id":"tv-\(i)","user_login":"fixture\(i)","user_name":"\(["Northern Lights", "Pixel Workshop", "Late Night Live", "The Creative Room"][i % 4])","game_id":"fixture","game_name":"\(["Science & Technology", "Minecraft", "Just Chatting", "Art"][i % 4])","title":"A big-screen stream","viewer_count":\(1234 + i * 321),"thumbnail_url":"http://localhost:8181/media/fixture.png"}
        """) } }
    static var profile: TwitchUser { decode(#"{"id":"fixture","login":"fixture","display_name":"Northern Lights","profile_image_url":"","offline_image_url":"http://localhost:8181/media/fixture.png","description":"Local television layout fixture"}"#) }
    static var videos: [Video] { decode(#"[{"id":"fixture-vod","user_id":"fixture","user_login":"fixture","title":"Building something together","thumbnail_url":"http://localhost:8181/media/fixture.png","duration":"1h24m","url":"https://www.twitch.tv/fixture"}]"#) }
    static var clips: [Clip] { decode(#"[{"id":"fixture-clip","title":"One more try","thumbnail_url":"http://localhost:8181/media/fixture.png","broadcaster_name":"Northern Lights","url":"https://www.twitch.tv/fixture"}]"#) }
    @MainActor static func load(_ model: AppModel) {
        model.personal.data.onboardingComplete = screen != "onboarding"
        model.personal.data.preferences.preferredQuality = "360p" // A synced mobile preference must not lower the TV default.
        model.personal.data.preferences.showChat = true
        model.streams = streams; model.followedStreams = Array(streams.prefix(3))
        model.categories = decode(#"[{"id":"fixture","name":"Minecraft","box_art_url":"http://localhost:8181/media/fixture.png"}]"#)
        model.channels = decode(#"[{"broadcaster_id":"tv-0","broadcaster_login":"fixture0","broadcaster_name":"Northern Lights","followed_at":"2026-10-01T00:00:00Z"},{"broadcaster_id":"offline","broadcaster_login":"offline","broadcaster_name":"Offline channel","followed_at":"2026-10-01T00:00:00Z"}]"#)
        model.personal.recordViewing(WatchSession(login: "fixture0", seconds: 30))
        model.personal.recordViewing(WatchSession(login: "fixture1", seconds: 240))
        model.personal.watched(.init(login: "fixture", title: "Northern Lights"))
        let source = StreamingSource(name: "Local TV fixture", baseURL: URL(string: "http://localhost:8181")!, allowLocalHTTP: true)
        try? model.sources.upsert(source)
        if screen == "starting" { model.selectedChannel = .init(login: "fixture-slow", name: "Starting fixture", contentType: "live") }
        if screen == "channel" || screen == "player" { model.selectedChannel = .init(login: "fixture", name: "Northern Lights", broadcasterID: "fixture", contentType: screen == "player" ? "vod" : nil, contentID: screen == "player" ? "fixture-vod" : nil) }
    }
    #endif
}
#endif
