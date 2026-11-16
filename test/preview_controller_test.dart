import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:mi_virtual_background_kit/mi_virtual_background_kit.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('FlutterWebRTC.Method'),
      (call) async => call.method == 'switchCamera' ? true : null,
    );
  });

  FakeStream makeStream(String id) {
    final track = FakeTrack('track-$id');
    return FakeStream('stream-$id', [track]);
  }

  test('start opens camera and attaches with the requested quality', () async {
    final stream = makeStream('1');
    final kit = FakeKit();
    final controller = VirtualBackgroundPreviewController(
      quality: BackgroundQuality.low,
      kit: kit,
      openCamera: () async => stream,
    );

    await controller.start();

    expect(controller.isStarted, isTrue);
    expect(controller.stream, same(stream));
    expect(kit.attached, ['track-1']);
    expect(kit.lastQuality, BackgroundQuality.low);
    await controller.dispose();
  });

  test('start is idempotent', () async {
    var opens = 0;
    final kit = FakeKit();
    final controller = VirtualBackgroundPreviewController(
      kit: kit,
      openCamera: () async {
        opens++;
        return makeStream('2');
      },
    );

    await controller.start();
    await controller.start();

    expect(opens, 1);
    expect(kit.attached, hasLength(1));
    await controller.dispose();
  });

  test('setEffect forwards before and after start', () async {
    final kit = FakeKit();
    final controller = VirtualBackgroundPreviewController(
      kit: kit,
      openCamera: () async => makeStream('3'),
    );

    await controller.setEffect(const NoEffect());
    await controller.start();
    await controller.setEffect(const BlurEffect(radius: 10));

    expect(kit.effects, [
      {'type': 'none'},
      {'type': 'blur', 'radius': 10.0},
    ]);
    await controller.dispose();
  });

  test('switchCamera re-attaches to re-apply the effect', () async {
    final kit = FakeKit();
    final controller = VirtualBackgroundPreviewController(
      kit: kit,
      openCamera: () async => makeStream('4'),
    );
    await controller.start();

    await controller.switchCamera();

    expect(kit.attached, ['track-4', 'track-4']);
    await controller.dispose();
  });

  test('stop detaches and stops the track, and is idempotent', () async {
    final stream = makeStream('5');
    final kit = FakeKit();
    final controller = VirtualBackgroundPreviewController(
      kit: kit,
      openCamera: () async => stream,
    );
    await controller.start();

    await controller.stop();
    await controller.stop();

    expect(kit.detachCalls, 1);
    expect((stream.getVideoTracks().first as FakeTrack).stopped, isTrue);
    expect(controller.isStarted, isFalse);
    expect(controller.stream, isNull);
    await controller.dispose();
  });

  test('releaseToCaller transfers ownership and is idempotent', () async {
    final stream = makeStream('6');
    final kit = FakeKit();
    final controller = VirtualBackgroundPreviewController(
      kit: kit,
      openCamera: () async => stream,
    );
    await controller.start();

    final first = await controller.releaseToCaller();
    final second = await controller.releaseToCaller();

    expect(second, same(first));
    expect(first.stream, same(stream));
    expect(first.track, same(stream.getVideoTracks().first));
    expect(first.kit, same(kit));
    expect(controller.stream, isNull);
    expect(kit.detachCalls, 0);

    await controller.dispose();
    expect(kit.disposeCalls, 0);
    expect(kit.detachCalls, 0);
  });

  test('dispose after normal start detaches, stops, and disposes once',
      () async {
    final stream = makeStream('7');
    final kit = FakeKit();
    final controller = VirtualBackgroundPreviewController(
      kit: kit,
      openCamera: () async => stream,
    );
    await controller.start();

    await controller.dispose();
    await controller.dispose();

    expect(kit.detachCalls, 1);
    expect(kit.disposeCalls, 1);
    expect((stream.getVideoTracks().first as FakeTrack).stopped, isTrue);
    await expectLater(controller.start(), throwsStateError);
    await expectLater(
      controller.setEffect(const NoEffect()),
      throwsStateError,
    );
  });

  test('releaseToCaller before start throws', () async {
    final controller = VirtualBackgroundPreviewController(
      kit: FakeKit(),
      openCamera: () async => makeStream('8'),
    );

    await expectLater(controller.releaseToCaller(), throwsStateError);
    await controller.dispose();
  });

  test('start with no video track throws and disposes the stream', () async {
    final stream = FakeStream('stream-9', <MediaStreamTrack>[]);
    final controller = VirtualBackgroundPreviewController(
      kit: FakeKit(),
      openCamera: () async => stream,
    );

    await expectLater(
      controller.start(),
      throwsA(isA<InvalidTrackException>()),
    );
    expect(stream.disposed, isTrue);
    await controller.dispose();
  });

  test('start propagates camera errors', () async {
    final controller = VirtualBackgroundPreviewController(
      kit: FakeKit(),
      openCamera: () async => throw StateError('permission denied'),
    );

    await expectLater(controller.start(), throwsStateError);
    expect(controller.isStarted, isFalse);
    await controller.dispose();
  });
}

class FakeKit extends MiVirtualBackgroundKit {
  final attached = <String>[];
  final effects = <Map<String, Object?>>[];
  BackgroundQuality? lastQuality;
  int detachCalls = 0;
  int disposeCalls = 0;

  @override
  Future<void> attach(
    MediaStreamTrack track, {
    BackgroundQuality? quality,
  }) async {
    attached.add(track.id ?? '');
    lastQuality = quality;
  }

  @override
  Future<void> setEffect(VirtualBackgroundEffect effect) async {
    effects.add(effect.toMap());
  }

  @override
  Future<void> detach() async {
    detachCalls++;
  }

  @override
  Future<void> dispose() async {
    disposeCalls++;
  }
}

class FakeStream extends MediaStream {
  FakeStream(String id, List<MediaStreamTrack> tracks)
      : _tracks = tracks,
        super(id, 'fake');

  final List<MediaStreamTrack> _tracks;
  bool disposed = false;

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

  @override
  Future<void> dispose() async {
    disposed = true;
  }
}

class FakeTrack extends MediaStreamTrack {
  FakeTrack(this.id) : super();

  @override
  final String? id;

  @override
  String? get label => id;

  @override
  String? get kind => 'video';

  bool _enabled = true;
  bool stopped = false;

  @override
  bool get enabled => _enabled;

  @override
  set enabled(bool value) => _enabled = value;

  @override
  bool? get muted => false;

  @override
  Future<void> stop() async {
    stopped = true;
  }

  @override
  Future<void> dispose() async {}
}
