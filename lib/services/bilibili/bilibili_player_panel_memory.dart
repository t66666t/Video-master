import 'dart:async';

import 'package:video_player_app/services/settings_service.dart';

/// The remembered open / closed state of the landscape Bilibili panel.
///
/// Only a deliberate user action changes it: the panel button, its shortcut
/// or the panel's collapse button. The player not opening the panel by
/// itself, another panel shown over it for a moment and entering or leaving
/// full screen only change what is shown now.
class BilibiliPlayerPanelMemory {
  BilibiliPlayerPanelMemory({
    required bool Function() read,
    required Future<void> Function(bool open) write,
  }) : _read = read,
       _write = write;

  factory BilibiliPlayerPanelMemory.of(SettingsService settings) =>
      BilibiliPlayerPanelMemory(
        read: () => settings.bilibiliPlayerPanelOpen,
        write: settings.saveBilibiliPlayerPanelOpen,
      );

  final bool Function() _read;
  final Future<void> Function(bool open) _write;

  bool get remembered => _read();

  /// The panel button or shortcut was used while the panel was [showing]:
  /// returns whether it is open afterwards and remembers that.
  bool userToggled({required bool showing}) {
    final open = !showing;
    unawaited(_write(open));
    return open;
  }

  /// The panel's own collapse button was used.
  void userCollapsed() {
    unawaited(_write(false));
  }
}
