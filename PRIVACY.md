# Privacy

No telemetry, analytics, advertising SDK or custom Twitchy account exists.

Twitch receives OAuth requests, token validation/revocation, official Helix queries, EventSub subscriptions and chat messages. Apple system authentication handles the sign-in browser. Twitch avatars/thumbnails/badges/emotes load from URLs returned by Twitch or its official emote CDN. Their servers receive normal network request metadata.

Your configured streaming source receives capability/health queries, requested channel/video IDs, quality preferences, manual download requests (with a permission reference for sources that require one) and its own source authentication. It never receives Twitch OAuth access tokens, refresh tokens or client secrets. Signed playback URLs may point to media hosts selected by that source, which receive normal media requests. Review your source operator's policies.

Locally stored JSON: public OAuth Client IDs/redirect preference (UserDefaults), source URLs/names/capabilities/status, selected source, appearance/player/chat preferences, favorites, up to 100 watched items and 2,000 viewing sessions and 20 recent searches, and download metadata including permission references. Locally downloaded MP4 files remain in Application Support/Twitchy/Downloads. Device-only Keychain holds account/source secrets. Chat retains at most 300 recent messages in memory, never on disk.

In a build provisioned for iCloud, Twitchy automatically syncs source configuration and source bearer tokens, selected source, preferences, favorites, recent searches, onboarding state, watch positions and viewing sessions through the private CloudKit database of your Apple account. CloudKit record fields use on-device encryption (`CKRecord.encryptedValues`). The local offline sync journal is AES-GCM encrypted with a device-only Keychain key. Source tokens imported from iCloud are stored in the separate source Keychain. Twitch OAuth access/refresh tokens, chat messages and downloaded files/metadata do not sync. Public Twitch application IDs and redirect settings sync; the OAuth login itself remains device-local.

Viewing sessions record channel login, timestamps and actual playing seconds. Twitchy ranks watched channels by minutes viewed plus five points per viewing session and requests their current live status from Twitch. It does not transmit history or interest scores to Twitch or a separate recommendation service.

Without iCloud or a properly provisioned build, the app continues locally and retains queued changes. The Settings screen displays sync availability and last successful sync. Changing Apple accounts pauses sync to avoid copying the previous account's data into the new account. Clearing history and removing favorites/sources produce synced deletion markers. Uninstalling may leave platform-managed Keychain or Application Support entries; remove local app data separately if desired.

The default browser OAuth return page is hosted on GitHub Pages. GitHub receives normal HTTPS hosting request metadata (including IP address). Twitch's access token is in the URL fragment, which is not sent to the hosting server. The page forwards that fragment directly to the native app and makes no external script/analytics requests or token-storage calls. Public Device Flow uses Twitch's activation page instead and does not need this hosted callback.

## Self-built copies and source operators

The public GitHub repository contains application code and setup identifiers, not users' Keychain entries, CloudKit records or local history. For independently provisioned builds, use your own Apple team and CloudKit container; see [self-build setup](docs/SELF_BUILD.md). The original maintainer does not operate the user-configured streaming source. A source operator can observe playback/download requests and must provide its own applicable privacy information. A developer who distributes a modified app or operates a backend must assess their own data-processing responsibilities.
