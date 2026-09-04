import 'dart:math' as math;

/// Pure playback-behavior rules shared by every previous/next entry point.
class PlaybackBehaviorPolicy {
  const PlaybackBehaviorPolicy._();

  static const Duration minimumNearEndWindow = Duration(seconds: 2);
  static const Duration maximumNearEndWindow = Duration(seconds: 10);

  /// A saved point that would immediately complete again is treated as a
  /// completed item and restarted. The window scales to 1% of the media while
  /// remaining bounded for very short and very long content.
  static Duration normalizeEpisodeStartPosition({
    required Duration savedPosition,
    required Duration duration,
    bool forceFromStart = false,
  }) {
    if (forceFromStart || savedPosition <= Duration.zero) {
      return Duration.zero;
    }
    if (duration <= Duration.zero) return savedPosition;
    if (savedPosition >= duration) return Duration.zero;

    final scaledWindowMs = duration.inMilliseconds ~/ 100;
    final nearEndWindowMs = math.max(
      minimumNearEndWindow.inMilliseconds,
      math.min(maximumNearEndWindow.inMilliseconds, scaledWindowMs),
    );
    final remainingMs = duration.inMilliseconds - savedPosition.inMilliseconds;
    return remainingMs <= nearEndWindowMs ? Duration.zero : savedPosition;
  }
}
