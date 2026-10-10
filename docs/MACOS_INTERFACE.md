# macOS interface

The desktop interface uses the main window for discovery, channel browsing and watching. iOS and tvOS retain their existing layouts.

- **Home:** featured live channel, personalized live recommendations based on viewing duration/frequency, followed live streams, favorites, resumable videos, popular streams and categories.
- **Channel:** a live preview or offline image, avatar, current title/category, viewer count when live, description, favorites, Twitch follow link and sharing. Recent videos, past broadcasts and clips have separate tabs and pagination. Past broadcasts request Twitch's `type=archive` filter.
- **Watching:** native AVPlayer controls, channel information, source-provided quality selection, mute, fullscreen and more videos. Chat stays in a separate column while the player/library scroll. Theater mode gives the player the entire detail width and hides chat and the library.
- **Navigation:** sidebar destinations return directly from a channel or player. The back button returns from watching to the channel, then to discovery. The sidebar uses native List selection and materials. A compact Now Playing row above Settings shows the account avatar, channel name, pause/resume and mute on one line. Clicking the avatar/name returns to the existing playback session; its context menu provides explicit Stop. Command-K opens Search; Command-comma opens Settings.

Opening a channel on macOS browses its profile without starting playback. Watch live and video/clip cards explicitly start playback. Continue Watching starts the selected saved video and seeks to its saved position. On macOS, navigating away from watching or returning to the channel does not stop the active stream. The app retains the AVPlayer/session and PiP delegate across navigation. Returning recreates the inline AVPlayerView so AVKit rebuilds its PiP controls; an already active PiP view is retained. Playback ends on explicit Stop, window/app closure, or replacement with other content. Changing the configured source invalidates its old session. Playback still requires a configured compatible streaming source. Following is performed on Twitch; the star stores a favorite that syncs in iCloud-enabled builds. A video's chat panel displays live channel chat, not historical chat replay.

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
