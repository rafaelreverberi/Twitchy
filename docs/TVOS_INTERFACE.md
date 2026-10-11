# Apple TV interface

The tvOS app has its own SwiftUI views in `Apps/Shared/TVViews.swift`. iPhone and Mac keep their existing interfaces. The TV workspace uses native focus, large thumbnails, short labels, and full-screen navigation. Its destinations are Home, Channels, Search, Library, and Settings. Downloads are absent, including initialization of the download directory.

First launch restores the local session and synced configuration before showing onboarding. A signed-out Apple TV starts Twitch's public Device Code Flow automatically. The full-screen onboarding displays a QR code for Twitch's verification URL and a large user code. Authorization polls automatically and requests access to followed channels. A successful sign-in opens the workspace. Apple TV never displays or connects chat. The decision to skip TV onboarding is device-local, so finishing onboarding on an iPhone does not skip sign-in on a new Apple TV.

Home opens with a large featured live thumbnail, choosing the highest-ranked live channel from the same synced viewing history used on iPhone and Mac. The For you section uses the shared recommendation scores; follows and popular streams supply a fallback when no personalized channel is live. Followed channels carry a red LIVE label beside their name.

Selecting a stream card on Home, Search, or a category starts playback immediately in fullscreen, independently of Twitch metadata requests. Both live cards and followed-channel entries under Channels open the channel profile first, with an explicit Watch Live action. There is no embedded player, chat column, fullscreen button, or quality selector inside playback. Live and offline channel profiles retain their video/clip library; choosing a recording also opens fullscreen. Menu ends playback and cleans up the server session. Video and source authentication remain independent of Twitch authentication.

Small stream, game, and recording cards inset their labels from the rounded edges. Horizontal rows reserve space for the native focus enlargement. Before a playback session exists, one white spinner appears without text; after that, AVKit owns its native loading indicator.

Video quality lives in Settings → Video quality. Best (auto) is the default and asks the source for its highest available quality. The override and discovered quality choices are local to this Apple TV, so a synced mobile quality preference does not change its default. Source-provided alternatives appear after playback.

Settings, source management, source editing, application settings, privacy, and license information use full-screen pages. Standard navigation and the Menu button provide return paths. There are no compact settings, onboarding, source-editor, or channel sheets.

## Storage repair

`TwitchyStoragePaths.directory` uses `Library/Caches/Twitchy` on tvOS and retains `Library/Application Support/Twitchy` on iOS/macOS. Personal data, source configuration, and the encrypted sync journal all use this location. Credentials and the journal encryption key stay in Keychain. CloudKit remains the source for restoring configuration after tvOS evicts caches.

This follows [Apple's tvOS storage guidance](https://developer.apple.com/library/archive/documentation/General/Conceptual/AppleTV_PG/index.html). Offline downloads are unsupported on Apple TV and the download manager no longer creates a directory there.

## Verification — 2026-10-11

- Apple TV 4K simulator at 1080p, tvOS 27: onboarding, QR/code screen, Home, Channels, Search, Library, Settings, channel, source list, source editor, advanced settings, About, Privacy, License, and category pages inspected and captured using simulator UI tests.
- Siri Remote focus/select/Menu navigation through stream cards, settings subpages, categories, and source editor.
- Local HLS playback enters Playing immediately at the full 1920×1080 simulator bounds; chat and inline quality controls are absent. Default quality requests auto even with a synced 360p preference, a TV override requests 360p, and Menu deletes the single playback session.
- QR screenshot decoded successfully with Apple Vision. A real Twitch device authorization request also returned a QR URL and user code, reaching the waiting-for-authorization state; consent was not completed.
- Native tvOS storage test verifies writable cache files, encrypted journal content, configuration reload, and restoration from a test cloud transport after cache eviction.
- All 49 shared package tests and all 10 tvOS UI/storage checks pass, including a focused loading-indicator rerun with a deliberately slow source. They cover personalization fixtures, live/offline channel labels, fullscreen entry/exit, TV quality overrides, and storage recovery.
- iPhone Simulator and Mac builds pass; their interfaces and platform storage locations remain unchanged.
- tvOS device Release build passes, including layered Home Screen/App Store icons and top-shelf assets.

Screenshots use local fixtures, not a live Twitch account. The production flow still requires a signed build, the configured CloudKit container, the user's iCloud account, Twitch consent, and a compatible streaming source. Real-account Twitch completion, physical Siri Remote behavior, and cross-device production CloudKit sync have not been verified here.

Run the TV checks with the mock server running:

```sh
python3 MockServer/server.py --port 8181
xcodebuild -project Twitchy.xcodeproj -scheme Twitchy-tvOS \
  -destination 'platform=tvOS Simulator,name=Apple TV 4K (3rd generation) (at 1080p)' \
  CODE_SIGNING_ALLOWED=NO test
```

Simulator fixture launches use `TWITCHY_TV_SCREEN` in Debug only. They use isolated personal/source files and in-memory secrets; they never authenticate to Twitch or mutate the user's real configuration. Release builds ignore this environment variable. Regenerate the native TV assets with `swift scripts/make_tv_assets.swift Apps/tvOS/Assets.xcassets/TVBrand.brandassets`.
