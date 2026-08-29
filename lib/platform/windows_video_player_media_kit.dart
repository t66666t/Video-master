import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:universal_platform/universal_platform.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

import 'pitch_preserving_audio_pipeline.dart';
import '../services/settings_service.dart';

class NativeVideoPlayerMediaKit {
  /// Private transport metadata understood only by this native video_player
  /// adapter. It is stripped before any HTTP request is sent.
  static const String externalAudioSourceHeader =
      'x-fluent-player-external-audio-source';

  static bool get supportsHardwareVideoDecodingControl =>
      UniversalPlatform.isAndroid ||
      UniversalPlatform.isIOS ||
      UniversalPlatform.isMacOS ||
      UniversalPlatform.isWindows ||
      UniversalPlatform.isLinux;

  static void ensureInitialized() {
    if (!supportsHardwareVideoDecodingControl) {
      return;
    }
    MediaKit.ensureInitialized();
    _NativeMediaKitVideoPlayer.registerWith();
  }

  /// Returns media_kit's native presentation-position samples for the
  /// controller identified by [playerId]. The samples are intentionally kept
  /// separate from video_player's comparatively coarse ValueNotifier updates:
  /// frame-driven overlays use them to detect drift, never as animation ticks.
  static Stream<Duration>? positionStreamFor(int playerId) {
    return _NativeMediaKitVideoPlayer.registeredInstance?._positionStreamFor(
      playerId,
    );
  }

  /// Returns each rate after libmpv has accepted it. Frame-driven overlays use
  /// this to share the player's exact media-time slope.
  static Stream<double>? rateStreamFor(int playerId) {
    return _NativeMediaKitVideoPlayer.registeredInstance?._rateStreamFor(
      playerId,
    );
  }

  /// Invalidates a queued rate request. A command already accepted by libmpv
  /// cannot be recalled, but the replacement request will run immediately
  /// after it instead of overlapping it.
  static void cancelPendingRateChange(int playerId) {
    _NativeMediaKitVideoPlayer.registeredInstance?._cancelPendingRateChange(
      playerId,
    );
  }

  /// Returns the explicit libmpv decoder policy used for a new player.
  /// `auto-safe` is media_kit's supported Android default; the other native
  /// backends use libmpv's `auto` probing. These values let libmpv fall back
  /// when it can reject an unsupported decoder up front. Some Android codec
  /// implementations fail only after MediaCodec has been selected, so the
  /// platform wrapper also performs one explicit software retry in that case.
  @visibleForTesting
  static String decoderOptionFor({
    required bool useHardwareDecoding,
    required String operatingSystem,
  }) {
    if (!useHardwareDecoding) return 'no';
    return operatingSystem == 'android' ? 'auto-safe' : 'auto';
  }

  @visibleForTesting
  static bool shouldRetryAndroidSoftwareDecoding({
    required bool useHardwareDecoding,
    required String operatingSystem,
    required bool firstFrameRendered,
    required bool fallbackAttempted,
  }) {
    return operatingSystem == 'android' &&
        useHardwareDecoding &&
        !firstFrameRendered &&
        !fallbackAttempted;
  }

  /// Caps a decoded texture to the actual Flutter view while retaining its
  /// aspect ratio. There is no quality benefit in moving a 4K texture through
  /// Flutter when the window can display only 1080p worth of physical pixels.
  @visibleForTesting
  static Size adaptiveTextureSize({
    required Size source,
    required Size physicalViewport,
  }) {
    if (source.width <= 0 ||
        source.height <= 0 ||
        physicalViewport.width <= 0 ||
        physicalViewport.height <= 0) {
      return source;
    }
    final scale = math.min(
      1.0,
      math.min(
        physicalViewport.width / source.width,
        physicalViewport.height / source.height,
      ),
    );
    if (scale >= 1.0) return source;

    int evenFloor(double value) {
      final floored = math.max(2, value.floor());
      return floored.isEven ? floored : floored - 1;
    }

    return Size(
      evenFloor(source.width * scale).toDouble(),
      evenFloor(source.height * scale).toDouble(),
    );
  }
}

class _NativeMediaKitVideoPlayer extends VideoPlayerPlatform
    with WidgetsBindingObserver {
  static _NativeMediaKitVideoPlayer? registeredInstance;

  final _players = HashMap<int, Player>();
  final _completers = HashMap<int, Completer<void>>();
  final _videoControllers = HashMap<int, VideoController>();
  final _streamControllers = HashMap<int, StreamController<VideoEvent>>();
  final _rateStreamControllers = HashMap<int, StreamController<double>>();
  final _streamSubscriptions = HashMap<int, List<StreamSubscription>>();
  final _rateRequestEpochs = HashMap<int, int>();
  final _rateCommands = HashMap<int, Future<void>>();
  final _sourceVideoSizes = HashMap<int, Size>();
  final _outputVideoSizes = HashMap<int, Size>();
  final _resizeEpochs = HashMap<int, int>();
  final _frameDropModes = HashMap<int, String>();
  final _decoderFallbackStates = HashMap<int, _DecoderFallbackState>();

  static void registerWith() {
    final previous = registeredInstance;
    if (previous != null) {
      WidgetsBinding.instance.removeObserver(previous);
    }
    final instance = _NativeMediaKitVideoPlayer();
    registeredInstance = instance;
    VideoPlayerPlatform.instance = instance;
    WidgetsBinding.instance.addObserver(instance);
  }

  @override
  void didChangeMetrics() {
    for (final entry in _sourceVideoSizes.entries) {
      _scheduleAdaptiveOutputResize(entry.key, entry.value);
    }
  }

  Stream<Duration>? _positionStreamFor(int textureId) {
    return _players[textureId]?.stream.position;
  }

  Stream<double>? _rateStreamFor(int textureId) {
    return _rateStreamControllers[textureId]?.stream;
  }

  void _cancelPendingRateChange(int textureId) {
    _rateRequestEpochs[textureId] = (_rateRequestEpochs[textureId] ?? 0) + 1;
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
    _rateStreamControllers.clear();
    _streamSubscriptions.clear();
    _rateRequestEpochs.clear();
    _rateCommands.clear();
    _sourceVideoSizes.clear();
    _outputVideoSizes.clear();
    _resizeEpochs.clear();
    _frameDropModes.clear();
    for (final state in _decoderFallbackStates.values) {
      state.dispose();
    }
    _decoderFallbackStates.clear();
  }

  @override
  Future<void> dispose(int textureId) async {
    _cancelPendingRateChange(textureId);
    _decoderFallbackStates.remove(textureId)?.dispose();
    try {
      await _rateCommands[textureId];
    } catch (_) {}
    await _players[textureId]?.dispose();

    await _streamControllers[textureId]?.close();
    await _rateStreamControllers[textureId]?.close();
    await Future.wait(
      _streamSubscriptions[textureId]?.map((e) => e.cancel()) ?? [],
    );

    _players.remove(textureId);
    _completers.remove(textureId);
    _videoControllers.remove(textureId);
    _streamControllers.remove(textureId);
    _rateStreamControllers.remove(textureId);
    _streamSubscriptions.remove(textureId);
    _rateRequestEpochs.remove(textureId);
    _rateCommands.remove(textureId);
    _sourceVideoSizes.remove(textureId);
    _outputVideoSizes.remove(textureId);
    _resizeEpochs.remove(textureId);
    _frameDropModes.remove(textureId);
  }

  @override
  Future<int?> create(DataSource dataSource) async {
    final player = Player(
      configuration: const PlayerConfiguration(
        osc: false,
        libass: false,
        pitch: false,
      ),
    );
    final completer = Completer<void>();
    final useHardwareDecoding = SettingsService().useHardwareVideoDecoding;
    final videoController = VideoController(
      player,
      configuration: VideoControllerConfiguration(
        hwdec: NativeVideoPlayerMediaKit.decoderOptionFor(
          useHardwareDecoding: useHardwareDecoding,
          operatingSystem: UniversalPlatform.operatingSystem,
        ),
        // This flag controls GPU texture rendering, independently of hwdec.
        // Keep it enabled even in software-decoder mode: CPU-rendering a 4K
        // Flutter texture is not a useful or performant fallback.
        enableHardwareAcceleration: true,
      ),
    );
    final streamController = StreamController<VideoEvent>();
    final rateStreamController = StreamController<double>.broadcast(sync: true);
    final streamSubscriptions = <StreamSubscription>[];

    final textureId = player.hashCode;

    _players[textureId] = player;
    _completers[textureId] = completer;
    _videoControllers[textureId] = videoController;
    _streamControllers[textureId] = streamController;
    _rateStreamControllers[textureId] = rateStreamController;
    _streamSubscriptions[textureId] = streamSubscriptions;

    final String resource;
    final Map<String, String> httpHeaders = Map<String, String>.from(
      dataSource.httpHeaders,
    );
    final externalAudioUri = httpHeaders.remove(
      NativeVideoPlayerMediaKit.externalAudioSourceHeader,
    );

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
    }

    final media = Media(resource, httpHeaders: httpHeaders);
    final decoderFallbackState = _DecoderFallbackState(
      media: media,
      externalAudioUri: externalAudioUri,
      enabled: UniversalPlatform.isAndroid && useHardwareDecoding,
    );
    _decoderFallbackStates[textureId] = decoderFallbackState;
    _initialize(textureId);

    // VideoController initialization is deliberately asynchronous and the
    // desktop media_kit plugin overwrites video-sync/video-timing-offset while
    // creating its native render context. Wait for that work before installing
    // our final clock configuration; otherwise the intended smooth timing is
    // silently replaced by media_kit's zero-lookahead defaults a frame later.
    await videoController.platform.future;

    // Install the latency, clock, and pitch pipeline before opening media so
    // the first decoded frame enters the final graph. Replacing `af` after open
    // is inaudible while paused, but still needlessly rebuilds the native graph.
    await PitchPreservingAudioPipeline.configure(player);
    await _configureHighResolutionPlayback(player);
    if (externalAudioUri != null) {
      await _configureStreamingBuffer(player);
    }
    await player.open(media, play: false);
    await _attachExternalAudio(player, externalAudioUri);
    await _disableSubtitleOutput(player);

    if (decoderFallbackState.enabled) {
      unawaited(
        videoController.waitUntilFirstFrameRendered.then((_) {
          if (_decoderFallbackStates[textureId] == decoderFallbackState) {
            decoderFallbackState.markFirstFrameRendered();
          }
        }),
      );
    }

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
  Future<void> setPlaybackSpeed(int textureId, double speed) {
    final player = _players[textureId];
    if (player == null || !speed.isFinite || speed <= 0) {
      return Future<void>.value();
    }

    final epoch = (_rateRequestEpochs[textureId] ?? 0) + 1;
    _rateRequestEpochs[textureId] = epoch;
    final previous = _rateCommands[textureId] ?? Future<void>.value();
    final command = () async {
      try {
        await previous;
      } catch (_) {
        // A failed older request must not suppress the latest requested rate.
      }
      if (_rateRequestEpochs[textureId] != epoch ||
          _players[textureId] != player) {
        return;
      }

      // scaletempo2 already performs its own 12 ms WSOLA overlap/crossfade on
      // the native audio thread. Sending an application-side staircase here
      // changes the clock many times inside one output buffer and causes the
      // very discontinuity the ramp was intended to hide. Production players
      // likewise set one target and let their realtime audio processor bridge
      // the boundary.
      await player.setRate(speed);
      if (_players[textureId] != player) return;

      final controller = _rateStreamControllers[textureId];
      if (controller != null && !controller.isClosed) controller.add(speed);
    }();

    late final Future<void> trackedCommand;
    trackedCommand = command.whenComplete(() {
      if (identical(_rateCommands[textureId], trackedCommand)) {
        _rateCommands.remove(textureId);
      }
    });
    _rateCommands[textureId] = trackedCommand;
    return trackedCommand;
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
      // The video_player widget's parent already owns aspect-ratio/layout
      // containment. A second BoxFit.contain here can expose rounding or padded
      // dimensions from a 480P texture as an extra black border after switching
      // qualities. Fill only this already aspect-correct viewport.
      fit: BoxFit.fill,
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
      Timer? audioOnlyFallbackTimer;
      final decoderFallbackState = _decoderFallbackStates[textureId];

      void emitPlayerError(Object error) {
        if (streamController.isClosed ||
            (decoderFallbackState?.fatalErrorEmitted ?? false)) {
          return;
        }
        if (decoderFallbackState != null) {
          decoderFallbackState.fatalErrorEmitted = true;
          decoderFallbackState.failureTimer?.cancel();
          decoderFallbackState.failureTimer = null;
        }
        streamController.addError(
          PlatformException(code: 'media_kit_error', message: '$error'),
        );
      }

      Future<void> retryWithSoftwareDecoder() async {
        final state = decoderFallbackState;
        if (state == null ||
            _decoderFallbackStates[textureId] != state ||
            _players[textureId] != player) {
          return;
        }

        final resumePosition = player.state.position;
        final resumePlaying = player.state.playing;
        try {
          final platform = player.platform;
          if (platform is! NativePlayer) {
            emitPlayerError(state.lastError ?? 'Hardware decoder failed');
            return;
          }

          debugPrint(
            'MediaKit Android hardware decoder failed before the first frame; '
            'retrying once with software decoding: ${state.lastError}',
          );
          await platform.setProperty(
            'hwdec',
            'no',
            waitForInitialization: false,
          );
          if (_decoderFallbackStates[textureId] != state ||
              _players[textureId] != player) {
            return;
          }

          await player.open(state.media, play: false);
          await _attachExternalAudio(player, state.externalAudioUri);
          await _disableSubtitleOutput(player);
          if (resumePosition > Duration.zero &&
              resumePosition < player.state.duration) {
            await player.seek(resumePosition);
          }
          if (resumePlaying) {
            await player.play();
          }
        } catch (error) {
          emitPlayerError(
            'Hardware decoder failed and software retry could not start: $error',
          );
        }
      }

      void notify() {
        if (!completer.isCompleted && !streamController.isClosed) {
          if (width != null && height != null && duration != null) {
            audioOnlyFallbackTimer?.cancel();
            streamController.add(
              VideoEvent(
                eventType: VideoEventType.initialized,
                size: Size((width ?? 0) * 1.0, (height ?? 0) * 1.0),
                duration: player.state.duration,
              ),
            );
            completer.complete();
          }
        }
      }

      void scheduleAudioOnlyFallback() {
        audioOnlyFallbackTimer ??= Timer(
          const Duration(milliseconds: 1500),
          () {
            if (!completer.isCompleted &&
                !streamController.isClosed &&
                duration != null) {
              // Audio files can contain embedded cover art reported as a video
              // track. Such a still image does not always emit videoParams.
              width = 0;
              height = 0;
              notify();
            }
          },
        );
      }

      streamSubscriptions.add(
        player.stream.duration.listen((event) {
          if (event > Duration.zero) {
            duration = event;
            notify();
            scheduleAudioOnlyFallback();
          }
        }),
      );
      streamSubscriptions.add(
        player.stream.videoParams.listen((event) {
          width = event.dw;
          height = event.dh;
          if ((width ?? 0) > 0 && (height ?? 0) > 0) {
            final sourceSize = Size(width!.toDouble(), height!.toDouble());
            _sourceVideoSizes[textureId] = sourceSize;
            _scheduleAdaptiveOutputResize(textureId, sourceSize);
            unawaited(
              _configureFrameDroppingForResolution(
                textureId,
                player,
                sourceSize,
              ),
            );
            audioOnlyFallbackTimer?.cancel();
            notify();
          }
        }),
      );
      streamSubscriptions.add(
        player.stream.tracks.listen((event) {
          // media_kit prepends the synthetic "auto" and "no" entries. Audio
          // files with embedded cover art therefore look as if they contain a
          // video stream, but that still image often never emits videoParams.
          // Classify album art from track metadata immediately instead of
          // making every such audio file pay the 1.5 s safety timeout.
          final mediaVideoTracks = event.video
              .where((track) => track.id != 'auto' && track.id != 'no')
              .toList(growable: false);
          final hasAudioTrack = event.audio.any(
            (track) => track.id != 'auto' && track.id != 'no',
          );
          final hasMotionVideo = mediaVideoTracks.any(
            (track) => track.image != true && track.albumart != true,
          );
          if (hasAudioTrack && !hasMotionVideo) {
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
              VideoEvent(eventType: VideoEventType.completed),
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
              buffered: [DurationRange(Duration.zero, event)],
            ),
          );
        }),
      );
      streamSubscriptions.add(
        player.stream.error.listen((event) {
          final state = decoderFallbackState;
          if (state != null && state.enabled && !state.firstFrameRendered) {
            state.lastError = event;
            final shouldRetry =
                NativeVideoPlayerMediaKit.shouldRetryAndroidSoftwareDecoding(
                  useHardwareDecoding: true,
                  operatingSystem: UniversalPlatform.operatingSystem,
                  firstFrameRendered: state.firstFrameRendered,
                  fallbackAttempted: state.fallbackAttempted,
                );
            if (shouldRetry) {
              state.fallbackAttempted = true;
              state.failureTimer = Timer(const Duration(seconds: 12), () {
                if (!state.firstFrameRendered) {
                  emitPlayerError(
                    state.lastError ??
                        'Hardware decoder failed and software retry timed out',
                  );
                }
              });
              unawaited(retryWithSoftwareDecoder());
            }
            // media_kit emits decoder log errors even when libmpv is about to
            // recover. Do not poison VideoPlayerController before the explicit
            // one-shot software attempt has had a chance to render a frame.
            return;
          }

          // Errors outside Android's guarded first-frame attempt are fatal.
          // Delivering them immediately prevents initialize() from hanging.
          emitPlayerError(event);
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

  Future<void> _attachExternalAudio(Player player, String? uri) async {
    if (uri == null || uri.isEmpty) return;
    final parsed = Uri.tryParse(uri);
    if (parsed == null ||
        !parsed.isAbsolute ||
        (parsed.scheme != 'http' && parsed.scheme != 'https')) {
      throw ArgumentError.value(uri, 'externalAudioUri', 'Invalid media URI');
    }
    await player.setAudioTrack(
      AudioTrack.uri(uri, title: 'Bilibili audio', language: 'und'),
    );
  }

  Future<void> _configureStreamingBuffer(Player player) async {
    final platform = player.platform;
    if (platform is! NativePlayer) return;
    final maxForwardBytes =
        UniversalPlatform.isAndroid || UniversalPlatform.isIOS
        ? 32 * 1024 * 1024
        : 64 * 1024 * 1024;
    final maxBackBytes = UniversalPlatform.isAndroid || UniversalPlatform.isIOS
        ? 8 * 1024 * 1024
        : 16 * 1024 * 1024;
    await Future.wait<void>([
      platform.setProperty('cache', 'yes', waitForInitialization: false),
      platform.setProperty('cache-secs', '30', waitForInitialization: false),
      platform.setProperty(
        'demuxer-readahead-secs',
        '30',
        waitForInitialization: false,
      ),
      platform.setProperty(
        'demuxer-max-bytes',
        '$maxForwardBytes',
        waitForInitialization: false,
      ),
      platform.setProperty(
        'demuxer-max-back-bytes',
        '$maxBackBytes',
        waitForInitialization: false,
      ),
    ]);
  }

  Future<void> _configureHighResolutionPlayback(Player player) async {
    final platform = player.platform;
    if (platform is! NativePlayer) return;

    // Automatic decoder threading is particularly important for dav1d's 4K
    // AV1 software fallback. Direct rendering avoids an avoidable decoded-frame
    // copy, while framedrop during precise seeks prevents a large GOP from
    // making the UI appear stuck after scrubbing.
    await Future.wait<void>(<Future<void>>[
      platform.setProperty(
        'vd-lavc-threads',
        '0',
        waitForInitialization: false,
      ),
      platform.setProperty('vd-lavc-dr', 'yes', waitForInitialization: false),
      platform.setProperty(
        'hr-seek-framedrop',
        'yes',
        waitForInitialization: false,
      ),
    ]);
  }

  Future<void> _configureFrameDroppingForResolution(
    int textureId,
    Player player,
    Size sourceSize,
  ) async {
    final platform = player.platform;
    if (platform is! NativePlayer) return;

    // mpv recommends VO-only dropping for normal media. Decoder dropping is
    // deliberately reserved for >1080p streams, where continuing to decode
    // every obsolete frame can otherwise leave a slow 4K software decoder
    // permanently behind the audio clock.
    final highResolution = sourceSize.width * sourceSize.height > 1920 * 1080;
    final mode = highResolution ? 'decoder+vo' : 'vo';
    if (_frameDropModes[textureId] == mode) return;
    try {
      await platform.setProperty(
        'framedrop',
        mode,
        waitForInitialization: false,
      );
      if (_players[textureId] == player) {
        _frameDropModes[textureId] = mode;
      }
    } catch (error) {
      debugPrint('MediaKit framedrop configuration failed: $error');
    }
  }

  Size? _physicalViewportSize() {
    final views = WidgetsBinding.instance.platformDispatcher.views;
    if (views.isEmpty) return null;
    Size? largest;
    for (final view in views) {
      final size = view.physicalSize;
      if (size.width <= 0 || size.height <= 0) continue;
      if (largest == null ||
          size.width * size.height > largest.width * largest.height) {
        largest = size;
      }
    }
    return largest;
  }

  void _scheduleAdaptiveOutputResize(int textureId, Size sourceSize) {
    // media_kit intentionally does not expose output resizing on Android.
    // Its Surface/MediaCodec path remains fully GPU accelerated instead.
    if (UniversalPlatform.isAndroid) return;
    final epoch = (_resizeEpochs[textureId] ?? 0) + 1;
    _resizeEpochs[textureId] = epoch;

    // media_kit also reacts to videoParams and first sets the source size.
    // Reapply our display-aware cap after that native resize has completed.
    Future<void>.delayed(const Duration(milliseconds: 20), () async {
      if (_resizeEpochs[textureId] != epoch ||
          _sourceVideoSizes[textureId] != sourceSize) {
        return;
      }
      final controller = _videoControllers[textureId];
      final viewport = _physicalViewportSize();
      if (controller == null || viewport == null) return;

      final target = NativeVideoPlayerMediaKit.adaptiveTextureSize(
        source: sourceSize,
        physicalViewport: viewport,
      );
      if (_outputVideoSizes[textureId] == target) return;

      try {
        if (target == sourceSize) {
          await controller.setSize();
        } else {
          await controller.setSize(
            width: target.width.toInt(),
            height: target.height.toInt(),
          );
        }
        if (_videoControllers[textureId] == controller) {
          _outputVideoSizes[textureId] = target;
          debugPrint(
            'MediaKit texture: '
            '${sourceSize.width.toInt()}x${sourceSize.height.toInt()} -> '
            '${target.width.toInt()}x${target.height.toInt()}',
          );
        }
      } catch (error) {
        debugPrint('MediaKit adaptive texture resize failed: $error');
      }
    });
  }
}

class _DecoderFallbackState {
  _DecoderFallbackState({
    required this.media,
    required this.externalAudioUri,
    required this.enabled,
  });

  final Media media;
  final String? externalAudioUri;
  final bool enabled;
  bool fallbackAttempted = false;
  bool firstFrameRendered = false;
  bool fatalErrorEmitted = false;
  String? lastError;
  Timer? failureTimer;

  void markFirstFrameRendered() {
    firstFrameRendered = true;
    failureTimer?.cancel();
    failureTimer = null;
  }

  void dispose() {
    failureTimer?.cancel();
    failureTimer = null;
  }
}
