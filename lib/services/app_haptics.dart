import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'settings_service.dart';

/// The single gateway for app-wide haptic feedback.
///
/// Keeping the platform and preference checks here prevents individual
/// interactions from bypassing the user's vibration setting.
class AppHaptics {
  const AppHaptics._();

  static bool get isSupportedPlatform {
    if (kIsWeb) return false;
    return defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS;
  }

  static bool _canVibrate(SettingsService settings) {
    return isSupportedPlatform && settings.enableHapticFeedback;
  }

  static Future<void> _perform(
    SettingsService settings,
    Future<void> Function() feedback,
  ) async {
    if (!_canVibrate(settings)) return;
    try {
      await feedback();
    } catch (error) {
      debugPrint('Haptic feedback unavailable: $error');
    }
  }

  static Future<void> selectionClick(SettingsService settings) async {
    await _perform(settings, HapticFeedback.selectionClick);
  }

  static Future<void> longPressStarted(SettingsService settings) async {
    await _perform(settings, HapticFeedback.mediumImpact);
  }

  static Future<void> reorderDragStarted(SettingsService settings) async {
    await _perform(settings, HapticFeedback.mediumImpact);
  }

  static Future<void> reorderTargetChanged(SettingsService settings) async {
    await _perform(settings, HapticFeedback.selectionClick);
  }

  static Future<void> reorderDragCompleted(SettingsService settings) async {
    await _perform(settings, HapticFeedback.lightImpact);
  }

  static Future<void> doubleTapSeek(SettingsService settings) async {
    await _perform(settings, HapticFeedback.lightImpact);
  }
}
