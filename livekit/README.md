# mi_virtual_background_kit_livekit

LiveKit adapter for [`mi_virtual_background_kit`](https://pub.dev/packages/mi_virtual_background_kit).
Attach blur, image, or solid-color backgrounds to a LiveKit `LocalVideoTrack`;
the adapter keeps the effect across camera switches and track restarts.

All processing stays on-device. No network calls, no telemetry.

## Install

```yaml
dependencies:
  mi_virtual_background_kit_livekit: ^0.2.0
```

## Usage

```dart
import 'package:livekit_client/livekit_client.dart';
import 'package:mi_virtual_background_kit/mi_virtual_background_kit.dart';
import 'package:mi_virtual_background_kit_livekit/mi_virtual_background_kit_livekit.dart';

// `room` is the connected Room; `local` is a LocalVideoTrack from
// room.localParticipant!.videoTrackPublications.
final vb = LiveKitVirtualBackground(room: room);
await vb.attach(local, quality: BackgroundQuality.balanced);
await vb.setEffect(const BlurEffect(radius: 12));

await vb.detach();
await vb.dispose();
```

## Lifecycle

With `room:`, the adapter follows mechanism C from ADR 0002 §5:

- Camera switch, unmute, and track restart re-attach automatically when LiveKit
  replaces the underlying `MediaStreamTrack` (`TrackStreamUpdatedEvent`).
- Unpublish detaches; republish attaches the new camera track automatically.
- `detach` is idempotent and keeps room listeners, so republish still works.

Without `room:`, only track-level recovery works. Republish and unpublish are
not observed; call `attach` again with the new track.

Unsupported: remote tracks and non-camera sources such as screen share. Pass a
published local camera `LocalVideoTrack` only. Core errors (`InvalidTrackException`,
`UnsupportedPlatformException`) propagate unchanged.

A runnable version lives in
[`example/lib/livekit_page.dart`](https://github.com/Azmi010/mi_virtual_background_kit/blob/main/example/lib/livekit_page.dart).
The manual `flutter_webrtc` recipe, for apps that do not want the adapter
dependency, stays in
[`doc/integration.md`](https://github.com/Azmi010/mi_virtual_background_kit/blob/main/doc/integration.md).

## License

Adapter code: MIT — see [LICENSE](https://github.com/Azmi010/mi_virtual_background_kit/blob/main/LICENSE).
Dependencies: `mi_virtual_background_kit` (MIT) and `livekit_client`
(Apache-2.0). Core dependencies and their licenses are listed in the
[core README](https://github.com/Azmi010/mi_virtual_background_kit#license).
