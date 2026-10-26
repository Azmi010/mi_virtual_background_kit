import 'package:flutter_test/flutter_test.dart';
import 'package:mi_virtual_background_kit/src/status/status.dart';

void main() {
  group('ProcessorStatus', () {
    test('has the four FR-07 states', () {
      expect(ProcessorStatus.values, <ProcessorStatus>[
        ProcessorStatus.idle,
        ProcessorStatus.initializing,
        ProcessorStatus.active,
        ProcessorStatus.error,
      ]);
    });
  });

  group('BackgroundException codes (FR-08)', () {
    test('UnsupportedPlatformException', () {
      const e = UnsupportedPlatformException('no GPU segmentation');
      expect(e.code, 'unsupportedPlatform');
      expect(e.message, 'no GPU segmentation');
      expect(
        e.toString(),
        'UnsupportedPlatformException(unsupportedPlatform): no GPU segmentation',
      );
    });

    test('ModelLoadFailedException', () {
      const e = ModelLoadFailedException();
      expect(e.code, 'modelLoadFailed');
      expect(e.message, isNull);
      expect(e.toString(),
          'ModelLoadFailedException(modelLoadFailed): no message');
    });

    test('InvalidTrackException', () {
      const e = InvalidTrackException('track is disposed');
      expect(e.code, 'invalidTrack');
      expect(e.message, 'track is disposed');
    });

    test('InvalidImageException', () {
      const e = InvalidImageException('bytes empty');
      expect(e.code, 'invalidImage');
      expect(e.message, 'bytes empty');
    });

    test('all are BackgroundException and sealed-exhaustive', () {
      const exceptions = <BackgroundException>[
        UnsupportedPlatformException(),
        ModelLoadFailedException(),
        InvalidTrackException(),
        InvalidImageException(),
      ];
      final codes = exceptions.map((e) {
        return switch (e) {
          UnsupportedPlatformException() => 'unsupportedPlatform',
          ModelLoadFailedException() => 'modelLoadFailed',
          InvalidTrackException() => 'invalidTrack',
          InvalidImageException() => 'invalidImage',
        };
      }).toList();
      expect(
        codes,
        <String>[
          'unsupportedPlatform',
          'modelLoadFailed',
          'invalidTrack',
          'invalidImage',
        ],
      );
    });
  });
}
