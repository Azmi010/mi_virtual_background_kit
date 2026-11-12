# FAQ & troubleshooting

Entries come from problems actually hit during development of this package.

## 1. Camera preview is black after `attach`

The kit never touches the renderer — a black preview is a `flutter_webrtc`
issue: check the `RTCVideoRenderer.srcObject = stream` assignment, the
permission prompt, and that you pass the track of the *live* stream (not a
stopped/disposed one). Verify with `NoEffect`: if the preview is still black,
the problem is upstream of this package.

## 2. `InvalidTrackException: track has no id`

`attach` was called before `getUserMedia` finished, on a disposed track, or on
a non-video track. Attach only `stream.getVideoTracks().first` from a stream
you just created.

## 3. `UnsupportedPlatformException` on attach

`await kit.isSupported()` returned (or would return) `false`. Reasons:

- Android below minSdk 24, or no OpenGL ES 2.0, or the bundled model file is
  missing from the APK.
- iOS below 15.0, no Metal GPU, or model resource not bundled.

## 4. `setEffect` runs but the picture never changes

Effects only apply **after** a successful `attach`. Listen to `statusStream`:
the effect shows once status reaches `active`. Also `setEffect` before
`attach` is remembered and applied on attach — but if attach itself failed
(see #2/#3), nothing renders.

## 5. Video got choppy on my old phone

Segmentation is the cost center; 32-bit devices are ~10× slower. Do, in order:

1. `BackgroundQuality.low` at `attach` time (or `setQuality` at runtime).
2. Listen to `fallbackStream` — the kit already degrades quality and can
   disable the effect by itself; tell the user instead of freezing.
3. Offer `NoEffect` as an escape hatch in your UI.

Numbers per device class: [benchmark.md](benchmark.md).

## 6. Effect disappears after switching cameras

The native processor is rebuilt on camera switch. Re-attach with the same
track — the kit re-applies your last effect automatically:

```dart
await Helper.switchCamera(track);
await kit.attach(track);
```

## 7. `modelLoadFailed`

The bundled `selfie_segmenter.tflite` (250 KB) did not load. Usual causes:
a custom build stripped plugin resources, a split APK is missing the asset
arm, or ProGuard removed a MediaPipe class. A plain `flutter build apk`/`ipa`
is fine; check your shrinking config if you changed it.

## 8. Background image does not show (`invalidImage` or nothing)

- Asset source: the file must be listed under `flutter: assets:` in your
  `pubspec.yaml`, and the path is the asset key (`assets/office.jpg`).
- File source: the path must be readable by the app (use the app documents
  directory, not a temp path from another process).
- Bytes source: empty bytes throw `InvalidImageException` in Dart before
  reaching native.

## 9. iOS build fails or `pod install` errors

- Deployment target must be ≥ 15.0.
- `flutter_webrtc` must resolve inside `^1.6.2`; if pods fight over its
  version, run `pod install --repo-update` from `example/ios` and retry.
- On Flutter < 3.48 there is an SPM linking bug for plugin packages; this repo
  ships `tool/link_example_build.sh` as the workaround (CI uses it).

## 10. After background→foreground the app fell back / effect disabled

The FPS monitor resets when the frame gap exceeds 1 s, so this should not
happen; if it does, it is a genuine drop (screen off, thermal throttle).
`fallbackStream` events are the source of truth — re-apply your effect with
`setEffect` once status returns to `active`.

## 11. Does it process remote participants' video?

No — by design (PRD non-goal). Only the local camera track is supported.

## 12. Will my app size grow a lot?

Model is 250 KB (Apache-2.0) bundled as an asset. MediaPipe task libs add a
few MB per architecture; no download happens at runtime, ever.

## 13. LiveKit: which track do I attach?

The published *local* camera track's underlying `MediaStreamTrack` — see the
[LiveKit recipe](integration.md#livekit). Remote tracks are not supported.
Shared camera tracks (a second `getUserMedia` reusing an open camera session)
are handled since 0.2: `attach` redirects to the track that actually receives
frames (ADR 0002 §6).

## 14. `dart doc` crashes with `RangeError` in `_stripDocImports`

Known bug in the dartdoc version bundled with some Flutter SDKs (fixed in
dartdoc ≥ 9.0.7), triggered by dependency doc comments — not by this package.
Workaround: `dart pub global activate dartdoc 9.0.11 && dart pub global run
dartdoc`.

## 15. Installed debug APK stays on the Flutter splash screen

Observed on the A1 test device when the debug APK was built while
`example/build` was a symlink created by `tool/link_example_build.sh` (that
script exists only for the Flutter < 3.48 iOS/SPM copy bug — run it for iOS
builds, then restore a real `example/build` directory before building the
Android APK). `flutter run` still worked; a freshly installed standalone APK
from the symlinked build hung before the first frame. Rebuild from a real
`example/build` directory and reinstall.
