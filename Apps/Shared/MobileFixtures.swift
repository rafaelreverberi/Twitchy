#if DEBUG && os(iOS) && targetEnvironment(simulator)
import Foundation
import TwitchyCore
import TwitchyAPI
import TwitchyChat

enum MobileFixtures {
    static var enabled: Bool { ProcessInfo.processInfo.environment["TWITCHY_UI_PLAYBACK_FIXTURE"] == "1" }
    private static func decode<T: Decodable>(_ text: String) -> T { try! JSONCoding.decoder().decode(T.self, from: Data(text.utf8)) }
    static var profile: TwitchUser { decode(#"{"id":"fixture","login":"fixture","display_name":"Playback test","profile_image_url":"","description":"A local channel for checking the iPhone layout, player transitions and chat. No Twitch account is used."}"#) }
    static var stream: TwitchStream { decode(#"{"id":"fixture-live","user_id":"fixture","user_login":"fixture","user_name":"Playback test","game_id":"fixture","game_name":"Science & Technology","title":"A stream that stays with you","viewer_count":1234,"thumbnail_url":"http://localhost:8181/media/fixture.png"}"#) }
    static var searchChannels: [SearchChannel] { decode(#"[{"id":"fixture","broadcaster_login":"fixture","display_name":"Playback test","game_name":"Science & Technology","title":"Search navigation fixture","is_live":true,"thumbnail_url":""}]"#) }
    static var videos: [Video] { decode(#"[{"id":"fixture-vod","user_id":"fixture","user_login":"fixture","title":"Building something together","thumbnail_url":"http://localhost:8181/media/fixture.png","duration":"1h24m","url":"https://www.twitch.tv/fixture","view_count":5400},{"id":"fixture-vod-2","user_id":"fixture","user_login":"fixture","title":"Highlights from the last stream","thumbnail_url":"http://localhost:8181/media/fixture.png","duration":"32m","url":"https://www.twitch.tv/fixture","view_count":2200}]"#) }
    static var clips: [Clip] { decode(#"[{"id":"fixture-clip","title":"That was close!","thumbnail_url":"http://localhost:8181/media/fixture.png","broadcaster_name":"Playback test","url":"https://www.twitch.tv/fixture"}]"#) }
    static var messages: [ChatMessage] {
        let examples = [
            ("luna", "#A970FF", "Hey everyone 👋"),
            ("pixelpilot", "#00B8A9", "That looks so much better on a phone."),
            ("nightowl", "#EE8354", "Video above, chat below. Perfect."),
            ("luna", "#A970FF", "What quality is the stream running at?"),
            ("river", "#5D9BF5", "Auto. The stream keeps going when you switch views."),
            ("pixelpilot", "#00B8A9", "This is a longer message to check that usernames and the conversation wrap naturally onto the next line instead of squeezing into separate columns."),
            ("nightowl", "#EE8354", "Nice! ✨"),
            ("river", "#5D9BF5", "And back to the channel without starting over."),
            ("luna", "#A970FF", "Hello from the simulator 🖤")
        ]
        return examples.enumerated().map { index, entry in
            let object: [String: Any] = ["broadcaster_user_id":"fixture", "chatter_user_id":"fixture-\(index)", "chatter_user_name":entry.0, "chatter_user_login":entry.0, "message_id":"fixture-message-\(index)", "color":entry.1, "badges":[], "message":["text":entry.2, "fragments":[["type":"text", "text":entry.2]]]]
            return try! JSONCoding.decoder().decode(ChatMessage.self, from: JSONSerialization.data(withJSONObject: object))
        }
    }
}
#endif
