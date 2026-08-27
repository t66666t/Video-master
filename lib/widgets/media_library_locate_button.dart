import 'dart:math' as math;

import 'package:flutter/material.dart';

/// A quiet, independently tappable "show in parent folder" affordance.
///
/// The visible control scales with its card. The transparent hit target may be
/// slightly larger so dense grids remain usable without making the icon loud.
class MediaLibraryLocateButton extends StatelessWidget {
  const MediaLibraryLocateButton({
    super.key,
    required this.cardWidth,
    required this.onPressed,
    this.width,
    this.height,
    this.iconSize,
  });

  final double cardWidth;
  final VoidCallback onPressed;
  final double? width;
  final double? height;
  final double? iconSize;

  @override
  Widget build(BuildContext context) {
    final buttonWidth = width ?? cardWidth * 0.23;
    final buttonHeight = height ?? cardWidth * 0.19;
    final resolvedIconSize = iconSize ?? cardWidth * 0.072;
    final radius = math.min(buttonWidth, buttonHeight) * 0.42;
    final borderRadius = BorderRadius.only(topLeft: Radius.circular(radius));

    return Tooltip(
      message: '显示所在目录',
      child: Semantics(
        button: true,
        label: '显示所在目录',
        child: SizedBox(
          key: const ValueKey('show-in-parent-folder-button-surface'),
          width: buttonWidth,
          height: buttonHeight,
          child: Material(
            color: Colors.transparent,
            child: Ink(
              decoration: BoxDecoration(
                color: const Color(0xFF202328).withValues(alpha: 0.96),
                borderRadius: borderRadius,
                border: Border(
                  top: BorderSide(
                    color: Colors.white.withValues(alpha: 0.10),
                    width: math.max(0.7, cardWidth * 0.004),
                  ),
                  left: BorderSide(
                    color: Colors.white.withValues(alpha: 0.10),
                    width: math.max(0.7, cardWidth * 0.004),
                  ),
                ),
              ),
              child: InkWell(
                key: const ValueKey('show-in-parent-folder-button'),
                onTap: onPressed,
                borderRadius: borderRadius,
                hoverColor: Colors.white.withValues(alpha: 0.07),
                splashColor: Colors.blueAccent.withValues(alpha: 0.14),
                child: Center(
                  child: Icon(
                    Icons.folder_open_rounded,
                    size: resolvedIconSize,
                    color: Colors.white.withValues(alpha: 0.82),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
