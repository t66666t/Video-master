import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
import '../models/video_item.dart';
import '../models/subtitle_model.dart';
import 'playlist_manager.dart';
import 'progress_tracker.dart';
import 'app_wakelock_coordinator.dart';
import '../services/embedded_subtitle_service.dart';
import '../services/library_service.dart';
import '../services/settings_service.dart';
import '../services/subtitle_timeline_resolver.dart';
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
  VideoPlayerController? _controller;
  bool _serviceOwnsController = false;

  // 字幕相关
  List<SubtitleItem> _subtitles = [];
  List<SubtitleItem> _secondarySubtitles = [];
  List<String> _subtitlePaths = [];
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

  Timer? _seekPersistTimer;
  Timer? _seekVerificationTimer;
  int _seekRequestId = 0;
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

  Future<void> _detachController(
    VideoPlayerController controller, {
    required bool disposeController,
    bool pauseIfPlaying = false,
  }) async {
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
        _startRealtimeSyncLoop();
        _updatePosition();
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
  bool get isMuted => _isMuted;
  double get volume => _volume;
  VideoPlayerController? get controller => _controller;
  List<SubtitleItem> get subtitles => _subtitles;
  List<SubtitleItem> get secondarySubtitles => _secondarySubtitles;
  List<String> get subtitlePaths => _subtitlePaths;
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
    _subtitles = primary;
    _secondarySubtitles = secondary;
    _subtitlePaths = List<String>.from(paths);
    _subtitleTimeline = SubtitleTimelineResolver(_subtitles);
    _lastSubtitleIndex = 0;
    _currentSubtitle = null;
    _updateCurrentSubtitle();
    notifyListeners();
  }

  void clearSubtitleState() {
    setSubtitleState(paths: const [], primary: const [], secondary: const []);
    // Clear the subtitle file cache to free memory when switching videos.
    _subtitleCache.clear();
  }

  String? _resolveFirstAssociatedSubtitlePath(VideoItem item) {
    final additional = item.additionalSubtitles;
    if (additional == null || additional.isEmpty) return null;
    for (final path in additional.values) {
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

    final associated = item.additionalSubtitles;
    if (associated != null && associated.isNotEmpty) {
      for (final path in associated.values) {
        if (path.isEmpty) continue;
        expectedPaths.add(p.normalize(path));
      }
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

  Future<String?> _scanForExternalSubtitlePath(String videoPath) async {
    try {
      final videoFile = File(videoPath);
      if (!await videoFile.exists()) return null;

      final dir = videoFile.parent;
      if (!await dir.exists()) return null;

      final videoName = p.basenameWithoutExtension(videoPath);
      final extractedPrefix = '$videoName.stream_';
      final List<File> subtitleFiles = <File>[];

      await for (final entity in dir.list()) {
        if (entity is! File) continue;
        final name = p.basename(entity.path);
        if (!name.startsWith(videoName)) continue;
        if (name.startsWith(extractedPrefix)) continue;

        final ext = p.extension(entity.path).toLowerCase();
        if (!<String>{
          '.srt',
          '.vtt',
          '.ass',
          '.ssa',
          '.sup',
          '.lrc',
          '.sub',
          '.idx',
          '.scc',
        }.contains(ext)) {
          continue;
        }
        subtitleFiles.add(entity);
      }

      if (subtitleFiles.isEmpty) return null;

      subtitleFiles.sort(
        (a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()),
      );
      return p.normalize(subtitleFiles.first.path);
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

      final dataRoot = await SettingsService().resolveLargeDataRootDir();
      final subDir = Directory(p.join(dataRoot.path, 'subtitles'));
      if (!await subDir.exists()) {
        await subDir.create(recursive: true);
      }

      final extractedPath = await embeddedService.extractSubtitle(
        item.path,
        track.index,
        subDir.path,
        codecName: track.codecName,
        videoId: item.id,
      );
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

    final primary = await _parseSubtitleFile(paths[0]);
    final secondary = paths.length > 1
        ? await _parseSubtitleFile(paths[1])
        : <SubtitleItem>[];
    if (requestId != _subtitleLoadRequestId) return;
    if (_currentItem?.id != item.id) return;

    setSubtitleState(paths: paths, primary: primary, secondary: secondary);
  }

  /// 设置外部控制器（用于UI创建的控制器移交给服务管理）
  Future<void> setController(VideoPlayerController controller) async {
    // 如果是同一个控制器，无需处理
    if (_controller == controller) return;

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
    _logPlaybackEvent(
      'controller attached',
      data: <String, Object?>{
        'initialized': controller.value.isInitialized,
        'isPlaying': controller.value.isPlaying,
      },
    );

    // 立即同步状态
    if (_controller!.value.isInitialized) {
      unawaited(_applyConfiguredPlaybackSpeed(_controller!));
      _duration = _controller!.value.duration;
      _position = _controller!.value.position;
      _bufferedPosition = _readBufferedPosition(_controller!);
      _state = _controller!.value.isPlaying
          ? PlaybackState.playing
          : PlaybackState.paused;
      _hasPlaybackCompleted =
          !_controller!.value.isPlaying &&
          _hasReachedPlaybackEnd(_position, _duration);
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
      return;
    }
    await controller.setPlaybackSpeed(targetSpeed);
  }

  /// 清除当前控制器引用（当UI销毁控制器时调用）
  void clearController() {
    if (_controller != null) {
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
      _controller = null;
      _serviceOwnsController = false;
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
  }) async {
    final int playRequestId = ++_playRequestId;
    try {
      _hasPlaybackCompleted = false;
      _logPlaybackEvent(
        'play requested',
        data: <String, Object?>{
          'itemId': item.id,
          'title': item.title,
          'autoPlay': autoPlay,
          'startPositionMs': startPosition?.inMilliseconds,
        },
      );

      if (_controllerIsReusableForItem(item)) {
        final controller = _controller!;
        _currentItem = item;
        _duration = controller.value.duration;
        _position = controller.value.position;
        _bufferedPosition = _readBufferedPosition(controller);
        _lastControllerIsPlaying = controller.value.isPlaying;

        await _applyConfiguredPlaybackSpeed(controller);
        await _applyMuteStateToController(reason: 'reuse existing controller');

        if (startPosition != null &&
            startPosition >= Duration.zero &&
            (_duration <= Duration.zero || startPosition < _duration)) {
          await seekTo(startPosition, source: 'play_same_item_reuse');
        }

        if (autoPlay) {
          _state = PlaybackState.playing;
          _syncWakelockWithState();
          notifyListeners();
          _startProgressTracking();
          if (!controller.value.isPlaying) {
            await controller.play();
          }
        } else {
          _state = PlaybackState.paused;
          _syncWakelockWithState();
          notifyListeners();
          _stopProgressTracking();
          if (controller.value.isPlaying) {
            await controller.pause();
          }
          _position = controller.value.position;
          _bufferedPosition = _readBufferedPosition(controller);
          await _saveCurrentProgress(immediate: true);
        }

        _lastControllerIsPlaying = controller.value.isPlaying;
        await _savePlaybackStateSnapshot();
        _refreshSubtitlesForCurrentItem(item);
        return;
      }

      // 如果正在播放其他媒体，或当前控制器已失效，先保存进度并停止
      if (_currentItem != null || _controller != null) {
        clearSubtitleState();
        await _saveCurrentProgress();
        _seekPersistTimer?.cancel();
        _seekPersistTimer = null;
        await _disposeController();
      }

      _currentItem = item;
      _state = PlaybackState.loading;
      _syncWakelockWithState();
      notifyListeners();

      if (_playlistManager != null) {
        final idx = _playlistManager!.indexOfItem(item.id);
        if (idx >= 0) {
          _playlistManager!.setCurrentIndex(idx);
        } else {
          _playlistManager!.loadFolderPlaylist(item.parentId, item.id);
        }
      }

      // 创建新的控制器
      final file = File(item.path);
      if (!await file.exists()) {
        _state = PlaybackState.error;
        notifyListeners();
        debugPrint('MediaPlaybackService: 文件不存在 ${item.path}');
        return;
      }
      if (playRequestId != _playRequestId) {
        return;
      }

      final controller = VideoPlayerController.file(
        file,
        videoPlayerOptions: buildVideoPlayerOptions(),
      );
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

      await _applyConfiguredPlaybackSpeed(controller);

      _duration = controller.value.duration;
      _bufferedPosition = _readBufferedPosition(controller);
      if (_progressTracker != null && _duration > Duration.zero) {
        await _progressTracker!.saveDurationImmediately(item.id, _duration);
      }

      // 设置音量和静音状态
      await controller.setVolume(_isMuted ? 0.0 : _volume);

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

      // 跳转到起始位置
      if (initialPosition > Duration.zero && initialPosition < _duration) {
        await controller.seekTo(initialPosition);
        _position = initialPosition;
        _bufferedPosition = _readBufferedPosition(controller);
      }

      if (autoPlay) {
        // 乐观更新：立即设置状态为播放中
        _state = PlaybackState.playing;
        _syncWakelockWithState();
        notifyListeners();

        // 启动进度追踪定时器
        _startProgressTracking();

        // 开始播放
        await controller.play();
      } else {
        // 保持暂停状态
        _state = PlaybackState.paused;
        _syncWakelockWithState();
        // 暂停时也应该保存一次初始状态
        await _saveCurrentProgress(immediate: true);
      }

      // 保存播放状态快照
      await _savePlaybackStateSnapshot();

      if (!autoPlay) {
        notifyListeners();
      }

      _refreshSubtitlesForCurrentItem(item);
    } catch (e) {
      debugPrint('MediaPlaybackService: 播放失败 $e');
      _state = PlaybackState.error;
      _syncWakelockWithState();
      notifyListeners();
    }
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
    _currentItem = null;
    _position = Duration.zero;
    _duration = Duration.zero;
    _bufferedPosition = Duration.zero;
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

  /// 暂停播放
  Future<void> pause() async {
    if (_state != PlaybackState.playing) return;

    try {
      _hasPlaybackCompleted = false;
      _logPlaybackEvent(
        'pause requested',
        data: <String, Object?>{
          'itemId': _currentItem?.id,
          'positionMs': _position.inMilliseconds,
        },
      );
      // 乐观更新：立即设置状态为暂停
      _state = PlaybackState.paused;
      _syncWakelockWithState();
      notifyListeners();

      // 停止进度追踪定时器
      _stopProgressTracking();

      await _controller?.pause();

      // 更新最终位置
      if (_controller != null && _controller!.value.isInitialized) {
        _position = _controller!.value.position;
        _bufferedPosition = _readBufferedPosition(_controller!);
      }

      // 暂停时立即保存进度
      await _saveCurrentProgress(immediate: true);

      // 保存播放状态快照
      await _savePlaybackStateSnapshot();

      notifyListeners();
    } catch (e) {
      debugPrint('MediaPlaybackService: 暂停失败 $e');
    }
  }

  /// 继续播放
  Future<void> resume() async {
    final currentItem = _currentItem;
    if (_hasPlaybackCompleted && currentItem != null) {
      _logPlaybackEvent(
        'resume requested after completion',
        data: <String, Object?>{'itemId': currentItem.id},
      );
      await play(currentItem, autoPlay: true, startPosition: Duration.zero);
      return;
    }

    if (_state != PlaybackState.paused) return;

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

      await _controller?.play();

      // 保存播放状态快照
      await _savePlaybackStateSnapshot();
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
    final controllerPosition = _controller!.value.position;
    final controllerDuration = _controller!.value.duration;
    final controllerBufferedPosition = _readBufferedPosition(_controller!);
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
      // 重新启动进度追踪定时器
      _startProgressTracking();
    } else {
      _state = PlaybackState.paused;
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
    }

    // 停止进度追踪
    _stopProgressTracking();
    _seekPersistTimer?.cancel();
    _seekPersistTimer = null;

    // 释放控制器
    await _disposeController();

    _state = PlaybackState.idle;
    _syncWakelockWithState();
    clearSubtitleState();
    _currentItem = null;
    _position = Duration.zero;
    _duration = Duration.zero;
    _bufferedPosition = Duration.zero;

    notifyListeners();
  }

  /// 跳转到指定位置
  Future<void> seekTo(Duration position, {String source = 'ui'}) async {
    if (_controller == null || !_controller!.value.isInitialized) return;

    try {
      final controllerDuration = _controller!.value.duration;
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

      _position = clampedPosition;
      notifyListeners();

      final requestId = ++_seekRequestId;
      await _controller!.seekTo(clampedPosition);
      if (requestId != _seekRequestId) return;

      final actualPosition = _controller!.value.position;
      if (actualPosition != _position) {
        _position = actualPosition;
        notifyListeners();
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
      _bufferedPosition = _readBufferedPosition(_controller!);
      _scheduleSeekVerification(
        expectedPosition: clampedPosition,
        source: source,
      );

      _seekPersistTimer?.cancel();
      _seekPersistTimer = Timer(const Duration(milliseconds: 500), () {
        _saveCurrentProgress(immediate: true).catchError((e) {
          debugPrint('MediaPlaybackService: 保存进度失败 $e');
        });
        _savePlaybackStateSnapshot().catchError((e) {
          debugPrint('MediaPlaybackService: 保存播放状态快照失败 $e');
        });
      });

      notifyListeners();
    } catch (e) {
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

    if (_currentItem?.id == item.id && _controller != null) {
      clearSubtitleState();
      _seekPersistTimer?.cancel();
      _seekPersistTimer = null;
      await _disposeController();
      _lastControllerIsPlaying = null;
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
    final duration = _controller!.value.duration;
    final controllerIsPlaying = _controller!.value.isPlaying;
    final wasControllerPlaying =
        _lastControllerIsPlaying ?? controllerIsPlaying;
    final bufferedPosition = _readBufferedPosition(_controller!);
    if (!_controllerVolumeMatchesDesired(_controller!)) {
      unawaited(
        _applyMuteStateToController(reason: 'controller drift detected'),
      );
    }
    if (bufferedPosition != _bufferedPosition) {
      _bufferedPosition = bufferedPosition;
    }

    if (!_hasPlaybackCompleted &&
        _hasReachedPlaybackEnd(position, duration) &&
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
      final bool shouldNormalizeYouTubeAutoCaptions =
          _shouldNormalizeYouTubeAutoCaptions(path);
      final String cacheKey = shouldNormalizeYouTubeAutoCaptions
          ? '$path::yt_auto'
          : '$path::plain';
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
        if (shouldNormalizeYouTubeAutoCaptions &&
            YouTubeAutoCaptionNormalizer.shouldNormalize(
              subtitles: parsed,
              subtitlePath: path,
              videoItem: _currentItem,
            )) {
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
        baseName.contains('自动');
  }

  /// 更新当前字幕（支持连续字幕）
  void _updateCurrentSubtitle() {
    if (_subtitles.isEmpty) {
      if (_currentSubtitle != null) {
        _currentSubtitle = null;
      }
      _lastSubtitleIndex = -1;
      return;
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
    }
  }

  /// 播放完成处理
  void _onPlaybackCompleted() {
    if (_isHandlingPlaybackCompletion) return;
    _isHandlingPlaybackCompletion = true;
    unawaited(_handlePlaybackCompleted());
  }

  Future<void> _handlePlaybackCompleted() async {
    try {
      if (_controller != null && _controller!.value.isInitialized) {
        _position = _controller!.value.position;
        _duration = _controller!.value.duration;
        _bufferedPosition = _readBufferedPosition(_controller!);
      }
      await _saveCurrentProgress(immediate: true);

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
  }

  void _stopPositionUpdates() {
    _positionUpdateTimer?.cancel();
    _positionUpdateTimer = null;
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

    // 只有当位置或时长发生变化时才通知监听器
    if (newPosition != _position ||
        newDuration != _duration ||
        newBufferedPosition != _bufferedPosition) {
      _position = newPosition;
      _duration = newDuration;
      _bufferedPosition = newBufferedPosition;
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
      _updateCurrentSubtitle();

      // 检查是否播放结束
      if (_position >= _duration && _duration > Duration.zero) {
        _onPlaybackCompleted();
      }

      notifyListeners();
    }
  }

  // _updateNotificationProgress 已移除，改用事件驱动

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
  Future<void> _disposeController() async {
    final controller = _controller;
    if (controller != null) {
      _logPlaybackEvent(
        'disposing controller',
        data: <String, Object?>{
          'itemId': _currentItem?.id,
          'positionMs': _position.inMilliseconds,
        },
      );
      final bool shouldDisposeController = _serviceOwnsController;
      _controller = null;
      _serviceOwnsController = false;
      await _detachController(
        controller,
        disposeController: shouldDisposeController,
        pauseIfPlaying: true,
      );
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
    unawaited(_disposeController());
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
