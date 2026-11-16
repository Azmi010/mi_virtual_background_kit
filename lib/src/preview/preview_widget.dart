import 'dart:async';

// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../../mi_virtual_background_kit.dart' show BackgroundFit;
import 'preview.dart';

/// Camera preview that renders the local track with its virtual background.
///
/// The controller owns camera acquisition and the kit; this widget only renders
/// the stream and turns start/permission errors into state instead of crashing.
class VirtualBackgroundPreview extends StatefulWidget {
  /// Creates a preview for [controller].
  ///
  /// The widget calls `controller.start()` when the controller has not started
  /// yet. A failed start is shown in place of the video with a retry button.
  const VirtualBackgroundPreview({
    super.key,
    required this.controller,
    this.mirror = true,
    this.fit = BackgroundFit.cover,
  });

  /// Controller that owns the camera and background processor.
  final VirtualBackgroundPreviewController controller;

  /// Mirrors the preview, typically for the front camera.
  final bool mirror;

  /// How the camera frame fills the widget.
  final BackgroundFit fit;

  @override
  State<VirtualBackgroundPreview> createState() =>
      _VirtualBackgroundPreviewState();
}

class _VirtualBackgroundPreviewState extends State<VirtualBackgroundPreview> {
  final RTCVideoRenderer _renderer = RTCVideoRenderer();
  Future<void>? _init;
  Object? _error;
  bool _starting = false;
  bool _rendererDisposed = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onControllerChanged);
    _init = _renderer.initialize();
    if (widget.controller.isStarted) {
      unawaited(_syncRenderer());
    } else {
      unawaited(_start());
    }
  }

  @override
  void didUpdateWidget(covariant VirtualBackgroundPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onControllerChanged);
      widget.controller.addListener(_onControllerChanged);
      unawaited(_syncRenderer());
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    final init = _init;
    if (init == null) {
      _disposeRenderer();
    } else {
      unawaited(init.whenComplete(_disposeRenderer));
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final error = _error;
    if (error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Camera preview error: $error',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              ElevatedButton(
                onPressed: _retry,
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    final stream = widget.controller.stream;
    if (stream == null || stream.getVideoTracks().isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    return RTCVideoView(
      _renderer,
      mirror: widget.mirror,
      objectFit: switch (widget.fit) {
        BackgroundFit.cover => RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
        BackgroundFit.contain =>
          RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
      },
    );
  }

  Future<void> _start() async {
    if (_starting) return;
    _starting = true;
    try {
      await widget.controller.start();
      if (mounted) setState(() => _error = null);
    } catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      _starting = false;
    }
    await _syncRenderer();
  }

  void _retry() => unawaited(_start());

  void _onControllerChanged() => unawaited(_syncRenderer());

  Future<void> _syncRenderer() async {
    await _init;
    if (!mounted || _rendererDisposed) return;
    _renderer.srcObject = widget.controller.stream;
    if (mounted) setState(() {});
  }

  void _disposeRenderer() {
    if (_rendererDisposed) return;
    _rendererDisposed = true;
    unawaited(_renderer.dispose());
  }
}
