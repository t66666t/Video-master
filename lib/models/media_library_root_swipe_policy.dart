import 'package:flutter/gestures.dart';

import 'media_library_root_entry.dart';
import 'media_library_root_entry_order.dart';

/// Strict adjacent-tab swipe for 继续学习 / 最近添加 / 文件夹.
///
/// Mouse and trackpad are never eligible: desktop box-select, file drops,
/// and wheel/trackpad pans would mis-fire. System back lives on the screen
/// edges, so those strips are also ignored. The recognizer itself is a
/// horizontal drag so a vertical list scroll keeps the arena.
class MediaLibraryRootSwipePolicy {
  const MediaLibraryRootSwipePolicy._();

  /// Logical px kept for Android/iOS edge back.
  static const double systemEdgeGuard = 32;

  /// Fraction of width that commits without a flick.
  static const double commitFraction = 0.36;

  /// px/s in the swipe direction that commits a shorter drag.
  static const double commitVelocity = 950;

  static bool isEligiblePointer(PointerDeviceKind kind) {
    return kind == PointerDeviceKind.touch || kind == PointerDeviceKind.stylus;
  }

  static bool isAwayFromSystemEdges({
    required double localX,
    required double width,
    double guard = systemEdgeGuard,
  }) {
    if (width <= guard * 2) return false;
    return localX >= guard && localX <= width - guard;
  }

  /// Finger moving left (negative [dx]) reveals the next chip to the right.
  static MediaLibraryRootEntry? neighbor({
    required MediaLibraryRootEntry current,
    required double dx,
    List<MediaLibraryRootEntry> order = MediaLibraryRootEntryOrder.defaults,
  }) {
    if (dx == 0) return null;
    final index = order.indexOf(current);
    if (index < 0) return null;
    final nextIndex = dx < 0 ? index + 1 : index - 1;
    if (nextIndex < 0 || nextIndex >= order.length) return null;
    return order[nextIndex];
  }

  static bool shouldCommit({
    required double dragDx,
    required double width,
    required double velocityDx,
  }) {
    if (width <= 0) return false;
    final towardNext = dragDx < 0;
    final distance = dragDx.abs();
    final flick = towardNext
        ? velocityDx < -commitVelocity
        : velocityDx > commitVelocity;
    if (flick && distance > 24) return true;
    return distance >= width * commitFraction;
  }

  /// Page to show after the finger lifts. Null stays on [current].
  ///
  /// [shouldCommit] only accepts a flick that points the same way as
  /// [dragDx]. Past [commitFraction] that locks the first direction, so a
  /// halfway drag that reverses still lands on the page being left. A flick
  /// against the current offset picks the other neighbor instead.
  static MediaLibraryRootEntry? settleTarget({
    required MediaLibraryRootEntry current,
    required double dragDx,
    required double width,
    required double velocityDx,
    List<MediaLibraryRootEntry> order = MediaLibraryRootEntryOrder.defaults,
  }) {
    if (width <= 0) return null;
    if (_isOpposingFlick(dragDx: dragDx, velocityDx: velocityDx)) {
      final direction = velocityDx > 0 ? 1.0 : -1.0;
      return neighbor(current: current, dx: direction, order: order);
    }
    if (!shouldCommit(
      dragDx: dragDx,
      width: width,
      velocityDx: velocityDx,
    )) {
      return null;
    }
    return neighbor(current: current, dx: dragDx, order: order);
  }

  static bool _isOpposingFlick({
    required double dragDx,
    required double velocityDx,
  }) {
    if (velocityDx > commitVelocity) return dragDx < 0;
    if (velocityDx < -commitVelocity) return dragDx > 0;
    return false;
  }

  /// Resist sliding off the first/last tab.
  static double clampDrag({
    required double dx,
    required double width,
    required bool hasNeighbor,
  }) {
    if (width <= 0) return 0;
    if (!hasNeighbor) return dx.clamp(-width * 0.12, width * 0.12);
    return dx.clamp(-width, width);
  }

  /// Chip-row position in the current display order.
  static double highlightIndex({
    required MediaLibraryRootEntry current,
    required double dragDx,
    required double width,
    List<MediaLibraryRootEntry> order = MediaLibraryRootEntryOrder.defaults,
  }) {
    final index = order.indexOf(current).toDouble();
    if (index < 0) return 0;
    final last = (order.length - 1).toDouble().clamp(0.0, double.infinity);
    if (width <= 0) return index;
    return (index - dragDx / width).clamp(0.0, last);
  }

  /// How strongly chip [entryIndex] should look selected.
  static double chipWeight({
    required int entryIndex,
    required double highlightIndex,
  }) {
    return (1.0 - (highlightIndex - entryIndex).abs()).clamp(0.0, 1.0);
  }
}
