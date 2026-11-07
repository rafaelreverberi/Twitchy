# Sources and playback order

**Sources → + → Add Source** offers two kinds:

| Type | Configuration | Playback | New downloads |
|---|---|---|---|
| Twitch Proxy | User-entered base URL or `{channel}` HLS URL template | Native AVPlayer, live only | No |
| Twitchy Server | Source API v1 base URL; optional independent access token | Native AVPlayer with source sessions, supported live/VOD/clips | Only when connected and capable |

Open **Profile → Settings → Sources** on Mac/iPhone/iPad or **Settings → Sources** on Apple TV. Press Add/plus, select the type, configure and save. Move Up/Down changes priority; selecting an entry moves it to the top. Disabled entries are skipped. For example: **Server A → Server B → custom proxy**. Proxies are not automatically forced behind servers: the displayed user order is authoritative.

Type, public configuration, enablement and order sync through private encrypted iCloud records. Each source retains a stable UUID; server credentials sync only in the existing encrypted path and enter the destination Keychain. Health/test results remain local. Legacy server files decode as Twitchy Servers and preserve the previously preferred source at the top. A preceding Advanced-only custom proxy is migrated into this list once. Device provisioning is required for actual CloudKit transport; fixture tests verify the merge/order behavior separately.

Older embedded-player entries are ignored when loading saved sources or receiving iCloud records. Other sources retain their configuration and relative priority.

## Custom proxy

The app includes no public endpoint list or recommended public default. Enter only an address whose operator permits your use. **Automatic** accepts a Luminous-compatible base URL (a missing scheme becomes HTTPS), or chooses direct HLS when the address contains `{channel}`. Explicit contract choices are available when needed. Generic HTTP/SOCKS forward proxies are not supported.

Examples for your own service:

- Base URL: `https://your-host.example/prefix` → `/prefix/live/{channel}?allow_source=true&allow_audio_only=true`.
- Direct template: `https://your-host.example/playlist?login={channel}&mode=live`.

Public query parameters and deployment prefixes are retained. Channels are normalized and validated. Credentials/fragments and unsafe endpoints are rejected; public HTTPS uses ordinary certificate verification. Local HTTP requires explicit development trust and the existing private-host URL policy. The proxy receives no Twitch/server authentication. Short-lived media signatures are kept only in memory.

Enter a currently live channel and use **Test Connection**. It checks master/media and one child manifest, not every segment or actual playback. A proxy 404 can mean a wrong login or provider/upstream failure; it is not sufficient proof that Twitch content is offline. The November 3 investigation found `letshugotv` is the relevant LetsHugo Twitch login; `letshugo` returned 404. See [dated measurements](PROXY_RESEARCH.md), which are research observations rather than endorsements.

## Twitchy Server and downloads

Use a backend implementing [Source API v1](SERVER_API.md), such as the separate [Twitchy Server](https://github.com/rafaelreverberi/twitchy-server). Credentials are independent of Twitch sign-in. HTTPS is required outside explicitly trusted local development. Server URL paths are preserved. Server sessions negotiate capabilities, use native quality/state semantics and DELETE cleanup/expiry. Sources cannot borrow one another’s credentials or redirect authenticated control requests to a third party.

A newly requested download is enabled only for a currently connected capable Twitchy Server, and never while the active playback provider is a proxy. The UI explains this restriction on iPhone/iPad/Mac. Existing downloads and local/offline playback remain usable; existing transfers retain their original source identity. Apple TV has no download interface.

## Recovery and boundaries

Server probes are bounded; source session creation retains existing timeouts/capability negotiation. Recoverable server failures and proxy resolution failures advance through the displayed order. Source authentication/permission/offline errors remain terminal. Item/startup/stall recovery excludes previously failed provider UUIDs within a bounded chain. New requests and explicit Retry start normal priority again. A recovered earlier source never interrupts an already working fallback.

[Implementation and limitations](PROXY_FALLBACK.md) describe cancellation, validation and native playback. Twitchy is an independent client, not an ad blocker, proxy operator or legal approval. Only configure permitted services/content. No anonymity, continuous availability or ad-free experience is promised.
