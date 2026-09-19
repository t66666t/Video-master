import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';

import 'hardware_keyboard_shortcuts.dart';

/// True when an editable field currently owns keyboard focus.
bool isEditableTextFocused() {
  final BuildContext? focusContext =
      FocusManager.instance.primaryFocus?.context;
  if (focusContext == null) return false;
  return focusContext.widget is EditableText ||
      focusContext.findAncestorWidgetOfExactType<EditableText>() != null;
}

bool hasBlockingKeyboardModifier() {
  return HardwareKeyboard.instance.isControlPressed ||
      HardwareKeyboard.instance.isAltPressed ||
      HardwareKeyboard.instance.isMetaPressed;
}

String formatShortcutKey(LogicalKeyboardKey key) {
  if (key == LogicalKeyboardKey.space) return 'Space';
  if (key == LogicalKeyboardKey.escape) return 'Esc';
  if (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.numpadEnter) {
    return 'Enter';
  }
  if (key == LogicalKeyboardKey.arrowLeft) return 'Left';
  if (key == LogicalKeyboardKey.arrowRight) return 'Right';
  if (key == LogicalKeyboardKey.arrowUp) return 'Up';
  if (key == LogicalKeyboardKey.arrowDown) return 'Down';
  final String label = key.keyLabel;
  if (label.isEmpty) return '';
  return label.length == 1 ? label.toUpperCase() : label;
}

String tooltipWithShortcutKey(String label, LogicalKeyboardKey key) {
  final String shortcut = formatShortcutKey(key);
  if (shortcut.isEmpty) return label;
  return '$label ($shortcut)';
}

/// Hover platforms get `(Key)` suffixes; touch-only phones still show them
/// when a physical keyboard is attached because tooltips also appear on long
/// press, and the same map drives both desktop and mobile keyboards.
String hoverAwareShortcutTooltip(String label, LogicalKeyboardKey key) {
  final TargetPlatform? platform = currentNativeTargetPlatform;
  if (platform == null || !supportsHardwareKeyboardShortcutsOn(platform)) {
    return label;
  }
  return tooltipWithShortcutKey(label, key);
}
