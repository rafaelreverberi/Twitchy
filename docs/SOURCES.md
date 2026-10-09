# Streaming sources

Open Profile → Settings → Sources. Add a name and HTTPS base URL, optionally enable independent bearer authentication and enter the credential issued by that server. Save, Test, inspect the version/capabilities and Select. Multiple sources are persisted; exactly one is active. Edit, disable or remove sources from this screen. Removing a source also deletes its Keychain entry. Active source changes stop the current playback session.

Tailscale HTTPS names with valid system-trusted certificates are supported like any other HTTPS host. Certificate verification is never disabled. Source URLs must have a host and no embedded user/password, query or fragment. Paths are preserved as prefixes: `https://host/client` calls `/client/v1/health`.

Local HTTP requires explicit per-source opt-in and is accepted only for loopback, .local names and RFC1918 IPv4 addresses. ATS allows local networking, with no global insecure-load exception. Some OS versions may still require a trusted HTTPS endpoint for numeric local addresses. Production deployments should use HTTPS.

Non-sensitive source metadata is stored in Application Support/Twitchy/sources.json. Source bearer tokens use a distinct device-only Keychain service. Twitch tokens use another service and cannot enter StreamingSourceClient. Health and capabilities are checked independently; playback negotiates fresh capabilities so stale saved metadata cannot bypass gating.

Media URLs may contain short-lived signatures issued by the source; long-lived source credentials are never appended. AVPlayer uses its own normal network handling. Cross-origin redirects on authenticated control/file requests are refused. The client does not validate that a server is legally entitled to provide third-party media; source operators must establish permission.
