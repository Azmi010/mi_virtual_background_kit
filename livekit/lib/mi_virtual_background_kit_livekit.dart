import 'package:livekit_client/livekit_client.dart' show LocalVideoTrack;
import 'package:mi_virtual_background_kit/mi_virtual_background_kit.dart'
    show BackgroundQuality, MiVirtualBackgroundKit, VirtualBackgroundEffect;

/// LiveKit adapter for `mi_virtual_background_kit`.
///
/// Attaches the core effect pipeline to a published local LiveKit camera track.
/// All effect logic stays in the core package; this adapter only translates the
/// track type and forwards calls.
class LiveKitVirtualBackground {
  /// Creates an adapter with its own core kit instance.
  LiveKitVirtualBackground() : _kit = MiVirtualBackgroundKit();

  final MiVirtualBackgroundKit _kit;

  /// Attaches the processor to a published local camera [track].
  ///
  /// The kit attaches to the underlying `MediaStreamTrack`, the same track the
  /// core package uses for `flutter_webrtc`. When [quality] is omitted, the core
  /// reuses the previous configuration.
  Future<void> attach(
    LocalVideoTrack track, {
    BackgroundQuality? quality,
  }) =>
      _kit.attach(track.mediaStreamTrack, quality: quality);

  /// Applies [effect] without restarting the camera track.
  Future<void> setEffect(VirtualBackgroundEffect effect) =>
      _kit.setEffect(effect);

  /// Detaches the processor. Idempotent.
  Future<void> detach() => _kit.detach();

  /// Releases native resources. Idempotent.
  Future<void> dispose() => _kit.dispose();
}
