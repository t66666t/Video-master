import 'package:flutter/material.dart';

/// The buttons on the right of the landscape player's top bar, in their
/// on-screen order.
enum PlayerTopAction {
  settings,
  subtitleLibrary,
  subtitleEditor,
  videoCompose,
  ocrSubtitle,
  bilibiliPanel,
  subtitleStyle,
  moveSubtitles,
  fullScreen,
  subtitleSidebar,
  aspectRatio,
}

/// Which buttons move into「更多」first when the bar is too narrow for the
/// title and all of them: rarely used tools first, the playback, subtitle
/// and Bilibili buttons last. The one place this order is written down.
const List<PlayerTopAction> kPlayerTopActionCollapseOrder = <PlayerTopAction>[
  PlayerTopAction.videoCompose,
  PlayerTopAction.ocrSubtitle,
  PlayerTopAction.subtitleEditor,
  PlayerTopAction.moveSubtitles,
  PlayerTopAction.subtitleStyle,
  PlayerTopAction.aspectRatio,
  PlayerTopAction.settings,
  PlayerTopAction.subtitleLibrary,
  PlayerTopAction.bilibiliPanel,
  PlayerTopAction.subtitleSidebar,
  PlayerTopAction.fullScreen,
];

/// The title keeps at least this width; buttons move into「更多」instead.
const double kPlayerTopTitleMinWidth = 96;

/// One button of the top bar and how it reads in「更多」.
@immutable
class PlayerTopBarAction {
  const PlayerTopBarAction({
    required this.action,
    required this.button,
    required this.width,
    required this.icon,
    required this.label,
    required this.onSelected,
    this.iconColor,
  });

  final PlayerTopAction action;

  /// The button as shown in the bar.
  final Widget button;

  /// The width [button] takes in the bar.
  final double width;

  final IconData icon;
  final Color? iconColor;

  /// The menu text (with its shortcut, as in the tooltip).
  final String label;

  /// What the button does; the menu item does the same.
  final VoidCallback onSelected;
}

/// The buttons of [actions] that go into「更多」so that [fixedWidth] (back
/// button, title at its minimum, gaps) and the rest fit in [available].
/// Empty when everything fits: the bar then stays exactly as it was.
Set<PlayerTopAction> playerTopActionsToCollapse({
  required double available,
  required double fixedWidth,
  required List<PlayerTopBarAction> actions,
  required double moreButtonWidth,
}) {
  const tolerance = 0.01;
  var total = fixedWidth;
  for (final entry in actions) {
    total += entry.width;
  }
  final collapsed = <PlayerTopAction>{};
  if (total <= available + tolerance) return collapsed;
  total += moreButtonWidth;
  for (final action in kPlayerTopActionCollapseOrder) {
    for (final entry in actions) {
      if (entry.action != action) continue;
      collapsed.add(action);
      total -= entry.width;
    }
    if (collapsed.isNotEmpty && total <= available + tolerance) break;
  }
  return collapsed;
}

/// The row of the landscape top bar: back button, title, buttons. When the
/// row is too narrow, buttons move into a「更多」menu by
/// [kPlayerTopActionCollapseOrder] so the title keeps
/// [kPlayerTopTitleMinWidth]. [mirrored] puts the buttons on the left
/// (left-handed mode).
class PlayerTopBar extends StatelessWidget {
  const PlayerTopBar({
    super.key,
    required this.leading,
    required this.leadingWidth,
    required this.title,
    required this.gap,
    required this.actions,
    required this.mirrored,
    required this.buttonExtent,
    required this.iconSize,
    required this.buttonPadding,
    this.onMenuSelected,
  });

  final List<Widget> leading;
  final double leadingWidth;

  /// Null when there is no title.
  final Widget? title;

  /// Space on both sides of the title.
  final double gap;

  final List<PlayerTopBarAction> actions;
  final bool mirrored;

  /// Size of the「更多」button, like the other buttons.
  final double buttonExtent;
  final double iconSize;
  final EdgeInsets buttonPadding;

  /// Called before a menu item's action runs.
  final VoidCallback? onMenuSelected;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final title = this.title;
        final fixedWidth =
            leadingWidth +
            (title == null ? 0 : gap * 2 + kPlayerTopTitleMinWidth);
        final collapsed = constraints.hasBoundedWidth
            ? playerTopActionsToCollapse(
                available: constraints.maxWidth,
                fixedWidth: fixedWidth,
                actions: actions,
                moreButtonWidth: buttonExtent,
              )
            : const <PlayerTopAction>{};
        final more = collapsed.isEmpty
            ? null
            : _MoreButton(
                actions: <PlayerTopBarAction>[
                  for (final entry in actions)
                    if (collapsed.contains(entry.action)) entry,
                ],
                extent: buttonExtent,
                iconSize: iconSize,
                padding: buttonPadding,
                onSelected: onMenuSelected,
              );
        final buttons = <Widget>[
          if (mirrored && more != null) more,
          for (final entry in actions)
            if (!collapsed.contains(entry.action)) entry.button,
          if (!mirrored && more != null) more,
        ];
        return Row(
          children: [
            if (mirrored) ...buttons else ...leading,
            if (title != null) ...[
              SizedBox(width: gap),
              Expanded(child: title),
              SizedBox(width: gap),
            ] else
              const Spacer(),
            if (mirrored) ...leading else ...buttons,
          ],
        );
      },
    );
  }
}

class _MoreButton extends StatelessWidget {
  const _MoreButton({
    required this.actions,
    required this.extent,
    required this.iconSize,
    required this.padding,
    this.onSelected,
  });

  final List<PlayerTopBarAction> actions;
  final double extent;
  final double iconSize;
  final EdgeInsets padding;
  final VoidCallback? onSelected;

  Future<void> _open(BuildContext context) async {
    final button = context.findRenderObject() as RenderBox?;
    final overlay =
        Navigator.of(context).overlay?.context.findRenderObject() as RenderBox?;
    if (button == null || overlay == null) return;
    final topLeft = button.localToGlobal(Offset.zero, ancestor: overlay);
    final bottomRight = button.localToGlobal(
      button.size.bottomRight(Offset.zero),
      ancestor: overlay,
    );
    final picked = await showMenu<PlayerTopAction>(
      context: context,
      color: const Color(0xFF2C2C2C),
      position: RelativeRect.fromRect(
        Rect.fromPoints(topLeft, bottomRight),
        Offset.zero & overlay.size,
      ),
      items: <PopupMenuEntry<PlayerTopAction>>[
        for (final entry in actions)
          PopupMenuItem<PlayerTopAction>(
            key: ValueKey('video-controls-more-${entry.action.name}'),
            value: entry.action,
            child: Row(
              children: [
                Icon(
                  entry.icon,
                  size: 20,
                  color: entry.iconColor ?? Colors.white,
                ),
                const SizedBox(width: 12),
                Flexible(
                  child: Text(
                    entry.label,
                    style: const TextStyle(color: Colors.white, fontSize: 14),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
    if (picked == null) return;
    for (final entry in actions) {
      if (entry.action != picked) continue;
      onSelected?.call();
      entry.onSelected();
      return;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Builder(
      builder: (context) => IconButton(
        key: const ValueKey('video-controls-top-more'),
        icon: const Icon(Icons.more_vert, color: Colors.white),
        tooltip: '更多',
        onPressed: () => _open(context),
        iconSize: iconSize,
        padding: padding,
        constraints: BoxConstraints.tightFor(width: extent, height: extent),
      ),
    );
  }
}
