#if os(macOS)
import Foundation
import Network

@MainActor final class DiscordPresence {
    static let enabledKey = "discordPresenceEnabled"
    static let applicationIDKey = "discordPresenceApplicationID"
    static let defaultApplicationID = Bundle.main.object(forInfoDictionaryKey: "DiscordApplicationID") as? String ?? ""

    struct Viewing: Equatable {
        let id: UUID
        let channel: String
        let channelLogin: String
        let title: String?
        let avatarURL: URL?
        let playing: Bool
    }

    private var viewingID: UUID?
    private var accumulated: TimeInterval = 0
    private var playingSince: TimeInterval?
    private var interruptedAt: TimeInterval?
    private let interruptionGrace: TimeInterval = 8
    private var timestamp: Int64 = 0
    private var applicationID = ""
    private var desiredChannel: String?
    private var desiredTitle: String?
    private var desiredAvatar: URL?
    private var desiredChannelURL: URL?
    private var publishedChannel: String?
    private var publishedTitle: String?
    private var publishedAvatar: URL?
    private var publishedChannelURL: URL?
    private var publishedTimestamp: Int64 = 0
    private var connection: NWConnection?
    private var ready = false
    private var retryAfter: TimeInterval = 0
    private var handshakeDeadline: TimeInterval = 0
    private var nextSocket = 0

    func update(enabled: Bool, applicationID: String, viewing: Viewing?) {
        let id = applicationID.trimmingCharacters(in: .whitespacesAndNewlines)
        let configuredID = enabled && UInt64(id).map({ $0 > 0 }) == true ? id : ""
        let now = ProcessInfo.processInfo.systemUptime

        if self.applicationID != configuredID {
            disconnect()
            self.applicationID = configuredID
            retryAfter = 0
            nextSocket = 0
        }
        if viewingID != viewing?.id {
            viewingID = viewing?.id
            accumulated = 0
            playingSince = nil
            interruptedAt = nil
        }
        if let viewing, viewing.playing {
            interruptedAt = nil
            if playingSince == nil {
                playingSince = now
                timestamp = Int64(Date.now.timeIntervalSince1970 - accumulated)
            }
        } else if let playingSince {
            // AVPlayer may briefly report a pause while switching segments or recovering.
            let interruption = interruptedAt ?? now
            interruptedAt = interruption
            if now - interruption >= interruptionGrace {
                accumulated += interruption - playingSince
                self.playingSince = nil
            }
        }
        let visible = configuredID.isEmpty || playingSince == nil ? nil : viewing
        desiredChannel = visible?.channel
        desiredTitle = visible?.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        if desiredTitle?.count ?? 0 < 2 { desiredTitle = nil }
        desiredAvatar = visible?.avatarURL
        desiredChannelURL = visible.flatMap { viewing in
            let login = viewing.channelLogin
            guard !login.isEmpty, login.range(of: #"\A[A-Za-z0-9_]+\z"#, options: .regularExpression) != nil else { return nil }
            return URL(string: "https://www.twitch.tv/\(login)")
        }

        if ready {
            publish()
        } else if connection != nil {
            if desiredChannel == nil || now >= handshakeDeadline { disconnect() }
        } else if desiredChannel != nil, now >= retryAfter {
            connect(now: now)
        }
    }

    func stopWatching() {
        update(enabled: !applicationID.isEmpty, applicationID: applicationID, viewing: nil)
    }

    private func connect(now: TimeInterval) {
        retryAfter = now + 5
        let environment = ProcessInfo.processInfo.environment
        let directories = ["XDG_RUNTIME_DIR", "TMPDIR", "TMP", "TEMP"].compactMap { environment[$0] } + ["/tmp"]
        var seen = Set<String>()
        let sockets = directories.flatMap { directory in
            (0..<10).map { URL(fileURLWithPath: directory).appendingPathComponent("discord-ipc-\($0)").path }
        }.filter { seen.insert($0).inserted && FileManager.default.fileExists(atPath: $0) }
        guard !sockets.isEmpty else { return }

        let socket = sockets[nextSocket % sockets.count]
        nextSocket = (nextSocket + 1) % sockets.count
        let connection = NWConnection(to: .unix(path: socket), using: .tcp)
        self.connection = connection
        handshakeDeadline = now + 5
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            Task { @MainActor in
                guard let self, let connection, self.connection === connection else { return }
                switch state {
                case .ready:
                    self.send(0, json: ["v": 1, "client_id": self.applicationID], on: connection)
                    self.read(on: connection)
                case .failed, .cancelled, .waiting:
                    self.disconnect()
                default: break
                }
            }
        }
        connection.start(queue: .main)
    }

    private func disconnect() {
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        ready = false
        publishedChannel = nil
        publishedTitle = nil
        publishedAvatar = nil
        publishedChannelURL = nil
    }

    private func publish() {
        guard let connection, publishedChannel != desiredChannel || publishedTitle != desiredTitle || publishedAvatar != desiredAvatar ||
              publishedChannelURL != desiredChannelURL || (desiredChannel != nil && publishedTimestamp != timestamp) else { return }
        let activity: Any
        if let desiredChannel {
            var assets = ["large_image": "twitchy_icon", "large_text": "Twitchy"]
            if let desiredAvatar, desiredAvatar.scheme == "https", desiredAvatar.absoluteString.count <= 300 {
                assets["small_image"] = desiredAvatar.absoluteString
                assets["small_url"] = desiredChannelURL?.absoluteString
                assets["small_text"] = "Watching " + String(desiredChannel.prefix(100))
            }
            var payload: [String: Any] = [
                "type": 3,
                "assets": assets,
                "details": "Watching \(String(desiredChannel.prefix(100)))",
                "timestamps": ["start": timestamp],
                "buttons": [["label": "Get Twitchy", "url": "https://github.com/rafaelreverberi/Twitchy"]]
            ]
            if let desiredTitle { payload["state"] = String(desiredTitle.prefix(128)) }
            activity = payload
        } else {
            activity = NSNull()
        }
        publishedChannel = desiredChannel
        publishedTitle = desiredTitle
        publishedAvatar = desiredAvatar
        publishedChannelURL = desiredChannelURL
        publishedTimestamp = timestamp
        send(1, json: [
            "cmd": "SET_ACTIVITY",
            "args": ["pid": ProcessInfo.processInfo.processIdentifier, "activity": activity],
            "nonce": UUID().uuidString
        ], on: connection)
    }

    private func send(_ opcode: UInt32, json: [String: Any], on connection: NWConnection) {
        guard let body = try? JSONSerialization.data(withJSONObject: json) else { return }
        send(opcode, body: body, on: connection)
    }

    private func send(_ opcode: UInt32, body: Data, on connection: NWConnection) {
        var header = [opcode.littleEndian, UInt32(body.count).littleEndian]
        let frame = header.withUnsafeMutableBytes { Data($0) } + body
        connection.send(content: frame, completion: .contentProcessed { [weak self, weak connection] error in
            guard error != nil else { return }
            Task { @MainActor in
                guard let self, let connection, self.connection === connection else { return }
                self.disconnect()
            }
        })
    }

    private func receive(_ count: Int, on connection: NWConnection, completion: @escaping @MainActor @Sendable (Data) -> Void) {
        connection.receive(minimumIncompleteLength: count, maximumLength: count) { [weak self, weak connection] data, _, complete, error in
            Task { @MainActor in
                guard let self, let connection, self.connection === connection else { return }
                guard let data, data.count == count, !complete, error == nil else { self.disconnect(); return }
                completion(data)
            }
        }
    }

    private func read(on connection: NWConnection) {
        receive(8, on: connection) { [weak self, weak connection] header in
            guard let self, let connection else { return }
            let (opcode, length) = header.withUnsafeBytes {
                (UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)),
                 Int(UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self))))
            }
            guard (1...65536).contains(length), opcode != 2 else { disconnect(); return }
            receive(length, on: connection) { [weak self, weak connection] body in
                guard let self, let connection else { return }
                if opcode == 3 { send(4, body: body, on: connection) }
                if opcode == 1, let message = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                    if message["evt"] as? String == "READY" {
                        ready = true
                        publish()
                    }
                }
                read(on: connection)
            }
        }
    }
}
#endif
