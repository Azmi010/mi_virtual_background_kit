# Integration guide

How to attach `mi_virtual_background_kit` to camera tracks from
`flutter_webrtc` and from LiveKit. Verified on device with the app in
[`example/`](../example) (Android: Samsung SM-A135F, iOS: iPhone 15).

## Common rules

- Create the camera track first (`getUserMedia` or LiveKit publish), then
  `kit.attach(track)`. Attaching a disposed or id-less track throws
  `InvalidTrackException`.
- Check `await kit.isSupported()` first; on `false` the platform throws
  `UnsupportedPlatformException` on attach.
- One `MiVirtualBackgroundKit` instance per camera track. Call `detach()` when
  the track stops and `dispose()` when the widget/page is torn down (both are
  idempotent).
- Listen to `statusStream` (`idle` → `initializing` → `active`, or `error`) and
  `fallbackStream` to surface performance problems to the user.

## flutter_webrtc

```dart
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:mi_virtual_background_kit/mi_virtual_background_kit.dart';

final kit = MiVirtualBackgroundKit();

// 1. Camera track.
final stream = await navigator.mediaDevices.getUserMedia(const {
  'audio': false,
  'video': {'facingMode': 'user', 'width': 640, 'height': 480},
});
final track = stream.getVideoTracks().first;

// 2. Attach + effect.
if (await kit.isSupported()) {
  await kit.attach(track, quality: BackgroundQuality.balanced);
  await kit.setEffect(const BlurEffect(radius: 12));
}

// 3. Switch effects at runtime — the track is never restarted.
await kit.setEffect(ImageEffect.asset('assets/office.jpg'));
await kit.setEffect(const ColorEffect(Color(0xFF0E1114)));
await kit.setEffect(const NoEffect());

// 4. Teardown.
await kit.detach();
await kit.dispose();
for (final t in stream.getTracks()) {
  t.stop();
}
```

### Switching cameras (front/back)

`Helper.switchCamera(track)` from `flutter_webrtc` keeps the same track id, but
the native processor is rebuilt. Re-attach afterwards — the kit re-applies the
last effect automatically:

```dart
await Helper.switchCamera(track);
await kit.attach(track); // effect from step 2 survives the switch
```

### Performance

- Defaults are conservative (segmentation input 256 px, 30 fps composite).
  On low-end devices use `BackgroundQuality.low`, or lower values via
  `kit.setQuality(...)`.
- If the device still cannot keep up, the kit downgrades quality and finally
  disables the effect on its own, emitting events on `fallbackStream` — show a
  SnackBar and offer `setEffect(...)` again when the load drops.

## LiveKit

Works because LiveKit's Flutter SDK (`livekit_client`) is built on
`flutter_webrtc`: a published local camera track exposes the underlying
`MediaStreamTrack`, which is what `attach` takes. No LiveKit dependency is
pulled into this package.

```dart
import 'package:livekit_client/livekit_client.dart';
import 'package:mi_virtual_background_kit/mi_virtual_background_kit.dart';

final kit = MiVirtualBackgroundKit();
final room = Room();

await room.connect(wsUrl, token);
await room.localParticipant!.setCameraEnabled(true);

// Wait until the camera publication exists, then grab the track.
LocalVideoTrack? local;
while (local == null) {
  await Future<void>.delayed(const Duration(milliseconds: 100));
  for (final p in room.localParticipant!.videoTrackPublications) {
    final t = p.track;
    if (t is LocalVideoTrack) local = t;
  }
}

await kit.attach(local!.mediaStreamTrack);
await kit.setEffect(const BlurEffect(radius: 15));

// Later: on room teardown.
await kit.dispose();
await room.disconnect();
```

Notes:

- Only **local, published** camera tracks. Remote participants' video is not
  processed (see README limitations).
- **Stop other local camera captures first.** `flutter_webrtc` reuses an
  already-open camera session for a second `getUserMedia` (to avoid an
  Android Camera2 bug), but such *shared* tracks are not wired to the
  frame-processor pipeline — `attach` succeeds yet effects never render.
  Stop and dispose your other `MediaStream`s before connecting LiveKit (the
  example does exactly this in `_openLiveKit`).
- If the user switches camera through LiveKit, re-attach the kit the same way
  as in the flutter_webrtc section.
- A runnable version of this recipe lives in
  [`example/lib/livekit_page.dart`](../example/lib/livekit_page.dart) (dev
  server + `adb reverse`, credentials are LiveKit's public `--dev` defaults).

## Next

- Errors and odd behavior: [FAQ](faq.md)
- Numbers: [benchmark](benchmark.md)
