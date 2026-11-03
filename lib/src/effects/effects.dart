import 'dart:typed_data';
import 'dart:ui' show Color;

/// How a background image is fitted to the frame.
enum BackgroundFit {
  /// Fill the frame, cropping the image if needed.
  cover,

  /// Fit the whole image inside the frame, letterboxing if needed.
  contain,
}

/// Base class for all virtual background effects.
///
/// Use the subclasses [BlurEffect], [ImageEffect], [ColorEffect], or
/// [NoEffect]. Instances serialize to a map for the platform channel via
/// [toMap].
sealed class VirtualBackgroundEffect {
  const VirtualBackgroundEffect();

  /// Serializes this effect to a platform-channel map.
  Map<String, Object?> toMap();
}

/// Blurs the background behind the person.
final class BlurEffect extends VirtualBackgroundEffect {
  const BlurEffect({required this.radius});

  /// Blur radius; higher is blurlier.
  final double radius;

  @override
  Map<String, Object?> toMap() => <String, Object?>{
        'type': 'blur',
        'radius': radius,
      };
}

/// Replaces the background with a solid [color].
final class ColorEffect extends VirtualBackgroundEffect {
  const ColorEffect(this.color);

  /// Fill color applied behind the person.
  final Color color;

  @override
  Map<String, Object?> toMap() => <String, Object?>{
        'type': 'color',
        'color': color.toARGB32(),
      };
}

/// Replaces the background with a still image.
///
/// Provide exactly one source: [ImageEffect.asset], [ImageEffect.file], or
/// [ImageEffect.bytes]. Bytes are passed through to native; Dart never decodes
/// or stores the image beyond what the caller supplies.
final class ImageEffect extends VirtualBackgroundEffect {
  /// Image from a Flutter asset path.
  const ImageEffect.asset(
    String assetPath, {
    this.fit = BackgroundFit.cover,
  })  : sourceType = ImageSourceType.asset,
        data = assetPath;

  /// Image from a file path on disk.
  const ImageEffect.file(
    String filePath, {
    this.fit = BackgroundFit.cover,
  })  : sourceType = ImageSourceType.file,
        data = filePath;

  /// Image from raw encoded bytes (e.g. downloaded by the app).
  ImageEffect.bytes(
    Uint8List bytes, {
    this.fit = BackgroundFit.cover,
  })  : sourceType = ImageSourceType.bytes,
        data = bytes;

  /// Whether [data] holds an asset path, file path, or raw bytes.
  final ImageSourceType sourceType;

  /// Asset path, file path, or raw bytes depending on [sourceType].
  final Object data;

  /// How the image is fitted to the frame.
  final BackgroundFit fit;

  @override
  Map<String, Object?> toMap() => <String, Object?>{
        'type': 'image',
        'fit': fit.name,
        'sourceType': sourceType.name,
        'data': data,
      };
}

/// Source kind for [ImageEffect].
enum ImageSourceType {
  /// Flutter asset path (`assets/...`).
  asset,

  /// Absolute file path on disk.
  file,

  /// Raw encoded image bytes (e.g. downloaded by the app).
  bytes,
}

/// Disables background processing entirely (bypass).
final class NoEffect extends VirtualBackgroundEffect {
  const NoEffect();

  @override
  Map<String, Object?> toMap() => <String, Object?>{'type': 'none'};
}
