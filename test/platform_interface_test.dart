import 'package:flutter_test/flutter_test.dart';
import 'package:mi_virtual_background_kit/mi_virtual_background_kit_method_channel.dart';
import 'package:mi_virtual_background_kit/mi_virtual_background_kit_platform_interface.dart';

class _BarePlatform extends MiVirtualBackgroundKitPlatform {}

void main() {
  test('defaults to MethodChannelMiVirtualBackgroundKit', () {
    expect(
      MiVirtualBackgroundKitPlatform.instance,
      isA<MethodChannelMiVirtualBackgroundKit>(),
    );
  });

  late _BarePlatform platform;

  setUp(() => platform = _BarePlatform());

  void expectUnimplemented(Future<Object?> Function() call) {
    expect(call, throwsUnimplementedError);
  }

  group('unimplemented defaults', () {
    test('public API methods', () {
      expectUnimplemented(() => platform.isSupported());
      expectUnimplemented(() => platform.attach('t'));
      expectUnimplemented(() => platform.setEffect(const {}));
      expectUnimplemented(() => platform.setQuality(const {}));
      expectUnimplemented(() => platform.detach());
      expectUnimplemented(() => platform.dispose());
      expect(() => platform.statusStream, throwsUnimplementedError);
      expect(() => platform.fallbackStream, throwsUnimplementedError);
      expectUnimplemented(() => platform.getPlatformVersion());
    });

    test('spike methods', () {
      expectUnimplemented(() => platform.spikeAttach('t'));
      expectUnimplemented(() => platform.spikeFrameCount());
      expectUnimplemented(() => platform.spikeInfo());
      expectUnimplemented(() => platform.spikeBenchmarkReadback());
      expectUnimplemented(() => platform.spikeSegmentBenchmark());
      expectUnimplemented(() => platform.spikeCompositeBench());
      expectUnimplemented(() => platform.spikeReadback());
      expectUnimplemented(() => platform.spikeEnableGpu(true));
      expectUnimplemented(() => platform.spikeGpuInfo());
      expectUnimplemented(() => platform.spikeSetEnabled(true));
      expectUnimplemented(() => platform.spikeDetach('t'));
    });
  });
}
