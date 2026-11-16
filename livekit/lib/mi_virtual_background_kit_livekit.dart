import 'package:livekit_client/livekit_client.dart'
    show
        CancelListenFunc,
        LocalTrackPublishedEvent,
        LocalTrackUnpublishedEvent,
        LocalVideoTrack,
        Room,
        TrackSource;
import 'package:mi_virtual_background_kit/mi_virtual_background_kit.dart'
    show BackgroundQuality, MiVirtualBackgroundKit, VirtualBackgroundEffect;

/// LiveKit adapter for `mi_virtual_background_kit`.
///
/// Attaches the core effect pipeline to a published local LiveKit camera track.
/// All effect logic stays in the core package; this adapter only translates the
/// track type, forwards calls, and re-attaches when LiveKit replaces the
/// underlying `MediaStreamTrack` (ADR 0002 §5, mechanism C).
class LiveKitVirtualBackground {
  /// Creates an adapter, optionally watching [room] for publish/unpublish
  /// events. Passing the room enables recovery after republish and detach on
  /// unpublish; track-level events work without it.
  LiveKitVirtualBackground({Room? room}) : _room = room {
    final currentRoom = _room;
    if (currentRoom != null) {
      _roomSubs.add(
        currentRoom.events.on<LocalTrackPublishedEvent>(_onPublished),
      );
      _roomSubs.add(
        currentRoom.events.on<LocalTrackUnpublishedEvent>(_onUnpublished),
      );
    }
  }

  final MiVirtualBackgroundKit _kit = MiVirtualBackgroundKit();
  final Room? _room;
  final List<CancelListenFunc> _roomSubs = [];
  CancelListenFunc? _trackSub;
  LocalVideoTrack? _track;
  bool _disposed = false;

  /// Attaches the processor to a published local camera [track].
  ///
  /// The kit attaches to the underlying `MediaStreamTrack`, the same track the
  /// core package uses for `flutter_webrtc`. When [quality] is omitted, the core
  /// reuses the previous configuration.
  Future<void> attach(
    LocalVideoTrack track, {
    BackgroundQuality? quality,
  }) async {
    _ensureNotDisposed();
    await _wireTrack(track);
    await _kit.attach(track.mediaStreamTrack, quality: quality);
  }

  /// Applies [effect] without restarting the camera track.
  Future<void> setEffect(VirtualBackgroundEffect effect) =>
      _kit.setEffect(effect);

  /// Detaches from the current track. Idempotent.
  ///
  /// Room listeners stay active so a republished camera track is attached
  /// automatically.
  Future<void> detach() async {
    await _trackSub?.call();
    _trackSub = null;
    _track = null;
    await _kit.detach();
  }

  /// Cancels all listeners and releases native resources. Idempotent.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    for (final cancel in _roomSubs) {
      await cancel();
    }
    _roomSubs.clear();
    await _trackSub?.call();
    _trackSub = null;
    _track = null;
    await _kit.dispose();
  }

  Future<void> _wireTrack(LocalVideoTrack track) async {
    if (identical(_track, track)) return;
    await _trackSub?.call();
    _track = track;
    _trackSub = track.events.listen((event) async {
      // TrackStreamUpdatedEvent is internal in livekit_client, so match by
      // runtime type name. Ignore events from a track we no longer own.
      if (_disposed || !identical(_track, track)) return;
      if (event.runtimeType.toString() != 'TrackStreamUpdatedEvent') return;
      await _kit.attach(track.mediaStreamTrack);
    });
  }

  Future<void> _onPublished(LocalTrackPublishedEvent event) async {
    if (_disposed || event.publication.source != TrackSource.camera) return;
    final track = event.publication.track;
    if (track is LocalVideoTrack) await attach(track);
  }

  Future<void> _onUnpublished(LocalTrackUnpublishedEvent event) async {
    if (_disposed || event.publication.source != TrackSource.camera) return;
    await detach();
  }

  void _ensureNotDisposed() {
    if (_disposed) {
      throw StateError('LiveKitVirtualBackground has been disposed');
    }
  }
}
