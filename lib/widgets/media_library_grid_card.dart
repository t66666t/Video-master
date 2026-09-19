import 'package:flutter/material.dart';

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
    this.elevation,
  });

  final double radius;
  final bool isSelected;
  final VoidCallback onTap;

  /// 键鼠右击：进入选择并选中/取消该项，不走左键打开或播放。
  final VoidCallback? onSecondaryTap;
  final Widget child;
  final double? elevation;

  static const Color _unselectedColor = Color(0xFF2C2C2C);
  static const WidgetStateProperty<Color?> _noOverlay =
      WidgetStatePropertyAll<Color?>(Colors.transparent);

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      elevation: elevation ?? (isSelected ? 3 : 0),
      color: isSelected
          ? Colors.blueAccent.withValues(alpha: 0.2)
          : _unselectedColor,
      surfaceTintColor: Colors.transparent,
      shadowColor: Colors.black54,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(radius),
        side: isSelected
            ? const BorderSide(color: Colors.blueAccent, width: 2)
            : BorderSide.none,
      ),
      child: InkWell(
        onTap: onTap,
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
