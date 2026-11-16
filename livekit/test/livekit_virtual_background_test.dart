import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_client/livekit_client.dart';
import 'package:mi_virtual_background_kit/mi_virtual_background_kit.dart';
// ignore: implementation_imports
import 'package:mi_virtual_background_kit/src/platform/mi_virtual_background_kit_platform_interface.dart';
import 'package:mi_virtual_background_kit_livekit/mi_virtual_background_kit_livekit.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

void main() {
  late FakePlatform platform;
  late LiveKitVirtualBackground adapter;
  late LocalVideoTrack track;

  Future<void> pumpEvents() =>
      Future<void>.delayed(const Duration(milliseconds: 10));

  LocalVideoTrack makeTrack(String id) {
    final native = FakeMediaStreamTrack(id);
    // ignore: invalid_use_of_internal_member
    return LocalVideoTrack(
      TrackSource.camera,
      FakeMediaStream('stream-$id', [native]),
      native,
      const CameraCaptureOptions(),
    );
  }

  setUp(() {
    platform = FakePlatform();
    MiVirtualBackgroundKitPlatform.instance = platform;
    track = makeTrack('track-1');
    adapter = LiveKitVirtualBackground();
  });

  tearDown(() async {
    await adapter.dispose();
  });

  test('attach forwards the underlying MediaStreamTrack id and quality',
      () async {
    await adapter.attach(
      track,
      quality: const BackgroundQuality(segmentationWidth: 128),
    );

    expect(platform.attachedIds, ['track-1']);
    expect(platform.qualities.single?['segmentationWidth'], 128);
  });

  test('setEffect forwards the serialized effect', () async {
    await adapter.setEffect(const BlurEffect(radius: 12));

    expect(platform.effects.single['type'], 'blur');
  });

  test('detach is idempotent', () async {
    await adapter.attach(track);

    await adapter.detach();
    await adapter.detach();

    expect(platform.detachCalls, 1);
  });

  test('stream update re-attaches to the new MediaStreamTrack', () async {
    await adapter.attach(track);
    final next = FakeMediaStreamTrack('track-2');
    // ignore: invalid_use_of_internal_member
    track.updateMediaStreamAndTrack(
      FakeMediaStream('stream-2', [next]),
      next,
    );

    await pumpEvents();

    expect(platform.attachedIds, ['track-1', 'track-2']);
  });

  test('detach stops stream-update recovery', () async {
    await adapter.attach(track);
    await adapter.detach();
    platform.attachedIds.clear();
    final next = FakeMediaStreamTrack('track-3');
    // ignore: invalid_use_of_internal_member
    track.updateMediaStreamAndTrack(
      FakeMediaStream('stream-3', [next]),
      next,
    );

    await pumpEvents();

    expect(platform.attachedIds, isEmpty);
  });

  test('dispose cancels listeners and is idempotent', () async {
    await adapter.attach(track);
    await adapter.dispose();
    await adapter.dispose();

    expect(platform.disposeCalls, 1);
    platform.attachedIds.clear();
    final next = FakeMediaStreamTrack('track-4');
    // ignore: invalid_use_of_internal_member
    track.updateMediaStreamAndTrack(
      FakeMediaStream('stream-4', [next]),
      next,
    );

    await pumpEvents();

    expect(platform.attachedIds, isEmpty);
  });
}

class FakePlatform extends MiVirtualBackgroundKitPlatform
    with MockPlatformInterfaceMixin {
  final attachedIds = <String>[];
  final qualities = <Map<String, Object?>?>[];
  final effects = <Map<String, Object?>>[];
  int detachCalls = 0;
  int disposeCalls = 0;

  @override
  Future<void> attach(String trackId, {Map<String, Object?>? quality}) async {
    attachedIds.add(trackId);
    qualities.add(quality);
  }

  @override
  Future<void> setEffect(Map<String, Object?> effect) async {
    effects.add(effect);
  }

  @override
  Future<void> detach() async {
    detachCalls++;
  }

  @override
  Future<void> dispose() async {
    disposeCalls++;
  }

  @override
  Future<bool> isSupported() async => true;
}

class FakeMediaStream extends MediaStream {
  FakeMediaStream(String id, List<MediaStreamTrack> tracks)
      : _tracks = tracks,
        super(id, 'fake');

  final List<MediaStreamTrack> _tracks;

  @override
  bool? get active => true;

  @override
  Future<void> getMediaTracks() async {}

  @override
  Future<void> addTrack(MediaStreamTrack track,
      {bool addToNative = true}) async {
    _tracks.add(track);
  }

  @override
  Future<void> removeTrack(
    MediaStreamTrack track, {
    bool removeFromNative = true,
  }) async {
    _tracks.remove(track);
  }

  @override
  List<MediaStreamTrack> getTracks() => _tracks;

  @override
  List<MediaStreamTrack> getAudioTracks() =>
      _tracks.where((t) => t.kind == 'audio').toList();

  @override
  List<MediaStreamTrack> getVideoTracks() =>
      _tracks.where((t) => t.kind == 'video').toList();
}

class FakeMediaStreamTrack extends MediaStreamTrack {
  FakeMediaStreamTrack(this.id) : super();

  @override
  final String? id;

  @override
  String? get label => id;

  @override
  String? get kind => 'video';

  bool _enabled = true;

  @override
  bool get enabled => _enabled;

  @override
  set enabled(bool value) => _enabled = value;

  @override
  bool? get muted => false;

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {}
}
