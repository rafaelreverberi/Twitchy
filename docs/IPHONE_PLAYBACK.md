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
