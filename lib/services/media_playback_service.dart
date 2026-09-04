import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
import '../models/video_item.dart';
import '../models/media_source_ref.dart';
import '../models/managed_subtitle_asset.dart';
import '../models/playback_session.dart';
import '../models/subtitle_model.dart';
import '../platform/windows_video_player_media_kit.dart';
import '../platform/local_playback_backend_policy.dart';
import 'playlist_manager.dart';
import 'playback_queue_policy.dart';
import 'progress_tracker.dart';
import 'app_wakelock_coordinator.dart';
import 'audio_playback_compatibility_service.dart';
import 'playback_timeline_clock.dart';
import 'playback_behavior_policy.dart';
import '../services/embedded_subtitle_service.dart';
import '../services/library_service.dart';
import '../services/media_materialization_service.dart';
import '../services/settings_service.dart';
import '../services/bilibili/bilibili_streaming_service.dart';
import '../services/task_subtitle_storage_service.dart';
import '../services/subtitle_timeline_resolver.dart';
import '../services/subtitle_discovery_service.dart';
import '../utils/pgs_parser.dart';
import '../utils/subtitle_converter.dart';
import '../utils/subtitle_parser.dart';
import '../utils/youtube_auto_caption_normalizer.dart';

List<Map<String, Object?>> _parseTextSubtitlesToSerializable(String content) {
  final parsed = SubtitleParser.parse(content);
  final result = <Map<String, Object?>>[];
  for (final item in parsed) {
    result.add(<String, Object?>{
      'i': item.index,
      's': item.startTime.inMilliseconds,
      'e': item.endTime.inMilliseconds,
      't': item.text,
    });
  }
  return result;
}

class _EpisodeNavigationCommand {
  const _EpisodeNavigationCommand({
    required this.delta,
    required this.autoPlay,
  });

  final int delta;
  final bool autoPlay;
}

/// Result of [_awaitPlaybackReadiness].
///
/// `degraded` means the media was positioned correctly but the transport could
/// not be confirmed as actually running (background clock never started, or a
/// foreground decoder produced no frame). The session is then parked as paused
/// at the seek target instead of being torn down and retried, so the episode
/// switch itself stays successful and recoverable.
enum _PlaybackReadinessResult { confirmed, degraded }

/// 播放状态枚举
enum PlaybackState {
  idle, // 空闲状态
  loading, // 加载中
  playing, // 播放中
  paused, // 暂停
  error, // 错误
}

/// 媒体播放服务 - 管理全局播放状态
class MediaPlaybackService extends ChangeNotifier {
  static const String _globalMutePrefsKey = 'globalMute';

  // 单例模式
  static final MediaPlaybackService _instance =
      MediaPlaybackService._internal();
  factory MediaPlaybackService() => _instance;
  MediaPlaybackService._internal();

  // 依赖服务
  PlaylistManager? _playlistManager;
  ProgressTracker? _progressTracker;
  LibraryService? _libraryService;
  EmbeddedSubtitleService? _embeddedSubtitleService;
  BilibiliStreamingService? _bilibiliStreamingService;
  final Set<Object> _playbackPageOwners = <Object>{};
  final Set<Object> _miniPlaybackCardOwners = <Object>{};
  bool _mediaNotificationVisible = false;

  // 播放状态
  PlaybackState _state = PlaybackState.idle;
  VideoItem? _currentItem;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  Duration _bufferedPosition = Duration.zero;
  bool _isMuted = false;
  double _volume = 1.0;
  double _playbackSpeed = 1.0;
  VideoPlayerController? _controller;
  bool _serviceOwnsController = false;
  bool _isSourceMissing = false;
  List<BilibiliStreamQuality> _streamQualities = const [];
  BilibiliStreamQuality? _selectedStreamQuality;
  double? _streamDisplayAspectRatio;
  bool _isSwitchingStreamQuality = false;
  BilibiliPreparedPlayback? _currentBilibiliPlayback;
  MaterializedMediaLease? _currentMaterializedPlaybackLease;
  int _streamQualitySwitchRequestId = 0;
  bool _controllerCreatedWithoutVisiblePlaybackPage = false;
  Future<bool>? _visibleVideoOutputRecovery;
  bool? _requestedBilibiliVideoTrackEnabled;
  int _bilibiliVideoTrackPolicyRevision = 0;

  // 字幕相关
  List<SubtitleItem> _subtitles = [];
  List<SubtitleItem> _secondarySubtitles = [];
  List<String> _subtitlePaths = [];
  int _subtitleRevision = 0;
  SubtitleItem? _currentSubtitle;
  int _lastSubtitleIndex = 0;
  SubtitleTimelineResolver _subtitleTimeline = SubtitleTimelineResolver(
    const <SubtitleItem>[],
  );
  final Map<String, List<SubtitleItem>> _subtitleCache = {};
  int _subtitleLoadRequestId = 0;

  // 进度追踪定时器
  Timer? _progressTimer;

  // 进度更新定时器（用于实时UI更新）
  Timer? _positionUpdateTimer;
  Timer? _backgroundMediaSyncTimer;

  // 每帧更新的单一媒体时间轴，同时驱动进度 UI 和弹幕。
  final ValueNotifier<Duration> positionNotifier = ValueNotifier<Duration>(
    Duration.zero,
  );

  /// Low-frequency position updates for small progress-only widgets.
  final ValueNotifier<Duration> coarsePositionNotifier =
      ValueNotifier<Duration>(Duration.zero);

  /// 每帧只读取同一时钟；普通原生位置采样不会反向修正它。
  Ticker? _interpolationTicker;
  final PlaybackTimelineClock _timelineClock = PlaybackTimelineClock();
  StreamSubscription<Duration>? _nativePositionSubscription;
  StreamSubscription<double>? _nativeRateSubscription;
  int? _nativePositionPlayerId;
  double? _nativePresentationPlaybackSpeed;
  int _playbackSpeedRequestId = 0;
  double? _pendingPlaybackSpeed;
  double _confirmedPlaybackSpeed = 1.0;
  double _lastDispatchedPlaybackSpeed = 1.0;
  double? _temporaryPlaybackBaseSpeed;
  Future<void> _playbackSpeedCommandTail = Future<void>.value();

  Timer? _seekPersistTimer;
  Timer? _seekVerificationTimer;
  int _seekRequestId = 0;
  int? _pendingSeekRequestId;
  bool _preservePlayingStateAfterSeek = false;
  bool _initialPositionSeekInFlight = false;
  Duration? _initialPositionGuardTarget;
  DateTime? _initialPositionGuardUntil;
  bool? _lastControllerIsPlaying;
  Timer? _externalSeekResetTimer;
  int _externalSubtitleSeekAccumulator = 0;
  Duration? _externalInitialSeekPosition;
  bool _isAppInForeground = true;
  AppLifecycleState? _lastAppLifecycleState;
  String _lastSeekSource = 'none';
  Duration? _lastRequestedSeekPosition;
  DateTime? _lastSeekRequestedAt;
  bool _isHandlingPlaybackCompletion = false;
  bool _hasPlaybackCompleted = false;
  int _playRequestId = 0;
  int _sessionGeneration = 0;
  int _controllerGeneration = 0;
  PlaybackSessionSnapshot _session = const PlaybackSessionSnapshot.idle();
  VideoPlayerController? _sessionController;
  int? _activePlayInvocationGeneration;
  final List<_EpisodeNavigationCommand> _pendingEpisodeNavigation =
      <_EpisodeNavigationCommand>[];
  bool _isDrainingEpisodeNavigation = false;
  Completer<void>? _episodeNavigationCompleter;
  Future<void>? _controllerErrorRecovery;

  // ===== 预加载下一个视频控制器 =====
  /// 预加载的控制器引用（后台 initialize，paused 状态）
  VideoPlayerController? _preloadedController;

  /// 预加载控制器对应的 item id
  String? _preloadedItemId;

  /// 预加载控制器对应的 playRequestId（防止竞态）
  int _preloadedRequestId = 0;

  /// 是否已触发预加载（避免重复触发）
  bool _preloadTriggered = false;

  /// 预加载进度阈值
  static const double _preloadThreshold = 0.8;

  // ===== 后台 dispose 追踪 =====
  /// 追踪正在后台 dispose 的旧控制器，防止泄漏
  final Set<VideoPlayerController> _disposingControllers =
      <VideoPlayerController>{};

  /// Mobile hardware decoders are a scarce resource. A new controller must
  /// not race the native disposal of the controller it replaces, otherwise
  /// the new player can intermittently fail to acquire a decoder while the
  /// app is backgrounded. Later play requests wait on the same barrier too.
  Future<void> _mobileControllerReleaseBarrier = Future<void>.value();

  /// 后台 dispose 完成后自动移除的 Future 数量上限
  static const int _maxDisposingControllers = 3;

  static const Duration _controllerSeekVerificationDelay = Duration(
    milliseconds: 180,
  );
  static const Duration _controllerSeekVerificationFollowUpDelay = Duration(
    milliseconds: 650,
  );
  static const Duration _controllerSeekTimeout = Duration(seconds: 2);
  static const Duration _controllerInitializeTimeout = Duration(seconds: 20);
  static const Duration _mobileControllerReleaseTimeout = Duration(seconds: 8);
  static const Duration _firstVideoFrameTimeout = Duration(seconds: 12);
  // One retry is enough for genuinely transient switch failures (e.g. a
  // decoder slot still releasing). Readiness degradation keeps clock/frame
  // timeouts out of this loop, so three reopen attempts per skip were pure
  // overhead that left notification-controlled switches stuck on loading.
  static const int _mediaSwitchMaxAttempts = 2;
  static const Duration _playbackCompletionConfirmationDelay = Duration(
    milliseconds: 140,
  );
  static const int _seekVerificationToleranceMs = 450;
  static const Duration _initialPositionGuardDuration = Duration(seconds: 2);
  static const Duration _backgroundMediaSyncInterval = Duration(
    milliseconds: 900,
  );
  static const Duration _streamQualityWarmFrameDelay = Duration(
    milliseconds: 45,
  );
  static const int _streamQualityHandoffToleranceMs = 60;
  static const Duration _streamQualityPhaseLockTimeout = Duration(seconds: 5);
  static const Duration _streamQualityPhaseLockSampleDelay = Duration(
    milliseconds: 32,
  );

  void _logPlaybackEvent(String message, {Map<String, Object?>? data}) {
    if (!kDebugMode) return;
    final buffer = StringBuffer('MediaPlaybackService: $message');
    if (data != null && data.isNotEmpty) {
      buffer.write(' | ');
      bool first = true;
      data.forEach((key, value) {
        if (!first) buffer.write(', ');
        first = false;
        buffer.write('$key=$value');
      });
    }
    debugPrint(buffer.toString());
  }

  void _syncWakelockWithState() {
    AppWakelockCoordinator.setActive(
      AppWakelockCoordinator.mediaPlaybackReason,
      _state == PlaybackState.playing && _isAppInForeground,
    );
    _syncBilibiliCachePolicy();
  }

  void _syncBilibiliCachePolicy() {
    final streaming = _bilibiliStreamingService;
    if (streaming == null) return;
    final item = _currentItem;
    streaming.updateCachePolicy(
      itemId: item?.id,
      isOnlineItem: item?.sourceRef?.kind == MediaSourceKind.bilibiliStream,
      isPlaying: _state == PlaybackState.playing,
      playbackPageVisible: _isAppInForeground && _playbackPageOwners.isNotEmpty,
      miniPlaybackCardVisible:
          _isAppInForeground && _miniPlaybackCardOwners.isNotEmpty,
      mediaNotificationVisible: _mediaNotificationVisible,
    );
    _syncBilibiliVideoTrackPolicy();
  }

  void _syncBilibiliVideoTrackPolicy() {
    final item = _currentItem;
    final controller = _controller;
    final isActiveOnlineStream =
        !kIsWeb &&
        (Platform.isAndroid || Platform.isIOS) &&
        item?.sourceRef?.kind == MediaSourceKind.bilibiliStream &&
        _currentBilibiliPlayback != null &&
        controller != null &&
        controller.value.isInitialized;
    if (!isActiveOnlineStream) {
      _requestedBilibiliVideoTrackEnabled = null;
      _bilibiliVideoTrackPolicyRevision++;
      return;
    }

    // Only a visible full playback page consumes video frames. Keep the exact
    // same Player, external audio track and clock everywhere else, but deselect
    // Bilibili's video track so libmpv stops requesting video bytes.
    final shouldEnableVideo =
        _isAppInForeground && _playbackPageOwners.isNotEmpty;
    if (_requestedBilibiliVideoTrackEnabled == shouldEnableVideo) return;
    _requestedBilibiliVideoTrackEnabled = shouldEnableVideo;
    final revision = ++_bilibiliVideoTrackPolicyRevision;
    final itemId = item!.id;
    unawaited(
      NativeVideoPlayerMediaKit.setExternalVideoTrackEnabledFor(
        // ignore: invalid_use_of_visible_for_testing_member
        controller.playerId,
        enabled: shouldEnableVideo,
      ).then((applied) {
        if (revision != _bilibiliVideoTrackPolicyRevision ||
            _currentItem?.id != itemId ||
            !identical(_controller, controller)) {
          return;
        }
        if (!applied) _requestedBilibiliVideoTrackEnabled = null;
      }),
    );
  }

  /// Registers whether a full playback page is currently visible. The owner
  /// token is the State object, so portrait/landscape hand-offs can overlap
  /// without one page accidentally disabling the other page's cache policy.
  void setPlaybackPageVisible(Object owner, bool visible) {
    if (visible) {
      _playbackPageOwners.add(owner);
    } else {
      _playbackPageOwners.remove(owner);
    }
    _syncBilibiliCachePolicy();
  }

  bool get _hasVisiblePlaybackPage =>
      _isAppInForeground && _playbackPageOwners.isNotEmpty;

  /// Registers the mini playback card independently from the full page.
  void setMiniPlaybackCardVisible(Object owner, bool visible) {
    if (visible) {
      _miniPlaybackCardOwners.add(owner);
    } else {
      _miniPlaybackCardOwners.remove(owner);
    }
    _syncBilibiliCachePolicy();
  }

  /// The system media notification is a cache context only on phones. The
  /// system-media service supplies this flag after it has published a current
  /// item notification.
  void setMediaNotificationVisible(bool visible) {
    if (_mediaNotificationVisible == visible) return;
    _mediaNotificationVisible = visible;
    _syncBilibiliCachePolicy();
  }

  static VideoPlayerOptions buildVideoPlayerOptions({
    SettingsService? settings,
  }) {
    final resolvedSettings = settings ?? SettingsService();
    return VideoPlayerOptions(
      mixWithOthers: resolvedSettings.allowConcurrentPlayback,
      // Keep background playback capability enabled and handle the
      // "leave app then pause" policy ourselves so toggles apply immediately.
      allowBackgroundPlayback: true,
    );
  }

  bool _controllerIsReusableForItem(VideoItem item) {
    final controller = _controller;
    if (_currentItem?.id != item.id || controller == null) {
      return false;
    }
    try {
      return controller.value.isInitialized;
    } catch (_) {
      return false;
    }
  }

  bool _isCurrentPlayRequest(
    int requestId,
    String itemId, {
    VideoPlayerController? controller,
  }) {
    if (requestId != _playRequestId || _currentItem?.id != itemId) {
      return false;
    }
    return controller == null || identical(_controller, controller);
  }

  bool _isCurrentControllerSession(
    VideoPlayerController controller,
    String? itemId,
  ) {
    return identical(_controller, controller) && _currentItem?.id == itemId;
  }

  void _clearInitialPositionGuard() {
    _initialPositionGuardTarget = null;
    _initialPositionGuardUntil = null;
  }

  void _armInitialPositionGuard(Duration target, {bool protectZero = false}) {
    if (target < Duration.zero || (!protectZero && target == Duration.zero)) {
      _clearInitialPositionGuard();
      return;
    }
    _initialPositionGuardTarget = target;
    _initialPositionGuardUntil = DateTime.now().add(
      _initialPositionGuardDuration,
    );
  }

  bool _shouldIgnoreInitialPositionSample(Duration sample) {
    final target = _initialPositionGuardTarget;
    final until = _initialPositionGuardUntil;
    if (target == null || until == null) return false;
    if (DateTime.now().isAfter(until)) {
      _clearInitialPositionGuard();
      return false;
    }
    final deltaMs = sample.inMilliseconds - target.inMilliseconds;
    // When playback is running, the first confirmed sample may already be a
    // little ahead of the target. A sample far behind or far ahead is still
    // from the pre-seek clock (especially noticeable on backward seeks).
    if (deltaMs >= -_seekVerificationToleranceMs &&
        deltaMs <= const Duration(seconds: 3).inMilliseconds) {
      _clearInitialPositionGuard();
      return false;
    }
    // Keep the optimistic service position until native playback catches up or
    // the bounded guard expires. This covers both forward and backward seeks.
    return true;
  }

  /// Establishes a deterministic starting point before playback is allowed to
  /// start. Some native backends probe a network source from byte zero during
  /// initialize and briefly report it as playing; seeking while that probe is
  /// still running can otherwise produce the visible "intro then saved
  /// position" jump.
  Future<void> _seekInitialPosition(
    VideoPlayerController controller,
    Duration requestedPosition,
  ) async {
    if (!controller.value.isInitialized) return;
    final previous = _initialPositionSeekInFlight;
    _initialPositionSeekInFlight = true;
    try {
      await _seekInitialPositionImpl(controller, requestedPosition);
    } finally {
      _initialPositionSeekInFlight = previous;
    }
  }

  Future<void> _seekInitialPositionImpl(
    VideoPlayerController controller,
    Duration requestedPosition,
  ) async {
    if (!controller.value.isInitialized) return;

    var target = requestedPosition < Duration.zero
        ? Duration.zero
        : requestedPosition;
    final duration = controller.value.duration;
    if (duration > Duration.zero && target >= duration) {
      target = Duration.zero;
    }

    try {
      // A new controller must be paused before both the zero seek and a
      // resumed seek. This is intentionally done even when the backend says it
      // is already paused, because it clears an implicit network-probe play.
      await controller.pause();
    } catch (_) {}

    Duration actual = await _readNativeControllerPosition(controller);
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        await controller.seekTo(target).timeout(_controllerSeekTimeout);
      } catch (_) {
        break;
      }

      // Verify against the native player rather than controller.value. Flutter
      // value notifications can be suspended in the background; treating that
      // stale value as a failed seek caused notification episode changes to
      // issue the same seek repeatedly and replay the target fragment.
      await Future<void>.delayed(const Duration(milliseconds: 60));
      actual = await _readNativeControllerPosition(controller);
      if ((actual.inMilliseconds - target.inMilliseconds).abs() <=
          _seekVerificationToleranceMs) {
        _position = target;
        break;
      }
    }

    actual = await _readNativeControllerPosition(controller);
    final accepted =
        (actual.inMilliseconds - target.inMilliseconds).abs() <=
        _seekVerificationToleranceMs;
    if (accepted) {
      _position = target;
      _armInitialPositionGuard(target);
    } else {
      // Never persist a requested position that the native backend rejected.
      // The next open will then resume from the actual confirmed position.
      _position = actual;
      _clearInitialPositionGuard();
    }
    try {
      // Seeking must finish in a paused state. autoPlay is applied explicitly
      // by the caller after this method returns.
      if (controller.value.isPlaying) {
        await controller.pause();
      }
    } catch (_) {}
    _bufferedPosition = _readBufferedPosition(controller);
  }

  void _trackMobileControllerRelease(Future<void> release) {
    if (kIsWeb || !(Platform.isAndroid || Platform.isIOS)) return;
    final previous = _mobileControllerReleaseBarrier;
    _mobileControllerReleaseBarrier = () async {
      await Future.wait<void>([
        _ignoreControllerReleaseError(previous),
        _ignoreControllerReleaseError(release),
      ]);
    }();
  }

  Future<void> _ignoreControllerReleaseError(Future<void> release) async {
    try {
      await release;
    } catch (error) {
      _logPlaybackEvent(
        'native controller release failed',
        data: <String, Object?>{'error': error.toString()},
      );
    }
  }

  Future<void> _disposeTrackedController(VideoPlayerController controller) {
    final release = () async {
      try {
        await controller.dispose();
      } catch (_) {}
    }();
    _trackMobileControllerRelease(release);
    return release;
  }

  Future<void> _detachController(
    VideoPlayerController controller, {
    required bool disposeController,
    bool pauseIfPlaying = false,
  }) async {
    _detachNativePositionStream(controller);
    try {
      controller.removeListener(_onControllerUpdate);
    } catch (_) {}

    if (pauseIfPlaying) {
      try {
        // A newly opened source must remain silent until its saved position is
        // confirmed and the latest episode-switch intent is committed. Pause
        // unconditionally because isPlaying may still be a stale Dart value.
        await controller.pause();
      } catch (_) {}
    }

    if (!disposeController) {
      return;
    }

    await _disposeTrackedController(controller);
  }

  void _attachNativePositionStream(VideoPlayerController controller) {
    _cancelNativePositionStream();
    // video_player exposes this identifier for platform-adapter integration.
    // ignore: invalid_use_of_visible_for_testing_member
    final playerId = controller.playerId;
    final positionStream = NativeVideoPlayerMediaKit.positionStreamFor(
      playerId,
    );
    final rateStream = NativeVideoPlayerMediaKit.rateStreamFor(playerId);
    if (positionStream == null && rateStream == null) return;
    _nativePositionPlayerId = playerId;
    _nativePresentationPlaybackSpeed = controller.value.playbackSpeed;
    if (positionStream != null) {
      _nativePositionSubscription = positionStream.listen((nativePosition) {
        if (!identical(_controller, controller) ||
            _pendingSeekRequestId != null) {
          return;
        }
        if (_shouldIgnoreInitialPositionSample(nativePosition)) return;
        _timelineClock.observeNativePosition(nativePosition);
      });
    }
    if (rateStream != null) {
      _nativeRateSubscription = rateStream.listen((nativeRate) {
        if (!identical(_controller, controller) ||
            !nativeRate.isFinite ||
            nativeRate <= 0) {
          return;
        }
        _nativePresentationPlaybackSpeed = nativeRate;
        if (_timelineClock.isInitialized) {
          // Preserve the currently presented position and change only its
          // slope. Progress, subtitles and danmaku therefore follow the rate
          // accepted by libmpv without jumping at either boundary.
          _timelineClock.setRate(nativeRate);
        }
      });
    }
  }

  void _detachNativePositionStream(VideoPlayerController controller) {
    // ignore: invalid_use_of_visible_for_testing_member
    if (_nativePositionPlayerId != controller.playerId) return;
    _cancelNativePositionStream();
  }

  void _cancelNativePositionStream() {
    final positionSubscription = _nativePositionSubscription;
    final rateSubscription = _nativeRateSubscription;
    _nativePositionSubscription = null;
    _nativeRateSubscription = null;
    _nativePositionPlayerId = null;
    _nativePresentationPlaybackSpeed = null;
    if (positionSubscription != null) {
      unawaited(positionSubscription.cancel());
    }
    if (rateSubscription != null) unawaited(rateSubscription.cancel());
  }

  void handleAppLifecycleState(AppLifecycleState? state) {
    final AppLifecycleState? previousState = _lastAppLifecycleState;
    _lastAppLifecycleState = state;

    final bool isForeground =
        state == null ||
        state == AppLifecycleState.resumed ||
        state == AppLifecycleState.inactive;
    _setAppForegroundState(isForeground);

    final bool shouldPauseForBackground =
        !kIsWeb &&
        (Platform.isAndroid || Platform.isIOS) &&
        SettingsService().pausePlaybackWhenAppBackgrounded &&
        _state == PlaybackState.playing &&
        (state == AppLifecycleState.hidden ||
            state == AppLifecycleState.detached ||
            (state == AppLifecycleState.paused &&
                previousState != AppLifecycleState.hidden));

    if (shouldPauseForBackground) {
      unawaited(pause());
    } else if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      // Even when the user has enabled background playback, persist the
      // authoritative service position before the process can be suspended or
      // killed. The playback page must not write a competing raw-controller
      // position during the same transition.
      unawaited(persistCurrentProgress());
    }
  }

  void setAppForegroundState(bool isForeground) {
    _setAppForegroundState(isForeground);
  }

  void _setAppForegroundState(bool isForeground) {
    if (_isAppInForeground == isForeground) return;
    _isAppInForeground = isForeground;
    _syncWakelockWithState();

    if (_state == PlaybackState.playing) {
      if (isForeground) {
        // The frame ticker is suspended while the app is backgrounded, while
        // the native player keeps advancing. Read that player's clock directly
        // before restarting the ticker: controller.value may still contain the
        // final background Dart sample and would make the foreground UI jump
        // backward before catching up.
        _stopRealtimeSyncLoop();
        final controller = _controller;
        final itemId = _currentItem?.id;
        if (controller != null &&
            itemId != null &&
            controller.value.isInitialized) {
          // ignore: invalid_use_of_visible_for_testing_member
          final playerId = controller.playerId;
          final nativeClock = NativeVideoPlayerMediaKit.positionStreamFor(
            playerId,
          );
          if (nativeClock == null) {
            // Other platform adapters keep controller.value authoritative.
            _updatePosition();
            _resetPlaybackTimeline(_position, running: _shouldTimelineRun());
            _startRealtimeSyncLoop();
          } else {
            unawaited(_reanchorForegroundClock(controller, itemId));
          }
        } else {
          _startRealtimeSyncLoop();
        }
      } else {
        _startRealtimeSyncLoop();
      }
    }
    if (isForeground && _playbackPageOwners.isNotEmpty) {
      final item = _currentItem;
      if (item != null) unawaited(ensureVisibleVideoOutput(item.id));
    }
  }

  Future<void> _reanchorForegroundClock(
    VideoPlayerController controller,
    String itemId,
  ) async {
    final nativePosition = await _readNativeControllerPosition(controller);
    if (!_isAppInForeground ||
        _currentItem?.id != itemId ||
        !identical(_controller, controller)) {
      return;
    }

    var position = nativePosition < Duration.zero
        ? Duration.zero
        : nativePosition;
    final controllerDuration = controller.value.duration;
    if (controllerDuration > Duration.zero) {
      _duration = controllerDuration;
      if (position > controllerDuration) position = controllerDuration;
    }
    _position = position;
    _bufferedPosition = _readBufferedPosition(controller);
    _setCoarsePosition(position);
    _resetPlaybackTimeline(position, running: _shouldTimelineRun());
    _startRealtimeSyncLoop();
    notifyListeners();
  }

  // Getters
  PlaybackState get state => _state;
  VideoItem? get currentItem => _currentItem;
  Duration get position => _position;
  Duration get duration => _duration;
  Duration get bufferedPosition => _bufferedPosition;
  bool get isPlaying => _state == PlaybackState.playing;
  bool get desiredPlaying => _session.desiredPlaying;
  PlaybackSessionSnapshot get session => _session;
  int get sessionGeneration => _session.generation;
  bool get isSourceMissing => _isSourceMissing;
  List<BilibiliStreamQuality> get streamQualities => _streamQualities;
  BilibiliStreamQuality? get selectedStreamQuality => _selectedStreamQuality;
  double? get streamDisplayAspectRatio => _streamDisplayAspectRatio;
  bool get isSwitchingStreamQuality => _isSwitchingStreamQuality;
  bool get isCurrentItemBilibiliStream =>
      _currentItem?.sourceRef?.kind == MediaSourceKind.bilibiliStream;
  bool get isCurrentItemOnlineBilibiliStream =>
      isCurrentItemBilibiliStream && _currentBilibiliPlayback != null;

  /// Whether the active native controller is safe for a playback page to
  /// mount, even while the session is still waiting for its first video frame.
  ///
  /// `loading` describes playback readiness, not controller availability. A
  /// visible media_kit output may need to be mounted before its first rendered
  /// frame can arrive, so pages must not use the state alone as a mount gate.
  bool get hasMountableController {
    final controller = _controller;
    final item = _currentItem;
    return controller != null &&
        item != null &&
        identical(controller, _sessionController) &&
        _session.itemId == item.id &&
        _session.isControllerMountable &&
        controller.value.isInitialized &&
        !controller.value.hasError &&
        _controllerHasRequiredVideoOutput(item, controller);
  }

  bool canMountControllerFor(
    String itemId, {
    VideoPlayerController? controller,
  }) {
    final candidate = controller ?? _controller;
    return candidate != null &&
        identical(candidate, _controller) &&
        _currentItem?.id == itemId &&
        _session.itemId == itemId &&
        identical(candidate, _sessionController) &&
        _session.isControllerMountable &&
        candidate.value.isInitialized &&
        !candidate.value.hasError &&
        _controllerHasRequiredVideoOutput(_currentItem!, candidate);
  }

  bool _controllerHasRequiredVideoOutput(
    VideoItem item,
    VideoPlayerController controller,
  ) {
    if (item.type == MediaType.audio || kIsWeb) return true;
    // ignore: invalid_use_of_visible_for_testing_member
    return NativeVideoPlayerMediaKit.hasVideoOutputFor(controller.playerId) !=
        false;
  }

  int _beginPlaybackSession(VideoItem item, {required bool desiredPlaying}) {
    final generation = ++_sessionGeneration;
    _sessionController = null;
    _session = PlaybackSessionSnapshot(
      generation: generation,
      itemId: item.id,
      phase: PlaybackSessionPhase.resolving,
      desiredPlaying: desiredPlaying,
      controllerGeneration: _controllerGeneration,
      hasVideoOutput: false,
    );
    return generation;
  }

  void _transitionPlaybackSession(
    int generation,
    PlaybackSessionPhase phase, {
    VideoPlayerController? controller,
    bool? desiredPlaying,
    String? error,
  }) {
    if (_session.generation != generation) return;
    var controllerGeneration = _session.controllerGeneration;
    var hasVideoOutput = _session.hasVideoOutput;
    if (controller != null) {
      if (!identical(_sessionController, controller)) {
        _sessionController = controller;
        controllerGeneration = ++_controllerGeneration;
      }
      final item = _currentItem;
      hasVideoOutput =
          item != null &&
          item.id == _session.itemId &&
          _controllerHasRequiredVideoOutput(item, controller);
    } else if (phase == PlaybackSessionPhase.missing ||
        phase == PlaybackSessionPhase.failed ||
        phase == PlaybackSessionPhase.stopped ||
        phase == PlaybackSessionPhase.idle) {
      _sessionController = null;
      hasVideoOutput = false;
    }
    _session = _session.copyWith(
      phase: phase,
      desiredPlaying: desiredPlaying,
      controllerGeneration: controllerGeneration,
      hasVideoOutput: hasVideoOutput,
      error: error,
      clearError: error == null,
    );
  }

  void _setDesiredPlaying(bool value) {
    _session = _session.copyWith(desiredPlaying: value);
  }

  bool _isControllerReadyForItem(VideoItem item) {
    final controller = _controller;
    if (_currentItem?.id != item.id ||
        controller == null ||
        !identical(controller, _sessionController) ||
        _session.itemId != item.id ||
        !_session.isControllerMountable ||
        !controller.value.isInitialized ||
        controller.value.hasError ||
        _state == PlaybackState.error ||
        _state == PlaybackState.loading) {
      return false;
    }
    // A background Android video intentionally has no Flutter texture, but its
    // native media clock is already a complete playback session. Requiring a
    // mountable texture here made every notification skip retry the entire
    // source up to three times, including three opens and three seeks. Only a
    // genuinely visible page requires video output before the request is done.
    if (playbackRequestNeedsVideoOutput(
          isVideo: item.type == MediaType.video,
          hasVisiblePlaybackPage: _hasVisiblePlaybackPage,
        ) &&
        !_controllerHasRequiredVideoOutput(item, controller)) {
      return false;
    }
    if (!_session.desiredPlaying) return _state == PlaybackState.paused;
    if (_state != PlaybackState.playing) return false;
    return !_hasVisiblePlaybackPage || controller.value.isPlaying;
  }

  /// Makes the latest session intent authoritative after any asynchronous
  /// initialize/play/readiness work. Notification and mini-player commands
  /// are allowed to change that intent while a media switch is in flight.
  Future<bool> _commitControllerPlaybackIntent({
    required int sessionGeneration,
    required int playRequestId,
    required VideoItem item,
    required VideoPlayerController controller,
  }) async {
    if (!_isCurrentPlayRequest(
      playRequestId,
      item.id,
      controller: controller,
    )) {
      return false;
    }
    final desiredPlaying = _session.generation == sessionGeneration
        ? _session.desiredPlaying
        : false;
    if (desiredPlaying && !controller.value.isPlaying) {
      await controller.play();
    } else if (!desiredPlaying) {
      // Always send pause for a pause-on-switch request. The Dart value can
      // lag the native player by one event while open/seek is completing;
      // checking isPlaying here allowed a few native packets to escape even
      // though the switch setting was off.
      await controller.pause();
    }
    if (!_isCurrentPlayRequest(
      playRequestId,
      item.id,
      controller: controller,
    )) {
      return false;
    }

    _lastControllerIsPlaying = controller.value.isPlaying;
    _state = desiredPlaying ? PlaybackState.playing : PlaybackState.paused;
    _resetPlaybackTimeline(
      _position,
      running: desiredPlaying && controller.value.isPlaying,
    );
    if (desiredPlaying) {
      _startProgressTracking();
    } else {
      _stopProgressTracking();
    }
    _transitionPlaybackSession(
      sessionGeneration,
      _controllerHasRequiredVideoOutput(item, controller)
          ? PlaybackSessionPhase.ready
          : PlaybackSessionPhase.videoOutputDeferred,
      controller: controller,
      desiredPlaying: desiredPlaying,
    );
    _syncWakelockWithState();
    notifyListeners();
    return true;
  }

  @visibleForTesting
  static bool playbackRequestNeedsVideoOutput({
    required bool isVideo,
    required bool hasVisiblePlaybackPage,
  }) {
    return isVideo && hasVisiblePlaybackPage;
  }

  /// True only for an Android video player intentionally created headless in
  /// the background. Normal foreground controllers must never be rebuilt while
  /// a route transition is waiting for its first frame.
  bool needsVisibleVideoOutputRecovery(String itemId) {
    final item = _currentItem;
    final controller = _controller;
    if (kIsWeb ||
        !Platform.isAndroid ||
        item == null ||
        item.id != itemId ||
        item.type != MediaType.video ||
        !_controllerCreatedWithoutVisiblePlaybackPage ||
        controller == null ||
        !controller.value.isInitialized) {
      return false;
    }
    return NativeVideoPlayerMediaKit.hasVideoOutputFor(
          // ignore: invalid_use_of_visible_for_testing_member
          controller.playerId,
        ) ==
        false;
  }

  /// Readiness probe that never fails the surrounding play request.
  ///
  /// A notification-controlled background switch must not be torn down and
  /// retried just because its native clock start was not observed in time:
  /// retrying reopened the source up to three times and left the notification
  /// stuck on loading. Instead, an unconfirmed transport is parked paused at
  /// the seek target and reported as [_PlaybackReadinessResult.degraded], and
  /// an explicit play command (notification, mini player, page) resumes it.
  Future<_PlaybackReadinessResult> _awaitPlaybackReadinessResult({
    required VideoItem item,
    required VideoPlayerController controller,
    required int playRequestId,
  }) async {
    if (!_hasVisiblePlaybackPage) {
      final playbackReady = NativeVideoPlayerMediaKit.playbackReadyFor(
        // ignore: invalid_use_of_visible_for_testing_member
        controller.playerId,
      );
      if (playbackReady == null) {
        return _PlaybackReadinessResult.confirmed;
      }
      final ready = await playbackReady.timeout(
        _controllerInitializeTimeout,
        onTimeout: () => false,
      );
      if (!ready &&
          _isCurrentPlayRequest(
            playRequestId,
            item.id,
            controller: controller,
          )) {
        _logPlaybackEvent(
          'background playback clock did not start in time; '
          'parking session as paused at the seek target',
          data: <String, Object?>{
            'itemId': item.id,
            'positionMs': _position.inMilliseconds,
          },
        );
        try {
          if (controller.value.isPlaying) await controller.pause();
        } catch (_) {}
        return _PlaybackReadinessResult.degraded;
      }
      return _PlaybackReadinessResult.confirmed;
    }
    if (item.type != MediaType.video) {
      return _PlaybackReadinessResult.confirmed;
    }
    final firstFrame = NativeVideoPlayerMediaKit.firstFrameRenderedFor(
      // ignore: invalid_use_of_visible_for_testing_member
      controller.playerId,
    );
    if (firstFrame == null) return _PlaybackReadinessResult.confirmed;

    try {
      await firstFrame.timeout(_firstVideoFrameTimeout);
      return _PlaybackReadinessResult.confirmed;
    } on TimeoutException {
      if (!_isCurrentPlayRequest(
        playRequestId,
        item.id,
        controller: controller,
      )) {
        return _PlaybackReadinessResult.confirmed;
      }
      _logPlaybackEvent(
        'first video frame timed out; recovering decoder output',
        data: <String, Object?>{'itemId': item.id},
      );
    }

    final recovered = await NativeVideoPlayerMediaKit.recoverVideoOutputFor(
      // ignore: invalid_use_of_visible_for_testing_member
      controller.playerId,
    ).timeout(_controllerInitializeTimeout, onTimeout: () => false);
    if (!recovered) {
      // Foreground decoder produced no frame. Degrade to a paused session at
      // the target position instead of entering the error state: the mounted
      // page keeps its controls, and a manual play retries the transport
      // without reopening the media source.
      _logPlaybackEvent(
        'video decoder produced no frame; parking session as paused',
        data: <String, Object?>{'itemId': item.id},
      );
      try {
        if (controller.value.isPlaying) await controller.pause();
      } catch (_) {}
      return _PlaybackReadinessResult.degraded;
    }
    await firstFrame.timeout(_firstVideoFrameTimeout);
    return _PlaybackReadinessResult.confirmed;
  }

  void _primeDeferredVideoOutput(
    VideoItem item,
    VideoPlayerController controller,
  ) {
    // Split Bilibili streams deliberately stay audio-only until an actual
    // playback page becomes visible. Local files never reach this branch.
    if (item.sourceRef?.kind == MediaSourceKind.bilibiliStream &&
        !_hasVisiblePlaybackPage) {
      return;
    }
    if (!needsVisibleVideoOutputRecovery(item.id)) return;
    // Start render-output creation while the notification-controlled session
    // is still in the background. This is intentionally non-blocking: audio
    // playback and command acknowledgement must not wait for Flutter texture
    // work, but foreground entry can join the same pending attachment.
    // ignore: invalid_use_of_visible_for_testing_member
    final playerId = controller.playerId;
    unawaited(
      NativeVideoPlayerMediaKit.attachVideoOutputFor(playerId).then((attached) {
        if (!attached ||
            _currentItem?.id != item.id ||
            !identical(_controller, controller) ||
            controller.value.hasError) {
          return;
        }
        _controllerCreatedWithoutVisiblePlaybackPage = false;
        _transitionPlaybackSession(
          _session.generation,
          _state == PlaybackState.loading
              ? PlaybackSessionPhase.controllerMountable
              : PlaybackSessionPhase.ready,
          controller: controller,
          desiredPlaying: _session.desiredPlaying,
        );
        notifyListeners();
        _logPlaybackEvent(
          'background video output primed on existing player',
          data: <String, Object?>{'itemId': item.id, 'playerId': playerId},
        );
      }),
    );
  }

  /// Adds a visible texture to a controller created while Android was
  /// backgrounded. It first tries to join/attach output to the existing native
  /// player, preserving its decoder, Bilibili gateway, cache, exact clock and
  /// play/pause state. Only when both attachment attempts fail does it fall
  /// back to a controlled reopen of the same media at the same position with
  /// the same play/pause intent — so foreground entry always lands on a
  /// working session instead of one permanently stuck without video output.
  Future<bool> ensureVisibleVideoOutput(String itemId) {
    final existing = _visibleVideoOutputRecovery;
    if (existing != null) return existing;
    final item = _currentItem;
    final controller = _controller;
    if (!needsVisibleVideoOutputRecovery(itemId) ||
        item == null ||
        controller == null) {
      if (item?.id == itemId && item?.type == MediaType.video) {
        _controllerCreatedWithoutVisiblePlaybackPage = false;
      }
      return Future<bool>.value(true);
    }

    late final Future<bool> recovery;
    recovery =
        () async {
          // ignore: invalid_use_of_visible_for_testing_member
          final playerId = controller.playerId;
          _logPlaybackEvent(
            'attaching visible output to background player',
            data: <String, Object?>{'itemId': item.id, 'playerId': playerId},
          );
          var attached = false;
          for (var attempt = 0; attempt < 2 && !attached; attempt++) {
            attached = await NativeVideoPlayerMediaKit.attachVideoOutputFor(
              playerId,
            );
            if (!attached && attempt == 0) {
              await Future<void>.delayed(const Duration(milliseconds: 100));
            }
          }
          if (_currentItem?.id != item.id ||
              !identical(_controller, controller)) {
            return false;
          }
          if (attached && !controller.value.hasError) {
            _controllerCreatedWithoutVisiblePlaybackPage = false;
            _transitionPlaybackSession(
              _session.generation,
              _state == PlaybackState.loading
                  ? PlaybackSessionPhase.controllerMountable
                  : PlaybackSessionPhase.ready,
              controller: controller,
              desiredPlaying: _session.desiredPlaying,
            );
            notifyListeners();
            _logPlaybackEvent(
              'visible output attached without reopening media',
              data: <String, Object?>{'itemId': item.id, 'playerId': playerId},
            );
            return true;
          }

          _logPlaybackEvent(
            'visible output attachment failed',
            data: <String, Object?>{'itemId': item.id, 'playerId': playerId},
          );
          if (!_isAppInForeground) {
            // The app went back to the background while attaching. Reopening
            // now would create another headless session; leave recovery to the
            // next foreground entry.
            return false;
          }
          if (isEpisodeNavigationBusy) {
            // An episode switch is in flight; its own play request will build
            // a fresh foreground session. Reopening the stale item here would
            // race that switch and cancel it.
            _logPlaybackEvent(
              'skipping visible-output reopen while an episode switch is in '
              'flight',
              data: <String, Object?>{'itemId': item.id},
            );
            return false;
          }
          // Last-resort fallback: the Flutter texture could not be re-attached
          // to the existing native player (e.g. Android reclaimed the surface
          // while backgrounded). Reopen the same media at the same position
          // with the same play/pause intent so the user still gets a working
          // session. Because we are foreground now, play() creates the
          // controller with a real video output and clears the deferred flag.
          final resumePosition = _position;
          final desiredPlaying = _session.desiredPlaying;
          _logPlaybackEvent(
            'reopening media with preserved position after failed output '
            'attachment',
            data: <String, Object?>{
              'itemId': item.id,
              'resumeMs': resumePosition.inMilliseconds,
              'autoPlay': desiredPlaying,
            },
          );
          await play(
            item,
            startPosition: resumePosition,
            autoPlay: desiredPlaying,
          );
          return _currentItem?.id == item.id &&
              _controller != null &&
              !needsVisibleVideoOutputRecovery(item.id);
        }().whenComplete(() {
          if (identical(_visibleVideoOutputRecovery, recovery)) {
            _visibleVideoOutputRecovery = null;
          }
        });
    _visibleVideoOutputRecovery = recovery;
    return recovery;
  }

  /// Whether an item can be opened without first asking the user to restore
  /// its source. Online Bilibili cards are virtual sources; every other item
  /// follows the same local-file requirement used by [play].
  bool hasUsableSource(VideoItem item) {
    final manager = _playlistManager;
    if (manager != null) return manager.isQueueEligible(item);
    return PlaybackQueuePolicy().isEligible(item);
  }

  VideoItem? _findPlayableRelative({
    required bool next,
    bool wrap = false,
    bool includeCurrentAfterWrap = false,
  }) {
    final manager = _playlistManager;
    if (manager == null) return null;
    final playlist = manager.playlist;
    final currentIndex = manager.currentIndex;
    if (playlist.isEmpty ||
        currentIndex < 0 ||
        currentIndex >= playlist.length) {
      return null;
    }

    if (playlist.length == 1) {
      return wrap && includeCurrentAfterWrap ? playlist.first : null;
    }
    var index = currentIndex + (next ? 1 : -1);
    if (wrap) {
      index %= playlist.length;
      if (index < 0) index += playlist.length;
      return playlist[index];
    }
    return index >= 0 && index < playlist.length ? playlist[index] : null;
  }

  VideoItem? get nextPlayableItem => _findPlayableRelative(next: true);
  VideoItem? get previousPlayableItem => _findPlayableRelative(next: false);
  bool get hasPlayableNext => nextPlayableItem != null;
  bool get hasPlayablePrevious => previousPlayableItem != null;

  /// True while an episode-switch command is queued or executing. Foreground
  /// recovery (visible-output reopen) must not interleave with it.
  bool get isEpisodeNavigationBusy =>
      _isDrainingEpisodeNavigation || _pendingEpisodeNavigation.isNotEmpty;
  bool get isMuted => _isMuted;
  double get volume => _volume;
  double get playbackSpeed => _playbackSpeed;
  double get confirmedPlaybackSpeed => _confirmedPlaybackSpeed;
  bool get isTemporaryPlaybackSpeedActive =>
      _temporaryPlaybackBaseSpeed != null;
  VideoPlayerController? get controller => _controller;
  List<SubtitleItem> get subtitles => _subtitles;
  List<SubtitleItem> get secondarySubtitles => _secondarySubtitles;
  List<String> get subtitlePaths => _subtitlePaths;
  int get subtitleRevision => _subtitleRevision;
  SubtitleItem? get currentSubtitle => _currentSubtitle;

  /// 初始化服务依赖
  Future<void> initialize({
    required PlaylistManager playlistManager,
    required ProgressTracker progressTracker,
    LibraryService? libraryService,
    EmbeddedSubtitleService? embeddedSubtitleService,
    BilibiliStreamingService? bilibiliStreamingService,
  }) async {
    _playlistManager = playlistManager;
    _progressTracker = progressTracker;
    _libraryService = libraryService;
    _embeddedSubtitleService = embeddedSubtitleService;
    _bilibiliStreamingService = bilibiliStreamingService;
    _attachPlaybackMaterializedListener();
    await _restorePersistedMuteState(notify: false);
    _syncBilibiliCachePolicy();
  }

  bool _playbackMaterializedListenerAttached = false;

  /// 合成/OCR 下载的素材在后台补齐为可直接播放的文件时，把当前正在在线
  /// 播放的同卡片会话切换到“本地素材”档，实现“下载好即离线复用”。
  void _attachPlaybackMaterializedListener() {
    if (_playbackMaterializedListenerAttached) return;
    final materialization = _libraryService?.mediaMaterializationService;
    if (materialization == null) return;
    _playbackMaterializedListenerAttached = true;
    materialization.addPlaybackMaterializedListener(
      _onLocalPlaybackMaterialized,
    );
  }

  void _onLocalPlaybackMaterialized(String itemId) {
    final item = _currentItem;
    if (item == null || item.id != itemId) return;
    if (item.sourceRef?.kind != MediaSourceKind.bilibiliStream) return;
    if (_isSwitchingStreamQuality) return;
    if (_selectedStreamQuality?.isLocalMaterialized == true) return;
    if (_state != PlaybackState.playing && _state != PlaybackState.paused) {
      return;
    }
    unawaited(_adoptMaterializedLocalPlayback(item));
  }

  Future<void> _adoptMaterializedLocalPlayback(VideoItem item) async {
    try {
      final lease = await _libraryService?.acquireExistingMaterializedPlayback(
        item,
      );
      if (lease == null) return;
      await lease.release();
      if (_currentItem?.id != item.id ||
          _isSwitchingStreamQuality ||
          _selectedStreamQuality?.isLocalMaterialized == true) {
        return;
      }
      _logPlaybackEvent(
        'local materialized playback became available; switching source',
        data: <String, Object?>{'itemId': item.id},
      );
      await switchBilibiliStreamQuality(
        BilibiliStreamQuality.localMaterializedId,
      );
    } catch (error) {
      _logPlaybackEvent(
        'local materialized playback adoption failed',
        data: <String, Object?>{'itemId': item.id, 'error': '$error'},
      );
    }
  }

  /// Returns whether the requested quality (or Bilibili's lower fallback) was
  /// actually committed. Failed warm-up deliberately leaves the visible player
  /// untouched, so the UI can report a rollback instead of ignoring the click.
  Future<bool> switchBilibiliStreamQuality(int qualityId) async {
    final item = _currentItem;
    final streaming = _bilibiliStreamingService;
    final previousController = _controller;
    if (item == null ||
        streaming == null ||
        previousController == null ||
        !previousController.value.isInitialized ||
        item.sourceRef?.kind != MediaSourceKind.bilibiliStream ||
        _isSwitchingStreamQuality ||
        _selectedStreamQuality?.id == qualityId) {
      return _selectedStreamQuality?.id == qualityId;
    }

    if (qualityId == BilibiliStreamQuality.localMaterializedId) {
      final lease = await _libraryService?.acquireExistingMaterializedPlayback(
        item,
      );
      if (lease == null) return false;
      await lease.release();
      await play(
        item,
        startPosition: _streamQualityHandoffPosition(),
        autoPlay: _state == PlaybackState.playing,
        forceRecreate: true,
      );
      return _selectedStreamQuality?.id == qualityId;
    }

    final switchRequestId = ++_streamQualitySwitchRequestId;
    final previousPlayback = _currentBilibiliPlayback;
    final previousMaterializedLease = _currentMaterializedPlaybackLease;
    final previousSelectedQuality = _selectedStreamQuality;
    final previousControllerOwned = _serviceOwnsController;
    BilibiliPreparedPlayback? preparedPlayback;
    VideoPlayerController? warmController;
    var committed = false;

    _isSwitchingStreamQuality = true;
    notifyListeners();

    try {
      preparedPlayback = await streaming.prepare(item, qualityId: qualityId);
      if (!_isCurrentStreamQualitySwitch(
        switchRequestId,
        item.id,
        previousController,
      )) {
        return false;
      }

      // Bilibili can map a requested quality to the same lower fallback that
      // is already active. Avoid a pointless decoder hand-off in that case.
      if (preparedPlayback.selectedQuality.id == previousSelectedQuality?.id) {
        streaming.rememberQuality(item.id, preparedPlayback.selectedQuality.id);
        return true;
      }

      warmController = _createBilibiliStreamController(preparedPlayback);
      try {
        await warmController.initialize();
      } catch (error) {
        await _detachController(
          warmController,
          disposeController: true,
          pauseIfPlaying: true,
        );
        warmController = null;
        await streaming.releasePlayback(preparedPlayback);
        preparedPlayback = null;

        // A few phones expose only one hardware decoder at the selected
        // resolution. They cannot keep the old and new tracks alive together;
        // fall back only for a positively identified decoder-capacity error.
        if (_isMobileDecoderCapacityError(error) &&
            _isCurrentStreamQualitySwitch(
              switchRequestId,
              item.id,
              previousController,
            )) {
          streaming.rememberQuality(item.id, qualityId);
          await play(
            item,
            startPosition: _streamQualityHandoffPosition(),
            autoPlay: _state == PlaybackState.playing,
            forceRecreate: true,
          );
          return _selectedStreamQuality?.id == qualityId;
        } else {
          _logPlaybackEvent(
            'stream quality warm-up failed; keeping previous stream',
            data: <String, Object?>{
              'itemId': item.id,
              'qualityId': qualityId,
              'error': error,
            },
          );
        }
        return false;
      }

      if (!_isCurrentStreamQualitySwitch(
        switchRequestId,
        item.id,
        previousController,
      )) {
        return false;
      }

      await _prepareStreamQualityHandoff(controller: warmController);
      if (!_isCurrentStreamQualitySwitch(
        switchRequestId,
        item.id,
        previousController,
      )) {
        return false;
      }

      final shouldPlay = _state == PlaybackState.playing;
      final handoffPosition = await _synchronizeStreamQualityAtCommit(
        controller: warmController,
        previousController: previousController,
        shouldPlay: shouldPlay,
      );
      if (!_isCurrentStreamQualitySwitch(
        switchRequestId,
        item.id,
        previousController,
      )) {
        return false;
      }

      _commitStreamQualityHandoff(
        item: item,
        controller: warmController,
        preparedPlayback: preparedPlayback,
        position: handoffPosition,
        shouldPlay: shouldPlay,
      );
      committed = true;
      warmController = null;
      preparedPlayback = null;

      streaming.rememberQuality(item.id, _selectedStreamQuality!.id);
      unawaited(_savePlaybackStateSnapshot());

      // Silence the old audio immediately, but retain its decoded texture
      // through the Flutter frame that mounts the replacement. Disposing it in
      // the same event turn can make the texture registrar publish one empty
      // frame even though both native players were otherwise ready.
      try {
        if (previousController.value.isPlaying) {
          unawaited(previousController.pause());
        }
      } catch (_) {}
      unawaited(
        _releasePreviousStreamAfterHandoffFrame(
          controller: previousController,
          disposeController: previousControllerOwned,
          streaming: streaming,
          playback: previousPlayback,
          materializedLease: previousMaterializedLease,
        ),
      );

      final activeController = _controller;
      if (activeController != null) {
        unawaited(
          activeController.setVolume(_isMuted ? 0.0 : _volume).catchError((
            Object error,
          ) {
            _logPlaybackEvent(
              'stream quality hand-off volume restore failed',
              data: <String, Object?>{'error': error},
            );
          }),
        );
      }
      return true;
    } catch (error) {
      _logPlaybackEvent(
        'stream quality hand-off failed; keeping previous stream',
        data: <String, Object?>{
          'itemId': item.id,
          'qualityId': qualityId,
          'error': error,
        },
      );
      return false;
    } finally {
      if (!committed && warmController != null) {
        await _detachController(
          warmController,
          disposeController: true,
          pauseIfPlaying: true,
        );
      }
      if (!committed && preparedPlayback != null) {
        await streaming.releasePlayback(preparedPlayback);
      }
      if (switchRequestId == _streamQualitySwitchRequestId) {
        _isSwitchingStreamQuality = false;
        notifyListeners();
      }
    }
  }

  /// Tries to move an actively materialized Bilibili player back to its
  /// online stream before cache deletion. A false result means the caller
  /// must defer deletion until the current file lease is released.
  Future<bool> releaseMaterializedPlaybackForClear(String itemId) async {
    final item = _currentItem;
    if (item?.id != itemId || _currentMaterializedPlaybackLease == null) {
      return true;
    }
    BilibiliStreamQuality? onlineQuality;
    for (final quality in _streamQualities) {
      if (!quality.isLocalMaterialized) {
        onlineQuality = quality;
        break;
      }
    }
    if (onlineQuality == null) {
      try {
        final qualities = await _bilibiliStreamingService?.listQualities(item!);
        if (qualities != null && qualities.isNotEmpty) {
          onlineQuality = qualities.first;
        }
      } catch (_) {}
    }
    if (onlineQuality == null) return false;
    await switchBilibiliStreamQuality(onlineQuality.id);
    return _currentMaterializedPlaybackLease == null;
  }

  VideoPlayerController _createBilibiliStreamController(
    BilibiliPreparedPlayback playback,
  ) {
    return VideoPlayerController.networkUrl(
      playback.videoUri,
      httpHeaders: <String, String>{
        NativeVideoPlayerMediaKit.externalAudioSourceHeader: playback.audioUri
            .toString(),
      },
      videoPlayerOptions: buildVideoPlayerOptions(),
    );
  }

  bool _isCurrentStreamQualitySwitch(
    int requestId,
    String itemId,
    VideoPlayerController previousController,
  ) {
    return requestId == _streamQualitySwitchRequestId &&
        _currentItem?.id == itemId &&
        identical(_controller, previousController) &&
        previousController.value.isInitialized;
  }

  Duration _streamQualityHandoffPosition() {
    var position = positionNotifier.value;
    if (position < Duration.zero) position = Duration.zero;
    final effectiveDuration = _duration;
    if (effectiveDuration > Duration.zero && position > effectiveDuration) {
      position = effectiveDuration;
    }
    return position;
  }

  Future<void> _prepareStreamQualityHandoff({
    required VideoPlayerController controller,
  }) async {
    await controller.setVolume(0.0);
    final targetSpeed = _playbackSpeed;
    if ((controller.value.playbackSpeed - targetSpeed).abs() >= 0.001) {
      await controller.setPlaybackSpeed(targetSpeed);
    }

    await _seekWarmController(controller, _streamQualityHandoffPosition());
    // Pre-roll even when the visible player is paused. The candidate is muted,
    // and replaying then seeking back is the only portable way to make Android
    // SurfaceTexture, AVPlayer and desktop texture backends all decode a frame
    // before their widget is attached.
    await controller.play();
    await _waitForWarmStreamFrame(controller);

    if (_state != PlaybackState.playing) {
      // Keep the last frame produced by pre-roll. Seeking again while paused
      // can clear a desktop texture without asking the decoder for a
      // replacement frame, which presents as black video with healthy audio.
      await controller.pause();
    }
  }

  Future<Duration> _synchronizeStreamQualityAtCommit({
    required VideoPlayerController controller,
    required VideoPlayerController previousController,
    required bool shouldPlay,
  }) async {
    if (!shouldPlay) {
      return _synchronizePausedStreamQualityAtCommit(
        controller: controller,
        previousController: previousController,
      );
    }

    return _phaseLockPlayingStreamQualityAtCommit(
      controller: controller,
      previousController: previousController,
    );
  }

  /// Phase-locks the already decoded replacement without seeking it again.
  /// A post-warm seek can invalidate a Windows texture after media_kit's
  /// one-shot first-frame signal has completed, producing black video while
  /// the external audio track continues normally.
  Future<Duration> _phaseLockPlayingStreamQualityAtCommit({
    required VideoPlayerController controller,
    required VideoPlayerController previousController,
  }) async {
    final normalSpeed = _playbackSpeed;
    var appliedSpeed = controller.value.playbackSpeed;
    final deadline = DateTime.now().add(_streamQualityPhaseLockTimeout);

    Future<void> setCandidateSpeed(double speed) async {
      if ((appliedSpeed - speed).abs() < 0.01) return;
      await controller.setPlaybackSpeed(speed);
      appliedSpeed = speed;
    }

    try {
      if (!controller.value.isPlaying) await controller.play();
      while (DateTime.now().isBefore(deadline)) {
        if (controller.value.hasError) {
          throw StateError(
            controller.value.errorDescription ?? 'replacement stream failed',
          );
        }

        if (controller.value.isBuffering) {
          await Future<void>.delayed(_streamQualityPhaseLockSampleDelay);
          continue;
        }

        final positions = await Future.wait<Duration>(<Future<Duration>>[
          _readNativeControllerPosition(previousController),
          _readNativeControllerPosition(controller),
        ]);
        final deltaMs =
            positions[1].inMilliseconds - positions[0].inMilliseconds;

        if (deltaMs.abs() <= _streamQualityHandoffToleranceMs) {
          await setCandidateSpeed(normalSpeed);
          if (!controller.value.isPlaying) await controller.play();

          // Confirm one more presentation interval at normal speed. No seek is
          // allowed after this confirmation, so the decoded texture remains
          // valid when Flutter mounts it.
          await Future<void>.delayed(_streamQualityPhaseLockSampleDelay);
          if (controller.value.isBuffering) continue;
          final confirmation = await Future.wait<Duration>(<Future<Duration>>[
            _readNativeControllerPosition(previousController),
            _readNativeControllerPosition(controller),
          ]);
          final confirmedDeltaMs =
              confirmation[1].inMilliseconds - confirmation[0].inMilliseconds;
          if (confirmedDeltaMs.abs() <= _streamQualityHandoffToleranceMs) {
            return confirmation[1];
          }
          continue;
        }

        if (deltaMs > 0) {
          // Candidate is ahead: freeze its decoded frame while the visible old
          // player catches up.
          await setCandidateSpeed(normalSpeed);
          if (controller.value.isPlaying) await controller.pause();
        } else {
          // Candidate is behind: catch up off-screen at a modest higher rate.
          // Unlike another seek, this keeps decoded frames flowing.
          if (!controller.value.isPlaying) await controller.play();
          final catchUp = ((-deltaMs) / 300).clamp(0.5, 1.5).toDouble();
          await setCandidateSpeed(normalSpeed + catchUp);
        }

        await Future<void>.delayed(_streamQualityPhaseLockSampleDelay);
      }
      throw StateError('playing stream quality hand-off did not phase-lock');
    } finally {
      await setCandidateSpeed(normalSpeed);
      if (!controller.value.hasError && !controller.value.isPlaying) {
        await controller.play();
      }
    }
  }

  Future<Duration> _synchronizePausedStreamQualityAtCommit({
    required VideoPlayerController controller,
    required VideoPlayerController previousController,
  }) async {
    if (controller.value.isPlaying) await controller.pause();
    final target = await _readNativeControllerPosition(previousController);
    var candidate = await _readNativeControllerPosition(controller);
    if ((candidate.inMilliseconds - target.inMilliseconds).abs() <=
        _streamQualityHandoffToleranceMs) {
      return candidate;
    }

    // Decode forward after the seek and pause only once native position
    // movement confirms that a replacement frame has been presented.
    await _seekWarmController(controller, target);
    await controller.play();
    final deadline = DateTime.now().add(const Duration(seconds: 2));
    while (DateTime.now().isBefore(deadline)) {
      if (controller.value.hasError) {
        throw StateError(
          controller.value.errorDescription ?? 'replacement stream failed',
        );
      }
      candidate = await _readNativeControllerPosition(controller);
      final advancedMs = candidate.inMilliseconds - target.inMilliseconds;
      if (!controller.value.isBuffering && advancedMs >= 25) {
        await controller.pause();
        candidate = await _readNativeControllerPosition(controller);
        if ((candidate.inMilliseconds - target.inMilliseconds).abs() <= 120) {
          return candidate;
        }
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 16));
    }

    if (controller.value.isPlaying) await controller.pause();
    throw StateError('paused stream quality hand-off did not render at target');
  }

  Future<Duration> _readNativeControllerPosition(
    VideoPlayerController controller,
  ) async {
    try {
      return await controller.position ?? controller.value.position;
    } catch (_) {
      return controller.value.position;
    }
  }

  Future<void> _releasePreviousStreamAfterHandoffFrame({
    required VideoPlayerController controller,
    required bool disposeController,
    required BilibiliStreamingService streaming,
    required BilibiliPreparedPlayback? playback,
    MaterializedMediaLease? materializedLease,
  }) async {
    await Future.any<void>(<Future<void>>[
      SchedulerBinding.instance.endOfFrame,
      Future<void>.delayed(const Duration(milliseconds: 50)),
    ]);
    await _detachController(
      controller,
      disposeController: disposeController,
      pauseIfPlaying: true,
    );
    if (playback != null) await streaming.releasePlayback(playback);
    await materializedLease?.release();
  }

  Future<void> _seekWarmController(
    VideoPlayerController controller,
    Duration position,
  ) async {
    if (controller.value.isPlaying) await controller.pause();
    var target = position < Duration.zero ? Duration.zero : position;
    final duration = controller.value.duration;
    if (duration > Duration.zero && target > duration) target = duration;

    for (var attempt = 0; attempt < 3; attempt++) {
      await controller.seekTo(target);
      await Future<void>.delayed(const Duration(milliseconds: 35));
      if ((controller.value.position.inMilliseconds - target.inMilliseconds)
              .abs() <=
          _streamQualityHandoffToleranceMs) {
        return;
      }
    }
  }

  Future<void> _waitForWarmStreamFrame(VideoPlayerController controller) async {
    final nativeFirstFrame = NativeVideoPlayerMediaKit.firstFrameRenderedFor(
      // ignore: invalid_use_of_visible_for_testing_member
      controller.playerId,
    );
    if (nativeFirstFrame != null) {
      try {
        await nativeFirstFrame.timeout(const Duration(seconds: 3));
        await Future<void>.delayed(_streamQualityWarmFrameDelay);
        return;
      } on TimeoutException {
        // Fall through to the portable buffering/clock readiness heuristic.
      }
    }

    // video_player has no portable first-frame callback. Every supported
    // backend does expose buffering, buffered ranges or position movement.
    // Seeing one of those signals after muted pre-roll is the closest common
    // first-frame readiness contract available across all platform adapters.
    final initialPosition = controller.value.position;
    final deadline = DateTime.now().add(const Duration(milliseconds: 900));
    var observedBuffering = controller.value.isBuffering;
    while (DateTime.now().isBefore(deadline)) {
      final value = controller.value;
      if (value.hasError) {
        throw StateError(value.errorDescription ?? 'stream warm-up failed');
      }
      observedBuffering = observedBuffering || value.isBuffering;
      final positionAdvanced =
          (value.position.inMilliseconds - initialPosition.inMilliseconds)
              .abs() >=
          30;
      final bufferedAtTarget = value.buffered.any(
        (range) =>
            range.start <= initialPosition && range.end > initialPosition,
      );
      if (!value.isBuffering &&
          (observedBuffering || positionAdvanced || bufferedAtTarget)) {
        await Future<void>.delayed(_streamQualityWarmFrameDelay);
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 16));
    }
    if (controller.value.hasError) {
      throw StateError(
        controller.value.errorDescription ?? 'stream warm-up failed',
      );
    }
    await Future<void>.delayed(_streamQualityWarmFrameDelay);
  }

  void _commitStreamQualityHandoff({
    required VideoItem item,
    required VideoPlayerController controller,
    required BilibiliPreparedPlayback preparedPlayback,
    required Duration position,
    required bool shouldPlay,
  }) {
    final previousController = _controller!;
    BilibiliStreamQuality? localQuality;
    for (final quality in _streamQualities) {
      if (quality.isLocalMaterialized) {
        localQuality = quality;
        break;
      }
    }
    _invalidatePlaybackSpeedCommands();
    _detachNativePositionStream(previousController);
    try {
      previousController.removeListener(_onControllerUpdate);
    } catch (_) {}

    _controller = controller;
    _serviceOwnsController = true;
    final hasVideoOutput = _controllerHasRequiredVideoOutput(item, controller);
    _controllerCreatedWithoutVisiblePlaybackPage =
        item.type == MediaType.video && !hasVideoOutput;
    _transitionPlaybackSession(
      _session.generation,
      hasVideoOutput
          ? PlaybackSessionPhase.ready
          : PlaybackSessionPhase.videoOutputDeferred,
      controller: controller,
      desiredPlaying: shouldPlay,
    );
    _currentBilibiliPlayback = preparedPlayback;
    _currentMaterializedPlaybackLease = null;
    _isSourceMissing = false;
    _streamQualities = List.unmodifiable([
      ?localQuality,
      ...preparedPlayback.qualities,
    ]);
    _selectedStreamQuality = preparedPlayback.selectedQuality;
    _streamDisplayAspectRatio = preparedPlayback.displayAspectRatio;
    _duration = controller.value.duration;
    _position = position;
    _bufferedPosition = _readBufferedPosition(controller);
    _state = shouldPlay ? PlaybackState.playing : PlaybackState.paused;
    _lastControllerIsPlaying = controller.value.isPlaying;
    _armInitialPositionGuard(position);

    _attachNativePositionStream(controller);
    controller.addListener(_onControllerUpdate);
    _resetPlaybackTimeline(
      position,
      running: shouldPlay && controller.value.isPlaying,
    );
    if (shouldPlay) {
      _startProgressTracking();
    } else {
      _stopProgressTracking();
    }
    _syncWakelockWithState();
    notifyListeners();
    _logPlaybackEvent(
      'stream quality hand-off committed',
      data: <String, Object?>{
        'itemId': item.id,
        'qualityId': preparedPlayback.selectedQuality.id,
        'positionMs': position.inMilliseconds,
        'playing': shouldPlay,
      },
    );
  }

  bool _isMobileDecoderCapacityError(Object error) {
    if (kIsWeb || !(Platform.isAndroid || Platform.isIOS)) return false;
    final message = error.toString().toLowerCase();
    return <String>[
      'mediacodec',
      'decoder initialization',
      'decoder init',
      'insufficient resource',
      'resource busy',
      'no available decoder',
      'omx.',
      '0xfffffff4',
    ].any(message.contains);
  }

  /// 设置字幕列表
  void setSubtitles(List<SubtitleItem> subtitles) {
    setSubtitleState(paths: const [], primary: subtitles, secondary: const []);
  }

  void setSubtitleState({
    required List<String> paths,
    required List<SubtitleItem> primary,
    required List<SubtitleItem> secondary,
  }) {
    _subtitleLoadRequestId++;
    for (final path in paths) {
      _subtitleCache.remove('$path::plain');
      _subtitleCache.remove('$path::yt_auto');
      _subtitleCache.remove('$path::timeline_v2');
    }
    _commitSubtitleState(paths: paths, primary: primary, secondary: secondary);
  }

  void _commitSubtitleState({
    required List<String> paths,
    required List<SubtitleItem> primary,
    required List<SubtitleItem> secondary,
    bool notify = true,
  }) {
    _subtitles = List<SubtitleItem>.unmodifiable(primary);
    _secondarySubtitles = List<SubtitleItem>.unmodifiable(secondary);
    _subtitlePaths = List<String>.unmodifiable(paths);
    _subtitleRevision++;
    _subtitleTimeline = SubtitleTimelineResolver(_subtitles);
    _lastSubtitleIndex = 0;
    _currentSubtitle = null;
    _updateCurrentSubtitle();
    if (notify) notifyListeners();
  }

  /// Loads and commits the selected primary/secondary subtitle paths for the
  /// active media item. The service owns the request generation so a slower
  /// request from a covered or disposed playback page cannot overwrite a more
  /// recent selection made on the other layout.
  Future<bool> loadSubtitlePathsForCurrentItem({
    required String itemId,
    required List<String> paths,
  }) async {
    final int requestId = ++_subtitleLoadRequestId;
    if (_currentItem?.id != itemId) return false;

    final selectedPaths = List<String>.unmodifiable(
      paths.where((path) => path.trim().isNotEmpty).take(2),
    );
    if (selectedPaths.isEmpty) {
      if (requestId != _subtitleLoadRequestId || _currentItem?.id != itemId) {
        return false;
      }
      _currentItem!
        ..subtitlePath = null
        ..secondarySubtitlePath = null;
      _commitSubtitleState(
        paths: const <String>[],
        primary: const <SubtitleItem>[],
        secondary: const <SubtitleItem>[],
      );
      return true;
    }

    final primary = await _parseSubtitleFile(selectedPaths.first);
    final secondary = selectedPaths.length > 1
        ? await _parseSubtitleFile(selectedPaths[1])
        : <SubtitleItem>[];
    if (requestId != _subtitleLoadRequestId || _currentItem?.id != itemId) {
      return false;
    }

    _currentItem!
      ..subtitlePath = selectedPaths.first
      ..secondarySubtitlePath = selectedPaths.length > 1
          ? selectedPaths[1]
          : null;
    _commitSubtitleState(
      paths: selectedPaths,
      primary: primary,
      secondary: secondary,
    );
    return true;
  }

  /// Makes a portrait/landscape hand-off atomic from the subtitle point of
  /// view. A playback page may be created while the initial subtitle refresh
  /// is still parsing, so merely reading [subtitlePaths] can expose a partial
  /// (primary-only) snapshot to the new page.
  Future<bool> ensureSubtitlePathsForCurrentItem({
    required String itemId,
    required List<String> paths,
  }) async {
    if (_currentItem?.id != itemId) return false;

    final expected = paths
        .where((path) => path.trim().isNotEmpty)
        .take(2)
        .map(p.normalize)
        .toList(growable: false);
    final current = _subtitlePaths.map(p.normalize).toList(growable: false);
    final bool hasCompleteParsedState =
        expected.length == current.length &&
        _sameOrderedPaths(expected, current) &&
        (expected.isEmpty || _subtitles.isNotEmpty) &&
        (expected.length < 2 || _secondarySubtitles.isNotEmpty);
    if (hasCompleteParsedState) return true;

    return loadSubtitlePathsForCurrentItem(itemId: itemId, paths: expected);
  }

  static bool _sameOrderedPaths(List<String> left, List<String> right) {
    if (left.length != right.length) return false;
    for (var i = 0; i < left.length; i++) {
      if (left[i] != right[i]) return false;
    }
    return true;
  }

  void clearSubtitleState() {
    setSubtitleState(paths: const [], primary: const [], secondary: const []);
    // Clear the subtitle file cache to free memory when switching videos.
    _subtitleCache.clear();
  }

  void _clearSubtitleStateForMediaSwitch() {
    _subtitleLoadRequestId++;
    _commitSubtitleState(
      paths: const <String>[],
      primary: const <SubtitleItem>[],
      secondary: const <SubtitleItem>[],
      notify: false,
    );
    _subtitleCache.clear();
  }

  String? _resolveFirstAssociatedSubtitlePath(VideoItem item) {
    final associated = item.downloadAssociatedSubtitles;
    if (associated.isEmpty) return null;
    for (final path in associated.values) {
      if (path.isEmpty) continue;
      final normalized = p.normalize(path);
      if (File(normalized).existsSync()) {
        return normalized;
      }
    }
    return null;
  }

  Future<String?> _normalizeExistingSubtitlePath(String? path) async {
    if (path == null || path.trim().isEmpty) return null;
    final normalized = p.normalize(path);
    try {
      if (await File(normalized).exists()) {
        return normalized;
      }
    } catch (_) {}
    return null;
  }

  bool _shouldPreserveSubtitleStateOnRefreshMiss(VideoItem item) {
    if (_subtitlePaths.isEmpty ||
        (_subtitles.isEmpty && _secondarySubtitles.isEmpty)) {
      return false;
    }

    final expectedPaths = <String>{};
    final primaryPath = item.subtitlePath;
    if (primaryPath != null && primaryPath.isNotEmpty) {
      expectedPaths.add(p.normalize(primaryPath));
    }

    final secondaryPath = item.secondarySubtitlePath;
    if (secondaryPath != null && secondaryPath.isNotEmpty) {
      expectedPaths.add(p.normalize(secondaryPath));
    }

    final associated = item.downloadAssociatedSubtitles;
    if (associated.isNotEmpty) {
      for (final path in associated.values) {
        if (path.isEmpty) continue;
        expectedPaths.add(p.normalize(path));
      }
    }
    for (final path in item.localSubtitleGroups.values) {
      if (path.isEmpty) continue;
      expectedPaths.add(p.normalize(path));
    }

    if (expectedPaths.isEmpty) {
      return false;
    }

    for (final path in _subtitlePaths) {
      if (expectedPaths.contains(p.normalize(path))) {
        return true;
      }
    }
    return false;
  }

  Future<List<String>> _collectInitialSubtitlePaths(VideoItem item) async {
    final List<String> paths = <String>[];

    final primaryPath = await _normalizeExistingSubtitlePath(item.subtitlePath);
    if (primaryPath != null) {
      paths.add(primaryPath);
    }

    final secondaryPath = await _normalizeExistingSubtitlePath(
      item.secondarySubtitlePath,
    );
    if (secondaryPath != null && !paths.contains(secondaryPath)) {
      paths.add(secondaryPath);
    }

    if (paths.isNotEmpty) {
      return paths;
    }

    if (!item.blockAutoAssociatedSubtitleSelection) {
      final associatedPath = _resolveFirstAssociatedSubtitlePath(item);
      if (associatedPath != null && !paths.contains(associatedPath)) {
        paths.add(associatedPath);
      }
    }

    if (paths.isNotEmpty) {
      return paths;
    }

    if (!item.blockAutoAssociatedSubtitleSelection) {
      final scannedPaths = await _scanAutoExternalSubtitlePaths(item);
      for (final candidate in scannedPaths) {
        if (paths.length >= 2) break;
        if (!paths.contains(candidate)) {
          paths.add(candidate);
        }
      }
    }

    if (paths.isNotEmpty) {
      return paths;
    }

    final embeddedPath = await _extractEmbeddedSubtitlePath(item);
    if (embeddedPath != null) {
      paths.add(embeddedPath);
    }

    return paths;
  }

  /// Loads only subtitle files already associated with the library item.
  ///
  /// This deliberately avoids directory scans and embedded-track extraction:
  /// those operations can contend with the media decoder for the same file.
  /// Known external subtitles are small and can be parsed while the old native
  /// player is being released, making the transcript available during loading.
  Future<void> _refreshKnownSubtitlesForCurrentItem(VideoItem item) async {
    final int requestId = ++_subtitleLoadRequestId;
    final paths = <String>[];

    Future<void> addIfAvailable(String? candidate) async {
      if (candidate == null || candidate.trim().isEmpty || paths.length >= 2) {
        return;
      }
      final normalized = await _normalizeExistingSubtitlePath(candidate);
      if (normalized != null && !paths.contains(normalized)) {
        paths.add(normalized);
      }
    }

    await addIfAvailable(item.subtitlePath);
    await addIfAvailable(item.secondarySubtitlePath);
    if (paths.isEmpty && !item.blockAutoAssociatedSubtitleSelection) {
      for (final candidate in item.downloadAssociatedSubtitles.values) {
        await addIfAvailable(candidate);
        if (paths.length >= 2) break;
      }
    }

    if (paths.isEmpty ||
        requestId != _subtitleLoadRequestId ||
        _currentItem?.id != item.id) {
      return;
    }

    final parsed =
        await Future.wait<List<SubtitleItem>>(<Future<List<SubtitleItem>>>[
          _parseSubtitleFile(paths.first),
          if (paths.length > 1) _parseSubtitleFile(paths[1]),
        ]);
    if (requestId != _subtitleLoadRequestId || _currentItem?.id != item.id) {
      return;
    }
    _commitSubtitleState(
      paths: paths,
      primary: parsed.first,
      secondary: parsed.length > 1 ? parsed[1] : const <SubtitleItem>[],
    );
  }

  Future<List<String>> _scanAutoExternalSubtitlePaths(VideoItem item) async {
    try {
      final entries = await const SubtitleDiscoveryService().scanVideoDirectory(
        videoPath: item.path,
        videoDurationMs: item.durationMs > 0 ? item.durationMs : null,
      );
      return entries
          .where((entry) => entry.isAuto)
          .take(2)
          .map((entry) => entry.path)
          .toList();
    } catch (e) {
      developer.log('Scan auto external subtitles failed', error: e);
      return const <String>[];
    }
  }

  bool _isImageSubtitleCodec(String codecName) {
    final codec = codecName.toLowerCase();
    return codec == 'hdmv_pgs_subtitle' ||
        codec == 'dvd_subtitle' ||
        codec == 'xsub';
  }

  Future<void> _markEmbeddedAttempted(VideoItem item) async {
    if (item.hasAttemptedAutoEmbeddedSubtitleLoad) return;
    item.hasAttemptedAutoEmbeddedSubtitleLoad = true;
    final library = _libraryService;
    if (library == null) return;
    try {
      await library.markAutoEmbeddedSubtitleLoadAttempted(item.id);
      final updated = library.getVideo(item.id);
      if (updated != null && _currentItem?.id == item.id) {
        _currentItem = updated;
      }
    } catch (e) {
      developer.log('Mark embedded subtitle attempt failed', error: e);
    }
  }

  Future<String?> _extractEmbeddedSubtitlePath(VideoItem item) async {
    if (item.blockAutoAssociatedSubtitleSelection ||
        item.prefersManagedAssociatedSubtitles ||
        item.hasAttemptedAutoEmbeddedSubtitleLoad) {
      return null;
    }

    final embeddedService = _embeddedSubtitleService;
    if (embeddedService == null) return null;

    await _markEmbeddedAttempted(item);
    if (_currentItem?.id != item.id) return null;

    try {
      final tracks = await embeddedService.getEmbeddedSubtitles(item.path);
      if (_currentItem?.id != item.id) return null;
      if (tracks.isEmpty) return null;

      final track = tracks.firstWhere(
        (candidate) => !_isImageSubtitleCodec(candidate.codecName),
        orElse: () => tracks.first,
      );
      if (_isImageSubtitleCodec(track.codecName)) {
        return null;
      }

      final subDir = await const TaskSubtitleStorageService().taskDirectory(
        item.id,
        create: true,
      );

      final extractedPath = await embeddedService.extractSubtitle(
        item.path,
        track.index,
        subDir.path,
        codecName: track.codecName,
        videoId: item.id,
      );
      if (extractedPath != null) {
        await _libraryService?.registerManagedSubtitleAsset(
          item.id,
          path: extractedPath,
          kind: ManagedSubtitleAssetKind.embedded,
          displayName: track.title,
        );
      }
      if (_currentItem?.id != item.id) return null;
      return await _normalizeExistingSubtitlePath(extractedPath);
    } catch (e) {
      developer.log('Extract embedded subtitle failed', error: e);
      return null;
    }
  }

  Future<void> _persistResolvedSubtitlePath(
    VideoItem item,
    String primaryPath, {
    String? secondaryPath,
  }) async {
    final library = _libraryService;
    if (library == null) return;
    try {
      final settings = SettingsService();
      final String? existingSecondary;
      if (secondaryPath != null) {
        existingSecondary = await _normalizeExistingSubtitlePath(secondaryPath);
      } else {
        existingSecondary = await _normalizeExistingSubtitlePath(
          item.secondarySubtitlePath,
        );
      }
      await library.updateVideoSubtitles(
        item.id,
        primaryPath,
        settings.autoCacheSubtitles,
        secondarySubtitlePath: existingSecondary,
        isSecondaryCached: settings.autoCacheSubtitles,
      );
      if (_currentItem?.id != item.id) return;
      final updated = library.getVideo(item.id);
      if (updated != null) {
        _currentItem = updated;
      }
    } catch (e) {
      developer.log('Persist resolved subtitle path failed', error: e);
    }
  }

  Future<void> _refreshSubtitlesForCurrentItem(VideoItem item) async {
    final int requestId = ++_subtitleLoadRequestId;

    final List<String> paths = await _collectInitialSubtitlePaths(item);
    if (requestId != _subtitleLoadRequestId) return;
    if (_currentItem?.id != item.id) return;
    if (paths.isEmpty) {
      if (_shouldPreserveSubtitleStateOnRefreshMiss(item)) {
        return;
      }
      setSubtitleState(paths: const [], primary: const [], secondary: const []);
      return;
    }

    final String? normalizedPrimary = await _normalizeExistingSubtitlePath(
      item.subtitlePath,
    );
    if (normalizedPrimary == null && paths.isNotEmpty) {
      await _persistResolvedSubtitlePath(
        item,
        paths.first,
        secondaryPath: paths.length > 1 ? paths[1] : null,
      );
      if (requestId != _subtitleLoadRequestId) return;
      if (_currentItem?.id != item.id) return;
    }

    final parsed =
        await Future.wait<List<SubtitleItem>>(<Future<List<SubtitleItem>>>[
          _parseSubtitleFile(paths[0]),
          if (paths.length > 1) _parseSubtitleFile(paths[1]),
        ]);
    final primary = parsed.first;
    final secondary = parsed.length > 1 ? parsed[1] : <SubtitleItem>[];
    if (requestId != _subtitleLoadRequestId) return;
    if (_currentItem?.id != item.id) return;

    setSubtitleState(paths: paths, primary: primary, secondary: secondary);
  }

  /// 设置外部控制器（用于UI创建的控制器移交给服务管理）
  Future<void> setController(VideoPlayerController controller) async {
    // 如果是同一个控制器，无需处理
    if (_controller == controller) return;
    _playRequestId++;
    _seekRequestId++;
    _pendingSeekRequestId = null;
    _invalidatePlaybackSpeedCommands();

    final previousController = _controller;
    final bool shouldDisposePrevious = _serviceOwnsController;

    // 先移除旧控制器的监听器，防止状态冲突
    if (previousController != null) {
      _controller = null;
      _serviceOwnsController = false;
      await _detachController(
        previousController,
        disposeController: shouldDisposePrevious,
        pauseIfPlaying: true,
      );
    }

    _controller = controller;
    // setController is a transfer, not a borrowed reference. Centralizing
    // native-player ownership lets mobile media switches await the real decoder
    // release before constructing the replacement.
    _serviceOwnsController = true;
    final currentItem = _currentItem;
    _controllerCreatedWithoutVisiblePlaybackPage =
        currentItem != null &&
        currentItem.type == MediaType.video &&
        !_controllerHasRequiredVideoOutput(currentItem, controller);
    _isSourceMissing = false;
    _attachNativePositionStream(controller);
    _logPlaybackEvent(
      'controller attached',
      data: <String, Object?>{
        'initialized': controller.value.isInitialized,
        'isPlaying': controller.value.isPlaying,
      },
    );

    // 立即同步状态
    if (_controller!.value.isInitialized) {
      _capturePlaybackSpeedFromController(_controller!);
      _duration = _controller!.value.duration;
      _position = _controller!.value.position;
      _bufferedPosition = _readBufferedPosition(_controller!);
      _state = _controller!.value.isPlaying
          ? PlaybackState.playing
          : PlaybackState.paused;
      _hasPlaybackCompleted =
          !_controller!.value.isPlaying &&
          _hasReachedPlaybackEnd(_position, _duration);
      _resetPlaybackTimeline(_position, running: _controller!.value.isPlaying);
    }
    _lastControllerIsPlaying = _controller!.value.isPlaying;

    // 添加新监听器
    _controller!.addListener(_onControllerUpdate);
    unawaited(_applyMuteStateToController(reason: 'controller attached'));

    // 启动进度追踪
    if (_state == PlaybackState.playing) {
      _startProgressTracking();
    } else {
      _stopProgressTracking();
    }

    _syncWakelockWithState();
    notifyListeners();
  }

  Future<void> _applyConfiguredPlaybackSpeed(
    VideoPlayerController controller,
  ) async {
    final settings = SettingsService();
    final targetSpeed = settings.effectiveGlobalPlaybackSpeed;
    if ((controller.value.playbackSpeed - targetSpeed).abs() < 0.001) {
      _playbackSpeed = targetSpeed;
      _confirmedPlaybackSpeed = targetSpeed;
      _lastDispatchedPlaybackSpeed = targetSpeed;
      return;
    }
    _lastDispatchedPlaybackSpeed = targetSpeed;
    await controller.setPlaybackSpeed(targetSpeed);
    _playbackSpeed = targetSpeed;
    _confirmedPlaybackSpeed = targetSpeed;
  }

  void _capturePlaybackSpeedFromController(
    VideoPlayerController controller, {
    bool notify = false,
  }) {
    if (!controller.value.isInitialized) return;
    // Platform callbacks may briefly expose the old rate while a new rate
    // command is in flight. The requested rate owns the timeline until the
    // matching command completes.
    if (_pendingPlaybackSpeed != null) return;
    final speed = controller.value.playbackSpeed;
    if ((_confirmedPlaybackSpeed - speed).abs() < 0.001) return;
    _playbackSpeed = speed;
    _confirmedPlaybackSpeed = speed;
    _lastDispatchedPlaybackSpeed = speed;
    _nativePresentationPlaybackSpeed = speed;
    if (_timelineClock.isInitialized) {
      _timelineClock.setRate(speed);
    }
    if (notify) notifyListeners();
  }

  /// Changes the speed of the active playback session without changing the
  /// persisted speed-lock preference.
  Future<void> setPlaybackSpeed(double speed) {
    return _setPlaybackSpeed(speed, notifyStateChange: true);
  }

  Future<void> _setPlaybackSpeed(
    double speed, {
    required bool notifyStateChange,
  }) async {
    if (!speed.isFinite || speed <= 0) return;
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;

    final requestId = ++_playbackSpeedRequestId;
    // Invalidate a queued native request before serializing the replacement.
    // This is important for a quick press/release: libmpv must see at most one
    // enter command followed by one restore command, never overlapping calls.
    // ignore: invalid_use_of_visible_for_testing_member
    NativeVideoPlayerMediaKit.cancelPendingRateChange(controller.playerId);
    final changed = (_playbackSpeed - speed).abs() >= 0.001;
    _pendingPlaybackSpeed = speed;
    _playbackSpeed = speed;
    if (changed && notifyStateChange) notifyListeners();

    final previousCommand = _playbackSpeedCommandTail;
    final command = _runPlaybackSpeedCommand(
      previousCommand: previousCommand,
      controller: controller,
      requestId: requestId,
      speed: speed,
      notifyStateChange: notifyStateChange,
    );
    _playbackSpeedCommandTail = command.catchError((Object _) {});
    await command;
  }

  Future<void> _runPlaybackSpeedCommand({
    required Future<void> previousCommand,
    required VideoPlayerController controller,
    required int requestId,
    required double speed,
    required bool notifyStateChange,
  }) async {
    try {
      await previousCommand;
    } catch (_) {
      // A failed older command must not prevent the latest requested speed
      // from being applied.
    }

    if (requestId != _playbackSpeedRequestId || controller != _controller) {
      return;
    }

    try {
      if ((_lastDispatchedPlaybackSpeed - speed).abs() >= 0.001) {
        _lastDispatchedPlaybackSpeed = speed;
        await controller.setPlaybackSpeed(speed);
      }
      if (requestId != _playbackSpeedRequestId || controller != _controller) {
        return;
      }

      _pendingPlaybackSpeed = null;
      _playbackSpeed = speed;
      _confirmedPlaybackSpeed = speed;
      _nativePresentationPlaybackSpeed = speed;
      if (_timelineClock.isInitialized) {
        // A rate transition changes only the slope of the existing media
        // timeline. In particular, never re-anchor to controller.position
        // here: Android's platform player and libmpv publish that sample with
        // different delays, so using it as a new origin makes every overlay
        // jump at both the press and release boundaries.
        _timelineClock.setRate(speed);
      } else {
        _resetPlaybackTimeline(
          positionNotifier.value,
          running: _shouldTimelineRun(),
          rate: speed,
        );
      }
    } catch (_) {
      _lastDispatchedPlaybackSpeed = _confirmedPlaybackSpeed;
      if (requestId != _playbackSpeedRequestId || controller != _controller) {
        return;
      }
      _pendingPlaybackSpeed = null;
      _playbackSpeed = _confirmedPlaybackSpeed;
      _nativePresentationPlaybackSpeed = _confirmedPlaybackSpeed;
      if (_timelineClock.isInitialized) {
        _timelineClock.setRate(_confirmedPlaybackSpeed);
      }
      if (notifyStateChange) notifyListeners();
      rethrow;
    }
  }

  /// Applies a temporary rate without changing the persisted/global rate.
  /// Repeated calls retain the original base rate until [endTemporaryPlaybackSpeed].
  Future<void> beginTemporaryPlaybackSpeed(double speed) {
    if (!speed.isFinite || speed <= 0) return Future<void>.value();
    _temporaryPlaybackBaseSpeed ??= _playbackSpeed;
    // The local long-press overlay already owns the transient visual state.
    // Broadcasting this ephemeral speed through the whole application would
    // rebuild unrelated consumers in the exact frame where native rate
    // switching needs the most headroom.
    return _setPlaybackSpeed(speed, notifyStateChange: false);
  }

  /// Restores the stable rate that was active before the temporary session.
  Future<void> endTemporaryPlaybackSpeed() {
    final restoreSpeed = _temporaryPlaybackBaseSpeed;
    _temporaryPlaybackBaseSpeed = null;
    if (restoreSpeed == null) return Future<void>.value();
    return _setPlaybackSpeed(restoreSpeed, notifyStateChange: false);
  }

  void _invalidatePlaybackSpeedCommands() {
    _playbackSpeedRequestId++;
    _pendingPlaybackSpeed = null;
    _temporaryPlaybackBaseSpeed = null;
    _lastDispatchedPlaybackSpeed = _confirmedPlaybackSpeed;
    _nativePresentationPlaybackSpeed = _confirmedPlaybackSpeed;
    _playbackSpeedCommandTail = Future<void>.value();
  }

  /// 清除当前控制器引用（当UI销毁控制器时调用）
  void clearController() {
    _clearInitialPositionGuard();
    if (_controller != null) {
      _invalidatePlaybackSpeedCommands();
      _logPlaybackEvent(
        'controller cleared',
        data: <String, Object?>{
          'itemId': _currentItem?.id,
          'positionMs': _position.inMilliseconds,
        },
      );
      try {
        _controller!.removeListener(_onControllerUpdate);
      } catch (e) {
        // 忽略
      }
      _cancelNativePositionStream();
      _controller = null;
      _serviceOwnsController = false;
      _controllerCreatedWithoutVisiblePlaybackPage = false;
      _timelineClock.setRunning(false);
    }
  }

  /// 更新媒体元数据
  Future<void> updateMetadata(VideoItem item) async {
    _currentItem = item;
    final generation = _beginPlaybackSession(
      item,
      desiredPlaying: _controller?.value.isPlaying ?? false,
    );
    final activeController = _controller;
    if (activeController != null &&
        activeController.value.isInitialized &&
        !activeController.value.hasError) {
      _transitionPlaybackSession(
        generation,
        _controllerHasRequiredVideoOutput(item, activeController)
            ? PlaybackSessionPhase.ready
            : PlaybackSessionPhase.videoOutputDeferred,
        controller: activeController,
      );
    }
    _logPlaybackEvent(
      'metadata updated',
      data: <String, Object?>{
        'itemId': item.id,
        'title': item.title,
        'type': item.type.name,
      },
    );

    if (_playlistManager != null) {
      final idx = _playlistManager!.indexOfItem(item.id);
      if (idx >= 0) {
        _playlistManager!.setCurrentIndex(idx);
      } else {
        _playlistManager!.loadFolderPlaylist(item.parentId, item.id);
      }
    }

    // 如果控制器已就绪，确保时长准确
    if (_controller != null && _controller!.value.isInitialized) {
      _duration = _controller!.value.duration;
    }

    notifyListeners();
  }

  /// 跳转到上一句字幕
  Future<void> seekToPreviousSubtitle({
    String source = 'subtitle_navigation',
  }) async {
    if (_subtitles.isEmpty || _controller == null) return;
    _logPlaybackEvent(
      'seek to previous subtitle requested',
      data: <String, Object?>{
        'source': source,
        'positionMs': _position.inMilliseconds,
      },
    );

    final int currentIndex = _findSubtitleIndexForCurrentPosition();
    if (currentIndex < 0 || currentIndex >= _subtitles.length) return;
    final currentStart = _subtitles[currentIndex].startTime;

    // 如果当前位置在当前字幕开始后1秒以上，跳到当前字幕开始
    if (_position > currentStart + const Duration(seconds: 1)) {
      await seekTo(currentStart, source: source);
      return;
    }

    // 否则跳到上一句字幕
    if (currentIndex > 0) {
      await seekTo(_subtitles[currentIndex - 1].startTime, source: source);
    }
  }

  /// 跳转到下一句字幕
  Future<void> seekToNextSubtitle({
    String source = 'subtitle_navigation',
  }) async {
    if (_subtitles.isEmpty || _controller == null) return;
    _logPlaybackEvent(
      'seek to next subtitle requested',
      data: <String, Object?>{
        'source': source,
        'positionMs': _position.inMilliseconds,
      },
    );

    final int currentIndex = _findSubtitleIndexForCurrentPosition();
    if (currentIndex == -1) {
      await seekTo(_subtitles.first.startTime, source: source);
      return;
    }

    // 跳到下一句字幕
    if (currentIndex < _subtitles.length - 1) {
      await seekTo(_subtitles[currentIndex + 1].startTime, source: source);
    }
  }

  int _findSubtitleIndexForCurrentPosition() {
    return _subtitleTimeline.indexAtMs(_position.inMilliseconds);
  }

  /// 播放媒体
  Future<void> play(
    VideoItem item, {
    Duration? startPosition,
    bool autoPlay = true,
    bool forceRecreate = false,
  }) async {
    _streamQualitySwitchRequestId++;
    _isSwitchingStreamQuality = false;
    final int playRequestId = ++_playRequestId;
    final int sessionGeneration = _beginPlaybackSession(
      item,
      desiredPlaying: autoPlay,
    );
    _activePlayInvocationGeneration = sessionGeneration;
    bool shouldPlayNow() => _session.generation == sessionGeneration
        ? _session.desiredPlaying
        : autoPlay;
    _seekRequestId++;
    _pendingSeekRequestId = null;
    _clearInitialPositionGuard();
    _seekVerificationTimer?.cancel();
    _seekVerificationTimer = null;
    VideoPlayerController? requestController;
    MaterializedMediaLease? requestMaterializedLease;
    BilibiliPreparedPlayback? requestBilibiliPlayback;
    Future<
      ({MaterializedMediaLease? materialized, BilibiliPreparedPlayback? online})
    >?
    earlyBilibiliSource;

    Future<void> releaseRequestBilibiliPlayback() async {
      final playback = requestBilibiliPlayback;
      requestBilibiliPlayback = null;
      if (playback != null) {
        await _bilibiliStreamingService?.releasePlayback(playback);
      }
    }

    Future<void> releaseEarlyBilibiliSource() async {
      final pending = earlyBilibiliSource;
      earlyBilibiliSource = null;
      if (pending == null) return;
      try {
        final source = await pending;
        await source.materialized?.release();
        if (source.online != null) {
          await _bilibiliStreamingService?.releasePlayback(source.online!);
        }
      } catch (_) {
        // Preparation failures are handled by play()'s normal error path.
      }
    }

    try {
      _hasPlaybackCompleted = false;

      // 修复：如果startPosition为null且当前位置已在末尾（播放完成状态），
      // 则从头开始播放，避免无法跳转上一集或进入已完成的视频
      if (_currentItem?.id == item.id &&
          startPosition == null &&
          _position > Duration.zero &&
          PlaybackBehaviorPolicy.normalizeEpisodeStartPosition(
                savedPosition: _position,
                duration: _duration,
              ) ==
              Duration.zero) {
        startPosition = Duration.zero;
        _logPlaybackEvent(
          'play from beginning due to completion',
          data: <String, Object?>{
            'itemId': item.id,
            'previousPositionMs': _position.inMilliseconds,
          },
        );
      }

      _logPlaybackEvent(
        'play requested',
        data: <String, Object?>{
          'itemId': item.id,
          'title': item.title,
          'autoPlay': autoPlay,
          'startPositionMs': startPosition?.inMilliseconds,
          'forceRecreate': forceRecreate,
        },
      );

      if (!forceRecreate &&
          _controllerIsReusableForItem(item) &&
          item.sourceRef?.kind == MediaSourceKind.bilibiliStream &&
          _selectedStreamQuality?.isLocalMaterialized != true &&
          _libraryService != null) {
        final local = await _libraryService!
            .acquireExistingMaterializedPlayback(item);
        if (local != null) {
          await local.release();
          if (!_isCurrentPlayRequest(playRequestId, item.id)) return;
          forceRecreate = true;
        }
      }

      if (!forceRecreate && _controllerIsReusableForItem(item)) {
        final controller = _controller!;
        final authoritativePosition = _position;
        _currentItem = item;
        _transitionPlaybackSession(
          sessionGeneration,
          _controllerHasRequiredVideoOutput(item, controller)
              ? PlaybackSessionPhase.controllerMountable
              : PlaybackSessionPhase.videoOutputDeferred,
          controller: controller,
        );
        _preloadTriggered = false;
        _duration = controller.value.duration;
        // Keep the service timeline as the source of truth. The native
        // controller can briefly report byte-zero while a network stream is
        // resuming, which must not overwrite a restored position.
        _bufferedPosition = _readBufferedPosition(controller);
        _lastControllerIsPlaying = controller.value.isPlaying;

        _capturePlaybackSpeedFromController(controller);
        await _applyMuteStateToController(reason: 'reuse existing controller');
        if (!_isCurrentPlayRequest(
          playRequestId,
          item.id,
          controller: controller,
        )) {
          return;
        }

        // 修复：如果startPosition为null且视频已播放完成（位置在末尾），则从头开始播放
        if (startPosition == null &&
            _position > Duration.zero &&
            PlaybackBehaviorPolicy.normalizeEpisodeStartPosition(
                  savedPosition: _position,
                  duration: _duration,
                ) ==
                Duration.zero) {
          startPosition = Duration.zero;
          _logPlaybackEvent(
            'reuse controller: play from beginning due to completion',
            data: <String, Object?>{'itemId': item.id},
          );
        }

        if (startPosition != null &&
            startPosition >= Duration.zero &&
            (_duration <= Duration.zero || startPosition < _duration)) {
          await seekTo(startPosition, source: 'play_same_item_reuse');
          if (!_isCurrentPlayRequest(
            playRequestId,
            item.id,
            controller: controller,
          )) {
            return;
          }
        }

        // Re-opening an already restored online card must not trust a stale
        // byte-zero native sample. Re-anchor the controller before allowing
        // play so the first decoded fragment is the saved position.
        if (startPosition == null &&
            item.sourceRef?.kind == MediaSourceKind.bilibiliStream &&
            controller.value.isInitialized &&
            (controller.value.position.inMilliseconds -
                        authoritativePosition.inMilliseconds)
                    .abs() >
                _seekVerificationToleranceMs) {
          await _seekInitialPosition(controller, authoritativePosition);
          if (!_isCurrentPlayRequest(
            playRequestId,
            item.id,
            controller: controller,
          )) {
            return;
          }
        }

        _resetPlaybackTimeline(
          _position,
          running: shouldPlayNow() && controller.value.isPlaying,
        );

        if (shouldPlayNow()) {
          _state = PlaybackState.playing;
          _syncWakelockWithState();
          notifyListeners();
          _startProgressTracking();
          if (!controller.value.isPlaying) {
            await controller.play();
            if (!_isCurrentPlayRequest(
              playRequestId,
              item.id,
              controller: controller,
            )) {
              return;
            }
          }
        } else {
          _state = PlaybackState.paused;
          _syncWakelockWithState();
          notifyListeners();
          _stopProgressTracking();
          if (controller.value.isPlaying) {
            await controller.pause();
            if (!_isCurrentPlayRequest(
              playRequestId,
              item.id,
              controller: controller,
            )) {
              return;
            }
          }
          final nativePosition = controller.value.position;
          final positionDeltaMs =
              (nativePosition.inMilliseconds - _position.inMilliseconds).abs();
          if (positionDeltaMs <= _seekVerificationToleranceMs) {
            _position = nativePosition;
          }
          _bufferedPosition = _readBufferedPosition(controller);
          await _saveCurrentProgress(immediate: true);
          if (!_isCurrentPlayRequest(
            playRequestId,
            item.id,
            controller: controller,
          )) {
            return;
          }
        }

        if (!await _commitControllerPlaybackIntent(
          sessionGeneration: sessionGeneration,
          playRequestId: playRequestId,
          item: item,
          controller: controller,
        )) {
          return;
        }
        await _savePlaybackStateSnapshot();
        if (!_isCurrentPlayRequest(
          playRequestId,
          item.id,
          controller: controller,
        )) {
          return;
        }
        _refreshSubtitlesForCurrentItem(item);
        return;
      }

      // 如果正在播放其他媒体，或当前控制器已失效，先保存进度并停止
      final isBilibiliStream =
          item.sourceRef?.kind == MediaSourceKind.bilibiliStream;
      if (isBilibiliStream) {
        // Resolve the target stream while the previous mobile controller is
        // releasing. Local-file ordering is untouched, while Bilibili switches
        // no longer wait for decoder release before beginning network setup.
        earlyBilibiliSource = () async {
          final materialized = _libraryService == null
              ? null
              : await _libraryService!.acquireExistingMaterializedPlayback(
                  item,
                );
          if (materialized != null) {
            return (materialized: materialized, online: null);
          }
          final streaming = _bilibiliStreamingService;
          if (streaming == null) {
            throw StateError('Bilibili streaming service is not initialized');
          }
          return (materialized: null, online: await streaming.prepare(item));
        }();
      }

      if (_currentItem != null || _controller != null) {
        _transitionPlaybackSession(
          sessionGeneration,
          PlaybackSessionPhase.releasingOld,
        );
        final bool hadController = _controller != null;
        // Commit the empty subtitle timeline together with the target item
        // below. Publishing it separately makes transcript UIs flash blank
        // while they still identify the previous episode.
        _clearSubtitleStateForMediaSwitch();
        // 非阻塞保存进度：ProgressTracker 内存写入同步，落盘异步
        unawaited(_saveCurrentProgress());
        _seekPersistTimer?.cancel();
        _seekPersistTimer = null;
        if (hadController &&
            !kIsWeb &&
            (Platform.isAndroid || Platform.isIOS)) {
          final release = _disposeController(awaitCompletion: true);
          _trackMobileControllerRelease(release);
        } else if (hadController) {
          // Desktop decoders are not constrained by the mobile hardware codec
          // pool, so retain the faster overlapping hand-off there.
          unawaited(_disposeController());
        }
      }

      // Publish the target item together with its own timeline snapshot.  The
      // previous controller may remain alive while the new one initializes,
      // so leaving these fields untouched would briefly render the previous
      // item's progress on the new current-item card.
      var loadingPosition =
          startPosition ??
          _progressTracker?.getProgress(item.id) ??
          Duration(milliseconds: item.lastPositionMs);
      final loadingDuration = Duration(
        milliseconds: item.durationMs > 0 ? item.durationMs : 0,
      );
      loadingPosition = PlaybackBehaviorPolicy.normalizeEpisodeStartPosition(
        savedPosition: loadingPosition,
        duration: loadingDuration,
      );

      _currentItem = item;
      _isSourceMissing = false;
      _position = loadingPosition;
      _duration = loadingDuration;
      _bufferedPosition = Duration.zero;
      _resetPlaybackTimeline(loadingPosition, running: false);
      _state = PlaybackState.loading;
      _transitionPlaybackSession(
        sessionGeneration,
        PlaybackSessionPhase.preparingSource,
      );
      _syncWakelockWithState();
      notifyListeners();

      // Keep independent page content responsive while the native player is
      // handing off. Subtitle parsing and compatible-path resolution do not
      // require a controller, so overlap them with native disposal instead of
      // placing them behind the slowest part of media initialization.
      unawaited(_refreshKnownSubtitlesForCurrentItem(item));
      final sourceFile = File(item.path);
      final Future<File?> playbackFileFuture = () async {
        if (isBilibiliStream) return null;
        if (!await sourceFile.exists()) return null;
        final playbackPath = _libraryService != null
            ? await _libraryService!.ensureCompatiblePlaybackFile(item)
            : (await AudioPlaybackCompatibilityService.resolve(
                sourceFile,
                isAudio: item.type == MediaType.audio,
                existingPlaybackPath: item.playbackPath,
              )).path;
        return File(playbackPath);
      }();

      if (_playlistManager != null) {
        final idx = _playlistManager!.indexOfItem(item.id);
        if (idx >= 0) {
          _playlistManager!.setCurrentIndex(idx);
        } else {
          _playlistManager!.loadFolderPlaylist(item.parentId, item.id);
        }
      }

      // 重置预加载触发标志（新视频开始时重新计数）
      _preloadTriggered = false;

      // 尝试热替换：如果预加载控制器可用且匹配当前 item，跳过 initialize
      if (!isBilibiliStream &&
          !forceRecreate &&
          _tryUsePreloadedController(item)) {
        final controller = _controller!;
        _transitionPlaybackSession(
          sessionGeneration,
          _controllerHasRequiredVideoOutput(item, controller)
              ? PlaybackSessionPhase.controllerMountable
              : PlaybackSessionPhase.videoOutputDeferred,
          controller: controller,
        );
        if (playRequestId != _playRequestId) {
          unawaited(_disposeController());
          return;
        }

        await _applyConfiguredPlaybackSpeed(controller);
        if (!_isCurrentPlayRequest(
          playRequestId,
          item.id,
          controller: controller,
        )) {
          return;
        }
        await _applyMuteStateToController(
          reason: 'preloaded controller hot-swap',
        );
        if (!_isCurrentPlayRequest(
          playRequestId,
          item.id,
          controller: controller,
        )) {
          return;
        }
        _duration = controller.value.duration;
        _bufferedPosition = _readBufferedPosition(controller);
        if (_progressTracker != null && _duration > Duration.zero) {
          await _progressTracker!.saveDurationImmediately(item.id, _duration);
          if (!_isCurrentPlayRequest(
            playRequestId,
            item.id,
            controller: controller,
          )) {
            return;
          }
        }

        // 跳转到起始位置
        // Freeze the resume point at request start. A delayed controller
        // initialization must not re-read mutable progress after another
        // route's cleanup has run.
        final initialPosition =
            PlaybackBehaviorPolicy.normalizeEpisodeStartPosition(
              savedPosition: loadingPosition,
              duration: _duration,
            );
        // Always seek, including zero. A near-end resume point may have been
        // normalized to the beginning; leaving the service timeline at the
        // old near-end value while the preloaded decoder is at zero can fire a
        // false completion and start an episode-switch loop.
        if (_duration <= Duration.zero || initialPosition < _duration) {
          await controller
              .seekTo(initialPosition)
              .timeout(_controllerSeekTimeout);
          if (!_isCurrentPlayRequest(
            playRequestId,
            item.id,
            controller: controller,
          )) {
            return;
          }
          _position = initialPosition;
        }

        _resetPlaybackTimeline(
          _position,
          running: shouldPlayNow() && controller.value.isPlaying,
        );

        controller.addListener(_onControllerUpdate);
        _lastControllerIsPlaying = controller.value.isPlaying;
        if (shouldPlayNow()) {
          // The visible output may be required for the native backend to
          // produce its first frame. Publish the initialized controller while
          // readiness is still pending so the page can mount that output.
          notifyListeners();
          if (!controller.value.isPlaying) {
            await controller.play();
            if (!_isCurrentPlayRequest(
              playRequestId,
              item.id,
              controller: controller,
            )) {
              return;
            }
          }
          final readiness = await _awaitPlaybackReadinessResult(
            item: item,
            controller: controller,
            playRequestId: playRequestId,
          );
          if (!_isCurrentPlayRequest(
            playRequestId,
            item.id,
            controller: controller,
          )) {
            return;
          }
          if (readiness == _PlaybackReadinessResult.confirmed) {
            _state = PlaybackState.playing;
            _resetPlaybackTimeline(
              _position,
              running: controller.value.isPlaying,
            );
            _syncWakelockWithState();
            notifyListeners();
            _startProgressTracking();
          } else {
            // Readiness degraded: park as paused at the seek target and clear
            // the play intent so the final intent commit cannot re-play a
            // transport that was just confirmed as not running.
            _setDesiredPlaying(false);
            _state = PlaybackState.paused;
            _syncWakelockWithState();
            notifyListeners();
            _stopProgressTracking();
            _position = controller.value.position;
          }
        } else {
          _state = PlaybackState.paused;
          _syncWakelockWithState();
          notifyListeners();
          _stopProgressTracking();
          _position = controller.value.position;
        }

        if (!await _commitControllerPlaybackIntent(
          sessionGeneration: sessionGeneration,
          playRequestId: playRequestId,
          item: item,
          controller: controller,
        )) {
          return;
        }
        await _savePlaybackStateSnapshot();
        if (!_isCurrentPlayRequest(
          playRequestId,
          item.id,
          controller: controller,
        )) {
          return;
        }
        _refreshSubtitlesForCurrentItem(item);
        _logPlaybackEvent(
          'play via preloaded controller',
          data: {'itemId': item.id, 'autoPlay': autoPlay},
        );
        return;
      }

      // 预加载不匹配：释放预加载控制器（用户手动切换到非下一个视频）
      unawaited(_disposePreloadedController());

      // 创建新的控制器
      if (earlyBilibiliSource != null) {
        final source = await earlyBilibiliSource!;
        earlyBilibiliSource = null;
        requestMaterializedLease = source.materialized;
        requestBilibiliPlayback = source.online;
        if (!_isCurrentPlayRequest(playRequestId, item.id)) {
          await requestMaterializedLease?.release();
          requestMaterializedLease = null;
          await releaseRequestBilibiliPlayback();
          return;
        }
      }
      if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
        try {
          await _mobileControllerReleaseBarrier.timeout(
            _mobileControllerReleaseTimeout,
          );
        } on TimeoutException {
          _logPlaybackEvent(
            'previous mobile controller release timed out',
            data: <String, Object?>{'itemId': item.id},
          );
          throw TimeoutException('previous mobile decoder is still releasing');
        }
        if (!_isCurrentPlayRequest(playRequestId, item.id)) {
          await requestMaterializedLease?.release();
          requestMaterializedLease = null;
          await releaseRequestBilibiliPlayback();
          return;
        }
      }
      requestMaterializedLease ??=
          isBilibiliStream &&
              requestBilibiliPlayback == null &&
              _libraryService != null
          ? await _libraryService!.acquireExistingMaterializedPlayback(item)
          : null;
      requestBilibiliPlayback ??=
          isBilibiliStream && requestMaterializedLease == null
          ? (_bilibiliStreamingService == null
                ? throw StateError('Bilibili 在线播放服务尚未初始化')
                : await _bilibiliStreamingService!.prepare(item))
          : null;
      final preparedStream = requestBilibiliPlayback;
      final playbackFile = await playbackFileFuture;
      if (!isBilibiliStream && playbackFile == null) {
        if (!_isCurrentPlayRequest(playRequestId, item.id)) {
          return;
        }
        // A missing source is a recoverable media-session state, not a fatal
        // playback error. Keep the item/timeline/playlist active so every
        // playback page can render its normal controls and navigate past it.
        _isSourceMissing = true;
        _state = PlaybackState.paused;
        _transitionPlaybackSession(
          sessionGeneration,
          PlaybackSessionPhase.missing,
          desiredPlaying: false,
        );
        _stopProgressTracking();
        _syncWakelockWithState();
        notifyListeners();
        unawaited(_savePlaybackStateSnapshot());
        unawaited(_refreshSubtitlesForCurrentItem(item));
        debugPrint('MediaPlaybackService: 文件不存在 ${item.path}');
        return;
      }
      if (playRequestId != _playRequestId) {
        await requestMaterializedLease?.release();
        requestMaterializedLease = null;
        await releaseRequestBilibiliPlayback();
        return;
      }

      if (!_isCurrentPlayRequest(playRequestId, item.id)) {
        await requestMaterializedLease?.release();
        requestMaterializedLease = null;
        await releaseRequestBilibiliPlayback();
        return;
      }
      if (isBilibiliStream && requestMaterializedLease != null) {
        final localLease = requestMaterializedLease;
        final localHeight = localLease.height;
        final localQuality = BilibiliStreamQuality(
          id: BilibiliStreamQuality.localMaterializedId,
          label: localHeight == null || localHeight <= 0
              ? '本地素材'
              : '本地 ${localHeight}P',
        );
        List<BilibiliStreamQuality> onlineQualities = const [];
        try {
          onlineQualities =
              await _bilibiliStreamingService?.listQualities(item) ?? const [];
        } catch (_) {
          // The verified local file remains playable when Bilibili is
          // temporarily unavailable. Online choices can return on reopen.
        }
        if (!_isCurrentPlayRequest(playRequestId, item.id)) {
          await requestMaterializedLease.release();
          requestMaterializedLease = null;
          await releaseRequestBilibiliPlayback();
          return;
        }
        _streamQualities = List.unmodifiable([
          localQuality,
          ...onlineQualities,
        ]);
        _selectedStreamQuality = localQuality;
        final width = localLease.width ?? 0;
        final height = localLease.height ?? 0;
        _streamDisplayAspectRatio = width > 0 && height > 0
            ? width / height
            : null;
        _currentBilibiliPlayback = null;
      } else if (isBilibiliStream && preparedStream != null) {
        _streamQualities = List.unmodifiable(preparedStream.qualities);
        _selectedStreamQuality = preparedStream.selectedQuality;
        _streamDisplayAspectRatio = preparedStream.displayAspectRatio;
      } else {
        _streamQualities = const [];
        _selectedStreamQuality = null;
        _streamDisplayAspectRatio = null;
        _currentBilibiliPlayback = null;
      }
      final controller = isBilibiliStream
          ? requestMaterializedLease != null
                ? VideoPlayerController.file(
                    File(requestMaterializedLease.requiredVideoPath),
                    videoPlayerOptions: buildVideoPlayerOptions(),
                  )
                : _createBilibiliStreamController(preparedStream!)
          : VideoPlayerController.file(
              playbackFile!,
              videoPlayerOptions: buildVideoPlayerOptions(),
            );
      requestController = controller;
      _transitionPlaybackSession(
        sessionGeneration,
        PlaybackSessionPhase.initializingTransport,
      );
      if (playRequestId != _playRequestId) {
        await _detachController(
          controller,
          disposeController: true,
          pauseIfPlaying: true,
        );
        await requestMaterializedLease?.release();
        requestMaterializedLease = null;
        await releaseRequestBilibiliPlayback();
        return;
      }

      // 初始化控制器
      await controller.initialize().timeout(_controllerInitializeTimeout);
      _transitionPlaybackSession(
        sessionGeneration,
        PlaybackSessionPhase.transportReady,
      );

      if (playRequestId != _playRequestId) {
        await _detachController(
          controller,
          disposeController: true,
          pauseIfPlaying: true,
        );
        await requestMaterializedLease?.release();
        requestMaterializedLease = null;
        await releaseRequestBilibiliPlayback();
        return;
      }

      // Network players may start their probe at byte zero while initialize()
      // completes. Stop that implicit start before the saved-position seek so
      // the user never sees the first fragment before the requested point.
      try {
        if (controller.value.isInitialized && controller.value.isPlaying) {
          await controller.pause();
        }
      } catch (_) {}

      _controller = controller;
      _serviceOwnsController = true;
      if (preparedStream != null) {
        _currentBilibiliPlayback = preparedStream;
        requestBilibiliPlayback = null;
      }
      final hasRequiredVideoOutput = _controllerHasRequiredVideoOutput(
        item,
        controller,
      );
      _controllerCreatedWithoutVisiblePlaybackPage =
          item.type == MediaType.video && !hasRequiredVideoOutput;
      _transitionPlaybackSession(
        sessionGeneration,
        hasRequiredVideoOutput
            ? PlaybackSessionPhase.controllerMountable
            : PlaybackSessionPhase.videoOutputDeferred,
        controller: controller,
      );
      if (requestMaterializedLease != null) {
        _currentMaterializedPlaybackLease = requestMaterializedLease;
        requestMaterializedLease = null;
      }
      _isSourceMissing = false;
      _attachNativePositionStream(controller);

      await _applyConfiguredPlaybackSpeed(controller);
      if (!_isCurrentPlayRequest(
        playRequestId,
        item.id,
        controller: controller,
      )) {
        return;
      }

      _duration = controller.value.duration;
      _bufferedPosition = _readBufferedPosition(controller);
      if (_progressTracker != null && _duration > Duration.zero) {
        await _progressTracker!.saveDurationImmediately(item.id, _duration);
        if (!_isCurrentPlayRequest(
          playRequestId,
          item.id,
          controller: controller,
        )) {
          return;
        }
      }

      // 设置音量和静音状态
      await controller.setVolume(_isMuted ? 0.0 : _volume);
      if (!_isCurrentPlayRequest(
        playRequestId,
        item.id,
        controller: controller,
      )) {
        return;
      }

      // 添加监听器

      // 确定起始位置
      Duration initialPosition = loadingPosition;

      // 如果没有指定起始位置，尝试从进度追踪器获取
      // 修复：如果保存的进度在末尾（表示已播放完成），则从头开始播放
      // 避免无法跳转上一集或进入已完成的视频
      // 注意：只有当_duration > 0时才检查，避免误判
      final normalizedInitialPosition =
          PlaybackBehaviorPolicy.normalizeEpisodeStartPosition(
            savedPosition: initialPosition,
            duration: _duration,
          );
      if (normalizedInitialPosition != initialPosition) {
        _logPlaybackEvent(
          'reset to beginning due to completion',
          data: <String, Object?>{
            'itemId': item.id,
            'savedProgressMs': initialPosition.inMilliseconds,
          },
        );
      }
      initialPosition = normalizedInitialPosition;

      // 跳转到起始位置
      // 注意：即使initialPosition为0，也需要seekTo，确保控制器从开头开始播放
      // 避免控制器停留在末尾导致立即触发播放完成
      await _seekInitialPosition(controller, initialPosition);
      if (!_isCurrentPlayRequest(
        playRequestId,
        item.id,
        controller: controller,
      )) {
        return;
      }

      _primeDeferredVideoOutput(item, controller);

      _resetPlaybackTimeline(
        _position,
        running: shouldPlayNow() && controller.value.isPlaying,
      );

      controller.addListener(_onControllerUpdate);
      _lastControllerIsPlaying = controller.value.isPlaying;
      if (shouldPlayNow()) {
        // 乐观更新：立即设置状态为播放中

        // 启动进度追踪定时器

        // 开始播放
        // Mounting the visible VideoPlayer can be part of the native render
        // path. Publish the initialized, positioned controller before waiting
        // for first-frame readiness to avoid a circular loading wait.
        notifyListeners();
        await controller.play();
        if (!_isCurrentPlayRequest(
          playRequestId,
          item.id,
          controller: controller,
        )) {
          return;
        }
        final readiness = await _awaitPlaybackReadinessResult(
          item: item,
          controller: controller,
          playRequestId: playRequestId,
        );
        if (!_isCurrentPlayRequest(
          playRequestId,
          item.id,
          controller: controller,
        )) {
          return;
        }
        if (readiness == _PlaybackReadinessResult.confirmed) {
          _lastControllerIsPlaying = controller.value.isPlaying;
          _state = PlaybackState.playing;
          _transitionPlaybackSession(
            sessionGeneration,
            hasRequiredVideoOutput
                ? PlaybackSessionPhase.ready
                : PlaybackSessionPhase.videoOutputDeferred,
            controller: controller,
          );
          _resetPlaybackTimeline(
            _position,
            running: controller.value.isPlaying,
          );
          _syncWakelockWithState();
          notifyListeners();
          _startProgressTracking();
        } else {
          // Readiness degraded (background clock never started / foreground
          // decoder produced no frame). Keep the episode switch successful:
          // park paused at the recorded position, clear the play intent so
          // the intent commit below cannot re-play, and leave the session
          // ready instead of erroring out.
          _setDesiredPlaying(false);
          _lastControllerIsPlaying = false;
          _state = PlaybackState.paused;
          _transitionPlaybackSession(
            sessionGeneration,
            hasRequiredVideoOutput
                ? PlaybackSessionPhase.ready
                : PlaybackSessionPhase.videoOutputDeferred,
            controller: controller,
          );
          _resetPlaybackTimeline(_position, running: false);
          _syncWakelockWithState();
          notifyListeners();
          _stopProgressTracking();
          await _saveCurrentProgress(immediate: true);
          if (!_isCurrentPlayRequest(
            playRequestId,
            item.id,
            controller: controller,
          )) {
            return;
          }
        }
      } else {
        _lastControllerIsPlaying = controller.value.isPlaying;
        // 保持暂停状态
        _state = PlaybackState.paused;
        _transitionPlaybackSession(
          sessionGeneration,
          hasRequiredVideoOutput
              ? PlaybackSessionPhase.ready
              : PlaybackSessionPhase.videoOutputDeferred,
          controller: controller,
        );
        _syncWakelockWithState();
        // 暂停时也应该保存一次初始状态
        await _saveCurrentProgress(immediate: true);
        if (!_isCurrentPlayRequest(
          playRequestId,
          item.id,
          controller: controller,
        )) {
          return;
        }
      }

      // 保存播放状态快照
      // A transport command can change play/pause intent while preparation or
      // first-frame readiness is pending. Reconcile it before committing.
      // Commit the *current* intent even when the native controller already
      // reached that state. A notification pause can arrive while the initial
      // play Future is pending: the listener correctly pauses the transport,
      // but the earlier loading branch may just have written `playing` again.
      // Leaving that mismatch makes _playPlaylistItem treat a successful
      // switch as failed and reopen/reseek the same source repeatedly.
      if (!await _commitControllerPlaybackIntent(
        sessionGeneration: sessionGeneration,
        playRequestId: playRequestId,
        item: item,
        controller: controller,
      )) {
        return;
      }

      await _savePlaybackStateSnapshot();
      if (!_isCurrentPlayRequest(
        playRequestId,
        item.id,
        controller: controller,
      )) {
        return;
      }

      notifyListeners();

      _refreshSubtitlesForCurrentItem(item);
    } catch (e) {
      await releaseEarlyBilibiliSource();
      await requestMaterializedLease?.release();
      requestMaterializedLease = null;
      await releaseRequestBilibiliPlayback();
      debugPrint('MediaPlaybackService: 播放失败 $e');
      if (!_isCurrentPlayRequest(playRequestId, item.id)) {
        final controller = requestController;
        if (controller != null && !identical(_controller, controller)) {
          await _detachController(
            controller,
            disposeController: true,
            pauseIfPlaying: true,
          );
        }
        return;
      }
      // A failed candidate still owns a native player (and, for Bilibili, a
      // gateway session). Retaining it exhausts mobile decoder slots and can
      // make the next retry render only a black texture.
      final failedController = requestController;
      if (failedController != null) {
        if (identical(_controller, failedController)) {
          await _disposeController(awaitCompletion: true).timeout(
            _mobileControllerReleaseTimeout,
            onTimeout: () => _logPlaybackEvent(
              'failed controller cleanup timed out',
              data: <String, Object?>{'itemId': item.id},
            ),
          );
        } else {
          await _detachController(
            failedController,
            disposeController: true,
            pauseIfPlaying: true,
          ).timeout(
            _mobileControllerReleaseTimeout,
            onTimeout: () => _logPlaybackEvent(
              'failed candidate cleanup timed out',
              data: <String, Object?>{'itemId': item.id},
            ),
          );
        }
      }
      final bool sourceMissing =
          item.sourceRef?.kind != MediaSourceKind.bilibiliStream &&
          !kIsWeb &&
          !await File(item.path).exists();
      _isSourceMissing = sourceMissing;
      if (sourceMissing) _playlistManager?.reloadPlaylist();
      _state = sourceMissing ? PlaybackState.paused : PlaybackState.error;
      _transitionPlaybackSession(
        sessionGeneration,
        sourceMissing
            ? PlaybackSessionPhase.missing
            : PlaybackSessionPhase.failed,
        desiredPlaying: false,
        error: sourceMissing ? null : e.toString(),
      );
      _syncWakelockWithState();
      notifyListeners();
      if (sourceMissing) {
        unawaited(_refreshSubtitlesForCurrentItem(item));
      }
    } finally {
      if (_activePlayInvocationGeneration == sessionGeneration) {
        _activePlayInvocationGeneration = null;
      }
    }
  }

  /// Recreates the active native player so a changed libmpv decoder policy is
  /// applied immediately. Position, pause/play state, rate, volume and media
  /// metadata are restored by the normal [play] hand-off path.
  Future<void> reloadCurrentVideoDecoder() async {
    final item = _currentItem;
    final controller = _controller;
    if (item == null || controller == null || item.type != MediaType.video) {
      return;
    }

    Duration position = _position;
    bool autoPlay = _state == PlaybackState.playing;

    // A preloaded controller was created with the previous decoder policy and
    // must never be hot-swapped into this new session.
    await _disposePreloadedController(awaitCompletion: true);
    await play(
      item,
      startPosition: position,
      autoPlay: autoPlay,
      forceRecreate: true,
    );
  }

  /// 取消仍在初始化中的播放请求，通常用于用户在加载页中主动返回。
  Future<void> cancelPendingPlay({String? expectedItemId}) async {
    final bool matchesExpectedItem =
        expectedItemId == null || _currentItem?.id == expectedItemId;
    if (_state != PlaybackState.loading || !matchesExpectedItem) {
      return;
    }

    _playRequestId++;
    _subtitleLoadRequestId++;
    _clearInitialPositionGuard();
    _hasPlaybackCompleted = false;
    _seekPersistTimer?.cancel();
    _seekPersistTimer = null;
    _seekVerificationTimer?.cancel();
    _seekVerificationTimer = null;
    _stopProgressTracking();

    final controller = _controller;
    final bool shouldDisposeController = _serviceOwnsController;
    _controller = null;
    _serviceOwnsController = false;
    _controllerCreatedWithoutVisiblePlaybackPage = false;
    _lastControllerIsPlaying = null;

    _state = PlaybackState.idle;
    _isSourceMissing = false;
    _currentItem = null;
    final cancelledGeneration = ++_sessionGeneration;
    _sessionController = null;
    _session = PlaybackSessionSnapshot(
      generation: cancelledGeneration,
      itemId: expectedItemId,
      phase: PlaybackSessionPhase.stopped,
      desiredPlaying: false,
      controllerGeneration: _controllerGeneration,
      hasVideoOutput: false,
    );
    _position = Duration.zero;
    _duration = Duration.zero;
    _bufferedPosition = Duration.zero;
    _resetPlaybackTimeline(Duration.zero, running: false, rate: 1.0);
    clearSubtitleState();
    _syncWakelockWithState();
    notifyListeners();

    if (controller != null) {
      await _detachController(
        controller,
        disposeController: shouldDisposeController,
        pauseIfPlaying: true,
      );
    }
  }

  /// Converts a late file-system failure into the same recoverable state used
  /// when [play] finds that the source was already missing.
  void markCurrentSourceMissing({String? expectedItemId}) {
    final item = _currentItem;
    if (item == null ||
        (expectedItemId != null && item.id != expectedItemId) ||
        _isSourceMissing) {
      return;
    }

    _playRequestId++;
    _seekRequestId++;
    _pendingSeekRequestId = null;
    _clearInitialPositionGuard();
    _hasPlaybackCompleted = false;
    _stopProgressTracking();
    unawaited(_disposeController());
    _isSourceMissing = true;
    _state = PlaybackState.paused;
    _playlistManager?.reloadPlaylist();
    _transitionPlaybackSession(
      _session.generation,
      PlaybackSessionPhase.missing,
      desiredPlaying: false,
    );
    _setPlaybackTimelineRunning(false);
    _syncWakelockWithState();
    notifyListeners();
    unawaited(_savePlaybackStateSnapshot());
    unawaited(_refreshSubtitlesForCurrentItem(item));
  }

  /// 暂停播放
  Future<void> pause({
    String? expectedItemId,
    VideoPlayerController? expectedController,
  }) async {
    if (expectedItemId != null && _currentItem?.id != expectedItemId) return;
    if (expectedController != null &&
        !identical(_controller, expectedController)) {
      return;
    }
    if (_activePlayInvocationGeneration == _session.generation) {
      _setDesiredPlaying(false);
      // Publish the intent before awaiting the native transport. Android can
      // keep pause() pending while a newly selected source is still preparing;
      // delaying this notification leaves the media card showing the wrong
      // button and makes a second tap look as though it was ignored.
      notifyListeners();
      final loadingController = _controller;
      if (_currentItem?.id == _session.itemId &&
          loadingController != null &&
          loadingController.value.isPlaying) {
        try {
          await loadingController.pause();
        } catch (_) {}
      }
      return;
    }
    if (_state != PlaybackState.playing) return;
    final controller = _controller;
    final itemId = _currentItem?.id;
    if (controller == null || itemId == null) return;
    final requestId = ++_playRequestId;
    _seekRequestId++;
    _pendingSeekRequestId = null;

    try {
      _preservePlayingStateAfterSeek = false;
      _hasPlaybackCompleted = false;
      _logPlaybackEvent(
        'pause requested',
        data: <String, Object?>{
          'itemId': _currentItem?.id,
          'positionMs': _position.inMilliseconds,
        },
      );
      // 乐观更新：立即设置状态为暂停
      // Freeze the exact position from the last presented VSync before any
      // asynchronous platform callback can replace it with a coarse native
      // sample. Play/pause is a slope change, not a seek.
      _setPlaybackTimelineRunning(false);
      _state = PlaybackState.paused;
      _setDesiredPlaying(false);
      _syncWakelockWithState();
      notifyListeners();

      // 停止进度追踪定时器
      _stopProgressTracking();

      await controller.pause();
      if (!_isCurrentPlayRequest(requestId, itemId, controller: controller)) {
        return;
      }

      // Keep an authoritative timeline position when a network backend
      // briefly reports byte zero during pause acknowledgement.
      if (controller.value.isInitialized) {
        final nativePosition = controller.value.position;
        final positionDeltaMs =
            (nativePosition.inMilliseconds - _position.inMilliseconds).abs();
        if (positionDeltaMs <= _seekVerificationToleranceMs) {
          _position = nativePosition;
        }
        _bufferedPosition = _readBufferedPosition(controller);
      }

      // 暂停时立即保存进度
      await _saveCurrentProgress(immediate: true);
      if (!_isCurrentPlayRequest(requestId, itemId, controller: controller)) {
        return;
      }

      // 保存播放状态快照
      await _savePlaybackStateSnapshot();
      if (!_isCurrentPlayRequest(requestId, itemId, controller: controller)) {
        return;
      }

      notifyListeners();
    } catch (e) {
      debugPrint('MediaPlaybackService: 暂停失败 $e');
    }
  }

  /// 继续播放
  Future<void> resume() async {
    final currentItem = _currentItem;
    if (_activePlayInvocationGeneration == _session.generation) {
      _setDesiredPlaying(true);
      // Keep the notification transport state responsive while the episode
      // switch Future is still active. The play() transaction reconciles this
      // latest intent again before it commits the new controller.
      notifyListeners();
      final loadingController = _controller;
      if (currentItem?.id == _session.itemId &&
          loadingController != null &&
          loadingController.value.isInitialized &&
          !loadingController.value.isPlaying) {
        try {
          await loadingController.play();
        } catch (_) {}
      }
      return;
    }
    if (_state == PlaybackState.error && currentItem != null) {
      _logPlaybackEvent(
        'resume requested after load failure; retrying media',
        data: <String, Object?>{'itemId': currentItem.id},
      );
      await play(
        currentItem,
        autoPlay: true,
        startPosition: _position,
        forceRecreate: true,
      );
      return;
    }
    if (_isSourceMissing && currentItem != null) {
      // The play button doubles as a retry. If the user has restored the file
      // at its original path, the existing page becomes playable immediately.
      await play(currentItem, autoPlay: true, startPosition: _position);
      return;
    }
    if (_hasPlaybackCompleted && currentItem != null) {
      _logPlaybackEvent(
        'resume requested after completion',
        data: <String, Object?>{'itemId': currentItem.id},
      );
      // 修复：使用当前位置而不是从头开始，这样用户拖拽进度条后能正确恢复播放
      final resumePosition =
          (_position < _duration && _position > Duration.zero)
          ? _position
          : Duration.zero;
      await play(currentItem, autoPlay: true, startPosition: resumePosition);
      return;
    }

    if (_state != PlaybackState.paused || currentItem == null) return;
    final controller = _controller;
    final itemId = _currentItem?.id;
    if (controller == null || itemId == null) return;
    final requestId = ++_playRequestId;
    _seekRequestId++;
    _pendingSeekRequestId = null;

    try {
      _setDesiredPlaying(true);
      _hasPlaybackCompleted = false;
      _logPlaybackEvent(
        'resume requested',
        data: <String, Object?>{
          'itemId': _currentItem?.id,
          'positionMs': _position.inMilliseconds,
        },
      );
      // 乐观更新：立即设置状态为播放中
      _state = PlaybackState.playing;
      _syncWakelockWithState();
      notifyListeners();

      // 重新启动进度追踪定时器
      if (currentItem.sourceRef?.kind == MediaSourceKind.bilibiliStream &&
          controller.value.isInitialized &&
          (controller.value.position.inMilliseconds - _position.inMilliseconds)
                  .abs() >
              _seekVerificationToleranceMs) {
        await _seekInitialPosition(controller, _position);
        if (!_isCurrentPlayRequest(requestId, itemId, controller: controller)) {
          return;
        }
      }

      _startProgressTracking();

      await controller.play();
      if (!_isCurrentPlayRequest(requestId, itemId, controller: controller)) {
        return;
      }

      if (controller.value.isInitialized) {
        // Do not copy controller.value.position here. A network backend may
        // expose its initial probe position for one callback after play().
        // The authoritative service timeline already contains the resume
        // position; native samples will catch up through _updatePosition().
        _setPlaybackTimelineRunning(true);
      }

      // 保存播放状态快照
      await _savePlaybackStateSnapshot();
      if (!_isCurrentPlayRequest(requestId, itemId, controller: controller)) {
        return;
      }
    } catch (e) {
      debugPrint('MediaPlaybackService: 继续播放失败 $e');
    }
  }

  /// 从 controller 同步播放状态（用于播放页面状态同步）
  /// 这个方法不进行状态检查，直接更新状态并通知监听器
  bool updatePlaybackStateFromController({
    String? expectedItemId,
    VideoPlayerController? expectedController,
  }) {
    if (expectedItemId != null && _currentItem?.id != expectedItemId) {
      return false;
    }
    final controller = _controller;
    if (expectedController != null &&
        !identical(controller, expectedController)) {
      return false;
    }
    if (controller == null || !controller.value.isInitialized) return false;
    if (_initialPositionSeekInFlight) return false;

    // 直接从 controller 读取实际播放状态
    final controllerIsPlaying = controller.value.isPlaying;
    if (controllerIsPlaying) {
      _preservePlayingStateAfterSeek = false;
    } else if (_pendingSeekRequestId != null ||
        _preservePlayingStateAfterSeek) {
      return false;
    }
    final controllerPosition = controller.value.position;
    final controllerDuration = controller.value.duration;
    final controllerBufferedPosition = _readBufferedPosition(controller);
    if (_shouldIgnoreInitialPositionSample(controllerPosition)) {
      _duration = controllerDuration;
      _bufferedPosition = controllerBufferedPosition;
      return true;
    }
    _capturePlaybackSpeedFromController(controller);
    final reachedPlaybackEnd = _hasReachedPlaybackEnd(
      controllerPosition,
      controllerDuration,
    );

    if (!controllerIsPlaying &&
        !_hasPlaybackCompleted &&
        reachedPlaybackEnd &&
        (_state == PlaybackState.playing || _lastControllerIsPlaying == true)) {
      _position = controllerPosition;
      _duration = controllerDuration;
      _bufferedPosition = controllerBufferedPosition;
      _resetPlaybackTimeline(controllerPosition, running: false);
      _lastControllerIsPlaying = controllerIsPlaying;
      _logPlaybackEvent(
        'controller sync detected playback completion',
        data: <String, Object?>{
          'itemId': _currentItem?.id,
          'positionMs': controllerPosition.inMilliseconds,
          'durationMs': controllerDuration.inMilliseconds,
        },
      );
      _onPlaybackCompleted();
      return true;
    }

    // The session intent is the play/pause authority. A transient controller
    // sample that disagrees with it — a late clock start after a degraded
    // pause, a seek-transition sample, a stale listener during a hand-off —
    // must not flip the public state (and with it the notification button);
    // only progress is taken from the sample. Page toggle buttons read the
    // controller directly, so they are unaffected by this guard.
    if (controllerIsPlaying != _session.desiredPlaying) {
      _lastControllerIsPlaying = controllerIsPlaying;
      _position = controllerPosition;
      _duration = controllerDuration;
      _bufferedPosition = controllerBufferedPosition;
      _resetPlaybackTimeline(
        controllerPosition,
        running: _session.desiredPlaying,
      );
      return true;
    }

    if (controllerIsPlaying) {
      _hasPlaybackCompleted = false;
      _state = PlaybackState.playing;
      _position = controllerPosition;
      _duration = controllerDuration;
      // Continue from the last rendered danmaku position. Re-anchoring to the
      // controller's low-frequency sample here moves every item at once.
      _setPlaybackTimelineRunning(true);
      // 重新启动进度追踪定时器
      _startProgressTracking();
    } else {
      _state = PlaybackState.paused;
      _setPlaybackTimelineRunning(false);
      // 停止进度追踪定时器
      _stopProgressTracking();

      // 更新最终位置
      _position = controllerPosition;
      _duration = controllerDuration;
      _bufferedPosition = controllerBufferedPosition;

      // 暂停时立即保存进度
      _saveCurrentProgress(immediate: true);
    }

    _syncWakelockWithState();

    // 异步保存播放状态快照（不阻塞UI）
    _savePlaybackStateSnapshot().catchError((e) {
      debugPrint('保存播放状态快照失败: $e');
    });

    // 通知监听器，触发 UI 更新
    notifyListeners();
    return true;
  }

  /// 停止播放
  Future<void> stop() async {
    final stoppedItem = _currentItem;
    final stoppedBilibiliStreamItemId =
        stoppedItem?.sourceRef?.kind == MediaSourceKind.bilibiliStream
        ? stoppedItem!.id
        : null;
    _streamQualitySwitchRequestId++;
    _isSwitchingStreamQuality = false;
    final stopRequestId = ++_playRequestId;
    _seekRequestId++;
    _pendingSeekRequestId = null;
    _preservePlayingStateAfterSeek = false;
    _clearInitialPositionGuard();
    _hasPlaybackCompleted = false;
    _logPlaybackEvent(
      'stop requested',
      data: <String, Object?>{
        'itemId': _currentItem?.id,
        'positionMs': _position.inMilliseconds,
      },
    );
    // 保存当前进度
    await _saveCurrentProgress(immediate: true);
    if (stopRequestId != _playRequestId) return;

    // 保存播放状态快照（停止状态）
    if (_progressTracker != null) {
      await _progressTracker!.savePlaybackState(
        PlaybackStateSnapshot(
          currentItemId: null,
          positionMs: 0,
          wasPlaying: false,
          playlistFolderId: null,
        ),
      );
      if (stopRequestId != _playRequestId) return;
    }

    // 停止进度追踪
    _stopProgressTracking();
    _seekPersistTimer?.cancel();
    _seekPersistTimer = null;

    // 释放控制器
    await _disposeController(
      awaitCompletion: stoppedBilibiliStreamItemId != null,
    );
    if (stoppedBilibiliStreamItemId != null) {
      await _bilibiliStreamingService?.releaseItem(stoppedBilibiliStreamItemId);
    }
    unawaited(_disposePreloadedController());
    _preloadTriggered = false;

    _state = PlaybackState.idle;
    _pendingEpisodeNavigation.clear();
    _isSourceMissing = false;
    _streamQualities = const [];
    _selectedStreamQuality = null;
    _streamDisplayAspectRatio = null;
    _currentBilibiliPlayback = null;
    _syncWakelockWithState();
    clearSubtitleState();
    _currentItem = null;
    final stoppedGeneration = ++_sessionGeneration;
    _sessionController = null;
    _session = PlaybackSessionSnapshot(
      generation: stoppedGeneration,
      itemId: stoppedItem?.id,
      phase: PlaybackSessionPhase.stopped,
      desiredPlaying: false,
      controllerGeneration: _controllerGeneration,
      hasVideoOutput: false,
    );
    _position = Duration.zero;
    _duration = Duration.zero;
    _bufferedPosition = Duration.zero;
    _resetPlaybackTimeline(Duration.zero, running: false, rate: 1.0);
    _syncBilibiliCachePolicy();

    notifyListeners();
  }

  /// 跳转到指定位置
  Future<void> seekTo(Duration position, {String source = 'ui'}) async {
    final controller = _controller;
    final itemId = _currentItem?.id;
    final playRequestId = _playRequestId;
    if (controller == null ||
        itemId == null ||
        !controller.value.isInitialized) {
      return;
    }

    // A manual seek supersedes the bounded startup guard. Otherwise a stale
    // native sample from the previous startup could hide the user's target.
    _clearInitialPositionGuard();

    var requestId = -1;
    try {
      final controllerDuration = controller.value.duration;
      if (controllerDuration > Duration.zero &&
          controllerDuration != _duration) {
        _duration = controllerDuration;
      }

      final clampedPosition = _duration > Duration.zero
          ? Duration(
              milliseconds: position.inMilliseconds
                  .clamp(0, _duration.inMilliseconds)
                  .toInt(),
            )
          : (position.inMilliseconds < 0 ? Duration.zero : position);

      // A slow ALAC seek can publish samples from the old position before
      // libmpv reaches the new timestamp. All progress surfaces share this
      // service, so keep those stale samples from snapping every UI back.
      _armInitialPositionGuard(clampedPosition, protectZero: true);

      _lastSeekSource = source;
      _lastRequestedSeekPosition = clampedPosition;
      _lastSeekRequestedAt = DateTime.now();
      _logPlaybackEvent(
        'seek requested',
        data: <String, Object?>{
          'itemId': _currentItem?.id,
          'source': source,
          'targetMs': clampedPosition.inMilliseconds,
          'durationMs': _duration.inMilliseconds,
        },
      );

      requestId = ++_seekRequestId;
      _pendingSeekRequestId = requestId;
      final seeksToPlaybackEnd =
          _duration > Duration.zero &&
          _hasReachedPlaybackEnd(clampedPosition, _duration);
      _preservePlayingStateAfterSeek =
          !seeksToPlaybackEnd &&
          (_preservePlayingStateAfterSeek || _state == PlaybackState.playing);

      _position = clampedPosition;
      // 立即更新插值基线，让 UI 在 seek 后立刻跳到目标位置
      _resetPlaybackTimeline(
        _position,
        running: _state == PlaybackState.playing,
      );
      notifyListeners();

      await controller.seekTo(clampedPosition).timeout(_controllerSeekTimeout);
      if (requestId != _seekRequestId ||
          playRequestId != _playRequestId ||
          !_isCurrentControllerSession(controller, itemId)) {
        return;
      }

      // VideoPlayerController has acknowledged this exact target. Its native
      // position sampler can still lag briefly, so a bounded direct verifier
      // below owns any later correction.
      final actualPosition = clampedPosition;
      if (actualPosition != _position) {
        _position = actualPosition;
        // 校正插值基线，确保插值时钟从实际位置继续推进
        _resetPlaybackTimeline(
          _position,
          running: _state == PlaybackState.playing,
        );
        notifyListeners();
      }
      if (_pendingSeekRequestId == requestId) {
        _pendingSeekRequestId = null;
      }
      _logPlaybackEvent(
        'seek applied',
        data: <String, Object?>{
          'source': source,
          'actualMs': actualPosition.inMilliseconds,
          'deltaMs':
              (actualPosition.inMilliseconds - clampedPosition.inMilliseconds)
                  .abs(),
        },
      );
      _bufferedPosition = _readBufferedPosition(controller);
      _scheduleSeekVerification(
        expectedPosition: clampedPosition,
        source: source,
        controller: controller,
        itemId: itemId,
        requestId: requestId,
      );

      _seekPersistTimer?.cancel();
      _seekPersistTimer = Timer(const Duration(milliseconds: 500), () {
        if (playRequestId != _playRequestId ||
            !_isCurrentControllerSession(controller, itemId)) {
          return;
        }
        _saveCurrentProgress(immediate: true).catchError((e) {
          debugPrint('MediaPlaybackService: 保存进度失败 $e');
        });
        _savePlaybackStateSnapshot().catchError((e) {
          debugPrint('MediaPlaybackService: 保存播放状态快照失败 $e');
        });
      });

      notifyListeners();
    } catch (e) {
      if (_pendingSeekRequestId == requestId) {
        _pendingSeekRequestId = null;
      }
      final isCurrentSession =
          playRequestId == _playRequestId &&
          _isCurrentControllerSession(controller, itemId);
      if (isCurrentSession && controller.value.isInitialized) {
        final controllerDuration = controller.value.duration;
        if (controllerDuration > Duration.zero) {
          _duration = controllerDuration;
        }
        _bufferedPosition = _readBufferedPosition(controller);

        if (e is TimeoutException) {
          // Some native audio backends finish a precise seek after their Dart
          // completion callback stalls. Stop blocking position samples now,
          // then let the bounded verifier reconcile the eventual result.
          final expectedPosition = _lastRequestedSeekPosition ?? _position;
          _armInitialPositionGuard(expectedPosition, protectZero: true);
          _scheduleSeekVerification(
            expectedPosition: expectedPosition,
            source: '$source-timeout',
            controller: controller,
            itemId: itemId,
            requestId: requestId,
          );
        } else {
          _clearInitialPositionGuard();
          _position = controller.value.position;
          _resetPlaybackTimeline(
            _position,
            running: _state == PlaybackState.playing,
          );
        }
        notifyListeners();
      }
      debugPrint('MediaPlaybackService: 跳转失败 $e');
    } finally {
      // Always release the sampling gate owned by this request. In
      // particular, a stale controller/session return or a native Future that
      // times out must never leave all future progress updates suppressed.
      if (_pendingSeekRequestId == requestId) {
        _pendingSeekRequestId = null;
        notifyListeners();
      }
    }
  }

  /// 设置音量
  Future<void> setVolume(double volume) async {
    _volume = volume.clamp(0.0, 1.0);

    if (_controller != null && !_isMuted) {
      await _applyMuteStateToController(reason: 'volume changed');
    }

    notifyListeners();
  }

  /// 切换静音状态
  Future<void> toggleMute() async {
    _isMuted = !_isMuted;
    notifyListeners();
    await Future.wait<void>([
      _persistMuteState(),
      _applyMuteStateToController(reason: 'toggle mute'),
    ]);
  }

  /// 播放下一个媒体
  Future<void> playNext({bool? autoPlay}) {
    final bool shouldAutoPlay = autoPlay ?? SettingsService().autoPlayNextVideo;
    _logPlaybackEvent(
      'skip to next requested',
      data: <String, Object?>{
        'itemId': _currentItem?.id,
        'autoPlay': shouldAutoPlay,
      },
    );
    // 确保播放列表是最新的
    return _enqueueEpisodeNavigation(1, autoPlay: shouldAutoPlay);
  }

  /// 播放上一个媒体
  Future<void> playPrevious({bool? autoPlay}) {
    final bool shouldAutoPlay = autoPlay ?? SettingsService().autoPlayNextVideo;
    _logPlaybackEvent(
      'skip to previous requested',
      data: <String, Object?>{
        'itemId': _currentItem?.id,
        'autoPlay': shouldAutoPlay,
      },
    );
    // 确保播放列表是最新的
    return _enqueueEpisodeNavigation(-1, autoPlay: shouldAutoPlay);
  }

  Future<void> _enqueueEpisodeNavigation(int delta, {required bool autoPlay}) {
    _pendingEpisodeNavigation.add(
      _EpisodeNavigationCommand(delta: delta, autoPlay: autoPlay),
    );
    final completer = _episodeNavigationCompleter ??= Completer<void>();
    if (!_isDrainingEpisodeNavigation) {
      _isDrainingEpisodeNavigation = true;
      scheduleMicrotask(_drainEpisodeNavigation);
    }
    return completer.future;
  }

  Future<void> _drainEpisodeNavigation() async {
    final completer = _episodeNavigationCompleter;
    try {
      while (_pendingEpisodeNavigation.isNotEmpty) {
        final commands = List<_EpisodeNavigationCommand>.of(
          _pendingEpisodeNavigation,
        );
        _pendingEpisodeNavigation.clear();
        await _executeEpisodeNavigation(commands);
      }
    } catch (error, stackTrace) {
      if (completer != null && !completer.isCompleted) {
        completer.completeError(error, stackTrace);
      }
    } finally {
      _isDrainingEpisodeNavigation = false;
      if (identical(_episodeNavigationCompleter, completer)) {
        _episodeNavigationCompleter = null;
      }
      if (completer != null && !completer.isCompleted) {
        completer.complete();
      }
    }
  }

  Future<void> _executeEpisodeNavigation(
    List<_EpisodeNavigationCommand> commands,
  ) async {
    final manager = _playlistManager;
    if (manager == null || commands.isEmpty) return;
    manager.reloadPlaylist();
    final snapshot = manager.snapshot;
    if (snapshot.currentIndex < 0 || snapshot.entries.isEmpty) return;

    var targetIndex = snapshot.currentIndex;
    for (final command in commands) {
      targetIndex = (targetIndex + command.delta).clamp(
        0,
        snapshot.entries.length - 1,
      );
    }
    if (targetIndex == snapshot.currentIndex) return;
    final target = snapshot.entries[targetIndex];
    if (!manager.isQueueEligible(target)) {
      manager.reloadPlaylist();
      return;
    }
    await _playPlaylistItem(target, autoPlay: commands.last.autoPlay);
  }

  /// 播放列表切换统一入口：切换前立即保存当前媒体进度，
  /// 避免新的保存请求覆盖上一媒体尚未落库的防抖进度。
  Future<void> playPlaylistItem(
    VideoItem item, {
    bool? autoPlay,
    Duration? startPosition,
    bool forceFromStart = false,
  }) async {
    final manager = _playlistManager;
    if (manager != null && !manager.isQueueEligible(item)) return;
    await _playPlaylistItem(
      item,
      autoPlay: autoPlay ?? SettingsService().autoPlayNextVideo,
      startPosition: startPosition,
      forceFromStart: forceFromStart,
    );
  }

  /// Serializes every media-switch entry ([_playPlaylistItem]) — episode
  /// navigation, notification queue taps, completion auto-advance and errored
  /// controller recovery — so two switches can never interleave their
  /// controller dispose/initialize work. Request-id checks inside [play]
  /// remain the second line of defense.
  Future<void> _mediaSwitchLock = Future<void>.value();

  Future<void> _runInMediaSwitchLock(Future<void> Function() action) {
    final operation = _mediaSwitchLock.then((_) => action());
    _mediaSwitchLock = operation.catchError((Object error, StackTrace stack) {
      _logPlaybackEvent(
        'media switch failed',
        data: <String, Object?>{'error': error.toString()},
      );
    });
    return operation;
  }

  Future<void> _playPlaylistItem(
    VideoItem item, {
    bool autoPlay = true,
    Duration? startPosition,
    bool forceFromStart = false,
  }) {
    return _runInMediaSwitchLock(
      () => _playPlaylistItemLocked(
        item,
        autoPlay: autoPlay,
        startPosition: startPosition,
        forceFromStart: forceFromStart,
      ),
    );
  }

  Future<void> _playPlaylistItemLocked(
    VideoItem item, {
    bool autoPlay = true,
    Duration? startPosition,
    bool forceFromStart = false,
  }) async {
    await _saveCurrentProgress(immediate: true);

    var frozenStartPosition =
        startPosition ??
        _progressTracker?.getProgress(item.id) ??
        Duration(milliseconds: item.lastPositionMs);
    final metadataDuration = Duration(
      milliseconds: item.durationMs > 0 ? item.durationMs : 0,
    );
    frozenStartPosition = PlaybackBehaviorPolicy.normalizeEpisodeStartPosition(
      savedPosition: frozenStartPosition,
      duration: metadataDuration,
      forceFromStart: forceFromStart,
    );

    final playlistManager = _playlistManager;
    if (playlistManager != null) {
      final targetIndex = playlistManager.indexOfItem(item.id);
      if (targetIndex >= 0) {
        playlistManager.setCurrentIndex(targetIndex);
      }
    }

    // 同一视频：复用控制器而非销毁重建（seekTo + play），避免 probe 开销
    // 仅当控制器不可复用时才走销毁路径
    if (_currentItem?.id == item.id && _controller != null) {
      clearSubtitleState();
      _seekPersistTimer?.cancel();
      _seekPersistTimer = null;
      if (!_controllerIsReusableForItem(item)) {
        unawaited(_disposeController());
        _lastControllerIsPlaying = null;
      }
      // 可复用时由 play() 走 _controllerIsReusableForItem 复用路径
    }

    final int maxAttempts = _mediaSwitchMaxAttempts;
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      await play(
        item,
        autoPlay: autoPlay,
        startPosition: frozenStartPosition,
        forceRecreate: attempt > 1,
      );
      if (_isControllerReadyForItem(item) ||
          _isSourceMissing ||
          _currentItem?.id != item.id) {
        return;
      }
      if (attempt >= maxAttempts) return;
      if (!kIsWeb &&
          Platform.isAndroid &&
          item.type == MediaType.audio &&
          item.sourceRef?.kind != MediaSourceKind.bilibiliStream) {
        // The codec probe handles known formats before the first controller is
        // created. This failure-driven promotion covers device-specific gaps
        // and unusual containers: retry the exact same queue item through
        // media_kit without introducing a second playback/session state.
        LocalPlaybackBackendPolicy.preferWideCodecBackend(item.path);
      }
      _logPlaybackEvent(
        'media switch attempt failed; retrying',
        data: <String, Object?>{
          'itemId': item.id,
          'attempt': attempt,
          'resumeMs': frozenStartPosition.inMilliseconds,
        },
      );
      await Future<void>.delayed(
        Duration(milliseconds: attempt == 1 ? 300 : 900),
      );
      if (_currentItem?.id != item.id) return;
    }
  }

  int _binarySearchFirstStartGT(int posMs) {
    return _subtitleTimeline.firstStartAfterMs(posMs);
  }

  int _findCurrentSubtitleIndexByPositionMs(int posMs) {
    return _subtitleTimeline.indexAtMs(posMs);
  }

  void handleExternalDoubleTapSeek({
    required bool isLeft,
    required int doubleTapSeekSeconds,
    required bool enableDoubleTapSubtitleSeek,
    required Duration subtitleOffset,
    String source = 'external_double_tap',
  }) {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    if (_state == PlaybackState.idle || _state == PlaybackState.error) return;

    final currentPos = _position;
    final duration = _duration > Duration.zero
        ? _duration
        : controller.value.duration;
    Duration target = Duration.zero;
    final bool hasActiveSeekWindow = _externalSeekResetTimer?.isActive ?? false;

    if (hasActiveSeekWindow) {
      _externalSeekResetTimer?.cancel();
    } else {
      _externalSubtitleSeekAccumulator = 0;
      _externalInitialSeekPosition =
          enableDoubleTapSubtitleSeek && _subtitles.isNotEmpty
          ? currentPos - subtitleOffset
          : currentPos;
    }

    if (isLeft) {
      _externalSubtitleSeekAccumulator--;
    } else {
      _externalSubtitleSeekAccumulator++;
    }

    if (enableDoubleTapSubtitleSeek && _subtitles.isNotEmpty) {
      final int initialPosMs = _externalInitialSeekPosition!.inMilliseconds;
      int nextSubIndex = _binarySearchFirstStartGT(initialPosMs);
      if (nextSubIndex < 0) nextSubIndex = 0;
      if (nextSubIndex > _subtitles.length) nextSubIndex = _subtitles.length;

      final int currentSubIndex = _findCurrentSubtitleIndexByPositionMs(
        initialPosMs,
      );
      int pivotIndex;
      bool isAtStartOfSub = false;

      if (currentSubIndex != -1) {
        pivotIndex = currentSubIndex;
        if (initialPosMs <
            _subtitles[currentSubIndex].startTime.inMilliseconds + 500) {
          isAtStartOfSub = true;
        }
      } else {
        pivotIndex = nextSubIndex - 1;
      }

      int targetIndex;
      if (_externalSubtitleSeekAccumulator < 0) {
        int jumps = _externalSubtitleSeekAccumulator.abs();
        if (currentSubIndex != -1 && !isAtStartOfSub) {
          jumps--;
          targetIndex = currentSubIndex;
        } else {
          targetIndex = pivotIndex;
        }
        targetIndex -= jumps;
      } else {
        targetIndex = pivotIndex + _externalSubtitleSeekAccumulator;
      }

      if (targetIndex < 0) {
        target = Duration.zero;
      } else if (targetIndex >= _subtitles.length) {
        target = duration;
      } else {
        target = _subtitles[targetIndex].startTime + subtitleOffset;
      }
    } else {
      final initialPosition = _externalInitialSeekPosition ?? currentPos;
      target =
          initialPosition +
          Duration(
            seconds: doubleTapSeekSeconds * _externalSubtitleSeekAccumulator,
          );
    }

    if (target < Duration.zero) target = Duration.zero;
    if (target > duration) target = duration;
    _externalSeekResetTimer = Timer(const Duration(milliseconds: 2000), () {
      _externalSubtitleSeekAccumulator = 0;
      _externalInitialSeekPosition = null;
    });
    unawaited(seekTo(target, source: source));
  }

  /// 控制器更新监听器（用于处理播放状态变化）
  void _onControllerUpdate() {
    final controller = _controller;
    if (controller == null) return;
    if (!controller.value.isInitialized) {
      if (controller.value.hasError) {
        _scheduleErroredControllerRecovery(controller);
      }
      return;
    }

    // 这个监听器主要用于处理播放状态变化（如播放完成、错误等）
    // 位置更新由 _positionUpdateTimer 定时器处理，避免过度通知

    // 检查播放完成
    final position = _controller!.value.position;
    final controllerIsPlaying = _controller!.value.isPlaying;
    final wasControllerPlaying =
        _lastControllerIsPlaying ?? controllerIsPlaying;
    final controllerPlaybackSpeed = _controller!.value.playbackSpeed;
    final playbackSpeedChanged =
        _pendingPlaybackSpeed == null &&
        (_playbackSpeed - controllerPlaybackSpeed).abs() >= 0.001;
    if (playbackSpeedChanged) {
      _playbackSpeed = controllerPlaybackSpeed;
      _confirmedPlaybackSpeed = controllerPlaybackSpeed;
      if (_timelineClock.isInitialized) {
        _timelineClock.setRate(controllerPlaybackSpeed);
      }
    }
    final bufferedPosition = _readBufferedPosition(_controller!);
    if (!_controllerVolumeMatchesDesired(_controller!)) {
      unawaited(
        _applyMuteStateToController(reason: 'controller drift detected'),
      );
    }
    if (bufferedPosition != _bufferedPosition) {
      _bufferedPosition = bufferedPosition;
    }

    if (_initialPositionSeekInFlight) return;

    // seek 期间 native controller 可能先发出 isPlaying=false，完成后再恢复。
    // 不记录这个过渡状态，也不触发播放完成/暂停同步，避免按钮闪成三角形。
    if (controllerIsPlaying) {
      _preservePlayingStateAfterSeek = false;
    } else if (_pendingSeekRequestId != null ||
        _preservePlayingStateAfterSeek) {
      return;
    }

    // 修复：使用_position而不是controller.value.position来判断播放完成
    // 因为controller.value.position可能还没有更新
    if (!_hasPlaybackCompleted &&
        _hasReachedPlaybackEnd(_position, _duration) &&
        (wasControllerPlaying ||
            controllerIsPlaying ||
            _state == PlaybackState.playing)) {
      _onPlaybackCompleted();
    }

    if (_lastControllerIsPlaying != controllerIsPlaying) {
      _lastControllerIsPlaying = controllerIsPlaying;
      _logPlaybackEvent(
        'controller play state changed',
        data: <String, Object?>{
          'isPlaying': controllerIsPlaying,
          'positionMs': position.inMilliseconds,
        },
      );
      // During initial loading, play-state changes are expected before the
      // first frame readiness check completes. Keep the public session state
      // as loading; the play request will commit playing (or error) after that
      // check. The controller itself has already been published for mounting.
      if (_state != PlaybackState.loading) {
        updatePlaybackStateFromController();
      }
    } else if (playbackSpeedChanged) {
      notifyListeners();
    }
  }

  void _scheduleErroredControllerRecovery(VideoPlayerController controller) {
    if (_controllerErrorRecovery != null ||
        !identical(_controller, controller)) {
      return;
    }
    final item = _currentItem;
    if (item == null || _isSourceMissing) return;

    final resumePosition = _position;
    final shouldPlay = _state == PlaybackState.playing;
    final error = controller.value.errorDescription;
    if (!kIsWeb &&
        Platform.isAndroid &&
        item.type == MediaType.audio &&
        item.sourceRef?.kind != MediaSourceKind.bilibiliStream) {
      // Some device decoders initialize successfully and report the real
      // codec/container failure only after playback starts. Promote that path
      // before the unified recovery re-enters _playPlaylistItem.
      LocalPlaybackBackendPolicy.preferWideCodecBackend(item.path);
    }
    _logPlaybackEvent(
      'controller became erroneous; rebuilding playback session',
      data: <String, Object?>{
        'itemId': item.id,
        'positionMs': resumePosition.inMilliseconds,
        'playing': shouldPlay,
        'error': error,
      },
    );

    late final Future<void> recovery;
    recovery =
        () async {
              if (!identical(_controller, controller) ||
                  _currentItem?.id != item.id) {
                return;
              }
              await _playPlaylistItem(
                item,
                autoPlay: shouldPlay,
                startPosition: resumePosition,
              );
            }()
            .catchError((Object recoveryError, StackTrace stackTrace) {
              _logPlaybackEvent(
                'errored controller recovery failed',
                data: <String, Object?>{
                  'itemId': item.id,
                  'error': recoveryError.toString(),
                },
              );
            })
            .whenComplete(() {
              if (identical(_controllerErrorRecovery, recovery)) {
                _controllerErrorRecovery = null;
              }
            });
    _controllerErrorRecovery = recovery;
  }

  Future<List<SubtitleItem>> _parseSubtitleFile(String path) async {
    try {
      final file = File(path);
      if (!await file.exists()) return [];

      final length = await file.length();
      if (length > 100 * 1024 * 1024) {
        debugPrint("Subtitle file too large ($length bytes), skipping: $path");
        return [];
      }

      final ext = path.toLowerCase();
      // Version the cache so an update cannot reuse a pre-normalization
      // in-memory result for this subtitle path.
      final String cacheKey = '$path::timeline_v2';
      final cached = _subtitleCache[cacheKey];
      if (cached != null) return cached;
      List<SubtitleItem> parsed = [];

      if (ext.endsWith('.sup')) {
        parsed = await PgsParser.parse(path);
      } else if (ext.endsWith('.idx')) {
        final converted = await SubtitleConverter.convert(
          inputPath: path,
          targetExtension: '.sup',
        );
        if (converted != null) parsed = await PgsParser.parse(converted);
      } else if (ext.endsWith('.scc')) {
        final converted = await SubtitleConverter.convert(
          inputPath: path,
          targetExtension: '.srt',
        );
        if (converted != null) return _parseSubtitleFile(converted);
      } else if (ext.endsWith('.sub')) {
        if (await SubtitleConverter.isMicroDvdSub(path)) {
          final converted = await SubtitleConverter.convert(
            inputPath: path,
            targetExtension: '.srt',
          );
          if (converted != null) return _parseSubtitleFile(converted);
        } else {
          final converted = await SubtitleConverter.convert(
            inputPath: path,
            targetExtension: '.sup',
          );
          if (converted != null) parsed = await PgsParser.parse(converted);
        }
      } else {
        List<int> bytes = await file.readAsBytes();
        String content = SubtitleParser.decodeBytes(bytes);

        if (content.isNotEmpty) {
          final serialized = await compute(
            _parseTextSubtitlesToSerializable,
            content,
          );
          parsed = serialized
              .map(
                (m) => SubtitleItem(
                  index: (m['i'] as int?) ?? 0,
                  startTime: Duration(milliseconds: (m['s'] as int?) ?? 0),
                  endTime: Duration(milliseconds: (m['e'] as int?) ?? 0),
                  text: (m['t'] as String?) ?? "",
                ),
              )
              .toList();
        }
      }

      if (parsed.isNotEmpty) {
        parsed.sort((a, b) => a.startTime.compareTo(b.startTime));
        if (YouTubeAutoCaptionNormalizer.shouldNormalize(parsed)) {
          parsed = YouTubeAutoCaptionNormalizer.normalize(parsed);
        }
      }
      _subtitleCache[cacheKey] = parsed;
      return parsed;
    } catch (e) {
      developer.log('Load sub error', error: e);
      return [];
    }
  }

  /* Legacy source/path gate retained only as historical context:
  bool _shouldNormalizeYouTubeAutoCaptions(String subtitlePath) {
    final currentItem = _currentItem;
    if (currentItem == null) {
      return false;
    }
    final sourceRef = currentItem.sourceRef;
    final sourceValue = (sourceRef?.originalValue ?? sourceRef?.value ?? '')
        .toLowerCase();
    final bool isYouTubeSource =
        sourceValue.contains('youtube.com') || sourceValue.contains('youtu.be');
    if (!isYouTubeSource ||
        !currentItem.usesManagedAssociatedSubtitles ||
        currentItem.isBilibiliExported) {
      return false;
    }

    final baseName = p.basename(p.normalize(subtitlePath)).toLowerCase();
    return baseName.contains('auto') ||
        baseName.contains('asr') ||
        baseName.contains('caption') ||
        baseName.contains('srv') ||
        baseName.contains('自动') ||
        baseName.contains('.translated.');
  }
  */

  /// 更新当前字幕（支持连续字幕）
  bool _updateCurrentSubtitle() {
    if (_subtitles.isEmpty) {
      final changed = _currentSubtitle != null || _lastSubtitleIndex != -1;
      if (_currentSubtitle != null) {
        _currentSubtitle = null;
      }
      _lastSubtitleIndex = -1;
      return changed;
    }

    final int foundIndex = _subtitleTimeline.indexAtMs(
      _position.inMilliseconds,
      preferredIndex: _lastSubtitleIndex,
    );
    final SubtitleItem? foundSubtitle = foundIndex >= 0
        ? _subtitles[foundIndex]
        : null;
    _lastSubtitleIndex = foundIndex;

    if (_currentSubtitle != foundSubtitle) {
      _currentSubtitle = foundSubtitle;
      return true;
    }
    return false;
  }

  /// 播放完成处理
  void _onPlaybackCompleted() {
    if (_isHandlingPlaybackCompletion) return;
    final completedItem = _currentItem;
    final completedController = _controller;
    if (completedItem == null ||
        completedController == null ||
        !completedController.value.isInitialized) {
      return;
    }
    _isHandlingPlaybackCompletion = true;
    unawaited(
      _handlePlaybackCompleted(
        completedItemId: completedItem.id,
        completedController: completedController,
        completedPlayRequestId: _playRequestId,
      ),
    );
  }

  Future<void> _handlePlaybackCompleted({
    required String completedItemId,
    required VideoPlayerController completedController,
    required int completedPlayRequestId,
  }) async {
    try {
      await Future<void>.delayed(_playbackCompletionConfirmationDelay);
      if (completedPlayRequestId != _playRequestId ||
          _currentItem?.id != completedItemId ||
          !identical(_controller, completedController) ||
          !completedController.value.isInitialized) {
        return;
      }

      final confirmedPosition = completedController.value.position;
      final confirmedDuration = completedController.value.duration;
      if (completedController.value.isPlaying ||
          !_hasReachedPlaybackEnd(confirmedPosition, confirmedDuration)) {
        _logPlaybackEvent(
          'ignored unconfirmed playback completion',
          data: <String, Object?>{
            'itemId': completedItemId,
            'positionMs': confirmedPosition.inMilliseconds,
            'durationMs': confirmedDuration.inMilliseconds,
            'isPlaying': completedController.value.isPlaying,
          },
        );
        return;
      }

      _preservePlayingStateAfterSeek = false;
      _position = confirmedPosition;
      _duration = confirmedDuration;
      _bufferedPosition = _readBufferedPosition(completedController);

      // 先保存当前进度（在末尾的位置）
      await _saveCurrentProgress(immediate: true);

      // 修复：播放完成后，将进度重置为0并保存
      // 这样用户下次播放时会从开头开始，避免无法跳转上一集或进入已完成的视频
      if (_progressTracker != null) {
        await _progressTracker!.saveProgressImmediately(
          completedItemId,
          Duration.zero,
        );
      }

      if (completedPlayRequestId != _playRequestId ||
          _currentItem?.id != completedItemId ||
          !identical(_controller, completedController)) {
        return;
      }

      final settings = SettingsService();
      final shouldAutoPlay = settings.autoPlayOnCompletion;
      if (!shouldAutoPlay) {
        _hasPlaybackCompleted = true;
        _state = PlaybackState.paused;
        _syncWakelockWithState();
        _stopProgressTracking();
        await _savePlaybackStateSnapshot();
        notifyListeners();
        return;
      }

      _hasPlaybackCompleted = false;
      _playlistManager?.reloadPlaylist();
      final VideoItem? targetItem = _findPlayableRelative(
        next: true,
        wrap: true,
        includeCurrentAfterWrap: true,
      );
      if (targetItem == null) {
        await stop();
        return;
      }

      await _playPlaylistItem(
        targetItem,
        autoPlay: true,
        forceFromStart: settings.autoPlayOnCompletionFromStart,
      );
    } finally {
      _isHandlingPlaybackCompletion = false;
    }
  }

  bool _hasReachedPlaybackEnd(Duration position, Duration duration) {
    if (duration <= Duration.zero) {
      return false;
    }
    const completionTolerance = Duration(milliseconds: 200);
    return position + completionTolerance >= duration;
  }

  /// 启动进度追踪定时器
  void _startProgressTracking() {
    _stopProgressPersistence();
    _stopRealtimeSyncLoop();

    // 每5秒保存一次进度
    _progressTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      _saveCurrentProgress(immediate: true);
      _savePlaybackStateSnapshot();
    });

    _startRealtimeSyncLoop();
  }

  /// 停止进度追踪定时器
  void _stopProgressTracking() {
    _stopProgressPersistence();
    _stopRealtimeSyncLoop();
  }

  void _startRealtimeSyncLoop() {
    _stopRealtimeSyncLoop();
    if (_state != PlaybackState.playing) return;
    if (_isAppInForeground) {
      _startPositionUpdates();
      return;
    }
    _backgroundMediaSyncTimer = Timer.periodic(_backgroundMediaSyncInterval, (
      _,
    ) {
      _updatePosition();
    });
  }

  void _stopRealtimeSyncLoop() {
    _stopPositionUpdates();
    _stopBackgroundMediaSync();
  }

  void _startPositionUpdates() {
    _stopPositionUpdates();
    if (!_isAppInForeground || _state != PlaybackState.playing) return;
    _positionUpdateTimer = Timer.periodic(const Duration(milliseconds: 300), (
      _,
    ) {
      _updatePosition();
    });
    _startInterpolationTicker();
  }

  void _stopPositionUpdates() {
    _positionUpdateTimer?.cancel();
    _positionUpdateTimer = null;
    _stopInterpolationTicker();
  }

  // ===== 插值时钟：每帧平滑推进 positionNotifier =====

  void _startInterpolationTicker() {
    _stopInterpolationTicker();
    final speed = _effectiveInterpolationSpeed();
    if (!_timelineClock.isInitialized) {
      _resetPlaybackTimeline(
        _position,
        running: _shouldTimelineRun(),
        rate: speed,
      );
    } else {
      _timelineClock.setDuration(_duration);
      _timelineClock.setRate(speed);
      _timelineClock.setRunning(_shouldTimelineRun());
    }
    _interpolationTicker = Ticker((frameElapsed) {
      if (_state != PlaybackState.playing) return;
      final currentSpeed = _effectiveInterpolationSpeed();
      if ((_timelineClock.rate - currentSpeed).abs() >= 0.001) {
        _timelineClock.setRate(currentSpeed);
      }
      final shouldRun = _shouldTimelineRun();
      if (_timelineClock.isRunning != shouldRun) {
        _timelineClock.setRunning(shouldRun);
      }
      // Never spread a missed frame over later frames. A frame presented two
      // VSync intervals later must sample the position two intervals later;
      // otherwise moving overlays slow down and then visibly catch up.
      final timelinePosition = _timelineClock.sampleFrame(frameElapsed);
      if (timelinePosition != positionNotifier.value) {
        positionNotifier.value = timelinePosition;
      }
    });
    _interpolationTicker!.start();
  }

  double _effectiveInterpolationSpeed() {
    final nativeRate = _nativePresentationPlaybackSpeed;
    if (nativeRate != null && nativeRate.isFinite && nativeRate > 0) {
      return nativeRate;
    }
    return _confirmedPlaybackSpeed.isFinite && _confirmedPlaybackSpeed > 0
        ? _confirmedPlaybackSpeed
        : 1.0;
  }

  bool _shouldTimelineRun() {
    final controller = _controller;
    return _state == PlaybackState.playing &&
        controller != null &&
        controller.value.isInitialized &&
        controller.value.isPlaying &&
        !controller.value.isBuffering;
  }

  void _resetPlaybackTimeline(
    Duration position, {
    required bool running,
    double? rate,
  }) {
    _timelineClock.reset(
      position,
      running: running,
      rate: rate ?? _effectiveInterpolationSpeed(),
      duration: _duration,
    );
    if (positionNotifier.value != _timelineClock.position) {
      positionNotifier.value = _timelineClock.position;
    }
    _setCoarsePosition(_timelineClock.position);
  }

  void _setPlaybackTimelineRunning(bool running) {
    final speed = _effectiveInterpolationSpeed();
    if (!_timelineClock.isInitialized) {
      _resetPlaybackTimeline(_position, running: running, rate: speed);
      return;
    }
    _timelineClock.setDuration(_duration);
    _timelineClock.setRate(speed);
    _timelineClock.setRunning(running);
    final timelinePosition = _timelineClock.position;
    if (positionNotifier.value != timelinePosition) {
      positionNotifier.value = timelinePosition;
    }
    _setCoarsePosition(timelinePosition);
  }

  void _setCoarsePosition(Duration position) {
    if (coarsePositionNotifier.value != position) {
      coarsePositionNotifier.value = position;
    }
  }

  void _stopInterpolationTicker() {
    _interpolationTicker?.stop();
    _interpolationTicker?.dispose();
    _interpolationTicker = null;
  }

  void _stopBackgroundMediaSync() {
    _backgroundMediaSyncTimer?.cancel();
    _backgroundMediaSyncTimer = null;
  }

  void _stopProgressPersistence() {
    _progressTimer?.cancel();
    _progressTimer = null;
  }

  /// 更新播放位置（用于实时UI同步）
  void _updatePosition() {
    if (_controller == null || !_controller!.value.isInitialized) return;
    if (_state != PlaybackState.playing) return;

    final newPosition = _controller!.value.position;
    final newDuration = _controller!.value.duration;
    final newBufferedPosition = _readBufferedPosition(_controller!);
    final durationChanged = newDuration != _duration;

    if (_shouldIgnoreInitialPositionSample(newPosition)) {
      _duration = newDuration;
      _bufferedPosition = newBufferedPosition;
      return;
    }

    // controller.seekTo 是异步的。播放状态下等待 native seek 完成期间，
    // controller 仍可能上报跳转前的位置；接受该样本会让进度条先到目标、
    // 再退回旧位置、最后再次到目标。此时保留上面的乐观目标位置即可。
    if (_pendingSeekRequestId != null) {
      return;
    }

    // 只有当位置或时长发生变化时才通知监听器
    if (newPosition != _position ||
        newDuration != _duration ||
        newBufferedPosition != _bufferedPosition) {
      _position = newPosition;
      _duration = newDuration;
      _bufferedPosition = newBufferedPosition;
      _setCoarsePosition(newPosition);

      // 更新插值基线（让插值时钟从真实位置继续平滑推进）
      // Native samples are often coarse or delayed, so they update metadata
      // only. Visible animation is re-anchored solely by an explicit seek,
      // media replacement, or real playback completion.
      _timelineClock.setDuration(_duration);

      if (_currentItem != null &&
          _progressTracker != null &&
          _duration > Duration.zero) {
        final durationMs = _duration.inMilliseconds;
        if (_currentItem!.durationMs == 0 ||
            _currentItem!.durationMs != durationMs) {
          _progressTracker!.saveDurationImmediately(
            _currentItem!.id,
            _duration,
          );
        }
      }

      if (durationChanged &&
          _currentItem != null &&
          _duration > Duration.zero) {
        // _lastPushedMediaDuration was removed
      }

      // 更新当前字幕
      final subtitleChanged = _updateCurrentSubtitle();

      // 检查是否播放结束
      if (_position >= _duration && _duration > Duration.zero) {
        _onPlaybackCompleted();
      }

      // 预加载下一个视频（进度达 80% 时触发一次）
      if (!_preloadTriggered &&
          _duration > Duration.zero &&
          _position.inMilliseconds >=
              (_duration.inMilliseconds * _preloadThreshold).toInt()) {
        _preloadTriggered = true;
        _maybePreloadNextVideo();
      }

      // Position and buffering change frequently. Progress-only consumers use
      // coarsePositionNotifier; rebuilding every provider consumer here was a
      // recurring source of animation-frame misses.
      if (durationChanged || subtitleChanged) {
        notifyListeners();
      }
    }
  }

  // _updateNotificationProgress 已移除，改用事件驱动

  /// 预加载播放列表中的下一个视频控制器
  void _maybePreloadNextVideo() {
    // 低端设备可通过设置关闭预加载
    if (!SettingsService().enableVideoPreload) return;
    // Mobile decoder pools are commonly limited to one or two instances. A
    // speculative controller can block a background episode switch.
    if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) return;

    final nextItem = nextPlayableItem;
    if (nextItem == null) return;
    if (nextItem.sourceRef?.kind == MediaSourceKind.bilibiliStream) return;

    // 如果预加载的已经是目标 item，跳过
    if (_preloadedItemId == nextItem.id && _preloadedController != null) return;

    // 释放之前的预加载控制器
    unawaited(_disposePreloadedController());

    _preloadedItemId = nextItem.id;
    _preloadedRequestId = _playRequestId;

    final file = File(nextItem.path);
    unawaited(() async {
      if (!await file.exists()) return;
      // 竞态检查：播放请求已变化
      if (_preloadedRequestId != _playRequestId) return;
      // 当前播放项可能已变化
      if (_preloadedItemId != nextItem.id) return;

      VideoPlayerController? candidate;
      try {
        final playbackPath = _libraryService != null
            ? await _libraryService!.ensureCompatiblePlaybackFile(nextItem)
            : (await AudioPlaybackCompatibilityService.resolve(
                file,
                isAudio: nextItem.type == MediaType.audio,
                existingPlaybackPath: nextItem.playbackPath,
              )).path;
        final playbackFile = File(playbackPath);
        final controller = VideoPlayerController.file(
          playbackFile,
          videoPlayerOptions: buildVideoPlayerOptions(),
        );
        candidate = controller;
        await controller.initialize().timeout(_controllerInitializeTimeout);
        // 竞态检查：预加载期间用户可能已切换视频
        if (_preloadedItemId != nextItem.id ||
            _preloadedRequestId != _playRequestId) {
          unawaited(_disposeTrackedController(controller));
          return;
        }
        _preloadedController = controller;
        candidate = null;
        _logPlaybackEvent(
          'preload next video completed',
          data: {'itemId': nextItem.id},
        );
      } catch (e) {
        final failedCandidate = candidate;
        if (failedCandidate != null) {
          unawaited(_disposeTrackedController(failedCandidate));
        }
        _logPlaybackEvent(
          'preload next video failed',
          data: {'itemId': nextItem.id, 'error': e.toString()},
        );
      }
    }());
  }

  /// 释放预加载的控制器
  Future<void> _disposePreloadedController({
    bool awaitCompletion = false,
  }) async {
    final controller = _preloadedController;
    _preloadedController = null;
    _preloadedItemId = null;
    if (controller != null) {
      if (awaitCompletion) {
        await _disposeTrackedController(controller);
      } else {
        unawaited(_disposeTrackedController(controller));
      }
    }
  }

  /// 尝试使用预加载的控制器，返回 true 表示热替换成功
  bool _tryUsePreloadedController(VideoItem item) {
    if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
      unawaited(_disposePreloadedController());
      return false;
    }
    if (_preloadedController == null || _preloadedItemId != item.id) {
      return false;
    }
    final controller = _preloadedController!;
    _preloadedController = null;
    _preloadedItemId = null;

    try {
      if (!controller.value.isInitialized) {
        unawaited(_disposeTrackedController(controller));
        return false;
      }
    } catch (_) {
      unawaited(_disposeTrackedController(controller));
      return false;
    }

    _controller = controller;
    _serviceOwnsController = true;
    _controllerCreatedWithoutVisiblePlaybackPage =
        item.type == MediaType.video &&
        !_controllerHasRequiredVideoOutput(item, controller);
    _attachNativePositionStream(controller);
    _logPlaybackEvent(
      'hot-swapped preloaded controller',
      data: {'itemId': item.id},
    );
    return true;
  }

  /// 保存当前播放进度
  /// Persists the authoritative playback position for lifecycle and route
  /// transitions. Playback pages must use this instead of reading the native
  /// controller directly; the latter can briefly report zero during an online
  /// stream's initial probe.
  Future<void> persistCurrentProgress({
    String? expectedItemId,
    VideoPlayerController? expectedController,
  }) async {
    if (expectedItemId != null && _currentItem?.id != expectedItemId) return;
    if (expectedController != null &&
        !identical(_controller, expectedController)) {
      return;
    }
    final item = _currentItem;
    if (item == null) return;
    final itemId = item.id;
    final position = _position;
    final progressTracker = _progressTracker;
    if (progressTracker == null) {
      await _libraryService?.updateVideoProgress(
        itemId,
        position.inMilliseconds,
      );
      return;
    }
    await progressTracker.saveProgressImmediately(itemId, position);
    if (_currentItem?.id != itemId ||
        (expectedController != null &&
            !identical(_controller, expectedController))) {
      return;
    }
    await _savePlaybackStateSnapshot();
  }

  Future<void> _saveCurrentProgress({bool immediate = false}) async {
    if (_currentItem == null || _progressTracker == null) return;

    if (immediate) {
      await _progressTracker!.saveProgressImmediately(
        _currentItem!.id,
        _position,
      );
    } else {
      await _progressTracker!.saveProgress(_currentItem!.id, _position);
    }
  }

  /// 释放控制器
  ///
  /// 非阻塞释放：同步移除 listener + 摘除引用，pause 与 dispose 在后台执行，
  /// 不阻塞 play() 后续流程。仅在 service.dispose() 时需要等待完成。
  Future<void> _disposeController({bool awaitCompletion = false}) async {
    final controller = _controller;
    final materializedLease = _currentMaterializedPlaybackLease;
    final bilibiliPlayback = _currentBilibiliPlayback;
    _currentMaterializedPlaybackLease = null;
    _currentBilibiliPlayback = null;
    _requestedBilibiliVideoTrackEnabled = null;
    _bilibiliVideoTrackPolicyRevision++;
    if (controller != null) {
      _invalidatePlaybackSpeedCommands();
      _logPlaybackEvent(
        'disposing controller',
        data: <String, Object?>{
          'itemId': _currentItem?.id,
          'positionMs': _position.inMilliseconds,
        },
      );
      final bool shouldDisposeController = _serviceOwnsController;
      _detachNativePositionStream(controller);
      _controller = null;
      _serviceOwnsController = false;
      _controllerCreatedWithoutVisiblePlaybackPage = false;

      if (awaitCompletion) {
        await _detachController(
          controller,
          disposeController: shouldDisposeController,
          pauseIfPlaying: true,
        );
        await _releasePlaybackResources(
          materializedLease: materializedLease,
          bilibiliPlayback: bilibiliPlayback,
        );
      } else {
        // play() 路径：非阻塞释放，不等待 pause/dispose 完成
        // listener 移除是同步的，防止后台 dispose 触发回调
        try {
          controller.removeListener(_onControllerUpdate);
        } catch (_) {}
        // pause fire-and-forget：native 层立即生效，不等待 platform channel 确认
        if (shouldDisposeController) {
          try {
            if (controller.value.isInitialized && controller.value.isPlaying) {
              unawaited(controller.pause());
            }
          } catch (_) {}
          // dispose 后台执行，不阻塞新控制器初始化
          // 通过 _disposingControllers 追踪，防止泄漏
          _disposingControllers.add(controller);
          final release = _disposeTrackedController(controller).whenComplete(
            () {
              _disposingControllers.remove(controller);
              unawaited(
                _releasePlaybackResources(
                  materializedLease: materializedLease,
                  bilibiliPlayback: bilibiliPlayback,
                ),
              );
            },
          );
          unawaited(release);
          // 超过上限时，日志告警（所有控制器已在后台 dispose 中，无需额外操作）
          if (_disposingControllers.length > _maxDisposingControllers) {
            _logPlaybackEvent(
              'disposing controllers exceeded limit',
              data: {'count': _disposingControllers.length},
            );
          }
        } else {
          // 非自有控制器：仅 pause（如果需要），不 dispose
          try {
            if (controller.value.isInitialized && controller.value.isPlaying) {
              unawaited(controller.pause());
            }
          } catch (_) {}
          await _releasePlaybackResources(
            materializedLease: materializedLease,
            bilibiliPlayback: bilibiliPlayback,
          );
        }
      }
    } else {
      await _releasePlaybackResources(
        materializedLease: materializedLease,
        bilibiliPlayback: bilibiliPlayback,
      );
    }
  }

  Future<void> _releasePlaybackResources({
    MaterializedMediaLease? materializedLease,
    BilibiliPreparedPlayback? bilibiliPlayback,
  }) async {
    await materializedLease?.release();
    if (bilibiliPlayback != null) {
      await _bilibiliStreamingService?.releasePlayback(bilibiliPlayback);
    }
  }

  @override
  void dispose() {
    unawaited(persistCurrentProgress());
    _playbackPageOwners.clear();
    _miniPlaybackCardOwners.clear();
    _mediaNotificationVisible = false;
    _syncBilibiliCachePolicy();
    _seekPersistTimer?.cancel();
    _seekPersistTimer = null;
    _seekVerificationTimer?.cancel();
    _seekVerificationTimer = null;
    _stopBackgroundMediaSync();
    _stopProgressTracking();
    _cancelNativePositionStream();
    unawaited(_disposeController(awaitCompletion: true));
    unawaited(_disposePreloadedController());
    // 等待所有后台 dispose 完成
    for (final c in _disposingControllers) {
      unawaited(c.dispose());
    }
    _disposingControllers.clear();
    AppWakelockCoordinator.setActive(
      AppWakelockCoordinator.mediaPlaybackReason,
      false,
    );
    super.dispose();
  }

  Duration _readBufferedPosition(VideoPlayerController controller) {
    final ranges = controller.value.buffered;
    if (ranges.isEmpty) return Duration.zero;
    Duration maxEnd = Duration.zero;
    for (final range in ranges) {
      if (range.end > maxEnd) {
        maxEnd = range.end;
      }
    }
    return maxEnd;
  }

  /// 保存播放状态快照
  Future<void> _savePlaybackStateSnapshot() async {
    if (_progressTracker == null) return;

    try {
      final snapshot = PlaybackStateSnapshot(
        currentItemId: _currentItem?.id,
        positionMs: _position.inMilliseconds,
        wasPlaying: _state == PlaybackState.playing,
        playlistFolderId: _currentItem?.parentId,
      );

      await _progressTracker!.savePlaybackState(snapshot);
    } catch (e) {
      debugPrint('MediaPlaybackService: 保存播放状态快照失败 $e');
    }
  }

  void _scheduleSeekVerification({
    required Duration expectedPosition,
    required String source,
    required VideoPlayerController controller,
    required String itemId,
    required int requestId,
  }) {
    _seekVerificationTimer?.cancel();
    _seekVerificationTimer = Timer(_controllerSeekVerificationDelay, () {
      unawaited(
        _verifySeekResult(
          expectedPosition: expectedPosition,
          source: source,
          controller: controller,
          itemId: itemId,
          requestId: requestId,
          retryOnDrift: true,
        ).then((confirmed) {
          if (confirmed ||
              requestId != _seekRequestId ||
              !_isCurrentControllerSession(controller, itemId)) {
            return;
          }
          _seekVerificationTimer = Timer(
            _controllerSeekVerificationFollowUpDelay,
            () => unawaited(
              _verifySeekResult(
                expectedPosition: expectedPosition,
                source: source,
                controller: controller,
                itemId: itemId,
                requestId: requestId,
                retryOnDrift: false,
              ),
            ),
          );
        }),
      );
    });
  }

  Future<bool> _verifySeekResult({
    required Duration expectedPosition,
    required String source,
    required VideoPlayerController controller,
    required String itemId,
    required int requestId,
    required bool retryOnDrift,
  }) {
    return _verifySeekResultImpl(
      expectedPosition: expectedPosition,
      source: source,
      controller: controller,
      itemId: itemId,
      requestId: requestId,
      retryOnDrift: retryOnDrift,
    );
  }

  Future<bool> _verifySeekResultImpl({
    required Duration expectedPosition,
    required String source,
    required VideoPlayerController controller,
    required String itemId,
    required int requestId,
    required bool retryOnDrift,
  }) async {
    if (requestId != _seekRequestId ||
        !_isCurrentControllerSession(controller, itemId) ||
        !controller.value.isInitialized) {
      _logPlaybackEvent(
        'seek verification skipped',
        data: <String, Object?>{
          'source': source,
          'reason': 'controller_or_request_replaced',
        },
      );
      return true;
    }

    Duration actualPosition;
    try {
      actualPosition = await controller.position ?? controller.value.position;
    } catch (_) {
      actualPosition = controller.value.position;
    }
    if (requestId != _seekRequestId ||
        !_isCurrentControllerSession(controller, itemId)) {
      return true;
    }

    final deltaMs =
        (actualPosition.inMilliseconds - expectedPosition.inMilliseconds).abs();
    final seekAgeMs = _lastSeekRequestedAt == null
        ? 0
        : DateTime.now().difference(_lastSeekRequestedAt!).inMilliseconds;
    final allowedForwardMs = _state == PlaybackState.playing
        ? seekAgeMs + _seekVerificationToleranceMs
        : _seekVerificationToleranceMs;
    final signedDeltaMs =
        actualPosition.inMilliseconds - expectedPosition.inMilliseconds;
    final confirmed =
        signedDeltaMs >= -_seekVerificationToleranceMs &&
        signedDeltaMs <= allowedForwardMs;
    if (!confirmed) {
      _logPlaybackEvent(
        'seek verification drift detected',
        data: <String, Object?>{
          'source': source,
          'expectedMs': expectedPosition.inMilliseconds,
          'actualMs': actualPosition.inMilliseconds,
          'deltaMs': deltaMs,
          'lastSeekSource': _lastSeekSource,
          'lastRequestedMs': _lastRequestedSeekPosition?.inMilliseconds,
          'lastSeekAgeMs': _lastSeekRequestedAt == null
              ? null
              : DateTime.now().difference(_lastSeekRequestedAt!).inMilliseconds,
          'willRecheck': retryOnDrift,
        },
      );
      if (retryOnDrift) {
        // A local ALAC seek may acknowledge before its native position event.
        // Wait for the follow-up read instead of issuing a duplicate seek into
        // the same decoder while it is still re-anchoring its audio clock.
        return false;
      }

      // The second direct read is authoritative: if the native backend still
      // rejected the seek, expose the real position instead of persisting the
      // optimistic target forever.
      _clearInitialPositionGuard();
      _position = actualPosition;
      _bufferedPosition = _readBufferedPosition(controller);
      _resetPlaybackTimeline(
        actualPosition,
        running: _state == PlaybackState.playing,
      );
      _updateCurrentSubtitle();
      notifyListeners();
      return false;
    }

    _logPlaybackEvent(
      'seek verification passed',
      data: <String, Object?>{
        'source': source,
        'expectedMs': expectedPosition.inMilliseconds,
        'actualMs': actualPosition.inMilliseconds,
        'lastRequestedMs': _lastRequestedSeekPosition?.inMilliseconds,
      },
    );
    _clearInitialPositionGuard();
    if (actualPosition != _position) {
      _position = actualPosition;
      _bufferedPosition = _readBufferedPosition(controller);
      _resetPlaybackTimeline(
        actualPosition,
        running: _state == PlaybackState.playing,
      );
      _updateCurrentSubtitle();
      notifyListeners();
    }
    return true;
  }

  double get _targetControllerVolume => _isMuted ? 0.0 : _volume;

  bool _controllerVolumeMatchesDesired(VideoPlayerController controller) {
    return (controller.value.volume - _targetControllerVolume).abs() < 0.001;
  }

  Future<void> _applyMuteStateToController({String? reason}) async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      return;
    }
    if (_controllerVolumeMatchesDesired(controller)) {
      return;
    }
    try {
      await controller.setVolume(_targetControllerVolume);
    } catch (e) {
      debugPrint(
        'MediaPlaybackService: 应用静音状态失败'
        '${reason == null ? '' : ' ($reason)'} $e',
      );
    }
  }

  Future<void> _restorePersistedMuteState({bool notify = true}) async {
    bool persistedMute = SettingsService().globalMute;
    try {
      final prefs = await SharedPreferences.getInstance();
      persistedMute = prefs.getBool(_globalMutePrefsKey) ?? persistedMute;
    } catch (e) {
      debugPrint('MediaPlaybackService: 读取静音状态失败 $e');
    }
    _isMuted = persistedMute;
    SettingsService().globalMute = persistedMute;
    if (notify) {
      notifyListeners();
    }
  }

  Future<void> _persistMuteState() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_globalMutePrefsKey, _isMuted);
      SettingsService().globalMute = _isMuted;
    } catch (e) {
      debugPrint('MediaPlaybackService: 保存静音状态失败 $e');
    }
  }
}
