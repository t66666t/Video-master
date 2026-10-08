import 'package:flutter/material.dart';

import '../theme/app_tokens.dart';
import '../utils/desktop_media_management_shortcuts.dart';
import '../utils/media_library_virtual_selection_actions.dart';
import 'media_library_compact_app_bar.dart';

/// Selection-mode actions under the media library on phone and desktop.
///
/// Phone widths used to overflow because the FluentPack action spelled out the
/// full product name and the row scrolled. Compact mode shortens the label and
/// shares the bar evenly so all actions stay on one screen.
class MediaLibrarySelectionBottomBar extends StatelessWidget {
  const MediaLibrarySelectionBottomBar({
    super.key,
    required this.actions,
    required this.onAction,
  });

  /// Folder / collection selection: recycle, export, optional rename.
  factory MediaLibrarySelectionBottomBar.folders({
    Key? key,
    required VoidCallback onMoveToRecycleBin,
    required VoidCallback onExportFluentPack,
    VoidCallback? onRename,
  }) {
    final actions = MediaLibraryVirtualSelectionActions.forFolders(
      selectedIds: onRename == null
          ? const <String>{'a', 'b'}
          : const <String>{'only'},
    );
    return MediaLibrarySelectionBottomBar(
      key: key,
      actions: actions,
      onAction: (kind) {
        switch (kind) {
          case MediaLibraryVirtualSelectionActionKind.recycle:
            onMoveToRecycleBin();
          case MediaLibraryVirtualSelectionActionKind.export:
            onExportFluentPack();
          case MediaLibraryVirtualSelectionActionKind.rename:
            onRename?.call();
          case MediaLibraryVirtualSelectionActionKind.pin:
          case MediaLibraryVirtualSelectionActionKind.unpin:
          case MediaLibraryVirtualSelectionActionKind.hideContinue:
          case MediaLibraryVirtualSelectionActionKind.dismissRecent:
            break;
        }
      },
    );
  }

  final List<MediaLibraryVirtualSelectionAction> actions;
  final ValueChanged<MediaLibraryVirtualSelectionActionKind> onAction;

  @override
  Widget build(BuildContext context) {
    final compact = useCompactMediaLibraryTopBar(context);
    return BottomAppBar(
      color: AppTokens.bgRaised,
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 4 : 8,
        vertical: compact ? 2 : 4,
      ),
      child: Row(
        mainAxisAlignment: compact
            ? MainAxisAlignment.start
            : MainAxisAlignment.spaceEvenly,
        children: [
          for (final action in actions)
            _action(
              compact: compact,
              icon: action.icon,
              color: action.color,
              label: _labelFor(action),
              tooltip: action.tooltip ?? _tooltipFor(action),
              onPressed: () => onAction(action.kind),
            ),
        ],
      ),
    );
  }

  String _labelFor(MediaLibraryVirtualSelectionAction action) {
    switch (action.kind) {
      case MediaLibraryVirtualSelectionActionKind.recycle:
        return DesktopMediaManagementShortcuts.buildTooltip(
          action.label,
          DesktopMediaManagementShortcutAction.openRecycleBin,
        );
      case MediaLibraryVirtualSelectionActionKind.export:
        return DesktopMediaManagementShortcuts.buildTooltip(
          action.label,
          DesktopMediaManagementShortcutAction.exportFluentPack,
        );
      case MediaLibraryVirtualSelectionActionKind.rename:
        return DesktopMediaManagementShortcuts.buildTooltip(
          action.label,
          DesktopMediaManagementShortcutAction.createCollection,
        );
      case MediaLibraryVirtualSelectionActionKind.pin:
      case MediaLibraryVirtualSelectionActionKind.unpin:
      case MediaLibraryVirtualSelectionActionKind.hideContinue:
      case MediaLibraryVirtualSelectionActionKind.dismissRecent:
        return action.label;
    }
  }

  String? _tooltipFor(MediaLibraryVirtualSelectionAction action) {
    if (action.kind == MediaLibraryVirtualSelectionActionKind.export) {
      return DesktopMediaManagementShortcuts.buildTooltip(
        '导出为 Fluent Pack 或 Zip',
        DesktopMediaManagementShortcutAction.exportFluentPack,
      );
    }
    return action.tooltip;
  }

  Widget _action({
    required bool compact,
    required IconData icon,
    required Color color,
    required String label,
    required VoidCallback? onPressed,
    String? tooltip,
  }) {
    final button = TextButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, color: color, size: compact ? 20 : 24),
      label: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: color),
      ),
      style: TextButton.styleFrom(
        padding: EdgeInsets.symmetric(horizontal: compact ? 4 : 12),
        visualDensity: compact ? VisualDensity.compact : VisualDensity.standard,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        minimumSize: Size.zero,
      ),
    );
    final labeled = tooltip == null
        ? button
        : Tooltip(message: tooltip, child: button);
    if (!compact) {
      return labeled;
    }
    return Expanded(
      child: Align(alignment: Alignment.center, child: labeled),
    );
  }
}
