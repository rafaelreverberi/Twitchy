# Build your own Twitchy copy

This update is distributed as source code. Build locally in Xcode; there is no binary GitHub Release for this update. MIT covers the original software, not third-party streams, artwork, Twitch trademarks or permission to use a source.

## Apple signing and iCloud

The checkout uses example Bundle IDs and has no Apple team or iCloud container selected. Simulator and local macOS builds can run with these settings.

For signed builds, create the ignored `Config/Twitchy.local.xcconfig` file and set `DEVELOPMENT_TEAM` to your team, `TWITCHY_BUNDLE_PREFIX` to your reverse-DNS prefix, and, if using iCloud, `TWITCHY_CLOUD_CONTAINER` to your registered container. The three app IDs append `.twitchy-macos`, `.twitchy-ios`, and `.twitchy-tvos` to the prefix. To enable CloudKit, also set `TWITCHY_CODE_SIGN_ENTITLEMENTS = Apps/Shared/Twitchy.entitlements` and assign the same container to all three App IDs in your Apple Developer account. Xcode and XcodeGen read the same local settings.

A paid Apple Developer Program team is needed to provision iCloud. Leave the container and entitlement settings empty for local builds without iCloud. See [CloudKit setup and verification](ICLOUD_SYNC.md).

Do not upload private signing keys, certificates with private keys, provisioning profiles, OAuth tokens, source credentials, local app data or signed application packages. The repository's ignore rules cover common signing-file formats, but inspect changes before committing.

## Twitch and your streaming source

Open **Set Up Twitch Connection** and register your own Public application. Save its Client ID in Twitchy. Never embed a client secret. See [Twitch authentication](TWITCH_AUTH.md) and [Twitch's registration guide](https://dev.twitch.tv/docs/authentication/register-app/). If using the optional legacy browser flow, host and register your own callback URL.

Configure a reachable compatible streaming source. Self-hosting and publishing source code do not establish permission to access or redistribute someone else's media. The client can accept explicitly enabled manual VOD/clip downloads without a permission-reference field; that technical capability does not confer download rights. Operators and users must comply with applicable content rights and Twitch terms. Do not present this project as an approved Twitch player or as granting permission to remove advertising or bypass access restrictions. See [distribution boundaries](LIMITATIONS.md).

## Privacy and assets

[PRIVACY.md](../PRIVACY.md) describes the data flow, local storage and automatic private CloudKit sync, including source bearer tokens. Twitch login credentials remain device-local. Keep this notice accurate for your fork and explain any additional processing your backend performs.

The repository includes the project's icon assets, README banner and generated test media. Reference mockups and real stream captures supplied during development are not bundled. A code license does not grant rights to Twitch branding, streamer portraits or media fetched at runtime; assess those rights separately before republishing content or promotional screenshots.
