/// Local processing metrics reported by the native engine (FR-23).
///
/// Emitted about once per second while an effect is active. All values are
/// measured on-device; nothing is sent off the device.
final class BackgroundMetrics {
  /// Creates a metrics sample.
  ///
  /// - [outputFps]: output frame rate over the last reporting window.
  /// - [segmentationLatencyMs]: last person-segmentation inference time in
  ///   milliseconds; null until the first inference completes.
  /// - [maskAgeMs]: age of the person mask currently composited, in
  ///   milliseconds; null until the first mask is uploaded.
  const BackgroundMetrics({
    required this.outputFps,
    this.segmentationLatencyMs,
    this.maskAgeMs,
  });

  /// Output frame rate over the last reporting window (about 1 s).
  final double outputFps;

  /// Last segmentation inference duration in milliseconds, if known.
  final double? segmentationLatencyMs;

  /// Age of the composited person mask in milliseconds, if known.
  final double? maskAgeMs;

  /// Deserializes a metrics sample from a native map.
  factory BackgroundMetrics.fromMap(Map<dynamic, dynamic> map) {
    return BackgroundMetrics(
      outputFps: (map['outputFps'] as num?)?.toDouble() ?? 0.0,
      segmentationLatencyMs: (map['segmentationLatencyMs'] as num?)?.toDouble(),
      maskAgeMs: (map['maskAgeMs'] as num?)?.toDouble(),
    );
  }

  /// Serializes to a map for testing or transmission.
  Map<String, Object?> toMap() => <String, Object?>{
        'outputFps': outputFps,
        if (segmentationLatencyMs != null)
          'segmentationLatencyMs': segmentationLatencyMs,
        if (maskAgeMs != null) 'maskAgeMs': maskAgeMs,
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BackgroundMetrics &&
          runtimeType == other.runtimeType &&
          outputFps == other.outputFps &&
          segmentationLatencyMs == other.segmentationLatencyMs &&
          maskAgeMs == other.maskAgeMs;

  @override
  int get hashCode => Object.hash(outputFps, segmentationLatencyMs, maskAgeMs);

  @override
  String toString() =>
      'BackgroundMetrics(fps: $outputFps, seg: $segmentationLatencyMs ms, '
      'maskAge: $maskAgeMs ms)';
}
