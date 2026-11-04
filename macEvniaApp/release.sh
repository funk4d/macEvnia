#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${ROOT}/build"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${ROOT}/Resources/Info.plist")"
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${ROOT}/Resources/Info.plist")"
APP="${BUILD_DIR}/macEvnia.app"
ARCHIVE_NAME="macEvnia-${VERSION}.zip"
STAGING="$(mktemp -d -t macEvnia-release)"

cleanup() {
  rm -rf "${STAGING}"
}
trap cleanup EXIT

"${ROOT}/Tests/run.sh"
MACOS_APP_NAME=macEvnia MACOS_BUNDLE_IDENTIFIER=local.macevnia "${ROOT}/build.sh"

COPYFILE_DISABLE=1 ditto -c -k --keepParent --norsrc --noextattr "${APP}" "${STAGING}/${ARCHIVE_NAME}"
unzip -tq "${STAGING}/${ARCHIVE_NAME}"
ditto -x -k "${STAGING}/${ARCHIVE_NAME}" "${STAGING}/unpacked"

EXTRACTED="${STAGING}/unpacked/macEvnia.app"
PLIST="${EXTRACTED}/Contents/Info.plist"
EXECUTABLE="${EXTRACTED}/Contents/MacOS/macEvnia"
test -x "${EXECUTABLE}"
plutil -lint "${PLIST}"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${PLIST}")" = local.macevnia
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "${PLIST}")" = macEvnia
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${PLIST}")" = "${VERSION}"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${PLIST}")" = "${BUILD_NUMBER}"
lipo "${EXECUTABLE}" -verify_arch arm64
cmp "${APP}/Contents/MacOS/macEvnia" "${EXECUTABLE}"
codesign --verify --deep --strict --verbose=2 "${EXTRACTED}"

mv "${STAGING}/${ARCHIVE_NAME}" "${BUILD_DIR}/${ARCHIVE_NAME}"
(
  cd "${BUILD_DIR}"
  shasum -a 256 "${ARCHIVE_NAME}" > "${ARCHIVE_NAME}.sha256"
  shasum -a 256 -c "${ARCHIVE_NAME}.sha256"
)

printf 'Prepared macEvnia %s (build %s)\nArchive: %s\nChecksum: %s\n' \
  "${VERSION}" "${BUILD_NUMBER}" "${BUILD_DIR}/${ARCHIVE_NAME}" "${BUILD_DIR}/${ARCHIVE_NAME}.sha256"
