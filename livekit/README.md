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

The adapter API lands in 0.2.0. Until then, use the manual recipe in
[`doc/integration.md`](https://github.com/Azmi010/mi_virtual_background_kit/blob/main/doc/integration.md).

## License

MIT — see [LICENSE](LICENSE).
