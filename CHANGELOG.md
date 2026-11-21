## 0.x policy note

During 0.x, changes that break consumer code (a new subclass of
`sealed class VirtualBackgroundEffect`, a new error code on
`BackgroundException`) are allowed in a **minor** release and the changelog
entry starts with **Breaking:**. New `BackgroundQuality` fields are non-breaking
as long as they have defaults that preserve the previous behavior.

## Unreleased

* Android: align the native `io.github.webrtc-sdk:android` pin to
  `150.7871.04`, matching `flutter_webrtc 1.6.3`, the upper bound of the
  tested version range. The previous `150.7871.01` declaration did not match
  the version Gradle resolves when both are on the classpath. This is not a
  breaking change; no public API changes.
* iOS: pin the MediaPipe Swift Package dependency to the v1.2.3 revision
  instead of the moving `master` branch, so consumer builds resolve the
  same MediaPipe code every time. A version tag cannot be used because
  MediaPipe declares `unsafeFlags` in its manifest.

## 0.2.1

* Android: ship `consumer-rules.pro` so apps with R8/minify keep the plugin,
  MediaPipe framework classes, protobuf messages, flogger, and datatransport.
  Apps no longer need to copy these rules into their own `proguard-rules.pro`
  (issue #2).

## 0.2.0

* Preview controller `VirtualBackgroundPreviewController` (FR-17/FR-18):
  `start`, `stop`, `setEffect`, `switchCamera`, `releaseToCaller`, and `dispose`
  are idempotent. `releaseToCaller` hands the stream, track, and kit to the
  caller without stopping the camera or removing the effect.
* `VirtualBackgroundPreview` widget renders the controller's stream through
  the `flutter_webrtc` renderer, with `mirror` and `fit` (`cover`/`contain`).
  Failed start or denied camera permission appears as an error message plus a
  retry button, not a crash.
* **Breaking:** minimum SDK raised to Dart 3.6.0 and Flutter 3.27.0 (required
  by the pub workspace for the LiveKit adapter package).
* **Breaking:** `FallbackAction` gains the `recovered` value — exhaustive
  `switch` statements over `FallbackAction` in consumer code need a new branch
  (ADR 0002 §9 policy: minor release plus a Breaking note).
* Fallback recovery: new `MiVirtualBackgroundKit.resumeEffect()` re-enables the
  last effect after stage-2 fallback disabled it, and
  `BackgroundQuality.autoRecovery` (default `false`) restores the effect and
  degraded segmentation quality automatically after fps stabilizes, emitting
  `FallbackAction.recovered`. Automatic recovery is one-shot per manual
  intervention (latch) so slow devices do not oscillate between active and
  inactive.
* `attach()` without a `quality` argument now uses the last quality
  configuration (camera switch no longer resets `BackgroundQuality` to
  defaults, including the `autoRecovery` flag).
* `metricsStream`: local `BackgroundMetrics` (output fps, last segmentation
  latency, mask age) emitted about once per second while an effect is active.
  Reporting is handled only while there are listeners — without listeners
  native builds no payload and sends nothing; all data stays on the device.
* `BackgroundMetrics.processorLatencyMs` (optional): duration from frame
  arrival at the native processor to the composited frame returned to WebRTC.
  The new field is `null` until the first composited frame and does not change
  existing consumer code.
* Android segmentation model default changed to `selfie_segmenter_landscape`:
  inference latency drops about 34% on low-end devices with comparable mask
  quality, so masks are fresher without fps regression. The default
  `segmentationWidth` remains 256.

## 0.1.1

* Fix iOS Swift Package Manager build failure in consumer apps that resolve a
  `flutter_webrtc` version other than `1.6.2+hotfix.4`
  (issue #1): `Package.swift` now declares the dependency as the versionless
  `../flutter_webrtc` path, which the Flutter tool (>= 3.47.2) rewrites to the
  app's resolved `flutter_webrtc-<version>` before building.
* Android blur now matches iOS strength: the single 3x3 pass (which offset
  samples by only ~`radius/25` texels, barely visible even at the maximum
  radius) is replaced by a progressive separable Gaussian on a half-res chain
  whose sigma equals the `radius` in pixels — the same semantics as iOS
  `CIImage.applyingGaussianBlur(sigma:)`. Verified side-by-side on Galaxy A13
  and iPhone 15 at radius 5 / 20 / 50.
* Fix displaced blurred copy of the person appearing behind them on Android
  (blur effect only): the composite sampled the blur chain with transform-baked
  camera coordinates instead of the chain's own texture coordinates.

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
  disabled below 10 fps, no crash.
* Fully on-device processing (MediaPipe `selfie_segmenter.tflite`,
  Apache-2.0, bundled; GPU compositing) — no network, no telemetry.
* Android (minSdk 24) and iOS 15.0+.
