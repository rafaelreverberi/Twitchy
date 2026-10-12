import Foundation

/// Public account metadata only. Authentication remains in the device Keychain.
public struct AccountProfileCache {
    public let url: URL
    public init(url: URL) { self.url = url }
    public func load(userID: String) -> TwitchUser? {
        guard let data = try? Data(contentsOf: url),
              let user = try? JSONDecoder().decode(TwitchUser.self, from: data),
              user.id == userID else { return nil }
        return user
    }
    public func save(_ user: TwitchUser) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(user).write(to: url, options: .atomic)
    }
    public func clear() { try? FileManager.default.removeItem(at: url) }
}
