#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${ROOT}/build"
APP_DIR="${BUILD_DIR}/macEvnia.app"
STAGING_DIR="$(mktemp -d "${BUILD_DIR}/.macEvnia-build.XXXXXX")"
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
codesign --force --deep --sign - "${STAGING_APP}" >/dev/null

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
