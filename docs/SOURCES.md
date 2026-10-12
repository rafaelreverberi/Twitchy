# Streaming sources

Open Profile → Settings → Sources. Add a name and HTTPS base URL, optionally enable independent bearer authentication and enter the credential issued by that server. On iPhone/iPad and Mac, tap a server to make it Primary; Edit and Check have separate buttons, and version/capability information, disabling and removal live under Details. Local HTTP is under Advanced in the editor. Removing a source also deletes its Keychain entry. Explicit changes to the preferred server stop the current playback session. Apple TV keeps its existing settings and source screens.

Sources sits above iCloud Sync in Settings. Twitch application configuration is under Advanced, immediately above About.

## Automatic fallback

Twitchy probes all enabled servers concurrently at startup and after a network-path change. Each authenticated `/v1/health` probe makes one request with a three-second request timeout and four-second transport resource timeout, without HTTP retry/backoff. Results are reused for up to 30 seconds when starting playback; a playback failure forces another check. Disabled servers are excluded.

The selected Primary remains the saved and synced preference. A healthy backup is only a device-local runtime choice. The existing source order determines backup priority. Health checks do not bounce an ongoing stream back to Primary; a new playback request prefers Primary again when it is available. Stale probe results cannot override edits or manual selection.

Session creation tries a healthy alternative once after a recoverable server/network error. AVPlayer item failures and failures during playback use the existing bounded retry setting; when enabled, retries resolve a healthy alternative and restore non-live playback position. Offline files and non-retryable content/permission errors do not trigger fallback. Downloads already in progress retain their original server.

Fallback can require a new media session and buffering; it does not guarantee gapless playback. Local fixture tests verify routing and credential isolation, rather than proving availability or uninterrupted playback on production servers.

Tailscale HTTPS names with valid system-trusted certificates are supported like any other HTTPS host. Certificate verification is never disabled. Source URLs must have a host and no embedded user/password, query or fragment. Paths are preserved as prefixes: `https://host/client` calls `/client/v1/health`.

Local HTTP requires explicit per-source opt-in and is accepted only for loopback, .local names and RFC1918 IPv4 addresses. ATS allows local networking, with no global insecure-load exception. Some OS versions may still require a trusted HTTPS endpoint for numeric local addresses. Production deployments should use HTTPS.

Non-sensitive source metadata is stored in Application Support/Twitchy/sources.json. Source bearer tokens use a distinct device-only Keychain service. Twitch tokens use another service and cannot enter StreamingSourceClient. Health and capabilities are checked independently; playback negotiates fresh capabilities so stale saved metadata cannot bypass gating.

Media URLs may contain short-lived signatures issued by the source; long-lived source credentials are never appended. AVPlayer uses its own normal network handling. Cross-origin redirects on authenticated control/file requests are refused. The client does not validate that a server is legally entitled to provide third-party media; source operators must establish permission.
