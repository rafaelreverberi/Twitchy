import SwiftUI
import TwitchyCore
import TwitchySources
import TwitchyDesignSystem

struct ProfileView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 20) { RemoteImage(model.user.flatMap { URL(string: $0.profileImageUrl) }, symbol: "person.crop.circle").frame(width: 90, height: 90).clipShape(Circle()); VStack(alignment: .leading) { Text(model.user?.displayName ?? "Your Twitch account").font(.title.bold()); Text(model.user.map { "@\($0.login)" } ?? "Connect your Twitch account").foregroundStyle(.secondary); Text(model.auth.status).font(.caption).foregroundStyle(TwitchyTheme.live) } }
                if let error = model.auth.error { Notice(error) }
                if model.auth.status != "Connected" { Button("Sign in with Twitch") { Task { await model.login() } }.buttonStyle(.borderedProminent).disabled(model.auth.isSigningIn) }
                else { Button("Sign out") { Task { model.chat.disconnect(); await model.auth.logout(); await model.playback.stop(); await model.refresh() } } }
                Button { model.showingSettings = true } label: { Label("Settings", systemImage: "gearshape").font(.headline) }.accessibilityIdentifier("profile.settings")
                Divider()
                Text("Watch history").font(.title2.bold())
                ForEach(model.personal.data.history) { entry in Button { model.open(login: entry.login, name: entry.title) } label: { HStack { Text(entry.title); Spacer(); Text(entry.watchedAt, style: .date).font(.caption).foregroundStyle(.secondary) } } }
                if !model.personal.data.history.isEmpty { Button("Clear watch history", role: .destructive) { model.personal.clearHistory() } }
                if let error = model.personal.error { Notice(error) }
                Divider(); Text("Twitchy · 0.1.0").font(.headline); Text("Your streams. Your way.").foregroundStyle(.secondary); Text("An independent third-party client by Rafael Reverberi. Not affiliated with Twitch.").font(.caption).foregroundStyle(.secondary)
            }.padding(28)
        }
    }
}
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
                    Text(model.auth.status).foregroundStyle(.secondary)
                    if model.auth.deviceCode == nil {
                        if model.auth.status != "Connected" {
                            Button("Sign in with Twitch") { Task { await model.login() } }.disabled(model.auth.isSigningIn).accessibilityIdentifier("oauth.signIn")
                        }
                        if model.auth.status == "Connected", model.auth.session?.scopes.contains("user:read:chat") == false {
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
                    if let error = model.auth.error { Notice(error) }
                }
                Section("Advanced") {
                    #if os(tvOS)
                    NavigationLink("Twitch application settings") {
                        Form {
                            TextField("Public Client ID", text: $model.deviceClientID).accessibilityIdentifier("oauth.clientID")
                            Text("Requires Client Type: Public in the Twitch Developer Console.")
                        }.navigationTitle("Twitch application")
                    }
                    #else
                    DisclosureGroup("Twitch application settings") {
                        TextField("Public Client ID", text: $model.deviceClientID).accessibilityIdentifier("oauth.clientID")
                        Text("Requires Client Type: Public in the Twitch Developer Console. No client secret is needed.").font(.caption).foregroundStyle(.secondary)
                        #if !os(tvOS)
                        TextField("Legacy browser Client ID", text: $model.clientID)
                        TextField("Registered redirect URI", text: $model.redirect)
                        Button("Use legacy browser sign-in") { Task { await model.auth.loginWithBrowser(configuration: model.configuration) } }
                        Text("Legacy browser sign-in cannot renew automatically. Use only with a Confidential app registration.").font(.caption).foregroundStyle(.secondary)
                        #endif
                    }.accessibilityIdentifier("oauth.advanced")
                    #endif
                }
                Section("iCloud Sync") {
                    Label(model.sync.cloud.status, systemImage: "icloud")
                    if let date = model.sync.cloud.lastSyncedAt { Text("Last synced \(date.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary) }
                    Button("Sync now") { Task { await model.sync.sync() } }.disabled(model.sync.cloud.isSyncing)
                    Text("Sources and their access tokens, preferences, searches and watch history sync through your iCloud account. Sign in to Twitch separately on each device. Downloaded files stay on this device.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Sources") { NavigationLink { SourcesView() } label: { Label("Streaming sources", systemImage: "server.rack") }; Text(model.sources.active?.name ?? "No streaming source selected").foregroundStyle(.secondary) }
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
struct SourcesView: View {
    @Environment(AppModel.self) private var model
    @State private var editing: StreamingSource?
    @State private var adding = false
    @State private var error: String?
    var body: some View {
        List {
            Section { Text("Video playback uses the active source. Twitch sign-in and chat remain independent.").foregroundStyle(.secondary) }
            if let error { Notice(error) }
            if let error = model.sources.error { Notice(error) }
            ForEach(model.sources.sources) { source in
                Section {
                    HStack { VStack(alignment: .leading) { Text(source.name).font(.headline); Text(source.baseURL.absoluteString).font(.caption).foregroundStyle(.secondary) }; Spacer(); if source.id == model.sources.activeID { Label("Active", systemImage: "checkmark.circle.fill").foregroundStyle(TwitchyTheme.live) } }
                    Text(source.connectionStatus).font(.caption)
                    if let version = source.serverVersion { Text("Server \(version) · API \(source.capabilities?.apiVersion ?? "unknown")") }
                    if let caps = source.capabilities { Text("Protocols: \(caps.playbackProtocols.joined(separator: ", "))"); Text("Live: \(caps.live ? "Yes" : "No") · VOD: \(caps.vod ? "Yes" : "No") · Downloads: \(caps.downloads ? "Yes" : "No")"); if let ad = caps.adHandling { Text("Server filtering: \(ad)") } }
                    if let date = source.lastSuccessfulCheck { Text("Last successful check: \(date.formatted())").font(.caption) }
                    HStack { Button("Test") { Task { await model.sources.test(source.id) } }; Button("Edit") { editing = source }; Button("Select") { perform { try model.sources.select(source.id) } }.disabled(!source.enabled); Button(source.enabled ? "Disable" : "Enable") { var copy = source; copy.enabled.toggle(); perform { try model.sources.upsert(copy) } } }
                    Button("Remove source", role: .destructive) { perform { try model.sources.remove(source.id) } }
                }
            }
            Section { Button { adding = true } label: { Label("Add streaming source", systemImage: "plus") }.accessibilityIdentifier("sources.add") }
        }
        #if os(macOS)
        .buttonStyle(.borderless)
        #endif
        .navigationTitle("Sources").sheet(isPresented: $adding) { SourceEditor(source: nil) }.sheet(item: $editing) { SourceEditor(source: $0) }
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
    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name).accessibilityIdentifier("sources.name")
                TextField("HTTPS base URL", text: $url).accessibilityIdentifier("sources.url")
                Toggle("Allow local HTTP for development", isOn: $localHTTP)
                Toggle("Source requires bearer authentication", isOn: $authenticate)
                if authenticate { SecureField(source == nil ? "Source token" : "New token (blank keeps existing)", text: $token) }
                Text("Use a source token issued by your server. Never enter a Twitch token. Local HTTP is restricted to loopback and private network addresses.").font(.caption).foregroundStyle(.secondary)
                if let error { Notice(error) }
                Button("Save source") {
                    do {
                        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { throw ClientError.message("Give your source a name.") }
                        let validated = try SourceURL.validate(url, allowLocalHTTP: localHTTP)
                        var value = source ?? StreamingSource(name: name, baseURL: validated)
                        value.name = name; value.baseURL = validated; value.allowLocalHTTP = localHTTP; value.usesAuthentication = authenticate
                        if value.baseURL != source?.baseURL { value.capabilities = nil; value.serverVersion = nil; value.lastSuccessfulCheck = nil; value.connectionStatus = "Not tested" }
                        let credential: String? = !authenticate ? "" : (!token.isEmpty ? token : nil)
                        try model.sources.upsert(value, credential: credential); dismiss()
                    } catch { self.error = error.localizedDescription }
                }.disabled(name.isEmpty || url.isEmpty).accessibilityIdentifier("sources.save")
            }
            #if !os(tvOS)
            .formStyle(.grouped)
            #endif
            .navigationTitle(source == nil ? "Add source" : "Edit source").toolbar { ToolbarItem { Button("Cancel") { dismiss() } } }
        }.onAppear { if let source { name = source.name; url = source.baseURL.absoluteString; localHTTP = source.allowLocalHTTP; authenticate = source.usesAuthentication } }
        #if os(macOS)
        .frame(width: 600, height: 440)
        #endif
    }
}

#Preview { SettingsView().environment(AppModel()) }
