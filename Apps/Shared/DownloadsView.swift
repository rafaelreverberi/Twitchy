import SwiftUI
import TwitchySources
import TwitchyCore
import TwitchyDesignSystem

struct DownloadsView: View {
    @Environment(AppModel.self) private var model
    @State private var contentID = ""
    @State private var permission = ""
    @State private var type = "vod"
    @State private var error: String?
    var body: some View {
        List {
            Section { Text("\(ByteCountFormatter.string(fromByteCount: model.downloads.storageBytes, countStyle: .file)) stored on this device").font(.headline) }
            if let error = error ?? model.downloads.error { Notice(error) }
            #if os(tvOS)
            EmptyState("Downloads unavailable on Apple TV", detail: "Use Twitchy on iPhone, iPad or Mac to store authorized media offline.", symbol: "arrow.down.circle")
            #else
            if model.sources.active?.capabilities?.downloads == true {
                Section("Download to this device") {
                    Picker("Content", selection: $type) { Text("Video").tag("vod"); Text("Clip").tag("clip") }
                    TextField("Content ID", text: $contentID)
                    if model.sources.active?.capabilities?.authorizedDownloadsOnly == true { TextField("Permission reference issued by your source", text: $permission) }
                    Button("Add download") { Task { do { let client = try model.sources.client(); await model.downloads.enqueue(client: client, type: type, contentID: contentID, permission: permission, quality: model.personal.data.preferences.preferredQuality) } catch { self.error = error.localizedDescription } } }.disabled(contentID.isEmpty || (model.sources.active?.capabilities?.authorizedDownloadsOnly == true && permission.isEmpty))
                }
            } else { EmptyState("No download-capable source", detail: "Select a source that supports video and clip downloads.", symbol: "arrow.down.circle") }
            ForEach(model.downloads.items) { item in
                Section {
                    Text(item.job.filename ?? item.contentID).font(.headline)
                    Text(item.job.status.rawValue.capitalized).foregroundStyle(.secondary)
                    if item.job.totalBytes != nil || item.job.status == .completed { ProgressView(value: item.job.progress) } else if item.job.status == .transferring { ProgressView() }
                    Text((item.job.totalBytes != nil ? "\(Int(item.job.progress * 100))% · " : "") + ByteCountFormatter.string(fromByteCount: item.job.transferredBytes, countStyle: .file)).font(.caption)
                    if let speed = item.bytesPerSecond, item.job.status == .transferring { Text("\(ByteCountFormatter.string(fromByteCount: Int64(speed), countStyle: .file))/s").font(.caption) }
                    HStack {
                        if item.job.status == .completed, let url = model.downloads.file(for: item) { Button("Play offline") { model.localPlayback = url } }
                        if item.job.status == .failed || item.job.status == .ready || item.job.status == .queued || item.job.status == .preparing { Button("Retry / resume") { do { model.downloads.resume(item.id, client: try originalClient(item.sourceID)) } catch { self.error = error.localizedDescription } } }
                        if item.job.status != .completed && item.job.status != .cancelled { Button("Cancel") { Task { await model.downloads.cancel(item.id, client: try? originalClient(item.sourceID)) } } }
                        Button("Delete", role: .destructive) { do { try model.downloads.delete(item.id) } catch { self.error = error.localizedDescription } }
                    }
                }
            }
            #endif
        }.task(id: model.sources.activeID) { if let id = model.sources.activeID { await model.sources.test(id) } }
    }
    private func originalClient(_ sourceID: UUID) throws -> StreamingSourceClient {
        guard let source = model.sources.sources.first(where: { $0.id == sourceID }) else { throw ClientError.message("Restore the original source to retry this download.") }
        return try model.sources.client(for: source)
    }
}

#Preview { DownloadsView().environment(AppModel()) }
