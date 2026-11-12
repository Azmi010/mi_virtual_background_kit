import 'package:flutter_test/flutter_test.dart';
import 'package:mi_virtual_background_kit/mi_virtual_background_kit.dart';

void main() {
  group('BackgroundQuality', () {
    test('default values match PRD specifications', () {
      const q = BackgroundQuality();
      expect(q.segmentationWidth, 256);
      expect(q.edgeSmoothing, 0.5);
      expect(q.targetFps, 30);
      expect(q.maskTemporalSmoothing, 0.7);
    });

    test('preset low initializes expected values', () {
      final q = BackgroundQuality.preset(BackgroundQualityPreset.low);
      expect(q, equals(BackgroundQuality.low));
      expect(q.segmentationWidth, 160);
      expect(q.edgeSmoothing, 0.0);
      expect(q.targetFps, 15);
    });

    test('preset balanced initializes expected values', () {
      final q = BackgroundQuality.preset(BackgroundQualityPreset.balanced);
      expect(q, equals(BackgroundQuality.balanced));
      expect(q.segmentationWidth, 256);
      expect(q.edgeSmoothing, 0.5);
      expect(q.targetFps, 30);
    });

    test('preset high initializes expected values', () {
      final q = BackgroundQuality.preset(BackgroundQualityPreset.high);
      expect(q, equals(BackgroundQuality.high));
      expect(q.segmentationWidth, 512);
      expect(q.edgeSmoothing, 1.0);
      expect(q.targetFps, 30);
    });

    test('toMap serializes properly for platform channel', () {
      const q = BackgroundQuality(
        segmentationWidth: 320,
        edgeSmoothing: 0.75,
        targetFps: 24,
        maskTemporalSmoothing: 0.4,
      );
      final map = q.toMap();
      expect(map['segmentationWidth'], 320);
      expect(map['edgeSmoothing'], 0.75);
      expect(map['targetFps'], 24);
      expect(map['maskTemporalSmoothing'], 0.4);
    });

    test('equality and hashCode work as value object', () {
      const q1 = BackgroundQuality(
        segmentationWidth: 256,
        edgeSmoothing: 0.5,
        targetFps: 30,
      );
      final q2 = BackgroundQuality.preset(BackgroundQualityPreset.balanced);
      final q3 = BackgroundQuality.preset(BackgroundQualityPreset.low);
      const q4 = BackgroundQuality(maskTemporalSmoothing: 0.0);

      expect(q1, equals(q2));
      expect(q1 == q1, isTrue);
      expect(q1 == Object(), isFalse);
      expect(q1.hashCode, equals(q2.hashCode));
      expect(q1, isNot(equals(q3)));
      expect(q1, isNot(equals(q4)));
      expect(q4.hashCode, isNot(equals(q1.hashCode)));
    });

    test('toString includes all properties', () {
      const q = BackgroundQuality(
        segmentationWidth: 200,
        edgeSmoothing: 0.3,
        targetFps: 20,
        maskTemporalSmoothing: 0.6,
      );
      expect(
        q.toString(),
        'BackgroundQuality(segmentationWidth: 200, edgeSmoothing: 0.3, '
        'targetFps: 20, maskTemporalSmoothing: 0.6)',
      );
    });

    test('zero maskTemporalSmoothing disables smoothing (v0.1 behavior)', () {
      const q = BackgroundQuality(maskTemporalSmoothing: 0.0);
      expect(q.maskTemporalSmoothing, 0.0);
      expect(q.toMap()['maskTemporalSmoothing'], 0.0);
    });
  });
}
