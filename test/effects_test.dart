import 'dart:typed_data';
import 'dart:ui' show Color;

import 'package:flutter_test/flutter_test.dart';
import 'package:mi_virtual_background_kit/src/effects/effects.dart';

void main() {
  group('BlurEffect', () {
    test('serializes to map', () {
      const effect = BlurEffect(radius: 12);
      expect(effect.toMap(), <String, Object?>{
        'type': 'blur',
        'radius': 12.0,
      });
    });
  });

  group('ColorEffect', () {
    test('serializes to map', () {
      const effect = ColorEffect(Color(0xFF0E1114));
      expect(effect.toMap(), <String, Object?>{
        'type': 'color',
        'color': 0xFF0E1114,
      });
    });
  });

  group('ImageEffect', () {
    test('asset serializes to map', () {
      const effect = ImageEffect.asset('assets/office.jpg');
      expect(effect.toMap(), <String, Object?>{
        'type': 'image',
        'fit': 'cover',
        'sourceType': 'asset',
        'data': 'assets/office.jpg',
      });
    });

    test('file with contain fit serializes to map', () {
      const effect =
          ImageEffect.file('/tmp/bg.png', fit: BackgroundFit.contain);
      expect(effect.toMap(), <String, Object?>{
        'type': 'image',
        'fit': 'contain',
        'sourceType': 'file',
        'data': '/tmp/bg.png',
      });
    });

    test('bytes serializes to map', () {
      final bytes = Uint8List.fromList(<int>[1, 2, 3]);
      final effect = ImageEffect.bytes(bytes);
      expect(effect.toMap(), <String, Object?>{
        'type': 'image',
        'fit': 'cover',
        'sourceType': 'bytes',
        'data': bytes,
      });
      expect(identical(effect.toMap()['data'], bytes), isTrue);
    });
  });

  group('NoEffect', () {
    test('serializes to map', () {
      const effect = NoEffect();
      expect(effect.toMap(), <String, Object?>{'type': 'none'});
    });
  });

  group('sealed exhaustiveness', () {
    test('switch covers all subtypes', () {
      const effects = <VirtualBackgroundEffect>[
        BlurEffect(radius: 1),
        ColorEffect(Color(0xFFFFFFFF)),
        ImageEffect.asset('a.png'),
        NoEffect(),
      ];
      final types = effects.map((e) {
        return switch (e) {
          BlurEffect() => 'blur',
          ColorEffect() => 'color',
          ImageEffect() => 'image',
          NoEffect() => 'none',
        };
      }).toList();
      expect(types, <String>['blur', 'color', 'image', 'none']);
    });
  });
}
