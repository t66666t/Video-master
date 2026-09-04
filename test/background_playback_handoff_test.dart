import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/services/media_playback_service.dart';

void main() {
  test('headless background video is playback-ready without a UI texture', () {
    expect(
      MediaPlaybackService.playbackRequestNeedsVideoOutput(
        isVideo: true,
        hasVisiblePlaybackPage: false,
      ),
      isFalse,
    );
    expect(
      MediaPlaybackService.playbackRequestNeedsVideoOutput(
        isVideo: true,
        hasVisiblePlaybackPage: true,
      ),
      isTrue,
    );
    expect(
      MediaPlaybackService.playbackRequestNeedsVideoOutput(
        isVideo: false,
        hasVisiblePlaybackPage: true,
      ),
      isFalse,
    );
  });

  test('foreground handoff attaches first and only reopens after failure', () {
    final serviceSource = File(
      'lib/services/media_playback_service.dart',
    ).readAsStringSync();
    final methodStart = serviceSource.indexOf(
      'Future<bool> ensureVisibleVideoOutput',
    );
    final methodEnd = serviceSource.indexOf(
      '/// Whether an item can be opened',
      methodStart,
    );
    expect(methodStart, greaterThanOrEqualTo(0));
    expect(methodEnd, greaterThan(methodStart));
    final method = serviceSource.substring(methodStart, methodEnd);
    final attach = method.indexOf('attachVideoOutputFor');
    final attachFailed = method.indexOf('visible output attachment failed');
    final reopen = method.indexOf('reopening media with preserved position');
    expect(attach, greaterThanOrEqualTo(0));
    // The primary path is still a zero-reload attachment to the existing
    // native player; the reopen fallback must exist only after the explicit
    // attachment-failure marker.
    expect(attachFailed, greaterThan(attach));
    expect(reopen, greaterThan(attachFailed));
    final beforeFailure = method.substring(0, attachFailed);
    expect(beforeFailure, isNot(contains('await play(')));
    expect(beforeFailure, isNot(contains('forceRecreate: true')));
    // A reopen during an in-flight episode switch would cancel the switch, so
    // the fallback must be guarded by the media-switch busy check.
    expect(
      method.indexOf('isEpisodeNavigationBusy'),
      greaterThan(attachFailed),
    );
    expect(method.indexOf('isEpisodeNavigationBusy'), lessThan(reopen));

    final platformSource = File(
      'lib/platform/windows_video_player_media_kit.dart',
    ).readAsStringSync();
    final attachStart = platformSource.indexOf(
      'Future<bool> _attachVideoOutputFor',
    );
    final attachEnd = platformSource.indexOf(
      'Future<bool>? _playbackReadyFor',
      attachStart,
    );
    final attachMethod = platformSource.substring(attachStart, attachEnd);
    expect(attachMethod, contains('_players[textureId]'));
    expect(attachMethod, contains('_videoControllers[textureId]'));
    expect(attachMethod, isNot(contains('player.open(')));
    expect(attachMethod, isNot(contains('player.seek(')));
  });

  test('notification skip ignores duplicate callbacks while active', () {
    final source = File(
      'lib/services/system_media_session_service.dart',
    ).readAsStringSync();
    expect(source, contains('bool _episodeSkipInFlight = false;'));
    expect(source, contains('await _handleSingleEpisodeSkip(isNext: true);'));
    expect(source, contains('await _handleSingleEpisodeSkip(isNext: false);'));
    expect(source, contains('if (_episodeSkipInFlight)'));
    expect(
      source,
      contains('await _runSerialized(() => _handleQueueSkip(isNext: isNext));'),
    );
    expect(source, contains('await playbackService.playNext();'));
    expect(source, contains('await playbackService.playPrevious();'));
  });

  test('background output priming attaches to the existing player', () {
    final source = File(
      'lib/services/media_playback_service.dart',
    ).readAsStringSync();
    final start = source.indexOf('void _primeDeferredVideoOutput');
    final end = source.indexOf('Future<bool> ensureVisibleVideoOutput', start);
    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));
    final method = source.substring(start, end);
    expect(method, contains('attachVideoOutputFor'));
    expect(method, isNot(contains('play(')));
    expect(method, isNot(contains('seek')));
  });

  test('programmatic notification navigation cannot auto-pause playback', () {
    for (final path in <String>[
      'lib/screens/portrait_video_screen.dart',
      'lib/screens/video_player_screen.dart',
    ]) {
      final source = File(path).readAsStringSync();
      expect(source, contains('bool _explicitPlaybackExitRequested = false;'));
      expect(
        RegExp(
          r'_explicitPlaybackExitRequested\s*&&\s*!suppressRouteCleanup',
        ).hasMatch(source),
        isTrue,
        reason: '$path may pause only after an explicit user exit',
      );
    }
  });
}
