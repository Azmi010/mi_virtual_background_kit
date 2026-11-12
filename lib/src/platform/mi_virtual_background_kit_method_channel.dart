import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'mi_virtual_background_kit_platform_interface.dart';
import '../fallback/fallback.dart';
import '../status/status.dart';

/// An implementation of [MiVirtualBackgroundKitPlatform] that uses method channels.
class MethodChannelMiVirtualBackgroundKit
    extends MiVirtualBackgroundKitPlatform {
  /// The method channel used to interact with the native platform.
  @visibleForTesting
  final methodChannel = const MethodChannel('mi_virtual_background_kit');

  /// The event channel streaming processor status updates.
  @visibleForTesting
  final eventChannel = const EventChannel('mi_virtual_background_kit/status');

  @override
  Future<bool> isSupported() async {
    final result = await _guard(
      () => methodChannel.invokeMethod<bool>('isSupported'),
    );
    return result ?? false;
  }

  @override
  Future<void> attach(String trackId, {Map<String, Object?>? quality}) async {
    await _guard(
      () => methodChannel.invokeMethod<void>(
        'attach',
        <String, Object?>{
          'trackId': trackId,
          if (quality != null) 'quality': quality,
        },
      ),
    );
  }

  @override
  Future<void> setQuality(Map<String, Object?> quality) async {
    await _guard(
      () => methodChannel.invokeMethod<void>('setQuality', quality),
    );
  }

  @override
  Future<void> setEffect(Map<String, Object?> effect) async {
    await _guard(
      () => methodChannel.invokeMethod<void>('setEffect', effect),
    );
  }

  @override
  Future<void> detach() async {
    await _guard(() => methodChannel.invokeMethod<void>('detach'));
  }

  /// T14.2/T14.3 measurement hook: overrides mask smoothing
  /// (`mode`: `none`/`ema`/`adaptive`, `value` 0..1, optional `d0`).
  /// Not part of the public API; used by the example's flicker-test page.
  Future<void> testSetSmoothing(
    String? mode,
    double value, {
    double? d0,
  }) async {
    await _guard(
      () => methodChannel.invokeMethod<void>(
        'testSetSmoothing',
        <String, Object?>{
          'mode': mode,
          'value': value,
          if (d0 != null) 'd0': d0,
        },
      ),
    );
  }

  /// T14.2/T14.3 measurement hook: tags subsequent `T133|` metric lines
  /// and resets the smoothing history.
  Future<void> testSetStage(String stage) async {
    await _guard(
      () => methodChannel.invokeMethod<void>(
        'testSetStage',
        <String, Object?>{'stage': stage},
      ),
    );
  }

  /// T14.4 measurement hook: forces one native performance-window evaluation
  /// at [fps] (stage-1 degrade below 14, stage-2 disable below 10 with two
  /// consecutive calls, recovery at >= 20 with `autoRecovery`). Not part of
  /// the public API; used by `example/integration_test/fallback_recovery_test.dart`.
  Future<void> testSimulateFps(double fps) async {
    await _guard(
      () => methodChannel.invokeMethod<void>(
        'testSimulateFps',
        <String, Object?>{'fps': fps},
      ),
    );
  }

  @override
  Future<void> dispose() async {
    await _guard(() => methodChannel.invokeMethod<void>('dispose'));
  }

  Stream<dynamic>? _rawBroadcastStream;

  Stream<dynamic> get _broadcastStream =>
      _rawBroadcastStream ??= eventChannel.receiveBroadcastStream();

  @override
  Stream<ProcessorStatus> get statusStream {
    return _broadcastStream
        .where((event) => event is String)
        .map(_statusFromEvent);
  }

  @override
  Stream<PerformanceFallbackEvent> get fallbackStream {
    return _broadcastStream
        .where((event) => event is Map)
        .map((event) => PerformanceFallbackEvent.fromMap(event as Map));
  }

  ProcessorStatus _statusFromEvent(dynamic event) {
    switch (event) {
      case 'initializing':
        return ProcessorStatus.initializing;
      case 'active':
        return ProcessorStatus.active;
      case 'error':
        return ProcessorStatus.error;
      default:
        return ProcessorStatus.idle;
    }
  }

  /// Invokes [call], mapping native error codes (FR-08) to typed exceptions.
  Future<T?> _guard<T>(Future<T?> Function() call) async {
    try {
      return await call();
    } on PlatformException catch (e) {
      final mapped = _mapErrorCode(e);
      if (mapped != null) throw mapped;
      rethrow;
    }
  }

  BackgroundException? _mapErrorCode(PlatformException e) {
    switch (e.code) {
      case 'unsupportedPlatform':
        return UnsupportedPlatformException(e.message);
      case 'modelLoadFailed':
        return ModelLoadFailedException(e.message);
      case 'invalidTrack':
        return InvalidTrackException(e.message);
      case 'invalidImage':
        return InvalidImageException(e.message);
      default:
        return null;
    }
  }
}
