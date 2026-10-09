import SwiftUI
public enum TwitchyTheme {
    public static let background = Color(hex: 0x0E0E10)
    public static let secondary = Color(hex: 0x18181B)
    public static let elevated = Color(hex: 0x1F1F23)
    public static let accent = Color(hex: 0x9146FF)
    public static let highlight = Color(hex: 0xA970FF)
    public static let muted = Color(hex: 0xADADB8)
    public static let live = Color(hex: 0x00C896)
    public static let error = Color(hex: 0xEB0400)
    public static let spacing: CGFloat = 20
}
extension Color {
    public init(hex: UInt32) { self.init(.sRGB, red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255, opacity: 1) }
}
public struct BrandMark: View {
    public init() {}
    public var body: some View { Image(systemName: "play.square.stack.fill").font(.system(size: 36, weight: .bold)).foregroundStyle(TwitchyTheme.accent).accessibilityLabel("Twitchy") }
}
public struct EmptyState: View {
    let title: String; let detail: String; let symbol: String
    public init(_ title: String, detail: String, symbol: String = "play.rectangle") { self.title = title; self.detail = detail; self.symbol = symbol }
    public var body: some View { VStack(spacing: 16) { Image(systemName: symbol).font(.system(size: 42)).foregroundStyle(TwitchyTheme.accent); Text(title).font(.title2.bold()); Text(detail).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420) }.padding(40).frame(maxWidth: .infinity) }
}
public struct RemoteImage: View {
    public var url: URL?; public var symbol: String
    public init(_ url: URL?, symbol: String = "play.rectangle") { self.url = url; self.symbol = symbol }
    public var body: some View {
        AsyncImage(url: url) { phase in
            if let image = phase.image { image.resizable().scaledToFill() }
            else { Rectangle().fill(TwitchyTheme.elevated).overlay { Image(systemName: symbol).font(.largeTitle).foregroundStyle(TwitchyTheme.muted) }.overlay { if phase.error == nil && url != nil { ProgressView() } } }
        }.clipped()
    }
}
public struct Notice: View {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var body: some View { Label(message, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(TwitchyTheme.muted).padding().frame(maxWidth: .infinity, alignment: .leading).background(TwitchyTheme.secondary, in: RoundedRectangle(cornerRadius: 12)).accessibilityIdentifier("status.notice") }
}
