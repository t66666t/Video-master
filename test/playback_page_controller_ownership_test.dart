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

  test('popup routes do not report playback pages as hidden', () {
    for (final path in <String>[
      'lib/screens/portrait_video_screen.dart',
      'lib/screens/video_player_screen.dart',
    ]) {
      final source = File(path).readAsStringSync();
      expect(
        RegExp(
          r'setPlaybackPageVisible\s*\(\s*this\s*,\s*ModalRoute\.of\(context\)\?\.isCurrent',
        ).hasMatch(source),
        isFalse,
        reason:
            '$path must not disable Bilibili video merely because a popup route is open',
      );
      expect(
        source,
        contains('registerPlaybackPageIfCurrent(context, this)'),
        reason: '$path must still register its initial visible state',
      );
    }
  });

  test('re-enabling a Bilibili video track seeks back to the clock', () {
    final source = File(
      'lib/platform/windows_video_player_media_kit.dart',
    ).readAsStringSync();
    expect(source, contains('shouldSeekAfterExternalVideoTrackEnable('));
    expect(source, contains('await player.seek(resumePosition)'));
    expect(source, contains('_prepareVideoTrackJoinPreservingAudio'));
    expect(source, isNot(contains('_resyncVideoToClockPreservingAudio')));
    expect(source, contains("'cache-pause',\n        'no'"));
    final enableStart = source.indexOf('if (shouldEnable) {');
    final enableEnd = source.indexOf(
      'final selected = player.state.track.video;',
    );
    expect(enableStart, greaterThan(0));
    expect(enableEnd, greaterThan(enableStart));
    final enableBody = source.substring(enableStart, enableEnd);
    expect(
      enableBody.contains('await player.pause();') &&
          enableBody.indexOf('await player.pause();') <
              enableBody.indexOf('await player.setVideoTrack(target)'),
      isFalse,
      reason:
          'Pausing before setVideoTrack clears the decoded texture and paints black',
    );
    expect(enableBody, contains('if (!resumePlaying &&'));
    expect(
      enableBody.indexOf('_prepareVideoTrackJoinPreservingAudio'),
      lessThan(enableBody.indexOf('await player.setVideoTrack(target)')),
    );
  });

  test('video surface stays unmounted until controller assignment', () {
    expect(
      File('lib/screens/video_player_screen.dart').readAsStringSync(),
      contains(
        '_controllerAssigned && (_initialized || _hasDecodedVideoTexture)',
      ),
    );
    expect(
      File('lib/screens/portrait_video_screen.dart').readAsStringSync(),
      contains(
        '_isControllerAssigned && (_initialized || _hasDecodedVideoTexture)',
      ),
    );
  });

  test('re-entry defers play while an active Bilibili session remounts', () {
    final landscape = File(
      'lib/screens/video_player_screen.dart',
    ).readAsStringSync();
    final portrait = File(
      'lib/screens/portrait_video_screen.dart',
    ).readAsStringSync();
    final service = File(
      'lib/services/media_playback_service.dart',
    ).readAsStringSync();
    expect(service, contains('shouldDeferPlayForActiveSession('));
    expect(
      landscape,
      contains('shouldDeferPlayForActiveSession(currentItem.id)'),
    );
    expect(
      portrait,
      contains('shouldDeferPlayForActiveSession(currentItem.id)'),
    );
    expect(landscape, contains('startPositionForCurrentSession('));
    expect(portrait, contains('startPositionForCurrentSession('));
  });

  test('ready Bilibili video is not covered by the loading overlay', () {
    final landscape = File(
      'lib/screens/video_player_screen.dart',
    ).readAsStringSync();
    final portrait = File(
      'lib/screens/portrait_video_screen.dart',
    ).readAsStringSync();
    expect(landscape, isNot(contains('!service.isSwitchingStreamQuality')));
    expect(portrait, isNot(contains('!service.isSwitchingStreamQuality')));
    expect(landscape, contains('!(_initialized && _controllerAssigned)'));
    expect(portrait, contains('!(_initialized && _isControllerAssigned)'));
    expect(landscape, contains('_buildVisibleVideoFrameCover()'));
    expect(portrait, contains('_buildVisibleVideoFrameCover()'));
    expect(
      portrait,
      contains(
        'Mark the texture visible before the aspect-ratio persist await',
      ),
    );
    expect(
      portrait,
      contains('Only drop the decoded picture once reuse is impossible'),
    );
    final navigation = File(
      'lib/services/playback_navigation_service.dart',
    ).readAsStringSync();
    expect(navigation, contains('_holdPlaybackPageVisibleUntilOwned('));
    // Mini / notification entry used to drop the warmup owner after one frame.
    expect(
      navigation,
      isNot(
        contains(
          'if (warmOnlineVideo) await WidgetsBinding.instance.endOfFrame',
        ),
      ),
    );
  });

  test('library entry primes playback before the page route mounts', () {
    for (final path in <String>[
      'lib/screens/home_screen.dart',
      'lib/screens/collection_screen.dart',
    ]) {
      final source = File(path).readAsStringSync();
      expect(source, contains('primeLibraryPlaybackEntry('));
      expect(source, contains('shouldShowMiniPlaybackCard'));
    }
    expect(
      File('lib/main.dart').readAsStringSync(),
      contains('publishRestoredSessionPreview('),
    );
    expect(
      File('lib/main.dart').readAsStringSync(),
      contains('shouldPrepareNativePlayerOnRestore('),
    );
    expect(
      File('lib/main.dart').readAsStringSync(),
      contains('warmRestoredOnlinePlayback('),
    );
    final home = File('lib/screens/home_screen.dart').readAsStringSync();
    final miniCardRegion = home.substring(
      home.indexOf('MediaLibraryOverlayKeys.miniPlaybackCard'),
    );
    expect(miniCardRegion, contains('shouldShowMiniPlaybackCard'));
    expect(
      home.split('shouldShowMiniPlaybackCard').length,
      greaterThan(3),
      reason:
          'Home Mini card, fill, padding and FAB must all use metadata visibility',
    );
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
