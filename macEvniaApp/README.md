# macEvnia

Native macOS menu bar app for Philips Evnia Ambiglow monitors with USB HID LampArray support.

Version 0.4. Requires Apple Silicon and macOS 14 or newer. Liquid Glass is used on macOS 26+; older versions use system blur.

## Build

Building requires Xcode with the macOS 26 SDK or newer. The resulting app supports macOS 14 and newer.

```bash
./build.sh
open build/macEvnia.app
```

macEvnia requires macOS Screen Recording permission for screen-follow Ambiglow. The blue screen-recording privacy indicator in the menu bar is normal while the app is sampling the screen.

## Release Archive

```bash
./release.sh
```

Runs tests, builds `macEvnia.app`, verifies the extracted ZIP, and writes `build/macEvnia-0.4.zip` and its SHA-256 checksum. This prepares local files only; it does not publish a GitHub release.

Without a Developer ID Application certificate, the build is ad-hoc signed and not notarized. Screen Recording permission may need to be granted again after an update.
