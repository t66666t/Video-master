import 'package:flutter/material.dart';

import '../theme/app_tokens.dart';

/// Shared chrome for media-library grid cards.
///
/// Default [Card] + [InkWell] draws a translucent white rounded highlight.
/// After an orientation change that highlight often stays behind, which is
/// exactly the stray square on shrunken portrait thumbnails.
class MediaLibraryGridCard extends StatelessWidget {
  const MediaLibraryGridCard({
    super.key,
    required this.radius,
    required this.isSelected,
    required this.onTap,
    required this.child,
    this.onSecondaryTap,
    this.isSelectionMode = false,
    this.onSelectionTap,
    this.elevation,
  });

  final double radius;
  final bool isSelected;
  final VoidCallback onTap;

  /// 键鼠右击：进入选择并选中/取消该项，不走左键打开或播放。
  final VoidCallback? onSecondaryTap;

  /// When true, [onTap] is ignored and [onSelectionTap] toggles selection.
  final bool isSelectionMode;
  final VoidCallback? onSelectionTap;
  final Widget child;
  final double? elevation;

  static const WidgetStateProperty<Color?> _noOverlay =
      WidgetStatePropertyAll<Color?>(Colors.transparent);

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      elevation: elevation ?? 0,
      color: isSelected ? AppTokens.accentSoft : AppTokens.bgCard,
      surfaceTintColor: Colors.transparent,
      shadowColor: Colors.transparent,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(radius),
      ),
      child: InkWell(
        onTap: isSelectionMode
            ? () {
                onSelectionTap?.call();
              }
            : onTap,
        onSecondaryTap: onSecondaryTap,
        splashFactory: NoSplash.splashFactory,
        overlayColor: _noOverlay,
        splashColor: Colors.transparent,
        highlightColor: Colors.transparent,
        hoverColor: Colors.transparent,
        focusColor: Colors.transparent,
        child: child,
      ),
    );
  }
}
