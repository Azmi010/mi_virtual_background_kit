import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart';
import 'package:mi_virtual_background_kit/mi_virtual_background_kit.dart';

/// LiveKit integration demo (doc/integration.md, T7.4).
///
/// Runs against `livekit/livekit-server --dev` on the host with
/// `adb reverse tcp:7880 tcp:7880` (dev credentials are public by design).
class LiveKitDemoPage extends StatefulWidget {
  const LiveKitDemoPage({super.key});

  @override
  State<LiveKitDemoPage> createState() => _LiveKitDemoPageState();
}

class _LiveKitDemoPageState extends State<LiveKitDemoPage> {
  static const _url = 'ws://127.0.0.1:7880';
  static const _apiKey = 'devkey';
  static const _apiSecret = 'secret';
  static const _roomName = 'demo';

  final _kit = MiVirtualBackgroundKit();
  Room? _room;
  VideoTrack? _localTrack;
  String _status = 'connecting...';
  String _effectName = 'Blur (15)';
  bool _attached = false;

  @override
  void initState() {
    super.initState();
    _connect();
  }

  String _devToken() {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    String encode(Map<String, Object?> json) =>
        base64Url.encode(utf8.encode(jsonEncode(json))).replaceAll('=', '');
    final header = encode(const {'alg': 'HS256', 'typ': 'JWT'});
    final payload = encode({
      'iss': _apiKey,
      'sub': 'demo-user',
      'nbf': now - 60,
      'exp': now + 4 * 3600,
      'video': {
        'room': _roomName,
        'roomJoin': true,
        'canPublish': true,
        'canSubscribe': true,
      },
    });
    final hmac = Hmac(sha256, utf8.encode(_apiSecret));
    final digest = hmac.convert(utf8.encode('$header.$payload'));
    final sig = base64Url.encode(digest.bytes).replaceAll('=', '');
    return '$header.$payload.$sig';
  }

  Future<void> _connect() async {
    try {
      final room = Room();
      _room = room;
      room.addListener(_onRoomChanged);
      await room.connect(_url, _devToken());
      await room.localParticipant!.setCameraEnabled(true);

      LocalVideoTrack? local;
      for (var i = 0; i < 100 && local == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        for (final p in room.localParticipant!.videoTrackPublications) {
          final track = p.track;
          if (track is LocalVideoTrack) {
            local = track;
            break;
          }
        }
      }
      if (local == null) {
        throw StateError('local camera track was not published');
      }

      // The kit attaches to the MediaStreamTrack LiveKit published — the same
      // flutter_webrtc track the rest of this package is built around.
      await _kit.attach(local.mediaStreamTrack);
      await _kit.setEffect(const BlurEffect(radius: 15));
      if (!mounted) return;
      setState(() {
        _localTrack = local;
        _attached = true;
        _status = 'connected + attached';
        _effectName = 'Blur (15)';
      });
    } catch (e) {
      if (mounted) setState(() => _status = 'ERROR $e');
    }
  }

  void _onRoomChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _set(String name, VirtualBackgroundEffect effect) async {
    await _kit.setEffect(effect);
    if (mounted) setState(() => _effectName = name);
  }

  @override
  void dispose() {
    _room?.removeListener(_onRoomChanged);
    _kit.dispose();
    _room?.disconnect();
    _room?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final track = _localTrack;
    return Scaffold(
      appBar: AppBar(title: const Text('LiveKit integration')),
      body: Column(
        children: [
          Expanded(
            child: track == null
                ? Center(child: Text(_status))
                : VideoTrackRenderer(
                    track,
                    fit: VideoViewFit.cover,
                    mirrorMode: VideoViewMirrorMode.mirror,
                  ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              children: [
                Text(
                  '$_status  |  kit: ${_attached ? _effectName : "not attached"}',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  alignment: WrapAlignment.center,
                  children: [
                    ElevatedButton(
                      onPressed: _attached
                          ? () => _set('None', const NoEffect())
                          : null,
                      child: const Text('None'),
                    ),
                    ElevatedButton(
                      onPressed: _attached
                          ? () => _set(
                              'Blur (15)',
                              const BlurEffect(radius: 15),
                            )
                          : null,
                      child: const Text('Blur'),
                    ),
                    ElevatedButton(
                      onPressed: _attached
                          ? () => _set(
                              'Asset (office)',
                              ImageEffect.asset(
                                'assets/office.jpg',
                                fit: BackgroundFit.cover,
                              ),
                            )
                          : null,
                      child: const Text('Asset'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
