import SwiftUI
import TwitchyCore
import TwitchySources
import TwitchyDesignSystem

struct ProfileView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 20) { DiscoveryImage(model.user.flatMap { URL(string: $0.profileImageUrl) }, symbol: "person.crop.circle").frame(width: 90, height: 90).clipShape(Circle()); VStack(alignment: .leading) { Text(model.user?.displayName ?? model.auth.session?.login ?? "Your Twitch account").font(.title.bold()); Text(model.user.map { "@\($0.login)" } ?? model.auth.session.map { "@\($0.login)" } ?? "Connect your Twitch account").foregroundStyle(.secondary); Text(model.accountStatus).font(.caption).foregroundStyle(TwitchyTheme.live) } }
                if let error = model.auth.error, !model.isOffline { Notice(error) }
                if !model.accountSignedIn { Button("Sign in with Twitch") { Task { await model.login() } }.buttonStyle(.borderedProminent).disabled(model.auth.isSigningIn) }
                else { Button("Sign out") { Task { model.chat.disconnect(); await model.auth.logout(); await model.playback.stop(); await model.refresh() } } }
                Button { model.showingSettings = true } label: { Label("Settings", systemImage: "gearshape").font(.headline) }.accessibilityIdentifier("profile.settings")
                Divider()
                #if os(tvOS)
                Text("Watch history").font(.title2.bold())
                ForEach(model.personal.data.history) { entry in Button { model.open(login: entry.login, name: entry.title) } label: { HStack { Text(entry.title); Spacer(); Text(entry.watchedAt, style: .date).font(.caption).foregroundStyle(.secondary) } } }
                #else
                WatchHistoryRow()
                #endif
                if !model.personal.data.history.isEmpty { Button("Clear watch history", role: .destructive) { model.personal.clearHistory() } }
                if let error = model.personal.error { Notice(error) }
                Divider(); Text("Twitchy · 0.1.0").font(.headline); Text("Your streams. Your way.").foregroundStyle(.secondary); Text("An independent third-party client by Rafael Reverberi. Not affiliated with Twitch.").font(.caption).foregroundStyle(.secondary)
            }.padding(28)
        }
    }
}
#if !os(tvOS)
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        @Bindable var model = model
        @Bindable var personal = model.personal
        NavigationStack {
            Form {
                Section("Twitch account") {
                    Text(model.auth.session.map { "Signed in as @\($0.login)" } ?? "Connect your Twitch account").font(.headline)
                    Text(model.accountStatus).foregroundStyle(.secondary)
                    if model.auth.deviceCode == nil {
                        if !model.accountSignedIn {
                            Button("Sign in with Twitch") { Task { await model.login() } }.disabled(model.auth.isSigningIn).accessibilityIdentifier("oauth.signIn")
                        }
                        if !model.isOffline, model.auth.status == "Connected", model.auth.session?.scopes.contains("user:read:chat") == false {
                            Button("Enable Twitch chat") { Task { await model.login(chat: true) } }
                        }
                    }
                    if let code = model.auth.deviceCode {
                        Text("Confirm access in your browser. Twitchy will finish signing in automatically.")
                        if let url = URL(string: code.verificationUri), url.scheme == "https", url.host == "www.twitch.tv" || url.host == "twitch.tv" { Link("Continue on Twitch", destination: url) }
                        Text("If asked, enter this code:").font(.caption)
                        Text(code.userCode).font(.title.monospaced().bold())
                        ProgressView("Waiting for Twitch")
                        Button("Cancel sign-in") { model.auth.cancelLogin() }
                    }
                    Text("Your sign-in is stored securely on this device and renewed automatically.").font(.caption).foregroundStyle(.secondary)
                    if model.auth.session != nil { Button("Sign out", role: .destructive) { Task { model.chat.disconnect(); await model.auth.logout(); await model.refresh() } } }
                    if let error = model.auth.error, !model.isOffline { Notice(error) }
                }
                Section("Sources") { NavigationLink { SourcesView() } label: { Label("Streaming sources", systemImage: "server.rack") }; Text(model.sources.active?.name ?? "No streaming source selected").foregroundStyle(.secondary) }
                Section("iCloud Sync") {
                    Label(model.sync.cloud.status, systemImage: "icloud")
                    if let date = model.sync.cloud.lastSyncedAt { Text("Last synced \(date.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary) }
                    Button("Sync now") { Task { await model.sync.sync() } }.disabled(model.sync.cloud.isSyncing)
                    Text("Sources and their access tokens, preferences, searches and watch history sync through your iCloud account. Sign in to Twitch separately on each device. Downloaded files stay on this device.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Playback") {
                    Picker("Preferred quality", selection: $personal.data.preferences.preferredQuality) {
                        Text("Best").tag("auto")
                        ForEach(model.playback.session?.qualities.filter { $0 != "auto" } ?? [], id: \.self) { Text($0).tag($0) }
                    }
                    Text("Best lets your source select the highest available quality. Additional qualities appear after a stream starts.").font(.caption).foregroundStyle(.secondary)
                    Toggle("Autoplay when opening a channel", isOn: $personal.data.preferences.autoplay)
                    Toggle("Picture in Picture", isOn: $personal.data.preferences.pictureInPicture)
                    Toggle("Retry playback after an interruption", isOn: $personal.data.preferences.retryPlayback)
                }
                Section("Chat") {
                    Toggle("Show chat", isOn: $personal.data.preferences.showChat)
                    #if os(tvOS)
                    Picker("Chat font size", selection: $personal.data.preferences.chatFontSize) { ForEach([14.0, 18.0, 22.0, 26.0], id: \.self) { Text(String(Int($0))).tag($0) } }
                    #else
                    Stepper("Font size: \(Int(personal.data.preferences.chatFontSize))", value: $personal.data.preferences.chatFontSize, in: 12...28)
                    #endif
                    Toggle("Show timestamps", isOn: $personal.data.preferences.timestamps)
                    Toggle("Show emotes", isOn: $personal.data.preferences.emotes)
                    Toggle("Automatically scroll to latest", isOn: $personal.data.preferences.autoscroll)
                }
                Section("Downloads") { Text("Stored: \(ByteCountFormatter.string(fromByteCount: model.downloads.storageBytes, countStyle: .file))"); Text("Authorized media only. Transfers stay local. Apple TV does not store offline downloads.").font(.caption).foregroundStyle(.secondary) }
                Section("Appearance") { Toggle("Dark theme", isOn: $personal.data.preferences.darkTheme); Toggle("Reduce animations", isOn: $personal.data.preferences.reduceMotion) }
                Section {
                    NavigationLink { AdvancedSettingsView() } label: { Label("Advanced", systemImage: "gearshape.2") }
                        .accessibilityIdentifier("settings.advanced")
                }
                Section("About") {
                    Text("Twitchy 0.1.0 (1) · Rafael Reverberi")
                    NavigationLink("Privacy") { LegalView(title: "Privacy", text: "Twitch authentication and metadata go directly to Twitch. Your configured streaming source receives playback and authorized download requests, plus its own credentials. Twitch credentials are never sent to it. Twitch sign-in stays in device-only Keychain entries. With a provisioned iCloud build, sources including their access tokens, preferences, public app settings, recent searches and watch history sync through encrypted private CloudKit records. The offline sync journal is encrypted; imported source tokens enter the source Keychain. Downloads stay local. Viewing time is used locally to rank live channels. No analytics is collected. Chat history is held only in bounded memory.") }
                    NavigationLink("License & acknowledgments") { LegalView(title: "License", text: "Original Twitchy code is licensed under the MIT License. Copyright © 2026 Rafael Reverberi. Permission is granted to use, copy, modify, merge, publish, distribute, sublicense and sell copies subject to preserving the copyright and license notice. Software is provided AS IS without warranty. Uses Apple system frameworks; no third-party runtime packages. Twitchy is not affiliated with or endorsed by Twitch.") }
                    Link("Twitch Developer documentation", destination: URL(string: "https://dev.twitch.tv/docs/")!)
                }
            }
            #if !os(tvOS)
            .formStyle(.grouped)
            #endif
            .navigationTitle("Settings").toolbar { ToolbarItem { Button("Done") { dismiss() } } }
        }
        #if os(macOS)
        .frame(width: 720, height: 780)
        #endif
    }
}
struct LegalView: View { var title: String; var text: String; var body: some View { ScrollView { Text(text).padding(28).frame(maxWidth: 700, alignment: .leading) }.navigationTitle(title) } }
struct AdvancedSettingsView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        @Bindable var model = model
        Form {
            Section("Twitch application settings") {
                TextField("Public Client ID", text: $model.deviceClientID).accessibilityIdentifier("oauth.clientID")
                Text("Requires Client Type: Public in the Twitch Developer Console. No client secret is needed.").font(.caption).foregroundStyle(.secondary)
                DisclosureGroup("Legacy browser sign-in") {
                    TextField("Legacy browser Client ID", text: $model.clientID)
                    TextField("Registered redirect URI", text: $model.redirect)
                    Button("Use legacy browser sign-in") { Task { await model.auth.loginWithBrowser(configuration: model.configuration) } }
                    Text("Legacy browser sign-in cannot renew automatically. Use only with a Confidential app registration.").font(.caption).foregroundStyle(.secondary)
                }
            }.accessibilityIdentifier("oauth.advanced")
        }
        #if !os(tvOS)
        .formStyle(.grouped)
        #endif
        .navigationTitle("Advanced")
    }
}
struct SourcesView: View {
    @Environment(AppModel.self) private var model
    @State private var editing: StreamingSource?
    @State private var adding = false
    @State private var removing: StreamingSource?
    @State private var testing: Set<UUID> = []
    @State private var error: String?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Label(model.sources.active.map { "Using \($0.name)" } ?? "Add your first server", systemImage: "server.rack")
                        .font(.title2.bold()).accessibilityIdentifier("sources.current")
                    Text("Choose your main server. If it becomes unavailable, Twitchy automatically uses another enabled server.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                if let error { Notice(error) }
                if model.sources.sources.isEmpty {
                    Button { adding = true } label: { Label("Add server", systemImage: "plus").frame(maxWidth: .infinity, minHeight: 44) }
                        .buttonStyle(.borderedProminent).accessibilityIdentifier("sources.add")
                }
                ForEach(model.sources.sources) { source in
                    VStack(alignment: .leading, spacing: 16) {
                        Button { perform { try model.sources.select(source.id) } } label: {
                            HStack(spacing: 14) {
                                Image(systemName: source.id == model.sources.activeID ? "checkmark.circle.fill" : "circle")
                                    .font(.title2).foregroundStyle(source.id == model.sources.activeID ? TwitchyTheme.accent : Color.secondary)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(source.name).font(.headline).foregroundStyle(.primary)
                                    Text(source.baseURL.host ?? source.baseURL.absoluteString).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer(minLength: 8)
                                if source.id == model.sources.activeID { Text("Primary").font(.caption.bold()).foregroundStyle(TwitchyTheme.accent) }
                            }.frame(maxWidth: .infinity, minHeight: 52).contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled(!source.enabled).accessibilityIdentifier("sources.select.\(source.name)")
                        HStack(spacing: 8) {
                            Image(systemName: source.enabled ? (model.sources.availability[source.id] == false ? "wifi.slash" : "network") : "pause.circle")
                            Text(!source.enabled ? "Disabled" : model.sources.isChecking ? "Checking…" : model.sources.availability[source.id].map { $0 ? "Available" : "Unavailable" } ?? "Not checked yet")
                            if source.id == model.sources.fallbackID { Text("· In use").foregroundStyle(TwitchyTheme.accent) }
                            Spacer()
                        }.font(.caption).foregroundStyle(.secondary)
                        HStack(spacing: 12) {
                            Button { editing = source } label: { Label("Edit", systemImage: "pencil").frame(maxWidth: .infinity, minHeight: 36) }
                                .accessibilityIdentifier("sources.edit.\(source.name)")
                            Button {
                                testing.insert(source.id)
                                Task { await model.sources.test(source.id); testing.remove(source.id) }
                            } label: { Label(testing.contains(source.id) ? "Checking…" : "Check", systemImage: "arrow.clockwise").frame(maxWidth: .infinity, minHeight: 36) }
                                .disabled(!source.enabled || testing.contains(source.id)).accessibilityIdentifier("sources.check.\(source.name)")
                        }.buttonStyle(.bordered)
                        DisclosureGroup("Details") {
                            VStack(alignment: .leading, spacing: 12) {
                                Text(source.baseURL.absoluteString).font(.caption).textSelection(.enabled)
                                if let version = source.serverVersion { Text("Server \(version)").font(.caption) }
                                if let caps = source.capabilities {
                                    Text([caps.live ? "Live" : nil, caps.vod ? "Videos" : nil, caps.clips ? "Clips" : nil, caps.downloads ? "Downloads" : nil].compactMap { $0 }.joined(separator: " · ")).font(.caption)
                                }
                                Text(source.connectionStatus).font(.caption).foregroundStyle(.secondary)
                                Toggle("Enabled", isOn: Binding(get: { source.enabled }, set: { enabled in
                                    var copy = source; copy.enabled = enabled; perform { try model.sources.upsert(copy) }
                                }))
                                Button("Remove server", role: .destructive) { removing = source }.buttonStyle(.borderless)
                                    .frame(minHeight: 44)
                            }.padding(.top, 12)
                        }.font(.subheadline).foregroundStyle(.secondary)
                    }.padding(20).background(TwitchyTheme.secondary, in: RoundedRectangle(cornerRadius: 20))
                }
            }.padding(20).frame(maxWidth: 720).frame(maxWidth: .infinity)
        }
        .background(TwitchyTheme.background)
        .navigationTitle("Sources")
        .toolbar {
            if !model.sources.sources.isEmpty {
                ToolbarItem { Button { adding = true } label: { Label("Add server", systemImage: "plus") }.accessibilityIdentifier("sources.add") }
            }
        }
        .animation(model.personal.data.preferences.reduceMotion ? nil : .easeInOut(duration: 0.2), value: model.sources.activeID)
        .animation(model.personal.data.preferences.reduceMotion ? nil : .easeInOut(duration: 0.2), value: model.sources.isChecking)
        .task { await model.sources.refreshAvailability() }
        .sheet(isPresented: $adding) { SourceEditor(source: nil) }.sheet(item: $editing) { SourceEditor(source: $0) }
        .confirmationDialog("Remove \(removing?.name ?? "server")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
            Button("Remove server", role: .destructive) { if let removing { perform { try model.sources.remove(removing.id) }; self.removing = nil } }
        }
    }
    private func perform(_ action: () throws -> Void) { do { try action(); error = nil } catch { self.error = error.localizedDescription } }
}
struct SourceEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let source: StreamingSource?
    @State private var name = ""
    @State private var url = ""
    @State private var localHTTP = false
    @State private var authenticate = false
    @State private var token = ""
    @State private var error: String?
    init(source: StreamingSource?) {
        self.source = source
        _name = State(initialValue: source?.name ?? "")
        _url = State(initialValue: source?.baseURL.absoluteString ?? "")
        _localHTTP = State(initialValue: source?.allowLocalHTTP ?? false)
        _authenticate = State(initialValue: source?.usesAuthentication ?? false)
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    TextField("Name", text: $name).accessibilityIdentifier("sources.name").autocorrectionDisabled()
                    TextField("https://your-server.com", text: $url).accessibilityIdentifier("sources.url")
                        #if os(iOS)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        #endif
                }
                Section("Access") {
                    Toggle("Access token required", isOn: $authenticate)
                    if authenticate {
                        SecureField(source == nil ? "Server access token" : "New token (blank keeps existing)", text: $token)
                        Text("Use the token from your server.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section {
                    DisclosureGroup("Advanced") {
                        Toggle("Allow HTTP on your local network", isOn: $localHTTP)
                        Text("Only for local development servers. Never enter Twitch credentials here.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let error { Notice(error) }
            }
            #if !os(tvOS)
            .formStyle(.grouped)
            #endif
            .navigationTitle(source == nil ? "Add server" : "Edit server")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || url.isEmpty)
                        .accessibilityIdentifier("sources.save")
                }
            }
        }
        #if os(macOS)
        .frame(width: 600, height: 520)
        #endif
    }
    private func save() {
        do {
            let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedName.isEmpty else { throw ClientError.message("Give your server a name.") }
            let validated = try SourceURL.validate(url, allowLocalHTTP: localHTTP)
            var value = source ?? StreamingSource(name: trimmedName, baseURL: validated)
            value.name = trimmedName; value.baseURL = validated; value.allowLocalHTTP = localHTTP; value.usesAuthentication = authenticate
            if value.baseURL != source?.baseURL { value.capabilities = nil; value.serverVersion = nil; value.lastSuccessfulCheck = nil; value.connectionStatus = "Not tested" }
            let credential: String? = !authenticate ? "" : (!token.isEmpty ? token : nil)
            if authenticate, source?.usesAuthentication != true, token.isEmpty { throw ClientError.message("Enter the access token from your server.") }
            try model.sources.upsert(value, credential: credential)
            Task { await model.sources.refreshAvailability(force: true) }
            dismiss()
        } catch { self.error = error.localizedDescription }
    }

}

#Preview { SettingsView().environment(AppModel()) }

#endif
