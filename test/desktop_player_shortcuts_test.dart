import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/utils/desktop_player_shortcuts.dart';

void main() {
  group('DesktopPlayerShortcuts', () {
    test('every player action has a unique key binding', () {
      expect(
        DesktopPlayerShortcuts.defaults.length,
        DesktopPlayerShortcutAction.values.length,
      );

      final keys = DesktopPlayerShortcuts.defaults.values
          .map((binding) => binding.logicalKey)
          .toSet();
      expect(keys.length, DesktopPlayerShortcutAction.values.length);
    });

    test('matches transport and panel shortcuts to their intended actions', () {
      final expected = <LogicalKeyboardKey, DesktopPlayerShortcutAction>{
        LogicalKeyboardKey.escape: DesktopPlayerShortcutAction.back,
        LogicalKeyboardKey.space: DesktopPlayerShortcutAction.playPause,
        LogicalKeyboardKey.arrowLeft: DesktopPlayerShortcutAction.seekBackward,
        LogicalKeyboardKey.arrowRight: DesktopPlayerShortcutAction.seekForward,
        LogicalKeyboardKey.keyS: DesktopPlayerShortcutAction.openSettings,
        LogicalKeyboardKey.keyL:
            DesktopPlayerShortcutAction.openSubtitleLibrary,
        LogicalKeyboardKey.keyE: DesktopPlayerShortcutAction.openSubtitleEditor,
        LogicalKeyboardKey.keyV: DesktopPlayerShortcutAction.openVideoCompose,
        LogicalKeyboardKey.keyT: DesktopPlayerShortcutAction.openSubtitleStyle,
        LogicalKeyboardKey.keyD: DesktopPlayerShortcutAction.moveSubtitles,
        LogicalKeyboardKey.keyB:
            DesktopPlayerShortcutAction.toggleSubtitleSidebar,
        LogicalKeyboardKey.keyF: DesktopPlayerShortcutAction.toggleFullScreen,
        LogicalKeyboardKey.keyA: DesktopPlayerShortcutAction.openAspectRatio,
        LogicalKeyboardKey.keyG:
            DesktopPlayerShortcutAction.toggleEpisodePicker,
        LogicalKeyboardKey.keyP: DesktopPlayerShortcutAction.previousEpisode,
        LogicalKeyboardKey.keyN: DesktopPlayerShortcutAction.nextEpisode,
        LogicalKeyboardKey.keyC: DesktopPlayerShortcutAction.toggleSubtitles,
        LogicalKeyboardKey.keyM: DesktopPlayerShortcutAction.toggleMute,
      };

      for (final entry in expected.entries) {
        expect(
          DesktopPlayerShortcuts.matchAction(entry.key),
          entry.value,
          reason: 'Unexpected action for ${entry.key.keyLabel}',
        );
      }
      expect(
        DesktopPlayerShortcuts.matchAction(LogicalKeyboardKey.keyQ),
        isNull,
      );
    });

    test('tooltips expose the actual configured shortcut', () {
      expect(
        DesktopPlayerShortcuts.buildTooltip(
          '播放/暂停',
          DesktopPlayerShortcutAction.playPause,
        ),
        '播放/暂停 (Space)',
      );
      expect(
        DesktopPlayerShortcuts.buildTooltip(
          '返回',
          DesktopPlayerShortcutAction.back,
        ),
        '返回 (Esc)',
      );
    });
  });
}
