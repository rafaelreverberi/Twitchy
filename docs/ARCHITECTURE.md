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

Persistence uses native atomic Codable JSON under Application Support/Twitchy. Personal preferences, favorites, bounded history and searches are local. Source metadata stores the active UUID and discovery results; credentials never enter JSON. Downloads store metadata beside local files. No iCloud login is needed.

## Optional synchronization design (not active)
A future CloudKit private database adapter can sync application-owned favorites/source display configuration/preferences/watch positions using per-record stable UUIDs, modifiedAt, record change tags and deletion tombstones. Fetch before conditional saves; merge disjoint field edits, use last modification timestamp as a documented fallback for same-field conflicts, retain server change tags and retry CKError.serverRecordChanged. Sources should sync only non-sensitive configuration, never credentials. Mark device-origin changes so incoming records do not form loops. Account follows remain authoritative on Twitch. Download files/metadata and Keychain entries stay local. If iCloud is absent or CloudKit unavailable, queue a bounded local change log and keep the local app usable. No current CloudKit capability/entitlement is enabled.
