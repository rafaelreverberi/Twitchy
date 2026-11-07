import Foundation
import TwitchyCore

public enum DefaultProxyConfiguration {
    // Fail closed: no public candidate passed permission + HLS + native playback verification.
    // Set exactly one configuration here only after completing docs/PROXY_RESEARCH.md.
    public static let verified: StreamingProxyConfiguration? = nil
    public static let unavailableReason = "No built-in proxy has passed all playback and operator-permission checks. Configure a permitted custom HLS proxy or a Twitchy source."
}

public enum ProxyError: Error, LocalizedError, Sendable, Equatable {
    case disabled, noVerifiedDefault, invalidConfiguration, invalidChannel, invalidPlaylist, unsafeURL, http(Int), exhausted
    public var errorDescription: String? {
        switch self {
        case .disabled: "Add or enable a playback source in Settings → Sources."
        case .noVerifiedDefault: DefaultProxyConfiguration.unavailableReason
        case .invalidConfiguration: "Enter a name and a permitted HTTPS base URL or HLS URL template containing {channel}. Do not include credentials, tokens or fragments."
        case .invalidChannel: "Enter a Twitch channel login using letters, numbers, or underscores (1–25 characters)."
        case .invalidPlaylist: "The proxy did not return a supported HLS playlist. Check its URL contract in proxy settings."
        case .unsafeURL: "The proxy returned an unsafe media URL or redirect. Use trusted HTTPS media without embedded credentials."
        case .http(let status): "The proxy returned HTTP \(status). This does not establish that the channel is offline. Retry later or check proxy settings."
        case .exhausted: "Playback recovery was exhausted. Retry playback or check streaming proxy settings."
        }
    }
}

public struct ProxyEndpoint: Sendable {
    public let configuration: StreamingProxyConfiguration
    public init(configuration: StreamingProxyConfiguration) { self.configuration = configuration }
    public func url(channel: String) throws -> URL {
        let login = channel.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard (1...25).contains(login.utf8.count), login.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 95 }) else { throw ProxyError.invalidChannel }
        guard !configuration.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ProxyError.invalidConfiguration }
        let input = configuration.address.trimmingCharacters(in: .whitespacesAndNewlines)
        let address = input.contains("://") ? input : "https://" + input
        let url: URL
        switch configuration.contract {
        case .automatic:
            var value = configuration; value.address = address
            value.contract = address.contains("{channel}") ? .directHLS : .luminous
            return try ProxyEndpoint(configuration: value).url(channel: login)
        case .directHLS:
            let marker = "twitchychannelplaceholder"
            guard address.components(separatedBy: "{channel}").count == 2,
                  let template = URLComponents(string: address.replacingOccurrences(of: "{channel}", with: marker)),
                  let host = template.host, !host.lowercased().contains(marker),
                  let resolved = URLComponents(string: address.replacingOccurrences(of: "{channel}", with: login))?.url else { throw ProxyError.invalidConfiguration }
            url = resolved
        case .luminous:
            // Documented upstream routes, preserving any deployment prefix and safe query parameters.
            guard let c = URLComponents(string: address), c.fragment == nil, let base = c.url else { throw ProxyError.invalidConfiguration }
            var value = URLComponents(url: base.appendingPathComponent("live").appendingPathComponent(login), resolvingAgainstBaseURL: false)!
            if value.queryItems == nil { value.queryItems = [URLQueryItem(name: "allow_source", value: "true"), URLQueryItem(name: "allow_audio_only", value: "true")] }
            guard let resolved = value.url else { throw ProxyError.invalidConfiguration }; url = resolved
        }
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false), c.fragment == nil,
              !(c.queryItems ?? []).contains(where: { item in
                  let key = item.name.lowercased()
                  return ["token", "sig", "signature", "key", "password", "auth", "credential", "secret"].contains(where: key.contains)
              }) else { throw ProxyError.invalidConfiguration }
        return try Self.safeMediaURL(url, local: configuration.allowLocalHTTP)
    }
    public static func safeMediaURL(_ url: URL, local: Bool) throws -> URL {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false), c.fragment == nil, c.user == nil, c.password == nil,
              let host = c.host?.lowercased(), !host.isEmpty, host != "169.254.169.254", !host.hasSuffix(".internal") else { throw ProxyError.unsafeURL }
        do { if !local {
                let parts = host.split(separator: ".").compactMap { Int($0) }
                let privateIPv4 = parts.count == 4 && (parts[0] == 0 || parts[0] == 10 || parts[0] == 127 || parts[0] >= 224 || (parts[0] == 169 && parts[1] == 254) || (parts[0] == 192 && parts[1] == 168) || (parts[0] == 172 && (16...31).contains(parts[1])) || (parts[0] == 100 && (64...127).contains(parts[1])))
                let ipv6 = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                guard !privateIPv4, host != "localhost", !host.hasSuffix(".local"), !host.hasSuffix(".localhost"),
                      !(host.contains(":") && (ipv6 == "::1" || ipv6 == "::" || ipv6.hasPrefix("fc") || ipv6.hasPrefix("fd") || ipv6.hasPrefix("fe8") || ipv6.hasPrefix("fe9") || ipv6.hasPrefix("fea") || ipv6.hasPrefix("feb") || ipv6.hasPrefix("::ffff:"))) else { throw ProxyError.unsafeURL }
            }
            return try SourceURL.media(url, allowLocalHTTP: local) } catch { throw ProxyError.unsafeURL }
    }
}

public struct ProxyMedia: Sendable {
    public var failedSourceIDs: Set<UUID> = []
    public var sourceID: UUID? = nil
    public let url: URL
    public let name: String
    public let variants: [String: URL]
    public let allowLocalHTTP: Bool
    public var qualities: [String] { ["auto"] + variants.keys.sorted() }
}

public struct HLSManifest: Sendable {
    public var variants: [String: URL] = [:]
    public var segments: [URL] = []
    public init(data: Data, base: URL, allowLocalHTTP: Bool) throws {
        guard data.count <= 1_048_576, let text = String(data: data, encoding: .utf8), text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#EXTM3U") else { throw ProxyError.invalidPlaylist }
        let uriExpression = try NSRegularExpression(pattern: #"URI="([^"]+)""#)
        var pending: String?
        var duration = false
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                guard pending == nil else { throw ProxyError.invalidPlaylist }
                pending = line
            } else if line.hasPrefix("#EXTINF:") { duration = true }
            else if !line.isEmpty, !line.hasPrefix("#") {
                guard let url = URL(string: line, relativeTo: base)?.absoluteURL else { throw ProxyError.invalidPlaylist }
                _ = try ProxyEndpoint.safeMediaURL(url, local: allowLocalHTTP)
                if let attributes = pending {
                    let resolution = attributes.range(of: #"RESOLUTION=\d+x(\d+)"#, options: .regularExpression).map { String(attributes[$0]).components(separatedBy: "x").last! + "p" }
                    let label = resolution ?? (attributes.contains("audio_only") ? "Audio only" : "Variant \(variants.count + 1)")
                    variants[variants[label] == nil ? label : "\(label) (\(variants.count + 1))"] = url
                    pending = nil
                } else if duration { segments.append(url); duration = false }
                else { throw ProxyError.invalidPlaylist }
            }
            // Validate every quoted URI (audio renditions, encryption keys, init maps, LL-HLS parts).
            for match in uriExpression.matches(in: line, range: NSRange(line.startIndex..., in: line)) {
                guard let range = Range(match.range(at: 1), in: line), let url = URL(string: String(line[range]), relativeTo: base)?.absoluteURL else { throw ProxyError.invalidPlaylist }
                _ = try ProxyEndpoint.safeMediaURL(url, local: allowLocalHTTP)
            }
        }
        guard pending == nil, !variants.isEmpty || !segments.isEmpty else { throw ProxyError.invalidPlaylist }
    }
}

/// Stateless resolver. No Auth/API dependency, no authorization parameter and no shared cookies.
public struct ProxyPlaybackProvider: Sendable {
    private let transport: any HTTPTransport
    public init(transport: any HTTPTransport = NetworkTransport(requestTimeout: 8, resourceTimeout: 12, maximumResponseBytes: 1_048_576)) { self.transport = transport }
    public func resolve(configuration: StreamingProxyConfiguration, request: PlaybackRequest) async throws -> ProxyMedia {
        guard request.contentType == "live" else { throw ClientError.unsupported }
        let endpoint = try ProxyEndpoint(configuration: configuration).url(channel: request.channelLogin ?? "")
        let (data, finalURL) = try await playlist(endpoint, local: configuration.allowLocalHTTP)
        let manifest = try HLSManifest(data: data, base: finalURL, allowLocalHTTP: configuration.allowLocalHTTP)
        if let child = manifest.variants.sorted(by: { $0.key < $1.key }).first?.value {
            let (data, base) = try await playlist(child, local: configuration.allowLocalHTTP)
            let childManifest = try HLSManifest(data: data, base: base, allowLocalHTTP: configuration.allowLocalHTTP)
            guard !childManifest.segments.isEmpty else { throw ProxyError.invalidPlaylist }
        }
        try Task.checkCancellation()
        return ProxyMedia(url: finalURL, name: configuration.name, variants: manifest.variants, allowLocalHTTP: configuration.allowLocalHTTP)
    }
    private func playlist(_ initial: URL, local: Bool) async throws -> (Data, URL) {
        var url = initial
        for hop in 0...3 {
            try Task.checkCancellation()
            _ = try ProxyEndpoint.safeMediaURL(url, local: local)
            var request = URLRequest(url: url); request.timeoutInterval = 8
            request.setValue("application/vnd.apple.mpegurl, application/x-mpegURL", forHTTPHeaderField: "Accept")
            let result = try await transport.send(request) // No automatic retries, cookies or credentials.
            try Task.checkCancellation()
            if [301, 302, 303, 307, 308].contains(result.status) {
                guard hop < 3, let location = result.headers["location"], let next = URL(string: location, relativeTo: url)?.absoluteURL,
                      next.scheme == "https" || (next.scheme == url.scheme && next.host == url.host && local) else { throw ProxyError.unsafeURL }
                url = next; continue
            }
            guard (200..<300).contains(result.status) else { throw ProxyError.http(result.status) }
            return (result.data, url)
        }
        throw ProxyError.unsafeURL
    }
}

public enum PlaybackFailurePolicy {
    public static func canRecover(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        if let error = error as? SourceAPIError { return error.problem.retryable && (error.status >= 500 || error.status == 429) }
        if let error = error as? URLError { return [.timedOut, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .notConnectedToInternet, .secureConnectionFailed, .serverCertificateUntrusted].contains(error.code) }
        if case ClientError.server(let status) = error { return status >= 500 || status == 429 }
        return false
    }
}

/// A direct playlist is deliberately not a fabricated Twitchy API session.
public enum ResolvedPlayback: Sendable {
    case source(StreamingSourceClient, PlaybackSession)
    case proxy(ProxyMedia)
    public var failedSourceIDs: Set<UUID> { switch self { case .source(_, let session): session.priorFailedSourceIDs ?? []; case .proxy(let media): media.failedSourceIDs } }
    public var sourceID: UUID? { switch self { case .source(let client, _): client.source.id; case .proxy(let media): media.sourceID } }
    public var url: URL { switch self { case .source(_, let session): session.hlsUrl; case .proxy(let media): media.url } }
    public var qualities: [String] { switch self { case .source(_, let session): session.qualities; case .proxy(let media): media.qualities } }
    public var providerName: String { switch self { case .source(let client, _): client.source.name; case .proxy(let media): media.name } }
}

@MainActor public struct PlaybackFallbackCoordinator {
    public let sources: StreamingSourceManager
    public let proxy: ProxyPlaybackProvider
    public init(sources: StreamingSourceManager, proxy: ProxyPlaybackProvider = .init()) { self.sources = sources; self.proxy = proxy }
    /// Explicit user order across provider kinds. No built-in proxy or hidden rotation.
    public func resolveOrdered(_ request: PlaybackRequest, excluding: Set<UUID> = []) async throws -> ResolvedPlayback {
        let revision = sources.playbackRevision
        var failed = excluding
        var lastError: (any Error)?
        for source in sources.sources where source.enabled && !excluding.contains(source.id) {
            try Task.checkCancellation()
            do {
                let result: ResolvedPlayback
                switch source.playbackKind {
                case .twitchyServer:
                    if let caps = source.capabilities, !caps.playbackProtocols.contains("hls") || (request.contentType == "live" ? !caps.live : request.contentType == "vod" ? !caps.vod : !caps.clips) { continue }
                    let client = try sources.client(for: source)
                    _ = try await client.probe()
                    let capabilities = try await client.capabilities()
                    guard capabilities.playbackProtocols.contains("hls"), request.contentType == "live" ? capabilities.live : request.contentType == "vod" ? capabilities.vod : capabilities.clips else { continue }
                    var session = try await client.createSession(request)
                    session.priorFailedSourceIDs = failed
                    guard !Task.isCancelled, sources.playbackRevision == revision else { Task { try? await client.endSession(session.sessionId) }; throw CancellationError() }
                    sources.notePlaybackCapabilities(source.id, capabilities: capabilities)
                    result = .source(client, session)
                case .twitchProxy:
                    guard request.contentType == "live" else { continue }
                    guard let configuration = source.proxyConfiguration else { throw ProxyError.invalidConfiguration }
                    var media = try await proxy.resolve(configuration: configuration, request: request)
                    media.sourceID = source.id; media.failedSourceIDs = failed; result = .proxy(media)
                case .removedEmbed: continue
                }
                guard !Task.isCancelled, sources.playbackRevision == revision else {
                    if case .source(let client, let session) = result { Task { try? await client.endSession(session.sessionId) } }
                    throw CancellationError()
                }
                sources.notePlaybackSource(source.id)
                return result
            } catch {
                try Task.checkCancellation()
                guard sources.playbackRevision == revision else { throw CancellationError() }
                // Source auth/content failures remain terminal. A proxy HTTP/manifest error is
                // a provider failure, never proof that Twitch's channel is offline.
                let recoverableProxy = source.playbackKind == .twitchProxy && ((error as? ProxyError) != nil || (error as? URLError)?.code != .cancelled)
                guard recoverableProxy || PlaybackFailurePolicy.canRecover(error) else { throw error }
                failed.insert(source.id)
                lastError = error
            }
        }
        throw ClientError.message(lastError == nil
            ? "Add a Twitchy Server or HLS proxy in Settings → Sources."
            : "All configured playback sources failed. Retry or check Settings → Sources.")
    }
    public func resolve(_ request: PlaybackRequest, configuration: StreamingProxyConfiguration, excluding: Set<UUID> = [], proxyAttempted: Bool = false) async throws -> ResolvedPlayback {
        let revision = sources.playbackRevision
        let ordered = [sources.selected].compactMap { $0 } + sources.sources.filter { $0.id != sources.activeID && $0.enabled }
        var lastError: (any Error)?
        for source in ordered where !excluding.contains(source.id) {
            if let caps = source.capabilities, !caps.playbackProtocols.contains("hls") || (request.contentType == "live" ? !caps.live : request.contentType == "vod" ? !caps.vod : !caps.clips) { continue }
            do {
                let client = try sources.client(for: source)
                _ = try await client.probe()
                try Task.checkCancellation()
                let session = try await client.createSession(request)
                guard !Task.isCancelled, sources.playbackRevision == revision else {
                    Task { try? await client.endSession(session.sessionId) }; throw CancellationError()
                }
                sources.notePlaybackSource(source.id)
                return .source(client, session)
            } catch {
                try Task.checkCancellation()
                guard sources.playbackRevision == revision else { throw CancellationError() }
                guard PlaybackFailurePolicy.canRecover(error) else { throw error }
                lastError = error
            }
        }
        guard request.contentType == "live" else { throw lastError ?? ClientError.noSource }
        guard configuration.enabled else { throw ProxyError.disabled }
        guard !proxyAttempted else { throw ProxyError.exhausted }
        let selected: StreamingProxyConfiguration
        if configuration.useCustom { selected = configuration }
        else { guard let value = DefaultProxyConfiguration.verified else { throw ProxyError.noVerifiedDefault }; selected = value }
        do {
            let media = try await proxy.resolve(configuration: selected, request: request)
            try Task.checkCancellation()
            guard sources.playbackRevision == revision else { throw CancellationError() }
            return .proxy(media)
        } catch is CancellationError { throw CancellationError() }
        catch let error as ProxyError { throw error }
        catch { throw ClientError.message("The fallback proxy could not be reached. Retry later or check Settings → Advanced → Streaming Proxy / Fallback.") }
    }
}
