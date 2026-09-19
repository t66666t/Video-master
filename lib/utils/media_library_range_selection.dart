import 'dart:async';
import 'dart:ui';

import 'package:flutter/widgets.dart';

/// Album-style library selection: a contiguous index range in reading order.
class MediaLibraryRangeSelection {
  const MediaLibraryRangeSelection._();

  /// Keeps items that were already selected, then adds every item from
  /// [startIndex] through [currentIndex] (inclusive, either direction).
  static Set<String> mergeSnapshotWithIndexRange({
    required Set<String> snapshot,
    required int startIndex,
    required int currentIndex,
    required int itemCount,
    required String? Function(int index) idAt,
  }) {
    final selected = Set<String>.from(snapshot);
    if (itemCount <= 0) return selected;
    final start = startIndex.clamp(0, itemCount - 1);
    final current = currentIndex.clamp(0, itemCount - 1);
    final from = start < current ? start : current;
    final to = start < current ? current : start;
    for (var i = from; i <= to; i++) {
      final id = idAt(i);
      if (id != null) selected.add(id);
    }
    return selected;
  }

  /// Height of the mini player overlay that sits on top of the list viewport.
  static double miniPlayerOverlayHeight({
    required bool visible,
    required double cardHeight,
    required double cardBottomInset,
  }) {
    if (!visible) return 0;
    return cardHeight + cardBottomInset;
  }

  /// Rubber-band box select is a mouse gesture on every platform, including a
  /// mouse plugged into a phone or tablet.
  static bool isMouseBoxGesture({
    required PointerDeviceKind? pointerKind,
    required int pointerCount,
  }) {
    return pointerCount == 1 && pointerKind == PointerDeviceKind.mouse;
  }
}

/// Edge-driven auto-scroll while a selection drag is held.
class MediaLibrarySelectionAutoScroll {
  const MediaLibrarySelectionAutoScroll._();

  static const double edgeExtent = 64;
  static const double maxSpeedPxPerSecond = 1400;
  static const Duration tick = Duration(milliseconds: 16);

  /// Negative velocity scrolls toward earlier items (up); positive scrolls down.
  static double velocityPxPerSecond({
    required double pointerY,
    required double viewportTop,
    required double viewportBottom,
  }) {
    if (viewportBottom <= viewportTop) return 0;
    if (pointerY <= viewportTop) return -maxSpeedPxPerSecond;
    if (pointerY >= viewportBottom) return maxSpeedPxPerSecond;
    if (pointerY < viewportTop + edgeExtent) {
      final t = (viewportTop + edgeExtent - pointerY) / edgeExtent;
      return -maxSpeedPxPerSecond * t.clamp(0.0, 1.0);
    }
    if (pointerY > viewportBottom - edgeExtent) {
      final t = (pointerY - (viewportBottom - edgeExtent)) / edgeExtent;
      return maxSpeedPxPerSecond * t.clamp(0.0, 1.0);
    }
    return 0;
  }
}

/// Owns the periodic [jumpTo] used while the pointer stays in an edge band.
class MediaLibrarySelectionAutoScroller {
  MediaLibrarySelectionAutoScroller({
    required this.scrollController,
    required this.onScrolled,
  });

  final ScrollController scrollController;
  final VoidCallback onScrolled;

  Timer? _timer;
  double _velocity = 0;

  void update({
    required double pointerY,
    required double viewportTop,
    required double viewportBottom,
  }) {
    _velocity = MediaLibrarySelectionAutoScroll.velocityPxPerSecond(
      pointerY: pointerY,
      viewportTop: viewportTop,
      viewportBottom: viewportBottom,
    );
    if (_velocity == 0) {
      stop();
      return;
    }
    _timer ??= Timer.periodic(MediaLibrarySelectionAutoScroll.tick, (_) {
      _tick();
    });
  }

  void _tick() {
    if (!scrollController.hasClients) {
      stop();
      return;
    }
    final position = scrollController.position;
    final delta =
        _velocity *
        (MediaLibrarySelectionAutoScroll.tick.inMilliseconds / 1000);
    final next = (position.pixels + delta).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    if (next == position.pixels) return;
    scrollController.jumpTo(next);
    onScrolled();
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _velocity = 0;
  }

  void dispose() => stop();
}
