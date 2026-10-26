import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'mi_virtual_background_kit_platform_interface.dart';

/// An implementation of [MiVirtualBackgroundKitPlatform] that uses method channels.
class MethodChannelMiVirtualBackgroundKit
    extends MiVirtualBackgroundKitPlatform {
  /// The method channel used to interact with the native platform.
  @visibleForTesting
  final methodChannel = const MethodChannel('mi_virtual_background_kit');

  @override
  Future<String?> getPlatformVersion() async {
    final version = await methodChannel.invokeMethod<String>(
      'getPlatformVersion',
    );
    return version;
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
