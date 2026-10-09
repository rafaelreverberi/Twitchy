# Roadmap

## Before a production release
- Register browser and public Device Flow apps; test callback compatibility, real login/logout/refresh, profile/follows/search and missing scopes.
- Exercise EventSub receive/send, migration, keepalive timeout, revocation, moderation deletes and reconnection with Twitch CLI/live accounts.
- Build the independent Go/Docker source against SERVER_API.json; test trusted HTTPS, HLS expiry, interruptions, permission enforcement and TTL cleanup.
- Validate native playback, PiP, audio/lifecycle, remote focus, accessibility and energy on physical iPhone, iPad, Mac and Apple TV.
- Review Twitch content/player/advertising and distribution requirements; add signing/notarization and release packaging only after approval.

## Next client iteration
Account-aware persistent metadata cache; VOD/clip pagination; improved inline emote wrapping/animated variants; optional subscription UI; chat moderation event removal; resizable layouts and separate macOS chat window; stronger deterministic socket transport tests.

## Later
Background/resumable authorized downloads with storage/concurrency controls; optional conflict-aware CloudKit sync; opt-in 7TV/BTTV/FFZ modules; source status-event contract extension. Never add direct Twitch extraction as a fallback.
