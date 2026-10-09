import SwiftUI
import TwitchyDesignSystem
import AVKit

@main struct TwitchyApp: App {
    @State private var model = AppModel()
    var body: some Scene {
        WindowGroup {
            RootView().environment(model).tint(TwitchyTheme.accent)
                .preferredColorScheme(model.personal.data.preferences.darkTheme ? .dark : nil)
                .task { await model.startup() }
        }
        #if os(macOS)
        .defaultSize(width: 1280, height: 830)
        .commands { CommandGroup(after: .appInfo) { Button("Twitchy Settings…") { model.showingSettings = true }.keyboardShortcut(",", modifiers: .command) } }
        #endif
    }
}
