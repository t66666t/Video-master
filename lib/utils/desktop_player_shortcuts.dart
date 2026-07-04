import 'package:flutter/services.dart';

enum DesktopPlayerShortcutAction {
  back,
  playPause,
  seekBackward,
  seekForward,
  openSettings,
  openSubtitleLibrary,
  openSubtitleEditor,
  openVideoCompose,
  openSubtitleStyle,
  moveSubtitles,
  toggleSubtitleSidebar,
  toggleFullScreen,
  openAspectRatio,
  toggleEpisodePicker,
  previousEpisode,
  nextEpisode,
  toggleSubtitles,
  toggleMute,
}

class DesktopPlayerShortcutBinding {
  const DesktopPlayerShortcutBinding(this.logicalKey);

  final LogicalKeyboardKey logicalKey;

  bool matches(LogicalKeyboardKey key) => logicalKey == key;

  String formatLabel() {
    if (logicalKey == LogicalKeyboardKey.space) return 'Space';
    if (logicalKey == LogicalKeyboardKey.escape) return 'Esc';
    if (logicalKey == LogicalKeyboardKey.arrowLeft) return 'Left';
    if (logicalKey == LogicalKeyboardKey.arrowRight) return 'Right';
    return logicalKey.keyLabel.toUpperCase();
  }
}

class DesktopPlayerShortcuts {
  static const Map<DesktopPlayerShortcutAction, DesktopPlayerShortcutBinding>
  defaults = <DesktopPlayerShortcutAction, DesktopPlayerShortcutBinding>{
    DesktopPlayerShortcutAction.back: DesktopPlayerShortcutBinding(
      LogicalKeyboardKey.escape,
    ),
    DesktopPlayerShortcutAction.playPause: DesktopPlayerShortcutBinding(
      LogicalKeyboardKey.space,
    ),
    DesktopPlayerShortcutAction.seekBackward: DesktopPlayerShortcutBinding(
      LogicalKeyboardKey.arrowLeft,
    ),
    DesktopPlayerShortcutAction.seekForward: DesktopPlayerShortcutBinding(
      LogicalKeyboardKey.arrowRight,
    ),
    DesktopPlayerShortcutAction.openSettings: DesktopPlayerShortcutBinding(
      LogicalKeyboardKey.keyS,
    ),
    DesktopPlayerShortcutAction.openSubtitleLibrary:
        DesktopPlayerShortcutBinding(LogicalKeyboardKey.keyL),
    DesktopPlayerShortcutAction.openSubtitleEditor:
        DesktopPlayerShortcutBinding(LogicalKeyboardKey.keyE),
    DesktopPlayerShortcutAction.openVideoCompose: DesktopPlayerShortcutBinding(
      LogicalKeyboardKey.keyV,
    ),
    DesktopPlayerShortcutAction.openSubtitleStyle: DesktopPlayerShortcutBinding(
      LogicalKeyboardKey.keyT,
    ),
    DesktopPlayerShortcutAction.moveSubtitles: DesktopPlayerShortcutBinding(
      LogicalKeyboardKey.keyD,
    ),
    DesktopPlayerShortcutAction.toggleSubtitleSidebar:
        DesktopPlayerShortcutBinding(LogicalKeyboardKey.keyB),
    DesktopPlayerShortcutAction.toggleFullScreen: DesktopPlayerShortcutBinding(
      LogicalKeyboardKey.keyF,
    ),
    DesktopPlayerShortcutAction.openAspectRatio: DesktopPlayerShortcutBinding(
      LogicalKeyboardKey.keyA,
    ),
    DesktopPlayerShortcutAction.toggleEpisodePicker:
        DesktopPlayerShortcutBinding(LogicalKeyboardKey.keyG),
    DesktopPlayerShortcutAction.previousEpisode: DesktopPlayerShortcutBinding(
      LogicalKeyboardKey.keyP,
    ),
    DesktopPlayerShortcutAction.nextEpisode: DesktopPlayerShortcutBinding(
      LogicalKeyboardKey.keyN,
    ),
    DesktopPlayerShortcutAction.toggleSubtitles: DesktopPlayerShortcutBinding(
      LogicalKeyboardKey.keyC,
    ),
    DesktopPlayerShortcutAction.toggleMute: DesktopPlayerShortcutBinding(
      LogicalKeyboardKey.keyM,
    ),
  };

  static DesktopPlayerShortcutAction? matchAction(LogicalKeyboardKey key) {
    for (final MapEntry<
          DesktopPlayerShortcutAction,
          DesktopPlayerShortcutBinding
        >
        entry
        in defaults.entries) {
      if (entry.value.matches(key)) {
        return entry.key;
      }
    }
    return null;
  }

  static String shortcutLabel(DesktopPlayerShortcutAction action) {
    final DesktopPlayerShortcutBinding? binding = defaults[action];
    return binding?.formatLabel() ?? '';
  }

  static String buildTooltip(String label, DesktopPlayerShortcutAction action) {
    final String shortcut = shortcutLabel(action);
    if (shortcut.isEmpty) return label;
    return '$label ($shortcut)';
  }
}
