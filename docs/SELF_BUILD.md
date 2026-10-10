# Build your own Twitchy copy

This update is distributed as source code. Build locally in Xcode; there is no binary GitHub Release for this update. MIT covers the original software, not third-party streams, artwork, Twitch trademarks or permission to use a source.

## Apple signing and iCloud

The committed identifiers are the maintainer's setup: team `CNBB6EET8T`, app IDs `ch.hivenet.twitchy-macos`, `ch.hivenet.twitchy-ios`, `ch.hivenet.twitchy-tvos`, and container `iCloud.ch.hivenet.twitchy`. These identifiers are configuration, not signing credentials. They do not give another developer access to the maintainer's signing private keys or users' private CloudKit databases.

For your own device builds:

1. Add your Apple account in Xcode and select your own developer team with automatic signing for each app target.
2. Choose unique Bundle IDs for the three app targets. Keep all targets in the same team.
3. Register your own iCloud container and enable iCloud with CloudKit support for all three App IDs, assigning the same container to each.
4. Replace the container identifier in both `Apps/Shared/Twitchy.entitlements` and `PrivateCloudTransport.containerID` in `Packages/TwitchyKit/Sources/TwitchyCore/CloudSync.swift`.
5. Update the team and explicit app/test Bundle IDs in `project.yml` as well as the Xcode project. XcodeGen regeneration must preserve your setup.
6. Run on your devices using the same iCloud account, and sign in to Twitch separately on each device. See [CloudKit setup and verification](ICLOUD_SYNC.md).

A paid Apple Developer Program team is needed to provision iCloud. The committed configuration includes iCloud entitlements and is not a ready-made Personal Team configuration. Simulator or unsigned local macOS builds work with sync disabled. A free on-device build requires disabling iCloud signing entitlements and setting `TwitchyCloudEnabled` to false in that platform's Info.plist; otherwise the physical-device code may try to construct CloudKit without the required entitlement. Re-enable both when using an iCloud-capable team.

Do not upload private signing keys, certificates with private keys, provisioning profiles, OAuth tokens, source credentials, local app data or signed application packages. The repository's ignore rules cover common signing-file formats, but inspect changes before committing.

## Twitch and your streaming source

The bundled public Twitch Client ID is not a secret. An independently registered fork/application must register its own Twitch application, choose Client Type Public, and set its Client ID under Settings → Advanced. Never embed a client secret. See [Twitch authentication](TWITCH_AUTH.md) and [Twitch's registration guide](https://dev.twitch.tv/docs/authentication/register-app/). If using the optional legacy browser flow, host and register your own callback URL.

Configure a reachable compatible streaming source. Self-hosting and publishing source code do not establish permission to access or redistribute someone else's media. The client can accept explicitly enabled manual VOD/clip downloads without a permission-reference field; that technical capability does not confer download rights. Operators and users must comply with applicable content rights and Twitch terms. Do not present this project as an approved Twitch player or as granting permission to remove advertising or bypass access restrictions. See [distribution boundaries](LIMITATIONS.md).

## Privacy and assets

[PRIVACY.md](../PRIVACY.md) describes the data flow, local storage and automatic private CloudKit sync, including source bearer tokens. Twitch login credentials remain device-local. Keep this notice accurate for your fork and explain any additional processing your backend performs.

The repository includes the project's icon assets, logged-out interface screenshots and generated test media. Reference mockups and real stream captures supplied during development are not bundled. A code license does not grant rights to Twitch branding, streamer portraits or media fetched at runtime; assess those rights separately before republishing content or promotional screenshots.
