# iCloud sync setup and verification

All three targets share `iCloud.ch.hivenet.twitchy`. Enable iCloud / CloudKit for their app identifiers in the same Apple Developer team and assign this container to each identifier. Select that team in Xcode and let automatic signing obtain the matching provisioning profiles. Personal development teams cannot provision iCloud. The project uses team `CNBB6EET8T` and app identifiers `ch.hivenet.twitchy-macos`, `ch.hivenet.twitchy-ios`, and `ch.hivenet.twitchy-tvos`. The XcodeGen template explicitly preserves these identifiers. Unsigned and simulator builds keep the app usable locally and display the sync limitation in Settings.

The private database uses zone `TwitchyPersonal`, record type `TwitchyValue`, and an encrypted Bytes field named `value`. Development CloudKit initializes the schema when records are saved. Before TestFlight or production distribution, deploy this schema to Production in CloudKit Console. Do not create `value` as an unencrypted field; Apple does not allow converting existing plain fields to encrypted fields.

Sync includes:

- Sources, source bearer tokens and selected source. Imported tokens enter the source-only Keychain.
- Every playback, chat and appearance preference, public OAuth application settings, recent searches and onboarding state.
- Watch entries including VOD/clip resume positions and actual viewing sessions across devices.
- Short-lived Apple TV live-stream presence for the iPhone Companion Mode (TV name, channel login/name and broadcaster ID).

Twitch access/refresh tokens, chat messages and downloaded media/indexes remain on each device. Offline downloaded paths and source health data cannot be transferred meaningfully to another device.

When a source uses localhost, that address still means the receiving device. Configure a reachable HTTPS source or private network address for cross-device playback. Sync cannot make an unavailable server reachable.

Mutations queue in an AES-GCM encrypted local journal and retry automatically; the Settings screen displays sync status and provides Sync now. The same private Apple account must be active on each device. Sync pauses if the Apple account changes, retaining the previous account's local data without uploading it into the new account. A new Apple account requires a separate local app data installation; there is no account-switch migration UI yet.

## Validation

Automated tests cover two independent devices, encrypted journal persistence, source credential import and deletion, disjoint offline preference edits, additive viewing sessions, offline restart, seed/server precedence, deletion tombstones, history clearing and Apple-account separation. Helix batching and separate VOD positions are also tested. These tests use an injected deterministic cloud transport; they do not prove Apple CloudKit provisioning or a real multi-device round trip.

The maintainer reported successful iCloud sync and launches on their devices on 2026-10-10. That report does not establish every merge/deletion scenario below. For independent verification with your own team/container: add an authenticated reachable source on Mac, sign in to Twitch separately on iPhone/iPad/Apple TV, confirm source playback on each, watch different channels offline, reconnect, check merged interests/resume positions, then remove a test source and confirm deletion on peers. Also check Production schema after deployment.

Legacy favorite records remain readable for storage compatibility, but favorites are no longer exposed in any client.

## iPhone and Mac Companion Mode

On iPhone Home, tap the TV icon beside Settings. On Mac, use the TV icon beside Settings at the bottom of the sidebar; Companion Mode fills the window until you select Done. The full-screen view waits with “Start a stream on your TV” until Twitchy on Apple TV reports an active live playback session. It then opens that channel’s chat with a composer, using the companion device’s own Twitch account and chat permissions. Enable chat from inside this view if needed. Videos, clips, failed playback and channel browsing do not advertise a live session. Multiple active TVs can be selected from the TV menu.

Both devices require signed iCloud-capable builds and the same iCloud account. Apple TV publishes an encrypted per-device presence record every 10 seconds while active; the open companion view checks every 5 seconds. Switches and stops propagate through CloudKit, so updates can take several seconds and depend on network availability. Presence expires after 60 seconds without a heartbeat, including when the TV app terminates before sending its stop record. No Twitch credentials or chat messages are included in presence records. The companion uses a separate chat connection and does not start video playback on the companion device.

Tests validate presence transfer, heartbeat refresh, stop tombstones, invalid records and expiration using a fake transport, plus waiting/full-screen chat/composer/dismissal with simulator fixtures. Live CloudKit discovery and sending a Twitch message require a real signed Apple TV and iPhone; simulator fixtures do not exercise those services.
