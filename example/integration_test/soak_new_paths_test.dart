import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:integration_test/integration_test.dart';
import 'package:livekit_client/livekit_client.dart';
import 'package:mi_virtual_background_kit/mi_virtual_background_kit.dart';
import 'package:mi_virtual_background_kit_livekit/mi_virtual_background_kit_livekit.dart';

/// T17.6 device soak for the v0.2 paths: preview start/stop and adapter
/// camera switches. Run via `tool/t176_test.sh LABEL DEVICE_ID`.
///
/// The suite is selected with `--dart-define=SOAK_SUITE=preview|adapter|all`.
/// The adapter suite needs the LiveKit dev server; on iOS pass
/// `LK_URL=ws://HOST_IP:7880` and tap Allow on the Local Network dialog.
const _suite = String.fromEnvironment('SOAK_SUITE', defaultValue: 'all');
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
    'sub': 'soak-t176',
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

/// `flutter test` reinstalls the app each run, so the first local connection
/// fails while the Local Network dialog is pending (errno 65). Absorb that
/// attempt before LiveKit connects.
Future<void> _ensureLocalNetwork(String host, int port) async {
  for (var attempt = 1; attempt <= 12; attempt++) {
    try {
      final socket = await Socket.connect(
        host,
        port,
        timeout: const Duration(seconds: 2),
      );
      socket.destroy();
      debugPrint('T176| LOCAL_NETWORK ok attempt=$attempt');
      return;
    } on SocketException catch (e) {
      debugPrint(
        'T176| LOCAL_NETWORK wait attempt=$attempt '
        'errno=${e.osError?.errorCode}',
      );
      await Future<void>.delayed(const Duration(seconds: 2));
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  if (_suite == 'preview' || _suite == 'all') {
    testWidgets('preview start/stop 100 cycles without leak or crash', (
      tester,
    ) async {
      final controller = VirtualBackgroundPreviewController(
        quality: BackgroundQuality.balanced,
      );
      final sw = Stopwatch()..start();

      for (var i = 1; i <= 100; i++) {
        await controller.start();
        expect(controller.isStarted, isTrue);
        await controller.setEffect(const ColorEffect(Color(0xFF00E5CC)));

        // Frames reach the native processor only while a renderer is bound.
        final stream = controller.stream!;
        final renderer = RTCVideoRenderer();
        await renderer.initialize();
        renderer.srcObject = stream;
        await tester.pumpWidget(MaterialApp(home: RTCVideoView(renderer)));
        await tester.pump(const Duration(milliseconds: 120));

        await controller.stop();
        expect(controller.isStarted, isFalse);
        renderer.srcObject = null;
        await renderer.dispose();
        await tester.pumpWidget(const MaterialApp(home: SizedBox.expand()));

        if (i % 10 == 0) {
          debugPrint(
            'T176| PREVIEW cycle=$i elapsed=${sw.elapsedMilliseconds}ms',
          );
        }
      }

      await controller.dispose();
      debugPrint(
        'T176| PREVIEW ALL DONE cycles=100 elapsed=${sw.elapsedMilliseconds}ms',
      );
    }, timeout: const Timeout(Duration(minutes: 6)));
  }

  if (_suite == 'adapter' || _suite == 'all') {
    testWidgets('adapter camera switches 20 times without crash', (
      tester,
    ) async {
      final endpoint = Uri.parse(_url);
      await _ensureLocalNetwork(endpoint.host, endpoint.port);

      final room = Room();
      final adapter = LiveKitVirtualBackground(room: room);
      try {
        await room.connect(_url, _devToken());
        await room.localParticipant!.setCameraEnabled(true);

        LocalVideoTrack? local;
        for (var i = 0; i < 50 && local == null; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
          for (final p in room.localParticipant!.videoTrackPublications) {
            final t = p.track;
            if (t is LocalVideoTrack) local = t;
          }
        }
        if (local == null) fail('local camera track was not published');

        await adapter.attach(local);
        await adapter.setEffect(const ColorEffect(Color(0xFF00E5CC)));
        await tester.pumpWidget(
          MaterialApp(
            home: VideoTrackRenderer(
              local,
              fit: VideoViewFit.cover,
              mirrorMode: VideoViewMirrorMode.mirror,
            ),
          ),
        );

        for (var i = 1; i <= 20; i++) {
          // restartTrack replaces MediaStreamTrack; the adapter must re-attach
          // via TrackStreamUpdatedEvent on every switch (ADR 0002 §5).
          await local.setCameraPosition(
            i.isOdd ? CameraPosition.front : CameraPosition.back,
          );
          await tester.pump(const Duration(milliseconds: 300));
          debugPrint(
            'T176| ADAPTER cycle=$i track=${local.mediaStreamTrack.id}',
          );
        }
        debugPrint('T176| ADAPTER ALL DONE cycles=20');
      } finally {
        await tester.pumpWidget(const MaterialApp(home: SizedBox.expand()));
        await adapter.dispose();
        try {
          await room.disconnect();
        } catch (e) {
          debugPrint('T176| DISCONNECT_ERROR $e');
        }
        room.dispose();
      }
    }, timeout: const Timeout(Duration(minutes: 6)));
  }
}
