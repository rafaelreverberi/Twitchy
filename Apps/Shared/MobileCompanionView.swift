#if os(iOS) || os(macOS)
import SwiftUI
import TwitchyCore
import TwitchyChat

struct CompanionView: View {
    var close: (() -> Void)? = nil
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var chat = ChatController()
    @State private var now = Date.now
    @State private var selectedTV: String?
    @State private var showingAuthorization = false
    private var televisions: [TVLivePresence] {
        #if DEBUG && (os(macOS) || targetEnvironment(simulator))
        if let scenario = ProcessInfo.processInfo.environment["TWITCHY_UI_COMPANION_FIXTURE"] {
            return scenario == "live" ? [.init(id: "fixture-tv", deviceName: "Living Room", login: "fixture", name: "Playback test", broadcasterID: "fixture")] : []
        }
        #endif
        return TVLivePresence.active(in: model.sync.cloud.values, now: now)
    }
    private var isFixture: Bool {
        #if os(iOS)
        model.isMobileFixture
        #elseif DEBUG && os(macOS)
        ProcessInfo.processInfo.environment["TWITCHY_UI_COMPANION_FIXTURE"] != nil
        #else
        false
        #endif
    }
    private var stream: TVLivePresence? { televisions.first { $0.id == selectedTV } ?? televisions.first }
    var body: some View {
        NavigationStack {
            Group {
                if let stream {
                    #if os(iOS)
                    MobileChatView(companionChat: chat, companionBroadcasterID: stream.broadcasterID, authorizeChat: {
                        showingAuthorization = true
                        Task { await model.login(chat: true, presentSettings: false) }
                    })
                        .id(stream.broadcasterID)
                    #else
                    ChatPanel(broadcasterID: stream.broadcasterID, companionChat: chat, authorizeChat: {
                        showingAuthorization = true
                        Task { await model.login(chat: true, presentSettings: false) }
                    })
                        .id(stream.broadcasterID)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    #endif
                } else {
                    ContentUnavailableView {
                        Label("Start a stream on your TV", systemImage: "tv")
                    } description: {
                        Text("Play a live stream in Twitchy on your Apple TV. Use the same iCloud account on both devices; its chat will appear here.")
                    } actions: {
                        Button("Refresh") { Task { if !isFixture { await model.sync.sync() }; now = .now } }
                        Text(model.sync.cloud.status).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(stream?.name ?? "Companion Mode")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { if let close { close() } else { dismiss() } }.accessibilityIdentifier("companion.close")
                }
                ToolbarItem(placement: .primaryAction) {
                    if televisions.count > 1 {
                        Menu {
                            ForEach(televisions) { tv in Button("\(tv.deviceName) · \(tv.name)") { selectedTV = tv.id } }
                        } label: { Image(systemName: "tv") }.accessibilityLabel("Choose Apple TV")
                    }
                }
            }
            #else
            .safeAreaInset(edge: .top, spacing: 0) {
                HStack {
                    Button("Done") { if let close { close() } else { dismiss() } }
                        .accessibilityIdentifier("companion.close")
                    Spacer()
                    Text(stream?.name ?? "Companion Mode").font(.headline)
                    Spacer()
                    if televisions.count > 1 {
                        Menu {
                            ForEach(televisions) { tv in Button("\(tv.deviceName) · \(tv.name)") { selectedTV = tv.id } }
                        } label: { Image(systemName: "tv") }.accessibilityLabel("Choose Apple TV")
                    }
                }.padding(16).background(.bar)
            }
            #endif
        }
        .task(id: "\(scenePhase)|\(stream?.broadcasterID ?? "")|\(model.auth.session?.accessToken ?? "")|\(model.auth.status)") {
            chat.disconnect()
            guard scenePhase == .active, let stream, let api = model.api, let session = model.auth.session,
                  session.scopes.contains("user:read:chat") else { return }
            chat.connect(api: api, broadcasterID: stream.broadcasterID, userID: session.userID)
        }
        .onChange(of: televisions.map(\.id), initial: true) { _, ids in
            if selectedTV == nil || !ids.contains(selectedTV!) { selectedTV = ids.first }
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                now = .now
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                if !isFixture { await model.sync.sync() }; now = .now
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            }
        }
        .sheet(isPresented: $showingAuthorization) {
            NavigationStack {
                Form {
                    Text(model.auth.status)
                    if let code = model.auth.deviceCode {
                        Text("Confirm access in your browser to enable Twitch chat.")
                        Text(code.userCode).font(.title.monospaced().bold())
                        if let url = URL(string: code.verificationUri), url.scheme == "https", ["twitch.tv", "www.twitch.tv"].contains(url.host ?? "") {
                            Link("Continue on Twitch", destination: url)
                        }
                        Button("Cancel sign-in") { model.auth.cancelLogin() }
                    }
                    if let error = model.auth.error { Text(error).foregroundStyle(.secondary) }
                    if !model.auth.isSigningIn, model.auth.session?.scopes.contains("user:read:chat") != true {
                        Button("Connect chat") { Task { await model.login(chat: true, presentSettings: false) } }
                    }
                }
                .navigationTitle("Connect chat")
                .toolbar { ToolbarItem { Button("Done") { showingAuthorization = false } } }
                #if os(macOS)
                .frame(minWidth: 420, minHeight: 300)
                #endif
            }
        }
        .onChange(of: model.auth.status) { _, status in
            if status == "Connected", model.auth.session?.scopes.contains("user:read:chat") == true { showingAuthorization = false }
        }
        .onDisappear { chat.disconnect() }
    }
}
#endif
