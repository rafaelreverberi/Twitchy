# Verification — 2026-10-09

Local development environment: Xcode 27.0 (27A266a), Apple Swift 6.4, macOS/iOS/tvOS SDKs 27.0; Apple Silicon host. Minimum targets: macOS 14, iOS/iPadOS/tvOS 17. XcodeGen generated the committed project; generation is not required to open it. No distribution signing, provisioning, notarization or release upload was performed.

| Check | Actual outcome | Limit |
|---|---|---|
| Swift package tests plus explicit localhost mock integration | **33 tests passed** | 28 service tests and 5 fixture integration tests; six URL cases in a parameterized service test |
| macOS application build | **Passed** | Native app launched and inspected with Accessibility/screenshot automation |
| iOS/iPadOS application build | **Passed** | Generic simulator build, including arm64/x86_64 simulator compilation |
| iPhone 18 Pro, iOS 27 UI test | **Passed** | Onboarding, five tabs and OAuth Settings access; no real account |
| iPad Pro 13-inch (M5), iOS 27 UI test | **Passed** | Sidebar destinations and Settings; real screenshot exported from XCTest |
| tvOS application build | **Passed** | SDK available, tvOS runtime/device unavailable; no remote interaction proof |
| macOS XCTest UI runner | **Failed before test bootstrap** | Runner killed before establishing connection, with unsigned and ad-hoc-signed attempts; direct native UI inspection succeeded separately |
| Later combined iPhone + iPad UI rerun | **No usable result; stopped** | Simulator test launch stalled, then Xcode log-finalization diagnostics; earlier individual passes remain separate evidence |
| OpenAPI 3.1 | **Passed** | Full openapi-spec-validator validation plus JSON/reference check |
| Git whitespace and targeted secret/path audit | **Passed** | No credentials, provisioning assets or developer-specific paths in project configuration |
| GitHub Actions | **Not run remotely** | Workflow prepared; repository remains local |

Fixture integration covers real HTTP health/capabilities, playback creation/cleanup, authorization rejection, MP4 transfer, persisted download restoration/deletion, retrying a failed local transfer, and AVPlayer reaching readyToPlay with a generated HLS fixture. The fixture contains no Twitch video. This establishes native HLS loading, not a real live Twitch stream, sustained playback, PiP on hardware, or rights to distribute third-party content.

Service tests cover official JSON decoding/pagination, emote/badge image wire keys, OAuth state/callback verification, identity/expiry/revocation validation, rotating Device Flow refresh tokens without a client secret, in-flight validation after logout, fake Keychain storage, source URL policy/persistence/switching and credential isolation, authenticated source URL changes, capabilities/session/error models, download failure states and cross-source cancellation, offline/HTTP errors, safe GET retries and respecting long rate-limit windows, EventSub envelopes/Unicode/reconnect URL policy and backoff, preferences/history/search persistence and absence of a direct video fallback.

EventSub socket migration keeps the old socket draining until the replacement welcome and deduplicates messages. This is implemented but not tested against a real Twitch WebSocket session; current reconnect tests cover decoding and policy, not full live transport behavior. Browser OAuth's owned HTTPS return bridge and public Device Flow registration also remain account-level integration work.

## Reproduce

```sh
./scripts/build.sh
./scripts/test.sh
# Individual simulator UI runs are preferred over a combined destination invocation:
xcodebuild -project Twitchy.xcodeproj -scheme Twitchy-iOS -destination 'platform=iOS Simulator,name=iPhone 18 Pro' CODE_SIGNING_ALLOWED=NO test
xcodebuild -project Twitchy.xcodeproj -scheme Twitchy-iOS -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' CODE_SIGNING_ALLOWED=NO test
```

Device names are from this host; use `xcrun simctl list devices available` on another machine. Running `swift test` without TWITCHY_MOCK_URL skips the five network/native fixture tests intentionally. `scripts/test.sh` starts its own isolated localhost fixture on port 18181, runs all tests and stops it.

OpenAPI full-validator reproduction (optional development tool; no app runtime dependency):
```sh
python3 -m venv .build/contract-validator
.build/contract-validator/bin/pip install openapi-spec-validator
.build/contract-validator/bin/python -c 'from openapi_spec_validator import validate_spec; import json; validate_spec(json.load(open("docs/SERVER_API.json")))'
```

## Remaining acceptance work

The core client is implemented and builds; the entire master prompt is not asserted as a completed production release. Real Twitch login, callback registration, Device Flow polling/refresh, account metadata and chat receive/send/revocation/migration need real credentials and consent. A production source is needed for actual live playback, signed media expiry and source interruption recovery. Apple TV runtime, physical-device PiP/audio/lifecycle, performance/accessibility, distribution approval, signing/notarization and remote CI remain unverified. CloudKit, background/range-resumable downloads, some customization and advanced chat polish are explicitly planned in the feature matrix rather than reported as complete.
