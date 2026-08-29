import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/playlist_manager.dart';
import 'package:video_player_app/services/progress_tracker.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

class _ControlledVideoPlatform extends VideoPlayerPlatform {
  final Map<int, StreamController<VideoEvent>> _events = {};
  int _nextPlayerId = 1;
  final List<double> playbackSpeedCalls = <double>[];
  final List<Completer<void>> _playbackSpeedBlockers = <Completer<void>>[];
  int activePlaybackSpeedCalls = 0;
  int maxConcurrentPlaybackSpeedCalls = 0;

  List<int> get playerIds => _events.keys.toList(growable: false);

  @override
  Future<void> init() async {}

  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    final id = _nextPlayerId++;
    _events[id] = StreamController<VideoEvent>();
    return id;
  }

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) => _events[playerId]!.stream;

  void initializePlayer(int playerId) {
    _events[playerId]!.add(
      VideoEvent(
        eventType: VideoEventType.initialized,
        duration: const Duration(minutes: 1),
        size: const Size(1920, 1080),
      ),
    );
  }

  void failPlayer(int playerId) {
    _events[playerId]!.addError(
      PlatformException(code: 'initialize_failed', message: 'failed'),
    );
  }

  @override
  Future<void> dispose(int playerId) async {
    await _events.remove(playerId)?.close();
  }

  @override
  Future<void> play(int playerId) async {}

  @override
  Future<void> pause(int playerId) async {}

  @override
  Future<void> seekTo(int playerId, Duration position) async {}

  @override
  Future<void> setVolume(int playerId, double volume) async {}

  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {
    playbackSpeedCalls.add(speed);
    activePlaybackSpeedCalls++;
    if (activePlaybackSpeedCalls > maxConcurrentPlaybackSpeedCalls) {
      maxConcurrentPlaybackSpeedCalls = activePlaybackSpeedCalls;
    }
    try {
      if (_playbackSpeedBlockers.isNotEmpty) {
        await _playbackSpeedBlockers.removeAt(0).future;
      }
    } finally {
      activePlaybackSpeedCalls--;
    }
  }

  Completer<void> blockNextPlaybackSpeedCall() {
    final blocker = Completer<void>();
    _playbackSpeedBlockers.add(blocker);
    return blocker;
  }

  @override
  Future<Duration> getPosition(int playerId) async => Duration.zero;

  @override
  Future<void> setLooping(int playerId, bool looping) async {}

  @override
  Future<void> setMixWithOthers(bool mixWithOthers) async {}

  @override
  Future<void> setAllowBackgroundPlayback(bool allowBackgroundPlayback) async {}

  @override
  Widget buildView(int playerId) => const SizedBox.shrink();
}

Future<void> _waitForPlayers(
  _ControlledVideoPlatform platform,
  int count,
) async {
  for (var i = 0; i < 100 && platform.playerIds.length < count; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  expect(platform.playerIds, hasLength(count));
}

Future<void> _waitForPlayerId(
  _ControlledVideoPlatform platform,
  int playerId,
) async {
  for (var i = 0; i < 100 && !platform.playerIds.contains(playerId); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  expect(platform.playerIds, contains(playerId));
}

Future<void> _waitForNoPlayers(_ControlledVideoPlatform platform) async {
  for (var i = 0; i < 100 && platform.playerIds.isNotEmpty; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  expect(platform.playerIds, isEmpty);
}

Future<void> _waitForPlaybackSpeedCalls(
  _ControlledVideoPlatform platform,
  int count,
) async {
  for (var i = 0; i < 100 && platform.playbackSpeedCalls.length < count; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  expect(platform.playbackSpeedCalls, hasLength(count));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues(<String, Object>{});

  test(
    'temporary playback speed commands are serialized and restored',
    () async {
      final originalPlatform = VideoPlayerPlatform.instance;
      final platform = _ControlledVideoPlatform();
      VideoPlayerPlatform.instance = platform;
      final tempDir = await Directory.systemTemp.createTemp(
        'temporary_playback_speed_test_',
      );
      final video = File('${tempDir.path}${Platform.pathSeparator}video.mp4');
      await video.writeAsBytes(<int>[0]);

      final service = MediaPlaybackService();
      await service.cancelPendingPlay();
      addTearDown(() async {
        await service.cancelPendingPlay();
        VideoPlayerPlatform.instance = originalPlatform;
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });

      await service.initialize(
        playlistManager: PlaylistManager(),
        progressTracker: ProgressTracker(),
      );
      final play = service.play(
        VideoItem(
          id: 'temporary-speed',
          path: video.path,
          title: 'Temporary speed',
          durationMs: 0,
          lastUpdated: 0,
        ),
      );
      await _waitForPlayers(platform, 1);
      platform.initializePlayer(platform.playerIds.single);
      await play;
      platform.playbackSpeedCalls.clear();
      platform.maxConcurrentPlaybackSpeedCalls = 0;
      var temporarySpeedNotifications = 0;
      void countTemporarySpeedNotification() {
        temporarySpeedNotifications++;
      }

      service.addListener(countTemporarySpeedNotification);
      addTearDown(
        () => service.removeListener(countTemporarySpeedNotification),
      );

      final blocker = platform.blockNextPlaybackSpeedCall();
      final begin = service.beginTemporaryPlaybackSpeed(2.0);
      await _waitForPlaybackSpeedCalls(platform, 1);
      expect(service.confirmedPlaybackSpeed, 1.0);
      expect(service.isTemporaryPlaybackSpeedActive, isTrue);

      final end = service.endTemporaryPlaybackSpeed();
      await Future<void>.delayed(Duration.zero);
      expect(platform.playbackSpeedCalls, <double>[2.0]);
      expect(platform.maxConcurrentPlaybackSpeedCalls, 1);

      blocker.complete();
      await begin;
      await end;

      expect(platform.playbackSpeedCalls, <double>[2.0, 1.0]);
      expect(platform.maxConcurrentPlaybackSpeedCalls, 1);
      expect(service.confirmedPlaybackSpeed, 1.0);
      expect(service.playbackSpeed, 1.0);
      expect(service.isTemporaryPlaybackSpeedActive, isFalse);
      expect(temporarySpeedNotifications, 0);
    },
  );

  test('a released long press is coalesced before native dispatch', () async {
    final originalPlatform = VideoPlayerPlatform.instance;
    final platform = _ControlledVideoPlatform();
    VideoPlayerPlatform.instance = platform;
    final tempDir = await Directory.systemTemp.createTemp(
      'coalesced_playback_speed_test_',
    );
    final video = File('${tempDir.path}${Platform.pathSeparator}video.mp4');
    await video.writeAsBytes(<int>[0]);

    final service = MediaPlaybackService();
    await service.cancelPendingPlay();
    addTearDown(() async {
      await service.cancelPendingPlay();
      VideoPlayerPlatform.instance = originalPlatform;
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    });

    await service.initialize(
      playlistManager: PlaylistManager(),
      progressTracker: ProgressTracker(),
    );
    final play = service.play(
      VideoItem(
        id: 'coalesced-speed',
        path: video.path,
        title: 'Coalesced speed',
        durationMs: 0,
        lastUpdated: 0,
      ),
    );
    await _waitForPlayers(platform, 1);
    platform.initializePlayer(platform.playerIds.single);
    await play;
    platform.playbackSpeedCalls.clear();

    final begin = service.beginTemporaryPlaybackSpeed(2.0);
    final end = service.endTemporaryPlaybackSpeed();
    await Future.wait(<Future<void>>[begin, end]);

    expect(platform.playbackSpeedCalls, isEmpty);
    expect(service.confirmedPlaybackSpeed, 1.0);
    expect(service.playbackSpeed, 1.0);
  });

  test(
    'foreground resume re-anchors the shared presentation position',
    () async {
      final originalPlatform = VideoPlayerPlatform.instance;
      final platform = _ControlledVideoPlatform();
      VideoPlayerPlatform.instance = platform;
      final tempDir = await Directory.systemTemp.createTemp(
        'foreground_position_resync_test_',
      );
      final video = File('${tempDir.path}${Platform.pathSeparator}video.mp4');
      await video.writeAsBytes(<int>[0]);

      final service = MediaPlaybackService();
      await service.cancelPendingPlay();
      addTearDown(() async {
        service.handleAppLifecycleState(AppLifecycleState.resumed);
        await service.cancelPendingPlay();
        VideoPlayerPlatform.instance = originalPlatform;
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });

      await service.initialize(
        playlistManager: PlaylistManager(),
        progressTracker: ProgressTracker(),
      );
      final play = service.play(
        VideoItem(
          id: 'foreground-position-resync',
          path: video.path,
          title: 'Foreground position resync',
          durationMs: 0,
          lastUpdated: 0,
        ),
      );
      await _waitForPlayers(platform, 1);
      platform.initializePlayer(platform.playerIds.single);
      await play;

      service.handleAppLifecycleState(AppLifecycleState.paused);
      final controller = service.controller!;
      controller.value = controller.value.copyWith(
        position: const Duration(seconds: 20),
        isPlaying: true,
      );

      // Native/coarse playback can advance while the Flutter frame ticker is
      // suspended. The shared presentation clock must catch up immediately
      // when the app becomes visible again.
      expect(
        service.positionNotifier.value,
        isNot(const Duration(seconds: 20)),
      );
      service.handleAppLifecycleState(AppLifecycleState.resumed);

      expect(service.position, const Duration(seconds: 20));
      expect(
        service.positionNotifier.value.inMilliseconds,
        closeTo(const Duration(seconds: 20).inMilliseconds, 50),
      );
      expect(
        service.coarsePositionNotifier.value.inMilliseconds,
        closeTo(const Duration(seconds: 20).inMilliseconds, 50),
      );
    },
  );

  test(
    'a stale initialization failure cannot overwrite newer playback',
    () async {
      final originalPlatform = VideoPlayerPlatform.instance;
      final platform = _ControlledVideoPlatform();
      VideoPlayerPlatform.instance = platform;
      final tempDir = await Directory.systemTemp.createTemp(
        'media_playback_request_race_test_',
      );
      addTearDown(() async {
        VideoPlayerPlatform.instance = originalPlatform;
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });

      final firstFile = File(
        '${tempDir.path}${Platform.pathSeparator}first.mp4',
      );
      final secondFile = File(
        '${tempDir.path}${Platform.pathSeparator}second.mp4',
      );
      final thirdFile = File(
        '${tempDir.path}${Platform.pathSeparator}third.mp4',
      );
      await firstFile.writeAsBytes(<int>[0]);
      await secondFile.writeAsBytes(<int>[0]);
      await thirdFile.writeAsBytes(<int>[0]);

      final service = MediaPlaybackService();
      await service.cancelPendingPlay();
      await service.initialize(
        playlistManager: PlaylistManager(),
        progressTracker: ProgressTracker(),
      );
      final firstItem = VideoItem(
        id: 'first',
        path: firstFile.path,
        title: 'First',
        durationMs: 0,
        lastUpdated: 0,
      );
      final secondItem = VideoItem(
        id: 'second',
        path: secondFile.path,
        title: 'Second',
        durationMs: 0,
        lastUpdated: 0,
      );

      final firstPlay = service.play(firstItem);
      await _waitForPlayers(platform, 1);
      final secondPlay = service.play(secondItem);
      await _waitForPlayers(platform, 2);

      platform.initializePlayer(platform.playerIds[1]);
      await secondPlay;
      expect(service.currentItem?.id, 'second');
      expect(service.state, PlaybackState.playing);

      platform.failPlayer(platform.playerIds[0]);
      await firstPlay;
      expect(service.currentItem?.id, 'second');
      expect(service.state, PlaybackState.playing);

      await service.seekTo(const Duration(seconds: 37));
      expect(service.position, const Duration(seconds: 37));

      final thirdItem = VideoItem(
        id: 'third',
        path: thirdFile.path,
        title: 'Third',
        durationMs: const Duration(minutes: 2).inMilliseconds,
        lastPositionMs: 0,
        lastUpdated: 0,
      );
      final thirdPlay = service.play(thirdItem);

      // The loading notification must never combine the new item identity
      // with the previous item's timeline (the visible one-frame progress bug).
      expect(service.currentItem?.id, 'third');
      expect(service.state, PlaybackState.loading);
      expect(service.position, Duration.zero);
      expect(service.duration, const Duration(minutes: 2));

      await _waitForPlayerId(platform, 3);
      platform.initializePlayer(3);
      await thirdPlay;
    },
  );

  test(
    'episode navigation defaults to the persisted auto-play setting',
    () async {
      final originalPlatform = VideoPlayerPlatform.instance;
      final platform = _ControlledVideoPlatform();
      VideoPlayerPlatform.instance = platform;
      final tempDir = await Directory.systemTemp.createTemp(
        'episode_navigation_autoplay_test_',
      );
      final firstFile = File(
        '${tempDir.path}${Platform.pathSeparator}first.mp4',
      );
      final secondFile = File(
        '${tempDir.path}${Platform.pathSeparator}second.mp4',
      );
      await firstFile.writeAsBytes(<int>[0]);
      await secondFile.writeAsBytes(<int>[0]);

      final settings = SettingsService();
      final originalAutoPlay = settings.autoPlayNextVideo;
      final playlist = PlaylistManager();
      final service = MediaPlaybackService();
      await service.stop();
      await service.initialize(
        playlistManager: playlist,
        progressTracker: ProgressTracker(),
      );
      final items = <VideoItem>[
        VideoItem(
          id: 'autoplay-first',
          path: firstFile.path,
          title: 'First',
          durationMs: 0,
          lastUpdated: 0,
        ),
        VideoItem(
          id: 'autoplay-second',
          path: secondFile.path,
          title: 'Second',
          durationMs: 0,
          lastUpdated: 0,
        ),
      ];
      playlist.setPlaylist(items);

      addTearDown(() async {
        settings.autoPlayNextVideo = originalAutoPlay;
        await service.stop();
        await _waitForNoPlayers(platform);
        VideoPlayerPlatform.instance = originalPlatform;
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });

      final initialPlay = service.play(items.first, autoPlay: false);
      await _waitForPlayers(platform, 1);
      platform.initializePlayer(platform.playerIds.single);
      await initialPlay;
      expect(service.state, PlaybackState.paused);

      settings.autoPlayNextVideo = true;
      final next = service.playNext();
      await _waitForPlayerId(platform, 2);
      platform.initializePlayer(2);
      await next;
      expect(service.currentItem?.id, 'autoplay-second');
      expect(service.state, PlaybackState.playing);

      settings.autoPlayNextVideo = false;
      final previous = service.playPrevious();
      await _waitForPlayerId(platform, 3);
      platform.initializePlayer(3);
      await previous;
      expect(service.currentItem?.id, 'autoplay-first');
      expect(service.state, PlaybackState.paused);
    },
  );

  test('subtitle hand-off repairs a primary-only service snapshot', () async {
    final originalPlatform = VideoPlayerPlatform.instance;
    final platform = _ControlledVideoPlatform();
    VideoPlayerPlatform.instance = platform;
    final tempDir = await Directory.systemTemp.createTemp(
      'subtitle_handoff_test_',
    );
    addTearDown(() async {
      VideoPlayerPlatform.instance = originalPlatform;
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    });

    final video = File('${tempDir.path}${Platform.pathSeparator}video.mp4');
    final primary = File('${tempDir.path}${Platform.pathSeparator}primary.srt');
    final secondary = File(
      '${tempDir.path}${Platform.pathSeparator}secondary.srt',
    );
    await video.writeAsBytes(<int>[0]);
    await primary.writeAsString('1\n00:00:00,000 --> 00:00:02,000\nPrimary\n');
    await secondary.writeAsString(
      '1\n00:00:00,000 --> 00:00:02,000\nSecondary\n',
    );

    final service = MediaPlaybackService();
    await service.initialize(
      playlistManager: PlaylistManager(),
      progressTracker: ProgressTracker(),
    );
    final item = VideoItem(
      id: 'handoff',
      path: video.path,
      title: 'Handoff',
      durationMs: 0,
      lastUpdated: 0,
      subtitlePath: primary.path,
      secondarySubtitlePath: secondary.path,
    );
    final play = service.play(item);
    await _waitForPlayers(platform, 1);

    // Known external subtitles must not sit behind native player
    // initialization. The playback platform is still deliberately blocked.
    for (var i = 0; i < 100 && service.subtitlePaths.length < 2; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    expect(service.state, PlaybackState.loading);
    expect(service.subtitlePaths, <String>[primary.path, secondary.path]);
    expect(service.subtitles.single.text, 'Primary');
    expect(service.secondarySubtitles.single.text, 'Secondary');

    platform.initializePlayer(platform.playerIds.single);
    await play;

    await service.loadSubtitlePathsForCurrentItem(
      itemId: item.id,
      paths: <String>[primary.path],
    );
    expect(service.subtitlePaths, hasLength(1));
    expect(service.secondarySubtitles, isEmpty);

    final committed = await service.ensureSubtitlePathsForCurrentItem(
      itemId: item.id,
      paths: <String>[primary.path, secondary.path],
    );
    expect(committed, isTrue);
    expect(service.subtitlePaths, <String>[primary.path, secondary.path]);
    expect(service.subtitles.single.text, 'Primary');
    expect(service.secondarySubtitles.single.text, 'Secondary');
  });
}
