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
  });
}
