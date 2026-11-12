import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:mi_virtual_background_kit/mi_virtual_background_kit.dart';
import 'package:mi_virtual_background_kit/src/platform/mi_virtual_background_kit_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class MockPlatform
    with MockPlatformInterfaceMixin
    implements MiVirtualBackgroundKitPlatform {
  final List<String> calls = <String>[];
  final List<Map<String, Object?>> effects = <Map<String, Object?>>[];
  final statusController = StreamController<ProcessorStatus>.broadcast();
  final fallbackController =
      StreamController<PerformanceFallbackEvent>.broadcast();

  bool supported = true;
  Object? attachError;
  bool throwOnAttachNoop = false;
  Map<String, Object?>? lastQuality;

  @override
  Future<bool> isSupported() async {
    calls.add('isSupported');
    return supported;
  }

  @override
  Future<void> attach(String trackId, {Map<String, Object?>? quality}) async {
    calls.add('attach:$trackId');
    lastQuality = quality;
    final error = attachError;
    if (error != null) throw error;
  }

  @override
  Future<void> setQuality(Map<String, Object?> quality) async {
    calls.add('setQuality');
    lastQuality = quality;
  }

  @override
  Future<void> setEffect(Map<String, Object?> effect) async {
    calls.add('setEffect');
    effects.add(effect);
  }

  @override
  Future<void> detach() async {
    calls.add('detach');
  }

  @override
  Future<void> dispose() async {
    calls.add('dispose');
  }

  @override
  Stream<ProcessorStatus> get statusStream => statusController.stream;

  @override
  Stream<PerformanceFallbackEvent> get fallbackStream =>
      fallbackController.stream;
}

class FakeTrack extends Fake implements MediaStreamTrack {
  FakeTrack(this.id);

  @override
  final String? id;
}

class NoIdTrack extends Fake implements MediaStreamTrack {
  @override
  final String? id = null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MockPlatform mock;
  late MiVirtualBackgroundKit kit;

  setUp(() {
    mock = MockPlatform();
    MiVirtualBackgroundKitPlatform.instance = mock;
    kit = MiVirtualBackgroundKit();
  });

  tearDown(() {
    mock.statusController.close();
    mock.fallbackController.close();
  });

  group('isSupported', () {
    test('delegates to platform', () async {
      expect(await kit.isSupported(), isTrue);
      expect(mock.calls, contains('isSupported'));
    });

    test('returns false from platform', () async {
      mock.supported = false;
      expect(await kit.isSupported(), isFalse);
    });
  });

  group('attach', () {
    test('passes track id to platform', () async {
      await kit.attach(FakeTrack('track-1'));
      expect(mock.calls, contains('attach:track-1'));
    });

    test('throws InvalidTrackException when track id is null', () async {
      await expectLater(
        kit.attach(NoIdTrack()),
        throwsA(isA<InvalidTrackException>()),
      );
      expect(mock.calls, isEmpty);
    });

    test('throws InvalidTrackException when track id is empty', () async {
      await expectLater(
        kit.attach(FakeTrack('')),
        throwsA(isA<InvalidTrackException>()),
      );
    });

    test('propagates platform errors', () async {
      mock.attachError = const UnsupportedPlatformException('no GPU');
      await expectLater(
        kit.attach(FakeTrack('t')),
        throwsA(isA<UnsupportedPlatformException>()),
      );
    });

    test('passes quality map to platform', () async {
      const q = BackgroundQuality(
        segmentationWidth: 320,
        edgeSmoothing: 0.8,
        targetFps: 25,
      );
      await kit.attach(FakeTrack('track-1'), quality: q);
      expect(mock.lastQuality, equals(q.toMap()));
    });

    test('re-applies last effect after re-attach (camera switch)', () async {
      await kit.attach(FakeTrack('track-1'));
      await kit.setEffect(const BlurEffect(radius: 12));
      mock.calls.clear();
      mock.effects.clear();

      await kit.attach(FakeTrack('track-2'));
      expect(mock.calls, contains('attach:track-2'));
      expect(mock.effects, hasLength(1));
      expect(mock.effects.single['type'], 'blur');
      expect(mock.effects.single['radius'], 12.0);
    });

    test('does not re-apply effect when none was set', () async {
      await kit.attach(FakeTrack('track-1'));
      mock.effects.clear();
      await kit.attach(FakeTrack('track-2'));
      expect(mock.effects, isEmpty);
    });

    test('rejects invalid quality on attach', () async {
      await expectLater(
        kit.attach(
          FakeTrack('track-1'),
          quality: const BackgroundQuality(segmentationWidth: 0),
        ),
        throwsA(isA<ArgumentError>()),
      );
      await expectLater(
        kit.attach(
          FakeTrack('track-1'),
          quality: const BackgroundQuality(edgeSmoothing: -0.1),
        ),
        throwsA(isA<ArgumentError>()),
      );
      await expectLater(
        kit.attach(
          FakeTrack('track-1'),
          quality: const BackgroundQuality(edgeSmoothing: 1.5),
        ),
        throwsA(isA<ArgumentError>()),
      );
      await expectLater(
        kit.attach(
          FakeTrack('track-1'),
          quality: const BackgroundQuality(targetFps: 0),
        ),
        throwsA(isA<ArgumentError>()),
      );
      await expectLater(
        kit.attach(
          FakeTrack('track-1'),
          quality: const BackgroundQuality(maskTemporalSmoothing: -0.1),
        ),
        throwsA(isA<ArgumentError>()),
      );
      await expectLater(
        kit.attach(
          FakeTrack('track-1'),
          quality: const BackgroundQuality(maskTemporalSmoothing: 1.5),
        ),
        throwsA(isA<ArgumentError>()),
      );
      expect(mock.calls, isEmpty);
    });
  });

  group('setQuality', () {
    test('delegates to platform after validation', () async {
      final q = BackgroundQuality.preset(BackgroundQualityPreset.high);
      await kit.setQuality(q);
      expect(mock.calls, contains('setQuality'));
      expect(mock.lastQuality, equals(q.toMap()));
    });

    test('rejects invalid quality without touching platform', () async {
      await expectLater(
        kit.setQuality(const BackgroundQuality(segmentationWidth: -1)),
        throwsA(isA<ArgumentError>()),
      );
      await expectLater(
        kit.setQuality(const BackgroundQuality(maskTemporalSmoothing: 1.5)),
        throwsA(isA<ArgumentError>()),
      );
      expect(mock.calls, isEmpty);
    });

    test('throws StateError when kit is disposed', () async {
      await kit.dispose();
      await expectLater(
        kit.setQuality(const BackgroundQuality()),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('setEffect', () {
    test('serializes effect and sends to platform', () async {
      await kit.setEffect(const BlurEffect(radius: 8));
      expect(mock.effects.single, <String, Object?>{
        'type': 'blur',
        'radius': 8.0,
      });
    });

    test('sends NoEffect as bypass', () async {
      await kit.setEffect(const NoEffect());
      expect(mock.effects.single['type'], 'none');
    });

    test('rejects blur radius <= 0 without touching platform', () async {
      await expectLater(
        kit.setEffect(const BlurEffect(radius: 0)),
        throwsA(isA<ArgumentError>()),
      );
      await expectLater(
        kit.setEffect(const BlurEffect(radius: -5)),
        throwsA(isA<ArgumentError>()),
      );
      expect(mock.effects, isEmpty);
    });

    test('rejects blur radius > 100 or non-finite', () async {
      await expectLater(
        kit.setEffect(const BlurEffect(radius: 101)),
        throwsA(isA<ArgumentError>()),
      );
      await expectLater(
        kit.setEffect(const BlurEffect(radius: double.infinity)),
        throwsA(isA<ArgumentError>()),
      );
      expect(mock.effects, isEmpty);
    });

    test('rejects empty asset path without touching platform', () async {
      await expectLater(
        kit.setEffect(const ImageEffect.asset('')),
        throwsA(isA<InvalidImageException>()),
      );
      await expectLater(
        kit.setEffect(const ImageEffect.asset('   ')),
        throwsA(isA<InvalidImageException>()),
      );
      expect(mock.effects, isEmpty);
    });

    test('rejects empty file path without touching platform', () async {
      await expectLater(
        kit.setEffect(const ImageEffect.file('')),
        throwsA(isA<InvalidImageException>()),
      );
      expect(mock.effects, isEmpty);
    });

    test('rejects empty bytes without touching platform', () async {
      await expectLater(
        kit.setEffect(ImageEffect.bytes(Uint8List(0))),
        throwsA(isA<InvalidImageException>()),
      );
      expect(mock.effects, isEmpty);
    });

    test('accepts valid boundary blur radius', () async {
      await kit.setEffect(const BlurEffect(radius: 100));
      expect(mock.effects.single['radius'], 100.0);
    });
  });

  group('detach', () {
    test('calls platform when attached', () async {
      await kit.attach(FakeTrack('t'));
      await kit.detach();
      expect(mock.calls, contains('detach'));
    });

    test('is idempotent when not attached', () async {
      await kit.detach();
      await kit.detach();
      expect(mock.calls, isNot(contains('detach')));
    });

    test('second detach after attach is no-op', () async {
      await kit.attach(FakeTrack('t'));
      await kit.detach();
      await kit.detach();
      expect(mock.calls.where((c) => c == 'detach'), hasLength(1));
    });
  });

  group('dispose', () {
    test('detaches first when attached, then disposes', () async {
      await kit.attach(FakeTrack('t'));
      await kit.dispose();
      expect(mock.calls, containsAllInOrder(<String>['detach', 'dispose']));
    });

    test('skips detach when not attached', () async {
      await kit.dispose();
      expect(mock.calls, isNot(contains('detach')));
      expect(mock.calls, contains('dispose'));
    });

    test('is idempotent', () async {
      await kit.dispose();
      await kit.dispose();
      expect(mock.calls.where((c) => c == 'dispose'), hasLength(1));
    });

    test('kit is unusable after dispose', () async {
      await kit.dispose();
      await expectLater(
        kit.attach(FakeTrack('t')),
        throwsA(isA<StateError>()),
      );
      await expectLater(
        kit.setEffect(const NoEffect()),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('statusStream', () {
    test('delegates to platform stream', () async {
      final events = <ProcessorStatus>[];
      final sub = kit.statusStream.listen(events.add);
      mock.statusController
        ..add(ProcessorStatus.initializing)
        ..add(ProcessorStatus.active);
      await Future<void>.delayed(Duration.zero);
      expect(events, [
        ProcessorStatus.initializing,
        ProcessorStatus.active,
      ]);
      await sub.cancel();
    });
  });

  group('fallbackStream', () {
    test('delegates to platform stream', () async {
      final events = <PerformanceFallbackEvent>[];
      final sub = kit.fallbackStream.listen(events.add);
      const sample = PerformanceFallbackEvent(
        action: FallbackAction.qualityDegraded,
        reason: 'fps_low',
        segmentationWidth: 192,
      );
      mock.fallbackController.add(sample);
      await Future<void>.delayed(Duration.zero);
      expect(events, [sample]);
      await sub.cancel();
    });
  });
}
