import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:mi_virtual_background_kit/mi_virtual_background_kit.dart';

/// Pre-join lobby: pick an effect in a live preview, then hand the camera off.
class LobbyPage extends StatefulWidget {
  const LobbyPage({super.key});

  @override
  State<LobbyPage> createState() => _LobbyPageState();
}

class _LobbyPageState extends State<LobbyPage> {
  late final VirtualBackgroundPreviewController _controller;
  String _effectName = 'None';
  bool _joining = false;

  @override
  void initState() {
    super.initState();
    _controller = VirtualBackgroundPreviewController(
      quality: BackgroundQuality.balanced,
    );
  }

  @override
  void dispose() {
    // After handoff this only marks the controller disposed; the caller owns
    // the camera and kit from that point.
    _controller.dispose();
    super.dispose();
  }

  Future<void> _set(String name, VirtualBackgroundEffect effect) async {
    await _controller.setEffect(effect);
    if (mounted) setState(() => _effectName = name);
  }

  Future<void> _join() async {
    if (_joining) return;
    setState(() => _joining = true);
    try {
      final handoff = await _controller.releaseToCaller();
      debugPrint('T165| JOIN effect=$_effectName track=${handoff.track.id}');
      if (!mounted) return;
      // pushReplacement would complete the future of the push that opened
      // LobbyPage; main would restart its camera and steal the shared source
      // while the call is still on screen.
      await Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => _CallPage(handoff: handoff)),
      );
      if (mounted) Navigator.of(context).pop();
    } catch (error) {
      if (mounted) {
        setState(() {
          _joining = false;
          _effectName = 'ERROR $error';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Lobby — pick a background')),
      body: Column(
        children: [
          Expanded(
            child: VirtualBackgroundPreview(
              controller: _controller,
              mirror: true,
              fit: BackgroundFit.cover,
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              children: [
                Text('Effect: $_effectName'),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  alignment: WrapAlignment.center,
                  children: [
                    ElevatedButton(
                      onPressed: () => _set('None', const NoEffect()),
                      child: const Text('None'),
                    ),
                    ElevatedButton(
                      onPressed: () =>
                          _set('Blur (15)', const BlurEffect(radius: 15)),
                      child: const Text('Blur'),
                    ),
                    ElevatedButton(
                      onPressed: () =>
                          _set('Teal', const ColorEffect(Color(0xFF00E5CC))),
                      child: const Text('Teal'),
                    ),
                    ElevatedButton(
                      onPressed: () => _set(
                        'Office',
                        ImageEffect.asset('assets/office.jpg'),
                      ),
                      child: const Text('Office'),
                    ),
                    ElevatedButton(
                      onPressed: () => _set(
                        'Gradient',
                        ImageEffect.asset('assets/gradient.png'),
                      ),
                      child: const Text('Gradient'),
                    ),
                    FilledButton.icon(
                      onPressed: _joining ? null : _join,
                      icon: const Icon(Icons.video_call),
                      label: const Text('Join'),
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

class _CallPage extends StatefulWidget {
  const _CallPage({required this.handoff});

  final PreviewHandoff handoff;

  @override
  State<_CallPage> createState() => _CallPageState();
}

class _CallPageState extends State<_CallPage> {
  final RTCVideoRenderer _renderer = RTCVideoRenderer();
  Future<void>? _init;
  bool _rendererDisposed = false;

  @override
  void initState() {
    super.initState();
    _init = _renderer.initialize();
    unawaited(_attach());
  }

  @override
  void dispose() {
    final init = _init;
    if (init == null) {
      _disposeRenderer();
    } else {
      unawaited(init.whenComplete(_disposeRenderer));
    }
    unawaited(_releaseHandoff());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Call — handed-off track')),
      body: Column(
        children: [
          const Padding(
            padding: EdgeInsets.all(12),
            child: Text('Camera kept running; effect stays attached.'),
          ),
          Expanded(child: RTCVideoView(_renderer, mirror: true)),
        ],
      ),
    );
  }

  Future<void> _attach() async {
    await _init;
    if (_rendererDisposed) return;
    debugPrint('T165| CALL stream=${widget.handoff.stream.id}');
    _renderer.srcObject = widget.handoff.stream;
    if (mounted) setState(() {});
  }

  Future<void> _releaseHandoff() async {
    debugPrint('T165| CALL_RELEASE');
    await widget.handoff.track.stop();
    await widget.handoff.stream.dispose();
    await widget.handoff.kit.dispose();
  }

  void _disposeRenderer() {
    if (_rendererDisposed) return;
    _rendererDisposed = true;
    unawaited(_renderer.dispose());
  }
}
