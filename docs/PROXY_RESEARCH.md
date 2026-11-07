> Historical investigation. See [current source options](SOURCES.md).

# Public proxy investigation — 2026-11-03

## Decision

**No public endpoint is enabled or shipped as a built-in default.** Luminous EU (`https://eu.luminous.dev/live/{channel}?allow_source=true&allow_audio_only=true`) is the strongest **technical candidate**, but permission to bundle its public infrastructure as the automatic fallback of this independently distributed app has not been established. Do not mistake the successful tests below for operator authorization or Twitch approval. The requested fail-closed exception applies. `DefaultProxyConfiguration.verified` is `nil`; the app provides a custom proxy path and an honest unavailable-default explanation.

No provider rotation list is included in application code. A custom proxy replaces the default completely. Before activating one default, obtain/review operator permission and limits, evaluate Twitch distribution requirements, repeat the tests, and validate the remaining Apple-device lifecycle cases.

## Sources and interface audit

- [Luminous upstream](https://github.com/AlyoshaVasilieva/luminous-ttv), [route implementation](https://github.com/AlyoshaVasilieva/luminous-ttv/blob/1caa3c7438f53d5a1e589c4291418c982154c9d4/src/main.rs): playlist resolver with `/live/{id}` and `/vod/{id}`, not a Source API v1 server or a segment-relay guarantee. Latest upstream commit seen through GitHub API: `1caa3c7438f53d5a1e589c4291418c982154c9d4`, 2026-05-27. Its README labels status uncertain and describes geographical ad avoidance; those are operator/project claims, not independently verified ad guarantees.
- [TTV LOL PRO V1 public proxy documentation](https://wiki.cdn-perfprod.com/v1/must-read/proxies) lists Luminous EU and PerfProd. The upstream Luminous software license does not itself authorize use of a hosted service. The public listing does not settle permission or quotas for bundling the service in Twitchy.
- [PerfProd FAQ](https://wiki.cdn-perfprod.com/must-read/faq) requires contacting the operator for third-party app use. No permission was requested or obtained in this task; no restricted playback probes were made. V2 is a browser-forward-proxy architecture, not a direct HLS API. [V1 status page](https://status.cdn-perfprod.com/) was reachable and showed European endpoints; status/uptime is not playback evidence. [Troubleshooting](https://wiki.cdn-perfprod.com/guides/extension/troubleshooting) describes public infrastructure limitations.
- [Nadeko operator announcement](https://github.com/younesaassila/ttv-lol-pro/discussions/37): Luminous-compatible endpoint `https://twitch.nadeko.net/live/{channel}`. Root replied “Twitch Albania Proxy for TTVLOL V1”; no independent app-distribution terms/SLA were established.
- [level3tjg release announcement](https://github.com/level3tjg/TwitchAdBlock/releases): publicly offered `https://luminous.level3tjg.me`, distinguished from its generic HTTP proxy. Tested the documented Luminous route; rejected on functional results.
- [Twitch terms](https://legal.twitch.com/en/legal/terms-of-service) and [developer agreement](https://legal.twitch.com/en/legal/developer-agreement/) were reviewed. Public technical access is not permission to redistribute video, interfere with advertising, bypass restrictions, or claim Twitch endorsement. This report is not a legal clearance.

## Environment and method

Tests ran from the available Apple-silicon macOS host/network. Geographic origin and routing were **not independently established**; no Swiss latency claim is made. Client date: 2026-11-03, Europe/Zurich. Normal TLS validation, no OAuth, source credentials, special browser headers, cookies, authentication bypass, or rate-limit bypass. Requests were bounded to 12 seconds and sample downloads to 4 MB. No 429 was observed; absence of 429 does not establish a quota.

Initial lightweight probes tested `monstercat`, `lck`, `shroud`, and `piratesoftware`. The first three returned upstream 404 responses on Luminous EU/Nadeko; those results were not counted as service outages or proof that the channels were live. Later requests found HLS on `gaules`, `tarik`, and `forsen`. Only actual HLS successes established usable streams; search-engine “live” labels were not relied on.

The repeatable final sample used three confirmed streams (`piratesoftware`, `gaules`, `tarik`), two rounds each: master → lowest advertised video variant → fMP4 init if present → one current segment → ffprobe. [Sanitized measurements](research/proxy-2026-11-03.jsonl) contain hosts, timings, statuses and codec metadata only. Full manifests, signed URLs, and downloaded media are not committed. Curl timing values are cumulative seconds from request start (DNS, connect, TLS, TTFB, total), not separate stage durations.

```sh
python3 scripts/probe_proxy.py \
  --template 'https://eu.luminous.dev/live/{channel}?allow_source=true&allow_audio_only=true' \
  --channel piratesoftware --channel gaules --channel tarik --rounds 2
```

Run only against a service that permits the test; public infrastructure can change. This script has no built-in endpoint list. It is not called by the app or normal tests.

## Comparison and observations

| Candidate | Bounded observations | Decision |
|---|---|---|
| Luminous EU | Three channels × two rounds: every sampled master, child, init and segment returned 200. Master total 0.424–0.611 s; variant 0.239–0.792 s; segment 0.069–0.291 s. TLS verification passed; zero redirects. Native macOS playback advanced on all three channels. | Best technical candidate; default blocked on permission/distribution and remaining device verification. |
| Nadeko Luminous | `piratesoftware`: master 0.668 s; two audio variants 0.259–0.263 s; segments 0.081–0.287 s; AAC confirmed after joining fMP4 init. Other initial channels returned 404. Normal TLS passed. | Less complete verification; no native or three-channel comparison. Hosted-use permissions unresolved. |
| level3tjg Luminous | Two requests for `monstercat` returned HTTP 525 in 0.496/0.382 s. Client-to-edge TLS passed; the error indicates an upstream/edge failure, not working playback. | Rejected; no HLS available to validate. |
| PerfProd V1/V2 | Primary docs/status reviewed. No playback tests because third-party-use permission is required. V2 is not the required direct-playlist interface. | Not eligible without permission; status is insufficient. |

Luminous EU final measurements: master DNS 2.6–5.5 ms; cumulative connect 12.7–110.5 ms; cumulative TLS 31.7–161.3 ms; TTFB 423–609 ms. Samples are too small to estimate long-term error rates or compare European geographic performance. No sustained buffering, Wi-Fi handoff, overnight continuity or peak-load test was performed. Offered variants included 1080p60, 720p60, 480p, 360p, 160p and audio-only on the inspected channel; availability varies by broadcaster.

Video samples from all three final channels contained H.264 + AAC (284×160 chosen to minimize bandwidth); two also contained timed ID3. The `piratesoftware` rendition used fragmented MP4 with `EXT-X-MAP`. Early bare fragment ffprobe attempts could not identify streams until the init data was included; those attempts were not represented as media-validation successes.

## Native playback

Opt-in `liveProxyNativePlaybackIntegration` uses the real shared coordinator, proxy resolver and `PlaybackController`/AVPlayer, no source configured. It waits for `.playing` **and** a media clock beyond one second, then stops. All three live-channel checks passed: `piratesoftware` 3.938 s, `gaules` 4.094 s, `tarik` 3.380 s (test elapsed times include resolving and polling; not frame-accurate startup latency). Mute was preserved. No credentials were passed.

```sh
TWITCHY_LIVE_PROXY_TEMPLATE='https://eu.luminous.dev/live/{channel}?allow_source=true&allow_audio_only=true' \
TWITCHY_LIVE_PROXY_CHANNEL=piratesoftware \
swift test --package-path Packages/TwitchyKit --filter liveProxyNativePlaybackIntegration
```

This does not establish physical iPhone/iPad/Apple TV behavior, fullscreen/PiP continuity, background transitions or extended stream stability. The test is disabled without explicit environment variables. No ad break was instrumented or independently identified; **advertisement removal remains unverified**.

## Follow-up: mixed sources, LetsHugo and BastiGHG — 2026-11-03

The user requested manually configurable proxies in Sources and an official-player fallback. No proxy list was added to the app. [LetsHugo’s management page](https://ins.gg/creator/letshugo) identifies his Twitch login as **letshugotv**. The initially discussed **letshugo** returned 404 on both tested services; this was not counted as a confirmed live-channel service failure.

[Sanitized follow-up measurements](research/proxy-2026-11-03-followup.jsonl) contain two rounds each for valid target channels, child playlists and video segments, plus the initial incorrect login and the rejected provider. All HTTPS client certificate checks passed; no cookies, OAuth, source tokens or undocumented browser headers were used. The host’s actual geography was not independently established. These are bounded current observations, not long-term monitoring or ad-break verification.

| Manually entered base URL | bastighg | letshugotv | Observed master totals | App contract |
|---|---|---|---|---|
| `https://eu.luminous.dev` | Two complete HLS/video rounds passed | Two complete HLS/video rounds passed | Basti 0.412–0.429 s; Hugo 0.436–0.498 s | Automatic or Luminous |
| `https://twitch.nadeko.net` | Two complete HLS/video rounds passed | Two complete HLS/video rounds passed | Basti 0.564–0.695 s; Hugo 0.558–0.653 s | Automatic or Luminous |
| `https://luminous.level3tjg.me` | HTTP 525, no HLS | Not retried after infrastructure failure | 1.799 s on the Basti request | Not operational in this sample |

Both working services returned actual H.264/AAC video fragments for the two requested live channels (160p was chosen to limit traffic). `liveOrderedProxyNativeIntegration` additionally ran the actual **new ordered-source path** into AVPlayer and required its media clock to advance beyond one second:

- Luminous EU / bastighg: passed, 3.033 s elapsed.
- Luminous EU / letshugotv: passed, 2.740 s elapsed.
- Nadeko / bastighg: passed, 3.043 s elapsed.
- Nadeko / letshugotv: passed, 4.463 s elapsed.

These services can be entered manually for permitted use, with a bare base URL and **Automatic** contract. No generic forward proxy, authenticated proxy, ad removal, geographic origin or service availability guarantee follows from those results. PerfProd was not tested without the third-party-use permission described in its operator FAQ. The project does not operate or promote an ad-blocking proxy network.

The official-player page was previously published on GitHub Pages. The deployment succeeded and HTTPS returned 200. The documented Twitch SDK keeps its iframe, controls and ads visible; native auxiliary controls are outside the image. There is no documented Skip Ads API. tvOS lacks a supported web embed and skips that provider without altering its synced enabled setting. HTTP 200 and SDK contract tests do not alone prove official video playback.


### Final local verification for the mixed-source implementation

- `./scripts/test.sh`: 106 tests completed successfully; public-network cases remain opt-in. Local mock download/AVPlayer checks and OpenAPI JSON/reference validation passed.
- `node scripts/check_official_player.mjs`: input validation, HTTPS parent, SDK quality formats, playback commands and event contracts passed.
- All three application schemes built successfully with `CODE_SIGNING_ALLOWED=NO`: `Twitchy-macOS` (`platform=macOS`), `Twitchy-iOS` (`generic/platform=iOS Simulator`) and `Twitchy-tvOS` (`generic/platform=tvOS Simulator`), each with separate DerivedData.
- iPhone simulator: `testAddSourceOffersAllKindsAndSavesOfficialAndProxyInOrder` passed; existing source selection/edit/check test also passed. The new test saves official/proxy entries and verifies priority changes.
- iPad simulator: opt-in `testOfficialTwitchPlayerLiveIntegration` passed with the real hosted page and `bastighg`, requiring SDK READY plus PLAYING and native pause/resume callbacks. The final expanded test also entered/exited fullscreen and verified resumed playback (40.798 seconds; `Test-Twitchy-iOS-2026.11.03_22-19-16-+0100.xcresult`). This is real WebKit/Twitch playback on a simulator, not physical iPad validation.
- macOS: the ad-hoc Run build played real BastiGHG video. Native pause/resume and entering/exiting fullscreen were checked through accessibility and screenshots; native and Twitch controls reflected resumed playback after each transition. A real Twitch ad countdown was visible before content resumed. No skip or ad-removal claim follows from this observation.
- Fullscreen uses a separate container around the same WebKit view, preventing stale SwiftUI surface teardown from removing the current view. Presentation changes restore previously running playback after WebKit’s detach pause; explicit pause/stop cancels that work. A deliberately paused player is not resumed.
- `git diff --check` passed. The published HTTPS page still returned the bridge marker. Apple UI CI remains opt-in and was not enabled on push.

Reproduce the iPad live test with a currently live channel and an available simulator UUID:

```sh
TEST_RUNNER_TWITCHY_LIVE_OFFICIAL_CHANNEL=bastighg xcodebuild \
  -project Twitchy.xcodeproj -scheme Twitchy-iOS \
  -destination 'platform=iOS Simulator,id=<available-ipad-uuid>' \
  -derivedDataPath .build/proxy-ipad CODE_SIGNING_ALLOWED=NO \
  -only-testing:TwitchyiOSUITests/NavigationTests/testOfficialTwitchPlayerLiveIntegration test
```

Physical iPhone/iPad/Apple TV, Siri Remote focus, prolonged stream continuity, signed distribution and real multi-device CloudKit transport remain unverified. tvOS has SDK build evidence only. Encrypted merge/order tests do not establish production iCloud delivery. The application implementation remains local/uncommitted; only the separately approved bridge/workflow commit was published.
