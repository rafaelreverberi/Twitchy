#if os(iOS)
import SwiftUI
import TwitchyChat
import TwitchyAPI
import TwitchyDesignSystem

struct MobileChatView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var companionChat: ChatController? = nil
    var companionBroadcasterID: String? = nil
    var authorizeChat: (() -> Void)? = nil
    private var chat: ChatController { companionChat ?? model.chat }
    @State private var text = ""
    @State private var follow = true
    @State private var sending = false
    @State private var received: [String: Date] = [:]
    @FocusState private var composing: Bool
    private var fixture: Bool {
        #if DEBUG && targetEnvironment(simulator)
        MobileFixtures.enabled || ProcessInfo.processInfo.environment["TWITCHY_UI_COMPANION_FIXTURE"] == "live"
        #else
        false
        #endif
    }
    private var messages: [ChatMessage] {
        #if DEBUG && targetEnvironment(simulator)
        if fixture { return MobileFixtures.messages }
        #endif
        return chat.messages
    }
    private var authorized: Bool { fixture || model.auth.session?.scopes.contains("user:read:chat") == true }
    var body: some View {
        if companionChat == nil && model.isOfflinePlayback { OfflineChatNotice() } else {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 9) {
                        ForEach(messages) { message in
                            MobileChatMessage(chat: chat, message: message, timestamp: received[message.id] ?? .now)
                                .id(message.id).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }.padding(.horizontal, 16).padding(.vertical, 12)
                }
                .contentShape(Rectangle())
                .simultaneousGesture(TapGesture().onEnded { composing = false; model.mobile.isComposing = false })
                .scrollDismissesKeyboard(.interactively)
                .defaultScrollAnchor(.bottom)
                .simultaneousGesture(DragGesture().onChanged { _ in follow = false })
                .overlay {
                    if messages.isEmpty {
                        VStack(spacing: 10) {
                            if !authorized {
                                Text("Join the conversation").font(.subheadline.weight(.semibold))
                                Text("Connect your Twitch account with chat permissions.").font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                                Button("Connect chat") { if let authorizeChat { authorizeChat() } else { Task { await model.login(chat: true) } } }.buttonStyle(.bordered).accessibilityIdentifier("chat.authorize")
                            } else {
                                Text(chat.status == "Connected" ? "Be the first to say hello." : "Connecting to live chat…").font(.footnote).foregroundStyle(.secondary)
                            }
                        }.padding(28)
                    }
                }
                .overlay(alignment: .bottom) {
                    if !follow, !messages.isEmpty {
                        Button { follow = true; if let last = messages.last { proxy.scrollTo(last.id, anchor: .bottom) } } label: {
                            Label("Latest messages", systemImage: "arrow.down").font(.caption.weight(.semibold)).padding(.horizontal, 14).padding(.vertical, 8)
                        }.background(.regularMaterial, in: Capsule()).padding(.bottom, 10)
                    }
                }
                .onChange(of: messages.last?.id, initial: true) { _, _ in
                    for message in messages where received[message.id] == nil { received[message.id] = .now }
                    let ids = Set(messages.map(\.id)); received = received.filter { ids.contains($0.key) }
                    if follow, model.personal.data.preferences.autoscroll, let last = messages.last {
                        if reduceMotion || model.personal.data.preferences.reduceMotion { proxy.scrollTo(last.id, anchor: .bottom) }
                        else { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(last.id, anchor: .bottom) } }
                    }
                }
            }
            if let error = chat.error, !fixture { Text(error).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.vertical, 6) }
            Divider()
            HStack(alignment: .bottom, spacing: 10) {
                TextField(authorized ? "Send a message" : "Connect to chat", text: $text, axis: .vertical)
                    .lineLimit(1...4).font(.subheadline).padding(.horizontal, 14).padding(.vertical, 11)
                    .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 22))
                    .focused($composing).disabled(!authorized).accessibilityIdentifier("chat.input")
                    .submitLabel(.done)
                Button { send() } label: {
                    Image(systemName: "arrow.up").font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 40, height: 40).background(TwitchyTheme.accent, in: Circle())
                }.disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sending || chat.status != "Connected" || fixture)
                    .opacity(text.isEmpty ? 0.4 : 1).accessibilityLabel("Send message")
            }.padding(.horizontal, 12).padding(.vertical, 10).background(Color(uiColor: .secondarySystemBackground))
        }
        .background(Color(uiColor: .systemBackground))
        .onChange(of: composing) { _, focused in model.mobile.isComposing = focused }
        .onChange(of: model.mobile.isComposing) { _, focused in if !focused { composing = false } }
        .onDisappear { composing = false; model.mobile.isComposing = false }
    }
    }
    private func send() {
        guard let api = model.api, let session = model.auth.session, let id = companionBroadcasterID ?? model.mobile.selection?.broadcasterID,
              !fixture, !sending, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        sending = true; let message = text
        Task {
            if await chat.send(api: api, broadcasterID: id, userID: session.userID, text: message), text == message { text = "" }
            sending = false
        }
    }
}
private struct MobileChatMessage: View {
    let chat: ChatController
    @Environment(AppModel.self) private var model
    let message: ChatMessage
    let timestamp: Date
    var body: some View {
        MobileChatFlow(spacing: 2) {
            if model.personal.data.preferences.timestamps {
                Text(timestamp.formatted(date: .omitted, time: .shortened)).font(.caption2).foregroundStyle(.tertiary).padding(.trailing, 3)
            }
            ForEach(message.badges, id: \.setId) { badge in
                if let url = chat.badgeImages["\(badge.setId)/\(badge.id)"] {
                    AsyncImage(url: url) { image in image.resizable().scaledToFit() } placeholder: { Color.clear }
                        .frame(width: 17, height: 17).accessibilityLabel(badge.setId)
                }
            }
            Text(message.chatterUserName + ":").fontWeight(.semibold).foregroundStyle(usernameColor).padding(.trailing, 2)
            if model.personal.data.preferences.emotes, !message.message.fragments.isEmpty {
                ForEach(Array(message.message.fragments.enumerated()), id: \.offset) { _, fragment in
                    if let emote = fragment.emote, let url = URL(string: "https://static-cdn.jtvnw.net/emoticons/v2/\(emote.id)/default/dark/1.0") {
                        AsyncImage(url: url) { image in image.resizable().scaledToFit() } placeholder: { Text(fragment.text).font(.caption2) }
                            .frame(width: 24, height: 24).accessibilityLabel(fragment.text)
                    } else { words(fragment.text) }
                }
            } else { words(message.message.text) }
        }
        .font(.system(size: model.personal.data.preferences.chatFontSize))
        .accessibilityElement(children: .ignore).accessibilityLabel(message.chatterUserName + ": " + message.message.text)
    }
    @ViewBuilder private func words(_ text: String) -> some View {
        ForEach(Array(text.split(separator: " ", omittingEmptySubsequences: false).enumerated()), id: \.offset) { _, word in Text(String(word) + " ") }
    }
    private var usernameColor: Color {
        let hex = message.color.replacingOccurrences(of: "#", with: "")
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return TwitchyTheme.highlight }
        return Color(hex: value)
    }
}
/// Inline badges, names, words and emotes wrap together instead of competing in an HStack.
private struct MobileChatFlow: Layout {
    let spacing: CGFloat
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 320
        return CGSize(width: width, height: positions(width: width, subviews: subviews).height)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let layout = positions(width: bounds.width, subviews: subviews)
        for (index, view) in subviews.enumerated() {
            view.place(at: CGPoint(x: bounds.minX + layout.points[index].x, y: bounds.minY + layout.points[index].y), anchor: .topLeading, proposal: ProposedViewSize(width: min(bounds.width, view.sizeThatFits(.unspecified).width), height: nil))
        }
    }
    private func positions(width: CGFloat, subviews: Subviews) -> (points: [CGPoint], height: CGFloat) {
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        var points: [CGPoint] = []
        for view in subviews {
            let size = view.sizeThatFits(ProposedViewSize(width: min(width, view.sizeThatFits(.unspecified).width), height: nil))
            if x > 0, x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            points.append(CGPoint(x: x, y: y)); x += size.width + spacing; rowHeight = max(rowHeight, size.height)
        }
        return (points, y + rowHeight)
    }
}
#endif
