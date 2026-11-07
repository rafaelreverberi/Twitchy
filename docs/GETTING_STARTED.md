# Getting started

Twitchy is available as source code for iPhone, iPad, Mac and Apple TV. Build the app on a Mac, sign in with Twitch, then connect a streaming source for video. There is no downloadable app release yet.

## 1. Build the app

```sh
git clone https://github.com/rafaelreverberi/Twitchy.git
cd Twitchy
open Twitchy.xcodeproj
```

Choose `Twitchy-macOS`, `Twitchy-iOS` (also iPad), or `Twitchy-tvOS`. For device signing and optional iCloud sync, follow [Self-build setup](SELF_BUILD.md).

Use Xcode 27.0 / Swift 6.4 or a compatible newer toolchain with all required Apple SDKs. Open `Twitchy.xcodeproj` directly; local Swift package products resolve automatically. There are no remote Swift packages. The iOS target supports both iPhone and iPad. Select a platform scheme, choose a simulator or signing team for a physical device, and Run.

Deployment minimums: iOS/iPadOS/tvOS 17.0, macOS 14.0. Build without distribution signing:
```sh
./scripts/build.sh
```

## 2. Sign in and connect a source

In onboarding, open **Set Up Twitch Connection**, register a Public application and save its Client ID. Then choose **Sign in with Twitch** and confirm access on Twitch. The Client ID syncs through private iCloud on provisioned builds. Authorize Twitch on each device. See [Twitch authentication](TWITCH_AUTH.md). Without login the screens remain navigable, but official Helix browsing needs a user token. Without a source, playback shows an actionable setup state. Chat does not use the source.

For a real streaming source, follow [Sources](SOURCES.md). The optional [Twitchy Server](https://github.com/rafaelreverberi/twitchy-server) provides self-hosted HLS and server-side ad filtering; the app itself does not filter ads. Use the server's [setup guide](https://github.com/rafaelreverberi/twitchy-server/blob/main/docs/SETUP.md) for Docker and HTTPS.

On Apple TV, open Settings → Sources. On the other platforms, use Profile → Settings → Sources. Your Twitch login and source bearer token are separate credentials.

## Troubleshooting

| Symptom | Check |
| --- | --- |
| No channels load | Sign in with Twitch; discovery requires a token. |
| A channel opens but video cannot start | Add, check and select a compatible source. Twitch login alone does not provide video. |
| Server works on Mac but fails on another device | Replace `localhost` with an address that device can reach. Set the server's `PUBLIC_BASE_URL` to that address too. |
| Source authentication fails | Use the independent server token, not your Twitch token. |
| Device signing or iCloud fails | Configure your own team, Bundle IDs and CloudKit container in [Self-build setup](SELF_BUILD.md). |
| Video buffers during marked ads | The optional server can pause output during filtering. See its [ad-handling guide](https://github.com/rafaelreverberi/twitchy-server/blob/main/docs/ADBLOCK.md). |

## Developer fixture (no real Twitch video)
```sh
python3 MockServer/server.py --port 8181
```
Add `http://localhost:8181`, enable local-development HTTP, save, test and select it. Simulator and Mac can reach the host loopback. A physical device's localhost refers to itself; the mock intentionally binds loopback only, so use a real HTTPS source for physical devices.

The bundled six-second H.264/AAC fixture is generated locally, contains a solid dark image and a tone, and carries no Twitch footage. This server is a test harness, not a streaming backend for regular viewing. It advertises live playback to exercise the client but returns only this finite fixture. In Downloads enter content ID `fixture` and permission reference `fixture-owner` to exercise transfer; any other permission is rejected. For HLS playback via the app you can open any channel detail after Twitch sign-in; automated service tests avoid needing Twitch entirely.

```sh
TWITCHY_MOCK_URL=http://localhost:8181 swift test --package-path Packages/TwitchyKit
```
Stop the mock with Ctrl-C. Optional regeneration requires FFmpeg:
```sh
ffmpeg -f lavfi -i 'color=c=0x18181B:s=640x360:r=24:d=6' -f lavfi -i 'sine=frequency=440:duration=6' -c:v libx264 -pix_fmt yuv420p -c:a aac -shortest -movflags +faststart MockServer/media/fixture.mp4
ffmpeg -i MockServer/media/fixture.mp4 -c copy -hls_time 2 -hls_playlist_type vod MockServer/media/fixture.m3u8
```

XcodeGen is needed only when editing project.yml: run `xcodegen generate` and commit the generated Xcode project and plists together. Tests are under Packages/TwitchyKit/Tests and Tests/UI. UI tests use local ad-hoc signing on macOS; distribution signing and notarization are separate.
