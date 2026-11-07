import Foundation
import TwitchyCore

public enum PlaybackSourceKind: String, Codable, Sendable, CaseIterable {
    case twitchProxy, twitchyServer
    // Decode older local and iCloud records so the source manager can discard them.
    case removedEmbed = "officialTwitch"

    public static let allCases: [Self] = [.twitchProxy, .twitchyServer]
    public var title: String {
        switch self { case .removedEmbed: "Removed source"; case .twitchProxy: "Twitch Proxy"; case .twitchyServer: "Twitchy Server" }
    }
    public var symbol: String {
        switch self { case .removedEmbed: "nosign"; case .twitchProxy: "network"; case .twitchyServer: "server.rack" }
    }
}

public extension StreamingSource {
    var playbackKind: PlaybackSourceKind { kind ?? .twitchyServer }
    var endpointLabel: String { playbackKind == .twitchProxy ? proxyConfiguration?.address ?? "Not configured" : baseURL.absoluteString }
    static func proxy(name: String, configuration: StreamingProxyConfiguration, id: UUID = UUID()) throws -> StreamingSource {
        let url = try ProxyEndpoint(configuration: configuration).url(channel: "validation")
        var source = StreamingSource(id: id, name: name, baseURL: url, allowLocalHTTP: configuration.allowLocalHTTP)
        source.kind = .twitchProxy; source.proxyConfiguration = configuration
        return source
    }
}
