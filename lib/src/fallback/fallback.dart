/// Action taken automatically by the kit when the device struggles with
/// real-time processing performance (FR-12).
enum FallbackAction {
  /// Quality was automatically degraded (e.g. segmentation resolution reduced)
  /// to keep video frame rate acceptable.
  qualityDegraded,

  /// Virtual background effect was automatically disabled (reverted to bypass)
  /// because the device cannot sustain minimum viable frame rate.
  disabled,
}

/// Event emitted when performance drops trigger an automatic fallback (FR-12).
final class PerformanceFallbackEvent {
  const PerformanceFallbackEvent({
    required this.action,
    required this.reason,
    this.segmentationWidth,
    this.targetFps,
  });

  /// The fallback action taken by the native engine.
  final FallbackAction action;

  /// Human- or machine-readable explanation (e.g. `fps_drop_8`).
  final String reason;

  /// New segmentation resolution width if degraded, or null.
  final int? segmentationWidth;

  /// Current target fps if modified, or null.
  final int? targetFps;

  /// Deserializes a fallback event from native map.
  factory PerformanceFallbackEvent.fromMap(Map<dynamic, dynamic> map) {
    final actionStr = map['action'] as String? ?? 'disabled';
    final action = actionStr == 'qualityDegraded'
        ? FallbackAction.qualityDegraded
        : FallbackAction.disabled;
    return PerformanceFallbackEvent(
      action: action,
      reason: (map['reason'] as String?) ?? 'performance_drop',
      segmentationWidth: (map['segmentationWidth'] as num?)?.toInt(),
      targetFps: (map['targetFps'] as num?)?.toInt(),
    );
  }

  /// Serializes to map for testing or transmission.
  Map<String, dynamic> toMap() => {
        'action': action.name,
        'reason': reason,
        if (segmentationWidth != null) 'segmentationWidth': segmentationWidth,
        if (targetFps != null) 'targetFps': targetFps,
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PerformanceFallbackEvent &&
          runtimeType == other.runtimeType &&
          action == other.action &&
          reason == other.reason &&
          segmentationWidth == other.segmentationWidth &&
          targetFps == other.targetFps;

  @override
  int get hashCode => Object.hash(action, reason, segmentationWidth, targetFps);

  @override
  String toString() =>
      'PerformanceFallbackEvent(action: $action, reason: $reason, width: $segmentationWidth, targetFps: $targetFps)';
}
