import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mi_virtual_background_kit/mi_virtual_background_kit.dart';

/// T6.5 S18: repeated attach/detach without crash or leak signals.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('attach/detach 100 cycles without error', (t) async {
    final kit = MiVirtualBackgroundKit();
    final stream = await navigator.mediaDevices.getUserMedia(<String, Object>{
      'audio': false,
      'video': <String, Object>{
        'facingMode': 'user',
        'width': 640,
        'height': 480,
        'frameRate': 30,
      },
    });
    final track = stream.getVideoTracks().first;
    addTearDown(() async {
      await kit.dispose();
      for (final tr in stream.getTracks()) {
        tr.stop();
      }
      await stream.dispose();
    });

    const cycles = 100;
    for (var i = 1; i <= cycles; i++) {
      await kit.attach(track);
      if (i % 25 == 0) {
        // Every 25th cycle also flip an effect to stress setEffect path.
        await kit.setEffect(const BlurEffect(radius: 10));
        await kit.setEffect(const NoEffect());
      }
      await kit.detach();
      // Detach again must stay idempotent mid-loop.
      if (i % 50 == 0) {
        await kit.detach();
      }
    }

    // Still usable after the loop.
    await kit.attach(track);
    await kit.detach();
  });
}
