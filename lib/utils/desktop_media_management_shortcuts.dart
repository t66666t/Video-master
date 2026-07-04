import 'package:flutter/services.dart';

enum DesktopMediaManagementShortcutAction {
  backOrExitSelection,
  toggleViewMode,
  toggleFullScreen,
  openLargeDataDirectory,
  exportSettings,
  openRecycleBin,
  openCardStyle,
  enterSelectionMode,
  toggleSelectAll,
}

class DesktopMediaManagementShortcuts {
  static const Map<DesktopMediaManagementShortcutAction, LogicalKeyboardKey>
  defaults = <DesktopMediaManagementShortcutAction, LogicalKeyboardKey>{
    DesktopMediaManagementShortcutAction.backOrExitSelection:
        LogicalKeyboardKey.escape,
    DesktopMediaManagementShortcutAction.toggleViewMode:
        LogicalKeyboardKey.keyV,
    DesktopMediaManagementShortcutAction.toggleFullScreen:
        LogicalKeyboardKey.keyF,
    DesktopMediaManagementShortcutAction.openLargeDataDirectory:
        LogicalKeyboardKey.keyO,
    DesktopMediaManagementShortcutAction.exportSettings:
        LogicalKeyboardKey.keyE,
    DesktopMediaManagementShortcutAction.openRecycleBin:
        LogicalKeyboardKey.keyR,
    DesktopMediaManagementShortcutAction.openCardStyle: LogicalKeyboardKey.keyT,
    DesktopMediaManagementShortcutAction.enterSelectionMode:
        LogicalKeyboardKey.keyB,
    DesktopMediaManagementShortcutAction.toggleSelectAll:
        LogicalKeyboardKey.keyA,
  };

  static DesktopMediaManagementShortcutAction? matchAction(
    LogicalKeyboardKey key,
  ) {
    for (final entry in defaults.entries) {
      if (entry.value == key) return entry.key;
    }
    return null;
  }

  static String shortcutLabel(DesktopMediaManagementShortcutAction action) {
    final LogicalKeyboardKey? key = defaults[action];
    if (key == null) return '';
    if (key == LogicalKeyboardKey.escape) return 'Esc';
    return key.keyLabel.toUpperCase();
  }

  static String buildTooltip(
    String label,
    DesktopMediaManagementShortcutAction action,
  ) {
    final String shortcut = shortcutLabel(action);
    if (shortcut.isEmpty) return label;
    return '$label ($shortcut)';
  }
}
