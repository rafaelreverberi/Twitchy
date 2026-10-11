# iPhone channel and player experience

The iOS channel and watch screens follow the layout and interaction patterns of
[Yattee](https://github.com/yattee/yattee/tree/2969b086924b1d9f490615fee57ba42761fa8973):
a cover with a centered channel avatar, a segmented channel library, custom
video controls, an expanded player and a persistent mini-player. The Twitch
chat is an independent pane with inline wrapping badges, names, words and
emotes, a compact composer and a jump-to-latest action. VOD controls include local timeline scrubbing and
ten-second seeking. Opening the keyboard
reduces the video and metadata footprint. Tapping either the video or chat
messages dismisses the keyboard. Home and Channels keep their existing
visual language. No Yattee source code or runtime dependencies are included.

Selecting a live stream on Home opens playback directly. Selecting a channel
opens its About, Videos, Broadcasts and Clips page without starting playback,
even when autoplay is enabled. Tap Watch live to start the stream. Channel metadata does not
wait for a streaming-source health check. Optional library failures do not
remove the channel header or a working live stream.

## Search navigation

Each iPhone tab owns a NavigationStack. Search uses SwiftUI's native searchable
navigation-bar drawer with always-visible placement, rather than a custom top
safe-area inset. This keeps the system title and search field in the same
navigation hierarchy. Opening a result dismisses search editing and preserves
the query for the return to Search. The UI regression checks the title above
the native search field on entry, after a channel return, and after tab switching.
macOS retains its pinned search field.

## Ownership and transitions

`MobilePlaybackCoordinator` owns the iOS presentation, managed playback and
retry tasks, and the retained `MobilePlayerSurface`. `MobileRootView` mounts one
UIView backed by one AVPlayerLayer for its lifetime. The layer uses the existing
shared AVPlayer. The channel view never stops playback on disappearance.

Fullscreen, chat/details, channel navigation, minimization, opening the same
stream and foreground/background transitions preserve the AVPlayerItem and
source session. The grid button opens the active channel and minimizes video.
Swipe down or the chevron minimizes the player; in fullscreen it first exits
fullscreen. Close on the mini-player explicitly stops and deletes the session.
Switching to different content, changing source, quality selection, and explicit
retry are the operations that may create a different session.

The PiP controller is retained and prepared after the video layer is ready.
Automatic PiP is enabled while the watch player is expanded, subject to the
app's PiP preference and Apple's system PiP settings/support. The restore
callback expands the same player. Background handling waits for AVKit's
transition; if PiP does not start, it pauses while retaining the item/session.
It does not delete playback merely because the app entered the background.

## Errors

Canceled starts and old-item errors cannot overwrite a newer playback.
Retryable source/network startup failures receive at most two managed retries,
with a reconnecting indicator. Permanent unavailable responses are displayed
as unavailable and do not loop or attach an invalid HLS item. Actual offline
channels or errors from an external source still need that source to recover.
macOS code paths and UI remain unchanged by this iOS redesign.

## Local verification

Generate a visible one-minute fixture and start the loopback-only test server:

```sh
scripts/make-playback-fixture.sh
python3 MockServer/server.py --port 8181 --media-dir /tmp/twitchy-visual-fixture --unique-sessions
```

Run the `Twitchy-iOS` UI tests on an iPhone simulator. Fixture mode is recognized
only in Debug iOS Simulator builds via `TWITCHY_UI_PLAYBACK_FIXTURE=1`. It uses
isolated personal preferences/history, does not sync to iCloud, does not install
a source or authenticate with Twitch, and disables message sending. Chat and
channel metadata are deterministic UI fixtures; HLS uses the real session client.

Tests check channel navigation, inline chat and keyboard layout, fullscreen and
rotation, same-stream reopening, minimization, background return and VOD seeking. They
compare both item identity and session identity and count POST/DELETE requests
at the mock server. Separate scenarios exercise one transient startup failure
and a permanent unavailable response. Screenshots are attached to xcresults.

The tested iOS 27 simulator reports PiP as unsupported. Its background-return
and session-preservation checks pass, but real automatic PiP must be tested on
a physical iPhone. Live Twitch chat, real source failures and long-running
buffering also require an actual Twitch account/source.

## Playback options (2026-10-11)

The button next to the channel name is now an ellipsis menu. View channel opens the existing channel library without replacing playback. Download is offered for VODs and clips, never live streams; the configured source must support client-side downloads. Queue results and errors are shown in a confirmation alert, and progress is available under Downloads. Favorites/star actions and sections have been removed across iPhone, Mac and Apple TV. Apple TV also no longer has the star/Library sidebar item. Follow/unfollow actions are omitted: Twitch no longer provides a supported API to change follows, and no additional OAuth scopes are requested.

Validation: all 53 package tests and macOS/iOS Simulator/tvOS Simulator builds passed. The focused iPhone UI test passed through Live → View channel → Video → View channel → Clip and verified that Download is absent for live content and present for VODs/clips. The Apple TV screen test passed across onboarding, Home, Channels, Search, Settings and channel views, checking that Library/Favorites/Add favorite/Remove favorite are absent. The new player-menu download action was not exercised against a real configured source in this pass.

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
