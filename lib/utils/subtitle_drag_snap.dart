import 'package:flutter/material.dart';

const double kSubtitleDragSnapGuideThreshold = 0.05;
const double kSubtitleDragSnapCaptureThreshold = 0.009;
const double kSubtitleDragSnapReleaseThreshold = 0.024;

class SubtitleDragSnapResult {
  final Alignment alignment;
  final bool snappedX;
  final bool snappedY;
  final bool guideX;
  final bool guideY;

  const SubtitleDragSnapResult({
    required this.alignment,
    required this.snappedX,
    required this.snappedY,
    required this.guideX,
    required this.guideY,
  });
}

class _AxisSnapResult {
  final double position;
  final bool snapped;
  final bool guided;

  const _AxisSnapResult({
    required this.position,
    required this.snapped,
    required this.guided,
  });
}

SubtitleDragSnapResult resolveSubtitleDragSnap({
  required Alignment currentAlignment,
  required Offset dragDelta,
  required Size dragBounds,
  required bool wasSnappedX,
  required bool wasSnappedY,
  double guideThreshold = kSubtitleDragSnapGuideThreshold,
  double captureThreshold = kSubtitleDragSnapCaptureThreshold,
  double releaseThreshold = kSubtitleDragSnapReleaseThreshold,
}) {
  final double normalizedDx = dragBounds.width <= 0
      ? 0.0
      : dragDelta.dx / (dragBounds.width / 2);
  final double normalizedDy = dragBounds.height <= 0
      ? 0.0
      : dragDelta.dy / (dragBounds.height / 2);

  final _AxisSnapResult snappedX = _resolveAxisSnap(
    rawValue: currentAlignment.x + normalizedDx,
    wasSnapped: wasSnappedX,
    guideThreshold: guideThreshold,
    captureThreshold: captureThreshold,
    releaseThreshold: releaseThreshold,
  );
  final _AxisSnapResult snappedY = _resolveAxisSnap(
    rawValue: currentAlignment.y + normalizedDy,
    wasSnapped: wasSnappedY,
    guideThreshold: guideThreshold,
    captureThreshold: captureThreshold,
    releaseThreshold: releaseThreshold,
  );

  return SubtitleDragSnapResult(
    alignment: Alignment(snappedX.position, snappedY.position),
    snappedX: snappedX.snapped,
    snappedY: snappedY.snapped,
    guideX: snappedX.guided,
    guideY: snappedY.guided,
  );
}

_AxisSnapResult _resolveAxisSnap({
  required double rawValue,
  required bool wasSnapped,
  required double guideThreshold,
  required double captureThreshold,
  required double releaseThreshold,
}) {
  final double clamped = rawValue.clamp(-1.0, 1.0).toDouble();
  final double distanceToCenter = clamped.abs();
  final bool shouldSnap = wasSnapped
      ? distanceToCenter <= releaseThreshold
      : distanceToCenter <= captureThreshold;

  if (shouldSnap) {
    return const _AxisSnapResult(position: 0.0, snapped: true, guided: true);
  }

  return _AxisSnapResult(
    position: clamped,
    snapped: false,
    guided: distanceToCenter <= guideThreshold,
  );
}
