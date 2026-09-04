import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('playback pages never create or transfer native controllers', () {
    for (final path in <String>[
      'lib/screens/portrait_video_screen.dart',
      'lib/screens/video_player_screen.dart',
    ]) {
      final source = File(path).readAsStringSync();
      expect(source, isNot(contains('VideoPlayerController.file(')));
      expect(source, isNot(contains('VideoPlayerController.networkUrl(')));
      expect(source, isNot(contains('.setController(')));
    }
  });

  test(
    'every episode navigation UI delegates playback behavior to service',
    () {
      for (final path in <String>[
        'lib/screens/portrait_video_screen.dart',
        'lib/screens/video_player_screen.dart',
        'lib/widgets/episode_picker_panel.dart',
        'lib/widgets/mini_playback_card.dart',
        'lib/services/system_media_session_service.dart',
      ]) {
        final source = File(path).readAsStringSync();
        expect(
          RegExp(r'playNext\s*\(\s*autoPlay:').hasMatch(source),
          isFalse,
          reason: '$path must not override the persisted switch',
        );
        expect(
          RegExp(r'playPrevious\s*\(\s*autoPlay:').hasMatch(source),
          isFalse,
          reason: '$path must not override the persisted switch',
        );
      }

      final landscapePage = File(
        'lib/screens/video_player_screen.dart',
      ).readAsStringSync();
      expect(landscapePage, isNot(contains('autoPlayNextEnabled')));
    },
  );
}
