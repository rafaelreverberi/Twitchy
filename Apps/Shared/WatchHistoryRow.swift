#if !os(tvOS)
import SwiftUI
import TwitchyCore
import TwitchyAPI
import TwitchyDesignSystem

struct WatchHistoryRow: View {
    @Environment(AppModel.self) private var model
    var title = "Watch history"
    @State private var visibleCount = 10
    @State private var thumbnails: [String: URL] = [:]
    @State private var avatars: [String: URL] = [:]

    private var entries: [WatchEntry] {
        Array(model.personal.data.history
            .sorted { $0.watchedAt > $1.watchedAt }.prefix(visibleCount))
    }
    private var loadID: String {
        (model.auth.session?.userID ?? "") + "|" + String(model.api != nil) + "|" + entries.map { "\($0.id):\($0.watchedAt.timeIntervalSince1970)" }.joined(separator: ",")
    }
    private var cardWidth: CGFloat {
        #if os(macOS)
        240
        #else
        230
        #endif
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.title2.bold())
            if entries.isEmpty {
                Text("Your recently watched channels, videos and clips will appear here.").foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: spacing) {
                        ForEach(entries) { entry in
                            Button {
                                model.selectedChannel = .init(login: entry.login, name: entry.title, contentType: entry.contentType, contentID: entry.contentID, resumePosition: entry.position)
                            } label: { card(entry) }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(entry.title), \(entry.login), \(entry.watchedAt.formatted(date: .abbreviated, time: .omitted))")
                            .accessibilityIdentifier("history.\(entry.id)")
                        }
                        if entries.count < model.personal.data.history.count {
                            Button {
                                visibleCount = min(visibleCount + 10, model.personal.data.history.count)
                            } label: {
                                Label("Load more", systemImage: "arrow.right")
                            }.buttonStyle(.bordered).controlSize(.large)
                                .padding(.horizontal, 12)
                                .accessibilityIdentifier("history.loadMore")
                        }
                    }
                    .padding(.vertical, 4)
                }.scrollIndicators(.hidden)
            }
        }.task(id: loadID) { await loadThumbnails() }
            .onChange(of: model.personal.data.history.isEmpty) { _, empty in
                if empty { visibleCount = 10; thumbnails = [:]; avatars = [:] }
            }
    }
    private var spacing: CGFloat {
        14
    }
    private func card(_ entry: WatchEntry) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            AsyncImage(url: thumbnails[entry.id]) { phase in
                if let image = phase.image { image.resizable().scaledToFill() }
                else { RemoteImage(avatars[entry.login.lowercased()], symbol: "person.crop.circle") }
            }.frame(width: cardWidth, height: cardWidth * 9 / 16).clipped()
                .overlay(alignment: .bottomLeading) {
                    Text(entry.contentType == "vod" ? "VIDEO" : entry.contentType == "clip" ? "CLIP" : "CHANNEL")
                        .font(.caption.bold()).foregroundStyle(.white).padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.black.opacity(0.7), in: Capsule()).padding(10)
                }
            VStack(alignment: .leading, spacing: 6) {
                Text(entry.title).font(.headline).lineLimit(1)
                Text(entry.login).foregroundStyle(.secondary).lineLimit(1)
                if entry.contentID != nil && entry.position > 0 {
                    Text("Resume at \(Int(entry.position) / 60):\(String(format: "%02d", Int(entry.position) % 60))").foregroundStyle(.secondary)
                } else {
                    Text(entry.watchedAt, style: .date).foregroundStyle(.secondary)
                }
            }
            .font(.caption).padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }.frame(width: cardWidth, alignment: .leading)
            .background(TwitchyTheme.secondary, in: RoundedRectangle(cornerRadius: 14))
            .clipShape(RoundedRectangle(cornerRadius: 14))
    }
    private func loadThumbnails() async {
        let snapshot = entries
        guard !snapshot.isEmpty, let api = model.api else { return }
        let logins = Array(Set(snapshot.map { $0.login.lowercased() }))
        let vodIDs = snapshot.filter { $0.contentType == "vod" }.compactMap(\.contentID)
        let clipIDs = snapshot.filter { $0.contentType == "clip" }.compactMap(\.contentID)
        async let users = try? api.users(logins: logins)
        async let streams = try? api.streams(logins: logins)
        async let videos: [Video] = {
            guard !vodIDs.isEmpty else { return [] }
            return (try? await api.videos(ids: vodIDs).data) ?? []
        }()
        async let clips: [Clip] = {
            guard !clipIDs.isEmpty else { return [] }
            return (try? await api.clips(ids: clipIDs).data) ?? []
        }()
        let (profiles, live, recorded, highlights) = await (users, streams, videos, clips)
        guard !Task.isCancelled, model.api === api else { return }
        let retained = Set(snapshot.map(\.id))
        var images = thumbnails.filter { retained.contains($0.key) }
        var channelImages = avatars.filter { logins.contains($0.key) }
        for user in profiles?.data ?? [] { channelImages[user.login.lowercased()] = URL(string: user.profileImageUrl) }
        for entry in snapshot {
            if entry.contentType == "vod", let video = recorded.first(where: { $0.id == entry.contentID }) {
                images[entry.id] = thumbnailURL(video.thumbnailUrl)
            } else if entry.contentType == "clip", let clip = highlights.first(where: { $0.id == entry.contentID }) {
                images[entry.id] = thumbnailURL(clip.thumbnailUrl)
            } else if entry.contentID == nil, let stream = live?.data.first(where: { $0.userLogin.lowercased() == entry.login.lowercased() }) {
                images[entry.id] = stream.thumbnail
            }
        }
        thumbnails = images
        avatars = channelImages
    }
    private func thumbnailURL(_ value: String) -> URL? {
        guard !value.isEmpty else { return nil }
        return URL(string: value.replacingOccurrences(of: "%{width}", with: "640").replacingOccurrences(of: "%{height}", with: "360").replacingOccurrences(of: "{width}", with: "640").replacingOccurrences(of: "{height}", with: "360"))
    }
}

#endif
