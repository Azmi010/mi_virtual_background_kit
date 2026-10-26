import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'mi_virtual_background_kit_platform_interface.dart';
import 'src/status/status.dart';

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
  Future<void> attach(String trackId) async {
    await _guard(
      () => methodChannel.invokeMethod<void>(
        'attach',
        <String, Object?>{'trackId': trackId},
      ),
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

  @override
  Future<void> dispose() async {
    await _guard(() => methodChannel.invokeMethod<void>('dispose'));
  }

  @override
  Stream<ProcessorStatus> get statusStream {
    return eventChannel.receiveBroadcastStream().map(_statusFromEvent);
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

  // --- Spike T0.4 (temporary) ---

  @override
  Future<bool> spikeAttach(String trackId) async {
    return await methodChannel.invokeMethod<bool>(
          'spikeAttach',
          <String, dynamic>{'trackId': trackId},
        ) ??
        false;
  }

  @override
  Future<int> spikeFrameCount() async {
    return await methodChannel.invokeMethod<int>('spikeFrameCount') ?? 0;
  }

  @override
  Future<Map<dynamic, dynamic>> spikeInfo() async {
    return await methodChannel.invokeMapMethod<dynamic, dynamic>('spikeInfo') ??
        <dynamic, dynamic>{};
  }

  @override
  Future<bool> spikeBenchmarkReadback() async {
    return await methodChannel.invokeMethod<bool>('spikeBenchmarkReadback') ??
        false;
  }

  @override
  Future<Map<dynamic, dynamic>> spikeSegmentBenchmark() async {
    return await methodChannel
            .invokeMapMethod<dynamic, dynamic>('spikeSegmentBenchmark') ??
        <dynamic, dynamic>{};
  }

  @override
  Future<Map<dynamic, dynamic>> spikeCompositeBench() async {
    return await methodChannel
            .invokeMapMethod<dynamic, dynamic>('spikeCompositeBench') ??
        <dynamic, dynamic>{};
  }

  @override
  Future<Map<dynamic, dynamic>> spikeReadback() async {
    return await methodChannel
            .invokeMapMethod<dynamic, dynamic>('spikeReadback') ??
        <dynamic, dynamic>{};
  }

  @override
  Future<bool> spikeEnableGpu(bool enabled) async {
    return await methodChannel.invokeMethod<bool>(
          'spikeEnableGpu',
          <String, dynamic>{'enabled': enabled},
        ) ??
        false;
  }

  @override
  Future<Map<dynamic, dynamic>> spikeGpuInfo() async {
    return await methodChannel
            .invokeMapMethod<dynamic, dynamic>('spikeGpuInfo') ??
        <dynamic, dynamic>{};
  }

  @override
  Future<bool> spikeSetEnabled(bool enabled) async {
    return await methodChannel.invokeMethod<bool>(
          'spikeSetEnabled',
          <String, dynamic>{'enabled': enabled},
        ) ??
        false;
  }

  @override
  Future<bool> spikeDetach(String trackId) async {
    return await methodChannel.invokeMethod<bool>(
          'spikeDetach',
          <String, dynamic>{'trackId': trackId},
        ) ??
        false;
  }
}
