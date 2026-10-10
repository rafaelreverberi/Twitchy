# Architecture

The committed Xcode project contains three application targets and a macOS UI-test target. Seven Swift package modules provide strict Swift 6 boundaries:

| Module | Responsibility | Dependencies |
|---|---|---|
| TwitchyCore | HTTP transport, retry/errors, Keychain protocol, personal persistence | Apple frameworks |
| TwitchyAPI | Typed official Helix endpoints, pagination, cache | Core |
| TwitchyAuth | Browser/device OAuth, token validation and refresh | Core |
| TwitchySources | v1 contract models, URL policy, source client/manager | Core |
| TwitchyPlayback | AVPlayer session lifecycle and local downloads | Core, Sources |
| TwitchyChat | EventSub and Send Chat orchestration | Core, API |
| TwitchyDesignSystem | Shared SwiftUI tokens/components | SwiftUI |

Apps/Shared composes these modules through an observable main-actor AppModel. Network services use async/await, an actor Helix client and Sendable typed results. Views own cancellable discovery/search tasks; search waits 350ms and checks cancellation/stale queries. Long-lived chat, auth and downloads expose explicit cleanup. URLSession is reused by each client; Helix GET cache is bounded at 100 URLs / 30 seconds. Models remain value types.

Account path: system auth → Twitch /validate → Twitch-only Keychain → Helix/EventSub. Video path: Sources settings → source-only Keychain → health/capabilities → source session → AVPlayer → DELETE cleanup. Download path: independently authorized source job → source file endpoint → UUID local MP4 → local index/offline AVPlayer. There is no dependency from Sources/Playback to Auth or API.

Persistence uses native atomic Codable JSON under Application Support/Twitchy. Source metadata stores the active UUID and discovery results; credentials never enter plaintext JSON. Downloads store metadata beside local files. Watch entries use channel/content identifiers; individual viewing sessions store real playing duration independently from resume position.

## iCloud synchronization
`CloudSyncStore` in Core provides a persisted encrypted replica and an injectable transport. `PrivateCloudTransport` uses the private CloudKit database, custom `TwitchyPersonal` record zone and `TwitchyValue` records. Record names are SHA-256 hashes of stable logical keys; the envelope (key, payload, modification time, revision) is stored only in the encrypted `value` field. New records use the same schema across all three bundle identifiers through container `iCloud.ch.hivenet.twitchy`.

`AppDataSync` in Sources maps each preference field, favorite, watch entry, viewing session and source into its own record. Source credentials accompany portable source configuration, then enter the destination source Keychain. Device-specific source health/capabilities stay local. Twitch OAuth sessions and downloads stay local. The replica file is AES-GCM sealed with a device-only Keychain key; it contains no plaintext credentials. Existing local records seed missing cloud values without replacing existing server values.

Fetch before conditional saves. Last modification time wins same-record conflicts, with a revision tie-breaker; CloudKit change tags protect races and `serverRecordChanged` retries fetch/reconcile up to three times. Independent viewing session UUIDs merge duration from multiple devices without double counting. Nil payloads are tombstones; clearing history also records a timestamp cutoff to suppress older unseen entries. Incoming changes bypass mutation callbacks to avoid sync loops. Offline mutations survive restarts and retry after edits, foreground entry and every 45 seconds while running. An Apple-account identity binding pauses synchronization after an account switch. A missing entitlement, offline account or server error leaves local behavior available and is visible in Settings.

Home queries up to 100 highest-interest channel logins through Helix, combines those live results with followed/popular streams, deduplicates and ranks by watched minutes plus five points per viewing session. Only actual playback contributes; paused/buffering time and seek positions do not. See [ICLOUD_SYNC.md](ICLOUD_SYNC.md) for Apple provisioning and validation boundaries.
