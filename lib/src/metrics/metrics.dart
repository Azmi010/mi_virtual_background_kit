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
  /// - [processorLatencyMs]: time from frame arrival at the native processor
  ///   to the composited frame returned to WebRTC; null until the first
  ///   composited frame. Excludes camera sensor and screen display time.
  const BackgroundMetrics({
    required this.outputFps,
    this.segmentationLatencyMs,
    this.maskAgeMs,
    this.processorLatencyMs,
  });

  /// Output frame rate over the last reporting window (about 1 s).
  final double outputFps;

  /// Last segmentation inference duration in milliseconds, if known.
  final double? segmentationLatencyMs;

  /// Age of the composited person mask in milliseconds, if known.
  final double? maskAgeMs;

  /// Frame arrival to composited output inside the native processor.
  ///
  /// Excludes camera sensor readout and screen display time.
  final double? processorLatencyMs;

  /// Deserializes a metrics sample from a native map.
  factory BackgroundMetrics.fromMap(Map<dynamic, dynamic> map) {
    return BackgroundMetrics(
      outputFps: (map['outputFps'] as num?)?.toDouble() ?? 0.0,
      segmentationLatencyMs: (map['segmentationLatencyMs'] as num?)?.toDouble(),
      maskAgeMs: (map['maskAgeMs'] as num?)?.toDouble(),
      processorLatencyMs: (map['processorLatencyMs'] as num?)?.toDouble(),
    );
  }

  /// Serializes to a map for testing or transmission.
  Map<String, Object?> toMap() => <String, Object?>{
        'outputFps': outputFps,
        if (segmentationLatencyMs != null)
          'segmentationLatencyMs': segmentationLatencyMs,
        if (maskAgeMs != null) 'maskAgeMs': maskAgeMs,
        if (processorLatencyMs != null)
          'processorLatencyMs': processorLatencyMs,
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BackgroundMetrics &&
          runtimeType == other.runtimeType &&
          outputFps == other.outputFps &&
          segmentationLatencyMs == other.segmentationLatencyMs &&
          maskAgeMs == other.maskAgeMs &&
          processorLatencyMs == other.processorLatencyMs;

  @override
  int get hashCode => Object.hash(
        outputFps,
        segmentationLatencyMs,
        maskAgeMs,
        processorLatencyMs,
      );

  @override
  String toString() =>
      'BackgroundMetrics(fps: $outputFps, seg: $segmentationLatencyMs ms, '
      'maskAge: $maskAgeMs ms, processor: $processorLatencyMs ms)';
}
