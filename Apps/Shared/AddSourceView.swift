import SwiftUI
import TwitchyCore
import TwitchySources

struct AddSourceView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selected: PlaybackSourceKind?
    var body: some View {
        #if os(tvOS)
        TVPage(title: "Add Source", backButton: true) {
            Text("Choose a provider. Sources are tried in your chosen order and sync through iCloud.").foregroundStyle(.secondary)
            ForEach(PlaybackSourceKind.allCases, id: \.self) { kind in
                if kind == .twitchyServer { NavigationLink(kind.title) { TVSourceEditor(source: nil) } }
                else { NavigationLink(kind.title) { PlaybackSourceEditor(kind: kind) } }
            }
        }
        #else
        if let selected {
            if selected == .twitchyServer { SourceEditor(source: nil) }
            else { PlaybackSourceEditor(kind: selected) }
        } else {
            NavigationStack {
                List {
                    ForEach(PlaybackSourceKind.allCases, id: \.self) { kind in
                        Button { selected = kind } label: {
                            HStack(spacing: 14) {
                                Image(systemName: kind.symbol).frame(width: 24)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(kind.title).font(.headline)
                                    Text(detail(kind)).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(); Image(systemName: "chevron.right").foregroundStyle(.secondary)
                            }.padding(.vertical, 12)
                        }.buttonStyle(.plain).accessibilityIdentifier("sources.add." + kind.rawValue)
                    }
                }
                .navigationTitle("Add Source")
                .toolbar { ToolbarItem { Button("Cancel") { dismiss() } } }
            }
            #if os(macOS)
            .frame(width: 600, height: 380)
            #endif
        }
        #endif
    }
    private func detail(_ kind: PlaybackSourceKind) -> String {
        switch kind {
        case .removedEmbed: ""
        case .twitchProxy: "Your own permitted HLS proxy. Enter its address and URL contract. No downloads."
        case .twitchyServer: "Connect a Twitchy Server with its own optional access token and download capabilities."
        }
    }
}

struct PlaybackSourceEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let kind: PlaybackSourceKind
    let source: StreamingSource?
    @State private var name: String
    @State private var address: String
    @State private var contract: ProxyContract
    @State private var trustedLocal: Bool
    @State private var enabled: Bool
    @State private var channel = ""
    @State private var message: String?
    @State private var checking = false
    @State private var testTask: Task<Void, Never>?
    @State private var revision = UUID()
    init(kind: PlaybackSourceKind, source: StreamingSource? = nil) {
        self.kind = kind; self.source = source
        _name = State(initialValue: source?.name ?? kind.title)
        _address = State(initialValue: source?.proxyConfiguration?.address ?? "")
        _contract = State(initialValue: source?.proxyConfiguration?.contract ?? .automatic)
        _trustedLocal = State(initialValue: source?.allowLocalHTTP ?? false)
        _enabled = State(initialValue: source?.enabled ?? true)
    }
    var body: some View {
        #if os(tvOS)
        TVPage(title: source == nil ? "Add " + kind.title : "Edit " + kind.title, backButton: true) { controls }
            .onDisappear(perform: cancelTest)
            .onChange(of: address) { _, _ in cancelTest(); message = nil }
            .onChange(of: channel) { _, _ in cancelTest(); message = nil }
            .onChange(of: contract) { _, _ in cancelTest(); message = nil }
        #else
        NavigationStack {
            Form { controls }.formStyle(.grouped)
                .navigationTitle(source == nil ? "Add " + kind.title : "Edit " + kind.title)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        #if os(macOS)
        .frame(width: 650, height: 650)
        #endif
        .onDisappear(perform: cancelTest)
            .onChange(of: address) { _, _ in cancelTest(); message = nil }
            .onChange(of: channel) { _, _ in cancelTest(); message = nil }
            .onChange(of: contract) { _, _ in cancelTest(); message = nil }
        #endif
    }
    @ViewBuilder private var controls: some View {
        Section {
            TextField("Name", text: $name).accessibilityIdentifier("sources.name")
            Toggle("Enabled", isOn: $enabled)
        }
        Section("Proxy configuration") {
            TextField("Proxy address or URL template", text: $address).accessibilityIdentifier("sources.proxy.address")
                #if os(iOS) || os(tvOS)
                .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                #endif
            Picker("URL contract", selection: $contract) {
                Text("Automatic · base URL or {channel} template").tag(ProxyContract.automatic)
                Text("Luminous / TTV LOL v1-compatible playlist").tag(ProxyContract.luminous)
                Text("Direct HLS template").tag(ProxyContract.directHLS)
            }
            Text("Enter a base URL for a Luminous-compatible service, or the provider’s documented playlist URL containing {channel}. HTTP/SOCKS forward proxies are not supported.").font(.caption).foregroundStyle(.secondary)
            Toggle("Trust local network for development", isOn: $trustedLocal)
            TextField("Currently live channel to test", text: $channel).accessibilityIdentifier("sources.proxy.channel")
                #if os(iOS) || os(tvOS)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                #endif
        }
        Section {
            Button(checking ? "Checking…" : "Test Connection") { test() }.disabled(checking || channel.isEmpty).accessibilityIdentifier("sources.proxy.test")
            if let message { Text(message).font(.callout).foregroundStyle(.secondary).accessibilityIdentifier("sources.editor.status") }
            Button("Save Source") { save() }.buttonStyle(.borderedProminent).accessibilityIdentifier("sources.save")
        }
        Section {
            Text("Twitchy does not operate, bundle or endorse ad-blocking proxies. You choose and configure the service yourself and must have permission to use it. Its operator may see your IP address and requested channels. Availability, legality and ad behavior depend on the service and your use; no ad-free playback is promised.").font(.caption).foregroundStyle(.secondary)
            Text("Source type, configuration, enablement and fallback order sync through your private iCloud account. Playback tests remain device-local.").font(.caption).foregroundStyle(.secondary)
        }
    }
    private func configuration() -> StreamingProxyConfiguration {
        var configuration = StreamingProxyConfiguration()
        configuration.name = name; configuration.address = address; configuration.contract = contract
        configuration.allowLocalHTTP = trustedLocal; configuration.enabled = enabled; configuration.useCustom = true
        return configuration
    }
    private func value() throws -> StreamingSource {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw ClientError.message("Give the source a name.") }
        var value = try StreamingSource.proxy(name: title, configuration: configuration(), id: source?.id ?? UUID())
        value.enabled = enabled
        return value
    }
    private func save() { do { cancelTest(); try model.sources.upsert(value()); dismiss() } catch { message = error.localizedDescription } }
    private func cancelTest() { revision = UUID(); testTask?.cancel(); testTask = nil; checking = false }
    private func test() {
        cancelTest(); checking = true; message = "Checking…"
        let current = revision
        do {
            let value = try value(), login = channel
            testTask = Task {
                do {
                    guard let configuration = value.proxyConfiguration else { throw ProxyError.invalidConfiguration }
                    _ = try await ProxyPlaybackProvider().resolve(configuration: configuration, request: .init(channelLogin: login))
                    guard !Task.isCancelled, revision == current else { return }
                    message = "HLS master/media manifest reachable. Segments, native playback and ad behavior are not verified by this check."
                    checking = false
                } catch { guard !Task.isCancelled, revision == current else { return }; checking = false; message = error.localizedDescription }
            }
        } catch { checking = false; message = error.localizedDescription }
    }
}
