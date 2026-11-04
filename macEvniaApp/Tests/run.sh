#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"
mkdir -p build

swiftc -swift-version 5 -target arm64-apple-macos14.0 -framework AppKit \
  Sources/Models.swift Sources/ProfileSymbols.swift Tests/ProfileSymbolsTests.swift \
  -o build/profile-symbols-tests

swiftc -swift-version 5 -target arm64-apple-macos14.0 -framework AppKit \
  Sources/UpdateChecker.swift Sources/DebugLog.swift Sources/MenuBarIcon.swift Tests/UpdateCheckerTests.swift \
  -o build/update-checker-tests

./build/profile-symbols-tests
./build/update-checker-tests "$@"
