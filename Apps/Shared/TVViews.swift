#if os(tvOS)
import SwiftUI
import AVKit
import CoreImage.CIFilterBuiltins
import TwitchyAPI
import TwitchyAuth
import TwitchyCore
import TwitchySources
import TwitchyDesignSystem

// A television workspace: full-screen routes, large media, native remote focus.
struct TVRootView: View {
    @Environment(AppModel.self) private var model
    @State private var signIn = false
    @State private var tab = "Home"
    @State private var completingSignIn = false
    @Environment(\.scenePhase) private var scenePhase
    @State private var companionDeviceID: String = {
        let key = "companion.tv.deviceID"
        if let id = UserDefaults.standard.string(forKey: key) { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: key)
        return id
    }()
    @AppStorage("tv.onboardingSkipped") private var skippedOnboarding = false
    var body: some View {
        @Bindable var model = model
        Group {
            if (TVFixtures.screen?.hasPrefix("onboarding") == true) || (model.startupComplete && !model.isOffline && model.auth.session == nil && (!skippedOnboarding || signIn) && !TVFixtures.enabled) {
                TVSignInView { signIn = false; skippedOnboarding = model.auth.session == nil }
            } else if let selection = model.selectedChannel {
                NavigationStack { TVChannelView(selection: selection) }.id(selection.id)
            } else {
                TabView(selection: $tab) {
                    NavigationStack { Group { if model.isOffline { OfflineDiscoveryView() } else { TVHomeView() } } }.tag("Home").tabItem { Label("Home", systemImage: "house") }
                    NavigationStack { Group { if model.isOffline { OfflineDiscoveryView() } else { TVChannelsView() } } }.tag("Channels").tabItem { Label("Channels", systemImage: "person.2") }
                    NavigationStack { Group { if model.isOffline { OfflineDiscoveryView() } else { TVSearchView() } } }.tag("Search").tabItem { Label("Search", systemImage: "magnifyingglass") }
                    NavigationStack { TVSettingsView { signIn = true } }.tag("Settings").tabItem { Label("Settings", systemImage: "gearshape") }
                }

            }
        }
        .onAppear { if let screen = TVFixtures.screen, ["Home", "Channels", "Search", "Settings"].contains(screen) { tab = screen } }
        .onChange(of: model.auth.status) { _, status in
            if status == "Signing in" || status == "Waiting for authorization" { completingSignIn = true }
            if status == "Connected" && completingSignIn {
                completingSignIn = false; signIn = false; skippedOnboarding = false
                model.personal.data.onboardingComplete = true
            }
        }
        .onChange(of: model.selectedChannel?.id) { _, id in
            if id == nil && !model.playback.pictureInPictureActive { model.sampleViewing(); model.chat.disconnect(); model.playback.player.pause(); Task { await model.playback.stop() } }
        }
        .task(id: "\(model.startupComplete)|\(model.tvCompanionBroadcasterID ?? "")|\(scenePhase)|\(model.playback.state)|\(model.playback.session?.sessionId ?? "")|\(model.selectedChannel?.id.uuidString ?? "")") {
            guard model.startupComplete, !TVFixtures.enabled else { return }
            while !Task.isCancelled {
                await publishCompanion()
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
            }
        }
        .preferredColorScheme(.dark)
        .fullScreenCover(isPresented: $model.showingSettings) {
            NavigationStack { TVSettingsView { model.showingSettings = false; signIn = true }
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { model.showingSettings = false } } }
            }
        }
    }
    private func publishCompanion() async {
        let key = TVLivePresence.keyPrefix + companionDeviceID
        var presence: TVLivePresence?
        if scenePhase == .active, let selection = model.selectedChannel,
           let request = model.playback.currentRequest, request.contentType == "live",
           request.channelLogin == selection.login, model.playback.session != nil,
           [.playing, .buffering, .adBreak, .reconnecting].contains(model.playback.state) {
            // Direct playback can begin before the optional channel profile request finishes.
            let id = selection.broadcasterID ?? model.tvCompanionBroadcasterID
            if let id {
                presence = .init(id: companionDeviceID, deviceName: UIDevice.current.name,
                                 login: selection.login, name: selection.name, broadcasterID: id)
            }
        }
        let payload = presence.flatMap { try? JSONEncoder().encode($0) }
        model.sync.cloud.put(key, payload: payload, refresh: presence != nil)
        await model.sync.sync()
    }

}

struct TVSignInView: View {
    @Environment(AppModel.self) private var model
    var completed: () -> Void
    var body: some View {
        HStack(spacing: 100) {
            VStack(alignment: .leading, spacing: 28) {
                Label("Twitchy", systemImage: "play.square.stack.fill").font(.system(size: 46, weight: .bold)).foregroundStyle(TwitchyTheme.highlight)
                Text("Your streams.\nOn the big screen.").font(.system(size: 66, weight: .bold)).fixedSize(horizontal: false, vertical: true)
                Text("Scan with your phone. Sign in on Twitch.\nYour channels are ready.").font(.system(size: 28)).foregroundStyle(.secondary)
                if let error = model.auth.error { Text(error).foregroundStyle(.secondary).font(.system(size: 24)) }
                HStack(spacing: 24) {
                    if model.auth.isSigningIn {
                        Button("Cancel") { model.auth.cancelLogin() }
                    } else {
                        Button("Connect Twitch") { Task { await model.login() } }.buttonStyle(.borderedProminent).accessibilityIdentifier("tv.connect")
                    }
                    Button("Browse later") { model.auth.cancelLogin(); model.personal.data.onboardingComplete = true; completed() }.accessibilityIdentifier("onboarding.complete")
                }.padding(.top, 20)
            }.frame(maxWidth: .infinity, alignment: .leading)
            VStack(spacing: 24) {
                if let code = model.auth.deviceCode ?? TVFixtures.deviceCode {
                    TVQRCode(value: code.verificationUri).frame(width: 300, height: 300)
                    Text("Enter this code on Twitch").font(.system(size: 24)).foregroundStyle(.secondary)
                    Text(code.userCode).font(.system(size: 52, weight: .bold, design: .monospaced)).tracking(6).accessibilityIdentifier("tv.deviceCode")
                    Text(URL(string: code.verificationUri).map { ($0.host ?? "twitch.tv").replacingOccurrences(of: "www.", with: "") + $0.path } ?? "twitch.tv/activate").font(.system(size: 23)).foregroundStyle(.secondary)
                    ProgressView("Waiting for Twitch…").font(.system(size: 24))
                } else {
                    Image(systemName: "qrcode.viewfinder").font(.system(size: 170)).foregroundStyle(TwitchyTheme.highlight)
                    Text(model.auth.isSigningIn ? "Connecting to Twitch…" : "Sign in with your phone").font(.system(size: 28))
                }
            }.frame(width: 420)
        }
        .padding(.horizontal, 90).padding(.vertical, 60).frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(TwitchyTheme.background.ignoresSafeArea())
        .task { if !TVFixtures.enabled && !model.auth.isSigningIn { await model.login() } }
        .onChange(of: model.auth.status) { _, status in
            if status == "Connected" {
                model.personal.data.onboardingComplete = true
                completed()
            }
        }
        .onDisappear { if model.auth.isSigningIn { model.auth.cancelLogin() } }
    }
}
struct TVQRCode: View {
    let value: String
    private var image: UIImage? {
        guard let url = URL(string: value), url.scheme == "https", ["twitch.tv", "www.twitch.tv"].contains(url.host ?? "") else { return nil }
        let filter = CIFilter.qrCodeGenerator(); filter.message = Data(value.utf8); filter.correctionLevel = "M"
        guard let output = filter.outputImage, let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
    var body: some View {
        Group { if let image { Image(uiImage: image).resizable().interpolation(.none).scaledToFit() } else { Image(systemName: "qrcode") } }
            .padding(22).background(.white, in: RoundedRectangle(cornerRadius: 20)).accessibilityLabel("Scan to sign in on Twitch")
    }
}

struct TVPage<Content: View>: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    var backButton = false
    @ViewBuilder var content: () -> Content
    @ViewBuilder var body: some View {
        if backButton { page.onExitCommand { dismiss() } } else { page }
    }
    private var page: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 34) {
                if backButton {
                    HStack(spacing: 30) {
                        Button("Back") { dismiss() }
                        Text(title).font(.system(size: 48, weight: .bold)).accessibilityIdentifier("tv.title." + title)
                    }
                } else if !title.isEmpty { Text(title).font(.system(size: 48, weight: .bold)).accessibilityIdentifier("tv.title." + title) }
                content()
            }.padding(.horizontal, 70).padding(.top, 35).padding(.bottom, 70).frame(maxWidth: .infinity, alignment: .leading)
        }.background(TwitchyTheme.background)
    }
}
struct TVStreamCard: View {
    @Environment(AppModel.self) private var model
    let stream: TwitchStream
    var opensChannel = false
    var body: some View {
        Button { model.selectedChannel = .init(login: stream.userLogin, name: stream.userName, broadcasterID: stream.userId, contentType: opensChannel ? nil : "live") } label: {
            VStack(alignment: .leading, spacing: 0) {
                DiscoveryImage(stream.thumbnail).frame(height: 210).overlay(alignment: .bottomLeading) {
                    Text("LIVE · \(stream.viewerCount.formatted())").font(.system(size: 20, weight: .bold)).padding(10).background(.black.opacity(0.8), in: Capsule()).padding(16)
                }.clipShape(RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 8) {
                    Text(stream.userName).font(.system(size: 28, weight: .semibold)).lineLimit(1)
                    Text(stream.gameName).font(.system(size: 23)).foregroundStyle(.secondary).lineLimit(1)
                }.padding(.horizontal, 20).padding(.vertical, 18).frame(maxWidth: .infinity, alignment: .leading)
            }.frame(width: 370, alignment: .leading)
        }.buttonStyle(.card).accessibilityLabel("Watch \(stream.userName), live, \(stream.gameName)")
    }
}
struct TVStreamRow: View {
    let title: String; let streams: [TwitchStream]
    var opensChannel = false
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text(title).font(.system(size: 30, weight: .semibold))
            ScrollView(.horizontal) { HStack(spacing: 34) { ForEach(streams) { TVStreamCard(stream: $0, opensChannel: opensChannel) } }.padding(16) }
                .frame(height: 380).padding(.horizontal, -16)
        }.focusSection()
    }
}
struct TVFeaturedStream: View {
    @Environment(AppModel.self) private var model
    let stream: TwitchStream
    let personalized: Bool
    private var thumbnail: URL? {
        URL(string: stream.thumbnailUrl.replacingOccurrences(of: "{width}", with: "1920").replacingOccurrences(of: "{height}", with: "1080"))
    }
    var body: some View {
        Button {
            model.selectedChannel = .init(login: stream.userLogin, name: stream.userName, broadcasterID: stream.userId, contentType: "live")
        } label: {
            ZStack(alignment: .bottomLeading) {
                DiscoveryImage(thumbnail).frame(height: 600)
                LinearGradient(colors: [.clear, .black.opacity(0.9)], startPoint: .top, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 18) {
                        Text(personalized ? "FOR YOU" : "LIVE NOW").tracking(3)
                        Label("LIVE", systemImage: "circle.fill").foregroundStyle(.red)
                    }.font(.system(size: 22, weight: .bold))
                    Text(stream.userName).font(.system(size: 64, weight: .bold)).lineLimit(1)
                    Text(stream.title).font(.system(size: 30, weight: .medium)).lineLimit(2)
                    HStack(spacing: 28) {
                        Text(stream.gameName).foregroundStyle(.white.opacity(0.8))
                        Label("Watch now", systemImage: "play.fill").fontWeight(.semibold)
                    }.font(.system(size: 25))
                }.foregroundStyle(.white).padding(48)
            }.frame(height: 600).clipShape(RoundedRectangle(cornerRadius: 20))
        }.buttonStyle(.card).accessibilityIdentifier("tv.featured")
            .accessibilityLabel("Watch \(stream.userName), \(personalized ? "for you" : "live"), \(stream.gameName)")
    }
}
struct TVHomeView: View {
    @Environment(AppModel.self) private var model
    private var featured: TwitchStream? { model.recommendedStreams.first ?? model.followedStreams.first ?? model.streams.first }
    var body: some View {
        TVPage(title: "Watch now") {
            if model.libraryLoading { DiscoverySkeleton() }
            else if model.api == nil && !TVFixtures.enabled { TVConnectPrompt() }
            else {
                if let featured { TVFeaturedStream(stream: featured, personalized: !model.recommendedStreams.isEmpty) }
                if !model.recommendedStreams.isEmpty { TVStreamRow(title: "For you", streams: model.recommendedStreams) }
                if !model.followedStreams.isEmpty { TVStreamRow(title: "Following · Live", streams: model.followedStreams) }
                if !model.streams.isEmpty { TVStreamRow(title: "Popular now", streams: model.streams) }
                if !model.categories.isEmpty {
                    Text("Browse games").font(.system(size: 30, weight: .semibold))
                    ScrollView(.horizontal) { HStack(spacing: 34) { ForEach(model.categories) { category in
                        NavigationLink { TVCategoryView(category: category) } label: {
                            VStack(alignment: .leading, spacing: 12) {
                                DiscoveryImage(URL(string: category.boxArtUrl.replacingOccurrences(of: "{width}", with: "285").replacingOccurrences(of: "{height}", with: "380"))).frame(width: 220, height: 294).clipShape(RoundedRectangle(cornerRadius: 14))
                                Text(category.name).font(.system(size: 24, weight: .semibold)).lineLimit(1).padding(.horizontal, 16).padding(.bottom, 20).frame(maxWidth: .infinity, alignment: .leading)
                            }.frame(width: 220)
                        }.buttonStyle(.card)
                    } }.padding(16) }.frame(height: 430).padding(.horizontal, -16).focusSection()
                }
                if let error = model.error { Text(error).foregroundStyle(.secondary) }
                HStack(spacing: 30) {
                    Button("Refresh") { Task { await model.refresh() } }
                    if model.streamsCursor != nil { Button("Load more") { Task { await model.moreStreams() } } }
                }
            }
        }
    }
}
struct TVConnectPrompt: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            Text("Connect your Twitch account").font(.system(size: 36, weight: .semibold))
            Text("Your channels and live streams.").foregroundStyle(.secondary)
            NavigationLink("Sign in with your phone") { TVSignInRoute() }.buttonStyle(.borderedProminent)
        }.padding(.vertical, 70)
    }
}
struct TVSignInRoute: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View { TVSignInView { dismiss() } }
}
struct TVChannelsView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        TVPage(title: "Following") {
            if !model.startupComplete || (model.loading && model.channels.isEmpty) { DiscoverySkeleton(style: .channels) }
            else if model.api == nil && !TVFixtures.enabled { TVConnectPrompt() }
            else {
                if !model.followedStreams.isEmpty { TVStreamRow(title: "Live now", streams: model.followedStreams, opensChannel: true) }
                if model.channels.isEmpty { Text("Follow channels on Twitch to see them here.").foregroundStyle(.secondary) }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 480))], spacing: 32) {
                    ForEach(model.channels) { channel in
                        let live = model.followedStreams.contains { $0.userId == channel.id }
                        Button {
                            model.selectedChannel = .init(login: channel.broadcasterLogin, name: channel.broadcasterName, broadcasterID: channel.id)
                        } label: {
                            HStack(spacing: 18) {
                                DiscoveryImage(model.avatars[channel.id], symbol: "person.crop.circle").frame(width: 76, height: 76).clipShape(Circle())
                                Text(channel.broadcasterName).font(.system(size: 28, weight: .semibold)).lineLimit(1)
                                if live { Label("LIVE", systemImage: "circle.fill").font(.system(size: 20, weight: .bold)).foregroundStyle(.red) }
                                Spacer(minLength: 0)
                            }.padding(20)
                        }.buttonStyle(.card).accessibilityLabel(channel.broadcasterName + (live ? ", live" : ", offline"))
                    }
                }
                if model.channelsCursor != nil { Button("Load more channels") { Task { await model.moreChannels() } } }
            }
        }
    }
}
struct TVCategoryView: View {
    @Environment(AppModel.self) private var model
    let category: TwitchCategory
    @State private var streams: [TwitchStream] = []
    @State private var cursor: String?
    @State private var error: String?
    var body: some View { TVPage(title: category.name, backButton: true) {
        TVStreamRow(title: "Live channels", streams: streams)
        if let error { Text(error).foregroundStyle(.secondary) }
        if cursor != nil { Button("Load more") { Task { await load(more: true) } } }
        if streams.isEmpty && error == nil { Text("No live channels right now.").foregroundStyle(.secondary) }
    }.task { await load(more: false) } }
    private func load(more: Bool) async {
        do { guard let api = model.api else { return }; let page = try await api.streams(gameID: category.id, after: more ? cursor : nil); try Task.checkCancellation(); streams = more ? streams + page.data : page.data; cursor = page.pagination?.cursor }
        catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
}
struct TVSearchView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var channels: [SearchChannel] = []
    @State private var categories: [TwitchCategory] = []
    @State private var error: String?
    @State private var loading = false
    var body: some View {
        TVPage(title: "Search") {
            if !model.startupComplete { DiscoverySkeleton(style: .channels) }
            else if model.api == nil && !TVFixtures.enabled { TVConnectPrompt() }
            else {
                TextField("Search channels or games", text: $query).accessibilityIdentifier("tv.search").onSubmit { model.personal.searched(query) }
                if query.isEmpty {
                    ForEach(model.personal.data.recentSearches, id: \.self) { item in Button(item) { query = item } }
                }
                if loading { DiscoverySkeleton(style: .channels) }
                if let error { Text(error).foregroundStyle(.secondary) }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 380))], spacing: 32) {
                    ForEach(channels) { channel in Button { model.selectedChannel = .init(login: channel.broadcasterLogin, name: channel.displayName, broadcasterID: channel.id, contentType: channel.isLive ? "live" : nil) } label: {
                        HStack(spacing: 20) { DiscoveryImage(URL(string: channel.thumbnailUrl), symbol: "person.crop.circle").frame(width: 90, height: 90).clipShape(Circle()); VStack(alignment: .leading, spacing: 8) { Text(channel.displayName).font(.system(size: 28, weight: .semibold)); Text(channel.isLive ? "LIVE" : "Offline").foregroundStyle(channel.isLive ? TwitchyTheme.live : .secondary).font(.system(size: 22)) }; Spacer() }.padding(20)
                    }.buttonStyle(.card) }
                    ForEach(categories) { category in NavigationLink { TVCategoryView(category: category) } label: { Label(category.name, systemImage: "gamecontroller").font(.system(size: 28)).padding(25) }.buttonStyle(.card) }
                }
                if !query.isEmpty && !loading && channels.isEmpty && categories.isEmpty && error == nil { Text("No results. Try another name.") }
            }
        }.task(id: query) {
            channels = []; categories = []; error = nil
            guard !query.trimmingCharacters(in: .whitespaces).isEmpty, let api = model.api else { loading = false; return }
            loading = true
            let text = query
            do {
                try await Task.sleep(for: .milliseconds(350))
                async let c = api.searchChannels(text); async let g = api.searchCategories(text)
                let results = try await (c, g); try Task.checkCancellation()
                guard query == text else { return }
                channels = results.0.data; categories = results.1.data; loading = false
            } catch is CancellationError {} catch {
                if !Task.isCancelled && query == text { self.error = error.localizedDescription; model.noteConnectionError(error); loading = false }
            }
        }
    }
}
struct TVSettingsView: View {
    @Environment(AppModel.self) private var model
    var signIn: () -> Void
    var body: some View {
        @Bindable var personal = model.personal
        TVPage(title: "Settings") {
            HStack(alignment: .top, spacing: 100) {
                VStack(alignment: .leading, spacing: 28) {
                    Text(model.user?.displayName ?? model.auth.session?.login ?? "Twitch account").font(.system(size: 34, weight: .semibold))
                    Text(model.accountStatus).foregroundStyle(.secondary)
                    if !model.accountSignedIn { Button("Connect Twitch", action: signIn).buttonStyle(.borderedProminent) }
                    NavigationLink("Streaming sources") { TVSourcesView() }.accessibilityIdentifier("tv.sources")
                    Text(model.sources.active?.name ?? "No source selected").foregroundStyle(.secondary)
                    Divider()
                    Label("iCloud", systemImage: "icloud").font(.system(size: 32, weight: .semibold))
                    Text(model.sync.cloud.status).font(.system(size: 25)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if let date = model.sync.cloud.lastSyncedAt { Text("Last synced \(date.formatted(date: .abbreviated, time: .shortened))").font(.system(size: 23)).foregroundStyle(.secondary) }
                    Button("Sync now") { Task { await model.sync.sync() } }.disabled(model.sync.cloud.isSyncing).accessibilityIdentifier("tv.sync")
                    Text("Sources and preferences sync with iCloud.\nTwitch sign-in stays on this Apple TV.").font(.system(size: 23)).foregroundStyle(.secondary)
                    if let error = model.personal.error { Text(error).font(.system(size: 23)).foregroundStyle(.secondary) }
                    if model.auth.session != nil { Button("Sign out", role: .destructive) { Task { model.chat.disconnect(); await model.playback.stop(); await model.auth.logout(); await model.refresh() } } }
                }.frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 26) {
                    Text("Playback").font(.system(size: 34, weight: .semibold))
                    NavigationLink("Video quality") { TVQualitySettings() }
                    Toggle("Picture in Picture", isOn: $personal.data.preferences.pictureInPicture)
                    Toggle("Retry interrupted playback", isOn: $personal.data.preferences.retryPlayback)
                    Toggle("Reduce animations", isOn: $personal.data.preferences.reduceMotion)
                    NavigationLink("Advanced Twitch settings") { TVAdvancedSettings() }
                    NavigationLink("About Twitchy") { TVPage(title: "Twitchy", backButton: true) {
                        Text("Your streams. Your way.").font(.system(size: 36))
                        Text("An independent client by Rafael Reverberi.\nNot affiliated with Twitch.").foregroundStyle(.secondary)
                        NavigationLink("Privacy") { TVPage(title: "Privacy", backButton: true) { Text("Twitch sign-in and channel information connect directly to Twitch. Video comes from your selected source. Twitch credentials are never sent to that source. Sources and their tokens sync in encrypted private iCloud records. Twitch credentials stay in this device’s Keychain. Viewing history is used to personalize recommendations. No analytics is collected.").font(.system(size: 28)).lineSpacing(12) } }
                        NavigationLink("License") { TVPage(title: "License", backButton: true) { Text("MIT License · Copyright © 2026 Rafael Reverberi").font(.system(size: 30)); Text("Permission is granted to use, copy, modify, merge, publish, distribute, sublicense and sell copies subject to preserving the copyright and license notice. Software is provided AS IS without warranty. Uses Apple system frameworks.").font(.system(size: 28)).lineSpacing(12) } }
                    } }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
struct TVAdvancedSettings: View {
    @Environment(AppModel.self) private var model
    var body: some View { @Bindable var model = model
        TVPage(title: "Twitch application", backButton: true) { TextField("Public Client ID", text: $model.deviceClientID); Text("Use a public Twitch app registration.").foregroundStyle(.secondary) }
    }
}
struct TVSourcesView: View {
    @Environment(AppModel.self) private var model
    @State private var error: String?
    var body: some View {
        TVPage(title: "Streaming sources", backButton: true) {
            HStack(spacing: 30) {
                NavigationLink("Add source") { TVSourceEditor(source: nil) }.buttonStyle(.borderedProminent)
                Button("Sync from iCloud") { Task { await model.sync.sync() } }
            }
            if model.sources.sources.isEmpty { Text("Add a source here, or sync the one from your iPhone or Mac.").foregroundStyle(.secondary) }
            if let error = error ?? model.sources.error { Text(error).foregroundStyle(.secondary) }
            ForEach(model.sources.sources) { source in
                VStack(alignment: .leading, spacing: 20) {
                    HStack { Text(source.name).font(.system(size: 34, weight: .semibold)); if source.id == model.sources.activeID { Label("Active", systemImage: "checkmark.circle.fill").foregroundStyle(TwitchyTheme.live) } }
                    Text(source.connectionStatus).foregroundStyle(.secondary)
                    HStack(spacing: 30) {
                        Button("Test") { Task { await model.sources.test(source.id) } }
                        Button("Select") { do { try model.sources.select(source.id) } catch { self.error = error.localizedDescription } }.disabled(!source.enabled)
                        NavigationLink("Edit") { TVSourceEditor(source: source) }
                        Button("Remove", role: .destructive) { do { try model.sources.remove(source.id) } catch { self.error = error.localizedDescription } }
                    }
                    Divider()
                }.padding(.vertical, 12)
            }
        }
    }
}
struct TVSourceEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let source: StreamingSource?
    @State private var name = ""
    @State private var address = ""
    @State private var token = ""
    @State private var authenticate = false
    @State private var localHTTP = false
    @State private var enabled = true
    @State private var error: String?
    var body: some View {
        TVPage(title: source == nil ? "Add streaming source" : "Edit streaming source", backButton: true) {
            TextField("Name", text: $name)
            TextField("HTTPS base URL", text: $address).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
            Toggle("Enabled", isOn: $enabled)
            Toggle("Bearer authentication", isOn: $authenticate)
            if authenticate { SecureField(source == nil ? "Source token" : "New token (blank keeps existing)", text: $token) }
            Toggle("Allow local HTTP", isOn: $localHTTP)
            Text("Use your server’s source token. Local HTTP is restricted to private networks.").foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.secondary) }
            Button("Save source") {
                do {
                    guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { throw ClientError.message("Give your source a name.") }
                    let url = try SourceURL.validate(address, allowLocalHTTP: localHTTP)
                    var value = source ?? StreamingSource(name: name, baseURL: url)
                    value.name = name; value.baseURL = url; value.enabled = enabled; value.allowLocalHTTP = localHTTP; value.usesAuthentication = authenticate
                    if url != source?.baseURL { value.capabilities = nil; value.serverVersion = nil; value.lastSuccessfulCheck = nil; value.connectionStatus = "Not tested" }
                    try model.sources.upsert(value, credential: !authenticate ? "" : (!token.isEmpty ? token : nil)); dismiss()
                } catch { self.error = error.localizedDescription }
            }.buttonStyle(.borderedProminent).disabled(name.isEmpty || address.isEmpty)
        }.onAppear { if let source { name = source.name; address = source.baseURL.absoluteString; authenticate = source.usesAuthentication; localHTTP = source.allowLocalHTTP; enabled = source.enabled } }
    }
}

/// TV quality is device-local, so another device's preference never lowers the TV's default.
enum TVPlaybackSettings {
    static var preferredQuality: String {
        get {
            if TVFixtures.enabled { return ProcessInfo.processInfo.environment["TWITCHY_TV_QUALITY"] ?? "auto" }
            return UserDefaults.standard.string(forKey: "tv.preferredQuality") ?? "auto"
        }
        set { if !TVFixtures.enabled { UserDefaults.standard.set(newValue, forKey: "tv.preferredQuality") } }
    }
    static var availableQualities: [String] { UserDefaults.standard.stringArray(forKey: "tv.availableQualities") ?? [] }
    static func remember(_ qualities: [String]) {
        if !TVFixtures.enabled { UserDefaults.standard.set(qualities, forKey: "tv.availableQualities") }
    }
}
struct TVQualitySettings: View {
    @State private var quality = TVPlaybackSettings.preferredQuality
    private var choices: [String] {
        var values = ["auto"]
        for value in TVPlaybackSettings.availableQualities + [quality] where !values.contains(value) { values.append(value) }
        return values
    }
    var body: some View {
        TVPage(title: "Video quality", backButton: true) {
            Text("Best lets your streaming source choose the highest available quality. Applies to this Apple TV.").foregroundStyle(.secondary)
            ForEach(choices, id: \.self) { value in
                Button { quality = value; TVPlaybackSettings.preferredQuality = value } label: {
                    HStack { Text(value == "auto" ? "Best · Automatic" : value); Spacer(); if quality == value { Image(systemName: "checkmark") } }.padding(12)
                }.accessibilityIdentifier("tv.quality." + value)
            }
            if choices.count == 1 { Text("More qualities appear after watching a stream.").foregroundStyle(.secondary) }
        }
    }
}

struct TVChannelView: View {
    @Environment(AppModel.self) private var model
    let selection: ChannelSelection
    @State private var stream: TwitchStream?
    @State private var profile: TwitchUser?
    @State private var videos: [Video] = []
    @State private var clips: [Clip] = []
    @State private var watching: Bool
    @State private var error: String?
    @State private var playbackTask: Task<Void, Never>?
    @State private var retryTask: Task<Void, Never>?
    @State private var retries = 0
    private var broadcasterID: String? { profile?.id ?? selection.broadcasterID }
    init(selection: ChannelSelection) {
        self.selection = selection
        _watching = State(initialValue: selection.contentType == "live" || selection.contentID != nil)
    }
    var body: some View {
        Group {
            if watching { fullscreenPlayer }
            else { channelLibrary }
        }
        .onExitCommand { close() }
        .onChange(of: broadcasterID, initial: true) { _, id in model.tvCompanionBroadcasterID = id }
        .task {
            // Playback starts independently of Twitch metadata and library requests.
            if watching { play(type: selection.contentType ?? "live", id: selection.contentID) }
            #if DEBUG && targetEnvironment(simulator)
            if TVFixtures.enabled {
                profile = TVFixtures.profile; stream = model.followedStreams.first { $0.userLogin == selection.login }; videos = TVFixtures.videos; clips = TVFixtures.clips
                return
            }
            #endif
            do {
                guard let api = model.api else { return }
                profile = try await api.users(logins: [selection.login]).data.first
                stream = try await api.streams(login: selection.login).data.first
                try Task.checkCancellation()
                if let id = broadcasterID {
                    async let v = api.videos(userID: id); async let c = api.clips(broadcasterID: id)
                    videos = try await v.data; clips = try await c.data
                }
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
        .task(id: model.playback.session?.sessionId) {
            if let session = model.playback.session { TVPlaybackSettings.remember(session.qualities) }
            while !Task.isCancelled && model.playback.session != nil {
                do { try await Task.sleep(for: .seconds(10)); try Task.checkCancellation(); savePosition() } catch { return }
            }
        }
        .onChange(of: model.playback.state) { _, state in
            if state == .failed && model.personal.data.preferences.retryPlayback && retries < 2 {
                retries += 1; let delay = retries * 2; retryTask?.cancel()
                retryTask = Task { do { try await Task.sleep(for: .seconds(delay)); try Task.checkCancellation(); await model.playback.retry() } catch {} }
            }
        }
        .onDisappear { if !model.playback.pictureInPictureActive { stop() } }
    }
    private var fullscreenPlayer: some View {
        ZStack {
            if model.playback.session != nil {
                TVPlayerSurface().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.error == nil && model.playback.error == nil {
                // AVKit owns loading once a session exists; never overlay a second spinner.
                ProgressView().tint(.white).accessibilityIdentifier("tv.starting")
            }
            if let message = model.playback.error ?? model.error, model.playback.state != .loading {
                VStack(spacing: 28) {
                    Text(message).font(.system(size: 28)).multilineTextAlignment(.center).frame(maxWidth: 850)
                    HStack(spacing: 30) {
                        Button("Back") { close() }
                        Button("Retry") { play(type: model.playback.currentRequest?.contentType ?? selection.contentType ?? "live", id: model.playback.currentRequest?.contentId ?? selection.contentID) }
                        if model.sources.active == nil { NavigationLink("Connect a streaming source") { TVSourcesView() } }
                    }
                }.padding(44).background(.black.opacity(0.9), in: RoundedRectangle(cornerRadius: 20))
            }
        }.ignoresSafeArea().background(.black)
    }
    private var channelLibrary: some View {
        TVPage(title: "") {
            HStack(spacing: 30) {
                Button("Back") { close() }.accessibilityIdentifier("tv.channel.back")
                Text(selection.name).font(.system(size: 48, weight: .semibold))
            }
            HStack(alignment: .center, spacing: 50) {
                DiscoveryImage(stream?.thumbnail ?? profile.flatMap { URL(string: $0.offlineImageUrl ?? "") }).frame(width: 780, height: 438).clipShape(RoundedRectangle(cornerRadius: 18))
                VStack(alignment: .leading, spacing: 24) {
                    if stream != nil { Label("LIVE", systemImage: "circle.fill").foregroundStyle(.red) } else { Text("Offline").foregroundStyle(.secondary) }
                    Text(selection.name).font(.system(size: 34, weight: .semibold)).lineLimit(3)
                    if let stream {
                        Text(stream.title).font(.system(size: 28)).lineLimit(2)
                        Text(stream.gameName).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 30) {
                if stream != nil { Button("Watch Live") { play(type: "live", id: nil) }.buttonStyle(.borderedProminent).accessibilityIdentifier("tv.watchLive") }
            }.focusSection()
            if let error { Text(error).foregroundStyle(.secondary) }
            if !videos.isEmpty {
                Text("Recent videos").font(.system(size: 30, weight: .semibold))
                ScrollView(.horizontal) { HStack(spacing: 34) { ForEach(videos) { video in media(title: video.title, thumbnail: video.thumbnailUrl, type: "vod", id: video.id) } }.padding(24) }.frame(height: 390).padding(.horizontal, -24).focusSection()
            }
            if !clips.isEmpty {
                Text("Clips").font(.system(size: 30, weight: .semibold))
                ScrollView(.horizontal) { HStack(spacing: 34) { ForEach(clips) { clip in media(title: clip.title, thumbnail: clip.thumbnailUrl, type: "clip", id: clip.id) } }.padding(24) }.frame(height: 390).padding(.horizontal, -24).focusSection()
            }
        }
    }
    private func media(title: String, thumbnail: String, type: String, id: String) -> some View {
        Button { play(type: type, id: id) } label: {
            VStack(alignment: .leading, spacing: 12) { DiscoveryImage(URL(string: thumbnail.replacingOccurrences(of: "%{width}", with: "640").replacingOccurrences(of: "%{height}", with: "360"))).frame(width: 370, height: 210).clipShape(RoundedRectangle(cornerRadius: 14)); Text(title).font(.system(size: 25, weight: .semibold)).lineLimit(2).frame(height: 65, alignment: .topLeading).padding(.horizontal, 20).padding(.bottom, 20).frame(maxWidth: .infinity, alignment: .leading) }.frame(width: 370)
        }.buttonStyle(.card)
    }
    private func play(type: String, id: String?) {
        savePosition(); playbackTask?.cancel(); retryTask?.cancel(); retries = 0; watching = true; model.error = nil
        playbackTask = Task {
            await model.play(selection, contentType: type, contentID: id, qualityOverride: TVPlaybackSettings.preferredQuality)
            guard !Task.isCancelled else { return }
            if id == selection.contentID && selection.resumePosition > 0 { await model.playback.player.seek(to: CMTime(seconds: selection.resumePosition, preferredTimescale: 600)) }
        }
    }
    private func savePosition() {
        guard let request = model.playback.currentRequest, request.contentType != "live", let id = request.contentId else { return }
        let seconds = model.playback.player.currentTime().seconds
        if seconds.isFinite && seconds > 0 { model.personal.watched(.init(login: selection.login, title: selection.name, position: seconds, contentType: request.contentType, contentID: id)) }
    }
    private func close() { savePosition(); model.tvCompanionBroadcasterID = nil; model.selectedChannel = nil }
    private func stop() { savePosition(); playbackTask?.cancel(); retryTask?.cancel(); model.playback.player.pause(); Task { await model.playback.stop() } }
}
struct TVPlayerSurface: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        NativePlayer(player: model.playback.player, pictureInPicture: model.personal.data.preferences.pictureInPicture) { model.playback.pictureInPictureActive = $0 }
            .background(.black).accessibilityIdentifier("tv.player")
            .accessibilityValue(model.playback.state.rawValue + "|" + (model.playback.session?.sessionId ?? ""))
    }
}
#endif
