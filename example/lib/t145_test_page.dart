import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:mi_virtual_background_kit/mi_virtual_background_kit.dart';
// ignore: implementation_imports
import 'package:mi_virtual_background_kit/src/platform/mi_virtual_background_kit_method_channel.dart';

/// T14.5 measurement page — segmentation strategy for slow devices (FR-22,
/// ADR 0002 §8).
///
/// Sweeps four configurations of (model × segmentation width), 3 s warmup +
/// 10 s measurement each, always in the same order:
///
/// | stage | model                        | width |
/// |-------|------------------------------|-------|
/// | sq256 | selfie_segmenter (legacy)    | 256   |
/// | sq144 | selfie_segmenter (legacy)    | 144   |
/// | ls256 | selfie_segmenter_landscape   | 256   |
/// | ls144 | selfie_segmenter_landscape   | 144   |
///
/// Sit still facing the camera during every MEASURE countdown. Native logs
/// one extended `T133| ... gap=<ms> inf=<ms> iv=<n>` line per mask; Dart
/// markers: `T145| CONFIG <stage> START/DONE` and `T145| STAGE ALL DONE`.
/// Capture: `tool/t145_log.sh <label>`; analysis: `python3 tool/t145_metrics.py`.
/// On iOS the model switch is a no-op (Android-only per ADR 0002 §8), so all
/// four stages measure the fixed square model — use iOS only for smoke.
class T145TestPage extends StatefulWidget {
  const T145TestPage({super.key});

  @override
  State<T145TestPage> createState() => _T145TestPageState();
}

class _T145TestPageState extends State<T145TestPage> {
  static const _videoConstraints = <String, dynamic>{
    'facingMode': 'user',
    'width': 640,
    'height': 480,
    'frameRate': 30,
  };

  /// (stage tag, model asset or null = production landscape, width).
  static const _configs = <(String, String?, int)>[
    ('sq256', 'selfie_segmenter.tflite', 256),
    ('sq144', 'selfie_segmenter.tflite', 144),
    ('ls256', null, 256),
    ('ls144', null, 144),
  ];

  static const _warmupSeconds = 3;
  static const _measureSeconds = 10;

  final _hooks = MethodChannelMiVirtualBackgroundKit();
  MiVirtualBackgroundKit _kit = MiVirtualBackgroundKit();
  final _renderer = RTCVideoRenderer();
  MediaStream? _stream;
  MediaStreamTrack? _track;
  String _stage = 'idle';
  String _kitStatus = '-';
  String _instruction = '';
  int _remaining = 0;
  int _configIdx = 0;
  bool _started = false;
  bool _busy = false;
  bool _done = false;
  StreamSubscription<ProcessorStatus>? _statusSub;

  void _log(String msg) => debugPrint('T145| $msg');

  @override
  void initState() {
    super.initState();
    _renderer.initialize();
  }

  Future<void> _countdown(String instruction, int seconds) async {
    for (var i = seconds; i > 0; i--) {
      if (!mounted) return;
      setState(() {
        _instruction = instruction;
        _remaining = i;
      });
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    if (!mounted) return;
    setState(() {
      _instruction = '';
      _remaining = 0;
    });
  }

  Future<void> _start() async {
    if (_busy) return;
    _busy = true;
    _log('RUN start');
    try {
      _statusSub = _kit.statusStream.listen((s) {
        _log('KIT_STATUS ${s.name}');
        if (mounted) setState(() => _kitStatus = s.name);
      });
      if (mounted) setState(() => _stage = 'opening camera');
      _stream = await navigator.mediaDevices.getUserMedia(const {
        'audio': false,
        'video': _videoConstraints,
      });
      _track = _stream!.getVideoTracks().first;
      _renderer.srcObject = _stream;
      await _kit.attach(_track!);
      await _kit.setEffect(const ColorEffect(Color(0xFF00E5CC)));
      _log('ACTION setup DONE track=${_track!.id}');
      if (mounted) {
        setState(() {
          _started = true;
          _stage = 'warmup';
        });
      }

      for (var i = 0; i < _configs.length; i++) {
        final (label, asset, width) = _configs[i];
        if (mounted) setState(() => _configIdx = i);
        await _hooks.testSetModel(asset);
        await _kit.setQuality(BackgroundQuality(segmentationWidth: width));
        await _hooks.testSetStage(label);
        _log('CONFIG $label START model=${asset ?? 'landscape'} width=$width');
        if (mounted) setState(() => _stage = label);
        await _countdown('WARMUP — diam, siapkan pose', _warmupSeconds);
        await _countdown('MEASURE — diam total, tatap kamera', _measureSeconds);
        _log('CONFIG $label DONE');
      }

      _log('STAGE ALL DONE');
      if (mounted) setState(() => _done = true);
    } catch (e, st) {
      _log('ERROR $e $st');
      if (mounted) setState(() => _stage = 'ERROR $e');
      _done = true;
    } finally {
      _busy = false;
      if (mounted) setState(() {});
    }
  }

  Future<void> _reset() async {
    if (_busy) return;
    await _statusSub?.cancel();
    _statusSub = null;
    final stream = _stream;
    _stream = null;
    _track = null;
    _renderer.srcObject = null;
    if (stream != null) {
      for (final t in stream.getTracks()) {
        try {
          await t.stop();
        } catch (_) {
          // already stopped
        }
      }
      try {
        await stream.dispose();
      } catch (_) {
        // already disposed
      }
    }
    await _kit.dispose();
    if (!mounted) return;
    setState(() {
      _kit = MiVirtualBackgroundKit();
      _stage = 'idle';
      _kitStatus = '-';
      _started = false;
      _done = false;
      _instruction = '';
      _remaining = 0;
      _configIdx = 0;
    });
  }

  @override
  void dispose() {
    _statusSub?.cancel();
    _stream?.getTracks().forEach((t) => t.stop());
    _stream?.dispose();
    _renderer.dispose();
    _kit.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('T14.5 segmentation strategy test')),
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (!_started) ...[
              const Text(
                'Start opens the camera and sweeps 4 configs '
                '(sq256 → sq144 → ls256 → ls144), 3 s warmup + 10 s measure '
                'each. Sit still facing the camera during every MEASURE. '
                'Log markers: T145| CONFIG <stage> START/DONE.',
              ),
              const SizedBox(height: 8),
              FilledButton(
                onPressed: _busy ? null : _start,
                child: const Text('Start — run all configs'),
              ),
            ] else ...[
              Text(
                'config: $_stage  (${_configIdx + 1}/${_configs.length})',
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 15,
                ),
              ),
              const SizedBox(height: 4),
              Text('kit: $_kitStatus'),
              if (_instruction.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  '$_instruction  ($_remaining)',
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: Colors.orange,
                  ),
                ),
              ],
              const SizedBox(height: 10),
              if (_done)
                FilledButton(
                  onPressed: _reset,
                  child: const Text('Reset → start over'),
                ),
            ],
            if (_started && _stream != null) ...[
              const SizedBox(height: 8),
              Expanded(
                child: RTCVideoView(
                  _renderer,
                  mirror: true,
                  objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
