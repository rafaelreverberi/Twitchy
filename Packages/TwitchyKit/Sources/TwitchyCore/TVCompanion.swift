import Foundation

/// Short-lived TV presence in the user's encrypted private iCloud database.
public struct TVLivePresence: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var deviceName: String
    public var login: String
    public var name: String
    public var broadcasterID: String
    public init(id: String, deviceName: String, login: String, name: String, broadcasterID: String) {
        self.id = id; self.deviceName = deviceName; self.login = login; self.name = name; self.broadcasterID = broadcasterID
    }
    public static let keyPrefix = "companion/tv/"
    public static let lifetime: TimeInterval = 60
    public static func active(in values: [String: SyncValue], now: Date = .now) -> [TVLivePresence] {
        values.values.sorted { $0.modifiedAt > $1.modifiedAt }.compactMap { value in
            guard value.key.hasPrefix(keyPrefix), now.timeIntervalSince(value.modifiedAt) >= -10,
                  now.timeIntervalSince(value.modifiedAt) < lifetime, let payload = value.payload,
                  let presence = try? JSONDecoder().decode(Self.self, from: payload),
                  value.key == keyPrefix + presence.id, !presence.login.isEmpty, !presence.broadcasterID.isEmpty else { return nil }
            return presence
        }
    }
}
