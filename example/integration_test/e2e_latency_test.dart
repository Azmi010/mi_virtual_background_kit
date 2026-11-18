import 'dart:async';
import 'dart:ui' show Color;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mi_virtual_background_kit/mi_virtual_background_kit.dart';

/// T17.3 device measurement: frame arrival to composited output.
///
/// ```sh
/// flutter test integration_test/e2e_latency_test.dart -d DEVICE
/// ```
///
/// Emits `T173|` lines with all `metricsStream` fields for post-processing.
/// `processorLatencyMs` is the camera-capture-to-composited-output duration
/// inside the native processor; it excludes sensor readout and display.
const int _seconds = int.fromEnvironment('E2E_SECONDS', defaultValue: 120);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late MiVirtualBackgroundKit kit;
  late MediaStream stream;
  late RTCVideoRenderer renderer;
  StreamSubscription<BackgroundMetrics>? subscription;
  final samples = <BackgroundMetrics>[];
  final sw = Stopwatch()..start();

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
    // A renderer is required or flutter_webrtc drops frames before the
    // native processor (same finding as T14.4).
    renderer.srcObject = stream;
    await kit.attach(
      stream.getVideoTracks().first,
      quality: BackgroundQuality.balanced,
    );
    await kit.setEffect(const ColorEffect(Color(0xFF00796B)));
    subscription = kit.metricsStream.listen((m) {
      samples.add(m);
      debugPrint(
        'T173| t=${sw.elapsedMilliseconds} '
        'fps=${m.outputFps.toStringAsFixed(1)} '
        'seg=${m.segmentationLatencyMs?.toStringAsFixed(1) ?? "-"} '
        'age=${m.maskAgeMs?.toStringAsFixed(1) ?? "-"} '
        'proc=${m.processorLatencyMs?.toStringAsFixed(1) ?? "-"}',
      );
    });
    debugPrint('T173| PHASE start seconds=$_seconds');
  });

  tearDown(() async {
    await subscription?.cancel();
    debugPrint('T173| PHASE end samples=${samples.length}');
    await kit.detach();
    await kit.dispose();
    renderer.srcObject = null;
    await renderer.dispose();
    for (final t in stream.getTracks()) {
      await t.stop();
    }
    await stream.dispose();
  });

  testWidgets('captures camera-to-output latency ($_seconds s)', (
    tester,
  ) async {
    await Future<void>.delayed(Duration(seconds: _seconds));
    expect(samples.length, greaterThan(2), reason: 'no metrics samples');
    expect(
      samples.any((m) => m.processorLatencyMs != null),
      isTrue,
      reason: 'processorLatencyMs never reported',
    );
  }, timeout: Timeout(Duration(seconds: _seconds + 120)));
}
