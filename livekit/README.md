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

// `local` is a LocalVideoTrack from room.localParticipant!.videoTrackPublications.
final vb = LiveKitVirtualBackground();
await vb.attach(local, quality: BackgroundQuality.balanced);
await vb.setEffect(const BlurEffect(radius: 12));

await vb.detach();
await vb.dispose();
```

The manual `flutter_webrtc` recipe stays available in
[`doc/integration.md`](https://github.com/Azmi010/mi_virtual_background_kit/blob/main/doc/integration.md).

## License

MIT — see [LICENSE](LICENSE).
