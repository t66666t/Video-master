import 'dart:math' as math;

/// Pure playback-behavior rules shared by every previous/next entry point.
class PlaybackBehaviorPolicy {
  const PlaybackBehaviorPolicy._();

  static const Duration minimumNearEndWindow = Duration(seconds: 2);
  static const Duration maximumNearEndWindow = Duration(seconds: 10);
  static const Duration completionTolerance = Duration(milliseconds: 200);

  /// Native clocks can trail the interpolated service timeline by a few
  /// hundred milliseconds. Treat either clock as having finished.
  static bool hasReachedPlaybackEnd({
    required Duration position,
    required Duration duration,
  }) {
    if (duration <= Duration.zero) return false;
    return position + completionTolerance >= duration;
  }

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
    if (savedPosition >= duration) {
      // Completing past a known duration restarts. A saved point far beyond
      // the reported length is corrupt/short metadata, not end-of-file.
      final overshoot = savedPosition - duration;
      return overshoot <= maximumNearEndWindow
          ? Duration.zero
          : savedPosition;
    }

    final scaledWindowMs = duration.inMilliseconds ~/ 100;
    final nearEndWindowMs = math.max(
      minimumNearEndWindow.inMilliseconds,
      math.min(maximumNearEndWindow.inMilliseconds, scaledWindowMs),
    );
    final remainingMs = duration.inMilliseconds - savedPosition.inMilliseconds;
    return remainingMs <= nearEndWindowMs ? Duration.zero : savedPosition;
  }

  /// Probe durations from a just-opened Bilibili stream can be a few seconds
  /// while library metadata still has the real length. Prefer the longer
  /// trusted value so a mid-file resume is not treated as "already finished".
  static Duration trustedDurationForResume({
    required Duration nativeDuration,
    required Duration metadataDuration,
    Duration savedPosition = Duration.zero,
  }) {
    var best = Duration.zero;
    if (metadataDuration > best) best = metadataDuration;
    if (nativeDuration > best) best = nativeDuration;
    if (metadataDuration > Duration.zero &&
        nativeDuration > Duration.zero &&
        nativeDuration < metadataDuration ~/ 2) {
      best = metadataDuration;
    }
    if (savedPosition > Duration.zero && best <= savedPosition) {
      return savedPosition + maximumNearEndWindow + const Duration(seconds: 1);
    }
    return best;
  }

  /// Leaving a playback page pauses only an explicit user exit of a live
  /// transport. Bilibili Mini/notification sessions use [transportPlaying]
  /// because Dart `isPlaying` stays false under cache-pause.
  static bool shouldPauseOnPlaybackPageExit({
    required bool autoPauseOnExit,
    required bool explicitExit,
    required bool suppressRouteCleanup,
    required bool transportPlaying,
  }) {
    return autoPauseOnExit &&
        explicitExit &&
        !suppressRouteCleanup &&
        transportPlaying;
  }

  /// Mobile "leave the app" pause. Loading Bilibili audio already has a play
  /// intent, so the transport flag is the authority rather than `_state`.
  static bool shouldPauseWhenAppBackgrounded({
    required bool enabled,
    required bool isMobilePlatform,
    required bool transportPlaying,
  }) {
    return enabled && isMobilePlatform && transportPlaying;
  }

  /// Split Bilibili streams often leave native `time-pos` behind the service
  /// clock, or keep Dart `isPlaying` false the whole session. Confirm the end
  /// from either clock; local files still reject a playing mid-file pulse.
  static bool isConfirmedPlaybackCompletion({
    required Duration servicePosition,
    required Duration serviceDuration,
    required Duration nativePosition,
    required Duration nativeDuration,
    required bool nativePlaying,
    required bool isOnlineBilibiliStream,
  }) {
    final nativeEnd = hasReachedPlaybackEnd(
      position: nativePosition,
      duration: nativeDuration,
    );
    final serviceEnd = hasReachedPlaybackEnd(
      position: servicePosition,
      duration: serviceDuration,
    );
    if (!nativeEnd && !serviceEnd) return false;
    if (isOnlineBilibiliStream) return true;
    return !nativePlaying || nativeEnd;
  }
}
