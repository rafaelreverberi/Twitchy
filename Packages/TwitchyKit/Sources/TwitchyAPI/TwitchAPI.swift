import Foundation
import TwitchyCore

public struct Page<T: Codable & Sendable>: Codable, Sendable {
    public var data: [T]
    public var pagination: Pagination?
    public var total: Int?
    public struct Pagination: Codable, Sendable { public var cursor: String? }
}
public struct TwitchUser: Codable, Sendable, Identifiable {
    public var id: String; public var login: String; public var displayName: String; public var profileImageUrl: String; public var description: String; public var offlineImageUrl: String? = nil
}
public struct TwitchStream: Codable, Sendable, Identifiable {
    public var id: String; public var userId: String; public var userLogin: String; public var userName: String
    public var gameId: String; public var gameName: String; public var title: String; public var viewerCount: Int; public var thumbnailUrl: String
    public var thumbnail: URL? { URL(string: thumbnailUrl.replacingOccurrences(of: "{width}", with: "640").replacingOccurrences(of: "{height}", with: "360")) }
}
public struct FollowedChannel: Codable, Sendable, Identifiable {
    public var id: String { broadcasterId }
    public var broadcasterId: String; public var broadcasterLogin: String; public var broadcasterName: String; public var followedAt: String
}
public struct SearchChannel: Codable, Sendable, Identifiable {
    public var id: String; public var broadcasterLogin: String; public var displayName: String; public var gameName: String; public var title: String; public var isLive: Bool; public var thumbnailUrl: String
}
public struct TwitchCategory: Codable, Sendable, Identifiable { public var id: String; public var name: String; public var boxArtUrl: String }
public struct Video: Codable, Sendable, Identifiable { public var id: String; public var userId: String; public var userLogin: String; public var title: String; public var thumbnailUrl: String; public var duration: String; public var url: String; public var viewCount: Int? = nil; public var createdAt: String? = nil }
public struct Clip: Codable, Sendable, Identifiable { public var id: String; public var title: String; public var thumbnailUrl: String; public var broadcasterName: String; public var url: String; public var viewCount: Int? = nil; public var createdAt: String? = nil; public var duration: Double? = nil }
public struct ChannelInfo: Codable, Sendable { public var broadcasterId: String; public var broadcasterLogin: String; public var broadcasterName: String; public var gameName: String; public var title: String }
public struct Emote: Codable, Sendable, Identifiable { public var id: String; public var name: String; public var images: Images; public struct Images: Codable, Sendable { public var url1x: String; public var url2x: String; public var url4x: String; enum CodingKeys: String, CodingKey { case url1x = "url1X", url2x = "url2X", url4x = "url4X" } } }
public struct BadgeSet: Codable, Sendable { public var setId: String; public var versions: [Version]; public struct Version: Codable, Sendable { public var id: String; public var imageUrl1x: String; public var title: String; enum CodingKeys: String, CodingKey { case id, title; case imageUrl1x = "imageUrl1X" } } }
public struct Subscription: Codable, Sendable { public var broadcasterId: String; public var tier: String; public var isGift: Bool }
public struct ChatSendResult: Codable, Sendable { public var messageId: String; public var isSent: Bool; public var dropReason: DropReason?; public struct DropReason: Codable, Sendable { public var code: String; public var message: String } }

// Immutable credentials only enter this official-origin client. SourceClient has no Twitch dependency.
public actor TwitchAPIClient {
    private let clientID: String
    private let token: String
    private let http: HTTPClient
    private var cache: [URL: (Date, Data)] = [:]
    public init(clientID: String, token: String, transport: any HTTPTransport = NetworkTransport()) { self.clientID = clientID; self.token = token; http = HTTPClient(transport: transport) }
    private func request(_ endpoint: String, query: [URLQueryItem] = [], method: String = "GET", body: Data? = nil) throws -> URLRequest {
        var c = URLComponents(string: "https://api.twitch.tv/helix/\(endpoint)")!; c.queryItems = query.isEmpty ? nil : query
        guard let url = c.url, url.host == "api.twitch.tv" else { throw ClientError.invalidURL }
        var r = URLRequest(url: url); r.httpMethod = method; r.httpBody = body
        r.setValue(clientID, forHTTPHeaderField: "Client-Id"); r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if body != nil { r.setValue("application/json", forHTTPHeaderField: "Content-Type") }; return r
    }
    private func get<T: Codable & Sendable>(_ type: T.Type, _ endpoint: String, _ values: [String: String] = [:], cacheable: Bool = false) async throws -> Page<T> {
        let r = try request(endpoint, query: values.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) })
        if cacheable, let entry = cache[r.url!], Date().timeIntervalSince(entry.0) < 30 { return try JSONCoding.decoder().decode(Page<T>.self, from: entry.1) }
        let data = try await http.response(r).data
        if cacheable { if cache.count > 100 { cache.removeAll() }; cache[r.url!] = (.now, data) }
        return try JSONCoding.decoder().decode(Page<T>.self, from: data)
    }
    public func currentUser() async throws -> TwitchUser { guard let user = try await get(TwitchUser.self, "users").data.first else { throw ClientError.invalidResponse }; return user }
    public func users(logins: [String]) async throws -> Page<TwitchUser> { let r = try request("users", query: logins.prefix(100).map { .init(name: "login", value: $0) }); return try await http.decode(Page<TwitchUser>.self, request: r) }
    public func followedChannels(userID: String, after: String? = nil) async throws -> Page<FollowedChannel> { var q = ["user_id": userID, "first": "100"]; q["after"] = after; return try await get(FollowedChannel.self, "channels/followed", q) }
    public func followedStreams(userID: String, after: String? = nil) async throws -> Page<TwitchStream> { var q = ["user_id": userID, "first": "100"]; q["after"] = after; return try await get(TwitchStream.self, "streams/followed", q) }
    public func streams(login: String? = nil, gameID: String? = nil, after: String? = nil) async throws -> Page<TwitchStream> { var q = ["first": "30"]; q["user_login"] = login; q["game_id"] = gameID; q["after"] = after; return try await get(TwitchStream.self, "streams", q, cacheable: true) }
    public func streams(logins: [String]) async throws -> Page<TwitchStream> {
        guard !logins.isEmpty else { throw ClientError.message("Choose at least one channel.") }
        let query = [URLQueryItem(name: "first", value: "100")] + logins.prefix(100).map { URLQueryItem(name: "user_login", value: $0) }
        return try await http.decode(Page<TwitchStream>.self, request: request("streams", query: query))
    }
    public func channel(id: String) async throws -> Page<ChannelInfo> { try await get(ChannelInfo.self, "channels", ["broadcaster_id": id]) }
    public func searchChannels(_ query: String, liveOnly: Bool = false, after: String? = nil) async throws -> Page<SearchChannel> { var q = ["query": query, "first": "30", "live_only": String(liveOnly)]; q["after"] = after; return try await get(SearchChannel.self, "search/channels", q, cacheable: true) }
    public func searchCategories(_ query: String, after: String? = nil) async throws -> Page<TwitchCategory> { var q = ["query": query, "first": "30"]; q["after"] = after; return try await get(TwitchCategory.self, "search/categories", q, cacheable: true) }
    public func topCategories(after: String? = nil) async throws -> Page<TwitchCategory> { var q = ["first": "12"]; q["after"] = after; return try await get(TwitchCategory.self, "games/top", q, cacheable: true) }
    public func videos(userID: String, after: String? = nil, type: String? = nil, sort: VideoSort? = nil) async throws -> Page<Video> { var q = ["user_id": userID, "first": "20"]; q["after"] = after; q["type"] = type; q["sort"] = sort?.rawValue; return try await get(Video.self, "videos", q) }
    public func videos(ids: [String]) async throws -> Page<Video> {
        let query = ids.prefix(100).map { URLQueryItem(name: "id", value: $0) }
        return try await http.decode(Page<Video>.self, request: request("videos", query: query))
    }
    public func clips(ids: [String]) async throws -> Page<Clip> {
        let query = ids.prefix(100).map { URLQueryItem(name: "id", value: $0) }
        return try await http.decode(Page<Clip>.self, request: request("clips", query: query))
    }
    public func clips(broadcasterID: String, after: String? = nil, startedAt: Date? = nil, endedAt: Date? = nil, first: Int = 20) async throws -> Page<Clip> {
        var q = ["broadcaster_id": broadcasterID, "first": String(min(max(first, 1), 100))]
        q["after"] = after
        let formatter = ISO8601DateFormatter()
        q["started_at"] = startedAt.map { formatter.string(from: $0) }
        q["ended_at"] = endedAt.map { formatter.string(from: $0) }
        return try await get(Clip.self, "clips", q)
    }
    /// Fetch whole recent intervals before sorting: Helix always ranks clips by views.
    public func recentClips(broadcasterID: String, since: Date, before: Date, minimumCount: Int = 20) async throws -> RecentClipPage {
        var end = before
        var items: [Clip] = []
        var seen = Set<String>()
        while end > since, items.count < max(1, minimumCount) {
            try Task.checkCancellation()
            let start = max(since, end.addingTimeInterval(-86400))
            let day = try await clipsInInterval(broadcasterID: broadcasterID, start: start, end: end)
            items += day.filter { seen.insert($0.id).inserted }
            end = start
        }
        items.sort { $0.creationDate == $1.creationDate ? $0.id < $1.id : $0.creationDate > $1.creationDate }
        return RecentClipPage(data: items, nextBefore: end > since ? end : nil)
    }
    private func clipsInInterval(broadcasterID: String, start: Date, end: Date) async throws -> [Clip] {
        var items: [Clip] = []
        var cursor: String?
        var cursors = Set<String>()
        repeat {
            try Task.checkCancellation()
            let page = try await clips(broadcasterID: broadcasterID, after: cursor, startedAt: start, endedAt: end, first: 100)
            items += page.data
            cursor = page.pagination?.cursor
            if let cursor, !cursors.insert(cursor).inserted { throw ClientError.invalidResponse }
        } while cursor != nil && items.count < 1000
        // Helix limits clip pagination to roughly 1,000 results. Split busy intervals.
        if items.count >= 1000 {
            guard end.timeIntervalSince(start) > 2 else { throw ClientError.message("Too many clips in this time interval. Please try again later.") }
            let middle = Date(timeIntervalSince1970: floor(start.timeIntervalSince1970 + end.timeIntervalSince(start) / 2))
            let newer = try await clipsInInterval(broadcasterID: broadcasterID, start: middle, end: end)
            let older = try await clipsInInterval(broadcasterID: broadcasterID, start: start, end: middle)
            return newer + older
        }
        return items.filter { $0.creationDate >= start && $0.creationDate < end }
    }
    public func emotes(broadcasterID: String? = nil) async throws -> Page<Emote> { if let id = broadcasterID { return try await get(Emote.self, "chat/emotes", ["broadcaster_id": id]) }; return try await get(Emote.self, "chat/emotes/global") }
    public func badges(broadcasterID: String? = nil) async throws -> Page<BadgeSet> { if let id = broadcasterID { return try await get(BadgeSet.self, "chat/badges", ["broadcaster_id": id]) }; return try await get(BadgeSet.self, "chat/badges/global") }
    public func subscription(broadcasterID: String, userID: String) async throws -> Page<Subscription> { try await get(Subscription.self, "subscriptions/user", ["broadcaster_id": broadcasterID, "user_id": userID]) }
    public func subscribeChat(sessionID: String, broadcasterID: String, userID: String) async throws {
        struct Body: Codable { var type = "channel.chat.message"; var version = "1"; var condition: Condition; var transport: Transport; struct Condition: Codable { var broadcasterUserId: String; var userId: String }; struct Transport: Codable { var method = "websocket"; var sessionId: String } }
        let body = Body(condition: .init(broadcasterUserId: broadcasterID, userId: userID), transport: .init(sessionId: sessionID))
        _ = try await http.response(request("eventsub/subscriptions", method: "POST", body: JSONCoding.encoder().encode(body)))
    }
    public func sendChat(broadcasterID: String, senderID: String, text: String) async throws -> ChatSendResult {
        struct Body: Codable { var broadcasterId: String; var senderId: String; var message: String }
        guard !text.isEmpty, text.count <= 500 else { throw ClientError.message("Chat messages must contain 1–500 characters.") }
        let body = try JSONCoding.encoder().encode(Body(broadcasterId: broadcasterID, senderId: senderID, message: text))
        let page = try await http.decode(Page<ChatSendResult>.self, request: request("chat/messages", method: "POST", body: body))
        guard let result = page.data.first else { throw ClientError.invalidResponse }; return result
    }
}

public enum VideoSort: String, Sendable { case recent = "time", views = "views" }
public struct RecentClipPage: Sendable {
    public let data: [Clip]
    public let nextBefore: Date?
}
extension Clip {
    public var creationDate: Date {
        guard let createdAt else { return .distantPast }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: createdAt) { return date }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: createdAt) ?? .distantPast
    }
}
