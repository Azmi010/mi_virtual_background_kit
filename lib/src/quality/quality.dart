/// Presets for background processing quality.
enum BackgroundQualityPreset {
  /// Optimized for lower-end devices: lower resolution segmentation (160px),
  /// no edge feathering (0.0), and target 15 fps.
  low,

  /// Balanced setting for typical devices: 256px segmentation,
  /// standard 0.5 edge smoothing, and 30 fps.
  balanced,

  /// High quality setting for powerful devices: 512px segmentation,
  /// full 1.0 edge smoothing, and 30 fps.
  high,
}

/// Configuration parameters for virtual background processing quality (FR-11).
class BackgroundQuality {
  /// Creates a [BackgroundQuality] configuration.
  ///
  /// - [segmentationWidth]: Width in pixels for person segmentation input.
  ///   Must be positive. Default is 256.
  /// - [edgeSmoothing]: Edge feathering / anti-aliasing amount in range `[0.0, 1.0]`.
  ///   0.0 means hard edge, 1.0 means maximum soft feathering. Default is 0.5.
  /// - [targetFps]: Target frame rate for compositing.
  ///   Must be positive. Default is 30.
  /// - [maskTemporalSmoothing]: Temporal smoothing of the person mask between
  ///   segmentation runs, in range `[0.0, 1.0]`. Higher values steady the
  ///   silhouette but trail fast motion; 0.0 disables smoothing (v0.1
  ///   behavior). Default is 0.7.
  const BackgroundQuality({
    this.segmentationWidth = 256,
    this.edgeSmoothing = 0.5,
    this.targetFps = 30,
    this.maskTemporalSmoothing = 0.7,
  });

  /// Low quality preset for lower-end devices.
  static const low = BackgroundQuality(
    segmentationWidth: 160,
    edgeSmoothing: 0.0,
    targetFps: 15,
  );

  /// Balanced preset for typical mobile devices.
  static const balanced = BackgroundQuality(
    segmentationWidth: 256,
    edgeSmoothing: 0.5,
    targetFps: 30,
  );

  /// High quality preset for powerful devices.
  static const high = BackgroundQuality(
    segmentationWidth: 512,
    edgeSmoothing: 1.0,
    targetFps: 30,
  );

  /// Creates a [BackgroundQuality] configuration from a [preset].
  factory BackgroundQuality.preset(BackgroundQualityPreset preset) {
    return switch (preset) {
      BackgroundQualityPreset.low => low,
      BackgroundQualityPreset.balanced => balanced,
      BackgroundQualityPreset.high => high,
    };
  }

  /// Width in pixels for person segmentation input.
  final int segmentationWidth;

  /// Edge smoothing factor between 0.0 (sharp/hard) and 1.0 (soft/feathered).
  final double edgeSmoothing;

  /// Target frame rate in frames per second.
  final int targetFps;

  /// Temporal smoothing of the person mask between segmentation runs (FR-20).
  ///
  /// In range `[0.0, 1.0]`; 0.0 disables smoothing (identical to v0.1).
  final double maskTemporalSmoothing;

  /// Serializes to a platform channel map.
  Map<String, Object?> toMap() => <String, Object?>{
        'segmentationWidth': segmentationWidth,
        'edgeSmoothing': edgeSmoothing,
        'targetFps': targetFps,
        'maskTemporalSmoothing': maskTemporalSmoothing,
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BackgroundQuality &&
          runtimeType == other.runtimeType &&
          segmentationWidth == other.segmentationWidth &&
          edgeSmoothing == other.edgeSmoothing &&
          targetFps == other.targetFps &&
          maskTemporalSmoothing == other.maskTemporalSmoothing;

  @override
  int get hashCode => Object.hash(
        segmentationWidth,
        edgeSmoothing,
        targetFps,
        maskTemporalSmoothing,
      );

  @override
  String toString() =>
      'BackgroundQuality(segmentationWidth: $segmentationWidth, edgeSmoothing: $edgeSmoothing, targetFps: $targetFps, maskTemporalSmoothing: $maskTemporalSmoothing)';
}
