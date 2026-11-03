/// Lifecycle state of the background processor (FR-07).
enum ProcessorStatus {
  /// No track attached, or effect is bypass.
  idle,

  /// Native pipeline is starting up.
  initializing,

  /// Frames are being processed.
  active,

  /// Processing failed; see the error event for details.
  error,
}

/// Error raised by the kit. Subclasses map 1:1 to the error codes in FR-08.
sealed class BackgroundException implements Exception {
  /// Creates an exception with optional [message] detail.
  const BackgroundException([this.message]);

  /// Optional human-readable detail.
  final String? message;

  /// Stable machine-readable code, e.g. `invalidTrack`.
  String get code;

  @override
  String toString() => '$runtimeType($code): ${message ?? 'no message'}';
}

/// Device or OS cannot run this feature (FR-08, `unsupportedPlatform`).
final class UnsupportedPlatformException extends BackgroundException {
  const UnsupportedPlatformException([super.message]);

  @override
  String get code => 'unsupportedPlatform';
}

/// Segmentation model failed to load (FR-08, `modelLoadFailed`).
final class ModelLoadFailedException extends BackgroundException {
  const ModelLoadFailedException([super.message]);

  @override
  String get code => 'modelLoadFailed';
}

/// Track is null, disposed, or not a local video track (FR-08, `invalidTrack`).
final class InvalidTrackException extends BackgroundException {
  const InvalidTrackException([super.message]);

  @override
  String get code => 'invalidTrack';
}

/// Background image missing, empty, or undecodable (FR-08, `invalidImage`).
final class InvalidImageException extends BackgroundException {
  const InvalidImageException([super.message]);

  @override
  String get code => 'invalidImage';
}
