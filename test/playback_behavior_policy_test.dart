import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/services/playback_behavior_policy.dart';

void main() {
  group('PlaybackBehaviorPolicy.normalizeEpisodeStartPosition', () {
    test('keeps a normal saved position', () {
      expect(
        PlaybackBehaviorPolicy.normalizeEpisodeStartPosition(
          savedPosition: const Duration(seconds: 30),
          duration: const Duration(minutes: 2),
        ),
        const Duration(seconds: 30),
      );
    });

    test('restarts completed and near-end media', () {
      for (final savedPosition in <Duration>[
        const Duration(minutes: 2),
        const Duration(seconds: 119),
      ]) {
        expect(
          PlaybackBehaviorPolicy.normalizeEpisodeStartPosition(
            savedPosition: savedPosition,
            duration: const Duration(minutes: 2),
          ),
          Duration.zero,
        );
      }
      expect(
        PlaybackBehaviorPolicy.normalizeEpisodeStartPosition(
          savedPosition: const Duration(seconds: 117),
          duration: const Duration(minutes: 2),
        ),
        const Duration(seconds: 117),
      );
    });

    test('bounds the near-end window for very long media', () {
      expect(
        PlaybackBehaviorPolicy.normalizeEpisodeStartPosition(
          savedPosition: const Duration(hours: 2) - const Duration(seconds: 9),
          duration: const Duration(hours: 2),
        ),
        Duration.zero,
      );
      expect(
        PlaybackBehaviorPolicy.normalizeEpisodeStartPosition(
          savedPosition: const Duration(hours: 2) - const Duration(seconds: 11),
          duration: const Duration(hours: 2),
        ),
        const Duration(hours: 2) - const Duration(seconds: 11),
      );
    });

    test('force-from-start wins over saved progress', () {
      expect(
        PlaybackBehaviorPolicy.normalizeEpisodeStartPosition(
          savedPosition: const Duration(seconds: 30),
          duration: const Duration(minutes: 2),
          forceFromStart: true,
        ),
        Duration.zero,
      );
    });

    test('keeps progress when duration is not known yet', () {
      expect(
        PlaybackBehaviorPolicy.normalizeEpisodeStartPosition(
          savedPosition: const Duration(seconds: 30),
          duration: Duration.zero,
        ),
        const Duration(seconds: 30),
      );
    });

    test('keeps progress when reported duration is far shorter than saved', () {
      expect(
        PlaybackBehaviorPolicy.normalizeEpisodeStartPosition(
          savedPosition: const Duration(minutes: 5),
          duration: const Duration(seconds: 2),
        ),
        const Duration(minutes: 5),
      );
    });

    test('prefers library duration over a short native probe', () {
      expect(
        PlaybackBehaviorPolicy.trustedDurationForResume(
          nativeDuration: const Duration(seconds: 2),
          metadataDuration: const Duration(minutes: 20),
          savedPosition: const Duration(minutes: 5),
        ),
        const Duration(minutes: 20),
      );
    });
  });

  group('PlaybackBehaviorPolicy playback-setting rules', () {
    test('page-exit pause follows the live transport, not Dart isPlaying', () {
      expect(
        PlaybackBehaviorPolicy.shouldPauseOnPlaybackPageExit(
          autoPauseOnExit: true,
          explicitExit: true,
          suppressRouteCleanup: false,
          transportPlaying: true,
        ),
        isTrue,
      );
      expect(
        PlaybackBehaviorPolicy.shouldPauseOnPlaybackPageExit(
          autoPauseOnExit: false,
          explicitExit: true,
          suppressRouteCleanup: false,
          transportPlaying: true,
        ),
        isFalse,
      );
      expect(
        PlaybackBehaviorPolicy.shouldPauseOnPlaybackPageExit(
          autoPauseOnExit: true,
          explicitExit: false,
          suppressRouteCleanup: false,
          transportPlaying: true,
        ),
        isFalse,
      );
      expect(
        PlaybackBehaviorPolicy.shouldPauseOnPlaybackPageExit(
          autoPauseOnExit: true,
          explicitExit: true,
          suppressRouteCleanup: true,
          transportPlaying: true,
        ),
        isFalse,
      );
      expect(
        PlaybackBehaviorPolicy.shouldPauseOnPlaybackPageExit(
          autoPauseOnExit: true,
          explicitExit: true,
          suppressRouteCleanup: false,
          transportPlaying: false,
        ),
        isFalse,
      );
    });

    test('background pause uses the Bilibili transport intent', () {
      expect(
        PlaybackBehaviorPolicy.shouldPauseWhenAppBackgrounded(
          enabled: true,
          isMobilePlatform: true,
          transportPlaying: true,
        ),
        isTrue,
      );
      expect(
        PlaybackBehaviorPolicy.shouldPauseWhenAppBackgrounded(
          enabled: true,
          isMobilePlatform: true,
          transportPlaying: false,
        ),
        isFalse,
      );
      expect(
        PlaybackBehaviorPolicy.shouldPauseWhenAppBackgrounded(
          enabled: true,
          isMobilePlatform: false,
          transportPlaying: true,
        ),
        isFalse,
      );
      expect(
        PlaybackBehaviorPolicy.shouldPauseWhenAppBackgrounded(
          enabled: false,
          isMobilePlatform: true,
          transportPlaying: true,
        ),
        isFalse,
      );
    });

    test('Bilibili completion trusts the service clock when native lags', () {
      const duration = Duration(minutes: 4);
      expect(
        PlaybackBehaviorPolicy.isConfirmedPlaybackCompletion(
          servicePosition: duration,
          serviceDuration: duration,
          nativePosition: duration - const Duration(seconds: 2),
          nativeDuration: duration,
          nativePlaying: false,
          isOnlineBilibiliStream: true,
        ),
        isTrue,
      );
      expect(
        PlaybackBehaviorPolicy.isConfirmedPlaybackCompletion(
          servicePosition: const Duration(minutes: 2),
          serviceDuration: duration,
          nativePosition: const Duration(minutes: 2),
          nativeDuration: duration,
          nativePlaying: false,
          isOnlineBilibiliStream: true,
        ),
        isFalse,
      );
      expect(
        PlaybackBehaviorPolicy.isConfirmedPlaybackCompletion(
          servicePosition: duration,
          serviceDuration: duration,
          nativePosition: const Duration(minutes: 2),
          nativeDuration: duration,
          nativePlaying: true,
          isOnlineBilibiliStream: false,
        ),
        isFalse,
      );
    });
  });
}
