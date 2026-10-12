# Twitchy branding

`Resources/AppIcon.icon` is the supplied Icon Composer document, copied without
changing its SVG layer, positioning, Display P3 fill or glass settings. The iOS
(iPhone/iPad) and macOS targets use `AppIcon`. Xcode compiles Default, Dark,
Clear and Tinted appearances and generates compatibility icons for older OS
versions. Keep this document outside the asset catalog; edit it in Icon Composer.

tvOS uses `Apps/tvOS/Assets.xcassets/TVBrand.brandassets` instead. Its opaque purple
back and transparent white logo front are separate layers for system parallax.
App Store and both Top Shelf images share the same mark. Regenerate them with:

```sh
swift scripts/make_tv_assets.swift Apps/tvOS/Assets.xcassets/TVBrand.brandassets
```

The original purple SVG is preserved in `Resources/Branding`. The design system
also bundles it as the vector `TwitchyLogo` asset, so `BrandMark` works in all three
apps, including Apple TV onboarding. This mark intentionally has no app-icon
background or system glass treatment.

Local verification: Xcode 27 builds for macOS and the iOS/tvOS Simulators;
Icon Composer exports inspected in Default, Dark, ClearLight and TintedDark.
Physical-device Home Screen appearance and App Store submission are not verified.
