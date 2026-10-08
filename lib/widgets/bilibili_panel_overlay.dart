import 'package:flutter/material.dart';

/// The landscape Bilibili panel on a phone: it slides in over the video from
/// the side the page keeps its panels on (the right, the left in left-handed
/// mode), with a dimmed video behind it; a tap on the video closes it.
class BilibiliPanelOverlay extends StatelessWidget {
  const BilibiliPanelOverlay({
    super.key,
    required this.panel,
    required this.fromLeft,
    required this.width,
    required this.onDismiss,
    this.padding = EdgeInsets.zero,
  });

  /// The panel, or null while it is closed.
  final Widget? panel;
  final bool fromLeft;
  final double width;
  final VoidCallback onDismiss;

  /// Kept free inside the panel (notch, gesture areas).
  final EdgeInsets padding;

  static const Duration duration = Duration(milliseconds: 250);

  @override
  Widget build(BuildContext context) {
    final panel = this.panel;
    final open = panel != null;
    return Stack(
      children: [
        Positioned.fill(
          child: IgnorePointer(
            ignoring: !open,
            child: GestureDetector(
              key: const ValueKey('bilibili-panel-overlay-scrim'),
              behavior: HitTestBehavior.opaque,
              onTap: onDismiss,
              child: AnimatedOpacity(
                opacity: open ? 1 : 0,
                duration: duration,
                child: const ColoredBox(color: Color(0x66000000)),
              ),
            ),
          ),
        ),
        Positioned(
          top: 0,
          bottom: 0,
          left: fromLeft ? 0 : null,
          right: fromLeft ? null : 0,
          width: width,
          child: AnimatedSwitcher(
            duration: duration,
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            layoutBuilder: (current, previous) =>
                Stack(fit: StackFit.expand, children: [...previous, ?current]),
            transitionBuilder: (child, animation) => SlideTransition(
              position: Tween<Offset>(
                begin: Offset(fromLeft ? -1 : 1, 0),
                end: Offset.zero,
              ).animate(animation),
              child: child,
            ),
            child: open
                ? Material(
                    key: const ValueKey('bilibili-panel-overlay'),
                    elevation: 8,
                    color: Colors.transparent,
                    child: Padding(padding: padding, child: panel),
                  )
                : const SizedBox.shrink(key: ValueKey('closed')),
          ),
        ),
      ],
    );
  }
}
