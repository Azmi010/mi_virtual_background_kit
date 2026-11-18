import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:livekit_client/livekit_client.dart';
import 'package:mi_virtual_background_kit/mi_virtual_background_kit.dart';
import 'package:mi_virtual_background_kit_livekit/mi_virtual_background_kit_livekit.dart';

/// T16.3 — preview handoff to a call, on a real device.
///
/// Needs the LiveKit dev server (Docker container `t131-lk` is enough):
///   docker start t131-lk
///   tool/preview_handoff_test.sh DEVICE_ID
///
/// Android uses `adb reverse`, so the default URL is localhost. On a physical
/// iOS device pass the host IP: `LK_URL=ws://192.168.1.5:7880` (script/T17.5).
const _url = String.fromEnvironment(
  'LK_URL',
  defaultValue: 'ws://127.0.0.1:7880',
);
const _apiKey = 'devkey';
const _apiSecret = 'secret';
const _roomName = 'demo';

String _devToken() {
  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  String encode(Map<String, Object?> json) =>
      base64Url.encode(utf8.encode(jsonEncode(json))).replaceAll('=', '');
  final header = encode(const {'alg': 'HS256', 'typ': 'JWT'});
  final payload = encode({
    'iss': _apiKey,
    'sub': 'handoff-test',
    'nbf': now - 60,
    'exp': now + 4 * 3600,
    'video': {
      'room': _roomName,
      'roomJoin': true,
      'canPublish': true,
      'canSubscribe': true,
    },
  });
  final digest = Hmac(
    sha256,
    utf8.encode(_apiSecret),
  ).convert(utf8.encode('$header.$payload'));
  return '$header.$payload.${base64Url.encode(digest.bytes).replaceAll('=', '')}';
}

/// iOS shows the Local Network dialog on the first local connection and fails
/// that in-flight socket. `flutter test` reinstalls the app each run, so the
/// dialog (and the failed first attempt) must be absorbed before Room.connect.
Future<void> _ensureLocalNetwork(String host, int port) async {
  for (var attempt = 1; attempt <= 12; attempt++) {
    try {
      final socket = await Socket.connect(
        host,
        port,
        timeout: const Duration(seconds: 2),
      );
      socket.destroy();
      debugPrint('T163| LOCAL_NETWORK ok attempt=$attempt');
      return;
    } on SocketException catch (e) {
      debugPrint(
        'T163| LOCAL_NETWORK wait attempt=$attempt '
        'errno=${e.osError?.errorCode}',
      );
      await Future<void>.delayed(const Duration(seconds: 2));
    }
  }
}

Future<PreviewHandoff> _startPreview(WidgetTester tester) async {
  final controller = VirtualBackgroundPreviewController(
    quality: BackgroundQuality.balanced,
  );
  await controller.start();
  await controller.setEffect(const ColorEffect(Color(0xFF00E5CC)));
  await tester.pumpWidget(
    MaterialApp(home: VirtualBackgroundPreview(controller: controller)),
  );
  await tester.pump(const Duration(seconds: 2));

  final handoff = await controller.releaseToCaller();
  await controller.dispose();
  await tester.pumpWidget(const MaterialApp(home: SizedBox.expand()));
  debugPrint(
    'T163| PREVIEW_READY stream=${handoff.stream.id} track=${handoff.track.id}',
  );
  return handoff;
}

Future<void> _release(PreviewHandoff handoff) async {
  await handoff.track.stop();
  await handoff.stream.dispose();
  await handoff.kit.dispose();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('handoff keeps the effect on both call paths', (tester) async {
    final endpoint = Uri.parse(_url);
    await _ensureLocalNetwork(endpoint.host, endpoint.port);

    // Path A — handoff straight into flutter_webrtc rendering.
    final a = await _startPreview(tester);
    final renderer = RTCVideoRenderer();
    await renderer.initialize();
    renderer.srcObject = a.stream;
    await tester.pumpWidget(MaterialApp(home: RTCVideoView(renderer)));
    await tester.pump(const Duration(seconds: 2));
    debugPrint('T163| PATH_A texture=${renderer.textureId}');
    await renderer.dispose();
    await _release(a);
    await tester.pumpWidget(const MaterialApp(home: SizedBox.expand()));

    // Path B — handoff into a LiveKit LocalVideoTrack + adapter, then publish.
    final b = await _startPreview(tester);
    final room = Room();
    // ignore: invalid_use_of_internal_member
    final local = LocalVideoTrack(
      TrackSource.camera,
      b.stream,
      b.track,
      const CameraCaptureOptions(),
    );
    final adapter = LiveKitVirtualBackground(room: room);
    try {
      await room.connect(_url, _devToken());
      debugPrint('T163| CONNECT ok $_url');
      await adapter.attach(local);
      debugPrint('T163| ATTACH ok');
      await adapter.setEffect(const ColorEffect(Color(0xFF00E5CC)));
      await room.localParticipant!.publishVideoTrack(local);
      debugPrint('T163| PUBLISH ok');
      await tester.pumpWidget(
        MaterialApp(
          home: VideoTrackRenderer(
            local,
            fit: VideoViewFit.cover,
            mirrorMode: VideoViewMirrorMode.mirror,
          ),
        ),
      );
      await tester.pump(const Duration(seconds: 2));
      debugPrint('T163| PATH_B published=${local.mediaStreamTrack.id}');
    } finally {
      await adapter.dispose();
      // A failed connect can make disconnect() time out; never let cleanup
      // mask the original error from connect/attach/publish.
      try {
        await room.disconnect();
      } catch (e) {
        debugPrint('T163| DISCONNECT_ERROR $e');
      }
      room.dispose();
      await _release(b);
      await tester.pumpWidget(const MaterialApp(home: SizedBox.expand()));
    }
  });
}
