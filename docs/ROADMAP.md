# Roadmap

Twitchy is a development source release. This list distinguishes remaining work from existing implementations; see the [README](../README.md) for features and [verification history](VERIFICATION.md) for dated checks.

## Before a production release

- Complete real-account Twitch consent, login/logout/refresh, profile/follows/search and missing-scope checks.
- Exercise EventSub receive/send, migration, keepalive timeout, revocation, moderation deletes and reconnection with live accounts.
- Verify the app with the separate [Twitchy Server](https://github.com/rafaelreverberi/twitchy-server): trusted HTTPS, media expiry, long ad pauses, interruptions and server fallback on real devices.
- Validate PiP, audio/lifecycle, Siri Remote focus, accessibility and energy on physical iPhone, iPad, Mac and Apple TV.
- Verify signed cross-device iCloud sync and iPhone Companion Mode with Apple TV. CloudKit and Companion Mode have implementations; this is remaining integration validation.
- Review distribution requirements and prepare signing, notarization and release packaging.

## Next client iteration

- Improve inline emote wrapping and animated variants.
- Add optional subscription UI and chat moderation event removal.
- Add resizable layouts and a separate macOS chat window.
- Strengthen deterministic WebSocket transport tests.

## Later

- Background and resumable downloads with storage and concurrency controls.
- Optional 7TV/BTTV/FFZ integration.
- Ongoing source-status events beyond v1 session creation.

Channel VOD/clip pagination, local history and recommendations, offline-aware navigation, private CloudKit sync, and automatic source fallback already have implementations. Direct Twitch video extraction remains outside the Apple client.
