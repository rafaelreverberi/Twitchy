# Security

Twitch access/Device Flow refresh tokens are stored in the device-only Keychain service com.rafaelreverberi.Twitchy.twitch. Source bearer tokens use com.rafaelreverberi.Twitchy.sources keyed by source UUID. No client secret is required or accepted by application configuration. OAuth state and callback origin/path are verified; tokens are validated for identity and expiry before use.

Sources are untrusted. Production URL policy requires HTTPS without embedded credentials. Explicit local-development HTTP is limited to private/loopback destinations; TLS validation remains enabled. Authenticated control/file requests refuse redirects. Source media must use valid HTTPS (or explicitly allowed local HTTP) and short-lived credentials suitable for AVPlayer. Sources never receive Twitch tokens by design. Files use UUID names instead of server filenames.

No token/debug HTTP header logging exists. User-facing source errors show stable codes rather than server-provided sensitive descriptions. The fixture suppresses access logs. Logs/screenshots provided in reports must be sanitized. Secrets, private account content, certificates and provisioning files must never be committed.

Token revocation, source compromise, disk access and developer registration must be included in integration review. The app is not sandboxed for App Store distribution yet; production entitlements, signing and notarization need review. Keychain failures are surfaced, and local logout only completes after successful credential deletion.

For vulnerabilities, contact the maintainer privately via the authenticated repository owner's available contact channel. Do not file public issues containing exploitation secrets or credentials. No unsupported security contact address is invented in this repository.
