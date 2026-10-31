import 'dart:typed_data';

import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'mi_virtual_background_kit_platform_interface.dart';
import 'src/effects/effects.dart';
import 'src/quality/quality.dart';
import 'src/status/status.dart';

export 'src/effects/effects.dart';
export 'src/quality/quality.dart';
export 'src/status/status.dart';

/// Real-time virtual background for local `flutter_webrtc` camera tracks.
///
/// Dart is control plane only: frames never cross into Dart. All processing
/// happens on-device in native code (GPU compositing + MediaPipe segmentation).
class MiVirtualBackgroundKit {
  MiVirtualBackgroundKit();

  MiVirtualBackgroundKitPlatform get _platform =>
      MiVirtualBackgroundKitPlatform.instance;

  bool _attached = false;
  bool _disposed = false;

  /// Whether the current device supports background processing.
  Future<bool> isSupported() => _platform.isSupported();

  /// Processor status: idle, initializing, active, error.
  Stream<ProcessorStatus> get statusStream => _platform.statusStream;

  /// Attaches the processor to a local camera [track] with optional [quality] settings.
  ///
  /// Throws [InvalidTrackException] if the track is null or has no id.
  /// Throws [UnsupportedPlatformException] if the platform rejects the track.
  Future<void> attach(
    MediaStreamTrack track, {
    BackgroundQuality quality = const BackgroundQuality(),
  }) async {
    _ensureNotDisposed();
    final id = track.id;
    if (id == null || id.isEmpty) {
      throw const InvalidTrackException('track has no id');
    }
    _validateQuality(quality);
    await _platform.attach(id, quality: quality.toMap());
    _attached = true;
  }

  /// Updates the processing [quality] configuration at runtime (FR-11).
  Future<void> setQuality(BackgroundQuality quality) async {
    _ensureNotDisposed();
    _validateQuality(quality);
    await _platform.setQuality(quality.toMap());
  }

  /// Applies [effect] to subsequent frames. Idempotent; does not restart the
  /// camera track (FR-05).
  ///
  /// Throws [ArgumentError] if a blur radius is out of range.
  /// Throws [InvalidImageException] if an image source is empty.
  Future<void> setEffect(VirtualBackgroundEffect effect) async {
    _ensureNotDisposed();
    _validateEffect(effect);
    await _platform.setEffect(effect.toMap());
  }

  /// Detaches the processor. Idempotent: safe to call when not attached or
  /// when already detached.
  Future<void> detach() async {
    if (!_attached) return;
    await _platform.detach();
    _attached = false;
  }

  /// Releases all native resources. Idempotent.
  ///
  /// After dispose the kit is unusable; create a new instance instead.
  Future<void> dispose() async {
    if (_disposed) return;
    await detach();
    await _platform.dispose();
    _disposed = true;
  }

  void _ensureNotDisposed() {
    if (_disposed) {
      throw StateError('MiVirtualBackgroundKit has been disposed');
    }
  }

  /// Validates [quality] configuration parameters (FR-11).
  void _validateQuality(BackgroundQuality quality) {
    if (quality.segmentationWidth <= 0) {
      throw ArgumentError.value(
        quality.segmentationWidth,
        'segmentationWidth',
        'must be positive',
      );
    }
    if (quality.edgeSmoothing.isNaN ||
        quality.edgeSmoothing < 0.0 ||
        quality.edgeSmoothing > 1.0) {
      throw ArgumentError.value(
        quality.edgeSmoothing,
        'edgeSmoothing',
        'must be between 0.0 and 1.0',
      );
    }
    if (quality.targetFps <= 0) {
      throw ArgumentError.value(
        quality.targetFps,
        'targetFps',
        'must be positive',
      );
    }
  }

  /// Validates [effect] before it reaches the platform channel.
  void _validateEffect(VirtualBackgroundEffect effect) {
    switch (effect) {
      case BlurEffect(:final radius):
        if (radius.isNaN || radius.isInfinite || radius <= 0 || radius > 100) {
          throw ArgumentError.value(
            radius,
            'radius',
            'blur radius must be in (0, 100]',
          );
        }
      case ImageEffect(:final sourceType, :final data):
        switch (sourceType) {
          case ImageSourceType.asset:
          case ImageSourceType.file:
            if ((data as String).trim().isEmpty) {
              throw const InvalidImageException('image path is empty');
            }
          case ImageSourceType.bytes:
            if ((data as Uint8List).isEmpty) {
              throw const InvalidImageException('image bytes are empty');
            }
        }
      case ColorEffect():
      case NoEffect():
        break;
    }
  }

  // --- Spike T0.4 (temporary, removed with example rewrite in Fase 7) ---

  Future<bool> spikeAttach(String trackId) => _platform.spikeAttach(trackId);

  Future<int> spikeFrameCount() => _platform.spikeFrameCount();

  Future<Map<dynamic, dynamic>> spikeInfo() => _platform.spikeInfo();

  Future<bool> spikeBenchmarkReadback() => _platform.spikeBenchmarkReadback();

  Future<Map<dynamic, dynamic>> spikeSegmentBenchmark() =>
      _platform.spikeSegmentBenchmark();

  Future<Map<dynamic, dynamic>> spikeCompositeBench() =>
      _platform.spikeCompositeBench();

  Future<Map<dynamic, dynamic>> spikeReadback() => _platform.spikeReadback();

  Future<bool> spikeEnableGpu(bool enabled) =>
      _platform.spikeEnableGpu(enabled);

  Future<Map<dynamic, dynamic>> spikeGpuInfo() => _platform.spikeGpuInfo();

  Future<bool> spikeSetEnabled(bool enabled) =>
      _platform.spikeSetEnabled(enabled);

  Future<bool> spikeDetach(String trackId) => _platform.spikeDetach(trackId);
}
