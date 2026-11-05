## 0.1.1

* Fix iOS Swift Package Manager build failure in consumer apps that resolve a
  `flutter_webrtc` version other than `1.6.2+hotfix.4`
  (issue #1): `Package.swift` now declares the dependency as the versionless
  `../flutter_webrtc` path, which the Flutter tool (>= 3.47.2) rewrites to the
  app's resolved `flutter_webrtc-<version>` before building.

## 0.1.0

* Initial release.
* Virtual background effects on local `flutter_webrtc` camera tracks: blur,
  image (asset / file / bytes, fit `cover` or `contain`), solid color, and
  none (bypass).
* Switch effects at runtime without restarting the camera track (`setEffect`,
  idempotent; camera switch keeps the active effect).
* `attach` with `BackgroundQuality` (segmentation width, edge smoothing,
  target fps) and runtime `setQuality`; presets `low` / `balanced` / `high`.
* `statusStream` (idle, initializing, active, error) and `fallbackStream`
  with typed errors; `isSupported()` checks device, GPU, and model.
* Two-stage performance fallback: quality degraded below 14 fps, effect
  disabled below 10 fps (FR-12), no crash.
* Fully on-device processing (MediaPipe `selfie_segmenter.tflite`,
  Apache-2.0, bundled; GPU compositing) — no network, no telemetry.
* Android (minSdk 24) and iOS 15.0+.
