// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:mi_virtual_background_kit/mi_virtual_background_kit.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    messenger.setMockMethodCallHandler(
      const MethodChannel('FlutterWebRTC.Method'),
      (call) async {
        if (call.method == 'createVideoRenderer') {
          return <String, Object?>{'textureId': 1};
        }
        return null;
      },
    );
    messenger.setMockStreamHandler(
      const EventChannel('FlutterWebRTC/Texture1'),
      MockStreamHandler.inline(onListen: (_, __) {}, onCancel: (_) {}),
    );
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(
      const MethodChannel('FlutterWebRTC.Method'),
      null,
    );
  });

  testWidgets('shows error state and retry when camera start fails', (
    tester,
  ) async {
    final controller = VirtualBackgroundPreviewController(
      kit: _FakeKit(),
      openCamera: () async => throw StateError('permission denied'),
    );

    await tester.pumpWidget(
      const MaterialApp(home: SizedBox.expand()),
    );
    await tester.pumpWidget(
      MaterialApp(home: VirtualBackgroundPreview(controller: controller)),
    );
    await tester.pump();

    expect(find.textContaining('Camera preview error:'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);

    await controller.dispose();
  });

  testWidgets('passes mirror and fit to the renderer', (tester) async {
    final stream = _FakeStream('stream-1', [_FakeTrack('track-1')]);
    final controller = VirtualBackgroundPreviewController(
      kit: _FakeKit(),
      openCamera: () async => stream,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: VirtualBackgroundPreview(
          controller: controller,
          mirror: true,
          fit: BackgroundFit.contain,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));

    final view = tester.widget<RTCVideoView>(find.byType(RTCVideoView));
    expect(view.mirror, isTrue);
    expect(
      view.objectFit,
      RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await controller.dispose();
  });

  testWidgets('repeated mount/unmount does not leak the renderer', (
    tester,
  ) async {
    final stream = _FakeStream('stream-2', [_FakeTrack('track-2')]);
    final controller = VirtualBackgroundPreviewController(
      kit: _FakeKit(),
      openCamera: () async => stream,
    );

    for (var i = 0; i < 3; i++) {
      await tester.pumpWidget(
        MaterialApp(home: VirtualBackgroundPreview(controller: controller)),
      );
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(tester.takeException(), isNull);
    await controller.dispose();
  });
}

class _FakeKit extends MiVirtualBackgroundKit {
  @override
  Future<void> attach(
    MediaStreamTrack track, {
    BackgroundQuality? quality,
  }) async {}

  @override
  Future<void> setEffect(VirtualBackgroundEffect effect) async {}

  @override
  Future<void> detach() async {}

  @override
  Future<void> dispose() async {}
}

class _FakeStream extends MediaStream {
  _FakeStream(String id, List<MediaStreamTrack> tracks)
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

class _FakeTrack extends MediaStreamTrack {
  _FakeTrack(this.id) : super();

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
