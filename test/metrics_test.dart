import 'package:flutter_test/flutter_test.dart';
import 'package:mi_virtual_background_kit/mi_virtual_background_kit.dart';
import 'package:mi_virtual_background_kit/src/platform/mi_virtual_background_kit_method_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('BackgroundMetrics', () {
    test('round-trips through toMap/fromMap', () {
      const m = BackgroundMetrics(
        outputFps: 29.5,
        segmentationLatencyMs: 12.0,
        maskAgeMs: 83.3,
        processorLatencyMs: 4.2,
      );
      final restored = BackgroundMetrics.fromMap(m.toMap());
      expect(restored, m);
      expect(restored.processorLatencyMs, 4.2);
    });

    test('fromMap tolerates missing optional fields', () {
      final m = BackgroundMetrics.fromMap(<dynamic, dynamic>{'outputFps': 30});
      expect(m.outputFps, 30.0);
      expect(m.segmentationLatencyMs, isNull);
      expect(m.maskAgeMs, isNull);
      expect(m.processorLatencyMs, isNull);
    });

    test('fromMap defaults outputFps to 0 when absent', () {
      final m = BackgroundMetrics.fromMap(const <dynamic, dynamic>{});
      expect(m.outputFps, 0.0);
    });

    test('fromMap accepts ints from the platform channel', () {
      final m = BackgroundMetrics.fromMap(<dynamic, dynamic>{
        'outputFps': 30,
        'segmentationLatencyMs': 7,
        'maskAgeMs': 120,
      });
      expect(m.outputFps, 30.0);
      expect(m.segmentationLatencyMs, 7.0);
      expect(m.maskAgeMs, 120.0);
    });

    test('equality and toString', () {
      const a = BackgroundMetrics(outputFps: 24.0);
      const b = BackgroundMetrics(outputFps: 24.0);
      const c = BackgroundMetrics(outputFps: 25.0);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(c));
      expect(a.toString(), contains('BackgroundMetrics'));
    });
  });

  group('metricsStream', () {
    late MethodChannelMiVirtualBackgroundKit platform;

    setUp(() => platform = MethodChannelMiVirtualBackgroundKit());

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockStreamHandler(platform.metricsEventChannel, null);
    });

    test('maps native maps to BackgroundMetrics and ignores other events',
        () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockStreamHandler(
        platform.metricsEventChannel,
        MockStreamHandler.inline(
          onListen: (Object? arguments, MockStreamHandlerEventSink events) {
            events
              ..success(<dynamic, dynamic>{
                'outputFps': 28.4,
                'segmentationLatencyMs': 91.0,
                'maskAgeMs': 250.0,
              })
              ..success(<dynamic, dynamic>{'outputFps': 30.0})
              // A non-map event must be filtered out, not crash.
              ..success('idle')
              ..endOfStream();
          },
        ),
      );

      final samples = await platform.metricsStream.toList();
      expect(samples, hasLength(2));
      expect(samples[0].outputFps, 28.4);
      expect(samples[0].segmentationLatencyMs, 91.0);
      expect(samples[0].maskAgeMs, 250.0);
      expect(samples[1].outputFps, 30.0);
      expect(samples[1].segmentationLatencyMs, isNull);
    });
  });
}
