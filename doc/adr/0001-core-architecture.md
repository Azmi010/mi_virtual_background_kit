# ADR 0001 — Core architecture of mi_virtual_background_kit

Status: Accepted (for review)
Date: 24 October 2026
Milestone: M0 — spike and technology decisions
Supporting figures: [doc/spike-results.md](../spike-results.md)

## Context

The package implements virtual background effects (blur, image, solid color) on the local
camera track of `flutter_webrtc`, fully on-device, Android + iOS, with the Dart API on the control
plane only — frames do not pass through Dart.

Spike devices (this track):

| Device | ABI | OS | Role |
|---|---|---|---|
| Samsung SM-A135F | `armeabi-v7a` (32-bit only) | Android 14 (API 34) | Physical, low-end, main device |
| iPhone 15 | arm64 | iOS 26.5 | Physical, iOS hook |
| Emulator `sdk_gphone16k_arm64` | `arm64-v8a` | Android 17 (API 37) | Latency comparison only (software GL) |

Spike code is in `android/.../spike/`, `ios/.../MiVirtualBackgroundKitPlugin.swift`, and
`example/` — removed before release.

## Decisions

### 1. Frame hook point: built-in frame processor API of flutter_webrtc

No fork. The plugin uses the existing native API already proven to be used by `livekit_client`
in production:

- **Android** — `FlutterWebRTCPlugin.sharedSingleton.getLocalTrack(trackId)` →
  `LocalVideoTrack.addProcessor(ExternalVideoFrameProcessing.onFrame)`. Frame is processed on the
  capture thread before reaching the sink.
- **iOS** — `FlutterWebRTCPlugin.sharedSingleton().localTracks[trackId]` →
  `LocalVideoTrack.addProcessing(_:)` (`ExternalVideoProcessingDelegate.onFrame`).

Live verification: Android `attach=true`, stable 30 fps, on/off toggle visible in preview;
iOS `attach=true`, stable 30 fps, transform visually verified on physical device.

Mandatory rules proven by this API design:

- Cache the `LocalVideoTrack` object on attach; **do not** look it up again by ID — the Dart
  call `stream.getMediaTracks()` overwrites the `localTracks` map with new objects that are not
  attached as processors (silent no-op).
- Document this as an internal contract in the implementation phase code.

### 2. Frame format: GPU texture on both platforms

- Android: `TextureBufferImpl` of type `OES`, rotation 270, 480x640 on a 640x480 request.
- iOS: `RTCCVPixelBuffer` (CVPixelBuffer), rotation 90, 640x480; pixel format
  (BGRA vs YCbCr biplanar) is **detected at runtime** — a static assumption proved wrong in the
  first spike (result: lines, not color shifting).

Consequence: the compositing pipeline stays on the GPU; transforms based on CPU byte access on the
Android buffer do not work (not CPU I420).

### 3. Segmentation engine: MediaPipe Image Segmenter

Compared head-to-head on two devices (full figures in spike-results T0.6):

| Criterion | MediaPipe (`tasks-vision` 0.10.20 + `selfie_segmenter.tflite`) | ML Kit (`segmentation-selfie` 16.0.0-beta6) |
|---|---|---|
| P1 latency @640 (median) | 179 ms | **111 ms** (faster on this device) |
| Mask resolution | = input resolution (256/640/…) | **fixed 256x256** (model baked) |
| Edge accuracy (overlay) | fine hair detail @640 | neat but coarse (256) |
| License | **Apache-2.0** | **ML Kit Terms of Service** (not open-source) |
| Size | AAR 18,8 MB + 250 KB model asset | tree ≈ 24,2 MB (249 KB model bundled) |
| Privacy dependency | `datatransport` installed as well (not yet disabled — see Risks) | `datatransport` + `firebase-encoders` + `play-services` |

**Decided: MediaPipe.** Deciding reasons: the Apache-2-0 license is compatible with redistribution
of the MIT package (ML Kit ToS is not), a cleaner dependency structure for PRD G4, and a
resolution-independent mask (ML Kit is locked to 256). ML Kit's latency advantage on P1 is noted as
is and does not change the decision.

Encoding fact the implementation must know: UINT8 category mask with
**person=0, background=255** (proven by histogram) — predicate `!= 0` = inverted.

Model: `selfie_segmenter.tflite` 249.537 bytes, **bundled as an asset** (without
runtime download), CPU delegate.

### 4. Compositing method: GPU (mandatory)

T0.7 results on P1:

| | 640x480 | 1280x720 |
|---|---|---|
| GPU blur / image | 30 fps, compose 0,9–1,1 ms | 30 fps, compose 1,1–1,2 ms |
| CPU blur (readback + Java) | 76 ms ≈ 13 fps | 253 ms ≈ 4 fps |
| CPU image | 36 ms ≈ 28 fps | 133 ms ≈ 7,5 fps |

The CPU path does not yet include texture upload and is already outside the 33 ms budget at both
resolutions. GLES2 compositing runs on the capture thread (the only thread with a correct EGL
context).

Consequence for segmentation: per-frame readback on P1 = 5,9 ms @640 / 42 ms @720 —
plus MediaPipe latency of 179 ms @640, **full per-frame segmentation is impossible on the
32-bit low-end class**. Design direction: compute the mask at lower resolution / lower
frequency, keep compositing per-frame with the latest mask. These parameters go into FR-11/FR-12
(Phase 5) and are retested on a mid-range device (not available in this spike).

### 5. Minimum OS

- **Android `minSdk 24`** (already in `android/build.gradle.kts`; follows the PRD candidate;
  Camera2 available since 21, MediaPipe tasks require 24).
- **iOS 13** (follows `flutter_webrtc`; all iOS-13 iPhones are arm64).

### 6. flutter_webrtc version range

`flutter_webrtc: ^1.6.2`, tested on `1.6.2+hotfix.4` (both platforms).

The hook point is an internal API (not a public semver contract). Consequences: pin the range
tightly, test the lower/upper bounds in CI (T6.4), and give a clear error message when the API
changes. If a later version breaks the hook, the package must restrict the range in
`pubspec.yaml` until adjusted.

### 7. Package format and build workaround

One plugin (`android/` + `ios/` folders), both `Package.swift` and `.podspec` are
provided (following `flutter_webrtc`; the user's app can use either SPM or
CocoaPods).

Build note: Flutter < 3.48 recursively copies plugin package contents (including `example/build`)
via rsync during the iOS SPM build — the repo uses `tool/link_example_build.sh`
(linking `example/build` outside the repo) until an upstream fix (flutter/flutter#188647,
Flutter 3.48) is available.

### 8. License

- Code: **MIT** (`LICENSE` file).
- Segmentation model: **Apache-2.0** — compatible with redistribution in the MIT package.

## Rejected alternatives

- **Fork/patch flutter_webrtc** — rejected: maintenance cost; the built-in processor API
  is already proven sufficient (same pattern used by LiveKit).
- **CPU compositing** — rejected: 76 ms/frame @640, 253 ms @720 (T0.7), 30 fps impossible.
- **ML Kit Selfie Segmentation** — rejected: non-open-source ToS license, fixed 256
  mask, Google telemetry dependency (T0.6). The faster latency on P1 does not
  outweigh those three things.
- **CPU byte access / `toI420()` as the main path** — rejected: the Android GPU buffer is
  OES, not CPU I420; readback conversion is expensive (5,9–42 ms).
- **Download the model at runtime** — rejected: violates G4 and adds offline failures;
  the 250 KB model is small enough to bundle.

## Risks and mitigation

- **Internal flutter_webrtc hook API** may change without semver — pin `^1.6.2`, test
  version bounds in CI, clear error when attach fails.
- **`datatransport` still active on the classpath** (comes with MediaPipe). `disableTransportNetwork()`
  in the current spike **only logs, does not disable the scheduler** — must be implemented
  before release (Phase 3) and verified with no network calls.
- **32-bit device (P1) is not real-time for per-frame segmentation** — design a
  lower-frequency/resolution fallback (FR-11/FR-12); mid-range class not yet tested, spike figures
  represent low-end only.
- **MediaPipe mask encoding person=0** differs from the common convention — overlay/compositing
  unit tests must verify mask direction.
- **Resource leak** on repeated attach/detach — tested in T3.7/T6.5.
