import 'package:flutter/material.dart';

import '../utils/desktop_media_management_shortcuts.dart';
import 'media_library_compact_app_bar.dart';

/// Selection-mode actions under the media library on phone and desktop.
///
/// Phone widths used to overflow because the FluentPack action spelled out the
/// full product name and the row scrolled. Compact mode shortens the label and
/// shares the bar evenly so all three actions stay on one screen.
class MediaLibrarySelectionBottomBar extends StatelessWidget {
  final VoidCallback onMoveToRecycleBin;
  final VoidCallback onExportFluentPack;
  final VoidCallback? onRename;

  const MediaLibrarySelectionBottomBar({
    super.key,
    required this.onMoveToRecycleBin,
    required this.onExportFluentPack,
    this.onRename,
  });

  @override
  Widget build(BuildContext context) {
    final compact = useCompactMediaLibraryTopBar(context);
    return BottomAppBar(
      color: const Color(0xFF1E1E1E),
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 4 : 8,
        vertical: compact ? 2 : 4,
      ),
      child: Row(
        mainAxisAlignment: compact
            ? MainAxisAlignment.start
            : MainAxisAlignment.spaceEvenly,
        children: [
          _action(
            compact: compact,
            icon: Icons.delete,
            color: Colors.redAccent,
            label: DesktopMediaManagementShortcuts.buildTooltip(
              '移入回收站',
              DesktopMediaManagementShortcutAction.openRecycleBin,
            ),
            onPressed: onMoveToRecycleBin,
          ),
          _action(
            compact: compact,
            icon: Icons.unarchive_outlined,
            color: const Color(0xFFAEB8FF),
            label: compact
                ? DesktopMediaManagementShortcuts.buildTooltip(
                    '导出',
                    DesktopMediaManagementShortcutAction.exportFluentPack,
                  )
                : DesktopMediaManagementShortcuts.buildTooltip(
                    '以 FluentPack 文件导出',
                    DesktopMediaManagementShortcutAction.exportFluentPack,
                  ),
            tooltip: DesktopMediaManagementShortcuts.buildTooltip(
              '以 FluentPack 文件导出',
              DesktopMediaManagementShortcutAction.exportFluentPack,
            ),
            onPressed: onExportFluentPack,
          ),
          if (onRename != null)
            _action(
              compact: compact,
              icon: Icons.edit,
              color: Colors.blueAccent,
              label: DesktopMediaManagementShortcuts.buildTooltip(
                '重命名',
                DesktopMediaManagementShortcutAction.createCollection,
              ),
              onPressed: onRename,
            ),
        ],
      ),
    );
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
