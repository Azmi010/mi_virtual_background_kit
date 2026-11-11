import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:mi_virtual_background_kit/mi_virtual_background_kit.dart';

import 'livekit_page.dart';

void main() {
  runApp(const ExampleApp());
}

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(home: const ExamplePage());
  }
}

class ExamplePage extends StatefulWidget {
  const ExamplePage({super.key});

  @override
  State<ExamplePage> createState() => _ExamplePageState();
}

class _ExamplePageState extends State<ExamplePage> {
  final _renderer = RTCVideoRenderer();
  final _kit = MiVirtualBackgroundKit();
  MediaStream? _stream;
  String _status = 'idle';
  bool _prodAttached = false;
  String _activeEffectName = 'None';
  double _blurRadius = 20.0;
  BackgroundQuality _quality = BackgroundQuality.balanced;
  bool _hideControls = false;
  Uint8List? _testImageBytes;
  StreamSubscription<ProcessorStatus>? _statusSubscription;
  StreamSubscription<PerformanceFallbackEvent>? _fallbackSubscription;
  ProcessorStatus _processorStatus = ProcessorStatus.idle;
  bool _isSupported = false;
  String? _lastFallbackMessage;

  @override
  void initState() {
    super.initState();
    _renderer.initialize();
    _statusSubscription = _kit.statusStream.listen((status) {
      debugPrint('KIT STATUS: $status');
      if (mounted) setState(() => _processorStatus = status);
    });
    _fallbackSubscription = _kit.fallbackStream.listen((event) {
      debugPrint('KIT FALLBACK: $event');
      if (mounted) {
        setState(() {
          _lastFallbackMessage =
              '${event.action == FallbackAction.qualityDegraded ? "Degraded" : "Disabled"} (${event.reason})';
          if (event.action == FallbackAction.disabled) {
            _activeEffectName = 'None (Auto-disabled)';
          }
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '⚠️ Fallback: ${event.action.name} (${event.reason})',
            ),
            duration: const Duration(seconds: 4),
            backgroundColor: event.action == FallbackAction.disabled
                ? Colors.redAccent
                : Colors.orangeAccent,
          ),
        );
      }
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

      // Production processor with runtime background compositing.
      await _kit.attach(track, quality: _quality);
      setState(() => _prodAttached = true);
      debugPrint('PROD attached track=${track.id}');
    } catch (e) {
      setState(() => _status = 'ERROR $e');
      debugPrint('EXAMPLE error $e');
    }
  }

  Future<Uint8List> _ensureTestPatternImage() async {
    final existing = _testImageBytes;
    if (existing != null) return existing;
    const width = 640;
    const height = 480;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(
      recorder,
      const Rect.fromLTWH(0.0, 0.0, 640.0, 480.0),
    );

    // Sky-blue to orange gradient
    final paint = Paint()
      ..shader = ui.Gradient.linear(Offset.zero, const Offset(0.0, 480.0), [
        const Color(0xFF1E88E5),
        const Color(0xFFFF6F00),
      ]);
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

  Future<void> _attach() async {
    try {
      final tracks = _stream?.getVideoTracks();
      if (tracks == null || tracks.isEmpty) return;
      final track = tracks.first;
      await _kit.attach(track, quality: _quality);
      setState(() {
        _prodAttached = true;
        _activeEffectName = 'None';
      });
      debugPrint('PROD attached track=${track.id}');
    } catch (e) {
      debugPrint('PROD attach error: $e');
    }
  }

  Future<void> _detach() async {
    try {
      await _kit.detach();
      setState(() {
        _prodAttached = false;
        _activeEffectName = 'None';
      });
      debugPrint('PROD detached');
    } catch (e) {
      debugPrint('PROD detach error: $e');
    }
  }

  Future<void> _switchCamera() async {
    try {
      final track = _stream?.getVideoTracks().first;
      if (track == null) return;
      await Helper.switchCamera(track);
      // FR-09: same track id after native switch; re-attach replaces the
      // processor and the kit re-applies the last effect automatically.
      if (_prodAttached) {
        await _kit.attach(track, quality: _quality);
      }
      debugPrint('switched camera track=${track.id}');
      if (mounted) setState(() => _status = 'camera switched');
    } catch (e) {
      debugPrint('switchCamera error: $e');
      if (mounted) setState(() => _status = 'switch ERROR $e');
    }
  }

  Future<void> _applyNone() async {
    await _kit.setEffect(const NoEffect());
    setState(() {
      _activeEffectName = 'None';
      _lastFallbackMessage = null;
    });
    debugPrint('PROD effect: None');
  }

  Future<void> _applyBlur() async {
    await _kit.setEffect(BlurEffect(radius: _blurRadius));
    setState(() {
      _activeEffectName = 'Blur (${_blurRadius.toInt()})';
      _lastFallbackMessage = null;
    });
    debugPrint('PROD effect: Blur radius=$_blurRadius');
  }

  Future<void> _applyColor(Color color, String name) async {
    await _kit.setEffect(ColorEffect(color));
    setState(() {
      _activeEffectName = 'Color ($name)';
      _lastFallbackMessage = null;
    });
    debugPrint('PROD effect: Color $name');
  }

  Future<void> _applyImage(BackgroundFit fit) async {
    final bytes = await _ensureTestPatternImage();
    await _kit.setEffect(ImageEffect.bytes(bytes, fit: fit));
    setState(() {
      _activeEffectName = 'Image (${fit.name})';
      _lastFallbackMessage = null;
    });
    debugPrint('PROD effect: Image fit=${fit.name}');
  }

  Future<void> _applyAssetImage(String assetPath) async {
    await _kit.setEffect(
      ImageEffect.asset(assetPath, fit: BackgroundFit.cover),
    );
    setState(() {
      _activeEffectName = 'Asset (${assetPath.split('/').last})';
      _lastFallbackMessage = null;
    });
    debugPrint('PROD effect: Asset $assetPath');
  }

  Future<void> _changeRadius(double radius) async {
    setState(() => _blurRadius = radius);
    if (_activeEffectName.startsWith('Blur')) {
      await _applyBlur();
    }
  }

  Future<void> _changeQuality(BackgroundQuality quality) async {
    setState(() => _quality = quality);
    if (_prodAttached) {
      await _kit.setQuality(quality);
      debugPrint('PROD quality: $quality');
    }
  }

  @override
  void dispose() {
    _statusSubscription?.cancel();
    _fallbackSubscription?.cancel();
    _kit.dispose();
    _stream?.getTracks().forEach((t) => t.stop());
    _stream?.dispose();
    _renderer.dispose();
    super.dispose();
  }

  Future<void> _openLiveKit() async {
    // One local camera session at a time: flutter_webrtc reuses an open
    // camera VideoSource for a second getUserMedia, and such shared tracks
    // never bind the videoSource processor, so addProcessor gets no frames.
    await _detach();
    final stream = _stream;
    _stream = null;
    stream?.getTracks().forEach((t) => t.stop());
    await stream?.dispose();
    if (mounted) {
      _renderer.srcObject = null;
      setState(() => _prodAttached = false);
    }

    if (!mounted) return;
    await Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => const LiveKitDemoPage()));

    // LiveKit page dispose() released the shared native resources; restart a
    // fresh capture — attach re-applies the last effect automatically.
    if (mounted) await _start();
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
          if (_lastFallbackMessage != null) ...[
            const SizedBox(height: 2),
            Text(
              '⚠️ Fallback: $_lastFallbackMessage',
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 11,
                color: Colors.deepOrange,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            alignment: WrapAlignment.center,
            children: [
              FilledButton.tonalIcon(
                onPressed: _prodAttached ? null : _attach,
                icon: const Icon(Icons.link, size: 18),
                label: const Text('Attach'),
              ),
              FilledButton.tonalIcon(
                onPressed: _prodAttached ? _detach : null,
                icon: const Icon(Icons.link_off, size: 18),
                label: const Text('Detach'),
              ),
              FilledButton.tonalIcon(
                onPressed: _switchCamera,
                icon: const Icon(Icons.cameraswitch, size: 18),
                label: const Text('Switch Cam'),
              ),
              FilledButton.tonalIcon(
                onPressed: _openLiveKit,
                icon: const Icon(Icons.video_call, size: 18),
                label: const Text('LiveKit'),
              ),
            ],
          ),
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
                ElevatedButton(
                  onPressed: () => _applyAssetImage('assets/office.jpg'),
                  child: const Text('Asset Office'),
                ),
                ElevatedButton(
                  onPressed: () => _applyAssetImage('assets/gradient.png'),
                  child: const Text('Asset Gradient'),
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
            const SizedBox(height: 4),
            SegmentedButton<BackgroundQuality>(
              segments: const [
                ButtonSegment(
                  value: BackgroundQuality.low,
                  label: Text('Low (15fps)'),
                ),
                ButtonSegment(
                  value: BackgroundQuality.balanced,
                  label: Text('Balanced'),
                ),
                ButtonSegment(
                  value: BackgroundQuality.high,
                  label: Text('High'),
                ),
              ],
              selected: {_quality},
              onSelectionChanged: (set) {
                if (set.isNotEmpty) _changeQuality(set.first);
              },
            ),
          ],
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
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      'status: ${_processorStatus.name}  effect: $_activeEffectName',
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
                        child: SingleChildScrollView(child: _buildControls()),
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
                  child: SafeArea(top: false, child: _buildControls()),
                ),
            ],
          );
        },
      ),
    );
  }
}
