import 'dart:ui' show Color;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mi_virtual_background_kit/mi_virtual_background_kit.dart';

/// T17.5 device test: `attach` on unwired track wrappers (FR-19, ADR 0002 §6).
///
/// Both cases used to attach successfully while no frame was ever processed:
///  1. `stream.getMediaTracks()` replaces the registry entry with a fresh,
///     unwired wrapper (Android and iOS).
///  2. A second `getUserMedia` on an open camera yields a shared track on
///     Android, and an independent camera chain on iOS.
///
/// A renderer is bound in every phase: without a frame consumer flutter_webrtc
/// never forwards frames to the native processor (T14.4 finding). `metricsStream`
/// only emits while frames flow through an active effect, so samples are the
/// automatic proof that the effect is really rendering after the redirect.
///
/// Run via `tool/t175_test.sh LABEL DEVICE_ID shared`, or directly:
///   cd example && flutter test integration_test/shared_track_test.dart -d DEVICE_ID
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const effect = ColorEffect(Color(0xFF00E5CC));

  Future<MediaStream> openCamera() =>
      navigator.mediaDevices.getUserMedia(<String, Object>{
        'audio': false,
        'video': <String, Object>{
          'facingMode': 'user',
          'width': 640,
          'height': 480,
          'frameRate': 30,
        },
      });

  Future<RTCVideoRenderer> bindRenderer(MediaStream stream) async {
    final renderer = RTCVideoRenderer();
    await renderer.initialize();
    renderer.srcObject = stream;
    return renderer;
  }

  late MiVirtualBackgroundKit kit;
  late MediaStream primary;
  late MediaStreamTrack primaryTrack;
  late RTCVideoRenderer primaryRenderer;
  final extraStreams = <MediaStream>[];
  final extraRenderers = <RTCVideoRenderer>[];

  setUp(() async {
    kit = MiVirtualBackgroundKit();
    primary = await openCamera();
    primaryTrack = primary.getVideoTracks().first;
    primaryRenderer = await bindRenderer(primary);
  });

  tearDown(() async {
    await kit.dispose();
    primaryRenderer.srcObject = null;
    await primaryRenderer.dispose();
    for (final renderer in extraRenderers) {
      renderer.srcObject = null;
      await renderer.dispose();
    }
    for (final stream in <MediaStream>[primary, ...extraStreams]) {
      for (final track in stream.getTracks()) {
        await track.stop();
      }
      await stream.dispose();
    }
  });

  testWidgets('effect renders after wrapper replacement and shared capture', (
    tester,
  ) async {
    final samples = <BackgroundMetrics>[];
    var phase = 'setup';
    final sub = kit.metricsStream.listen((m) {
      samples.add(m);
      debugPrint(
        'T175| $phase sample fps=${m.outputFps.toStringAsFixed(1)} '
        'seg=${m.segmentationLatencyMs?.toStringAsFixed(1) ?? 'null'} '
        'age=${m.maskAgeMs?.toStringAsFixed(1) ?? 'null'}',
      );
    });
    addTearDown(sub.cancel);

    Future<void> expectFrames(String name) async {
      final before = samples.length;
      phase = name;
      debugPrint('T175| PHASE $name start n=$before');
      await Future<void>.delayed(const Duration(seconds: 6));
      final fresh = samples.sublist(before);
      expect(
        fresh.length,
        greaterThanOrEqualTo(2),
        reason:
            'no metrics samples while $phase is active — frames never '
            'reached the processor (redirect failed?)',
      );
      expect(
        fresh.any((m) => m.outputFps > 5),
        isTrue,
        reason:
            'implausible fps during $phase: '
            '${fresh.map((m) => m.outputFps).join(', ')}',
      );
      debugPrint(
        'T175| PHASE $name done n=${fresh.length} '
        'fps=${fresh.last.outputFps.toStringAsFixed(1)}',
      );
    }

    Future<void> settle() async {
      await kit.detach();
      // Allow in-flight metric events from the previous phase to drain.
      await Future<void>.delayed(const Duration(milliseconds: 1500));
    }

    debugPrint(
      'T175| primary=${primaryTrack.id} renderer=${primaryRenderer.textureId}',
    );

    // Phase 1 — normal attach must produce frames (control for the other two).
    await kit.attach(primaryTrack);
    await kit.setEffect(effect);
    await expectFrames('baseline-primary');
    await settle();

    // Phase 2 — `getMediaTracks()` swaps the registry wrapper. The kit must
    // resolve the wired track again on attach (ADR 0002 §6).
    await primary.getMediaTracks();
    final replaced = primary.getVideoTracks().first;
    debugPrint('T175| replaced=${replaced.id}');
    expect(replaced.id, primaryTrack.id);
    await kit.attach(replaced);
    await kit.setEffect(effect);
    await expectFrames('registry-replacement');
    await settle();

    // Phase 3 — second capture while the first camera stays open and rendered.
    // Android: shared track. iOS: independent chain. Both must render frames.
    final second = await openCamera();
    extraStreams.add(second);
    final secondRenderer = await bindRenderer(second);
    extraRenderers.add(secondRenderer);
    final secondTrack = second.getVideoTracks().first;
    debugPrint(
      'T175| second=${secondTrack.id} renderer=${secondRenderer.textureId}',
    );
    await kit.attach(secondTrack);
    await kit.setEffect(effect);
    await expectFrames('second-capture');
    await settle();

    debugPrint('T175| ALL DONE samples=${samples.length}');
  }, timeout: const Timeout(Duration(minutes: 3)));
}
