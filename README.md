<p align="center">
  <img src="macEvniaApp/icons/macEvnia.png" width="128" height="128" alt="macEvnia icon">
</p>

# macEvnia

macEvnia is a native macOS menu bar app for Philips Evnia Ambiglow monitors that expose their backlight as a USB HID LampArray device.

It samples the screen, calculates LED colors, and sends them to the monitor in real time.

## Demo

<p align="center">
  <img src="demo.gif" width="100%" alt="macEvnia compared with the default Philips Follow Video mode">
</p>

The default Philips `Follow Video` mode can produce visible LED brightness jumps and uneven backlight transitions.

macEvnia gives the host full control over the Ambiglow LEDs, with up to 50 Hz LED updates, smoothing, wall color compensation, and per-LED brightness calibration.

## Supported Monitor

Tested with:

- Philips Evnia 27M2N5901A / 27M2N5900A
- USB HID LampArray device: `0cf2:b215`

Other Philips Evnia models may work if they expose a compatible HID LampArray device.

## Features

- Menu bar control
- Screen-follow Ambiglow
- Profiles
- Capture rate from 1 FPS to 50 FPS
- LED update rate from 1 Hz to 50 Hz
- Screenshot quality control
- Ambiglow brightness
- Screen brightness
- Smoothing
- Sample radius
- Wall color compensation
- Per-LED brightness calibration
- Rainbow, solid color, lights off, and return to monitor defaults

## Privacy

macEvnia needs macOS Screen Recording permission because screen-follow Ambiglow works by sampling the screen.

While macEvnia is running in screen-follow mode, macOS shows the blue screen-recording privacy indicator in the menu bar. This is normal.

macEvnia uses Apple's ScreenCaptureKit `SCScreenshotManager` capture path. The app does not record video, save screenshots, or send screen data anywhere.

## Build

Requirements:

- macOS 14 or newer
- Xcode command line tools

Build:

```bash
cd macEvniaApp
./build.sh
open build/macEvnia.app
```

The built app is located at:

```text
macEvniaApp/build/macEvnia.app
```

## Version

0.3

## Support

If macEvnia helps you, you can support its development on Ko-fi:

[![Support on Ko-fi](https://img.shields.io/badge/Support%20on-Ko--fi-FF5E5B?style=for-the-badge&logo=ko-fi&logoColor=white)](https://ko-fi.com/dmytroshevchuk)

## Trademarks

macEvnia is an independent, unofficial project. It is not affiliated with,
endorsed by, sponsored by, or supported by Koninklijke Philips N.V.

Philips, Evnia, and Ambiglow are trademarks of Koninklijke Philips N.V.
They are used here only to identify the monitors this software is designed
to work with.
