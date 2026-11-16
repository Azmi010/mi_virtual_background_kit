import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mi_virtual_background_kit/mi_virtual_background_kit.dart';

/// T14.6 device test: `metricsStream` (FR-23).
///
/// Run on a device (camera required):
///
/// ```sh
/// cd example
/// flutter test integration_test/metrics_test.dart -d DEVICE_ID
/// ```
///
/// Or via `tool/metrics_test.sh LABEL DEVICE_ID`, which stores the
/// transcript (Dart markers `T146|`) under doc/metrics-raw/ and — on
/// Android — raw logcat with the native `T133|` fps lines needed for the
/// overhead comparison.
///
/// What it proves on real hardware:
/// 1. With a listener: ~1 sample per second, sane values
///    (outputFps > 5, segmentation latency and mask age present after warmup).
/// 2. Samples are throttled (arrival gap >= 0.8 s), not per-mask spam.
/// 3. After the listener cancels: zero further samples.
/// 4. Phases `off -> on -> off` are marked with `T146| PHASE` lines so the
///    native `T133|` fps in each window can be compared for reporting
///    overhead (analysis step after the run).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late MiVirtualBackgroundKit kit;
  late MediaStream stream;
  late MediaStreamTrack track;
  late RTCVideoRenderer renderer;

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
    // A local track with no consumer never reaches the frame processor
    // (same finding as T14.4): bind a renderer exactly like a real app.
    renderer = RTCVideoRenderer();
    await renderer.initialize();
    renderer.srcObject = stream;
  });

  tearDown(() async {
    await kit.dispose();
    renderer.srcObject = null;
    await renderer.dispose();
    for (final t in stream.getTracks()) {
      t.stop();
    }
    await stream.dispose();
  });

  testWidgets(
    'metricsStream throttles to ~1 Hz and stops when cancelled (FR-23)',
    (tester) async {
      final transcript = <String>[];
      final sw = Stopwatch()..start();

      void log(String line) {
        debugPrint(line);
        transcript.add(line);
      }

      await kit.attach(track);
      await kit.setEffect(const BlurEffect(radius: 12));

      // Phase OFF (baseline, no listener): native gate must stay silent.
      log('T146| PHASE off start +${sw.elapsedMilliseconds}ms');
      await Future<void>.delayed(const Duration(seconds: 8));
      log('T146| PHASE off end +${sw.elapsedMilliseconds}ms');

      // Phase ON: subscribe and collect.
      final samples = <BackgroundMetrics>[];
      final arrivalMs = <int>[];
      final sub = kit.metricsStream.listen((m) {
        samples.add(m);
        arrivalMs.add(sw.elapsedMilliseconds);
        log(
          'T146| sample #${samples.length} +${sw.elapsedMilliseconds}ms '
          'fps=${m.outputFps.toStringAsFixed(1)} '
          'seg=${m.segmentationLatencyMs?.toStringAsFixed(1) ?? "null"} '
          'age=${m.maskAgeMs?.toStringAsFixed(1) ?? "null"}',
        );
      });
      addTearDown(sub.cancel);

      log('T146| PHASE on start +${sw.elapsedMilliseconds}ms');
      await Future<void>.delayed(const Duration(seconds: 12));
      log('T146| PHASE on end +${sw.elapsedMilliseconds}ms');

      // Cancel: native onCancel drops the sink; no further samples.
      await sub.cancel();
      final countAtCancel = samples.length;
      log('T146| listener cancelled, count=$countAtCancel');

      log('T146| PHASE off2 start +${sw.elapsedMilliseconds}ms');
      await Future<void>.delayed(const Duration(seconds: 6));
      log('T146| PHASE off2 end +${sw.elapsedMilliseconds}ms');
      expect(
        samples.length,
        countAtCancel,
        reason: 'no samples may arrive after the listener cancels',
      );

      // --- Assertions on the collected window ---
      expect(
        samples.length,
        greaterThanOrEqualTo(7),
        reason:
            'expected ~1 sample/s over 12 s, got ${samples.length}\n'
            'transcript:\n${transcript.join('\n')}',
      );

      // Throttle: native emits at most once per second of frame time.
      for (var i = 1; i < arrivalMs.length; i++) {
        final gap = arrivalMs[i] - arrivalMs[i - 1];
        expect(
          gap,
          greaterThanOrEqualTo(800),
          reason:
              'sample #$i arrived ${gap}ms after #$i - 1 '
              '(throttle broken, per-mask spam?)',
        );
      }

      for (var i = 0; i < samples.length; i++) {
        final fps = samples[i].outputFps;
        expect(
          fps,
          greaterThan(5.0),
          reason: 'sample #$i fps=$fps implausible',
        );
        expect(fps, lessThanOrEqualTo(120.0), reason: 'sample #$i fps=$fps');
        final seg = samples[i].segmentationLatencyMs;
        if (seg != null) {
          expect(seg, greaterThanOrEqualTo(0));
          expect(seg, lessThan(2000), reason: 'sample #$i seg=$seg ms');
        }
        final age = samples[i].maskAgeMs;
        if (age != null) {
          expect(age, greaterThanOrEqualTo(0));
          expect(age, lessThan(5000), reason: 'sample #$i age=$age ms');
        }
      }

      // After warmup both measured fields must be present at least once.
      expect(
        samples.any((m) => m.segmentationLatencyMs != null),
        isTrue,
        reason: 'segmentationLatencyMs never reported',
      );
      expect(
        samples.any((m) => m.maskAgeMs != null),
        isTrue,
        reason: 'maskAgeMs never reported',
      );

      await kit.detach();
      log(
        'T146| ALL DONE samples=${samples.length} '
        'minGap=${_minGap(arrivalMs)}ms',
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

int? _minGap(List<int> arrivalMs) {
  if (arrivalMs.length < 2) return null;
  var min = arrivalMs[1] - arrivalMs[0];
  for (var i = 2; i < arrivalMs.length; i++) {
    final gap = arrivalMs[i] - arrivalMs[i - 1];
    if (gap < min) min = gap;
  }
  return min;
}
