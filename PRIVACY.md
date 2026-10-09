# Privacy

No telemetry, analytics, advertising SDK or custom Twitchy account exists.

Twitch receives OAuth requests, token validation/revocation, official Helix queries, EventSub subscriptions and chat messages. Apple system authentication handles the sign-in browser. Twitch avatars/thumbnails/badges/emotes load from URLs returned by Twitch or its official emote CDN. Their servers receive normal network request metadata.

Your configured streaming source receives capability/health queries, requested channel/video IDs, quality preferences, independently authorized download requests and its own source authentication. It never receives Twitch OAuth access tokens, refresh tokens or client secrets. Signed playback URLs may point to media hosts selected by that source, which receive normal media requests. Review your source operator's policies.

Locally stored JSON: public OAuth Client IDs/redirect preference (UserDefaults), source URLs/names/capabilities/status, selected source, appearance/player/chat preferences, favorites, up to 100 watched channels and 20 recent searches, and download metadata including permission references. Locally downloaded MP4 files remain in Application Support/Twitchy/Downloads. Device-only Keychain holds account/source secrets. Chat retains at most 300 recent messages in memory, never on disk.

No CloudKit sync is currently enabled. iCloud sign-in is unnecessary. Clearing history, removing favorites/sources, deleting downloads and signing out are supported in the app. Uninstalling may leave platform-managed Keychain or Application Support entries; remove local app data separately if desired. The planned optional sync design is documented but collects/synchronizes nothing today.

The default browser OAuth return page is hosted on GitHub Pages. GitHub receives normal HTTPS hosting request metadata (including IP address). Twitch's access token is in the URL fragment, which is not sent to the hosting server. The page forwards that fragment directly to the native app and makes no external script/analytics requests or token-storage calls. Public Device Flow uses Twitch's activation page instead and does not need this hosted callback.
