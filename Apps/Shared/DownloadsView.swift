import SwiftUI
import TwitchySources
import TwitchyCore
import TwitchyPlayback
import TwitchyDesignSystem

struct DownloadsView: View {
    @Environment(AppModel.self) private var model
    @State private var error: String?
    private var active: [LocalDownload] { model.downloads.items.filter { [.queued, .preparing, .ready, .transferring].contains($0.job.status) } }
    private var interrupted: [LocalDownload] { model.downloads.items.filter { [.paused, .failed, .cancelled].contains($0.job.status) } }
    private var completed: [LocalDownload] { model.downloads.items.filter { $0.job.status == .completed } }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Downloads").font(.largeTitle.bold())
                        Text("Your videos, ready to go.").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Label(storageLabel, systemImage: "internaldrive")
                        .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                }
                if let error = error ?? model.downloads.error { Notice(error) }
                #if os(tvOS)
                EmptyState("Downloads unavailable on Apple TV", detail: "Use Twitchy on iPhone, iPad or Mac to watch downloaded videos.", symbol: "arrow.down.circle")
                #else
                if model.downloads.items.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "arrow.down.circle").font(.system(size: 48, weight: .light)).foregroundStyle(TwitchyTheme.accent)
                        Text("Take a video with you").font(.title2.bold())
                        Text("Choose Download from a video or clip’s menu. Your downloads and their progress will appear here.")
                            .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 360)
                    }.padding(.vertical, 64).frame(maxWidth: .infinity).accessibilityIdentifier("downloads.empty")
                }
                if !active.isEmpty { section("Downloading & queued", items: active) }
                if !interrupted.isEmpty { section("Needs attention", items: interrupted) }
                if !completed.isEmpty { section("Ready to watch", items: completed) }
                #endif
            }.padding(20).frame(maxWidth: 1080, alignment: .leading).frame(maxWidth: .infinity)
        }.background(TwitchyTheme.background)
            .task { model.downloads.prepareThumbnails() }
            .safeAreaInset(edge: .bottom) {
                #if os(iOS)
                if model.mobile.selection != nil { Color.clear.frame(height: 70) }
                #endif
            }
    }
    private var storageLabel: String { ByteCountFormatter.string(fromByteCount: model.downloads.storageBytes, countStyle: .file) }
    private func section(_ title: String, items: [LocalDownload]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text(title).font(.title3.bold()); Text("\(items.count)").font(.caption.bold()).foregroundStyle(.secondary); Spacer() }
            LazyVStack(spacing: 16) { ForEach(items) { item in card(item) } }
        }
    }
    private func card(_ item: LocalDownload) -> some View {
        Group {
            #if os(macOS)
            HStack(alignment: .top, spacing: 20) {
                artwork(item).frame(width: 220, height: 124)
                details(item).frame(maxWidth: .infinity, alignment: .leading)
            }.padding(18)
            #else
            VStack(alignment: .leading, spacing: 14) {
                artwork(item).aspectRatio(16 / 9, contentMode: .fit)
                details(item)
            }.padding(14)
            #endif
        }.background(TwitchyTheme.secondary, in: RoundedRectangle(cornerRadius: 20))
            .accessibilityElement(children: .contain).accessibilityIdentifier("download.\(item.id.uuidString)")
    }
    private func artwork(_ item: LocalDownload) -> some View {
        DownloadArtwork(fileURL: model.downloads.thumbnailFile(for: item), remoteURL: item.metadata?.thumbnailURL)
            .overlay(alignment: .bottomTrailing) {
                if let duration = item.metadata?.duration, !duration.isEmpty {
                    Text(duration).font(.caption.bold()).foregroundStyle(.white).padding(6)
                        .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 6)).padding(10)
                }
            }.clipShape(RoundedRectangle(cornerRadius: 12))
    }
    private func details(_ item: LocalDownload) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(item.displayTitle).font(.headline).lineLimit(2)
                    HStack(spacing: 6) {
                        Text(item.contentType == "clip" ? "CLIP" : "VIDEO").font(.caption2.bold()).foregroundStyle(TwitchyTheme.accent)
                        if let channel = item.metadata?.channel { Text(channel).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    }
                }
                Spacer(minLength: 0)
                Menu {
                    if !model.downloads.isRunning(item.id), item.job.status != .completed {
                        Button("Retry download", systemImage: "arrow.clockwise") {
                            do { model.downloads.resume(item.id, client: try originalClient(item.sourceID)) }
                            catch { self.error = error.localizedDescription }
                        }
                    }
                    if model.downloads.isRunning(item.id) {
                        Button("Cancel download", systemImage: "xmark", role: .destructive) {
                            Task { await model.downloads.cancel(item.id, client: try? originalClient(item.sourceID)) }
                        }
                    } else {
                        Button("Remove download", systemImage: "trash", role: .destructive) {
                            do { try model.downloads.delete(item.id) } catch { self.error = error.localizedDescription }
                        }
                    }
                } label: { Image(systemName: "ellipsis").font(.headline).frame(width: 32, height: 32).contentShape(Rectangle()) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel("Download options for \(item.displayTitle)")
            }
            if item.job.status == .completed {
                HStack {
                    Label("Available offline", systemImage: "checkmark.circle.fill").font(.caption.weight(.medium)).foregroundStyle(TwitchyTheme.live)
                    Spacer()
                    Text(bytes(item.job.transferredBytes)).font(.caption).foregroundStyle(.secondary)
                }
                if let url = model.downloads.file(for: item) {
                    Button { model.playOffline(item, url: url) } label: { Label("Play offline", systemImage: "play.fill") }
                        .buttonStyle(.borderedProminent).accessibilityIdentifier("download.play")
                }
            } else {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(status(item)).font(.subheadline.weight(.medium))
                            Spacer()
                            if item.job.status == .transferring { Text(remainingTime(item, at: context.date)).font(.caption).foregroundStyle(.secondary) }
                        }
                        if item.job.status == .transferring, let total = item.job.totalBytes, total > 0 {
                            ProgressView(value: min(1, max(0, Double(item.job.transferredBytes) / Double(total)))).tint(TwitchyTheme.accent)
                            Text("\(bytes(item.job.transferredBytes)) of \(bytes(total)) · \(bytes(max(0, total - item.job.transferredBytes))) remaining")
                                .font(.caption).foregroundStyle(.secondary)
                        } else if [.queued, .preparing, .ready, .transferring].contains(item.job.status) {
                            ProgressView().controlSize(.small)
                            Text(item.job.transferredBytes > 0 ? "\(bytes(item.job.transferredBytes)) downloaded · total size not available yet" : (item.job.status == .transferring ? "Starting transfer…" : "Preparing your video…"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if let message = item.job.error?.message, item.job.status == .failed { Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
                    }
                }
            }
        }
    }
    private func bytes(_ count: Int64) -> String { ByteCountFormatter.string(fromByteCount: max(0, count), countStyle: .file) }
    private func remainingTime(_ item: LocalDownload, at date: Date) -> String {
        guard let seconds = item.estimatedSecondsRemaining(at: date), seconds.isFinite else { return "Estimating…" }
        if seconds < 60 { return "Less than 1 min left" }
        return "About \(Int(min(ceil(seconds / 60), 99999))) min left"
    }
    private func status(_ item: LocalDownload) -> String {
        switch item.job.status {
        case .queued, .preparing, .ready: "Preparing download"
        case .transferring: "Downloading"
        case .completed: "Available offline"
        case .paused: "Paused"
        case .failed: "Download interrupted"
        case .cancelled: "Cancelled"
        }
    }
    private func originalClient(_ sourceID: UUID) throws -> StreamingSourceClient {
        guard let source = model.sources.sources.first(where: { $0.id == sourceID }) else { throw ClientError.message("Restore the original source to retry this download.") }
        return try model.sources.client(for: source)
    }
}

private struct DownloadArtwork: View {
    let fileURL: URL?
    let remoteURL: URL?
    @State private var cached: Image?
    var body: some View {
        Color.clear.overlay {
            if let cached { cached.resizable().scaledToFill() }
            else if let remoteURL { RemoteImage(remoteURL) }
            else {
                LinearGradient(colors: [TwitchyTheme.accent.opacity(0.3), TwitchyTheme.elevated], startPoint: .topLeading, endPoint: .bottomTrailing)
                    .overlay { Image(systemName: "play.rectangle").font(.largeTitle).foregroundStyle(.secondary) }
            }
        }.clipped().task(id: fileURL) {
            #if os(macOS)
            cached = fileURL.flatMap { NSImage(contentsOf: $0) }.map { Image(nsImage: $0) }
            #else
            cached = fileURL.flatMap { UIImage(contentsOfFile: $0.path) }.map { Image(uiImage: $0) }
            #endif
        }
    }
}

#Preview { DownloadsView().environment(AppModel()) }

struct OfflineChatNotice: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.slash").font(.title2).foregroundStyle(.secondary)
            Text("Chat could not be loaded because we are offline.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("chat.offline")
    }
}
