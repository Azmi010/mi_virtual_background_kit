import 'dart:typed_data';
import 'dart:ui' show Color;

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mi_virtual_background_kit/mi_virtual_background_kit.dart';

/// Minimal valid 1×1 RGB PNG for ImageEffect.bytes.
final Uint8List _tinyPng = Uint8List.fromList(<int>[
  0x89,
  0x50,
  0x4E,
  0x47,
  0x0D,
  0x0A,
  0x1A,
  0x0A,
  0x00,
  0x00,
  0x00,
  0x0D,
  0x49,
  0x48,
  0x44,
  0x52,
  0x00,
  0x00,
  0x00,
  0x01,
  0x00,
  0x00,
  0x00,
  0x01,
  0x08,
  0x02,
  0x00,
  0x00,
  0x00,
  0x90,
  0x77,
  0x53,
  0xDE,
  0x00,
  0x00,
  0x00,
  0x0C,
  0x49,
  0x44,
  0x41,
  0x54,
  0x78,
  0x9C,
  0x63,
  0xF8,
  0xCF,
  0xC0,
  0x00,
  0x00,
  0x03,
  0x01,
  0x01,
  0x00,
  0xC9,
  0xFE,
  0x92,
  0xEF,
  0x00,
  0x00,
  0x00,
  0x00,
  0x49,
  0x45,
  0x4E,
  0x44,
  0xAE,
  0x42,
  0x60,
  0x82,
]);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late MiVirtualBackgroundKit kit;
  late MediaStream stream;
  late MediaStreamTrack track;

  setUp(() async {
    kit = MiVirtualBackgroundKit();
    stream = await navigator.mediaDevices.getUserMedia(<String, Object>{
      'audio': false,
      'video': <String, Object>{
        'facingMode': 'user',
        'width': 640,
        'height': 480,
        'frameRate': 30,
      },
    });
    track = stream.getVideoTracks().first;
  });

  tearDown(() async {
    await kit.dispose();
    for (final t in stream.getTracks()) {
      t.stop();
    }
    await stream.dispose();
  });

  testWidgets('isSupported returns true on capable device', (t) async {
    expect(await kit.isSupported(), isTrue);
  });

  testWidgets('attach reaches active, effects switch, detach idempotent', (
    t,
  ) async {
    final statuses = <ProcessorStatus>[];
    final sub = kit.statusStream.listen(statuses.add);
    addTearDown(sub.cancel);

    await kit.attach(track);
    expect(
      statuses,
      anyOf(
        contains(ProcessorStatus.initializing),
        contains(ProcessorStatus.active),
      ),
      reason: 'status stream should emit initializing or active after attach',
    );

    // Wait briefly for native pipeline to settle.
    await Future<void>.delayed(const Duration(seconds: 1));
    expect(statuses, contains(ProcessorStatus.active));

    // FR-05: runtime effect switches without re-attach.
    await kit.setEffect(const BlurEffect(radius: 12));
    await kit.setEffect(const ColorEffect(Color(0xFF00796B)));
    await kit.setEffect(ImageEffect.bytes(_tinyPng));
    await kit.setEffect(
      ImageEffect.bytes(_tinyPng, fit: BackgroundFit.contain),
    );
    await kit.setEffect(const NoEffect());

    // FR-06: detach idempotent.
    await kit.detach();
    await kit.detach();

    // Re-attach still works (camera switch path).
    await kit.attach(track);
    await Future<void>.delayed(const Duration(seconds: 1));
    expect(statuses, contains(ProcessorStatus.active));

    await kit.detach();
    expect(statuses, isNotEmpty);
  });

  testWidgets('setEffect validates input before native', (t) async {
    await kit.attach(track);

    expect(
      () => kit.setEffect(const BlurEffect(radius: 0)),
      throwsA(isA<ArgumentError>()),
    );
    expect(
      () => kit.setEffect(ImageEffect.bytes(Uint8List(0))),
      throwsA(isA<InvalidImageException>()),
    );

    await kit.detach();
  });

  testWidgets('dispose is idempotent and kit unusable after', (t) async {
    await kit.attach(track);
    await kit.dispose();
    await kit.dispose();

    expect(() => kit.attach(track), throwsA(isA<StateError>()));
  });
}
