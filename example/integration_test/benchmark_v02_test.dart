import 'dart:async';
import 'dart:ui' show Color;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mi_virtual_background_kit/mi_virtual_background_kit.dart';

/// T17.1 device benchmark session.
///
/// Run through `tool/bench_v02.sh`, or directly:
///
/// ```sh
/// cd example
/// flutter test integration_test/benchmark_v02_test.dart -d DEVICE \
///   --dart-define=BENCH_EFFECT=blur --dart-define=BENCH_SECONDS=600
/// ```
///
/// Emits `T171|` markers for phase bounds, ~1 Hz `metricsStream` samples and
/// fallback events. The `none` effect emits no metrics samples by design:
/// bypass returns before the metrics gate in both native processors.
const String _effect = String.fromEnvironment(
  'BENCH_EFFECT',
  defaultValue: 'blur',
);
const int _seconds = int.fromEnvironment('BENCH_SECONDS', defaultValue: 600);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late MiVirtualBackgroundKit kit;
  late MediaStream stream;
  late RTCVideoRenderer renderer;
  StreamSubscription<BackgroundMetrics>? metricsSub;
  StreamSubscription<PerformanceFallbackEvent>? fallbackSub;
  final samples = <BackgroundMetrics>[];
  final sw = Stopwatch()..start();

  void log(String line) => debugPrint('T171| $line');

  setUp(() async {
    kit = MiVirtualBackgroundKit();
    stream = await navigator.mediaDevices.getUserMedia(const <String, Object>{
      'audio': false,
      'video': <String, Object>{
        'facingMode': 'user',
        'width': 640,
        'height': 480,
        'frameRate': 30,
      },
    });
    renderer = RTCVideoRenderer();
    await renderer.initialize();
    // A frame consumer is required: without a renderer flutter_webrtc drops
    // every frame before the native processor (finding from T14.4).
    renderer.srcObject = stream;
    await kit.attach(
      stream.getVideoTracks().first,
      quality: BackgroundQuality.balanced,
    );

    switch (_effect) {
      case 'none':
        await kit.setEffect(const NoEffect());
      case 'blur':
        await kit.setEffect(const BlurEffect(radius: 20));
      case 'image':
        await kit.setEffect(
          ImageEffect.asset('assets/office.jpg', fit: BackgroundFit.cover),
        );
      case 'color':
        await kit.setEffect(const ColorEffect(Color(0xFF00796B)));
      default:
        throw ArgumentError('unknown BENCH_EFFECT: $_effect');
    }

    metricsSub = kit.metricsStream.listen((m) {
      samples.add(m);
      log(
        'sample t=${sw.elapsedMilliseconds} '
        'fps=${m.outputFps.toStringAsFixed(1)} '
        'seg=${m.segmentationLatencyMs?.toStringAsFixed(1) ?? "-"} '
        'age=${m.maskAgeMs?.toStringAsFixed(1) ?? "-"}',
      );
    });
    fallbackSub = kit.fallbackStream.listen((e) {
      log(
        'fallback t=${sw.elapsedMilliseconds} '
        '${e.action.name} reason=${e.reason}',
      );
    });
    log(
      'PHASE start effect=$_effect quality=balanced '
      'camera=640x480@30 seconds=$_seconds',
    );
  });

  tearDown(() async {
    await metricsSub?.cancel();
    await fallbackSub?.cancel();
    log('PHASE end samples=${samples.length}');
    await kit.detach();
    await kit.dispose();
    renderer.srcObject = null;
    await renderer.dispose();
    for (final t in stream.getTracks()) {
      await t.stop();
    }
    await stream.dispose();
  });

  testWidgets('benchmark session ($_effect)', (tester) async {
    await Future<void>.delayed(Duration(seconds: _seconds));
    if (_effect != 'none') {
      expect(samples.length, greaterThan(2), reason: 'no metrics samples');
    }
  }, timeout: Timeout(Duration(seconds: _seconds + 120)));
}
