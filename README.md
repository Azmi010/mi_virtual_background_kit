# mi_virtual_background_kit

[![CI](https://github.com/Azmi010/mi_virtual_background_kit/actions/workflows/ci.yml/badge.svg)](https://github.com/Azmi010/mi_virtual_background_kit/actions/workflows/ci.yml)
[![pub](https://img.shields.io/pub/v/mi_virtual_background_kit.svg)](https://pub.dev/packages/mi_virtual_background_kit)

Real-time virtual background (blur, image, solid color) for local camera tracks
in Flutter apps built on `flutter_webrtc`. Fully on-device — no network, no
telemetry.

<!-- TODO(Fase 8): demo GIF -->

## Problem

Flutter video-call apps struggle to find a maintained, vendor-neutral virtual
background package for Android and iOS. Vendor SDKs are closed or paid; custom
native work (segmentation, threading, compositing) is costly to build and
maintain.

This package solves one problem well: process the local camera track so its
background is replaced, behind a small Dart API.

## Platform support

| Platform | Status |
|----------|--------|
| Android  | ✅ minSdk 24 |
| iOS      | ✅ iOS 13+ |
| Web      | ❌ not in v0.1 |
| Desktop  | ❌ not in v0.1 |

Requires `flutter_webrtc: ^1.6.2`.

## Install

```yaml
dependencies:
  mi_virtual_background_kit: ^0.1.0
```

<!-- TODO(Fase 8): native setup — camera permission, minSdk, iOS notes -->

## Quick example

<!-- TODO(Fase 8): short example matching final API (attach / setEffect / detach) -->

## Effects

- `BlurEffect` — adjustable radius
- `ImageEffect` — from asset, file path, or bytes
- `ColorEffect` — solid color
- `NoEffect` — bypass, no processing overhead

Switch effects at runtime without restarting the camera track.

## Status & errors

Processor status (idle / initializing / active / error) is exposed as a
`Stream`. Errors carry clear codes: `unsupportedPlatform`, `modelLoadFailed`,
`invalidTrack`, `invalidImage`.

## Limitations

- Local camera track only — remote video is not processed.
- No noise suppression, beauty filters, or AR effects.
- No image hosting: the app provides background images.
- Performance varies by device; conservative defaults, tunable quality.

## LiveKit

Works on top of `flutter_webrtc`, so LiveKit apps can use it.
<!-- TODO(Fase 8): short integration recipe -->

## License

MIT. See [LICENSE](LICENSE).
