import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

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
  bool _prodAttached = false;
  String _activeEffectName = 'None';
  double _blurRadius = 20.0;
  bool _transformOn = true;
  bool _hideControls = false;
  Uint8List? _testImageBytes;
  bool _benchmarked = false;
  int _gpuMicros = 0;
  int _gpuCount = 0;
  String _gpuType = '';
  Timer? _timer;
  StreamSubscription<ProcessorStatus>? _statusSubscription;
  ProcessorStatus _processorStatus = ProcessorStatus.idle;
  bool _isSupported = false;

  @override
  void initState() {
    super.initState();
    _renderer.initialize();
    _statusSubscription = _kit.statusStream.listen((status) {
      debugPrint('KIT STATUS: $status');
      if (mounted) setState(() => _processorStatus = status);
    });
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
      final supported = await _kit.isSupported();
      if (mounted) setState(() => _isSupported = supported);
      setState(() => _status = 'track=${track.id}');

      const prodMode = bool.fromEnvironment('PROD_ATTACH');
      debugPrint('PROD_ATTACH=$prodMode');
      if (prodMode) {
        // T3.2 / T3.3 verification mode: production processor with blur compositing.
        await _kit.attach(track);
        setState(() => _prodAttached = true);
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

  Future<Uint8List> _ensureTestPatternImage() async {
    final existing = _testImageBytes;
    if (existing != null) return existing;
    const width = 640;
    const height = 480;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, const Rect.fromLTWH(0.0, 0.0, 640.0, 480.0));

    // Sky-blue to orange gradient
    final paint = Paint()
      ..shader = ui.Gradient.linear(
        Offset.zero,
        const Offset(0.0, 480.0),
        [const Color(0xFF1E88E5), const Color(0xFFFF6F00)],
      );
    canvas.drawRect(const Rect.fromLTWH(0.0, 0.0, 640.0, 480.0), paint);

    // Upward arrow
    final arrowPaint = Paint()
      ..color = Colors.white
      ..strokeWidth = 14
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    final path = Path()
      ..moveTo(width * 0.5, height * 0.2)
      ..lineTo(width * 0.35, height * 0.45)
      ..moveTo(width * 0.5, height * 0.2)
      ..lineTo(width * 0.65, height * 0.45)
      ..moveTo(width * 0.5, height * 0.2)
      ..lineTo(width * 0.5, height * 0.8);
    canvas.drawPath(path, arrowPaint);

    final picture = recorder.endRecording();
    final img = await picture.toImage(width, height);
    final byteData = await img.toByteData(format: ui.ImageByteFormat.png);
    final bytes = byteData!.buffer.asUint8List();
    _testImageBytes = bytes;
    return bytes;
  }

  Future<void> _applyNone() async {
    await _kit.setEffect(const NoEffect());
    setState(() => _activeEffectName = 'None');
    debugPrint('PROD effect: None');
  }

  Future<void> _applyBlur() async {
    await _kit.setEffect(BlurEffect(radius: _blurRadius));
    setState(() => _activeEffectName = 'Blur (${_blurRadius.toInt()})');
    debugPrint('PROD effect: Blur radius=$_blurRadius');
  }

  Future<void> _applyColor(Color color, String name) async {
    await _kit.setEffect(ColorEffect(color));
    setState(() => _activeEffectName = 'Color ($name)');
    debugPrint('PROD effect: Color $name');
  }

  Future<void> _applyImage(BackgroundFit fit) async {
    final bytes = await _ensureTestPatternImage();
    await _kit.setEffect(ImageEffect.bytes(bytes, fit: fit));
    setState(() => _activeEffectName = 'Image (${fit.name})');
    debugPrint('PROD effect: Image fit=${fit.name}');
  }

  Future<void> _changeRadius(double radius) async {
    setState(() => _blurRadius = radius);
    if (_activeEffectName.startsWith('Blur')) {
      await _applyBlur();
    }
  }

  Future<void> _toggleTransform() async {
    final next = !_transformOn;
    await _kit.spikeSetEnabled(next);
    setState(() => _transformOn = next);
    debugPrint('SPIKE transformOn=$next');
  }

  @override
  void dispose() {
    _statusSubscription?.cancel();
    _timer?.cancel();
    _renderer.dispose();
    super.dispose();
  }

  Widget _buildControls() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '$_status  |  status: ${_processorStatus.name.toUpperCase()} (supported: $_isSupported)',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 11),
          ),
          const SizedBox(height: 2),
          Text(
            'frames: $_frames  fps: $_fps  mode: ${_prodAttached ? "PROD" : "SPIKE"}',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
          ),
          if (!_prodAttached) ...[
            Text(
              'gpu: ${_gpuMicros}us  n=$_gpuCount  type=$_gpuType',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12),
            ),
          ],
          const SizedBox(height: 6),
          if (_prodAttached) ...[
            Text(
              'Active Effect: $_activeEffectName',
              textAlign: TextAlign.center,
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
            ),
            const SizedBox(height: 4),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              alignment: WrapAlignment.center,
              children: [
                ElevatedButton(
                  onPressed: _applyNone,
                  child: const Text('None'),
                ),
                ElevatedButton(
                  onPressed: _applyBlur,
                  child: const Text('Blur'),
                ),
                ElevatedButton(
                  onPressed: () => _applyColor(const Color(0xFF00796B), 'Teal'),
                  child: const Text('Teal'),
                ),
                ElevatedButton(
                  onPressed: () => _applyImage(BackgroundFit.cover),
                  child: const Text('Img Cover'),
                ),
                ElevatedButton(
                  onPressed: () => _applyImage(BackgroundFit.contain),
                  child: const Text('Img Contain'),
                ),
              ],
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text('Radius: ${_blurRadius.toInt()}'),
                Expanded(
                  child: Slider(
                    value: _blurRadius,
                    min: 5,
                    max: 50,
                    divisions: 9,
                    onChanged: _changeRadius,
                  ),
                ),
              ],
            ),
          ] else
            ElevatedButton(
              onPressed: _spiked ? _toggleTransform : null,
              child: Text(
                _transformOn ? 'Disable transform' : 'Enable transform',
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('MiVirtualBackgroundKit'),
        actions: [
          IconButton(
            tooltip: _hideControls ? 'Show controls' : 'Hide controls',
            icon: Icon(_hideControls ? Icons.visibility : Icons.visibility_off),
            onPressed: () => setState(() => _hideControls = !_hideControls),
          ),
        ],
      ),
      body: OrientationBuilder(
        builder: (context, orientation) {
          final isLandscape = orientation == Orientation.landscape;

          final video = Stack(
            children: [
              Positioned.fill(
                child: RTCVideoView(
                  _renderer,
                  mirror: true,
                  objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                ),
              ),
              if (_hideControls) ...[
                Positioned(
                  top: 12,
                  right: 12,
                  child: FloatingActionButton.small(
                    tooltip: 'Show controls',
                    backgroundColor: Colors.black54,
                    foregroundColor: Colors.white,
                    onPressed: () => setState(() => _hideControls = false),
                    child: const Icon(Icons.tune),
                  ),
                ),
                Positioned(
                  top: 12,
                  left: 12,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      'fps: $_fps  frames: $_frames  status: ${_processorStatus.name}  effect: $_activeEffectName',
                      style: const TextStyle(color: Colors.white, fontSize: 11),
                    ),
                  ),
                ),
              ],
            ],
          );

          if (isLandscape) {
            return Row(
              children: [
                Expanded(child: video),
                if (!_hideControls)
                  SizedBox(
                    width: 280,
                    child: Material(
                      elevation: 4,
                      child: SafeArea(
                        child: SingleChildScrollView(
                          child: _buildControls(),
                        ),
                      ),
                    ),
                  ),
              ],
            );
          }

          return Column(
            children: [
              Expanded(child: video),
              if (!_hideControls)
                Material(
                  elevation: 4,
                  child: SafeArea(
                    top: false,
                    child: _buildControls(),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}
