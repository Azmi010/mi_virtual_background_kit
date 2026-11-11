import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'mi_virtual_background_kit_method_channel.dart';
import '../fallback/fallback.dart';
import '../status/status.dart';

/// Platform interface that implementations of mi_virtual_background_kit must
/// extend (federated-plugin contract).
abstract class MiVirtualBackgroundKitPlatform extends PlatformInterface {
  /// Constructs a MiVirtualBackgroundKitPlatform.
  MiVirtualBackgroundKitPlatform() : super(token: _token);

  static final Object _token = Object();

  static MiVirtualBackgroundKitPlatform _instance =
      MethodChannelMiVirtualBackgroundKit();

  /// The default instance of [MiVirtualBackgroundKitPlatform] to use.
  ///
  /// Defaults to [MethodChannelMiVirtualBackgroundKit].
  static MiVirtualBackgroundKitPlatform get instance => _instance;

  /// Platform-specific implementations should set this with their own
  /// platform-specific class that extends [MiVirtualBackgroundKitPlatform] when
  /// they register themselves.
  static set instance(MiVirtualBackgroundKitPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  // --- Public API (Fase 2) ---

  /// Whether this device/OS can run background processing.
  Future<bool> isSupported() {
    throw UnimplementedError('isSupported() has not been implemented.');
  }

  /// Attaches the processor to the camera track with the given [trackId] and optional [quality].
  Future<void> attach(String trackId, {Map<String, Object?>? quality}) {
    throw UnimplementedError('attach() has not been implemented.');
  }

  /// Updates the processing [quality] configuration at runtime.
  Future<void> setQuality(Map<String, Object?> quality) {
    throw UnimplementedError('setQuality() has not been implemented.');
  }

  /// Applies [effect] (already serialized via `toMap()`).
  Future<void> setEffect(Map<String, Object?> effect) {
    throw UnimplementedError('setEffect() has not been implemented.');
  }

  /// Detaches the processor from the current track.
  Future<void> detach() {
    throw UnimplementedError('detach() has not been implemented.');
  }

  /// Releases native resources.
  Future<void> dispose() {
    throw UnimplementedError('dispose() has not been implemented.');
  }

  /// Status updates from the native processor.
  Stream<ProcessorStatus> get statusStream {
    throw UnimplementedError('statusStream has not been implemented.');
  }

  /// Stream of automatic performance fallback events (FR-12).
  Stream<PerformanceFallbackEvent> get fallbackStream {
    throw UnimplementedError('fallbackStream has not been implemented.');
  }
}
