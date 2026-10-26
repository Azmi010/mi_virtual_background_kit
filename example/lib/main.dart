import 'dart:async';

import 'dart:io';

import 'package:flutter/material.dart';

import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:mi_virtual_background_kit/mi_virtual_background_kit.dart';

void main() {
  runApp(const SpikeApp());
}

class SpikeApp extends StatelessWidget {
  const SpikeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(home: const SpikePage());
  }
}

class SpikePage extends StatefulWidget {
  const SpikePage({super.key});

  @override
  State<SpikePage> createState() => _SpikePageState();
}

class _SpikePageState extends State<SpikePage> {
  final _renderer = RTCVideoRenderer();
  final _kit = MiVirtualBackgroundKit();
  MediaStream? _stream;
  String _status = 'idle';
  int _frames = 0;
  int _fps = 0;
  int _lastCount = 0;
  bool _spiked = false;
  bool _transformOn = true;
  bool _benchmarked = false;
  int _gpuMicros = 0;
  int _gpuCount = 0;
  String _gpuType = '';
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _renderer.initialize();
    _start();
  }

  Future<void> _start() async {
    try {
      final stream = await navigator.mediaDevices.getUserMedia(const {
        'audio': false,
        'video': {
          'facingMode': 'user',
          'width': 640,
          'height': 480,
          'frameRate': 30,
        },
      });
      _stream = stream;
      final track = stream.getVideoTracks().first;
      _renderer.srcObject = stream;
      setState(() => _status = 'track=${track.id}');

      const prodMode = bool.fromEnvironment('PROD_ATTACH');
      debugPrint('PROD_ATTACH=$prodMode');
      if (prodMode) {
        // T3.2 verification mode: production processor only, no spike chain.
        await _kit.attach(track);
        debugPrint('PROD attached track=${track.id}');
      } else {
        final ok = await _kit.spikeAttach(track.id!);
        setState(() => _spiked = ok);
        debugPrint('SPIKE attach=$ok trackId=${track.id}');

        if (!Platform.isAndroid) {
          debugPrint('SPIKE gpu path is Android only, skipping');
        } else {
          final gpuOk = await _kit.spikeEnableGpu(true);
          debugPrint('SPIKE gpuEnabled=$gpuOk');
        }
      }

      _timer = Timer.periodic(const Duration(seconds: 1), (_) => _updateHud());
      Future<void>.delayed(const Duration(seconds: 1), () async {
        // bare bool.fromEnvironment does not read the environment (always
        // false); reuse the const above.
        if (_benchmarked || prodMode) return;
        _benchmarked = true;
        if (Platform.isAndroid) {
          final rb = await _kit.spikeReadback();
          debugPrint('SPIKE readback=$rb');
          final seg = await _kit.spikeSegmentBenchmark();
          debugPrint('SPIKE segment=$seg');
          await _runCompositeStages();
        } else {
          await _kit.spikeBenchmarkReadback();
        }
      });
    } catch (e) {
      setState(() => _status = 'ERROR $e');
      debugPrint('SPIKE error $e');
    }
  }

  Future<void> _runCompositeStages() async {
    setState(() => _status = 'composite bench @640...');
    final r1 = await _kit.spikeCompositeBench();
    debugPrint('COMPOSITE640 $r1');
    setState(() => _status = 'composite640 done');

    // Tear the 640p track down so the next getUserMedia gets fresh 720p
    // constraints — flutter_webrtc would otherwise share the old VideoSource.
    _timer?.cancel();
    try {
      await _kit.spikeDetach(_stream!.getVideoTracks().first.id!);
    } catch (_) {
      // Detach is best-effort; the stream is disposed right after.
    }
    _stream?.getTracks().forEach((t) => t.stop());
    await _stream?.dispose();

    final s2 = await navigator.mediaDevices.getUserMedia(const {
      'audio': false,
      'video': {
        'facingMode': 'user',
        'width': 1280,
        'height': 720,
        'frameRate': 30,
      },
    });
    _stream = s2;
    _renderer.srcObject = s2;
    final t2 = s2.getVideoTracks().first;
    await _kit.spikeAttach(t2.id!);
    await _kit.spikeEnableGpu(true);

    setState(() => _status = 'composite bench @720p...');
    final r2 = await _kit.spikeCompositeBench();
    debugPrint('COMPOSITE720 $r2');
    setState(() => _status = 'composite720 done ${r2['w']}x${r2['h']}');

    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _updateHud());
  }

  Future<void> _updateHud() async {
    final info = await _kit.spikeInfo();
    final n = (info['frames'] as int?) ?? 0;
    final gpu = Platform.isAndroid
        ? await _kit.spikeGpuInfo()
        : <dynamic, dynamic>{};
    setState(() {
      _fps = n - _lastCount;
      _lastCount = n;
      _frames = n;
      _gpuMicros = (gpu['compositeMicros'] as int?) ?? 0;
      _gpuCount = (gpu['compositeCount'] as int?) ?? 0;
      _gpuType = (gpu['inputType'] as String?) ?? '';
    });
    debugPrint(
      'SPIKE frames=$n fps=$_fps buffer=${info['bufferType']} '
      'rot=${info['rotation']} size=${info['width']}x${info['height']} '
      'gpu=${_gpuMicros}us count=$_gpuCount type=$_gpuType',
    );
  }

  Future<void> _toggleTransform() async {
    final next = !_transformOn;
    await _kit.spikeSetEnabled(next);
    setState(() => _transformOn = next);
    debugPrint('SPIKE transformOn=$next');
  }

  @override
  void dispose() {
    _timer?.cancel();
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
                Text(_status, style: const TextStyle(fontSize: 11)),
                Text(
                  'frames: $_frames  fps: $_fps  transform: $_transformOn',
                  style: const TextStyle(fontSize: 13),
                ),
                Text(
                  'gpu: ${_gpuMicros}us  n=$_gpuCount  type=$_gpuType',
                  style: const TextStyle(fontSize: 13),
                ),
                const SizedBox(height: 8),
                ElevatedButton(
                  onPressed: _spiked ? _toggleTransform : null,
                  child: Text(
                    _transformOn ? 'Disable transform' : 'Enable transform',
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
