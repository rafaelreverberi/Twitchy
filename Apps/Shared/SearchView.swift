import SwiftUI
import TwitchyAPI
import TwitchyDesignSystem

struct SearchView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var kind = "Channels"
    @State private var channels: [SearchChannel] = []
    @State private var categories: [TwitchCategory] = []
    @State private var cursor: String?
    @State private var error: String?
    @State private var loading = false
    #if os(iOS)
    @State private var searching = false
    @State private var queryBeforeChannel: String?
    #endif
    private var canBrowse: Bool {
        #if DEBUG && os(iOS) && targetEnvironment(simulator)
        if MobileFixtures.enabled { return true }
        #endif
        return model.api != nil
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Picker("Search for", selection: $kind) { Text("Channels").tag("Channels"); Text("Live channels").tag("Live channels"); Text("Categories").tag("Categories") }.pickerStyle(.segmented)
                if !canBrowse { LoginPrompt() }
                else if query.isEmpty {
                    Text("Recent searches").font(.title2.bold())
                    ForEach(model.personal.data.recentSearches, id: \.self) { text in Button { query = text } label: { Label(text, systemImage: "clock") } }
                    EmptyState("Find your next stream", detail: "Search channels or categories. Videos and clips are available inside channel details.", symbol: "magnifyingglass")
                } else {
                    if loading { ProgressView("Searching Twitch…") }
                    if let error { Notice(error) }
                    if kind == "Categories" {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 200))]) { ForEach(categories) { category in NavigationLink { CategoryDetail(category: category) } label: { VStack { RemoteImage(URL(string: category.boxArtUrl.replacingOccurrences(of: "{width}", with: "285").replacingOccurrences(of: "{height}", with: "380"))).aspectRatio(0.75, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 12)); Text(category.name).font(.headline) } }.buttonStyle(.plain) } }
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 260, maximum: 400))], spacing: 20) {
                            ForEach(channels) { channel in Button { open(channel) } label: { HStack { RemoteImage(URL(string: channel.thumbnailUrl), symbol: "person.crop.circle").frame(width: 64, height: 64).clipShape(Circle()); VStack(alignment: .leading, spacing: 5) { Text(channel.displayName).font(.headline); Text(channel.gameName).font(.caption).foregroundStyle(.secondary); Text(channel.isLive ? "LIVE" : "Offline").font(.caption.bold()).foregroundStyle(channel.isLive ? TwitchyTheme.live : TwitchyTheme.muted) }; Spacer() }.padding(12).background(TwitchyTheme.secondary, in: RoundedRectangle(cornerRadius: 12)) }.buttonStyle(.plain) }
                        }
                    }
                    if !loading, error == nil, channels.isEmpty, categories.isEmpty { EmptyState("No results", detail: "Try another channel or category name.", symbol: "magnifyingglass") }
                    if cursor != nil { Button("Load more results") { Task { await search(more: true) } } }
                }
            }.padding(24)
        }
        #if os(iOS)
        .navigationTitle("Search")
        .navigationBarTitleDisplayMode(.large)
        .searchable(text: $query, isPresented: $searching, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search Twitch")
        #elseif os(tvOS)
        .searchable(text: $query, prompt: "Search Twitch")
        #else
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search Twitch", text: $query)
                    .textFieldStyle(.plain).submitLabel(.search)
                    .accessibilityIdentifier("search.input")
                    .onSubmit { model.personal.searched(query) }
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain).accessibilityLabel("Clear search")
                }
            }
            .padding(12).background(TwitchyTheme.secondary, in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 24).padding(.vertical, 12)
            .frame(maxWidth: .infinity).background(.bar)
        }
        #endif
        .task(id: query + kind) {
            channels = []; categories = []; cursor = nil
            guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            do { try await Task.sleep(for: .milliseconds(350)); await search(more: false) } catch { }
        }
        #if os(iOS)
        .onChange(of: model.selectedChannel) { _, channel in
            if channel == nil, let previous = queryBeforeChannel {
                query = previous
                queryBeforeChannel = nil
            }
        }
        #endif
        .onSubmit(of: .search) { model.personal.searched(query) }
    }
    private func open(_ channel: SearchChannel) {
        #if os(iOS)
        queryBeforeChannel = query
        searching = false
        query = ""
        #endif
        model.open(login: channel.broadcasterLogin, name: channel.displayName, id: channel.id)
    }
    private func search(more: Bool) async {
        #if DEBUG && os(iOS) && targetEnvironment(simulator)
        if MobileFixtures.enabled {
            channels = kind == "Categories" ? [] : MobileFixtures.searchChannels
            categories = []; cursor = nil
            return
        }
        #endif
        guard let api = model.api else { return }
        loading = true; error = nil; let current = query + kind; defer { if current == query + kind { loading = false } }
        do {
            if kind == "Categories" { let page = try await api.searchCategories(query, after: more ? cursor : nil); try Task.checkCancellation(); guard current == query + kind else { return }; categories = more ? categories + page.data : page.data; cursor = page.pagination?.cursor }
            else { let page = try await api.searchChannels(query, liveOnly: kind == "Live channels", after: more ? cursor : nil); try Task.checkCancellation(); guard current == query + kind else { return }; channels = more ? channels + page.data : page.data; cursor = page.pagination?.cursor }
        } catch is CancellationError { }
        catch { if current == query + kind { self.error = error.localizedDescription } }
    }
}

#Preview { SearchView().environment(AppModel()) }
