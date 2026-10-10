# Getting started

Use Xcode 27.0 / Swift 6.4 or a compatible newer toolchain with all required Apple SDKs. Open `Twitchy.xcodeproj` directly; local Swift package products resolve automatically. There are no remote Swift packages. The iOS target supports both iPhone and iPad. Select a platform scheme, choose a simulator or signing team for a physical device, and Run.

Deployment minimums: iOS/iPadOS/tvOS 17.0, macOS 14.0. Build without distribution signing:
```sh
./scripts/build.sh
```

The app begins with onboarding. Choose Sign in with Twitch; confirm access on Twitch and return to the app. The bundled Client ID requires a Public registration; see TWITCH_AUTH.md. Custom application configuration is under Profile → Settings → Advanced. Without login the screens remain navigable, but official Helix browsing needs a user token. Without a source, playback shows an actionable setup state. Chat does not use the source.

## Deterministic mock fixture
```sh
python3 MockServer/server.py --port 8181
```
Add `http://localhost:8181`, enable local-development HTTP, save, test and select it. Simulator and Mac can reach the host loopback. A physical device's localhost refers to itself; the mock intentionally binds loopback only, so use a real HTTPS source for physical devices.

The bundled six-second H.264/AAC fixture is generated locally, contains a solid dark image and a tone, and carries no Twitch footage. This server is a test harness, not the planned production backend. It advertises live playback to exercise the client but returns only this finite fixture. In Downloads enter content ID `fixture` and permission reference `fixture-owner` to exercise transfer; any other permission is rejected. For HLS playback via the app you can open any channel detail after Twitch sign-in; automated service tests avoid needing Twitch entirely.

```sh
TWITCHY_MOCK_URL=http://localhost:8181 swift test --package-path Packages/TwitchyKit
```
Stop the mock with Ctrl-C. Optional regeneration requires FFmpeg:
```sh
ffmpeg -f lavfi -i 'color=c=0x18181B:s=640x360:r=24:d=6' -f lavfi -i 'sine=frequency=440:duration=6' -c:v libx264 -pix_fmt yuv420p -c:a aac -shortest -movflags +faststart MockServer/media/fixture.mp4
ffmpeg -i MockServer/media/fixture.mp4 -c copy -hls_time 2 -hls_playlist_type vod MockServer/media/fixture.m3u8
```

XcodeGen is needed only when editing project.yml: run `xcodegen generate` and commit the generated Xcode project and plists together. Tests are under Packages/TwitchyKit/Tests and Tests/UI. UI tests use local ad-hoc signing on macOS; distribution signing and notarization are separate.
