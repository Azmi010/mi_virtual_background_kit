## Catatan kebijakan 0.x

Selama versi 0.x, perubahan yang memecah kode konsumen (subclass baru pada
`sealed class VirtualBackgroundEffect`, kode error baru pada `BackgroundException`)
diizinkan pada versi **minor** dan entri CHANGELOG-nya diawali **Breaking:**.
Field baru `BackgroundQuality` bukan breaking selama punya nilai bawaan yang
mempertahankan perilaku versi sebelumnya. Rincian: ADR 0002 butir 9.

## 0.2.0 (belum dirilis)

* **Breaking:** enum `FallbackAction` bertambah nilai `recovered` (FR-21) —
  `switch` eksaustif atas `FallbackAction` di kode konsumen perlu satu cabang
  baru (kebijakan ADR 0002 butir 9: minor + catatan Breaking).
* Fallback recovery (FR-21): API baru `MiVirtualBackgroundKit.resumeEffect()`
  menyalakan kembali efek terakhir setelah fallback tahap 2 mematikannya, dan
  opsi `BackgroundQuality.autoRecovery` (bawaan `false`) memulihkan efek serta
  kualitas segmentasi yang terdegradasi secara otomatis setelah fps stabil,
  memancarkan event `FallbackAction.recovered`. Pemulihan otomatis bersifat
  satu-kali per intervensi manual (latch) agar perangkat lambat tidak
  berfluktuasi antara aktif/nonaktif.
* `attach()` tanpa parameter `quality` kini memakai konfigurasi quality
  terakhir (kamera switch tidak lagi mengembalikan `BackgroundQuality` ke
  default, termasuk flag `autoRecovery`).

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
  `CIImage.applyingGaussianBlur(sigma:)`. Verified side-by-side on SM-A135F
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
  disabled below 10 fps (FR-12), no crash.
* Fully on-device processing (MediaPipe `selfie_segmenter.tflite`,
  Apache-2.0, bundled; GPU compositing) — no network, no telemetry.
* Android (minSdk 24) and iOS 15.0+.
