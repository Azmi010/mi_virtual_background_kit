import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mi_virtual_background_kit/src/platform/mi_virtual_background_kit_method_channel.dart';
import 'package:mi_virtual_background_kit/src/fallback/fallback.dart';
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

    test('setQuality sends maskTemporalSmoothing', () async {
      mockHandler((_) async => null);
      await platform.setQuality(const <String, Object?>{
        'segmentationWidth': 256,
        'edgeSmoothing': 0.5,
        'targetFps': 30,
        'maskTemporalSmoothing': 0.7,
      });
      expect(log.single.method, 'setQuality');
      expect(
        (log.single.arguments as Map)['maskTemporalSmoothing'],
        0.7,
      );
    });

    test('testSetSmoothing sends mode, value, and optional d0', () async {
      mockHandler((_) async => null);
      await platform.testSetSmoothing('adaptive', 0.7, d0: 0.12);
      expect(log.single.method, 'testSetSmoothing');
      expect(log.single.arguments, <String, Object?>{
        'mode': 'adaptive',
        'value': 0.7,
        'd0': 0.12,
      });

      log.clear();
      await platform.testSetSmoothing('none', 0.0);
      expect(log.single.arguments, <String, Object?>{
        'mode': 'none',
        'value': 0.0,
      });
    });

    test('testSetStage sends stage tag', () async {
      mockHandler((_) async => null);
      await platform.testSetStage('still');
      expect(log.single.method, 'testSetStage');
      expect(log.single.arguments, <String, Object?>{'stage': 'still'});
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

    test('fallbackStream maps event payload to PerformanceFallbackEvent',
        () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockStreamHandler(
        platform.eventChannel,
        MockStreamHandler.inline(
          onListen: (Object? arguments, MockStreamHandlerEventSink events) {
            events
              ..success({
                'event': 'fallback',
                'action': 'qualityDegraded',
                'reason': 'fps_drop_11',
                'segmentationWidth': 192,
                'targetFps': 15,
              })
              ..success({
                'event': 'fallback',
                'action': 'disabled',
                'reason': 'fps_critical_6',
              })
              ..endOfStream();
          },
        ),
      );

      final fallbackEvents = await platform.fallbackStream.toList();
      expect(fallbackEvents.length, 2);
      expect(fallbackEvents[0].action, FallbackAction.qualityDegraded);
      expect(fallbackEvents[0].segmentationWidth, 192);
      expect(fallbackEvents[1].action, FallbackAction.disabled);
    });

    test('concurrent statusStream and fallbackStream both receive events',
        () async {
      final customPlatform = MethodChannelMiVirtualBackgroundKit();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockStreamHandler(
        customPlatform.eventChannel,
        MockStreamHandler.inline(
          onListen: (Object? arguments, MockStreamHandlerEventSink events) {
            events
              ..success('active')
              ..success({
                'event': 'fallback',
                'action': 'qualityDegraded',
                'reason': 'fps_drop_12',
                'segmentationWidth': 192,
              })
              ..success('idle')
              ..endOfStream();
          },
        ),
      );

      final statusEvents = <ProcessorStatus>[];
      final fallbackEvents = <PerformanceFallbackEvent>[];

      final sub1 = customPlatform.statusStream.listen(statusEvents.add);
      final sub2 = customPlatform.fallbackStream.listen(fallbackEvents.add);

      await Future<void>.delayed(const Duration(milliseconds: 10));
      await sub1.cancel();
      await sub2.cancel();

      expect(statusEvents, [ProcessorStatus.active, ProcessorStatus.idle]);
      expect(fallbackEvents.length, 1);
      expect(fallbackEvents[0].action, FallbackAction.qualityDegraded);
    });
  });
}
