#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
xcodebuild -version
swift --version
swift test --package-path Packages/TwitchyKit
xcodebuild -project Twitchy.xcodeproj -scheme Twitchy-macOS -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project Twitchy.xcodeproj -scheme Twitchy-iOS -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project Twitchy.xcodeproj -scheme Twitchy-tvOS -destination 'generic/platform=tvOS Simulator' CODE_SIGNING_ALLOWED=NO build
python3 scripts/check_contract.py
