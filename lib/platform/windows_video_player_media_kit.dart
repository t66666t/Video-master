import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:universal_platform/universal_platform.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart'
    hide VideoTrack;

import 'pitch_preserving_audio_pipeline.dart';
import 'local_playback_backend_policy.dart';
import '../services/settings_service.dart';

class NativeVideoPlayerMediaKit {
  static const Set<String> _audioOnlyExtensions = <String>{
    '.aac',
    '.ac3',
    '.aif',
    '.aifc',
    '.aiff',
    '.alac',
    '.amr',
    '.ape',
    '.au',
    '.caf',
    '.dff',
    '.dsf',
    '.dts',
    '.eac3',
    '.flac',
    '.m4a',
    '.m4b',
    '.mka',
    '.mp2',
    '.mp3',
    '.oga',
    '.ogg',
    '.opus',
    '.ra',
    '.snd',
    '.tta',
    '.wav',
    '.wma',
    '.wv',
  };

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

  @visibleForTesting
  static VideoTrack? firstUsableVideoTrack(Tracks tracks) {
    for (final track in tracks.video) {
      if (track.id != 'auto' && track.id != 'no') return track;
    }
    return null;
  }

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

  /// Completes when the native texture has received its first decoded frame.
  /// This is used by online quality hand-off to avoid swapping a fully visible
  /// player for a replacement whose texture is still empty.
  static Future<void>? firstFrameRenderedFor(int playerId) {
    return _NativeMediaKitVideoPlayer.registeredInstance
        ?._firstFrameRenderedFor(playerId);
  }

  /// Whether this player owns an actual Flutter video output. A background
  /// headless player deliberately returns false; an unrelated platform adapter
  /// returns null so callers do not rebuild a controller they cannot inspect.
  static bool? hasVideoOutputFor(int playerId) {
    return _NativeMediaKitVideoPlayer.registeredInstance?._hasVideoOutputFor(
      playerId,
    );
  }

  /// Adds a Flutter video texture to an already playing native player.
  ///
  /// Android notification commands may create a headless player while the app
  /// is backgrounded. Attaching the output later keeps the exact same libmpv
  /// instance, network cache, Bilibili DASH tracks, position and play state;
  /// reopening the media here would make foreground entry visibly buffer and
  /// replay the seek target.
  static Future<bool> attachVideoOutputFor(int playerId) async {
    return await _NativeMediaKitVideoPlayer.registeredInstance
            ?._attachVideoOutputFor(playerId) ??
        false;
  }

  /// Selects or deselects the primary video track of a split Bilibili stream.
  /// The external audio track and the Player clock remain untouched, allowing
  /// mobile background playback to stop consuming video bytes without an
  /// audible hand-off. Local Android files are delegated to video_player and
  /// therefore never enter this path.
  static Future<bool> setExternalVideoTrackEnabledFor(
    int playerId, {
    required bool enabled,
  }) async {
    return await _NativeMediaKitVideoPlayer.registeredInstance
            ?._setExternalVideoTrackEnabledFor(playerId, enabled: enabled) ??
        false;
  }

  /// Completes only after the native media clock has demonstrably started or
  /// the demuxer has buffered beyond the requested position. Unlike a texture
  /// frame, this remains a valid readiness signal while Android is backgrounded.
  static Future<bool>? playbackReadyFor(int playerId) {
    return _NativeMediaKitVideoPlayer.registeredInstance?._playbackReadyFor(
      playerId,
    );
  }

  /// Reopens the same media on Android with software video decoding while
  /// preserving the audio/video clock. This is a last-resort recovery for a
  /// player whose audio started but whose hardware decoder never produced a
  /// Flutter texture frame.
  static Future<bool> recoverVideoOutputFor(int playerId) async {
    return await _NativeMediaKitVideoPlayer.registeredInstance
            ?._recoverVideoOutputFor(playerId) ??
        false;
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

  /// media_kit defers Android's VideoController creation through a post-frame
  /// callback. Hidden/paused apps may not receive another Flutter frame, so a
  /// media-notification switch must not block audio loading on that callback.
  @visibleForTesting
  static bool shouldDeferVideoOutputInitialization({
    required String operatingSystem,
    required AppLifecycleState? lifecycleState,
  }) {
    return operatingSystem == 'android' &&
        (lifecycleState == AppLifecycleState.hidden ||
            lifecycleState == AppLifecycleState.paused ||
            lifecycleState == AppLifecycleState.detached);
  }

  /// Pure audio never needs a Flutter video texture. In particular, creating a
  /// [VideoController] for M4A/ALAC leaves the Android first-frame observer
  /// pending forever. A later audio-decoder log can then be mistaken for a
  /// failed hardware *video* decoder and unnecessarily reopen the player.
  @visibleForTesting
  static bool shouldCreateVideoOutput({
    required String resource,
    required String operatingSystem,
    required AppLifecycleState? lifecycleState,
  }) {
    if (isKnownAudioOnlyResource(resource)) return false;

    final uri = Uri.tryParse(resource);
    final isNetworkSource = uri?.scheme == 'http' || uri?.scheme == 'https';
    return !isNetworkSource ||
        !shouldDeferVideoOutputInitialization(
          operatingSystem: operatingSystem,
          lifecycleState: lifecycleState,
        );
  }

  /// The pre-streaming Android implementation used the platform
  /// `video_player` backend for local files. Keep that stable path even though
  /// Bilibili DASH streams still need the MediaKit adapter for their external
  /// audio track.
  @visibleForTesting
  static bool shouldUsePlatformPlayer({
    required DataSourceType sourceType,
    required String operatingSystem,
    required String? resource,
  }) {
    return operatingSystem == 'android' &&
        sourceType == DataSourceType.file &&
        resource != null &&
        !LocalPlaybackBackendPolicy.isWideCodecBackendPreferred(resource);
  }

  /// Filters transient completion pulses from embedded album-art streams.
  ///
  /// video_player treats a forwarded completion as authoritative and moves
  /// its position to the duration. Some M4A files briefly publish completion
  /// while their still-image cover track is selected, paused, or torn down,
  /// even though the audio track is nowhere near its end.
  @visibleForTesting
  static bool shouldForwardPlaybackCompletion({
    required bool completed,
    required Duration position,
    required Duration duration,
  }) {
    if (!completed || duration <= Duration.zero || position < Duration.zero) {
      return false;
    }
    const completionTolerance = Duration(seconds: 1);
    return position + completionTolerance >= duration;
  }

  /// media_kit's error stream is synthesized from selected libmpv log lines;
  /// it is not a terminal-state stream. Once a controller has a duration and
  /// usable tracks, decoder/track-reconfiguration messages must not turn the
  /// whole VideoPlayerController into an uninitialized erroneous value.
  @visibleForTesting
  static bool shouldForwardPlayerError({
    required bool controllerInitialized,
    required Duration duration,
    required bool hasUsableMediaTrack,
  }) {
    if (!controllerInitialized) return true;
    return duration <= Duration.zero && !hasUsableMediaTrack;
  }

  /// Identifies sources whose visual track can only be embedded cover art.
  /// Disabling that track before the controller becomes usable keeps libmpv's
  /// seek clock anchored to audio instead of a one-frame attached picture.
  @visibleForTesting
  static bool isKnownAudioOnlyResource(String resource) {
    var path = resource;
    try {
      final uri = Uri.parse(resource);
      if (uri.path.isNotEmpty) path = uri.path;
    } catch (_) {}
    final normalized = path
        .replaceFirst(RegExp(r'[?#].*$'), '')
        .replaceAll('\\', '/')
        .toLowerCase();
    return _audioOnlyExtensions.any(normalized.endsWith);
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
  _NativeMediaKitVideoPlayer(this._platformFallback);

  static _NativeMediaKitVideoPlayer? registeredInstance;

  final VideoPlayerPlatform _platformFallback;
  final _delegatedTextureIds = HashMap<int, int>();
  // -1 is reserved by VideoPlayerController for an uninitialized player.
  int _nextDelegatedTextureId = -2;

  final _players = HashMap<int, Player>();
  final _completers = HashMap<int, Completer<void>>();
  final _videoControllers = HashMap<int, VideoController>();
  final _readyVideoOutputs = HashSet<int>();
  final _videoOutputAttachments = HashMap<int, Future<bool>>();
  final _externalVideoTrackCommands = HashMap<int, Future<void>>();
  final _externalVideoTrackDesired = HashMap<int, bool>();
  final _suspendedExternalVideoTracks = HashMap<int, VideoTrack>();
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
    final currentPlatform = VideoPlayerPlatform.instance;
    final platformFallback = currentPlatform is _NativeMediaKitVideoPlayer
        ? currentPlatform._platformFallback
        : currentPlatform;
    if (previous != null) {
      WidgetsBinding.instance.removeObserver(previous);
    }
    final instance = _NativeMediaKitVideoPlayer(platformFallback);
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

  Future<void>? _firstFrameRenderedFor(int textureId) {
    return _videoControllers[textureId]?.waitUntilFirstFrameRendered;
  }

  bool _hasVideoOutputFor(int textureId) {
    if (_delegatedTextureIds.containsKey(textureId)) return true;
    return _readyVideoOutputs.contains(textureId);
  }

  VideoController _createVideoController(Player player) {
    return VideoController(
      player,
      configuration: VideoControllerConfiguration(
        hwdec: NativeVideoPlayerMediaKit.decoderOptionFor(
          useHardwareDecoding: SettingsService().useHardwareVideoDecoding,
          operatingSystem: UniversalPlatform.operatingSystem,
        ),
        // This controls GPU texture rendering independently of decoder choice.
        enableHardwareAcceleration: true,
      ),
    );
  }

  void _observeFirstFrame(
    int textureId,
    VideoController videoController,
    _DecoderFallbackState state,
  ) {
    unawaited(() async {
      try {
        await videoController.waitUntilFirstFrameRendered;
        if (_decoderFallbackStates[textureId] == state &&
            _videoControllers[textureId] == videoController) {
          state.markFirstFrameRendered();
        }
      } catch (error) {
        debugPrint('MediaKit first-frame observer failed: $error');
      }
    }());
  }

  Future<bool> _attachVideoOutputFor(int textureId) {
    if (_delegatedTextureIds.containsKey(textureId)) {
      return Future<bool>.value(true);
    }
    if (_readyVideoOutputs.contains(textureId)) {
      return Future<bool>.value(true);
    }
    final pending = _videoOutputAttachments[textureId];
    if (pending != null) return pending;

    late final Future<bool> attachment;
    attachment =
        () async {
          final player = _players[textureId];
          final state = _decoderFallbackStates[textureId];
          if (player == null || state == null || state.knownAudioOnly) {
            return false;
          }

          VideoController? videoController;
          try {
            videoController = _createVideoController(player);
            _videoControllers[textureId] = videoController;
            state.videoOutputDeferred = false;
            _observeFirstFrame(textureId, videoController, state);
            // Do not time this out here. Android may suspend Flutter texture
            // work while the app is backgrounded. Keeping this Future alive
            // lets the exact same Player finish attaching its output as soon
            // as the engine can service textures, without reopening media.
            await videoController.platform.future;
            if (_players[textureId] != player ||
                _videoControllers[textureId] != videoController) {
              return false;
            }
            _readyVideoOutputs.add(textureId);
            final sourceSize = _sourceVideoSizes[textureId];
            if (sourceSize != null) {
              _scheduleAdaptiveOutputResize(textureId, sourceSize);
            }
            return true;
          } catch (error) {
            if (videoController != null &&
                _videoControllers[textureId] == videoController) {
              _videoControllers.remove(textureId);
            }
            _readyVideoOutputs.remove(textureId);
            if (_decoderFallbackStates[textureId] == state) {
              state.videoOutputDeferred = true;
            }
            debugPrint('MediaKit video-output attachment failed: $error');
            return false;
          }
        }().whenComplete(() {
          if (identical(_videoOutputAttachments[textureId], attachment)) {
            _videoOutputAttachments.remove(textureId);
          }
        });
    _videoOutputAttachments[textureId] = attachment;
    return attachment;
  }

  Future<bool>? _playbackReadyFor(int textureId) {
    final player = _players[textureId];
    if (player == null) return null;
    return () async {
      final initialPosition = player.state.position;
      while (_players[textureId] == player) {
        final state = player.state;
        final positionAdvanced =
            (state.position.inMilliseconds - initialPosition.inMilliseconds)
                .abs() >=
            30;
        final bufferedAhead =
            state.buffer.inMilliseconds > state.position.inMilliseconds + 30;
        if (state.playing &&
            !state.completed &&
            !state.buffering &&
            (positionAdvanced || bufferedAhead)) {
          return true;
        }
        await Future<void>.delayed(const Duration(milliseconds: 40));
      }
      return false;
    }();
  }

  Future<bool> _setExternalVideoTrackEnabledFor(
    int textureId, {
    required bool enabled,
  }) async {
    final player = _players[textureId];
    final state = _decoderFallbackStates[textureId];
    if (player == null || state?.externalAudioUri?.isNotEmpty != true) {
      return false;
    }

    _externalVideoTrackDesired[textureId] = enabled;
    final previous = _externalVideoTrackCommands[textureId];
    late final Future<void> command;
    command = (previous ?? Future<void>.value())
        .catchError((_) {})
        .then((_) async {
          if (_players[textureId] != player ||
              _decoderFallbackStates[textureId] != state) {
            return;
          }
          final shouldEnable = _externalVideoTrackDesired[textureId] ?? true;
          if (shouldEnable) {
            state!.externalVideoTrackSuspended = false;
            final target =
                _suspendedExternalVideoTracks.remove(textureId) ??
                NativeVideoPlayerMediaKit.firstUsableVideoTrack(
                  player.state.tracks,
                ) ??
                VideoTrack.auto();
            if (player.state.track.video.id != target.id) {
              await player.setVideoTrack(target);
            }
            return;
          }

          final selected = player.state.track.video;
          if (selected.id != 'no' && selected.id != 'auto') {
            _suspendedExternalVideoTracks[textureId] = selected;
          }
          state!.externalVideoTrackSuspended = true;
          if (selected.id != 'no') {
            await player.setVideoTrack(VideoTrack.no());
          }
        })
        .whenComplete(() {
          if (identical(_externalVideoTrackCommands[textureId], command)) {
            _externalVideoTrackCommands.remove(textureId);
          }
        });
    _externalVideoTrackCommands[textureId] = command;
    try {
      await command;
    } catch (error) {
      debugPrint('MediaKit external video-track switch failed: $error');
      return false;
    }
    return _players[textureId] == player &&
        _externalVideoTrackDesired[textureId] == enabled;
  }

  Future<bool> _recoverVideoOutputFor(int textureId) async {
    if (!UniversalPlatform.isAndroid) return false;
    final state = _decoderFallbackStates[textureId];
    final player = _players[textureId];
    if (state == null || player == null) return false;
    final existing = state.recovery;
    if (existing != null) return existing;

    final recovery = () async {
      final resumePosition = player.state.position;
      final resumePlaying = player.state.playing;
      try {
        final platform = player.platform;
        if (platform is! NativePlayer) return false;
        state.fallbackAttempted = true;
        await platform.setProperty('hwdec', 'no', waitForInitialization: false);
        if (_decoderFallbackStates[textureId] != state ||
            _players[textureId] != player) {
          return false;
        }
        await _openMediaWithExternalAudio(
          player,
          state.media,
          externalAudioUri: state.externalAudioUri,
          knownAudioOnly: state.knownAudioOnly,
        );
        await _disableSubtitleOutput(player);
        if (resumePosition > Duration.zero &&
            (player.state.duration <= Duration.zero ||
                resumePosition < player.state.duration)) {
          await player.seek(resumePosition);
        }
        if (resumePlaying) await player.play();
        return true;
      } catch (error) {
        debugPrint('MediaKit video-output recovery failed: $error');
        return false;
      }
    }();
    state.recovery = recovery;
    try {
      return await recovery;
    } finally {
      if (identical(state.recovery, recovery)) state.recovery = null;
    }
  }

  void _cancelPendingRateChange(int textureId) {
    if (_delegatedTextureIds.containsKey(textureId)) return;
    _rateRequestEpochs[textureId] = (_rateRequestEpochs[textureId] ?? 0) + 1;
  }

  @override
  Future<void> init() async {
    _delegatedTextureIds.clear();
    _nextDelegatedTextureId = -2;
    if (UniversalPlatform.isAndroid) {
      await _platformFallback.init();
    }
    for (final textureId in _players.keys) {
      await dispose(textureId);
    }

    _players.clear();
    _completers.clear();
    _videoControllers.clear();
    _readyVideoOutputs.clear();
    _videoOutputAttachments.clear();
    _externalVideoTrackCommands.clear();
    _externalVideoTrackDesired.clear();
    _suspendedExternalVideoTracks.clear();
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
    final delegatedTextureId = _delegatedTextureIds.remove(textureId);
    if (delegatedTextureId != null) {
      await _platformFallback.dispose(delegatedTextureId);
      return;
    }
    _cancelPendingRateChange(textureId);
    _decoderFallbackStates.remove(textureId)?.dispose();
    _externalVideoTrackDesired.remove(textureId);
    _suspendedExternalVideoTracks.remove(textureId);
    final videoTrackCommand = _externalVideoTrackCommands.remove(textureId);
    try {
      await videoTrackCommand;
    } catch (_) {}
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
    _readyVideoOutputs.remove(textureId);
    _videoOutputAttachments.remove(textureId);
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
    if (NativeVideoPlayerMediaKit.shouldUsePlatformPlayer(
      sourceType: dataSource.sourceType,
      operatingSystem: UniversalPlatform.operatingSystem,
      resource: dataSource.uri,
    )) {
      // The adapter itself still implements the legacy create contract used by
      // the current video_player package, so delegation must preserve it.
      // ignore: deprecated_member_use
      final delegatedTextureId = await _platformFallback.create(dataSource);
      if (delegatedTextureId == null) return null;
      return _exposeDelegatedTextureId(delegatedTextureId);
    }

    final player = Player(
      configuration: const PlayerConfiguration(
        osc: false,
        libass: false,
        pitch: false,
      ),
    );
    final completer = Completer<void>();
    final useHardwareDecoding = SettingsService().useHardwareVideoDecoding;
    final streamController = StreamController<VideoEvent>();
    final rateStreamController = StreamController<double>.broadcast(sync: true);
    final streamSubscriptions = <StreamSubscription>[];

    final textureId = player.hashCode;

    _players[textureId] = player;
    _completers[textureId] = completer;
    _streamControllers[textureId] = streamController;
    _rateStreamControllers[textureId] = rateStreamController;
    _streamSubscriptions[textureId] = streamSubscriptions;

    try {
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

      final knownAudioOnly = NativeVideoPlayerMediaKit.isKnownAudioOnlyResource(
        resource,
      );
      final createVideoOutput =
          NativeVideoPlayerMediaKit.shouldCreateVideoOutput(
            resource: resource,
            operatingSystem: UniversalPlatform.operatingSystem,
            lifecycleState: WidgetsBinding.instance.lifecycleState,
          );
      final videoOutputDeferred = !createVideoOutput;
      final VideoController? videoController = createVideoOutput
          ? _createVideoController(player)
          : null;
      if (videoController != null) {
        _videoControllers[textureId] = videoController;
      }

      final media = Media(resource, httpHeaders: httpHeaders);
      final decoderFallbackState = _DecoderFallbackState(
        media: media,
        externalAudioUri: externalAudioUri,
        knownAudioOnly: knownAudioOnly,
        enabled:
            UniversalPlatform.isAndroid &&
            useHardwareDecoding &&
            !knownAudioOnly,
        videoOutputDeferred: videoOutputDeferred,
      );
      _decoderFallbackStates[textureId] = decoderFallbackState;
      _initialize(textureId);

      // VideoController initialization is deliberately asynchronous and the
      // desktop media_kit plugin overwrites video-sync/video-timing-offset while
      // creating its native render context. Wait for that work before installing
      // our final clock configuration; otherwise the intended smooth timing is
      // silently replaced by media_kit's zero-lookahead defaults a frame later.
      if (videoController != null) {
        await videoController.platform.future;
        _readyVideoOutputs.add(textureId);
      }

      // Install the latency, clock, and pitch pipeline before opening media so
      // the first decoded frame enters the final graph. Replacing `af` after open
      // is inaudible while paused, but still needlessly rebuilds the native graph.
      await PitchPreservingAudioPipeline.configure(player);
      await _configureHighResolutionPlayback(player);
      if (externalAudioUri != null) {
        await _configureStreamingBuffer(player);
      }
      await _openMediaWithExternalAudio(
        player,
        media,
        externalAudioUri: externalAudioUri,
        knownAudioOnly: knownAudioOnly,
      );
      await _disableSubtitleOutput(player);
      if (knownAudioOnly) {
        // Keep libmpv's clock explicitly audio-only even if a container exposes
        // attached artwork as a selectable image track.
        await _disableAlbumArtVideoOutput(player);
      }

      if (videoController != null) {
        _observeFirstFrame(textureId, videoController, decoderFallbackState);
      }

      return textureId;
    } catch (error, stackTrace) {
      // video_player does not complete its internal creation barrier when a
      // platform create call throws. Return the registered id and deliver a
      // buffered platform error instead, so initialize() fails normally and
      // dispose() can reclaim the native player before a retry.
      debugPrint('MediaKit player creation failed: $error\n$stackTrace');
      if (!streamController.isClosed) {
        streamController.addError(
          error is PlatformException
              ? error
              : PlatformException(
                  code: 'media_kit_create_error',
                  message: error.toString(),
                ),
        );
      }
      return textureId;
    }
  }

  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    if (NativeVideoPlayerMediaKit.shouldUsePlatformPlayer(
      sourceType: options.dataSource.sourceType,
      operatingSystem: UniversalPlatform.operatingSystem,
      resource: options.dataSource.uri,
    )) {
      final delegatedTextureId = await _platformFallback.createWithOptions(
        options,
      );
      if (delegatedTextureId == null) return null;
      return _exposeDelegatedTextureId(delegatedTextureId);
    }
    // ignore: deprecated_member_use_from_same_package
    return create(options.dataSource);
  }

  int _exposeDelegatedTextureId(int delegatedTextureId) {
    final textureId = _nextDelegatedTextureId--;
    _delegatedTextureIds[textureId] = delegatedTextureId;
    return textureId;
  }

  @override
  Stream<VideoEvent> videoEventsFor(int textureId) {
    final delegatedTextureId = _delegatedTextureIds[textureId];
    if (delegatedTextureId != null) {
      return _platformFallback.videoEventsFor(delegatedTextureId);
    }
    if (_streamControllers[textureId] == null) {
      throw StateError(
        'VideoPlayer for textureId $textureId is not found, Check if its disposed.',
      );
    }
    return _streamControllers[textureId]!.stream;
  }

  @override
  Future<void> setLooping(int textureId, bool looping) async {
    final delegatedTextureId = _delegatedTextureIds[textureId];
    if (delegatedTextureId != null) {
      return _platformFallback.setLooping(delegatedTextureId, looping);
    }
    final playlistMode = looping ? PlaylistMode.single : PlaylistMode.none;
    return _players[textureId]?.setPlaylistMode(playlistMode);
  }

  @override
  Future<void> play(int textureId) async {
    final delegatedTextureId = _delegatedTextureIds[textureId];
    if (delegatedTextureId != null) {
      return _platformFallback.play(delegatedTextureId);
    }
    return _players[textureId]?.play();
  }

  @override
  Future<void> pause(int textureId) async {
    final delegatedTextureId = _delegatedTextureIds[textureId];
    if (delegatedTextureId != null) {
      return _platformFallback.pause(delegatedTextureId);
    }
    return _players[textureId]?.pause();
  }

  @override
  Future<void> setVolume(int textureId, double volume) async {
    final delegatedTextureId = _delegatedTextureIds[textureId];
    if (delegatedTextureId != null) {
      return _platformFallback.setVolume(delegatedTextureId, volume);
    }
    return _players[textureId]?.setVolume(volume * 100);
  }

  @override
  Future<void> seekTo(int textureId, Duration position) async {
    final delegatedTextureId = _delegatedTextureIds[textureId];
    if (delegatedTextureId != null) {
      return _platformFallback.seekTo(delegatedTextureId, position);
    }
    return _players[textureId]?.seek(position);
  }

  @override
  Future<void> setPlaybackSpeed(int textureId, double speed) {
    final delegatedTextureId = _delegatedTextureIds[textureId];
    if (delegatedTextureId != null) {
      return _platformFallback.setPlaybackSpeed(delegatedTextureId, speed);
    }
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
    final delegatedTextureId = _delegatedTextureIds[textureId];
    if (delegatedTextureId != null) {
      return _platformFallback.getPosition(delegatedTextureId);
    }
    return _players[textureId]?.platform?.state.position ?? Duration.zero;
  }

  @override
  Widget buildView(int textureId) {
    final delegatedTextureId = _delegatedTextureIds[textureId];
    if (delegatedTextureId != null) {
      // ignore: deprecated_member_use
      return _platformFallback.buildView(delegatedTextureId);
    }
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
  Widget buildViewWithOptions(VideoViewOptions options) {
    final delegatedTextureId = _delegatedTextureIds[options.playerId];
    if (delegatedTextureId != null) {
      return _platformFallback.buildViewWithOptions(
        VideoViewOptions(playerId: delegatedTextureId),
      );
    }
    // ignore: deprecated_member_use_from_same_package
    return buildView(options.playerId);
  }

  @override
  Future<void> setPreventsDisplaySleepDuringVideoPlayback(
    int textureId,
    bool preventsDisplaySleepDuringVideoPlayback,
  ) {
    final delegatedTextureId = _delegatedTextureIds[textureId];
    if (delegatedTextureId != null) {
      return _platformFallback.setPreventsDisplaySleepDuringVideoPlayback(
        delegatedTextureId,
        preventsDisplaySleepDuringVideoPlayback,
      );
    }
    return Future<void>.value();
  }

  @override
  Future<void> setMixWithOthers(bool mixWithOthers) {
    if (UniversalPlatform.isAndroid) {
      return _platformFallback.setMixWithOthers(mixWithOthers);
    }
    return Future<void>.value();
  }

  @override
  Future<void> setWebOptions(int textureId, VideoPlayerWebOptions options) {
    final delegatedTextureId = _delegatedTextureIds[textureId];
    if (delegatedTextureId != null) {
      return _platformFallback.setWebOptions(delegatedTextureId, options);
    }
    return Future.value();
  }

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

        debugPrint(
          'MediaKit Android hardware decoder failed before the first frame; '
          'retrying once with software decoding: ${state.lastError}',
        );
        final recovered = await _recoverVideoOutputFor(textureId);
        if (!recovered) {
          emitPlayerError(
            state.lastError ??
                'Hardware decoder failed and software retry could not start',
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
            decoderFallbackState?.initializationErrorTimer?.cancel();
            if (decoderFallbackState != null) {
              decoderFallbackState.initializationErrorTimer = null;
            }
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
            unawaited(_disableAlbumArtVideoOutput(player));
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
          if (NativeVideoPlayerMediaKit.shouldForwardPlaybackCompletion(
            completed: event,
            position: player.state.position,
            duration: player.state.duration,
          )) {
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
          if (state != null && state.knownAudioOnly && !completer.isCompleted) {
            state.lastError = event;
            state.initializationErrorTimer ??= Timer(
              const Duration(seconds: 3),
              () {
                if (_decoderFallbackStates[textureId] != state ||
                    _players[textureId] != player ||
                    completer.isCompleted) {
                  return;
                }
                final hasAudioTrack = player.state.tracks.audio.any(
                  (track) => track.id != 'auto' && track.id != 'no',
                );
                if (player.state.duration > Duration.zero && hasAudioTrack) {
                  // The log was emitted while ALAC/FFmpeg was configuring its
                  // decoder. The media is usable, so it is not a terminal
                  // VideoPlayerController error.
                  duration = player.state.duration;
                  width = 0;
                  height = 0;
                  notify();
                  return;
                }
                emitPlayerError(
                  state.lastError ?? 'Audio decoder failed to initialize',
                );
              },
            );
            debugPrint(
              'MediaKit deferred audio-only decoder log during '
              'initialization: $event',
            );
            return;
          }
          if (state != null &&
              state.enabled &&
              !state.videoOutputDeferred &&
              !state.externalVideoTrackSuspended &&
              !state.firstFrameRendered) {
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

          final tracks = player.state.tracks;
          final hasUsableMediaTrack =
              tracks.audio.any(
                (track) => track.id != 'auto' && track.id != 'no',
              ) ||
              tracks.video.any(
                (track) => track.id != 'auto' && track.id != 'no',
              );
          if (!NativeVideoPlayerMediaKit.shouldForwardPlayerError(
            controllerInitialized: completer.isCompleted,
            duration: player.state.duration,
            hasUsableMediaTrack: hasUsableMediaTrack,
          )) {
            debugPrint(
              'MediaKit ignored recoverable post-initialization error: $event',
            );
            return;
          }

          // Before initialization there is no usable controller to preserve.
          // Forwarding the failure also prevents initialize() from hanging.
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

  Future<void> _disableAlbumArtVideoOutput(Player player) async {
    try {
      if (player.state.track.video != VideoTrack.no()) {
        await player.setVideoTrack(VideoTrack.no());
      }
    } catch (_) {
      // Album art is decorative. Failure to deselect it must not block audio.
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

  Future<void> _openMediaWithExternalAudio(
    Player player,
    Media media, {
    required String? externalAudioUri,
    required bool knownAudioOnly,
  }) async {
    if (!knownAudioOnly) {
      // A Bilibili DASH video URL is video-only. Explicitly selecting video
      // before load keeps libmpv from deciding that the file has no selected
      // streams and unloading it before the external audio-add command runs.
      await player.setVideoTrack(VideoTrack.auto());
    }

    await player.open(media, play: false);

    final selectedPrimaryVideoTrack =
        !knownAudioOnly &&
            externalAudioUri != null &&
            externalAudioUri.isNotEmpty
        ? await _waitForPrimaryVideoTrack(player)
        : null;
    await _attachExternalAudio(player, externalAudioUri);
    if (selectedPrimaryVideoTrack != null) {
      // audio-add mutates libmpv's track list. Select the already-discovered
      // main video by its concrete id so automatic selection cannot settle on
      // `no` (or on artwork exposed by the external audio container).
      await player.setVideoTrack(selectedPrimaryVideoTrack);
    }
  }

  Future<VideoTrack> _waitForPrimaryVideoTrack(Player player) async {
    final current = NativeVideoPlayerMediaKit.firstUsableVideoTrack(
      player.state.tracks,
    );
    if (current != null) return current;

    final tracks = await player.stream.tracks
        .firstWhere(
          (tracks) =>
              NativeVideoPlayerMediaKit.firstUsableVideoTrack(tracks) != null,
        )
        .timeout(
          const Duration(seconds: 20),
          onTimeout: () => throw TimeoutException(
            'Timed out waiting for the primary video track before attaching '
            'external audio.',
          ),
        );
    return NativeVideoPlayerMediaKit.firstUsableVideoTrack(tracks)!;
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
      // Let libmpv accumulate a stable initial/rebuffer window while its clock
      // is paused. Without this, a split Bilibili stream can expose a few
      // decoded audio packets, underrun, and audibly repeat that tiny region.
      platform.setProperty('cache-pause', 'yes', waitForInitialization: false),
      platform.setProperty(
        'cache-pause-initial',
        'yes',
        waitForInitialization: false,
      ),
      platform.setProperty(
        'cache-pause-wait',
        '2',
        waitForInitialization: false,
      ),
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
    required this.knownAudioOnly,
    required this.enabled,
    required this.videoOutputDeferred,
  });

  final Media media;
  final String? externalAudioUri;
  final bool knownAudioOnly;
  final bool enabled;
  bool videoOutputDeferred;
  bool externalVideoTrackSuspended = false;
  bool fallbackAttempted = false;
  bool firstFrameRendered = false;
  bool fatalErrorEmitted = false;
  String? lastError;
  Timer? failureTimer;
  Timer? initializationErrorTimer;
  Future<bool>? recovery;

  void markFirstFrameRendered() {
    firstFrameRendered = true;
    failureTimer?.cancel();
    failureTimer = null;
  }

  void dispose() {
    failureTimer?.cancel();
    failureTimer = null;
    initializationErrorTimer?.cancel();
    initializationErrorTimer = null;
  }
}
