import 'package:flutter_test/flutter_test.dart';
import 'package:mi_virtual_background_kit/mi_virtual_background_kit.dart';

void main() {
  group('PerformanceFallbackEvent', () {
    test('fromMap deserializes qualityDegraded event correctly', () {
      final map = {
        'action': 'qualityDegraded',
        'reason': 'fps_drop_12',
        'segmentationWidth': 192,
        'targetFps': 15,
      };

      final event = PerformanceFallbackEvent.fromMap(map);

      expect(event.action, FallbackAction.qualityDegraded);
      expect(event.reason, 'fps_drop_12');
      expect(event.segmentationWidth, 192);
      expect(event.targetFps, 15);
    });

    test('fromMap deserializes disabled event with defaults', () {
      final map = {
        'action': 'disabled',
        'reason': 'fps_critical_7',
      };

      final event = PerformanceFallbackEvent.fromMap(map);

      expect(event.action, FallbackAction.disabled);
      expect(event.reason, 'fps_critical_7');
      expect(event.segmentationWidth, isNull);
      expect(event.targetFps, isNull);
    });

    test('fromMap deserializes recovered event (FR-21)', () {
      final map = {
        'action': 'recovered',
        'reason': 'auto',
        'segmentationWidth': 256,
        'targetFps': 30,
      };

      final event = PerformanceFallbackEvent.fromMap(map);

      expect(event.action, FallbackAction.recovered);
      expect(event.reason, 'auto');
      expect(event.segmentationWidth, 256);
      expect(event.targetFps, 30);
    });

    test('fromMap maps unknown or missing action to disabled', () {
      expect(
        PerformanceFallbackEvent.fromMap({'reason': 'x'}).action,
        FallbackAction.disabled,
      );
      expect(
        PerformanceFallbackEvent.fromMap({
          'action': 'somethingNew',
          'reason': 'x',
        }).action,
        FallbackAction.disabled,
      );
    });

    test('toMap serializes properly', () {
      const event = PerformanceFallbackEvent(
        action: FallbackAction.qualityDegraded,
        reason: 'fps_low',
        segmentationWidth: 192,
        targetFps: 15,
      );

      final map = event.toMap();
      expect(map['action'], 'qualityDegraded');
      expect(map['reason'], 'fps_low');
      expect(map['segmentationWidth'], 192);
      expect(map['targetFps'], 15);
    });

    test('equality, hashCode, and toString work as expected', () {
      const a = PerformanceFallbackEvent(
        action: FallbackAction.disabled,
        reason: 'timeout',
      );
      const b = PerformanceFallbackEvent(
        action: FallbackAction.disabled,
        reason: 'timeout',
      );
      const c = PerformanceFallbackEvent(
        action: FallbackAction.qualityDegraded,
        reason: 'timeout',
      );

      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(a, isNot(equals(c)));
      expect(a.toString(), contains('FallbackAction.disabled'));
    });
  });
}
