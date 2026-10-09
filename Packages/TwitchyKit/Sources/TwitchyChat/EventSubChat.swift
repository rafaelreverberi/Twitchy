import Foundation
import Observation
import TwitchyCore
import TwitchyAPI

public struct ChatMessage: Codable, Sendable, Identifiable {
    public var id: String { messageId }
    public var chatterUserName: String; public var chatterUserLogin: String; public var color: String; public var messageId: String; public var message: Message; public var badges: [Badge]
    public struct Message: Codable, Sendable { public var text: String; public var fragments: [Fragment] }
    public struct Fragment: Codable, Sendable { public var type: String; public var text: String; public var emote: Emote?; public struct Emote: Codable, Sendable { public var id: String } }
    public struct Badge: Codable, Sendable { public var setId: String; public var id: String; public var info: String }
}
public struct EventSubEnvelope: Decodable, Sendable {
    public var metadata: Metadata; public var payload: Payload
    public struct Metadata: Decodable, Sendable { public var messageId: String; public var messageType: String; public var messageTimestamp: String }
    public struct Payload: Decodable, Sendable { public var session: Session?; public var event: ChatMessage?; public var subscription: Subscription? }
    public struct Session: Decodable, Sendable { public var id: String; public var keepaliveTimeoutSeconds: Int?; public var reconnectUrl: String? }
    public struct Subscription: Decodable, Sendable { public var status: String? }
}
public enum EventSubPolicy {
    public static func reconnectURL(_ text: String) throws -> URL {
        guard let url = URL(string: text), url.scheme == "wss", url.host == "eventsub.wss.twitch.tv", url.user == nil, url.password == nil else { throw ClientError.invalidURL }; return url
    }
    public static func backoff(attempt: Int) -> Double { min(30, pow(2, Double(min(attempt, 5)))) }
}
@MainActor @Observable public final class ChatController {
    public private(set) var messages: [ChatMessage] = []
    public private(set) var status = "Disconnected"
    public private(set) var error: String?
    public private(set) var badgeImages: [String: URL] = [:]
    private var task: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var socket: URLSessionWebSocketTask?
    private var migratingSocket: URLSessionWebSocketTask?
    private var migrationReader: Task<Void, Never>?
    private let network = URLSession(configuration: .ephemeral)
    private var lastMessage = Date()
    private var keepalive = 30
    private var lastSent = Date.distantPast
    private var seen: [String] = []
    private var generation = UUID()
    public init() {}
    public func connect(api: TwitchAPIClient, broadcasterID: String, userID: String) {
        disconnect(); messages = []; seen = []; let current = UUID(); generation = current
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let global = try await api.badges(); let channel = try await api.badges(broadcasterID: broadcasterID)
                guard generation == current else { return }
                for set in global.data + channel.data { for version in set.versions { badgeImages["\(set.setId)/\(version.id)"] = URL(string: version.imageUrl1x) } }
            } catch { self.error = "Chat badges could not be loaded." }
            var next = URL(string: "wss://eventsub.wss.twitch.tv/ws")!
            var migrated = false; var failures = 0
            while !Task.isCancelled && generation == current {
                let connection = network.webSocketTask(with: next); socket = connection; connection.resume(); lastMessage = .now; status = "Connecting"
                watchdog?.cancel()
                watchdog = Task { [weak self] in
                    while !Task.isCancelled {
                        do { try await Task.sleep(for: .seconds(5)) } catch { return }
                        guard let self, generation == current else { return }
                        if Date().timeIntervalSince(lastMessage) > Double(keepalive + 10) { connection.cancel(with: .goingAway, reason: nil); return }
                    }
                }
                do {
                    while !Task.isCancelled && generation == current {
                        let frame = try await connection.receive(); let data: Data
                        switch frame { case .data(let value): data = value; case .string(let value): data = Data(value.utf8); @unknown default: continue }
                        let envelope = try JSONCoding.decoder().decode(EventSubEnvelope.self, from: data)
                        lastMessage = .now
                        switch envelope.metadata.messageType {
                        case "session_welcome":
                            guard let session = envelope.payload.session else { throw ClientError.invalidResponse }
                            keepalive = session.keepaliveTimeoutSeconds ?? 30
                            if migrated { migratingSocket?.cancel(with: .normalClosure, reason: nil); migratingSocket = nil; migrationReader?.cancel(); migrationReader = nil }
                            if !migrated { try await api.subscribeChat(sessionID: session.id, broadcasterID: broadcasterID, userID: userID) }
                            migrated = false; failures = 0; status = "Connected"; error = nil
                        case "notification":
                            if let event = envelope.payload.event { append(event) }
                        case "session_reconnect":
                            guard let url = envelope.payload.session?.reconnectUrl else { throw ClientError.invalidResponse }
                            next = try EventSubPolicy.reconnectURL(url); migrated = true
                            migratingSocket = connection
                            migrationReader = Task { [weak self] in
                                do {
                                    while !Task.isCancelled {
                                        let frame = try await connection.receive()
                                        let bytes: Data
                                        switch frame { case .data(let value): bytes = value; case .string(let value): bytes = Data(value.utf8); @unknown default: continue }
                                        let oldEnvelope = try JSONCoding.decoder().decode(EventSubEnvelope.self, from: bytes)
                                        guard let self, generation == current else { return }
                                        if let event = oldEnvelope.payload.event { append(event) }
                                    }
                                } catch { /* New socket or outer reconnect owns recovery. */ }
                            }
                            // Keep draining old messages until the new welcome transfers subscriptions.
                            break
                        case "revocation": throw ClientError.missingScope
                        default: break
                        }
                        if migrated { break }
                    }
                    if !migrated { connection.cancel(with: .normalClosure, reason: nil) }
                } catch {
                    connection.cancel(with: .goingAway, reason: nil)
                    migratingSocket?.cancel(with: .goingAway, reason: nil); migratingSocket = nil; migrationReader?.cancel(); migrationReader = nil
                    guard !Task.isCancelled, generation == current else { break }
                    self.error = error.localizedDescription
                    if let typed = error as? ClientError, typed == .missingScope || typed == .unauthorized { status = "Reconnect Twitch to authorize chat"; break }
                    status = "Reconnecting"; migrated = false; next = URL(string: "wss://eventsub.wss.twitch.tv/ws")!; failures += 1
                    do { try await Task.sleep(for: .seconds(EventSubPolicy.backoff(attempt: failures))) } catch { break }
                }
            }
            watchdog?.cancel()
        }
    }
    public func send(api: TwitchAPIClient, broadcasterID: String, userID: String, text: String) async -> Bool {
        guard Date().timeIntervalSince(lastSent) >= 1.2 else { error = "Wait a moment before sending another message."; return false }
        lastSent = .now
        do { let response = try await api.sendChat(broadcasterID: broadcasterID, senderID: userID, text: text); guard response.isSent else { error = response.dropReason?.message ?? "Twitch did not accept this message."; return false }; error = nil; return true }
        catch { self.error = error.localizedDescription; return false }
    }
    private func append(_ event: ChatMessage) {
        guard !seen.contains(event.id) else { return }
        messages.append(event); seen.append(event.id); messages = Array(messages.suffix(300)); seen = Array(seen.suffix(600))
    }
    public func disconnect() { migratingSocket?.cancel(with: .normalClosure, reason: nil); migratingSocket = nil; migrationReader?.cancel(); migrationReader = nil; generation = UUID(); task?.cancel(); task = nil; watchdog?.cancel(); watchdog = nil; socket?.cancel(with: .normalClosure, reason: nil); socket = nil; status = "Disconnected"; badgeImages = [:] }
}
