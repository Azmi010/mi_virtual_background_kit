import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:mi_virtual_background_kit/mi_virtual_background_kit.dart';
// ignore: implementation_imports
import 'package:mi_virtual_background_kit/src/platform/mi_virtual_background_kit_method_channel.dart';

/// T14.2/T14.3 measurement page — temporal mask smoothing (FR-20).
///
/// One run sweeps the smoothing variants x 2 stages (5 s each), always in the
/// same order. Perform the SAME script every run so the clips stay comparable:
///
/// - stage `still`:    sit still, look at the camera (edge flicker measurement).
/// - stage `motion`:   fast motion — shake the head, wave arms, lean in and
///                     out of frame (ghosting measurement).
///
/// Variants:
/// - `none`      raw mask (v0.1 baseline for the -50% flicker target).
/// - `adp-d006`  adaptive s = 0.7, D0 = 0.06 (spike T13.3 pick).
/// - `adp-d010`  adaptive s = 0.7, D0 = 0.10 (tuning candidate).
/// - `adp-d012`  adaptive s = 0.7, D0 = 0.12 (tuning candidate).
/// - `prod`      the production path (BackgroundQuality default), no override.
///
/// Native logs one `T133| m=.. v=.. st=.. rev=.. chg=.. d=.. lag=.. us=.. fps=..`
/// line per mask (Android: tool/smoothing_log.sh, iOS: tee the flutter run
/// output). Dart markers: `T133| STAGE <name> SETTLED` and `T133| STAGE ALL DONE`.
/// Analysis: `python3 tool/smoothing_metrics.py <logfile...>`.
class FlickerTestPage extends StatefulWidget {
  const FlickerTestPage({super.key});

  @override
  State<FlickerTestPage> createState() => _FlickerTestPageState();
}

class _FlickerTestPageState extends State<FlickerTestPage> {
  static const _videoConstraints = <String, dynamic>{
    'facingMode': 'user',
    'width': 640,
    'height': 480,
    'frameRate': 30,
  };

  /// (label, mode, history weight s, D0) — null mode = production path.
  static const _variants = <(String, String?, double, double?)>[
    ('none', 'none', 0.0, null),
    ('adp-d006', 'adaptive', 0.7, 0.06),
    ('adp-d010', 'adaptive', 0.7, 0.10),
    ('adp-d012', 'adaptive', 0.7, 0.12),
    ('prod', null, 0.0, null),
  ];

  static const _stageSeconds = 5;

  final _hooks = MethodChannelMiVirtualBackgroundKit();
  MiVirtualBackgroundKit _kit = MiVirtualBackgroundKit();
  final _renderer = RTCVideoRenderer();
  MediaStream? _stream;
  MediaStreamTrack? _track;
  String _stage = 'idle';
  String _kitStatus = '-';
  String _instruction = '';
  int _remaining = 0;
  bool _started = false;
  bool _busy = false;
  bool _done = false;
  List<(String, Future<void> Function())> _stages = const [];
  int _stageIdx = 0;
  StreamSubscription<ProcessorStatus>? _statusSub;

  void _log(String msg) => debugPrint('T133| $msg');

  @override
  void initState() {
    super.initState();
    _renderer.initialize();
  }

  Future<void> _countdown(String instruction) async {
    for (var i = _stageSeconds; i > 0; i--) {
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

  Future<void> _act(String name, Future<void> Function() fn) async {
    _log('ACTION $name START');
    try {
      await fn();
      _log('ACTION $name DONE');
    } catch (e) {
      _log('ACTION $name ERROR $e');
    }
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
      await _hooks.testSetSmoothing('none', 0);
      await _hooks.testSetStage('warmup');
      _log('ACTION setup DONE track=${_track!.id}');

      _stages = [
        for (final (label, mode, value, d0) in _variants) ...[
          (
            'still-$label',
            () async {
              await _hooks.testSetSmoothing(mode, value, d0: d0);
              await _hooks.testSetStage('still');
              _log('VARIANT $label mode=${mode ?? 'prod'} s=$value d0=$d0');
              await _countdown('DIAM — jangan bergerak');
            },
          ),
          (
            'motion-$label',
            () async {
              await _hooks.testSetStage('motion');
              await _countdown(
                'GERAK CEPAT — goyang kepala, angkat tangan, '
                'maju-mundur dari frame',
              );
            },
          ),
        ],
      ];
      _stageIdx = 0;

      _log('STAGE warmup SETTLED track=${_track!.id}');
      if (mounted) {
        setState(() {
          _stage = 'warmup';
          _started = true;
        });
      }
    } catch (e, st) {
      _log('ERROR $e $st');
      if (mounted) setState(() => _stage = 'ERROR $e');
      _done = true;
    } finally {
      _busy = false;
      if (mounted) setState(() {});
    }
  }

  Future<void> _nextStage() async {
    if (_busy || _done || _stageIdx >= _stages.length) return;
    _busy = true;
    final (name, action) = _stages[_stageIdx++];
    await _act(name, action);
    _log('STAGE $name SETTLED');
    if (mounted) setState(() => _stage = name);
    if (_stageIdx >= _stages.length) {
      _log('STAGE ALL DONE');
      if (mounted) setState(() => _done = true);
    }
    _busy = false;
    if (mounted) setState(() {});
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
      _stages = const [];
      _stageIdx = 0;
      _instruction = '';
      _remaining = 0;
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
      appBar: AppBar(title: const Text('T14.2/T14.3 mask smoothing test')),
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (!_started) ...[
              const Text(
                'Start opens the camera and attaches the kit. The run sweeps '
                '5 smoothing variants, each with a "still" stage and a '
                '"motion" stage (5 s each). Perform the SAME motions every '
                'variant. Log markers: T133| STAGE <name> SETTLED.',
              ),
              const SizedBox(height: 8),
              FilledButton(
                onPressed: _busy ? null : _start,
                child: const Text('Start — warmup'),
              ),
            ] else ...[
              Text(
                'stage: $_stage  (${_stageIdx + 1}/${_stages.length})',
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
              if (!_done)
                FilledButton(
                  onPressed: _busy ? null : _nextStage,
                  child: Text(
                    _stageIdx < _stages.length
                        ? 'Next stage → ${_stages[_stageIdx].$1}'
                        : 'Next stage',
                  ),
                ),
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
