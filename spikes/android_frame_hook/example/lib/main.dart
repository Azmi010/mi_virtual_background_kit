import 'package:flutter/material.dart';

import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:mi_virtual_background_kit/src/platform/mi_virtual_background_kit_method_channel.dart';

void main() {
  runApp(const SpikeApp());
}

class SpikeApp extends StatelessWidget {
  const SpikeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: const SpikePage(),
    );
  }
}

class SpikePage extends StatefulWidget {
  const SpikePage({super.key});

  @override
  State<SpikePage> createState() => _SpikePageState();
}

class _SpikePageState extends State<SpikePage> {
  final _renderer = RTCVideoRenderer();
  final _spike = MethodChannelMiVirtualBackgroundKit();
  MediaStream? _stream;
  String _status = 'idle';
  int _frames = 0;
  bool _spiked = false;

  @override
  void initState() {
    super.initState();
    _renderer.initialize();
    _start();
  }

  Future<void> _start() async {
    try {
      final stream = await navigator.mediaDevices.getUserMedia(
        const {
          'audio': false,
          'video': {
            'facingMode': 'user',
            'width': 640,
            'height': 480,
            'frameRate': 30,
          },
        },
      );
      _stream = stream;
      final track = stream.getVideoTracks().first;
      _renderer.srcObject = stream;
      setState(() => _status = 'track=${track.id} kind=${track.kind}');
    } catch (e) {
      setState(() => _status = 'ERROR $e');
    }
  }

  Future<void> _attachSpike() async {
    final track = _stream?.getVideoTracks().first;
    if (track == null) {
      setState(() => _status = 'no track');
      return;
    }
    final ok = await _spike.spikeAttach(track.id!);
    setState(() {
      _spiked = ok;
      _status = ok ? 'spike attached to ${track.id}' : 'spike attach FAILED';
    });
  }

  Future<void> _detachSpike() async {
    final track = _stream?.getVideoTracks().first;
    if (track == null) return;
    final ok = await _spike.spikeDetach(track.id!);
    setState(() {
      _spiked = false;
      _status = ok ? 'spike detached' : 'spike detach FAILED';
    });
  }

  Future<void> _countFrames() async {
    final n = await _spike.spikeFrameCount();
    setState(() => _frames = n);
  }

  @override
  void dispose() {
    _renderer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Spike T0.4 frame hook')),
      body: Column(
        children: [
          Expanded(
            child: RTCVideoView(
              _renderer,
              mirror: true,
              objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              children: [
                Text(_status, style: const TextStyle(fontSize: 12)),
                Text('frames processed: $_frames'),
                Wrap(
                  spacing: 8,
                  children: [
                    ElevatedButton(
                      onPressed: _spiked ? null : _attachSpike,
                      child: const Text('Attach spike'),
                    ),
                    ElevatedButton(
                      onPressed: _spiked ? _detachSpike : null,
                      child: const Text('Detach spike'),
                    ),
                    ElevatedButton(
                      onPressed: _countFrames,
                      child: const Text('Read frame count'),
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
