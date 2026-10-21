import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'mi_virtual_background_kit_method_channel.dart';

abstract class MiVirtualBackgroundKitPlatform extends PlatformInterface {
  /// Constructs a MiVirtualBackgroundKitPlatform.
  MiVirtualBackgroundKitPlatform() : super(token: _token);

  static final Object _token = Object();

  static MiVirtualBackgroundKitPlatform _instance = MethodChannelMiVirtualBackgroundKit();

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

  Future<String?> getPlatformVersion() {
    throw UnimplementedError('platformVersion() has not been implemented.');
  }

  // --- Spike T0.4 (temporary) ---

  Future<bool> spikeAttach(String trackId) {
    throw UnimplementedError('spikeAttach() has not been implemented.');
  }

  Future<int> spikeFrameCount() {
    throw UnimplementedError('spikeFrameCount() has not been implemented.');
  }

  Future<Map<dynamic, dynamic>> spikeInfo() {
    throw UnimplementedError('spikeInfo() has not been implemented.');
  }

  Future<bool> spikeBenchmarkReadback() {
    throw UnimplementedError('spikeBenchmarkReadback() has not been implemented.');
  }

  Future<Map<dynamic, dynamic>> spikeSegmentBenchmark() {
    throw UnimplementedError('spikeSegmentBenchmark() has not been implemented.');
  }

  Future<Map<dynamic, dynamic>> spikeReadback() {
    throw UnimplementedError('spikeReadback() has not been implemented.');
  }

  Future<bool> spikeEnableGpu(bool enabled) {
    throw UnimplementedError('spikeEnableGpu() has not been implemented.');
  }

  Future<Map<dynamic, dynamic>> spikeGpuInfo() {
    throw UnimplementedError('spikeGpuInfo() has not been implemented.');
  }

  Future<bool> spikeSetEnabled(bool enabled) {
    throw UnimplementedError('spikeSetEnabled() has not been implemented.');
  }

  Future<bool> spikeDetach(String trackId) {
    throw UnimplementedError('spikeDetach() has not been implemented.');
  }
}
