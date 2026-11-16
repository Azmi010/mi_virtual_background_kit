import 'dart:convert';
import 'dart:ui' show Color;

import 'package:crypto/crypto.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:livekit_client/livekit_client.dart';
import 'package:mi_virtual_background_kit/mi_virtual_background_kit.dart';
import 'package:mi_virtual_background_kit_livekit/mi_virtual_background_kit_livekit.dart';

/// T15.4 — LiveKit adapter lifecycle on a real device.
///
/// Start the dev server before running. With the existing Docker container:
///   docker start t131-lk
/// Or without Docker:
///   livekit-server --dev --bind 0.0.0.0
/// Then forward the port and run:
///   adb reverse tcp:7880 tcp:7880
///   flutter test integration_test/livekit_adapter_test.dart -d DEVICE_ID
const _url = 'ws://127.0.0.1:7880';
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
    'sub': 'adapter-test',
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

Future<LocalVideoTrack> _waitTrack(Room room) async {
  for (var i = 0; i < 100; i++) {
    for (final p in room.localParticipant!.videoTrackPublications) {
      final t = p.track;
      if (t is LocalVideoTrack) return t;
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  throw StateError('local camera track was not published');
}

void _show(RTCVideoRenderer renderer, LocalVideoTrack track) {
  renderer.srcObject = track.mediaStream;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('adapter keeps the effect across LiveKit track lifecycle', (
    t,
  ) async {
    final room = Room();
    final adapter = LiveKitVirtualBackground(room: room);
    final renderer = RTCVideoRenderer();
    late LocalVideoTrack track;

    try {
      await renderer.initialize();
      await room.connect(_url, _devToken());
      await room.localParticipant!.setCameraEnabled(true);
      track = await _waitTrack(room);
      _show(renderer, track);

      await adapter.attach(track);
      await adapter.setEffect(const ColorEffect(Color(0xFF00E5CC)));
      await Future<void>.delayed(const Duration(seconds: 2));

      // S2 — camera switch. LiveKit replaces MediaStreamTrack; the adapter must
      // re-attach on TrackStreamUpdatedEvent.
      final originalId = track.mediaStreamTrack.id;
      final options = track.currentOptions;
      if (options is CameraCaptureOptions) {
        await track.restartTrack(
          options.copyWith(cameraPosition: options.cameraPosition.switched()),
        );
      }
      expect(track.mediaStreamTrack.id, isNot(originalId));
      _show(renderer, track);
      await Future<void>.delayed(const Duration(seconds: 2));

      // S3 — mute / unmute.
      await room.localParticipant!.setCameraEnabled(false);
      await Future<void>.delayed(const Duration(seconds: 1));
      await room.localParticipant!.setCameraEnabled(true);
      _show(renderer, track);
      await Future<void>.delayed(const Duration(seconds: 2));

      // S4 — unpublish / republish. Room event must detach then attach the new
      // camera track.
      final publication = room.localParticipant!.getTrackPublicationBySource(
        TrackSource.camera,
      );
      if (publication != null) {
        await room.localParticipant!.removePublishedTrack(publication.sid);
      }
      await Future<void>.delayed(const Duration(seconds: 1));
      await room.localParticipant!.setCameraEnabled(true);
      track = await _waitTrack(room);
      _show(renderer, track);
      await Future<void>.delayed(const Duration(seconds: 2));

      // S5 — explicit restart.
      await track.restartTrack();
      _show(renderer, track);
      await Future<void>.delayed(const Duration(seconds: 2));

      await adapter.detach();
      await adapter.detach();
    } finally {
      await adapter.dispose();
      await renderer.dispose();
      await room.disconnect();
      room.dispose();
    }
  });
}
