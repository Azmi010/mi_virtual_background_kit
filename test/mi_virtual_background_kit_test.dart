import 'package:flutter_test/flutter_test.dart';
import 'package:mi_virtual_background_kit/mi_virtual_background_kit.dart';
import 'package:mi_virtual_background_kit/mi_virtual_background_kit_platform_interface.dart';
import 'package:mi_virtual_background_kit/mi_virtual_background_kit_method_channel.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class MockMiVirtualBackgroundKitPlatform
    with MockPlatformInterfaceMixin
    implements MiVirtualBackgroundKitPlatform {
  @override
  Future<String?> getPlatformVersion() => Future.value('42');

  @override
  Future<bool> spikeAttach(String trackId) => Future.value(true);

  @override
  Future<int> spikeFrameCount() => Future.value(0);

  @override
  Future<Map<dynamic, dynamic>> spikeInfo() => Future.value({});

  @override
  Future<bool> spikeBenchmarkReadback() => Future.value(true);

  @override
  Future<Map<dynamic, dynamic>> spikeSegmentBenchmark() => Future.value({});

  @override
  Future<Map<dynamic, dynamic>> spikeCompositeBench() => Future.value({});

  @override
  Future<Map<dynamic, dynamic>> spikeReadback() => Future.value({});

  @override
  Future<bool> spikeEnableGpu(bool enabled) => Future.value(true);

  @override
  Future<Map<dynamic, dynamic>> spikeGpuInfo() => Future.value({});

  @override
  Future<bool> spikeSetEnabled(bool enabled) => Future.value(true);

  @override
  Future<bool> spikeDetach(String trackId) => Future.value(true);
}

void main() {
  final MiVirtualBackgroundKitPlatform initialPlatform =
      MiVirtualBackgroundKitPlatform.instance;

  test('$MethodChannelMiVirtualBackgroundKit is the default instance', () {
    expect(
        initialPlatform, isInstanceOf<MethodChannelMiVirtualBackgroundKit>());
  });

  test('getPlatformVersion', () async {
    MiVirtualBackgroundKit miVirtualBackgroundKitPlugin =
        MiVirtualBackgroundKit();
    MockMiVirtualBackgroundKitPlatform fakePlatform =
        MockMiVirtualBackgroundKitPlatform();
    MiVirtualBackgroundKitPlatform.instance = fakePlatform;

    expect(await miVirtualBackgroundKitPlugin.getPlatformVersion(), '42');
  });
}
