#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"
mkdir -p build

swiftc -swift-version 5 -target arm64-apple-macos14.0 -framework AppKit \
  Sources/Models.swift Sources/LightingEffects.swift Sources/MusicEffect.swift Sources/MusicAudioTap.swift \
  Sources/DebugLog.swift Sources/PlaybackMode.swift Sources/ProfileSymbols.swift Tests/ProfileSymbolsTests.swift \
  -o build/profile-symbols-tests

swiftc -swift-version 5 -target arm64-apple-macos14.0 -framework AppKit \
  Sources/UpdateChecker.swift Sources/DebugLog.swift Sources/MenuBarIcon.swift Tests/UpdateCheckerTests.swift \
  -o build/update-checker-tests

settings_sources=()
for source in Sources/*.swift; do
  [[ "${source}" == Sources/AppDelegate.swift ]] || settings_sources+=("${source}")
done
swiftc -swift-version 5 -target arm64-apple-macos14.0 \
  "${settings_sources[@]}" Tests/ProfileSettingsTests.swift -o build/profile-settings-tests

./build/profile-symbols-tests
./build/profile-settings-tests
./build/update-checker-tests "$@"
