// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "TwitchyKit", platforms: [.macOS(.v14), .iOS(.v17), .tvOS(.v17)],
    products: ["TwitchyCore", "TwitchyAPI", "TwitchyAuth", "TwitchySources", "TwitchyPlayback", "TwitchyChat", "TwitchyDesignSystem"].map { .library(name: $0, targets: [$0]) },
    targets: [
        .target(name: "TwitchyCore"),
        .target(name: "TwitchyAPI", dependencies: ["TwitchyCore"]),
        .target(name: "TwitchyAuth", dependencies: ["TwitchyCore"]),
        .target(name: "TwitchySources", dependencies: ["TwitchyCore"]),
        .target(name: "TwitchyPlayback", dependencies: ["TwitchyCore", "TwitchySources"]),
        .target(name: "TwitchyChat", dependencies: ["TwitchyCore", "TwitchyAPI"]),
        .target(name: "TwitchyDesignSystem"),
        .testTarget(name: "TwitchyKitTests", dependencies: ["TwitchyCore", "TwitchyAPI", "TwitchyAuth", "TwitchySources", "TwitchyPlayback", "TwitchyChat"])
    ])
