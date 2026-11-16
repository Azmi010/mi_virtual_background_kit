import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../../mi_virtual_background_kit.dart';

export 'preview_widget.dart';

/// Ownership handed to the caller after [VirtualBackgroundPreviewController.releaseToCaller].
///
/// The background effect stays attached to [track]. The caller owns [stream],
/// [track], and [kit] from this point and must release them when done.
class PreviewHandoff {
  /// Creates a handoff record.
  const PreviewHandoff({
    required this.stream,
    required this.track,
    required this.kit,
  });

  /// Camera stream that still carries the processed track.
  final MediaStream stream;

  /// Camera track with the background processor still attached.
  final MediaStreamTrack track;

  /// Core kit whose processor is attached to [track].
  final MiVirtualBackgroundKit kit;
}

/// Controls a local camera preview with a virtual background (FR-17, FR-18).
///
/// [start] opens the camera and attaches the core kit. [releaseToCaller]
/// transfers ownership of the camera and kit to the caller without stopping the
/// camera or removing the effect. All methods are idempotent where it is safe.
class VirtualBackgroundPreviewController extends ChangeNotifier {
  /// Creates a preview controller with optional processing [quality].
  ///
  /// [kit] and [openCamera] are seams for tests; apps use the defaults.
  VirtualBackgroundPreviewController({
    BackgroundQuality? quality,
    MiVirtualBackgroundKit? kit,
    Future<MediaStream> Function()? openCamera,
  })  : _quality = quality,
        _kit = kit ?? MiVirtualBackgroundKit(),
        _openCamera = openCamera ?? _defaultOpenCamera;

  final BackgroundQuality? _quality;
  final Future<MediaStream> Function() _openCamera;
  final MiVirtualBackgroundKit _kit;

  MediaStream? _stream;
  MediaStreamTrack? _track;
  PreviewHandoff? _handoff;
  bool _started = false;
  bool _released = false;
  bool _disposed = false;

  /// Core kit, for status/fallback/metrics streams and manual recovery.
  MiVirtualBackgroundKit get kit => _kit;

  /// Camera stream while the preview owns it; `null` after handoff or stop.
  MediaStream? get stream => _stream;

  /// Whether the preview currently owns a running camera.
  bool get isStarted => _started;

  /// Opens the camera and attaches the background processor.
  ///
  /// Calling this again while started is a no-op.
  Future<void> start() async {
    _ensureNotDisposed();
    if (_started || _released) return;

    final stream = await _openCamera();
    final videoTracks = stream.getVideoTracks();
    if (videoTracks.isEmpty) {
      await stream.dispose();
      throw const InvalidTrackException('camera stream has no video track');
    }

    _stream = stream;
    _track = videoTracks.first;
    try {
      await _kit.attach(_track!, quality: _quality);
    } catch (_) {
      await _releaseCamera();
      rethrow;
    }
    _started = true;
    notifyListeners();
  }

  /// Applies [effect]. Before [start], the effect is remembered and applied on
  /// attach, matching [MiVirtualBackgroundKit.setEffect].
  Future<void> setEffect(VirtualBackgroundEffect effect) async {
    _ensureNotDisposed();
    if (_released) {
      throw StateError('preview was released to the caller');
    }
    await _kit.setEffect(effect);
    notifyListeners();
  }

  /// Switches the front/back camera and re-applies the last effect.
  Future<void> switchCamera() async {
    _ensureNotDisposed();
    final track = _track;
    if (_released || track == null) return;
    await Helper.switchCamera(track);
    await _kit.attach(track);
    notifyListeners();
  }

  /// Stops the camera and detaches the processor. Idempotent.
  ///
  /// After [releaseToCaller] this method does not touch the handed-off track.
  Future<void> stop() async {
    if (_disposed || _released || !_started) return;
    await _releaseCamera();
    _started = false;
    notifyListeners();
  }

  /// Transfers camera and kit ownership to the caller.
  ///
  /// The effect stays attached. Repeated calls return the same [PreviewHandoff].
  Future<PreviewHandoff> releaseToCaller() async {
    _ensureNotDisposed();
    final existing = _handoff;
    if (existing != null) return existing;
    final stream = _stream;
    final track = _track;
    if (stream == null || track == null) {
      throw StateError('preview is not started');
    }

    _released = true;
    _started = false;
    final handoff = PreviewHandoff(stream: stream, track: track, kit: _kit);
    _handoff = handoff;
    _stream = null;
    _track = null;
    notifyListeners();
    return handoff;
  }

  /// Releases resources owned by this controller. Idempotent.
  ///
  /// After handoff the caller owns the camera and kit, so this only marks the
  /// controller disposed.
  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    if (_released) {
      super.dispose();
      return;
    }
    await _releaseCamera();
    await _kit.dispose();
    super.dispose();
  }

  Future<void> _releaseCamera() async {
    await _kit.detach();
    final track = _track;
    final stream = _stream;
    _track = null;
    _stream = null;
    await track?.stop();
    await stream?.dispose();
  }

  void _ensureNotDisposed() {
    if (_disposed) {
      throw StateError('VirtualBackgroundPreviewController has been disposed');
    }
  }
}

Future<MediaStream> _defaultOpenCamera() =>
    navigator.mediaDevices.getUserMedia(<String, dynamic>{
      'audio': false,
      'video': <String, dynamic>{
        'facingMode': 'user',
        'width': 640,
        'height': 480,
        'frameRate': 30,
      },
    });
