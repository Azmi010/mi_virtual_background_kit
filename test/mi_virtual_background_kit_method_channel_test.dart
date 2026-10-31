import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mi_virtual_background_kit/mi_virtual_background_kit_method_channel.dart';
import 'package:mi_virtual_background_kit/src/status/status.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MethodChannelMiVirtualBackgroundKit platform;
  late MethodChannel channel;
  final List<MethodCall> log = <MethodCall>[];

  void mockHandler(Future<Object?>? Function(MethodCall call) handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
      log.add(methodCall);
      return handler(methodCall);
    });
  }

  setUp(() {
    platform = MethodChannelMiVirtualBackgroundKit();
    channel = platform.methodChannel;
    log.clear();
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  group('method channel calls', () {
    test('isSupported', () async {
      mockHandler((_) async => true);
      expect(await platform.isSupported(), isTrue);
      expect(log.single.method, 'isSupported');
    });

    test('isSupported defaults to false when null', () async {
      mockHandler((_) async => null);
      expect(await platform.isSupported(), isFalse);
    });

    test('attach sends trackId', () async {
      mockHandler((_) async => null);
      await platform.attach('track-9');
      expect(log.single.method, 'attach');
      expect(log.single.arguments, <String, Object?>{'trackId': 'track-9'});
    });

    test('attach sends trackId and quality', () async {
      mockHandler((_) async => null);
      await platform.attach('track-9', quality: const <String, Object?>{
        'segmentationWidth': 256,
        'edgeSmoothing': 0.5,
        'targetFps': 30,
      });
      expect(log.single.method, 'attach');
      expect(log.single.arguments, <String, Object?>{
        'trackId': 'track-9',
        'quality': const <String, Object?>{
          'segmentationWidth': 256,
          'edgeSmoothing': 0.5,
          'targetFps': 30,
        },
      });
    });

    test('setQuality sends quality map', () async {
      mockHandler((_) async => null);
      await platform.setQuality(const <String, Object?>{
        'segmentationWidth': 512,
        'edgeSmoothing': 1.0,
        'targetFps': 60,
      });
      expect(log.single.method, 'setQuality');
      expect(log.single.arguments, const <String, Object?>{
        'segmentationWidth': 512,
        'edgeSmoothing': 1.0,
        'targetFps': 60,
      });
    });

    test('setEffect sends serialized map', () async {
      mockHandler((_) async => null);
      await platform.setEffect(<String, Object?>{
        'type': 'blur',
        'radius': 5.0,
      });
      expect(log.single.method, 'setEffect');
      expect(log.single.arguments, <String, Object?>{
        'type': 'blur',
        'radius': 5.0,
      });
    });

    test('detach', () async {
      mockHandler((_) async => null);
      await platform.detach();
      expect(log.single.method, 'detach');
    });

    test('dispose', () async {
      mockHandler((_) async => null);
      await platform.dispose();
      expect(log.single.method, 'dispose');
    });
  });

  group('FR-08 error mapping', () {
    Future<void> expectMapped(
      String code,
      Type expectedType,
    ) async {
      mockHandler((_) async {
        throw PlatformException(code: code, message: 'msg for $code');
      });
      await expectLater(
        platform.detach(),
        throwsA(
          isA<BackgroundException>()
              .having((e) => e.code, 'code', code)
              .having((e) => e.runtimeType, 'runtimeType', expectedType)
              .having((e) => e.message, 'message', 'msg for $code'),
        ),
      );
    }

    test('unsupportedPlatform', () async {
      await expectMapped('unsupportedPlatform', UnsupportedPlatformException);
    });

    test('modelLoadFailed', () async {
      await expectMapped('modelLoadFailed', ModelLoadFailedException);
    });

    test('invalidTrack', () async {
      await expectMapped('invalidTrack', InvalidTrackException);
    });

    test('invalidImage', () async {
      await expectMapped('invalidImage', InvalidImageException);
    });

    test('unknown code rethrows PlatformException', () async {
      mockHandler((_) async {
        throw PlatformException(code: 'somethingElse');
      });
      await expectLater(
        platform.detach(),
        throwsA(isA<PlatformException>()
            .having((e) => e.code, 'code', 'somethingElse')),
      );
    });
  });

  group('statusStream', () {
    test('maps event names to ProcessorStatus', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockStreamHandler(
        platform.eventChannel,
        MockStreamHandler.inline(
          onListen: (Object? arguments, MockStreamHandlerEventSink events) {
            events
              ..success('initializing')
              ..success('active')
              ..success('error')
              ..success('idle')
              ..success('unknown-value')
              ..endOfStream();
          },
        ),
      );

      final statuses = await platform.statusStream.toList();
      expect(statuses, <ProcessorStatus>[
        ProcessorStatus.initializing,
        ProcessorStatus.active,
        ProcessorStatus.error,
        ProcessorStatus.idle,
        ProcessorStatus.idle,
      ]);
    });
  });

  group('spike methods (temporary)', () {
    test('each spike method invokes its channel call', () async {
      mockHandler((MethodCall call) async {
        if (call.method.contains('FrameCount')) return 7;
        if (call.method == 'spikeAttach' ||
            call.method == 'spikeDetach' ||
            call.method == 'spikeBenchmarkReadback' ||
            call.method == 'spikeEnableGpu' ||
            call.method == 'spikeSetEnabled') {
          return true;
        }
        return <dynamic, dynamic>{'k': 'v'};
      });

      expect(await platform.spikeAttach('t'), isTrue);
      expect(await platform.spikeFrameCount(), 7);
      expect(await platform.spikeInfo(), <dynamic, dynamic>{'k': 'v'});
      expect(await platform.spikeBenchmarkReadback(), isTrue);
      expect(
        await platform.spikeSegmentBenchmark(),
        <dynamic, dynamic>{'k': 'v'},
      );
      expect(
        await platform.spikeCompositeBench(),
        <dynamic, dynamic>{'k': 'v'},
      );
      expect(await platform.spikeReadback(), <dynamic, dynamic>{'k': 'v'});
      expect(await platform.spikeEnableGpu(false), isTrue);
      expect(await platform.spikeGpuInfo(), <dynamic, dynamic>{'k': 'v'});
      expect(await platform.spikeSetEnabled(true), isTrue);
      expect(await platform.spikeDetach('t'), isTrue);

      expect(
        log.map((c) => c.method),
        containsAll(<String>[
          'spikeAttach',
          'spikeFrameCount',
          'spikeInfo',
          'spikeBenchmarkReadback',
          'spikeSegmentBenchmark',
          'spikeCompositeBench',
          'spikeReadback',
          'spikeEnableGpu',
          'spikeGpuInfo',
          'spikeSetEnabled',
          'spikeDetach',
        ]),
      );
    });

    test('null map results fall back to empty map', () async {
      mockHandler((_) async => null);
      expect(await platform.spikeInfo(), isEmpty);
      expect(await platform.spikeSegmentBenchmark(), isEmpty);
      expect(await platform.spikeCompositeBench(), isEmpty);
      expect(await platform.spikeReadback(), isEmpty);
      expect(await platform.spikeGpuInfo(), isEmpty);
    });
  });
}
