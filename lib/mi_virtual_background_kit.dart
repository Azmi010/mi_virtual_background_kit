import 'mi_virtual_background_kit_platform_interface.dart';

class MiVirtualBackgroundKit {
  Future<String?> getPlatformVersion() {
    return MiVirtualBackgroundKitPlatform.instance.getPlatformVersion();
  }

  // --- Spike T0.4 (temporary) ---

  Future<bool> spikeAttach(String trackId) =>
      MiVirtualBackgroundKitPlatform.instance.spikeAttach(trackId);

  Future<int> spikeFrameCount() => MiVirtualBackgroundKitPlatform.instance.spikeFrameCount();

  Future<Map<dynamic, dynamic>> spikeInfo() =>
      MiVirtualBackgroundKitPlatform.instance.spikeInfo();

  Future<bool> spikeBenchmarkReadback() =>
      MiVirtualBackgroundKitPlatform.instance.spikeBenchmarkReadback();

  Future<Map<dynamic, dynamic>> spikeSegmentBenchmark() =>
      MiVirtualBackgroundKitPlatform.instance.spikeSegmentBenchmark();

  Future<Map<dynamic, dynamic>> spikeCompositeBench() =>
      MiVirtualBackgroundKitPlatform.instance.spikeCompositeBench();

  Future<Map<dynamic, dynamic>> spikeReadback() =>
      MiVirtualBackgroundKitPlatform.instance.spikeReadback();

  Future<bool> spikeEnableGpu(bool enabled) =>
      MiVirtualBackgroundKitPlatform.instance.spikeEnableGpu(enabled);

  Future<Map<dynamic, dynamic>> spikeGpuInfo() =>
      MiVirtualBackgroundKitPlatform.instance.spikeGpuInfo();

  Future<bool> spikeSetEnabled(bool enabled) =>
      MiVirtualBackgroundKitPlatform.instance.spikeSetEnabled(enabled);

  Future<bool> spikeDetach(String trackId) =>
      MiVirtualBackgroundKitPlatform.instance.spikeDetach(trackId);
}
