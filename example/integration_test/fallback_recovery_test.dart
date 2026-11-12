import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mi_virtual_background_kit/mi_virtual_background_kit.dart';
// ignore: implementation_imports
import 'package:mi_virtual_background_kit/src/platform/mi_virtual_background_kit_method_channel.dart';

/// T14.4 device test: fallback disable -> auto/manual recovery (FR-21).
///
/// Run on a device (camera required):
///
/// ```sh
/// cd example
/// flutter test integration_test/fallback_recovery_test.dart -d DEVICE_ID
/// ```
///
/// Or via `tool/fallback_recovery_test.sh LABEL DEVICE_ID`, which stores
/// the transcript (Dart markers `T144|`) under doc/fallback-raw/.
///
/// What it proves on real hardware:
/// 1. Injected critical fps disables the effect (stage-2) after stage-1 degrade.
/// 2. With `autoRecovery: true`, real healthy fps restores effect + quality
///    and emits `recovered`, status initializing -> active.
/// 3. A second failure right after an auto resume does NOT auto-recover
///    again (one-shot latch = no oscillation).
/// 4. `resumeEffect()` re-enables manually and reports `recovered(manual)`.
/// 5. With `autoRecovery` off (default), nothing recovers automatically.
///
/// Watch the preview while the test runs: the blur must visibly disappear
/// and come back at each transition.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late MiVirtualBackgroundKit kit;
  late MethodChannelMiVirtualBackgroundKit hooks;
  late MediaStream stream;
  late MediaStreamTrack track;
  late RTCVideoRenderer renderer;

  setUp(() async {
    kit = MiVirtualBackgroundKit();
    hooks = MethodChannelMiVirtualBackgroundKit();
    stream = await navigator.mediaDevices.getUserMedia(<String, Object>{
      'audio': false,
      'video': <String, Object>{
        'facingMode': 'user',
        'width': 640,
        'height': 480,
        'frameRate': 30,
      },
    });
    track = stream.getVideoTracks().first;
    // A local track with no consumer never reaches the frame processor:
    // flutter_webrtc forwards captured frames only while the track has a
    // sink, so the test must bind a renderer exactly like a real app does
    // (preview or publish). Verified on A1: without this, zero frames hit
    // the processor and FR-21 recovery never fires.
    renderer = RTCVideoRenderer();
    await renderer.initialize();
    renderer.srcObject = stream;
  });

  tearDown(() async {
    await kit.dispose();
    renderer.srcObject = null;
    await renderer.dispose();
    for (final t in stream.getTracks()) {
      t.stop();
    }
    await stream.dispose();
  });

  /// Polls [condition] every 200 ms until [timeout], then fails with [label]
  /// and everything observed so far.
  Future<void> waitUntil(
    bool Function() condition,
    Duration timeout,
    String label,
    List<String> transcript,
  ) async {
    final deadline = DateTime.now().add(timeout);
    while (!condition()) {
      if (DateTime.now().isAfter(deadline)) {
        fail(
          'timeout waiting for: $label\n'
          'observed T144| events:\n${transcript.join('\n')}',
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  }

  /// Injects critical fps repeatedly until [disabledTarget] `disabled` events
  /// arrived. A real healthy fps window can reset the low-fps counter between
  /// two injected windows, so a single pair of injections may not suffice.
  Future<void> forceDisable(
    MethodChannelMiVirtualBackgroundKit hooks,
    List<PerformanceFallbackEvent> events,
    int disabledTarget,
  ) async {
    int disabled() =>
        events.where((e) => e.action == FallbackAction.disabled).length;
    for (var i = 0; i < 12; i++) {
      if (disabled() >= disabledTarget) return;
      await hooks.testSimulateFps(8);
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  testWidgets(
    'stage-2 disable -> auto recovery -> latch -> manual resume (FR-21)',
    (tester) async {
      final transcript = <String>[];
      final events = <PerformanceFallbackEvent>[];
      final statuses = <ProcessorStatus>[];
      final sw = Stopwatch()..start();

      void log(String line) {
        debugPrint(line);
        transcript.add(line);
      }

      final fallbackSub = kit.fallbackStream.listen((e) {
        events.add(e);
        log(
          'T144| +${sw.elapsedMilliseconds}ms fallback '
          '${e.action.name} reason=${e.reason} '
          'width=${e.segmentationWidth} fps=${e.targetFps}',
        );
      });
      final statusSub = kit.statusStream.listen((s) {
        statuses.add(s);
        log('T144| +${sw.elapsedMilliseconds}ms status $s');
      });
      addTearDown(fallbackSub.cancel);
      addTearDown(statusSub.cancel);

      int countOf(FallbackAction action) =>
          events.where((e) => e.action == action).length;

      // Setup: blur active, auto-recovery on.
      await kit.attach(
        track,
        quality: const BackgroundQuality(autoRecovery: true),
      );
      await kit.setEffect(const BlurEffect(radius: 12));
      await waitUntil(
        () => statuses.contains(ProcessorStatus.active),
        const Duration(seconds: 10),
        'initial active status',
        transcript,
      );

      // Phase 1: force stage-1 degrade then stage-2 disable.
      log('T144| phase1 force disable');
      await forceDisable(hooks, events, 1);
      await waitUntil(
        () => countOf(FallbackAction.disabled) >= 1,
        const Duration(seconds: 10),
        'disabled event after injected critical fps',
        transcript,
      );
      expect(
        statuses,
        contains(ProcessorStatus.idle),
        reason: 'stage-2 disable must move status to idle',
      );

      // Phase 2: real camera fps is healthy -> auto recovery kicks in.
      log('T144| phase2 wait auto recovery');
      await waitUntil(
        () => countOf(FallbackAction.recovered) >= 1,
        const Duration(seconds: 20),
        'auto recovered event (autoRecovery: true)',
        transcript,
      );
      expect(events.last.action, FallbackAction.recovered);
      expect(
        events.map((e) => e.reason),
        contains('auto'),
        reason: 'first recovery must be the automatic one',
      );
      await waitUntil(
        () =>
            statuses.lastIndexOf(ProcessorStatus.active) >
            statuses.lastIndexOf(ProcessorStatus.idle),
        const Duration(seconds: 15),
        'status initializing -> active after auto resume',
        transcript,
      );

      // Phase 3: fail again right after the auto resume -> latch holds.
      log('T144| phase3 second failure must NOT auto-recover');
      await forceDisable(hooks, events, 2);
      await waitUntil(
        () => countOf(FallbackAction.disabled) >= 2,
        const Duration(seconds: 10),
        'second disabled event',
        transcript,
      );
      await Future<void>.delayed(const Duration(seconds: 8));
      expect(
        countOf(FallbackAction.recovered),
        1,
        reason:
            'latch must block a second auto recovery (oscillation check); '
            'bypass fps is healthy, only the latch can explain zero events',
      );
      expect(
        statuses.lastIndexOf(ProcessorStatus.idle),
        greaterThan(statuses.lastIndexOf(ProcessorStatus.active)),
        reason: 'must still be in the disabled (idle) state',
      );

      // Phase 4: manual resume re-enables and reports.
      log('T144| phase4 manual resumeEffect');
      await kit.resumeEffect();
      await waitUntil(
        () => events.any(
          (e) => e.action == FallbackAction.recovered && e.reason == 'manual',
        ),
        const Duration(seconds: 10),
        'recovered(manual) event from resumeEffect',
        transcript,
      );
      await waitUntil(
        () =>
            statuses.lastIndexOf(ProcessorStatus.active) >
            statuses.lastIndexOf(ProcessorStatus.idle),
        const Duration(seconds: 15),
        'status active after manual resume',
        transcript,
      );

      // Phase 5: quiet period — armed again but fps healthy: no flapping.
      log('T144| phase5 stability window');
      final eventsBefore = events.length;
      final statusesBefore = statuses.length;
      await Future<void>.delayed(const Duration(seconds: 6));
      expect(
        events.length,
        eventsBefore,
        reason: 'no fallback events while fps is stable (no oscillation)',
      );
      expect(statuses.length, statusesBefore);
      expect(countOf(FallbackAction.recovered), 2);

      // Give the operator a moment to see the restored blur.
      await Future<void>.delayed(const Duration(seconds: 2));
      await kit.detach();
      log('T144| ALL DONE');
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  testWidgets('stage-1 quality restored after stable healthy fps', (
    tester,
  ) async {
    final transcript = <String>[];
    final events = <PerformanceFallbackEvent>[];
    final sw = Stopwatch()..start();

    final sub = kit.fallbackStream.listen((e) {
      events.add(e);
      final line =
          'T144| +${sw.elapsedMilliseconds}ms fallback ${e.action.name} '
          'reason=${e.reason} width=${e.segmentationWidth}';
      debugPrint(line);
      transcript.add(line);
    });
    addTearDown(sub.cancel);

    await kit.attach(
      track,
      quality: const BackgroundQuality(autoRecovery: true),
    );
    await kit.setEffect(const BlurEffect(radius: 12));
    await Future<void>.delayed(const Duration(seconds: 1));

    // Single critical window degrades the quality (256 -> 192).
    await hooks.testSimulateFps(8);
    await waitUntil(
      () => events.any((e) => e.action == FallbackAction.qualityDegraded),
      const Duration(seconds: 10),
      'qualityDegraded event after one injected low-fps window',
      transcript,
    );

    // Real healthy fps restores the configured quality (hysteresis >= 20).
    await waitUntil(
      () => events.any(
        (e) =>
            e.action == FallbackAction.recovered &&
            e.reason == 'auto_quality' &&
            e.segmentationWidth == 256,
      ),
      const Duration(seconds: 20),
      'auto_quality recovered event restoring width 256',
      transcript,
    );

    expect(
      events.map((e) => e.action),
      isNot(contains(FallbackAction.disabled)),
      reason: 'quality restore alone must never disable the effect',
    );

    await kit.detach();
  }, timeout: const Timeout(Duration(minutes: 2)));

  testWidgets('autoRecovery off: stays disabled until resumeEffect', (
    tester,
  ) async {
    final transcript = <String>[];
    final events = <PerformanceFallbackEvent>[];
    final statuses = <ProcessorStatus>[];
    final sw = Stopwatch()..start();

    final fallbackSub = kit.fallbackStream.listen((e) {
      events.add(e);
      final line =
          'T144| +${sw.elapsedMilliseconds}ms fallback ${e.action.name} '
          'reason=${e.reason}';
      debugPrint(line);
      transcript.add(line);
    });
    final statusSub = kit.statusStream.listen(statuses.add);
    addTearDown(fallbackSub.cancel);
    addTearDown(statusSub.cancel);

    // Default quality: autoRecovery false.
    await kit.attach(track);
    await kit.setEffect(const BlurEffect(radius: 12));
    await Future<void>.delayed(const Duration(seconds: 1));

    await forceDisable(hooks, events, 1);
    await waitUntil(
      () => events.any((e) => e.action == FallbackAction.disabled),
      const Duration(seconds: 10),
      'disabled event with autoRecovery off',
      transcript,
    );

    // Recovery is off by default: healthy fps must NOT bring the effect back.
    await Future<void>.delayed(const Duration(seconds: 8));
    expect(
      events.map((e) => e.action),
      isNot(contains(FallbackAction.recovered)),
      reason: 'autoRecovery defaults to false: no automatic recovery',
    );

    // Manual path still works.
    await kit.resumeEffect();
    await waitUntil(
      () => events.any(
        (e) => e.action == FallbackAction.recovered && e.reason == 'manual',
      ),
      const Duration(seconds: 10),
      'recovered(manual) event with autoRecovery off',
      transcript,
    );
    expect(
      statuses.lastIndexOf(ProcessorStatus.active),
      greaterThan(statuses.lastIndexOf(ProcessorStatus.idle)),
    );

    await kit.detach();
  }, timeout: const Timeout(Duration(minutes: 2)));
}
