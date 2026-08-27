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
import '../models/managed_subtitle_asset.dart';
import '../models/subtitle_model.dart';
import '../platform/windows_video_player_media_kit.dart';
import 'playlist_manager.dart';
import 'progress_tracker.dart';
import 'app_wakelock_coordinator.dart';
import 'audio_playback_compatibility_service.dart';
import 'playback_timeline_clock.dart';
import '../services/embedded_subtitle_service.dart';
import '../services/library_service.dart';
import '../services/settings_service.dart';
import '../services/task_subtitle_storage_service.dart';
import '../services/subtitle_timeline_resolver.dart';
import '../services/subtitle_discovery_service.dart';
import '../utils/pgs_parser.dart';
import '../utils/subtitle_converter.dart';
import '../utils/subtitle_parser.dart';
import '../utils/youtube_auto_caption_normalizer.dart';
import '../utils/subtitle_file_matcher.dart';

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

  /// 后台 dispose 完成后自动移除的 Future 数量上限
  static const int _maxDisposingControllers = 3;

  // 是否启用自动播放下一集（横屏播放页可以禁用）
  bool _autoPlayNextEnabled = true;
  bool get autoPlayNextEnabled => _autoPlayNextEnabled;
  set autoPlayNextEnabled(bool value) {
    if (_autoPlayNextEnabled == value) return;
    _autoPlayNextEnabled = value;
    notifyListeners();
  }

  static const Duration _controllerSeekVerificationDelay = Duration(
    milliseconds: 180,
  );
  static const Duration _controllerSeekVerificationFollowUpDelay = Duration(
    milliseconds: 650,
  );
  static const int _seekVerificationToleranceMs = 450;
  static const Duration _backgroundMediaSyncInterval = Duration(
    milliseconds: 900,
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
        if (controller.value.isInitialized && controller.value.isPlaying) {
          await controller.pause();
        }
      } catch (_) {}
    }

    if (!disposeController) {
      return;
    }

    try {
      await controller.dispose();
    } catch (_) {}
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
        // the native player and the coarse background clock keep advancing.
        // Re-anchor the presentation clock before restarting the ticker so
        // progress, subtitles and danmaku all resume from the same position.
        _stopRealtimeSyncLoop();
        _updatePosition();
        _resetPlaybackTimeline(_position, running: _shouldTimelineRun());
        _startRealtimeSyncLoop();
      } else {
        _startRealtimeSyncLoop();
      }
    }
  }

  // Getters
  PlaybackState get state => _state;
  VideoItem? get currentItem => _currentItem;
  Duration get position => _position;
  Duration get duration => _duration;
  Duration get bufferedPosition => _bufferedPosition;
  bool get isPlaying => _state == PlaybackState.playing;
  bool get isSourceMissing => _isSourceMissing;
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
  }) async {
    _playlistManager = playlistManager;
    _progressTracker = progressTracker;
    _libraryService = libraryService;
    _embeddedSubtitleService = embeddedSubtitleService;
    await _restorePersistedMuteState(notify: false);
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
  }) {
    _subtitles = List<SubtitleItem>.unmodifiable(primary);
    _secondarySubtitles = List<SubtitleItem>.unmodifiable(secondary);
    _subtitlePaths = List<String>.unmodifiable(paths);
    _subtitleRevision++;
    _subtitleTimeline = SubtitleTimelineResolver(_subtitles);
    _lastSubtitleIndex = 0;
    _currentSubtitle = null;
    _updateCurrentSubtitle();
    notifyListeners();
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
      final scannedPath = await _scanForExternalSubtitlePath(item.path);
      if (scannedPath != null) {
        paths.add(scannedPath);
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

  Future<String?> _scanForExternalSubtitlePath(String videoPath) async {
    try {
      final settings = SettingsService();
      final entries = await const SubtitleDiscoveryService().scanVideoDirectory(
        videoPath: videoPath,
        rules: SubtitleScanRules(
          prefixMatchMode: settings.desktopSubtitlePrefixMatchMode,
          caseSensitive: settings.desktopSubtitleScanCaseSensitive,
        ),
      );
      return entries.isEmpty ? null : entries.first.path;
    } catch (e) {
      developer.log('Scan external subtitles failed', error: e);
      return null;
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
    String primaryPath,
  ) async {
    final library = _libraryService;
    if (library == null) return;
    try {
      final settings = SettingsService();
      final existingSecondary = await _normalizeExistingSubtitlePath(
        item.secondarySubtitlePath,
      );
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
      await _persistResolvedSubtitlePath(item, paths.first);
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
    _serviceOwnsController = false;
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

      Duration? nativePosition;
      final hasNativePresentationClock =
          _nativePositionPlayerId != null && _nativeRateSubscription != null;
      if (!hasNativePresentationClock) {
        try {
          nativePosition = await controller.position;
        } catch (_) {}
        if (requestId != _playbackSpeedRequestId || controller != _controller) {
          return;
        }
      }

      _pendingPlaybackSpeed = null;
      _playbackSpeed = speed;
      _confirmedPlaybackSpeed = speed;
      _nativePresentationPlaybackSpeed = speed;
      if (hasNativePresentationClock && _timelineClock.isInitialized) {
        // The native sample already updated the shared presentation slope.
        // Re-anchoring here would make progress, subtitles and danmaku jump.
        _timelineClock.setRate(speed);
      } else {
        _resetPlaybackTimeline(
          nativePosition ?? controller.value.position,
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
      _timelineClock.setRunning(false);
    }
  }

  /// 更新媒体元数据
  Future<void> updateMetadata(VideoItem item) async {
    _currentItem = item;
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
    final int playRequestId = ++_playRequestId;
    _seekRequestId++;
    _pendingSeekRequestId = null;
    _seekVerificationTimer?.cancel();
    _seekVerificationTimer = null;
    VideoPlayerController? requestController;
    try {
      _hasPlaybackCompleted = false;

      // 修复：如果startPosition为null且当前位置已在末尾（播放完成状态），
      // 则从头开始播放，避免无法跳转上一集或进入已完成的视频
      if (startPosition == null &&
          _duration > Duration.zero &&
          _position >= _duration - const Duration(milliseconds: 500)) {
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

      if (!forceRecreate && _controllerIsReusableForItem(item)) {
        final controller = _controller!;
        _currentItem = item;
        _preloadTriggered = false;
        _duration = controller.value.duration;
        _position = controller.value.position;
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
            _duration > Duration.zero &&
            _position >= _duration - const Duration(milliseconds: 500)) {
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

        _resetPlaybackTimeline(
          _position,
          running: autoPlay && controller.value.isPlaying,
        );

        if (autoPlay) {
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
          _position = controller.value.position;
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

        _lastControllerIsPlaying = controller.value.isPlaying;
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
      if (_currentItem != null || _controller != null) {
        clearSubtitleState();
        // 非阻塞保存进度：ProgressTracker 内存写入同步，落盘异步
        unawaited(_saveCurrentProgress());
        _seekPersistTimer?.cancel();
        _seekPersistTimer = null;
        // 非阻塞释放旧控制器：不等待 pause/dispose 完成
        unawaited(_disposeController());
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
      if (loadingPosition < Duration.zero ||
          (loadingDuration > Duration.zero &&
              loadingPosition >=
                  loadingDuration - const Duration(milliseconds: 500))) {
        loadingPosition = Duration.zero;
      }

      _currentItem = item;
      _isSourceMissing = false;
      _position = loadingPosition;
      _duration = loadingDuration;
      _bufferedPosition = Duration.zero;
      _resetPlaybackTimeline(loadingPosition, running: false);
      _state = PlaybackState.loading;
      _syncWakelockWithState();
      notifyListeners();

      // Keep independent page content responsive while the native player is
      // handing off. Subtitle parsing and compatible-path resolution do not
      // require a controller, so overlap them with native disposal instead of
      // placing them behind the slowest part of media initialization.
      unawaited(_refreshKnownSubtitlesForCurrentItem(item));
      final sourceFile = File(item.path);
      final Future<File?> playbackFileFuture = () async {
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
      if (!forceRecreate && _tryUsePreloadedController(item)) {
        final controller = _controller!;
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
        Duration initialPosition = startPosition ?? Duration.zero;
        if (startPosition == null && _progressTracker != null) {
          final savedProgress = _progressTracker!.getProgress(item.id);
          if (savedProgress != null) {
            initialPosition = savedProgress;
          }
        }
        if (_duration > Duration.zero &&
            initialPosition >= _duration - const Duration(milliseconds: 500)) {
          initialPosition = Duration.zero;
        }
        if (initialPosition > Duration.zero &&
            (_duration <= Duration.zero || initialPosition < _duration)) {
          await controller.seekTo(initialPosition);
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
          running: autoPlay && controller.value.isPlaying,
        );

        if (autoPlay) {
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
          _position = controller.value.position;
        }

        _lastControllerIsPlaying = controller.value.isPlaying;
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
      final playbackFile = await playbackFileFuture;
      if (playbackFile == null) {
        if (!_isCurrentPlayRequest(playRequestId, item.id)) {
          return;
        }
        // A missing source is a recoverable media-session state, not a fatal
        // playback error. Keep the item/timeline/playlist active so every
        // playback page can render its normal controls and navigate past it.
        _isSourceMissing = true;
        _state = PlaybackState.paused;
        _stopProgressTracking();
        _syncWakelockWithState();
        notifyListeners();
        unawaited(_savePlaybackStateSnapshot());
        unawaited(_refreshSubtitlesForCurrentItem(item));
        debugPrint('MediaPlaybackService: 文件不存在 ${item.path}');
        return;
      }
      if (playRequestId != _playRequestId) {
        return;
      }

      if (!_isCurrentPlayRequest(playRequestId, item.id)) {
        return;
      }
      final controller = VideoPlayerController.file(
        playbackFile,
        videoPlayerOptions: buildVideoPlayerOptions(),
      );
      requestController = controller;
      if (playRequestId != _playRequestId) {
        await _detachController(
          controller,
          disposeController: true,
          pauseIfPlaying: true,
        );
        return;
      }

      // 初始化控制器
      await controller.initialize();

      if (playRequestId != _playRequestId) {
        await _detachController(
          controller,
          disposeController: true,
          pauseIfPlaying: true,
        );
        return;
      }

      _controller = controller;
      _serviceOwnsController = true;
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
      controller.addListener(_onControllerUpdate);

      // 确定起始位置
      Duration initialPosition = startPosition ?? Duration.zero;

      // 如果没有指定起始位置，尝试从进度追踪器获取
      if (startPosition == null && _progressTracker != null) {
        final savedProgress = _progressTracker!.getProgress(item.id);
        if (savedProgress != null) {
          initialPosition = savedProgress;
        }
      }

      // 修复：如果保存的进度在末尾（表示已播放完成），则从头开始播放
      // 避免无法跳转上一集或进入已完成的视频
      // 注意：只有当_duration > 0时才检查，避免误判
      if (_duration > Duration.zero &&
          initialPosition >= _duration - const Duration(milliseconds: 500)) {
        _logPlaybackEvent(
          'reset to beginning due to completion',
          data: <String, Object?>{
            'itemId': item.id,
            'savedProgressMs': initialPosition.inMilliseconds,
          },
        );
        initialPosition = Duration.zero;
      }

      // 跳转到起始位置
      // 注意：即使initialPosition为0，也需要seekTo，确保控制器从开头开始播放
      // 避免控制器停留在末尾导致立即触发播放完成
      if (initialPosition < _duration) {
        await controller.seekTo(initialPosition);
        if (!_isCurrentPlayRequest(
          playRequestId,
          item.id,
          controller: controller,
        )) {
          return;
        }
        _position = initialPosition;
        _bufferedPosition = _readBufferedPosition(controller);
      }

      _resetPlaybackTimeline(
        _position,
        running: autoPlay && controller.value.isPlaying,
      );

      if (autoPlay) {
        // 乐观更新：立即设置状态为播放中
        _state = PlaybackState.playing;
        _syncWakelockWithState();
        notifyListeners();

        // 启动进度追踪定时器
        _startProgressTracking();

        // 开始播放
        await controller.play();
        if (!_isCurrentPlayRequest(
          playRequestId,
          item.id,
          controller: controller,
        )) {
          return;
        }
      } else {
        // 保持暂停状态
        _state = PlaybackState.paused;
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
      await _savePlaybackStateSnapshot();
      if (!_isCurrentPlayRequest(
        playRequestId,
        item.id,
        controller: controller,
      )) {
        return;
      }

      if (!autoPlay) {
        notifyListeners();
      }

      _refreshSubtitlesForCurrentItem(item);
    } catch (e) {
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
      final bool sourceMissing = !kIsWeb && !await File(item.path).exists();
      _isSourceMissing = sourceMissing;
      _state = sourceMissing ? PlaybackState.paused : PlaybackState.error;
      _syncWakelockWithState();
      notifyListeners();
      if (sourceMissing) {
        unawaited(_refreshSubtitlesForCurrentItem(item));
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
    try {
      if (controller.value.isInitialized) {
        position = controller.value.position;
        autoPlay = controller.value.isPlaying;
      }
    } catch (_) {}

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
    _lastControllerIsPlaying = null;

    _state = PlaybackState.idle;
    _isSourceMissing = false;
    _currentItem = null;
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
    _hasPlaybackCompleted = false;
    _stopProgressTracking();
    unawaited(_disposeController());
    _isSourceMissing = true;
    _state = PlaybackState.paused;
    _setPlaybackTimelineRunning(false);
    _syncWakelockWithState();
    notifyListeners();
    unawaited(_savePlaybackStateSnapshot());
    unawaited(_refreshSubtitlesForCurrentItem(item));
  }

  /// 暂停播放
  Future<void> pause() async {
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
      _syncWakelockWithState();
      notifyListeners();

      // 停止进度追踪定时器
      _stopProgressTracking();

      await controller.pause();
      if (!_isCurrentPlayRequest(requestId, itemId, controller: controller)) {
        return;
      }

      // 更新最终位置
      if (controller.value.isInitialized) {
        _position = controller.value.position;
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

    if (_state != PlaybackState.paused) return;
    final controller = _controller;
    final itemId = _currentItem?.id;
    if (controller == null || itemId == null) return;
    final requestId = ++_playRequestId;
    _seekRequestId++;
    _pendingSeekRequestId = null;

    try {
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
      _startProgressTracking();

      await controller.play();
      if (!_isCurrentPlayRequest(requestId, itemId, controller: controller)) {
        return;
      }

      if (controller.value.isInitialized) {
        _position = controller.value.position;
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
  void updatePlaybackStateFromController() {
    if (_controller == null || !_controller!.value.isInitialized) return;

    // 直接从 controller 读取实际播放状态
    final controllerIsPlaying = _controller!.value.isPlaying;
    if (controllerIsPlaying) {
      _preservePlayingStateAfterSeek = false;
    } else if (_pendingSeekRequestId != null ||
        _preservePlayingStateAfterSeek) {
      return;
    }
    final controllerPosition = _controller!.value.position;
    final controllerDuration = _controller!.value.duration;
    final controllerBufferedPosition = _readBufferedPosition(_controller!);
    _capturePlaybackSpeedFromController(_controller!);
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
      return;
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
  }

  /// 停止播放
  Future<void> stop() async {
    final stopRequestId = ++_playRequestId;
    _seekRequestId++;
    _pendingSeekRequestId = null;
    _preservePlayingStateAfterSeek = false;
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
    await _disposeController();
    unawaited(_disposePreloadedController());
    _preloadTriggered = false;

    _state = PlaybackState.idle;
    _isSourceMissing = false;
    _syncWakelockWithState();
    clearSubtitleState();
    _currentItem = null;
    _position = Duration.zero;
    _duration = Duration.zero;
    _bufferedPosition = Duration.zero;
    _resetPlaybackTimeline(Duration.zero, running: false, rate: 1.0);

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

      await controller.seekTo(clampedPosition);
      if (requestId != _seekRequestId ||
          playRequestId != _playRequestId ||
          !_isCurrentControllerSession(controller, itemId)) {
        return;
      }

      final actualPosition = controller.value.position;
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
      debugPrint('MediaPlaybackService: 跳转失败 $e');
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
  Future<void> playNext({bool autoPlay = true}) async {
    _logPlaybackEvent(
      'skip to next requested',
      data: <String, Object?>{'itemId': _currentItem?.id, 'autoPlay': autoPlay},
    );
    // 确保播放列表是最新的
    _playlistManager?.reloadPlaylist();

    final nextItem = _playlistManager?.getNext();
    if (nextItem != null) {
      await _playPlaylistItem(nextItem, autoPlay: autoPlay);
    }
  }

  /// 播放上一个媒体
  Future<void> playPrevious({bool autoPlay = true}) async {
    _logPlaybackEvent(
      'skip to previous requested',
      data: <String, Object?>{'itemId': _currentItem?.id, 'autoPlay': autoPlay},
    );
    // 确保播放列表是最新的
    _playlistManager?.reloadPlaylist();

    final previousItem = _playlistManager?.getPrevious();
    if (previousItem != null) {
      await _playPlaylistItem(previousItem, autoPlay: autoPlay);
    }
  }

  /// 播放列表切换统一入口：切换前立即保存当前媒体进度，
  /// 避免新的保存请求覆盖上一媒体尚未落库的防抖进度。
  Future<void> playPlaylistItem(
    VideoItem item, {
    bool autoPlay = true,
    Duration? startPosition,
  }) async {
    await _playPlaylistItem(
      item,
      autoPlay: autoPlay,
      startPosition: startPosition,
    );
  }

  Future<void> _playPlaylistItem(
    VideoItem item, {
    bool autoPlay = true,
    Duration? startPosition,
  }) async {
    await _saveCurrentProgress(immediate: true);

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

    await play(item, autoPlay: autoPlay, startPosition: startPosition);
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

    final currentPos = controller.value.position;
    final duration = controller.value.duration;
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
    if (_controller == null || !_controller!.value.isInitialized) return;

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
      updatePlaybackStateFromController();
    } else if (playbackSpeedChanged) {
      notifyListeners();
    }
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
    _isHandlingPlaybackCompletion = true;
    unawaited(_handlePlaybackCompleted());
  }

  Future<void> _handlePlaybackCompleted() async {
    try {
      _preservePlayingStateAfterSeek = false;
      if (_controller != null && _controller!.value.isInitialized) {
        _position = _controller!.value.position;
        _duration = _controller!.value.duration;
        _bufferedPosition = _readBufferedPosition(_controller!);
      }

      // 先保存当前进度（在末尾的位置）
      await _saveCurrentProgress(immediate: true);

      // 修复：播放完成后，将进度重置为0并保存
      // 这样用户下次播放时会从开头开始，避免无法跳转上一集或进入已完成的视频
      if (_currentItem != null && _progressTracker != null) {
        await _progressTracker!.saveProgressImmediately(
          _currentItem!.id,
          Duration.zero,
        );
      }

      final settings = SettingsService();
      final shouldAutoPlay =
          _autoPlayNextEnabled && settings.autoPlayOnCompletion;
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
      final VideoItem? targetItem =
          _playlistManager?.getNext() ?? _playlistManager?.getFirst();
      if (targetItem == null) {
        await stop();
        return;
      }

      await _playPlaylistItem(
        targetItem,
        autoPlay: true,
        startPosition:
            settings.autoPlayOnCompletionFromStart ||
                targetItem.id == _currentItem?.id
            ? Duration.zero
            : null,
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

    final nextItem = _playlistManager?.getNext();
    if (nextItem == null) return;

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
        await controller.initialize();
        // 竞态检查：预加载期间用户可能已切换视频
        if (_preloadedItemId != nextItem.id ||
            _preloadedRequestId != _playRequestId) {
          unawaited(controller.dispose());
          return;
        }
        _preloadedController = controller;
        _logPlaybackEvent(
          'preload next video completed',
          data: {'itemId': nextItem.id},
        );
      } catch (e) {
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
        try {
          await controller.dispose();
        } catch (_) {}
      } else {
        unawaited(controller.dispose());
      }
    }
  }

  /// 尝试使用预加载的控制器，返回 true 表示热替换成功
  bool _tryUsePreloadedController(VideoItem item) {
    if (_preloadedController == null || _preloadedItemId != item.id) {
      return false;
    }
    final controller = _preloadedController!;
    _preloadedController = null;
    _preloadedItemId = null;

    try {
      if (!controller.value.isInitialized) {
        unawaited(controller.dispose());
        return false;
      }
    } catch (_) {
      unawaited(controller.dispose());
      return false;
    }

    _controller = controller;
    _serviceOwnsController = true;
    _attachNativePositionStream(controller);
    controller.addListener(_onControllerUpdate);
    _logPlaybackEvent(
      'hot-swapped preloaded controller',
      data: {'itemId': item.id},
    );
    return true;
  }

  /// 保存当前播放进度
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

      if (awaitCompletion) {
        await _detachController(
          controller,
          disposeController: shouldDisposeController,
          pauseIfPlaying: true,
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
          unawaited(
            controller.dispose().whenComplete(() {
              _disposingControllers.remove(controller);
            }),
          );
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
        }
      }
    }
  }

  @override
  void dispose() {
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
  }) {
    _seekVerificationTimer?.cancel();
    _seekVerificationTimer = Timer(_controllerSeekVerificationDelay, () {
      _verifySeekResult(expectedPosition: expectedPosition, source: source);
      _seekVerificationTimer = Timer(
        _controllerSeekVerificationFollowUpDelay,
        () => _verifySeekResult(
          expectedPosition: expectedPosition,
          source: source,
        ),
      );
    });
  }

  void _verifySeekResult({
    required Duration expectedPosition,
    required String source,
  }) {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      _logPlaybackEvent(
        'seek verification skipped',
        data: <String, Object?>{
          'source': source,
          'reason': 'controller_unavailable',
        },
      );
      return;
    }
    final actualPosition = controller.value.position;
    final deltaMs =
        (actualPosition.inMilliseconds - expectedPosition.inMilliseconds).abs();
    if (deltaMs > _seekVerificationToleranceMs) {
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
        },
      );
    } else {
      _logPlaybackEvent(
        'seek verification passed',
        data: <String, Object?>{
          'source': source,
          'expectedMs': expectedPosition.inMilliseconds,
          'actualMs': actualPosition.inMilliseconds,
          'lastRequestedMs': _lastRequestedSeekPosition?.inMilliseconds,
        },
      );
    }
    if (actualPosition != _position) {
      _position = actualPosition;
      _bufferedPosition = _readBufferedPosition(controller);
      _updateCurrentSubtitle();
      notifyListeners();
    }
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
