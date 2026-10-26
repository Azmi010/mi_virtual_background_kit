import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'mi_virtual_background_kit_platform_interface.dart';
import 'src/effects/effects.dart';
import 'src/status/status.dart';

export 'src/effects/effects.dart';
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

  /// Attaches the processor to a local camera [track].
  ///
  /// Throws [InvalidTrackException] if the track is null or has no id.
  /// Throws [UnsupportedPlatformException] if the platform rejects the track.
  Future<void> attach(MediaStreamTrack track) async {
    _ensureNotDisposed();
    final id = track.id;
    if (id == null || id.isEmpty) {
      throw const InvalidTrackException('track has no id');
    }
    await _platform.attach(id);
    _attached = true;
  }

  /// Applies [effect] to subsequent frames. Idempotent; does not restart the
  /// camera track (FR-05).
  Future<void> setEffect(VirtualBackgroundEffect effect) async {
    _ensureNotDisposed();
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
