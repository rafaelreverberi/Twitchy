import SwiftUI

/// Compatibility route for existing player error links; configuration now lives in Sources.
struct ProxySettingsView: View {
    var body: some View {
        #if os(tvOS)
        TVSourcesView()
        #else
        SourcesView()
        #endif
    }
}

struct PlaybackProviderNotice: View {
    @Environment(AppModel.self) private var model
    @State private var visible = false
    @State private var announcedID: String?
    var body: some View {
        Group {
            if visible, let notice = model.playback.fallbackNotice {
                Text(notice).font(.caption).padding(10)
                    .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 8))
                    .foregroundStyle(.white).allowsHitTesting(false)
            }
        }
        .task(id: model.playback.playbackID) {
            visible = false
            guard model.playback.usingProxy, announcedID != model.playback.playbackID else { return }
            announcedID = model.playback.playbackID; visible = true
            do { try await Task.sleep(for: .seconds(7)); visible = false } catch { visible = false }
        }
    }
}
