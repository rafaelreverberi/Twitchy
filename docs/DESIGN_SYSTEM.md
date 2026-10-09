# Design system

Visual thesis: quiet dark surfaces, confident native typography and content-first live imagery, with violet reserved for actions and mint for live status.

Content hierarchy: native destination title → current task/collection → thumbnail and channel → stream title → category/viewers. Onboarding carries the product tagline; operational screens use short utility copy. Stream cards are clickable content, not decorative dashboard tiles. Missing images use neutral SF Symbol fallback rather than fabricated footage.

Colors are centralized in TwitchyDesignSystem/TwitchyTheme: background #0E0E10, secondary #18181B, elevated #1F1F23, accent #9146FF, highlight #A970FF, muted text #ADADB8, live #00C896, error #EB0400. When Dark theme is disabled, system light appearance uses background #F5F5F7, secondary #FFFFFF, elevated #EAEAF0 and muted text #5C5C67. Primary foreground follows SwiftUI semantic text. Rounded thumbnail radius 12, standard gap 20, page inset 24. Native dynamic typography and SF Symbols provide readable system integration. The original icon is a violet rounded play tile, generated from project-owned geometry.

iPhone uses a five-item TabView. iPad adapts to NavigationSplitView at regular width. macOS uses a List sidebar, toolbar, command-comma Settings and native AVPlayerView. tvOS uses native tabs, buttons and focus navigation; chat font uses a picker rather than unsupported steppers. Wider player layouts place chat beside media; compact layouts stack it.

Intentional motion: restrained thumbnail hover (1.015 scale), native navigation/sheet transitions and latest-message scroll animation. System Reduce Motion and the user's Reduce animations disable custom motion. No ornamental gradients/glass or copyrighted Twitch logos. Accessibility identifiers cover destinations, OAuth configuration, onboarding, source editor and chat composition. Major views have SwiftUI previews; additional per-platform accessibility/focus audits remain necessary.
