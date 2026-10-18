# Twitchy documentation

Build the native Apple app, sign in with Twitch, then connect a compatible source for video. The optional [Twitchy Server](https://github.com/rafaelreverberi/twitchy-server) supplies HLS and server-side ad filtering.

## Start here

| Guide | Use it for |
| --- | --- |
| [Getting started](GETTING_STARTED.md) | Clone, build, sign in, connect, and troubleshoot. |
| [Self-build setup](SELF_BUILD.md) | Your signing team, app identifiers and device provisioning. |
| [Streaming sources](SOURCES.md) | URLs, bearer tokens, health checks and automatic fallback. |
| [Twitch authentication](TWITCH_AUTH.md) | Device sign-in and custom OAuth configuration. |
| [iCloud sync](ICLOUD_SYNC.md) | Your CloudKit container and private sync. |
| [Known limitations](LIMITATIONS.md) | Feature and verification boundaries. |

## Platform and feature guides

[Mac interface](MACOS_INTERFACE.md) · [Apple TV interface](TVOS_INTERFACE.md) · [iPhone playback](IPHONE_PLAYBACK.md) · [Chat](CHAT.md) · [Roadmap](ROADMAP.md)

## Development

[Architecture](ARCHITECTURE.md) · [Source API](SERVER_API.md) · [OpenAPI](SERVER_API.json) · [Design system](DESIGN_SYSTEM.md) · [App icons](APP_ICONS.md) · [Performance](PERFORMANCE.md) · [Verification history](VERIFICATION.md) · [Offline download regression](OFFLINE_DOWNLOAD_REGRESSION.md)

Run `./scripts/test.sh` from the repository root for service and fixture checks, and `./scripts/build.sh` for all three app targets. See [Contributing](../CONTRIBUTING.md), [Security](../SECURITY.md), and [Privacy](../PRIVACY.md).

## Optional Twitchy Server

[Repository](https://github.com/rafaelreverberi/twitchy-server) · [Setup](https://github.com/rafaelreverberi/twitchy-server/blob/main/docs/SETUP.md) · [Adblock behavior](https://github.com/rafaelreverberi/twitchy-server/blob/main/docs/ADBLOCK.md) · [Server verification](https://github.com/rafaelreverberi/twitchy-server/blob/main/docs/VERIFICATION.md)

The server is a separate project. Its recognized-ad filtering can pause playback and does not guarantee an uninterrupted, ad-free stream. Twitchy itself performs no ad filtering.
