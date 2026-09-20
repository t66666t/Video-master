import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Bottom-right more / locate chrome shared by grid cards and list rows.
///
/// Glyphs are laid out first (one centered icon, or two icons with equal
/// leftover space on the left, middle and right). Hit targets are applied
/// afterwards: a single square, or two equal halves of the bar.
class MediaLibraryActionDockMetrics {
  static const Color chipColor = Color(0xFF202328);

  /// Square chip as a fraction of grid card width (preview: 19%).
  static const double gridChipOfWidth = 0.19;

  /// Square chip as a fraction of list row height so a wide row stays compact.
  static const double listChipOfHeight = 0.47;

  static double gridChipSize(double cardWidth) => cardWidth * gridChipOfWidth;

  static double listChipSize(double rowHeight) => rowHeight * listChipOfHeight;

  static double dockWidth({
    required double chipSize,
    required bool showMore,
    required bool showLocate,
  }) {
    if (showMore && showLocate) return chipSize * 2;
    if (showMore || showLocate) return chipSize;
    return 0;
  }

  /// Trailing inset for bottom meta only. Titles sit above the chip and
  /// must keep full width; a column-wide title inset leaves empty space.
  static double textInset({
    required double chipSize,
    required bool showMore,
    required bool showLocate,
    double existingPadding = 0,
  }) {
    return math.max(
      0.0,
      dockWidth(
            chipSize: chipSize,
            showMore: showMore,
            showLocate: showLocate,
          ) -
          existingPadding,
    );
  }
}

/// Flush bottom-right action bar. [more] / [locate] should be hit-only children.
class MediaLibraryActionDock extends StatelessWidget {
  const MediaLibraryActionDock({
    super.key,
    required this.chipSize,
    this.more,
    this.locate,
  });

  final double chipSize;
  final Widget? more;
  final Widget? locate;

  bool get _showMore => more != null;
  bool get _showLocate => locate != null;

  @override
  Widget build(BuildContext context) {
    if (!_showMore && !_showLocate) return const SizedBox.shrink();
    final width = MediaLibraryActionDockMetrics.dockWidth(
      chipSize: chipSize,
      showMore: _showMore,
      showLocate: _showLocate,
    );
    final radius = BorderRadius.only(
      topLeft: Radius.circular(chipSize * 0.39),
    );
    return Positioned(
      right: 0,
      bottom: 0,
      child: SizedBox(
        width: width,
        height: chipSize,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: MediaLibraryActionDockMetrics.chipColor,
            borderRadius: radius,
          ),
          child: ClipRRect(
            borderRadius: radius,
            child: Stack(
              fit: StackFit.expand,
              children: [
                IgnorePointer(child: _glyphs()),
                _hits(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _glyphs() {
    final dots = _MoreDots(chipSize: chipSize);
    final folder = _FolderGlyph(chipSize: chipSize);
    if (_showMore && _showLocate) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [dots, folder],
      );
    }
    return Center(child: _showMore ? dots : folder);
  }

  Widget _hits() {
    if (_showMore && _showLocate) {
      return Row(
        children: [
          Expanded(child: more!),
          Expanded(
            child: KeyedSubtree(
              key: const ValueKey('show-in-parent-folder-button-surface'),
              child: locate!,
            ),
          ),
        ],
      );
    }
    if (_showLocate) {
      return KeyedSubtree(
        key: const ValueKey('show-in-parent-folder-button-surface'),
        child: locate!,
      );
    }
    return more!;
  }
}

class _MoreDots extends StatelessWidget {
  const _MoreDots({required this.chipSize});

  final double chipSize;

  @override
  Widget build(BuildContext context) {
    // Filled dots read heavier than a stroked folder, so the cluster is
    // slightly smaller than the icon's layout size.
    final diameter = math.max(1.8, chipSize * 0.10);
    final gap = math.max(1.0, chipSize * 0.065);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < 3; i++) ...[
          if (i > 0) SizedBox(width: gap),
          Container(
            width: diameter,
            height: diameter,
            decoration: const BoxDecoration(
              color: Color(0xEBFFFFFF),
              shape: BoxShape.circle,
            ),
          ),
        ],
      ],
    );
  }
}

class _FolderGlyph extends StatelessWidget {
  const _FolderGlyph({required this.chipSize});

  final double chipSize;

  @override
  Widget build(BuildContext context) {
    return Icon(
      Icons.folder_open_outlined,
      size: chipSize * 0.56,
      color: const Color(0xE0FFFFFF),
    );
  }
}
