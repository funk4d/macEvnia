#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${ROOT}/build"
APP_DIR="${BUILD_DIR}/macEvnia.app"
mkdir -p "${BUILD_DIR}"
# Stage the bundle outside BUILD_DIR. If the repo lives under an iCloud-synced
# folder (Desktop & Documents sync), the file provider stamps
# com.apple.FinderInfo on the .app directory while it is being assembled, and
# codesign rejects that as "detritus". A system temp dir is never synced.
STAGING_DIR="$(mktemp -d -t macEvnia-build)"
STAGING_APP="${STAGING_DIR}/macEvnia.app"
CONTENTS="${STAGING_APP}/Contents"
MACOS="${CONTENTS}/MacOS"
RESOURCES="${CONTENTS}/Resources"
APP_ICON_SOURCE="${ROOT}/icons/macEvnia.png"
APP_ICONSET="${BUILD_DIR}/macEvnia.iconset"
APP_ICON="${RESOURCES}/macEvnia.icns"
MENUBAR_ICON_SOURCE="${ROOT}/icons/menubar_white.png.png"

cleanup() {
  rm -rf "${STAGING_DIR}"
}
trap cleanup EXIT

mkdir -p "${MACOS}" "${RESOURCES}"

swiftc \
  -swift-version 5 \
  -O \
  -target arm64-apple-macos14.0 \
  -I "${ROOT}/Sources" \
  -framework AppKit \
  -framework CoreGraphics \
  -framework CoreMedia \
  -framework CoreVideo \
  -framework IOKit \
  -framework ScreenCaptureKit \
  "${ROOT}"/Sources/*.swift \
  -o "${MACOS}/macEvnia"

if [[ -f "${APP_ICON_SOURCE}" ]]; then
  rm -rf "${APP_ICONSET}"
  mkdir -p "${APP_ICONSET}"
  sips -z 16 16 "${APP_ICON_SOURCE}" --out "${APP_ICONSET}/icon_16x16.png" >/dev/null
  sips -z 32 32 "${APP_ICON_SOURCE}" --out "${APP_ICONSET}/icon_16x16@2x.png" >/dev/null
  sips -z 32 32 "${APP_ICON_SOURCE}" --out "${APP_ICONSET}/icon_32x32.png" >/dev/null
  sips -z 64 64 "${APP_ICON_SOURCE}" --out "${APP_ICONSET}/icon_32x32@2x.png" >/dev/null
  sips -z 128 128 "${APP_ICON_SOURCE}" --out "${APP_ICONSET}/icon_128x128.png" >/dev/null
  sips -z 256 256 "${APP_ICON_SOURCE}" --out "${APP_ICONSET}/icon_128x128@2x.png" >/dev/null
  sips -z 256 256 "${APP_ICON_SOURCE}" --out "${APP_ICONSET}/icon_256x256.png" >/dev/null
  sips -z 512 512 "${APP_ICON_SOURCE}" --out "${APP_ICONSET}/icon_256x256@2x.png" >/dev/null
  sips -z 512 512 "${APP_ICON_SOURCE}" --out "${APP_ICONSET}/icon_512x512.png" >/dev/null
  iconutil -c icns "${APP_ICONSET}" -o "${APP_ICON}"
fi

if [[ -f "${MENUBAR_ICON_SOURCE}" ]]; then
  cp "${MENUBAR_ICON_SOURCE}" "${RESOURCES}/menubar_light.png"
fi

cp "${ROOT}/Resources/Info.plist" "${CONTENTS}/Info.plist"
xattr -cr "${STAGING_APP}"

SIGNING_IDENTITY="${MACOS_CODESIGN_IDENTITY:-}"
DEVELOPER_ID_IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null \
  | sed -nE 's/^[[:space:]]*[0-9]+\) ([[:xdigit:]]+) "(Developer ID Application:[^"]+)"$/\1|\2/p')"
DEVELOPER_ID_COUNT="$(printf '%s\n' "${DEVELOPER_ID_IDENTITIES}" | awk 'NF { count++ } END { print count + 0 }')"

if [[ -z "${SIGNING_IDENTITY}" ]]; then
  case "${DEVELOPER_ID_COUNT}" in
    0) ;;
    1) SIGNING_IDENTITY="$(printf '%s\n' "${DEVELOPER_ID_IDENTITIES}" | awk -F '|' 'NR == 1 { print $1 }')" ;;
    *)
      echo "Multiple Developer ID identities found. Set MACOS_CODESIGN_IDENTITY to choose one." >&2
      exit 1
      ;;
  esac
fi

MATCHING_DEVELOPER_ID="$(printf '%s\n' "${DEVELOPER_ID_IDENTITIES}" \
  | awk -F '|' -v identity="${SIGNING_IDENTITY}" '$1 == identity || $2 == identity { print $1; exit }')"

if [[ "${MACOS_REQUIRE_STABLE_CODESIGNING:-0}" == "1" && -z "${MATCHING_DEVELOPER_ID}" ]]; then
  echo "A Developer ID Application identity is required. Install one or set MACOS_CODESIGN_IDENTITY to its name or hash." >&2
  exit 1
fi

if [[ -n "${MATCHING_DEVELOPER_ID}" ]]; then
  SIGNING_IDENTITY="${MATCHING_DEVELOPER_ID}"
  codesign --force --deep --options runtime --timestamp --sign "${SIGNING_IDENTITY}" "${STAGING_APP}" >/dev/null
  echo "Signed with Developer ID: ${SIGNING_IDENTITY}"
elif [[ -n "${SIGNING_IDENTITY}" ]]; then
  codesign --force --deep --sign "${SIGNING_IDENTITY}" "${STAGING_APP}" >/dev/null
  echo "Signed with: ${SIGNING_IDENTITY}"
else
  codesign --force --deep --sign - "${STAGING_APP}" >/dev/null
  echo "Warning: this app is ad-hoc signed. macOS may ask for Screen Recording permission again after rebuilds." >&2
fi

test -x "${MACOS}/macEvnia"
plutil -lint "${CONTENTS}/Info.plist" >/dev/null
codesign --verify --deep --strict "${STAGING_APP}" >/dev/null

rm -rf "${APP_DIR}.previous"
if [[ -d "${APP_DIR}" ]]; then
  mv "${APP_DIR}" "${APP_DIR}.previous"
fi
mv "${STAGING_APP}" "${APP_DIR}"
rm -rf "${APP_DIR}.previous"

echo "Built: ${APP_DIR}"
echo "Run: open '${APP_DIR}'"
