# macOS interface

The desktop interface uses the main window for discovery, channel browsing and watching. iOS and tvOS retain their existing layouts.

- **Home:** featured live channel, personalized live recommendations based on viewing duration/frequency, followed live streams, resumable videos, popular streams and categories.
- **Channel:** a live preview or offline image, avatar, current title/category, viewer count when live, description and sharing. Recent videos, past broadcasts and clips have separate tabs and pagination. Past broadcasts request Twitch's `type=archive` filter.
- **Watching:** compact symbol controls over the video, channel information and more videos. Play/pause, volume, source-provided quality selection, AirPlay, Picture in Picture, chat, theater and fullscreen stay inside the player; no action row appears beneath it. Controls fade after three seconds of pointer inactivity and remain visible while paused or interacting with the control row. Videos and clips have a seek timeline. Chat stays in a separate column while the player/library scroll. Theater mode gives the player the entire detail width and hides chat and the library.
- **Navigation:** sidebar destinations return directly from a channel or player. The back button returns from watching to the channel, then to discovery. The sidebar uses native List selection and materials. A compact Now Playing row above Settings shows the account avatar, channel name, pause/resume, mute and an explicit Stop icon on one line. Clicking the avatar/name returns to the existing playback session; its context menu provides explicit Stop. Command-K opens Search; Command-comma opens Settings.

Opening a channel on macOS browses its profile without starting playback. Watch live and video/clip cards explicitly start playback. Continue Watching starts the selected saved video and seeks to its saved position. On macOS, navigating away from watching or returning to the channel does not stop the active stream. The app retains the AVPlayer, video layer and AVPictureInPictureController across navigation. Fullscreen moves that same video surface into a window-filling overlay without replacing the player or session. Playback ends on explicit Stop, window/app closure, or replacement with other content. Changing the configured source invalidates its old session. Playback still requires a configured compatible streaming source. A video's chat panel displays live channel chat, not historical chat replay.

## Verification (2026-10-10)

- macOS, iOS Simulator and tvOS Simulator application builds succeeded with signing disabled.
- All 45 package tests passed, including archive filtering/pagination and optional video metadata decoding and compact playback pause/mute/session cleanup. Opt-in external/fixture integrations were not enabled in this package run.
- OpenAPI local schema/reference validation passed.
- Manual macOS checks used the existing signed-in Twitch account and configured source: real Home metadata, BastiGHG profile/videos/broadcasts, eliasn97 clips, live playback, incoming EventSub chat with badges/emotes and wrapped text, theater mode, native sidebar return to Home, live mini-preview on Home, pause/resume, synchronized mute, reopening the existing player, PiP surviving return to Home, and explicit compact Stop. The source briefly returned source_unavailable; playback started successfully after retry.
- Chat sending, new downloads, fullscreen transitions, every quality, offline-channel browsing and narrow-window resizing were not exercised in this pass. iOS/tvOS were compiled, not tested on devices.

The initial interface update preserved source credentials, Twitch authentication and streaming backend code. The follow-up below adds explicit source-credential synchronization while retaining per-device Twitch authentication.

## PiP and sync follow-up (2026-10-10)

All 49 package tests and all three platform builds passed. Manual macOS testing confirmed the PiP control survives Home → compact Now Playing → stream and successfully starts PiP. A fresh real viewing session appeared as For you · Live now on Home. Pause excludes further duration; the compact row and source playback remain functional. Settings correctly displays the unsigned-build iCloud limitation.

The iCloud adapter, watch-duration tracking and recommendation logic are shared across platforms. Initial Apple-cloud testing was blocked by Personal Team provisioning. After switching to the maintainer's iCloud-capable team and `iCloud.ch.hivenet.twitchy`, the signed macOS build succeeded and its embedded provisioning profile contained the expected container. The maintainer subsequently reported successful iCloud sync and launches on their devices. See ICLOUD_SYNC.md for setup and the independent real-device acceptance test.

## Custom desktop controls (2026-10-11)

The desktop player uses AVPlayerLayer with custom SwiftUI controls and the public AVPictureInPictureController and AVRoutePickerView APIs. iPhone and Apple TV retain their existing controls. The Stop icon is directly accessible above Settings, after mute, and the Twitch follow link was removed from the macOS channel view. Fullscreen uses the existing window and keeps the same playback session.

Validation for this update: macOS builds with and without signing, iOS Simulator and tvOS Simulator builds passed. A separate temporary copy of the app with isolated personal/source storage and cloud sync disabled exercised local fixture playback, synchronized mute, theater, fullscreen entry/exit, quality selection, PiP surviving Home navigation/reopening, and Stop. The configured Intel Nuc source returned an offline connection error in the production-layout app, so live-source playback and AirPlay to a physical receiver were not verified for these custom controls.

## Library sorting and cards (2026-10-11)

Both Channel library and More from use responsive tabs and a Most recent / Most viewed menu. Thumbnail and title form one playback action, with a visible play symbol, hover feedback, duration, views, and creation time. Videos and broadcasts request Helix's time/views sorting; broadcasts keep the archive filter when loading more. Most recent clips cover the last 30 days, fetch complete time intervals before chronological sorting, and split busy intervals at Helix's pagination limit. Most viewed clips cover all time using Helix view-count order. Requests from a previous tab/sort are discarded, and Load more keeps the selected order. Existing iPhone and TV library calls retain their default parameters.

Validation: 53 package tests passed, including video-sort query preservation, clip metadata, chronological ordering across Helix pages, time-boundary deduplication, empty periods, and splitting at the clip result limit. macOS, iOS Simulator and tvOS Simulator builds passed. Live macOS checks loaded BastiGHG thumbnails and verified newest clips with timestamps and most-viewed clips with descending view counts. Cards and tabs were inspected in the channel view; the same library component is used beneath the player.

Favorites buttons and sections were removed on all platforms on 2026-10-11. Stored legacy favorites remain an internal compatibility field and are no longer exposed by the interface. Following lists continue to come from Twitch; Follow/Unfollow actions are currently omitted because the official API only supports reading follow state.

Clicking the avatar or channel name below the macOS player returns to the channel view while retaining playback in Now Playing. Double-clicking the video toggles fullscreen; the single-click play/pause gesture waits for double-click recognition so entering fullscreen does not pause the stream. iPhone and Apple TV gestures are unchanged.

## Download cards and library sorting (2026-10-11)

Downloads are started from a video or clip menu. The Downloads destination no longer has a manual content-ID/type/authorization form. Cards retain the content title, channel, duration and thumbnail; artwork is cached locally, with a video-frame fallback for completed downloads. Mac uses compact horizontal cards and iPhone uses full-width artwork. Transfers show a progress bar, downloaded/total/remaining bytes and an estimated remaining time in minutes when the source supplies a total size and measured transfer speed is available. Unknown sizes or stalled transfers display an estimating state. Completed downloads offer offline playback; interrupted downloads offer retry/removal, and active transfers offer cancellation.

The complete padded area of the Mac library tabs is clickable, both in Channel library and More from. iPhone offers Most recent / Most viewed in the channel ellipsis menu; the selected order survives tab changes and pagination. Recent clips use the same last-30-days window as Mac. Apple TV still has no persistent downloads UI.

Validation: 54 package tests passed, including metadata restoration, real fixture transfer, local poster caching, deletion and ETA conditions. All three platform builds passed. iPhone UI assertions passed for sorting, keeping the selected order on Clips, the empty Downloads state without manual fields, and recorded-only Download menus. Mac tab-padding clicks were verified against a live channel; preparing/completed download cards were inspected in a separate temporary app copy with isolated personal/source/download storage and cloud transport disabled. Real-source downloads and populated iPhone download cards were not live-tested.

## Offline playback and interaction fixes (2026-10-11)

Offline media now uses the retained app player, normal watch view, playback controls, seeking and fullscreen, rather than a separate AVKit sheet. No source session or chat connection is created for local playback; the chat panel says “Chat could not be loaded because we are offline.” Source changes do not interrupt a local movie. Source session cleanup is asynchronous, so an unreachable server cannot delay stopping or opening another video.

A stored 60-second clip reproduced the reported duration problem: FFprobe found 60 seconds of media while AVFoundation exposed only the initial 2.082-second fragment. OfflineMP4 rebuilds complete sample tables from the fragments, retaining media bytes and atomically replacing the original only after AVFoundation validation. It runs off the main actor, validates byte ranges, limits metadata/sample allocations and checks a known expected duration. New downloads are indexed before completion; existing fragmented downloads are repaired when opened. A truncated or obviously short file offers retry instead of being treated as completed.

The Mac double-click surface now sits above the full-height controls container while excluding the control bar. Manual testing confirmed fullscreen entry/exit without pausing. macOS has one search toolbar button outside Search and no top Settings button; Search has neither application toolbar action.

Validation: 60 package tests passed, including a copy of the actual 60-second clip and frame retrieval at second 55, an eight-second synthetic A/V movie, truncation preservation, duration checks and nonblocking cleanup. macOS, iOS Simulator and tvOS Simulator builds passed. The iPhone simulator UI test passed through Downloads → Play offline → normal player → fullscreen → watch view, checking the offline chat message, absence of a sheet and unchanged source-session request count. Real Mac offline playback showed a one-minute timeline and continued past the first fragment; both double-click directions and toolbar actions across Home/Channels/Profile/Search were checked. A physical iPhone was not tested.

The currently unresponsive Mac process was OS-stopped (process state T). Xcode’s console recorded that its LLDB RPC server had been killed while detaching. SIGCONT restored immediate app/UI responsiveness. This diagnoses that observed freeze; it does not establish that every past intermittent freeze had the same cause. A corrected Mac build was then launched without Xcode’s debugger.
