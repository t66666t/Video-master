import 'dart:async';
import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:universal_platform/universal_platform.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

class WindowsVideoPlayerMediaKit {
  static void ensureInitialized() {
    if (!UniversalPlatform.isWindows) {
      return;
    }
    MediaKit.ensureInitialized();
    _WindowsMediaKitVideoPlayer.registerWith();
  }
}

class _WindowsMediaKitVideoPlayer extends VideoPlayerPlatform {
  final _players = HashMap<int, Player>();
  final _completers = HashMap<int, Completer<void>>();
  final _videoControllers = HashMap<int, VideoController>();
  final _streamControllers = HashMap<int, StreamController<VideoEvent>>();
  final _streamSubscriptions = HashMap<int, List<StreamSubscription>>();

  static void registerWith() {
    VideoPlayerPlatform.instance = _WindowsMediaKitVideoPlayer();
  }

  @override
  Future<void> init() async {
    for (final textureId in _players.keys) {
      await dispose(textureId);
    }

    _players.clear();
    _completers.clear();
    _videoControllers.clear();
    _streamControllers.clear();
    _streamSubscriptions.clear();
  }

  @override
  Future<void> dispose(int textureId) async {
    await _players[textureId]?.dispose();

    await _streamControllers[textureId]?.close();
    await Future.wait(
      _streamSubscriptions[textureId]?.map((e) => e.cancel()) ?? [],
    );

    _players.remove(textureId);
    _completers.remove(textureId);
    _videoControllers.remove(textureId);
    _streamControllers.remove(textureId);
    _streamSubscriptions.remove(textureId);
  }

  @override
  Future<int?> create(DataSource dataSource) async {
    final player = Player(
      configuration: const PlayerConfiguration(
        osc: false,
        libass: false,
      ),
    );
    final completer = Completer<void>();
    final videoController = VideoController(player);
    final streamController = StreamController<VideoEvent>();
    final streamSubscriptions = <StreamSubscription>[];

    final textureId = player.hashCode;

    _players[textureId] = player;
    _completers[textureId] = completer;
    _videoControllers[textureId] = videoController;
    _streamControllers[textureId] = streamController;
    _streamSubscriptions[textureId] = streamSubscriptions;

    _initialize(textureId);

    final String resource;
    final Map<String, String> httpHeaders = dataSource.httpHeaders;

    switch (dataSource.sourceType) {
      case DataSourceType.asset:
        final String? asset;
        if (dataSource.package == null) {
          asset = dataSource.asset;
        } else {
          asset = 'packages/${dataSource.package}/${dataSource.asset}';
        }
        resource = 'asset:///$asset';
        break;
      case DataSourceType.network:
      case DataSourceType.file:
      case DataSourceType.contentUri:
        if (dataSource.uri == null) {
          throw ArgumentError('uri must not be null');
        }
        resource = dataSource.uri!;
        break;
      default:
        throw UnsupportedError('${dataSource.sourceType} is not supported');
    }

    await player.open(
      Media(
        resource,
        httpHeaders: httpHeaders,
      ),
      play: false,
    );
    await _disableSubtitleOutput(player);

    return textureId;
  }

  @override
  Stream<VideoEvent> videoEventsFor(int textureId) {
    if (_streamControllers[textureId] == null) {
      throw StateError(
        'VideoPlayer for textureId $textureId is not found, Check if its disposed.',
      );
    }
    return _streamControllers[textureId]!.stream;
  }

  @override
  Future<void> setLooping(int textureId, bool looping) async {
    final playlistMode = looping ? PlaylistMode.single : PlaylistMode.none;
    return _players[textureId]?.setPlaylistMode(playlistMode);
  }

  @override
  Future<void> play(int textureId) async {
    return _players[textureId]?.play();
  }

  @override
  Future<void> pause(int textureId) async {
    return _players[textureId]?.pause();
  }

  @override
  Future<void> setVolume(int textureId, double volume) async {
    return _players[textureId]?.setVolume(volume * 100);
  }

  @override
  Future<void> seekTo(int textureId, Duration position) async {
    return _players[textureId]?.seek(position);
  }

  @override
  Future<void> setPlaybackSpeed(int textureId, double speed) async {
    return _players[textureId]?.setRate(speed);
  }

  @override
  Future<Duration> getPosition(int textureId) async {
    return _players[textureId]?.platform?.state.position ?? Duration.zero;
  }

  @override
  Widget buildView(int textureId) {
    if (_videoControllers[textureId] == null) {
      throw StateError(
        'VideoPlayer for textureId $textureId is not found, Check if its disposed.',
      );
    }
    return Video(
      key: ValueKey(_videoControllers[textureId]!),
      controller: _videoControllers[textureId]!,
      wakelock: false,
      controls: NoVideoControls,
      fill: const Color(0x00000000),
      pauseUponEnteringBackgroundMode: false,
      resumeUponEnteringForegroundMode: false,
    );
  }

  @override
  Future<void> setMixWithOthers(bool mixWithOthers) => Future.value();

  @override
  Future<void> setWebOptions(int textureId, VideoPlayerWebOptions options) =>
      Future.value();

  void _initialize(int textureId) {
    if (_streamSubscriptions[textureId]?.isNotEmpty ?? false) {
      return;
    }

    final player = _players[textureId];
    final completer = _completers[textureId];
    final streamController = _streamControllers[textureId];
    final streamSubscriptions = _streamSubscriptions[textureId];

    if (player != null &&
        completer != null &&
        streamController != null &&
        streamSubscriptions != null) {
      int? width;
      int? height;
      Duration? duration;

      void notify() {
        if (!completer.isCompleted) {
          if (width != null && height != null && duration != null) {
            streamController.add(
              VideoEvent(
                eventType: VideoEventType.initialized,
                size: Size(
                  (width ?? 0) * 1.0,
                  (height ?? 0) * 1.0,
                ),
                duration: player.state.duration,
              ),
            );
            completer.complete();
          }
        }
      }

      streamSubscriptions.add(
        player.stream.duration.listen((event) {
          if (event > Duration.zero) {
            duration = event;
            notify();
          }
        }),
      );
      streamSubscriptions.add(
        player.stream.videoParams.listen((event) {
          width = event.dw;
          height = event.dh;
          if ((width ?? 0) > 0 && (height ?? 0) > 0) {
            notify();
          }
        }),
      );
      streamSubscriptions.add(
        player.stream.tracks.listen((event) {
          if (event.video.length == 2 && event.audio.length > 2) {
            width = 0;
            height = 0;
            notify();
          }
          if (event.subtitle.length > 2) {
            unawaited(_disableSubtitleOutput(player));
          }
        }),
      );
      streamSubscriptions.add(
        player.stream.playing.listen((event) async {
          await completer.future;
          streamController.add(
            VideoEvent(
              eventType: VideoEventType.isPlayingStateUpdate,
              isPlaying: event,
            ),
          );
        }),
      );
      streamSubscriptions.add(
        player.stream.completed.listen((event) async {
          await completer.future;
          if (event) {
            streamController.add(
              VideoEvent(
                eventType: VideoEventType.completed,
              ),
            );
          }
        }),
      );
      streamSubscriptions.add(
        player.stream.buffering.listen((event) async {
          await completer.future;
          streamController.add(
            VideoEvent(
              eventType: event
                  ? VideoEventType.bufferingStart
                  : VideoEventType.bufferingEnd,
            ),
          );
        }),
      );
      streamSubscriptions.add(
        player.stream.buffer.listen((event) async {
          await completer.future;
          streamController.add(
            VideoEvent(
              eventType: VideoEventType.bufferingUpdate,
              buffered: [
                DurationRange(
                  Duration.zero,
                  event,
                ),
              ],
            ),
          );
        }),
      );
      streamSubscriptions.add(
        player.stream.error.listen((event) async {
          await completer.future;
          streamController.addError(
            PlatformException(
              code: '',
              message: event,
            ),
          );
        }),
      );
    }
  }

  Future<void> _disableSubtitleOutput(Player player) async {
    try {
      if (player.state.track.subtitle != SubtitleTrack.no()) {
        await player.setSubtitleTrack(SubtitleTrack.no());
      }
    } catch (_) {
      // Best effort: keep playback working even if subtitle track switching fails.
    }
  }
}
