import 'package:wakelock_plus/wakelock_plus.dart';

/// 协调多个业务场景对亮屏的请求，避免互相覆盖关闭。
class AppWakelockCoordinator {
  static const String mediaPlaybackReason = 'media_playback';
  static const String bilibiliDownloadReason = 'bilibili_download_processing';
  static const String ytDlpDownloadReason = 'yt_dlp_download_processing';

  static final Set<String> _activeReasons = <String>{};
  static bool _wakelockApplied = false;

  static void setActive(String reason, bool active) {
    if (active) {
      _activeReasons.add(reason);
    } else {
      _activeReasons.remove(reason);
    }
    _sync();
  }

  static bool isReasonActive(String reason) => _activeReasons.contains(reason);

  static void _sync() {
    final bool shouldEnable = _activeReasons.isNotEmpty;
    if (_wakelockApplied == shouldEnable) return;
    _wakelockApplied = shouldEnable;
    try {
      final Future<void> future = shouldEnable
          ? WakelockPlus.enable()
          : WakelockPlus.disable();
      future.catchError((_) {});
    } catch (_) {}
  }
}
