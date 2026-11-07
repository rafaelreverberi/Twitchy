import Foundation

public enum ProxyContract: String, Codable, Sendable, CaseIterable {
    case automatic, directHLS, luminous
}

/// Contains public, non-secret configuration only. Media signatures are never persisted.
public struct StreamingProxyConfiguration: Codable, Sendable, Equatable {
    public var enabled = false
    public var useCustom = false
    public var name = "Custom proxy"
    public var address = ""
    public var contract: ProxyContract = .directHLS
    public var allowLocalHTTP = false
    public init() {}
}
