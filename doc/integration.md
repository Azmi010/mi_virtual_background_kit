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

The recommended path is the separate adapter package
`mi_virtual_background_kit_livekit`. It depends on the core package and
`livekit_client`, so apps that do not use LiveKit never pull those dependencies.

```yaml
dependencies:
  mi_virtual_background_kit_livekit: ^0.2.0
```

```dart
import 'package:livekit_client/livekit_client.dart';
import 'package:mi_virtual_background_kit/mi_virtual_background_kit.dart';
import 'package:mi_virtual_background_kit_livekit/mi_virtual_background_kit_livekit.dart';

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

final vb = LiveKitVirtualBackground(room: room);
await vb.attach(local!);
await vb.setEffect(const BlurEffect(radius: 15));

// Later: on room teardown.
await vb.detach();
await vb.dispose();
await room.disconnect();
```

Passing `room:` lets the adapter recover after camera switch, mute/unmute,
unpublish/republish, and track restart (ADR 0002 §5). Without it, only
track-level recovery works; call `attach` again with the new track after
republish. Remote tracks and non-camera sources such as screen share are not
supported.

### Manual recipe (no extra dependency)

LiveKit's Flutter SDK is built on `flutter_webrtc`. A published local camera
track exposes its underlying `MediaStreamTrack`, which the core `attach` takes.
If you prefer not to add the adapter, wire the events yourself:

```dart
import 'package:livekit_client/livekit_client.dart';
import 'package:mi_virtual_background_kit/mi_virtual_background_kit.dart';

final kit = MiVirtualBackgroundKit();
final room = Room();

await room.connect(wsUrl, token);
await room.localParticipant!.setCameraEnabled(true);

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

With the manual recipe, re-attach after camera switch, mute, republish, and
restart — LiveKit replaces the `MediaStreamTrack` each time. Only **local,
published** camera tracks are supported; remote participants' video is not
processed. Shared camera tracks are handled in core since 0.2 (ADR 0002 §6),
so stopping other local captures first is no longer required.

A runnable adapter example lives in
[`example/lib/livekit_page.dart`](../example/lib/livekit_page.dart) (dev
server + `adb reverse`, credentials are LiveKit's public `--dev` defaults).

## Next

- Errors and odd behavior: [FAQ](faq.md)
- Numbers: [benchmark](benchmark.md)
