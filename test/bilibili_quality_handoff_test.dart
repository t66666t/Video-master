import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/bilibili_models.dart';
import 'package:video_player_app/models/media_source_ref.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/bilibili/bilibili_api_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_streaming_service.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/playlist_manager.dart';
import 'package:video_player_app/services/progress_tracker.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

class _QualityApiService extends BilibiliApiService {
  @override
  Future<Map<String, dynamic>?> fetchVideoShot(String bvid, int cid) async =>
      null;

  @override
  Future<BilibiliStreamInfo> fetchPlayUrl(String bvid, int cid) async {
    StreamItem video(int id, String label, int width, int height) => StreamItem(
      id: id,
      baseUrl: 'https://upos-test.bilivideo.com/video-$id.m4s',
      bandwidth: id * 1000,
      codecs: 'avc1.640028',
      codecid: 7,
      mimeType: 'video/mp4',
      qualityName: label,
      width: width,
      height: height,
      frameRate: '30',
      initializationRange: '0-999',
      indexRange: '1000-1999',
    );

    return BilibiliStreamInfo(
      durationMs: const Duration(minutes: 2).inMilliseconds,
      qualityMap: const <int, String>{80: '1080P', 64: '720P'},
      videoStreams: <StreamItem>[
        video(80, '1080P', 1920, 1080),
        video(64, '720P', 1280, 720),
      ],
      audioStreams: <StreamItem>[
        StreamItem(
          id: 30280,
          baseUrl: 'https://upos-test.bilivideo.com/audio.m4s',
          bandwidth: 128000,
          codecs: 'mp4a.40.2',
          codecid: 0,
          mimeType: 'audio/mp4',
          initializationRange: '0-899',
          indexRange: '900-1799',
        ),
      ],
    );
  }
}

class _DelayedQualityApiService extends _QualityApiService {
  final Map<int, Completer<void>> blockers = <int, Completer<void>>{};
  final List<int> requestedCids = <int>[];

  @override
  Future<BilibiliStreamInfo> fetchPlayUrl(String bvid, int cid) async {
    requestedCids.add(cid);
    await (blockers[cid] ??= Completer<void>()).future;
    return super.fetchPlayUrl(bvid, cid);
  }
}

class _HandoffVideoPlatform extends VideoPlayerPlatform {
  final Map<int, StreamController<VideoEvent>> _events =
      <int, StreamController<VideoEvent>>{};
  final Map<int, Duration> _positions = <int, Duration>{};
  final Map<int, DateTime> _positionAnchors = <int, DateTime>{};
  final Map<int, bool> _playing = <int, bool>{};
  final Map<int, double> _rates = <int, double>{};
  final Map<int, int> seekCounts = <int, int>{};
  final Map<int, Duration> seekDelays = <int, Duration>{};
  final Map<int, Duration> lastPausePositions = <int, Duration>{};
  final List<({int playerId, double volume})> volumeCalls =
      <({int playerId, double volume})>[];
  final List<({int playerId, double volume, Duration position})>
  volumeCallPositions = <({int playerId, double volume, Duration position})>[];
  final List<int> disposedPlayerIds = <int>[];
  int _nextPlayerId = 1;

  List<int> get playerIds => _events.keys.toList(growable: false);

  @override
  Future<void> init() async {}

  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    final playerId = _nextPlayerId++;
    _events[playerId] = StreamController<VideoEvent>();
    _positions[playerId] = Duration.zero;
    _positionAnchors[playerId] = DateTime.now();
    _playing[playerId] = false;
    _rates[playerId] = 1.0;
    seekCounts[playerId] = 0;
    return playerId;
  }

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) => _events[playerId]!.stream;

  void initializePlayer(int playerId) {
    _events[playerId]!.add(
      VideoEvent(
        eventType: VideoEventType.initialized,
        duration: const Duration(minutes: 2),
        size: const Size(1920, 1080),
      ),
    );
  }

  void failPlayer(int playerId) {
    _events[playerId]!.addError(
      PlatformException(
        code: 'stream_failed',
        message: 'replacement stream failed',
      ),
    );
  }

  @override
  Future<void> dispose(int playerId) async {
    disposedPlayerIds.add(playerId);
    _positions.remove(playerId);
    _positionAnchors.remove(playerId);
    _playing.remove(playerId);
    _rates.remove(playerId);
    seekCounts.remove(playerId);
    await _events.remove(playerId)?.close();
  }

  @override
  Future<void> play(int playerId) async {
    _anchorPosition(playerId);
    _playing[playerId] = true;
  }

  @override
  Future<void> pause(int playerId) async {
    final position = _currentPosition(playerId);
    _positions[playerId] = position;
    _positionAnchors[playerId] = DateTime.now();
    _playing[playerId] = false;
    lastPausePositions[playerId] = position;
  }

  @override
  Future<void> seekTo(int playerId, Duration position) async {
    seekCounts[playerId] = (seekCounts[playerId] ?? 0) + 1;
    final delay = seekDelays[playerId];
    if (delay != null) await Future<void>.delayed(delay);
    _positions[playerId] = position;
    _positionAnchors[playerId] = DateTime.now();
  }

  @override
  Future<void> setVolume(int playerId, double volume) async {
    volumeCalls.add((playerId: playerId, volume: volume));
    volumeCallPositions.add((
      playerId: playerId,
      volume: volume,
      position: _currentPosition(playerId),
    ));
  }

  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {
    _anchorPosition(playerId);
    _rates[playerId] = speed;
  }

  @override
  Future<Duration> getPosition(int playerId) async =>
      _currentPosition(playerId);

  Duration _currentPosition(int playerId) {
    final base = _positions[playerId] ?? Duration.zero;
    if (_playing[playerId] != true) return base;
    final anchor = _positionAnchors[playerId] ?? DateTime.now();
    final elapsedUs = DateTime.now().difference(anchor).inMicroseconds;
    final rate = _rates[playerId] ?? 1.0;
    return base + Duration(microseconds: (elapsedUs * rate).round());
  }

  void _anchorPosition(int playerId) {
    _positions[playerId] = _currentPosition(playerId);
    _positionAnchors[playerId] = DateTime.now();
  }

  @override
  Future<void> setLooping(int playerId, bool looping) async {}

  @override
  Future<void> setMixWithOthers(bool mixWithOthers) async {}

  @override
  Future<void> setAllowBackgroundPlayback(bool allowBackgroundPlayback) async {}

  @override
  Widget buildView(int playerId) => const SizedBox.shrink();
}

VideoItem _streamItem({
  String id = 'quality-handoff-item',
  int cid = 456,
  int lastPositionMs = 0,
}) => VideoItem(
  id: id,
  path: 'bilibili://stream/BV1xx411c7mD?cid=$cid',
  title: 'Quality hand-off',
  durationMs: 120000,
  lastPositionMs: lastPositionMs,
  lastUpdated: 0,
  sourceRef: MediaSourceRef(
    value: 'BV1xx411c7mD',
    kind: MediaSourceKind.bilibiliStream,
    bvid: 'BV1xx411c7mD',
    cid: cid,
  ),
);

Future<void> _waitForPlayerCount(
  _HandoffVideoPlatform platform,
  int count,
) async {
  for (var attempt = 0; attempt < 200; attempt++) {
    if (platform.playerIds.length == count) return;
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
  expect(platform.playerIds, hasLength(count));
}

Future<void> _waitForPlayerId(
  _HandoffVideoPlatform platform,
  int playerId,
) async {
  for (var attempt = 0; attempt < 200; attempt++) {
    if (platform.playerIds.contains(playerId)) return;
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
  expect(platform.playerIds, contains(playerId));
}

Future<void> _waitForRequestedCid(
  _DelayedQualityApiService api,
  int cid,
) async {
  for (var attempt = 0; attempt < 200; attempt++) {
    if (api.requestedCids.contains(cid)) return;
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
  expect(api.requestedCids, contains(cid));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  test(
    'quality switch keeps the old player until the warm player is ready',
    () async {
      final originalPlatform = VideoPlayerPlatform.instance;
      final platform = _HandoffVideoPlatform();
      VideoPlayerPlatform.instance = platform;
      final streaming = BilibiliStreamingService(_QualityApiService());
      final service = MediaPlaybackService();
      await service.stop();
      await service.initialize(
        playlistManager: PlaylistManager(),
        progressTracker: ProgressTracker(),
        bilibiliStreamingService: streaming,
      );

      addTearDown(() async {
        await service.stop();
        await streaming.shutdown();
        VideoPlayerPlatform.instance = originalPlatform;
      });

      final initialPlay = service.play(_streamItem());
      await _waitForPlayerCount(platform, 1);
      platform.initializePlayer(1);
      await initialPlay;
      await service.seekTo(const Duration(seconds: 24));
      platform.seekDelays[2] = const Duration(milliseconds: 90);

      final qualitySwitch = service.switchBilibiliStreamQuality(64);
      await _waitForPlayerCount(platform, 2);

      expect(service.controller!.playerId, 1);
      expect(service.state, PlaybackState.playing);
      expect(service.position, const Duration(seconds: 24));
      expect(service.selectedStreamQuality?.id, 80);
      expect(platform.disposedPlayerIds, isNot(contains(1)));

      platform.initializePlayer(2);
      final switched = await qualitySwitch;

      expect(switched, isTrue);
      expect(service.controller!.playerId, 2);
      expect(service.state, PlaybackState.playing);
      expect(service.position.inMilliseconds, closeTo(24000, 500));
      expect(service.selectedStreamQuality?.id, 64);
      expect(service.isSwitchingStreamQuality, isFalse);
      expect(platform.volumeCalls, contains((playerId: 2, volume: 0.0)));
      expect(platform.volumeCalls, contains((playerId: 2, volume: 1.0)));
      expect(
        platform.seekCounts[2],
        1,
        reason: 'the replacement must not seek after its warm frame',
      );
      final oldPausePosition = platform.lastPausePositions[1]!;
      final newUnmutePosition = platform.volumeCallPositions
          .lastWhere((call) => call.playerId == 2 && call.volume == 1.0)
          .position;
      expect(
        (newUnmutePosition.inMilliseconds - oldPausePosition.inMilliseconds)
            .abs(),
        lessThanOrEqualTo(90),
      );
      await _waitForPlayerCount(platform, 1);
      expect(platform.playerIds, <int>[2]);

      final preferences = await SharedPreferences.getInstance();
      expect(preferences.getInt('bilibili_stream_preferred_quality'), 64);
    },
  );

  test('paused quality switch stays paused at the same position', () async {
    final originalPlatform = VideoPlayerPlatform.instance;
    final platform = _HandoffVideoPlatform();
    VideoPlayerPlatform.instance = platform;
    final streaming = BilibiliStreamingService(_QualityApiService());
    final service = MediaPlaybackService();
    await service.stop();
    await service.initialize(
      playlistManager: PlaylistManager(),
      progressTracker: ProgressTracker(),
      bilibiliStreamingService: streaming,
    );

    addTearDown(() async {
      await service.stop();
      await streaming.shutdown();
      VideoPlayerPlatform.instance = originalPlatform;
    });

    final initialPlay = service.play(_streamItem());
    await _waitForPlayerCount(platform, 1);
    platform.initializePlayer(1);
    await initialPlay;
    await service.seekTo(const Duration(seconds: 41));
    await service.pause();

    final qualitySwitch = service.switchBilibiliStreamQuality(64);
    await _waitForPlayerCount(platform, 2);
    platform.initializePlayer(2);
    final switched = await qualitySwitch;

    expect(switched, isTrue);
    expect(service.controller!.playerId, 2);
    expect(service.state, PlaybackState.paused);
    expect(service.controller!.value.isPlaying, isFalse);
    expect(service.position.inMilliseconds, closeTo(41000, 500));
    expect(service.selectedStreamQuality?.id, 64);
    await _waitForPlayerCount(platform, 1);
    expect(platform.playerIds, <int>[2]);
  });

  test('a newer playback request cancels a pending quality hand-off', () async {
    final originalPlatform = VideoPlayerPlatform.instance;
    final platform = _HandoffVideoPlatform();
    VideoPlayerPlatform.instance = platform;
    final streaming = BilibiliStreamingService(_QualityApiService());
    final service = MediaPlaybackService();
    await service.stop();
    await service.initialize(
      playlistManager: PlaylistManager(),
      progressTracker: ProgressTracker(),
      bilibiliStreamingService: streaming,
    );

    addTearDown(() async {
      await service.stop();
      await streaming.shutdown();
      VideoPlayerPlatform.instance = originalPlatform;
    });

    final initialPlay = service.play(_streamItem());
    await _waitForPlayerId(platform, 1);
    platform.initializePlayer(1);
    await initialPlay;

    final qualitySwitch = service.switchBilibiliStreamQuality(64);
    await _waitForPlayerId(platform, 2);

    final newerItem = _streamItem(id: 'newer-stream-item');
    final newerPlay = service.play(newerItem);
    await _waitForPlayerId(platform, 3);
    platform.initializePlayer(3);
    await newerPlay;

    platform.initializePlayer(2);
    final switched = await qualitySwitch;

    expect(switched, isFalse);
    expect(service.currentItem?.id, newerItem.id);
    expect(service.controller!.playerId, 3);
    expect(service.state, PlaybackState.playing);
    expect(service.selectedStreamQuality?.id, 80);
    expect(service.isSwitchingStreamQuality, isFalse);
    expect(platform.disposedPlayerIds, contains(2));
  });

  test(
    'failed warm player preserves the active quality and playback',
    () async {
      final originalPlatform = VideoPlayerPlatform.instance;
      final platform = _HandoffVideoPlatform();
      VideoPlayerPlatform.instance = platform;
      final streaming = BilibiliStreamingService(_QualityApiService());
      final service = MediaPlaybackService();
      await service.stop();
      await service.initialize(
        playlistManager: PlaylistManager(),
        progressTracker: ProgressTracker(),
        bilibiliStreamingService: streaming,
      );

      addTearDown(() async {
        await service.stop();
        await streaming.shutdown();
        VideoPlayerPlatform.instance = originalPlatform;
      });

      final initialPlay = service.play(_streamItem());
      await _waitForPlayerCount(platform, 1);
      platform.initializePlayer(1);
      await initialPlay;

      final qualitySwitch = service.switchBilibiliStreamQuality(64);
      await _waitForPlayerCount(platform, 2);
      platform.failPlayer(2);
      final switched = await qualitySwitch;

      expect(switched, isFalse);
      expect(service.controller!.playerId, 1);
      expect(service.state, PlaybackState.playing);
      expect(service.selectedStreamQuality?.id, 80);
      expect(service.isSwitchingStreamQuality, isFalse);
      expect(platform.disposedPlayerIds, contains(2));
      expect(platform.disposedPlayerIds, isNot(contains(1)));

      final preferences = await SharedPreferences.getInstance();
      expect(
        preferences.getInt('bilibili_stream_preferred_quality'),
        isNot(64),
      );
    },
  );

  test(
    'background episode switches keep settings across Bilibili and local media',
    () async {
      final originalPlatform = VideoPlayerPlatform.instance;
      final platform = _HandoffVideoPlatform();
      VideoPlayerPlatform.instance = platform;
      final streaming = BilibiliStreamingService(_QualityApiService());
      final tempDir = await Directory.systemTemp.createTemp(
        'bilibili_mixed_episode_switch_',
      );
      final localFile = File(
        '${tempDir.path}${Platform.pathSeparator}local.mp4',
      );
      await localFile.writeAsBytes(<int>[0]);
      final items = <VideoItem>[
        _streamItem(id: 'online-1', cid: 101, lastPositionMs: 7000),
        _streamItem(id: 'online-2', cid: 102, lastPositionMs: 19000),
        VideoItem(
          id: 'local-3',
          path: localFile.path,
          title: 'Local episode',
          durationMs: 120000,
          lastPositionMs: 31000,
          lastUpdated: 0,
        ),
      ];
      final settings = SettingsService();
      final originalAutoPlay = settings.autoPlayNextVideo;
      settings.autoPlayNextVideo = false;
      final service = MediaPlaybackService();
      await service.stop();
      await service.initialize(
        playlistManager: PlaylistManager()..setPlaylist(items),
        progressTracker: ProgressTracker(),
        bilibiliStreamingService: streaming,
      );

      addTearDown(() async {
        settings.autoPlayNextVideo = originalAutoPlay;
        service.setAppForegroundState(true);
        await service.stop();
        await streaming.shutdown();
        VideoPlayerPlatform.instance = originalPlatform;
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });

      final initialPlay = service.play(items.first, autoPlay: false);
      await _waitForPlayerId(platform, 1);
      platform.initializePlayer(1);
      await initialPlay;
      service.setAppForegroundState(false);

      final onlineToOnline = service.playNext();
      await _waitForPlayerId(platform, 2);
      platform.initializePlayer(2);
      await onlineToOnline;
      expect(service.currentItem?.id, 'online-2');
      expect(service.position, const Duration(seconds: 19));
      expect(service.state, PlaybackState.paused);
      expect(service.desiredPlaying, isFalse);

      await service.resume();
      expect(service.state, PlaybackState.playing);
      settings.autoPlayNextVideo = true;

      final onlineToLocal = service.playNext();
      await _waitForPlayerId(platform, 3);
      platform.initializePlayer(3);
      await onlineToLocal;
      expect(service.currentItem?.id, 'local-3');
      expect(service.position, const Duration(seconds: 31));
      expect(service.state, PlaybackState.playing);
      expect(service.desiredPlaying, isTrue);

      final localToOnline = service.playPrevious();
      await _waitForPlayerId(platform, 4);
      platform.initializePlayer(4);
      await localToOnline;
      expect(service.currentItem?.id, 'online-2');
      expect(service.position, const Duration(seconds: 19));
      expect(service.state, PlaybackState.playing);
      expect(service.desiredPlaying, isTrue);
    },
  );

  test(
    'Bilibili completion resumes saved progress or restarts from zero by setting',
    () async {
      final originalPlatform = VideoPlayerPlatform.instance;
      final platform = _HandoffVideoPlatform();
      VideoPlayerPlatform.instance = platform;
      final streaming = BilibiliStreamingService(_QualityApiService());
      final items = <VideoItem>[
        _streamItem(id: 'completion-online-1', cid: 201),
        _streamItem(id: 'completion-online-2', cid: 202, lastPositionMs: 23000),
      ];
      final settings = SettingsService();
      final originalAutoPlay = settings.autoPlayNextVideo;
      final originalCompletion = settings.autoPlayOnCompletion;
      final originalFromStart = settings.autoPlayOnCompletionFromStart;
      settings.autoPlayNextVideo = false;
      settings.autoPlayOnCompletion = true;
      settings.autoPlayOnCompletionFromStart = false;
      final service = MediaPlaybackService();
      await service.stop();
      await service.initialize(
        playlistManager: PlaylistManager()..setPlaylist(items),
        progressTracker: ProgressTracker(),
        bilibiliStreamingService: streaming,
      );

      addTearDown(() async {
        settings.autoPlayNextVideo = originalAutoPlay;
        settings.autoPlayOnCompletion = originalCompletion;
        settings.autoPlayOnCompletionFromStart = originalFromStart;
        await service.stop();
        await streaming.shutdown();
        VideoPlayerPlatform.instance = originalPlatform;
      });

      final initialPlay = service.play(items.first);
      await _waitForPlayerId(platform, 1);
      platform.initializePlayer(1);
      await initialPlay;
      var controller = service.controller!;
      platform._positions[1] = const Duration(minutes: 2);
      controller.value = controller.value.copyWith(
        position: const Duration(minutes: 2),
        duration: const Duration(minutes: 2),
        isPlaying: false,
      );

      await _waitForPlayerId(platform, 2);
      platform.initializePlayer(2);
      for (
        var i = 0;
        i < 300 &&
            (service.currentItem?.id != items[1].id ||
                service.state != PlaybackState.playing ||
                service.position != const Duration(seconds: 23));
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
      expect(service.currentItem?.id, items[1].id);
      expect(service.position, const Duration(seconds: 23));
      expect(service.state, PlaybackState.playing);

      settings.autoPlayOnCompletionFromStart = true;
      controller = service.controller!;
      controller.value = controller.value.copyWith(
        position: const Duration(seconds: 23),
        duration: const Duration(minutes: 2),
        isPlaying: true,
      );
      service.updatePlaybackStateFromController(
        expectedItemId: items[1].id,
        expectedController: controller,
      );
      platform._positions[2] = const Duration(minutes: 2);
      controller.value = controller.value.copyWith(
        position: const Duration(minutes: 2),
        duration: const Duration(minutes: 2),
        isPlaying: false,
      );

      await _waitForPlayerId(platform, 3);
      platform.initializePlayer(3);
      for (
        var i = 0;
        i < 300 &&
            (service.currentItem?.id != items.first.id ||
                service.state != PlaybackState.playing);
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
      expect(service.currentItem?.id, items.first.id);
      expect(service.position, Duration.zero);
      expect(service.state, PlaybackState.playing);
    },
  );

  test(
    'superseded Bilibili preparation releases its gateway session',
    () async {
      final originalPlatform = VideoPlayerPlatform.instance;
      final platform = _HandoffVideoPlatform();
      VideoPlayerPlatform.instance = platform;
      final api = _DelayedQualityApiService();
      final streaming = BilibiliStreamingService(api);
      final service = MediaPlaybackService();
      await service.stop();
      await service.initialize(
        playlistManager: PlaylistManager(),
        progressTracker: ProgressTracker(),
        bilibiliStreamingService: streaming,
      );

      addTearDown(() async {
        for (final blocker in api.blockers.values) {
          if (!blocker.isCompleted) blocker.complete();
        }
        await service.stop();
        await streaming.shutdown();
        VideoPlayerPlatform.instance = originalPlatform;
      });

      final firstItem = _streamItem(id: 'superseded-online', cid: 301);
      final secondItem = _streamItem(id: 'committed-online', cid: 302);
      final firstPlay = service.play(firstItem, autoPlay: false);
      await _waitForRequestedCid(api, 301);

      final secondPlay = service.play(secondItem, autoPlay: false);
      await _waitForRequestedCid(api, 302);
      api.blockers[302]!.complete();
      await _waitForPlayerId(platform, 1);
      platform.initializePlayer(1);
      await secondPlay;

      api.blockers[301]!.complete();
      await firstPlay;
      expect(service.currentItem?.id, secondItem.id);
      expect(streaming.activePlaybackSessionCount, 1);

      await service.stop();
      expect(streaming.activePlaybackSessionCount, 0);
    },
  );
}
