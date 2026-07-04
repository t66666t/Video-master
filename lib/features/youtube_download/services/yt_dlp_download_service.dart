import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'package:video_player_app/features/youtube_download/models/youtube_download_models.dart';
import 'package:video_player_app/features/youtube_download/platform/yt_dlp_native_bridge.dart';
import 'package:video_player_app/features/youtube_download/services/yt_dlp_binary_installer.dart';
import 'package:video_player_app/features/youtube_download/services/yt_dlp_binary_updater.dart';
import 'package:video_player_app/features/youtube_download/services/yt_dlp_meta_parser.dart';
import 'package:video_player_app/features/youtube_download/services/yt_dlp_request_builder.dart';
import 'package:video_player_app/models/media_source_ref.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/app_wakelock_coordinator.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/services/temporary_storage_cleanup_models.dart';

/// 后台 Isolate 中执行的 JSON 编码，避免主线程卡顿
String _encodeJsonMaps(List<Map<String, dynamic>> maps) => jsonEncode(maps);

class YtDlpDownloadService extends ChangeNotifier {
  static const String _tasksPrefsKey = 'yt_dlp_tasks_v1';
  static const String _completedTasksPrefsKey = 'yt_dlp_completed_tasks_v1';
  static const String _failedTasksPrefsKey = 'yt_dlp_failed_tasks_v1';
  static const String _sessionPrefsKey = 'yt_dlp_session_config_v1';
  static const String _downloadPreferencesPrefsKey =
      'yt_dlp_download_preferences_v1';
  static const String _pendingAndroidTempCleanupPrefsKey =
      'yt_dlp_android_pending_temp_cleanup_keys';
  static const String _androidTempPrefix = 'ytdlp_';
  static const String _selectedContainerPrefsKey =
      'yt_dlp_last_output_container';
  static const String _audioOnlyPrefsKey = 'yt_dlp_last_audio_only';
  static const int _maxFallbackAttempts = 10;
  static const int _maxHistoryItems = 30;
  static const Duration _thumbnailRequestTimeout = Duration(seconds: 8);
  static const Duration _thumbnailResponseTimeout = Duration(seconds: 12);
  static const Duration _thumbnailImageConvertTimeout = Duration(seconds: 10);
  static const String _fallbackUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';
  static const List<String> _fallbackPlayerClientCandidates = [
    'tv_embedded',
    'mweb',
    'web',
    'ios',
    'android',
  ];

  final Uuid _uuid = const Uuid();
  final YtDlpRequestBuilder _requestBuilder = const YtDlpRequestBuilder();
  final YtDlpNativeBridge _nativeBridge = YtDlpNativeBridge();
  final YtDlpBinaryUpdater _binaryUpdater = const YtDlpBinaryUpdater();

  final List<YtDlpTaskRecord> tasks = [];
  final Map<String, int> _taskIndexById = {};
  // 缓存的任务 ID 列表，仅在任务结构变更时更新，避免 Selector 每次 notify 都重建列表
  List<String> _cachedTaskIds = const [];
  final List<YtDlpTaskRecord> recentCompletedTasks = [];
  final List<YtDlpTaskRecord> recentFailedTasks = [];

  Future<void>? _initFuture;
  StreamSubscription<DownloadTaskEvent>? _taskEventSub;
  Timer? _persistDebounceTimer;
  Timer? _progressNotifyTimer;
  DownloadSessionConfig _sessionConfig = DownloadSessionConfig.defaults();
  YtDlpDownloadPreferences _downloadPreferences =
      YtDlpDownloadPreferences.defaults();
  YtDlpBinaryStatus _binaryStatus = const YtDlpBinaryStatus();
  YtDlpBinaryReleaseInfo? _latestYtDlpRelease;
  final Map<String, DateTime> _lastTaskEventAt = <String, DateTime>{};
  bool _isInitialized = false;
  bool _runtimePrepared = false;
  bool _isPageActive = false;
  bool _hasPendingProgressPersistence = false;
  bool _hasPendingProgressUiRefresh = false;
  bool _isUpdatingYtDlp = false;
  double? _ytDlpUpdateProgress;
  String _ytDlpUpdateStage = '准备更新';
  String? _ytDlpUpdateError;
  bool keepScreenAwakeDuringProcessing = false;
  bool isResolving = false;
  String? resolvingStatus;
  int _processingTaskCount = 0;
  int _selectedCount = 0;
  int _selectedRunnableCount = 0;
  int _selectedPausableCount = 0;
  int _selectedPrioritizableCount = 0;
  int _selectedCancellableCount = 0;
  int _selectedRetryableCount = 0;
  int _selectedCompletedCount = 0;
  int _queuedCount = 0;
  int _activeCount = 0;
  int _failedCount = 0;
  int _completedCount = 0;
  bool _lastAppliedKeepAwakeActive = false;
  bool _metricsDirty = true;

  DownloadSessionConfig get sessionConfig => _sessionConfig;
  YtDlpDownloadPreferences get downloadPreferences => _downloadPreferences;
  YtDlpBinaryStatus get binaryStatus => _binaryStatus;
  YtDlpBinaryReleaseInfo? get latestYtDlpRelease => _latestYtDlpRelease;
  bool get supportsOnlineYtDlpUpdate => YtDlpBinaryUpdater.supportsOnlineUpdate;
  bool get isUpdatingYtDlp => _isUpdatingYtDlp;
  double? get ytDlpUpdateProgress => _ytDlpUpdateProgress;
  String get ytDlpUpdateStage => _ytDlpUpdateStage;
  String? get ytDlpUpdateError => _ytDlpUpdateError;
  String get bundledYtDlpVersion => YtDlpBinaryInstaller.bundledYtDlpVersion;
  bool get hasNewerYtDlpRelease {
    final latest = _normalizeBinaryVersion(_latestYtDlpRelease?.version);
    final current = _normalizeBinaryVersion(_binaryStatus.ytDlpVersion);
    return latest != null && current != null && latest != current;
  }

  bool get isInitialized => _isInitialized;
  bool get isInitializing => _initFuture != null && !_isInitialized;

  bool get supportsProcessingKeepAwakeToggle =>
      Platform.isAndroid || Platform.isIOS || Platform.isMacOS;

  bool get isProcessingKeepAwakeActive =>
      keepScreenAwakeDuringProcessing && hasProcessingTasks;

  bool get hasProcessingTasks => _processingTaskCount > 0;

  @override
  void notifyListeners() {
    if (_metricsDirty) {
      _refreshTaskMetrics();
      _metricsDirty = false;
    }
    super.notifyListeners();
  }

  Future<void> init() {
    _initFuture ??= _initInternal();
    return _initFuture!;
  }

  Future<void> ensureReady({
    bool activatePage = false,
    bool requireRuntime = false,
  }) async {
    if (activatePage) {
      _isPageActive = true;
    }
    if (!_isInitialized) {
      await init();
    }
    if (requireRuntime) {
      await _ensureRuntimeReady();
    }
    await _syncTaskEventBinding();
  }

  Future<void> activatePage() {
    return ensureReady(activatePage: true, requireRuntime: true);
  }

  Future<void> deactivatePage() async {
    _isPageActive = false;
    await _syncTaskEventBinding();
  }

  Future<void> _initInternal() async {
    final prefs = await SharedPreferences.getInstance();
    keepScreenAwakeDuringProcessing =
        prefs.getBool('yt_dlp_keep_screen_awake_during_processing') ?? false;
    await _loadPersistedState(prefs);
    _isInitialized = true;
    await _syncTaskEventBinding();
    _syncKeepAwake();
    _metricsDirty = true;
    notifyListeners();
    unawaited(_restoreTaskThumbnailArtifacts());
  }

  Future<void> _loadPersistedState(SharedPreferences prefs) async {
    final rawSession = prefs.getString(_sessionPrefsKey);
    if (rawSession != null && rawSession.isNotEmpty) {
      _sessionConfig = DownloadSessionConfig.fromJson(
        Map<String, dynamic>.from(_safeDecodeMap(rawSession)),
      );
    } else {
      final configFromNative = await _nativeBridge.loadYoutubeSessionConfig();
      if (configFromNative != null) {
        _sessionConfig = configFromNative;
      }
    }
    final rawDownloadPreferences = prefs.getString(
      _downloadPreferencesPrefsKey,
    );
    if (rawDownloadPreferences != null && rawDownloadPreferences.isNotEmpty) {
      _downloadPreferences = YtDlpDownloadPreferences.fromJson(
        Map<String, dynamic>.from(_safeDecodeMap(rawDownloadPreferences)),
      );
    }
    final normalizedSessionConfig = _normalizeLoadedSessionConfig(
      _sessionConfig,
    );
    final sessionConfigChanged = !_sameSessionConfig(
      _sessionConfig,
      normalizedSessionConfig,
    );
    _sessionConfig = normalizedSessionConfig;
    if (sessionConfigChanged) {
      await prefs.setString(
        _sessionPrefsKey,
        _encodeMap(_sessionConfig.toJson()),
      );
      await _nativeBridge.saveYoutubeSessionConfig(_sessionConfig);
    }

    final rawTasks = prefs.getString(_tasksPrefsKey);
    if (rawTasks != null && rawTasks.isNotEmpty) {
      try {
        tasks
          ..clear()
          ..addAll(decodeTaskList(rawTasks));
      } catch (_) {
        tasks.clear();
      }
    }

    final rawCompleted = prefs.getString(_completedTasksPrefsKey);
    if (rawCompleted != null && rawCompleted.isNotEmpty) {
      try {
        recentCompletedTasks
          ..clear()
          ..addAll(decodeTaskList(rawCompleted));
      } catch (_) {
        recentCompletedTasks.clear();
      }
    }

    final rawFailed = prefs.getString(_failedTasksPrefsKey);
    if (rawFailed != null && rawFailed.isNotEmpty) {
      try {
        recentFailedTasks
          ..clear()
          ..addAll(decodeTaskList(rawFailed));
      } catch (_) {
        recentFailedTasks.clear();
      }
    }

    for (var i = 0; i < tasks.length; i++) {
      final task = tasks[i];
      if (task.status == YtDlpTaskStatus.downloading ||
          task.status == YtDlpTaskStatus.postProcessing ||
          task.status == YtDlpTaskStatus.resolving ||
          task.status == YtDlpTaskStatus.pausing ||
          task.status == YtDlpTaskStatus.queued) {
        tasks[i] = task.copyWith(
          status: YtDlpTaskStatus.paused,
          errorMessage: '应用重启后可继续',
          lastFailedAtIso: DateTime.now().toIso8601String(),
        );
      }
    }

    if (Platform.isAndroid) {
      await _cleanupAndroidTempOrphans();
    }

    _refreshHistorySnapshots();
    await _persistTaskState(prefs: prefs);
    _rebuildTaskIndex();
  }

  Future<void> _restoreTaskThumbnailArtifacts() async {
    try {
      var changed = false;
      for (var i = 0; i < tasks.length; i++) {
        final updated = await _withEnsuredTaskThumbnail(tasks[i]);
        if (updated != tasks[i]) {
          tasks[i] = updated;
          changed = true;
        }
      }
      if (changed) {
        await saveTasks();
      }
      await _cleanupOrphanTaskThumbnailArtifacts();
    } catch (e) {
      debugPrint('恢复 yt-dlp 任务缩略图失败: $e');
    }
  }

  Future<void> _ensureTaskThumbnailCached(String taskId) async {
    final index = _indexOfTask(taskId);
    if (index < 0) {
      return;
    }
    final updated = await _withEnsuredTaskThumbnail(tasks[index]);
    if (updated == tasks[index]) {
      return;
    }
    tasks[index] = updated;
    await saveTasks();
  }

  Future<YtDlpTaskRecord> _withEnsuredTaskThumbnail(
    YtDlpTaskRecord task,
  ) async {
    if (task.thumbnailCandidateUrls.isEmpty) {
      return task;
    }
    final existingPath = _normalizeLocalFilePath(task.localThumbnailPath);
    if (existingPath != null && existingPath.isNotEmpty) {
      final repairedExistingPath = await _repairWindowsThumbnailArtifact(
        existingPath,
      );
      if (repairedExistingPath != null && repairedExistingPath.isNotEmpty) {
        final existingFile = File(repairedExistingPath);
        if (await existingFile.exists()) {
          return repairedExistingPath == task.localThumbnailPath
              ? task
              : task.copyWith(taskThumbnailPath: repairedExistingPath);
        }
      }
    }
    final savedPath = await _downloadTaskThumbnailArtifact(task);
    if (savedPath == null || savedPath.isEmpty) {
      return task;
    }
    return task.copyWith(taskThumbnailPath: savedPath);
  }

  Future<String?> _downloadTaskThumbnailArtifact(YtDlpTaskRecord task) async {
    if (task.thumbnailCandidateUrls.isEmpty && task.sourceUrl.isEmpty) {
      return null;
    }
    final dir = await _resolveTaskThumbnailDirectory();
    final baseFileName =
        '${task.taskId}_${_sanitizeOutputBaseName(task.title)}';
    // 桌面端优先用 yt-dlp 进程下载缩略图（可靠，不受 Dart HttpClient 平台限制）
    final ytDlpResult = await _downloadThumbnailViaYtDlp(
      sourceUrl: task.sourceUrl,
      targetDirectory: dir,
      baseFileName: baseFileName,
      sessionConfig: task.executionSessionConfig,
    );
    if (ytDlpResult != null && ytDlpResult.isNotEmpty) {
      return ytDlpResult;
    }
    // Android 端无 yt-dlp 二进制，或 yt-dlp 失败时，回退到 HTTP 客户端
    if (task.thumbnailCandidateUrls.isEmpty) {
      return null;
    }
    return _downloadThumbnailArtifactWithFallback(
      candidateUrls: task.thumbnailCandidateUrls,
      targetDirectory: dir,
      fileNamePrefix: baseFileName,
      failureLabel: '下载 yt-dlp 任务缩略图',
    );
  }

  Future<void> _deleteTaskThumbnailArtifact(String? thumbnailPath) async {
    final normalizedPath = _normalizeLocalFilePath(thumbnailPath);
    if (normalizedPath == null || normalizedPath.isEmpty) {
      return;
    }
    try {
      final file = File(normalizedPath);
      if (await file.exists()) {
        await file.delete();
      }
    } catch (e) {
      debugPrint('删除 yt-dlp 任务缩略图失败: $e');
    }
  }

  Future<void> _cleanupOrphanTaskThumbnailArtifacts() async {
    final dir = await _resolveTaskThumbnailDirectory();
    final retainedPaths = tasks
        .map((item) => item.localThumbnailPath?.trim())
        .whereType<String>()
        .where((item) => item.isNotEmpty)
        .map(p.normalize)
        .toSet();
    try {
      await for (final entity in dir.list()) {
        if (entity is! File) {
          continue;
        }
        final normalizedPath = p.normalize(entity.path);
        if (!retainedPaths.contains(normalizedPath)) {
          await entity.delete();
        }
      }
    } catch (e) {
      debugPrint('清理 yt-dlp 孤儿缩略图失败: $e');
    }
  }

  Future<void> _ensureRuntimeReady({bool forceRefresh = false}) async {
    if (_runtimePrepared && !forceRefresh) {
      return;
    }
    await YtDlpBinaryInstaller.ensureInstalled();
    _binaryStatus = await _nativeBridge.getBinaryStatus();
    _runtimePrepared = true;
    notifyListeners();
  }

  Future<void> _bindTaskEventsIfNeeded() async {
    if (!_runtimePrepared) {
      return;
    }
    final shouldBind = _isPageActive || hasProcessingTasks;
    if (!shouldBind || _taskEventSub != null) {
      return;
    }
    _taskEventSub?.cancel();
    _taskEventSub = _nativeBridge.taskEvents().listen(
      _handleTaskEvent,
      onError: (_) {},
    );
  }

  Future<void> _unbindTaskEventsIfIdle() async {
    if (_isPageActive || hasProcessingTasks) {
      return;
    }
    await _taskEventSub?.cancel();
    _taskEventSub = null;
  }

  Future<void> _syncTaskEventBinding() async {
    if (_isPageActive || hasProcessingTasks) {
      await _bindTaskEventsIfNeeded();
      return;
    }
    await _unbindTaskEventsIfIdle();
  }

  Future<void> _flushPendingProgressPersistence() async {
    final hadPending = _hasPendingProgressPersistence;
    _persistDebounceTimer?.cancel();
    _persistDebounceTimer = null;
    if (!hadPending) {
      return;
    }
    _hasPendingProgressPersistence = false;
    final prefs = await SharedPreferences.getInstance();
    await _persistTaskState(prefs: prefs);
  }

  void _scheduleProgressPersistence() {
    _hasPendingProgressPersistence = true;
    _persistDebounceTimer?.cancel();
    _persistDebounceTimer = Timer(const Duration(seconds: 1), () {
      _persistDebounceTimer = null;
      if (!_hasPendingProgressPersistence) {
        return;
      }
      unawaited(_flushPendingProgressPersistence());
    });
  }

  void _notifyProgressUpdate() {
    _syncKeepAwake();
    _scheduleProgressPersistence();
    _hasPendingProgressUiRefresh = true;
    if (_progressNotifyTimer != null) {
      return;
    }
    // Windows 端针对多任务负载动态调节刷新间隔
    final refreshInterval = _isPageActive
        ? (tasks.length >= 60
              ? const Duration(milliseconds: 500)
              : tasks.length >= 25 && Platform.isWindows
                  ? const Duration(milliseconds: 380)
                  : _activeTaskProgressThrottle)
        : (tasks.length >= 60
              ? const Duration(milliseconds: 900)
              : _backgroundTaskProgressThrottle);
    _progressNotifyTimer = Timer(refreshInterval, () {
      _progressNotifyTimer = null;
      if (!_hasPendingProgressUiRefresh) {
        return;
      }
      _hasPendingProgressUiRefresh = false;
      notifyListeners();
    });
  }

  void _clearPendingProgressUiRefresh() {
    _progressNotifyTimer?.cancel();
    _progressNotifyTimer = null;
    _hasPendingProgressUiRefresh = false;
  }

  Future<void> shutdown() async {
    _isPageActive = false;
    _clearPendingProgressUiRefresh();
    await _flushPendingProgressPersistence();
    await _taskEventSub?.cancel();
    _taskEventSub = null;
    await saveTasks();
  }

  Future<void> saveTasks() async {
    _clearPendingProgressUiRefresh();
    await _flushPendingProgressPersistence();
    _rebuildTaskIndex();
    _metricsDirty = true;
    final prefs = await SharedPreferences.getInstance();
    _refreshHistorySnapshots();
    await _persistTaskState(prefs: prefs);
    _syncKeepAwake();
    await _syncTaskEventBinding();
    notifyListeners();
  }

  Future<void> saveSessionConfig(DownloadSessionConfig config) async {
    await ensureReady(activatePage: true, requireRuntime: true);
    _sessionConfig = _normalizeLoadedSessionConfig(config);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _sessionPrefsKey,
      _encodeMap(_sessionConfig.toJson()),
    );
    await _nativeBridge.saveYoutubeSessionConfig(_sessionConfig);
    notifyListeners();
  }

  Future<void> saveDownloadPreferences(
    YtDlpDownloadPreferences preferences,
  ) async {
    await ensureReady(activatePage: true);
    final previousPreferences = _downloadPreferences;
    _downloadPreferences = preferences;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _downloadPreferencesPrefsKey,
      _encodeMap(_downloadPreferences.toJson()),
    );
    final qualityChanged =
        previousPreferences.preferredQuality != preferences.preferredQuality;
    if (qualityChanged) {
      await _applyPreferredQualityToAllTasks();
      return;
    }
    notifyListeners();
  }

  Future<void> updateDownloadPreferences({
    String? preferredQuality,
    List<String>? preferredSubtitleLanguages,
    bool? autoImportToLibrary,
    bool? autoDeleteTaskAfterImport,
  }) async {
    await saveDownloadPreferences(
      _downloadPreferences.copyWith(
        preferredQuality: preferredQuality,
        preferredSubtitleLanguages: preferredSubtitleLanguages,
        autoImportToLibrary: autoImportToLibrary,
        autoDeleteTaskAfterImport: autoDeleteTaskAfterImport,
      ),
    );
  }

  Future<void> _applyPreferredQualityToAllTasks() async {
    var updated = false;
    for (var i = 0; i < tasks.length; i++) {
      final task = tasks[i];
      final meta = task.meta;
      if (meta == null) {
        continue;
      }
      final nextSelection = _buildSelectionFromPreferences(
        selection: task.selection,
        meta: meta,
        preferences: _downloadPreferences,
        forceVideoPreference: true,
      );
      if (nextSelection.selectedVideoFormatId ==
              task.selection.selectedVideoFormatId &&
          _sameStringList(
            nextSelection.selectedAudioFormatIds,
            task.selection.selectedAudioFormatIds,
          )) {
        continue;
      }
      tasks[i] = task.copyWith(selection: nextSelection);
      updated = true;
    }
    if (updated) {
      await saveTasks();
      return;
    }
    notifyListeners();
  }

  Future<String?> importCookiesFile(String sourcePath) async {
    await ensureReady(activatePage: true, requireRuntime: true);
    final importedPath = await _nativeBridge.importYoutubeCookies(sourcePath);
    if (importedPath != null && importedPath.isNotEmpty) {
      final updated = _sessionConfig.copyWith(
        cookiesFilePath: importedPath,
        useCookies: true,
      );
      await saveSessionConfig(updated);
      return importedPath;
    }

    final cookiesDir = await _resolveCookiesDirectory();
    final target = File(p.join(cookiesDir.path, 'cookies.txt'));
    final source = File(sourcePath);
    if (await source.exists()) {
      await source.copy(target.path);
      final updated = _sessionConfig.copyWith(
        cookiesFilePath: target.path,
        useCookies: true,
      );
      await saveSessionConfig(updated);
      return target.path;
    }
    return null;
  }

  Future<void> saveLastSelection(DownloadSelection selection) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _selectedContainerPrefsKey,
      selection.outputContainer,
    );
    await prefs.setBool(_audioOnlyPrefsKey, selection.audioOnly);
  }

  Future<DownloadSelection> loadLastSelection() async {
    final prefs = await SharedPreferences.getInstance();
    return DownloadSelection(
      outputContainer: prefs.getString(_selectedContainerPrefsKey) ?? 'mp4',
      audioOnly: prefs.getBool(_audioOnlyPrefsKey) ?? false,
    );
  }

  Future<bool> toggleKeepScreenAwakeDuringProcessing() async {
    await ensureReady(activatePage: true);
    keepScreenAwakeDuringProcessing = !keepScreenAwakeDuringProcessing;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(
      'yt_dlp_keep_screen_awake_during_processing',
      keepScreenAwakeDuringProcessing,
    );
    _syncKeepAwake();
    notifyListeners();
    return keepScreenAwakeDuringProcessing;
  }

  Future<VideoMeta?> resolveUrl(String url) async {
    await ensureReady(activatePage: true, requireRuntime: true);
    final normalized = url.trim();
    if (normalized.isEmpty) {
      return null;
    }

    final environmentError = _currentEnvironmentError();
    if (environmentError != null) {
      resolvingStatus = environmentError;
      notifyListeners();
      return null;
    }

    isResolving = true;
    resolvingStatus = '正在解析链接...';
    notifyListeners();

    try {
      final lastSelection = await loadLastSelection();
      final attemptConfigs = _buildResolveAttemptConfigs(_sessionConfig);
      final saferResolveConfig = _buildSaferResolveConfig(
        _normalizeLoadedSessionConfig(_sessionConfig),
      );
      VideoMeta? meta;
      DownloadSessionConfig? resolvedConfig;
      Object? lastError;
      for (var i = 0; i < attemptConfigs.length; i++) {
        final attemptConfig = attemptConfigs[i];
        try {
          final rawPayload = await _nativeBridge
              .resolveYoutubeMeta(normalized, attemptConfig)
              .timeout(
                const Duration(seconds: 95),
                onTimeout: () => throw TimeoutException('桌面端解析超时'),
              );
          if (rawPayload == null) {
            throw Exception('当前平台暂未返回可用的解析结果');
          }
          final parsedMeta = await _parseResolvedMeta(rawPayload);
          if (parsedMeta.videoFormats.isEmpty &&
              parsedMeta.audioFormats.isEmpty) {
            throw Exception('已拿到元数据，但没有可用格式，请尝试调整会话设置或切换策略');
          }
          meta = parsedMeta;
          resolvedConfig = attemptConfig;
          break;
        } catch (e) {
          lastError = e;
          if (i == attemptConfigs.length - 1) {
            rethrow;
          }
          if (!_shouldRetryResolveWithSaferConfig(
            e,
            attemptConfig,
            saferResolveConfig,
          )) {
            rethrow;
          }
          resolvingStatus = '检测到高级 YouTube 参数可能影响解析，正在回退后重试...';
          notifyListeners();
        }
      }
      if (meta == null) {
        throw lastError ?? Exception('解析失败');
      }
      final resolvedSelection = await _applyMetaRecommendationsInBackground(
        lastSelection,
        meta,
        _downloadPreferences,
      );
      final taskId = _uuid.v4();
      var task = YtDlpTaskRecord.fromMeta(
        taskId: taskId,
        sourceUrl: normalized,
        sourceRef: MediaSourceRef(value: normalized, kind: MediaSourceKind.url),
        meta: meta,
        selection: resolvedSelection,
      );
      if (resolvedConfig != null &&
          !_sameSessionConfig(resolvedConfig, _sessionConfig)) {
        task = task.copyWith(executionSessionConfig: resolvedConfig);
      }
      tasks.insert(0, task);
      await saveTasks();
      unawaited(_ensureTaskThumbnailCached(taskId));
      resolvingStatus =
          resolvedConfig != null &&
              !_sameSessionConfig(resolvedConfig, _sessionConfig)
          ? '解析完成，已自动回退高级 YouTube 参数'
          : '解析完成';
      return meta;
    } catch (e) {
      final failureType = _mapFailureText(e.toString());
      resolvingStatus = '解析失败(${_failureTypeLabel(failureType)}): $e';
      return null;
    } finally {
      isResolving = false;
      notifyListeners();
    }
  }

  Future<VideoMeta> _parseResolvedMeta(Map<String, dynamic> rawPayload) async {
    final rawInfo = _extractRawInfo(rawPayload);
    if (rawInfo.isEmpty) {
      throw Exception('yt-dlp 返回了空或不可解析的元数据，请检查日志或调整会话设置');
    }
    return compute(_parseResolvedMetaOnWorker, rawPayload);
  }

  Future<DownloadSelection> _applyMetaRecommendationsInBackground(
    DownloadSelection selection,
    VideoMeta meta,
    YtDlpDownloadPreferences preferences,
  ) {
    return compute(_applyMetaRecommendationsOnWorker, {
      'selection': selection.toJson(),
      'meta': meta.toJson(),
      'preferences': preferences.toJson(),
    });
  }

  Future<void> startTask(
    YtDlpTaskRecord task, {
    bool prioritize = false,
  }) async {
    await ensureReady(requireRuntime: true);
    final index = _indexOfTask(task.taskId);
    if (index < 0) return;
    final current = tasks[index];
    if (current.meta == null || !current.canStart) return;
    final previousTempArtifactKey = current.tempArtifactKey;

    if (Platform.isAndroid &&
        previousTempArtifactKey != null &&
        previousTempArtifactKey.isNotEmpty) {
      await _cleanupAndroidTempArtifactsByKey(previousTempArtifactKey);
    }

    tasks[index] = current.copyWith(
      status: YtDlpTaskStatus.queued,
      statusMessage: null,
      stepMessages: const [],
      errorMessage: null,
      failureType: YtDlpFailureType.none,
      failureContext: null,
      completedAtIso: null,
      lastFailedAtIso: null,
      executionSessionConfig: current.executionSessionConfig ?? _sessionConfig,
      request: null,
      tempArtifactKey: null,
      progress: 0,
      downloadedBytes: null,
      totalBytes: null,
      speedText: null,
      etaText: null,
      outputPath: null,
    );
    if (prioritize) {
      final moved = tasks.removeAt(index);
      tasks.insert(_priorityInsertIndex(), moved);
    }
    await saveTasks();

    if (_hasActiveTask(excludingTaskId: task.taskId)) {
      return;
    }

    await _launchQueuedTask(task.taskId);
  }

  Future<void> prioritizeTask(YtDlpTaskRecord task) async {
    await ensureReady(requireRuntime: true);
    final index = _indexOfTask(task.taskId);
    if (index < 0 || task.meta == null) return;
    final current = tasks[index];
    if (_isActiveExecutionStatus(current.status)) {
      return;
    }

    final hadBlockingTask = _hasBlockingTask();
    final moved = current.copyWith(
      status: YtDlpTaskStatus.queued,
      errorMessage: null,
      failureType: YtDlpFailureType.none,
      failureContext: null,
      tempArtifactKey: null,
    );
    tasks.removeAt(index);
    tasks.insert(_priorityInsertIndex(), moved);
    await saveTasks();

    if (!hadBlockingTask) {
      await _launchQueuedTask(moved.taskId);
    }
  }

  Future<void> _launchQueuedTask(String taskId) async {
    final index = _indexOfTask(taskId);
    if (index < 0) return;
    final task = tasks[index];
    if (task.meta == null) return;

    final environmentError = _currentEnvironmentError(requireFfmpeg: true);
    if (environmentError != null) {
      tasks[index] = task.copyWith(
        status: YtDlpTaskStatus.failed,
        errorMessage: environmentError,
        failureType: YtDlpFailureType.unsupported,
        lastFailedAtIso: DateTime.now().toIso8601String(),
      );
      await saveTasks();
      await _tryStartNextQueuedTask(excludingTaskId: taskId);
      return;
    }

    final outputDir = await _resolveOutputDirectory(
      task.executionSessionConfig,
    );
    final request = _requestBuilder.build(
      taskId: task.taskId,
      url: task.sourceUrl,
      meta: task.meta!,
      selection: task.selection,
      sessionConfig: task.executionSessionConfig ?? _sessionConfig,
      outputDir: outputDir.path,
    );
    String? tempArtifactKey;
    var launchRequest = request;
    if (_shouldUseAndroidStagedFallback) {
      tempArtifactKey = _createAndroidTempArtifactKey(task);
      launchRequest = await _buildAndroidStagedRequest(
        task: task,
        baseRequest: request,
        tempArtifactKey: tempArtifactKey,
      );
    }
    tasks[index] = tasks[index].copyWith(
      request: launchRequest,
      tempArtifactKey: tempArtifactKey,
      producedPaths: const [],
      status: YtDlpTaskStatus.queued,
      statusMessage: null,
      stepMessages: const [],
      errorMessage: null,
      failureType: YtDlpFailureType.none,
      failureContext: null,
    );
    await saveTasks();
    await _bindTaskEventsIfNeeded();

    final started = await _nativeBridge.startYoutubeDownload(launchRequest);
    if (!started) {
      if (Platform.isAndroid && tempArtifactKey != null) {
        await _cleanupAndroidTempArtifactsByKey(tempArtifactKey);
      }
      tasks[index] = tasks[index].copyWith(
        status: YtDlpTaskStatus.failed,
        errorMessage: '当前平台暂不支持启动 yt-dlp 下载任务',
        failureType: YtDlpFailureType.unsupported,
        lastFailedAtIso: DateTime.now().toIso8601String(),
      );
      await saveTasks();
      await _tryStartNextQueuedTask(excludingTaskId: taskId);
    }
  }

  Future<void> pauseTask(YtDlpTaskRecord task) async {
    await ensureReady(requireRuntime: true);
    final index = _indexOfTask(task.taskId);
    if (index < 0) return;
    final current = tasks[index];
    if (!current.canPause) {
      return;
    }
    final isWaitingInQueue =
        current.status == YtDlpTaskStatus.queued &&
        _hasBlockingTask(excludingTaskId: task.taskId);
    if (isWaitingInQueue) {
      tasks[index] = current.copyWith(
        status: YtDlpTaskStatus.paused,
        errorMessage: '已从队列暂停',
      );
      await saveTasks();
      return;
    }
    tasks[index] = current.copyWith(
      status: YtDlpTaskStatus.pausing,
      errorMessage: '正在暂停...',
    );
    await saveTasks();
    final paused = await _nativeBridge.pauseYoutubeDownload(task.taskId);
    final latestIndex = _indexOfTask(task.taskId);
    if (latestIndex < 0) return;
    if (!paused) {
      tasks[latestIndex] = tasks[latestIndex].copyWith(
        status: current.status,
        errorMessage: '暂停失败，请稍后重试',
      );
      await saveTasks();
    }
  }

  Future<void> cancelTask(YtDlpTaskRecord task) async {
    await ensureReady(requireRuntime: true);
    final index = _indexOfTask(task.taskId);
    if (index < 0) return;
    final current = tasks[index];
    if (!current.canCancel &&
        current.status != YtDlpTaskStatus.queued &&
        current.status != YtDlpTaskStatus.pending) {
      tasks[index] = current.copyWith(errorMessage: '当前任务不支持取消');
      await saveTasks();
      return;
    }
    final isWaitingInQueue =
        current.status == YtDlpTaskStatus.queued &&
        _hasBlockingTask(excludingTaskId: task.taskId);
    if (isWaitingInQueue || current.status == YtDlpTaskStatus.paused) {
      tasks[index] = current.copyWith(
        status: YtDlpTaskStatus.cancelled,
        errorMessage: '已取消',
        failureType: YtDlpFailureType.userCancelled,
      );
      await saveTasks();
      return;
    }
    final cancelled = await _nativeBridge.cancelYoutubeDownload(task.taskId);
    if (cancelled) {
      return;
    }
    if (current.status == YtDlpTaskStatus.queued) {
      tasks[index] = current.copyWith(
        status: YtDlpTaskStatus.cancelled,
        errorMessage: '已取消',
        failureType: YtDlpFailureType.userCancelled,
      );
      await saveTasks();
      await _tryStartNextQueuedTask(excludingTaskId: task.taskId);
      return;
    }
    tasks[index] = tasks[index].copyWith(errorMessage: '当前任务不支持取消');
    await saveTasks();
  }

  Future<void> retryTask(YtDlpTaskRecord task) async {
    await ensureReady(requireRuntime: true);
    final index = _indexOfTask(task.taskId);
    if (index < 0) return;
    final current = tasks[index];
    if (!current.canRetry) {
      return;
    }
    tasks[index] = tasks[index].copyWith(
      status: YtDlpTaskStatus.pending,
      statusMessage: null,
      stepMessages: const [],
      errorMessage: null,
      failureType: YtDlpFailureType.none,
      retryCount: current.retryCount + 1,
      fallbackAttemptCount: 0,
      appliedFallbackSteps: const [],
      executionSessionConfig: _sessionConfig,
      failureContext: null,
      completedAtIso: null,
      lastFailedAtIso: null,
      request: null,
      tempArtifactKey: null,
      progress: 0,
      downloadedBytes: null,
      totalBytes: null,
      speedText: null,
      etaText: null,
      outputPath: null,
      producedPaths: const [],
    );
    await saveTasks();
    await startTask(tasks[index]);
  }

  Future<void> removeTask(
    YtDlpTaskRecord task, {
    bool deleteCompletedOutput = true,
  }) async {
    await ensureReady(requireRuntime: true);
    final isProcessing =
        task.status == YtDlpTaskStatus.queued ||
        task.status == YtDlpTaskStatus.resolving ||
        task.status == YtDlpTaskStatus.pausing ||
        task.status == YtDlpTaskStatus.downloading ||
        task.status == YtDlpTaskStatus.postProcessing;
    if (isProcessing) {
      await _nativeBridge.cancelYoutubeDownload(task.taskId);
    }
    await _nativeBridge.removeYoutubeTask(task.taskId);
    if (Platform.isAndroid) {
      await _cleanupAndroidArtifactsForTask(
        task,
        deleteCompletedOutput: deleteCompletedOutput,
        forgetTrackedKey: true,
      );
    }
    await _deleteTaskThumbnailArtifact(task.localThumbnailPath);
    tasks.removeWhere((item) => item.taskId == task.taskId);
    await saveTasks();
    if (isProcessing) {
      await _tryStartNextQueuedTask(excludingTaskId: task.taskId);
    }
  }

  Future<void> clearAllTasks() async {
    await ensureReady(activatePage: true);
    final taskSnapshot = [...tasks];
    for (final task in taskSnapshot) {
      await removeTask(task);
    }
    await saveTasks();
  }

  Future<void> clearCompletedTasks() async {
    await ensureReady(activatePage: true);
    final completed = tasks
        .where(
          (item) =>
              item.status == YtDlpTaskStatus.completed ||
              item.status == YtDlpTaskStatus.exported,
        )
        .toList();
    for (final task in completed) {
      await removeTask(task);
    }
  }

  void selectAll() {
    final shouldSelect = tasks.any((item) => !item.isSelected);
    for (var i = 0; i < tasks.length; i++) {
      tasks[i] = tasks[i].copyWith(isSelected: shouldSelect);
    }
    _persistSelectionState();
  }

  Future<void> removeSelected() async {
    await ensureReady(activatePage: true);
    final selected = tasks.where((item) => item.isSelected).toList();
    for (final task in selected) {
      await removeTask(task);
    }
  }

  Future<void> pauseSelected() async {
    await ensureReady(activatePage: true, requireRuntime: true);
    final selected = tasks
        .where((item) => item.isSelected && item.canPause)
        .toList();
    for (final task in selected) {
      await pauseTask(task);
    }
  }

  Future<void> cancelSelected() async {
    await ensureReady(activatePage: true, requireRuntime: true);
    final selected = tasks
        .where((item) => item.isSelected && item.canCancel)
        .toList();
    for (final task in selected) {
      await cancelTask(task);
    }
  }

  Future<void> retrySelected() async {
    await ensureReady(activatePage: true, requireRuntime: true);
    final selected = tasks
        .where((item) => item.isSelected && item.canRetry)
        .toList();
    for (final task in selected) {
      await retryTask(task);
    }
  }

  Future<void> startSelected() async {
    await ensureReady(activatePage: true, requireRuntime: true);
    final selectedIndices = <int>[];
    for (var i = 0; i < tasks.length; i++) {
      if (tasks[i].isSelected && tasks[i].canStart) {
        selectedIndices.add(i);
      }
    }
    if (selectedIndices.isEmpty) return;

    // Batch: set all selected tasks to queued status in one pass
    for (final index in selectedIndices) {
      final current = tasks[index];
      if (Platform.isAndroid &&
          current.tempArtifactKey != null &&
          current.tempArtifactKey!.isNotEmpty) {
        await _cleanupAndroidTempArtifactsByKey(current.tempArtifactKey!);
      }
      tasks[index] = current.copyWith(
        status: YtDlpTaskStatus.queued,
        statusMessage: null,
        stepMessages: const [],
        errorMessage: null,
        failureType: YtDlpFailureType.none,
        failureContext: null,
        completedAtIso: null,
        lastFailedAtIso: null,
        executionSessionConfig: current.executionSessionConfig ?? _sessionConfig,
        request: null,
        tempArtifactKey: null,
        progress: 0,
        downloadedBytes: null,
        totalBytes: null,
        speedText: null,
        etaText: null,
        outputPath: null,
      );
    }
    // Single save + notify for all queued tasks
    await saveTasks();

    // Launch the first queued task if no active task is running
    if (!_hasActiveTask()) {
      final firstQueued = tasks.firstWhere(
        (item) => item.status == YtDlpTaskStatus.queued && item.meta != null,
        orElse: () => const YtDlpTaskRecord(
          taskId: '',
          sourceUrl: '',
          selection: DownloadSelection(),
          createdAtIso: '',
        ),
      );
      if (firstQueued.taskId.isNotEmpty) {
        await _launchQueuedTask(firstQueued.taskId);
      }
    }
  }

  Future<void> prioritizeSelected() async {
    await ensureReady(activatePage: true, requireRuntime: true);
    final selected = tasks
        .where(
          (item) =>
              item.isSelected &&
              item.meta != null &&
              !_isActiveExecutionStatus(item.status),
        )
        .toList();
    if (selected.isEmpty) {
      return;
    }

    final hadBlockingTask = _hasBlockingTask();
    final selectedIds = selected.map((item) => item.taskId).toSet();
    final prioritized = selected
        .map(
          (item) => item.copyWith(
            status: YtDlpTaskStatus.queued,
            errorMessage: null,
            failureType: YtDlpFailureType.none,
            failureContext: null,
            tempArtifactKey: null,
          ),
        )
        .toList();
    tasks.removeWhere((item) => selectedIds.contains(item.taskId));
    tasks.insertAll(_priorityInsertIndex(), prioritized);
    await saveTasks();

    if (!hadBlockingTask) {
      await _launchQueuedTask(prioritized.first.taskId);
    }
  }

  void updateTaskSelection(String taskId, bool selected) {
    final index = _indexOfTask(taskId);
    if (index < 0) return;
    tasks[index] = tasks[index].copyWith(isSelected: selected);
    _persistSelectionState();
  }

  void _persistSelectionState() {
    notifyListeners();
    unawaited(saveTasks());
  }

  Future<void> updateTaskSelectionModel(
    String taskId,
    DownloadSelection selection,
  ) async {
    await ensureReady(activatePage: true);
    final index = _indexOfTask(taskId);
    if (index < 0) return;
    tasks[index] = tasks[index].copyWith(selection: selection);
    await saveLastSelection(selection);
    await saveTasks();
  }

  int get selectedCount => _selectedCount;

  int get selectedRunnableCount => _selectedRunnableCount;

  int get selectedPausableCount => _selectedPausableCount;

  int get selectedPrioritizableCount => _selectedPrioritizableCount;

  int get selectedCancellableCount => _selectedCancellableCount;

  int get selectedRetryableCount => _selectedRetryableCount;

  int get selectedCompletedCount => _selectedCompletedCount;

  int get queuedCount => _queuedCount;

  int get activeCount => _activeCount;

  int get failedCount => _failedCount;

  int get completedCount => _completedCount;

  void _refreshTaskMetrics() {
    var processingTaskCount = 0;
    var selectedCount = 0;
    var selectedRunnableCount = 0;
    var selectedPausableCount = 0;
    var selectedPrioritizableCount = 0;
    var selectedCancellableCount = 0;
    var selectedRetryableCount = 0;
    var selectedCompletedCount = 0;
    var queuedCount = 0;
    var activeCount = 0;
    var failedCount = 0;
    var completedCount = 0;
    for (final task in tasks) {
      if (task.status == YtDlpTaskStatus.queued) {
        queuedCount++;
        processingTaskCount++;
      }
      if (_isActiveExecutionStatus(task.status)) {
        processingTaskCount++;
        activeCount++;
      }
      if (task.status == YtDlpTaskStatus.failed) {
        failedCount++;
      }
      if (task.status == YtDlpTaskStatus.completed ||
          task.status == YtDlpTaskStatus.exported) {
        completedCount++;
      }
      if (!task.isSelected) {
        continue;
      }
      selectedCount++;
      if (task.canStart) {
        selectedRunnableCount++;
      }
      if (task.canPause) {
        selectedPausableCount++;
      }
      if (task.meta != null && !_isActiveExecutionStatus(task.status)) {
        selectedPrioritizableCount++;
      }
      if (task.canCancel) {
        selectedCancellableCount++;
      }
      if (task.canRetry) {
        selectedRetryableCount++;
      }
      if (task.status == YtDlpTaskStatus.completed &&
          (task.outputPath?.isNotEmpty ?? false)) {
        selectedCompletedCount++;
      }
    }
    _processingTaskCount = processingTaskCount;
    _selectedCount = selectedCount;
    _selectedRunnableCount = selectedRunnableCount;
    _selectedPausableCount = selectedPausableCount;
    _selectedPrioritizableCount = selectedPrioritizableCount;
    _selectedCancellableCount = selectedCancellableCount;
    _selectedRetryableCount = selectedRetryableCount;
    _selectedCompletedCount = selectedCompletedCount;
    _queuedCount = queuedCount;
    _activeCount = activeCount;
    _failedCount = failedCount;
    _completedCount = completedCount;
  }

  Future<String> resolveEffectiveOutputDirectoryPath([
    DownloadSessionConfig? config,
  ]) async {
    final dir = await _resolveOutputDirectory(config);
    return dir.path;
  }

  Future<int> importToLibrary({
    YtDlpTaskRecord? task,
    String? targetFolderId,
  }) async {
    final library = LibraryService();
    await library.init();
    final importedTaskIds = <String>{};
    final candidates = task == null
        ? tasks
              .where(
                (item) =>
                    item.isSelected &&
                    item.status == YtDlpTaskStatus.completed &&
                    (item.outputPath?.isNotEmpty ?? false),
              )
              .toList()
        : [task];
    if (candidates.isEmpty) {
      return 0;
    }

    final subtitleDir = await _resolveLibrarySubtitleDirectory();
    final thumbnailDir = await _resolveLibraryThumbnailDirectory();
    var importedCount = 0;
    for (var ci = 0; ci < candidates.length; ci++) {
      final candidate = candidates[ci];
      // 每处理 3 个任务时让出主线程，保持 UI 响应
      if (ci > 0 && ci % 3 == 0) {
        await Future<void>.delayed(Duration.zero);
      }
      final outputPath = candidate.outputPath;
      if (candidate.status != YtDlpTaskStatus.completed ||
          outputPath == null ||
          outputPath.isEmpty) {
        continue;
      }
      final mediaFile = File(outputPath);
      if (!await mediaFile.exists()) {
        continue;
      }

      final copiedSubtitles = await _copyLibrarySubtitleArtifacts(
        task: candidate,
        outputPath: outputPath,
        subtitleDir: subtitleDir,
        preferredLanguages: candidate.selection.subtitleLanguages,
      );
      final defaultSubtitlePath = copiedSubtitles.isEmpty
          ? null
          : copiedSubtitles.values.first;
      final additionalSubtitles = copiedSubtitles.isEmpty
          ? null
          : Map<String, String>.from(copiedSubtitles);
      final thumbnailPath =
          _resolveLibraryMediaType(candidate, outputPath) == MediaType.video
          ? await _copyLibraryThumbnailArtifact(
              candidate: candidate,
              thumbnailDir: thumbnailDir,
            )
          : null;

      final item = VideoItem(
        id: _uuid.v4(),
        path: outputPath,
        title: _resolveLibraryItemTitle(candidate, outputPath),
        thumbnailPath: thumbnailPath,
        durationMs: 0,
        lastUpdated: DateTime.now().millisecondsSinceEpoch,
        parentId: targetFolderId,
        subtitlePath: defaultSubtitlePath,
        additionalSubtitles: additionalSubtitles,
        usesManagedAssociatedSubtitles: copiedSubtitles.isNotEmpty,
        codec: _inferLibraryCodec(candidate),
        type: _resolveLibraryMediaType(candidate, outputPath),
        sourceRef: candidate.sourceRef,
      );
      final videoId = await library.addSingleVideo(item, useOriginalPath: true);
      if (videoId != null && videoId.isNotEmpty) {
        await _deleteExportedSubtitleSidecars(candidate, outputPath);
        importedCount += 1;
        importedTaskIds.add(candidate.taskId);
      }
    }
    if (importedTaskIds.isNotEmpty) {
      for (var i = 0; i < tasks.length; i++) {
        final candidate = tasks[i];
        if (!importedTaskIds.contains(candidate.taskId)) {
          continue;
        }
        tasks[i] = candidate.copyWith(
          status: YtDlpTaskStatus.exported,
          errorMessage: null,
        );
      }
      await saveTasks();
    }
    return importedCount;
  }

  Future<Directory> _resolveOutputDirectory([
    DownloadSessionConfig? config,
  ]) async {
    final effectiveConfig = config ?? _sessionConfig;
    if (Platform.isAndroid) {
      final docDir = await getApplicationDocumentsDirectory();
      final dir = Directory(p.join(docDir.path, 'yt_dlp_downloads'));
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      return dir;
    }
    final customDir = effectiveConfig.outputDirectory;
    if (customDir != null && customDir.trim().isNotEmpty) {
      final dir = Directory(customDir);
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      return dir;
    }

    if (Platform.isWindows) {
      final dataRoot = await SettingsService().resolveLargeDataRootDir();
      final dir = Directory(p.join(dataRoot.path, 'yt_dlp_downloads'));
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      return dir;
    }

    final docDir = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docDir.path, 'yt_dlp_downloads'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<Directory> _resolveCookiesDirectory() async {
    if (Platform.isWindows) {
      final dataRoot = await SettingsService().resolveLargeDataRootDir();
      final dir = Directory(p.join(dataRoot.path, 'yt_dlp_cookies'));
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      return dir;
    }

    final docDir = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docDir.path, 'yt_dlp_cookies'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  void _syncKeepAwake() {
    _refreshTaskMetrics();
    if (!supportsProcessingKeepAwakeToggle) return;
    final shouldKeepAwake =
        keepScreenAwakeDuringProcessing && hasProcessingTasks;
    if (_lastAppliedKeepAwakeActive == shouldKeepAwake) {
      return;
    }
    _lastAppliedKeepAwakeActive = shouldKeepAwake;
    AppWakelockCoordinator.setActive(
      AppWakelockCoordinator.ytDlpDownloadReason,
      shouldKeepAwake,
    );
  }

  Future<void> refreshBinaryStatus() async {
    await ensureReady(activatePage: true, requireRuntime: true);
    await _ensureRuntimeReady(forceRefresh: true);
  }

  Future<YtDlpBinaryReleaseInfo?> refreshLatestYtDlpRelease() async {
    if (!supportsOnlineYtDlpUpdate) {
      _latestYtDlpRelease = null;
      _ytDlpUpdateError = null;
      notifyListeners();
      return null;
    }
    try {
      final release = await _binaryUpdater.fetchLatestRelease();
      _latestYtDlpRelease = release;
      _ytDlpUpdateError = null;
      notifyListeners();
      return release;
    } catch (error) {
      _ytDlpUpdateError = error.toString();
      notifyListeners();
      rethrow;
    }
  }

  Future<YtDlpBinaryUpdateResult> updateYtDlpToLatest() async {
    await ensureReady(activatePage: true, requireRuntime: true);
    if (!supportsOnlineYtDlpUpdate) {
      throw UnsupportedError('当前平台不支持在线更新 yt-dlp');
    }
    if (_isUpdatingYtDlp) {
      throw StateError('yt-dlp 正在更新中');
    }
    if (isResolving || hasProcessingTasks) {
      throw StateError('请先等待当前解析或下载任务结束后再更新 yt-dlp');
    }

    _isUpdatingYtDlp = true;
    _ytDlpUpdateProgress = 0;
    _ytDlpUpdateStage = '正在检查最新版本';
    _ytDlpUpdateError = null;
    notifyListeners();
    try {
      final result = await _binaryUpdater.updateToLatest(
        currentVersion: _binaryStatus.ytDlpVersion,
        currentBinaryPath: _binaryStatus.ytDlpPath,
        onProgress: (progress) {
          _ytDlpUpdateStage = '正在下载 yt-dlp';
          _ytDlpUpdateProgress = progress;
          notifyListeners();
        },
      );
      _ytDlpUpdateStage = '正在应用更新';
      _ytDlpUpdateProgress = 1;
      notifyListeners();
      _latestYtDlpRelease = result.release;
      _runtimePrepared = false;
      await _ensureRuntimeReady(forceRefresh: true);
      return result;
    } catch (error) {
      _ytDlpUpdateError = error.toString();
      rethrow;
    } finally {
      _isUpdatingYtDlp = false;
      _ytDlpUpdateProgress = null;
      _ytDlpUpdateStage = '准备更新';
      notifyListeners();
    }
  }

  String? _normalizeBinaryVersion(String? version) {
    final normalized = version?.trim();
    if (normalized == null || normalized.isEmpty) {
      return null;
    }
    return normalized.replaceFirst(RegExp(r'^v', caseSensitive: false), '');
  }

  Future<void> _handleTaskEvent(DownloadTaskEvent event) async {
    if (_shouldThrottleTaskEvent(event)) {
      return;
    }
    final index = _indexOfTask(event.taskId);
    if (index < 0) return;

    final current = tasks[index];
    final normalizedStatusMessage = _normalizeTaskStatusMessage(event);
    final updatedStepMessages = _appendTaskStepMessage(
      current.stepMessages,
      normalizedStatusMessage,
    );
    final isPauseTransition = current.status == YtDlpTaskStatus.pausing;
    final isLateActiveEvent =
        event.type == 'task_queued' ||
        event.type == 'task_started' ||
        event.type == 'task_step' ||
        event.type == 'task_progress' ||
        event.type == 'task_post_processing';
    if (isPauseTransition && isLateActiveEvent) {
      tasks[index] = current.copyWith(
        progress: event.progress ?? current.progress,
        downloadedBytes: event.downloadedBytes ?? current.downloadedBytes,
        totalBytes: event.totalBytes ?? current.totalBytes,
        speedText: event.speedText ?? current.speedText,
        etaText: event.etaText ?? current.etaText,
        outputPath: event.outputPath ?? current.outputPath,
        statusMessage: normalizedStatusMessage ?? current.statusMessage,
        stepMessages: updatedStepMessages,
        errorMessage: '正在暂停...',
      );
      if (event.type == 'task_progress') {
        _notifyProgressUpdate();
      } else {
        await saveTasks();
      }
      return;
    }
    final nextStatus = _mapEventTypeToStatus(event.type, current.status);
    final updated = current.copyWith(
      status: nextStatus,
      progress: event.progress ?? current.progress,
      downloadedBytes: event.downloadedBytes ?? current.downloadedBytes,
      totalBytes: event.totalBytes ?? current.totalBytes,
      speedText: event.speedText ?? current.speedText,
      etaText: event.etaText ?? current.etaText,
      outputPath: event.outputPath ?? current.outputPath,
      producedPaths: _orderedUniqueStrings([
        ...current.producedPaths,
        ...event.producedPaths,
      ]),
      statusMessage: normalizedStatusMessage ?? current.statusMessage,
      stepMessages: updatedStepMessages,
      errorMessage:
          event.type == 'task_failed' ||
              event.type == 'task_cancelled' ||
              event.type == 'task_paused'
          ? normalizedStatusMessage ?? event.message ?? current.errorMessage
          : event.type == 'task_completed'
          ? null
          : current.errorMessage,
      failureType: event.type == 'task_failed'
          ? _mapFailureText(event.message ?? event.errorCode ?? '')
          : event.type == 'task_cancelled'
          ? YtDlpFailureType.userCancelled
          : current.failureType,
      failureContext: event.type == 'task_failed'
          ? _buildFailureContext(current, event)
          : current.failureContext,
      completedAtIso: event.type == 'task_completed'
          ? DateTime.now().toIso8601String()
          : current.completedAtIso,
      lastFailedAtIso:
          event.type == 'task_failed' || event.type == 'task_cancelled'
          ? DateTime.now().toIso8601String()
          : current.lastFailedAtIso,
    );
    tasks[index] = updated;
    if (Platform.isAndroid &&
        (event.type == 'task_failed' || event.type == 'task_cancelled')) {
      await _cleanupAndroidArtifactsForTask(updated, forgetTrackedKey: true);
      tasks[index] = tasks[index].copyWith(
        tempArtifactKey: null,
        outputPath: await _isAndroidTempPath(updated.outputPath)
            ? null
            : tasks[index].outputPath,
      );
    }
    if (event.type == 'task_progress') {
      _notifyProgressUpdate();
    } else {
      await saveTasks();
    }
    if (Platform.isAndroid &&
        event.type == 'task_completed' &&
        current.tempArtifactKey != null) {
      final stagedProgress = current.progress < 0.99 ? current.progress : 0.99;
      final staging = current.copyWith(
        status: YtDlpTaskStatus.postProcessing,
        progress: stagedProgress,
        downloadedBytes: event.downloadedBytes ?? current.downloadedBytes,
        totalBytes: event.totalBytes ?? current.totalBytes,
        speedText: event.speedText ?? current.speedText,
        etaText: null,
        outputPath: event.outputPath ?? current.outputPath,
        statusMessage: '下载完成，正在本地收尾...',
        stepMessages: _appendTaskStepMessage(
          current.stepMessages,
          '下载完成，正在本地收尾...',
        ),
        errorMessage: '下载完成，正在本地收尾...',
        completedAtIso: current.completedAtIso,
      );
      tasks[index] = staging;
      await saveTasks();
      final finalized = await _finalizeAndroidTask(
        staging,
        hintedProducedPaths: event.producedPaths,
      );
      final finalIndex = _indexOfTask(event.taskId);
      if (finalIndex >= 0 && finalized != null) {
        tasks[finalIndex] = finalized;
        await saveTasks();
        if (finalized.status == YtDlpTaskStatus.completed) {
          await _handleCompletedTaskAutomation(finalized);
        }
      }
      await _tryStartNextQueuedTask(excludingTaskId: event.taskId);
      return;
    }
    if (event.type == 'task_completed') {
      await _handleCompletedTaskAutomation(updated);
    }

    if (event.type == 'task_failed') {
      final didFallback = await _tryAutoFallback(updated);
      if (didFallback) {
        return;
      }
    }

    if (event.type == 'task_paused' ||
        event.type == 'task_completed' ||
        event.type == 'task_failed' ||
        event.type == 'task_cancelled') {
      await _tryStartNextQueuedTask(excludingTaskId: event.taskId);
    }
  }

  Future<void> _handleCompletedTaskAutomation(YtDlpTaskRecord task) async {
    if (!_downloadPreferences.autoImportToLibrary) {
      return;
    }
    try {
      final importedCount = await importToLibrary(task: task);
      if (importedCount <= 0) {
        await _markAutoImportFailure(task.taskId, '自动导入未成功：未找到可导入的视频文件');
        return;
      }
      if (!_downloadPreferences.autoDeleteTaskAfterImport) {
        return;
      }
      final current = tasks
          .where((item) => item.taskId == task.taskId)
          .cast<YtDlpTaskRecord?>()
          .firstOrNull;
      if (current == null) {
        return;
      }
      await removeTask(current, deleteCompletedOutput: false);
    } catch (e) {
      final message = '自动导入失败: $e';
      debugPrint(message);
      await _markAutoImportFailure(task.taskId, message);
    }
  }

  Future<void> _markAutoImportFailure(String taskId, String message) async {
    final index = _indexOfTask(taskId);
    if (index < 0) {
      return;
    }
    final current = tasks[index];
    tasks[index] = current.copyWith(
      statusMessage: message,
      errorMessage: message,
      stepMessages: _appendTaskStepMessage(current.stepMessages, message),
    );
    await saveTasks();
  }

  YtDlpTaskStatus _mapEventTypeToStatus(String type, YtDlpTaskStatus fallback) {
    switch (type) {
      case 'task_queued':
        return YtDlpTaskStatus.queued;
      case 'task_started':
      case 'task_step':
      case 'task_progress':
        return YtDlpTaskStatus.downloading;
      case 'task_paused':
        return YtDlpTaskStatus.paused;
      case 'task_post_processing':
        return YtDlpTaskStatus.postProcessing;
      case 'task_completed':
        return YtDlpTaskStatus.completed;
      case 'task_failed':
        return YtDlpTaskStatus.failed;
      case 'task_cancelled':
        return YtDlpTaskStatus.cancelled;
      case 'task_retrying':
        return YtDlpTaskStatus.queued;
      default:
        return fallback;
    }
  }

  Map<String, dynamic> _safeDecodeMap(String raw) {
    try {
      return Map<String, dynamic>.from(jsonDecode(raw) as Map);
    } catch (_) {
      return <String, dynamic>{};
    }
  }

  Map<String, dynamic> _extractRawInfo(Map<String, dynamic> payload) {
    final structured = payload['rawInfo'];
    if (structured is Map) {
      return Map<String, dynamic>.from(structured);
    }
    final rawJson = payload['rawInfoJson']?.toString();
    if (rawJson != null && rawJson.isNotEmpty) {
      return _safeDecodeMap(rawJson);
    }
    return payload;
  }

  List<DownloadSessionConfig> _buildResolveAttemptConfigs(
    DownloadSessionConfig config,
  ) {
    final normalized = _normalizeLoadedSessionConfig(config);
    final attempts = <DownloadSessionConfig>[normalized];
    final safer = _buildSaferResolveConfig(normalized);
    if (!_sameSessionConfig(normalized, safer)) {
      attempts.add(safer);
    }
    return attempts;
  }

  DownloadSessionConfig _buildSaferResolveConfig(DownloadSessionConfig config) {
    final hasPlayerClients = config.enabledPlayerClients.any(
      (item) => item.trim().isNotEmpty,
    );
    final hasVisitorData = config.visitorData?.trim().isNotEmpty ?? false;
    final hasPoToken = config.poTokens.any(
      (item) => item.enabled && item.hasValue,
    );
    if (!hasPlayerClients && !hasVisitorData && !hasPoToken) {
      return config;
    }
    return config.copyWith(
      enabledPlayerClients: const [],
      visitorData: null,
      poTokens: const [],
    );
  }

  bool _shouldRetryResolveWithSaferConfig(
    Object error,
    DownloadSessionConfig attemptedConfig,
    DownloadSessionConfig saferConfig,
  ) {
    if (_sameSessionConfig(attemptedConfig, saferConfig)) {
      return false;
    }
    final lower = error.toString().toLowerCase();
    if (lower.contains('timeout') ||
        lower.contains('timed out') ||
        lower.contains('network') ||
        lower.contains('socket') ||
        lower.contains('proxy')) {
      return false;
    }
    const riskyKeywords = <String>[
      'player_client',
      'player client',
      'visitor_data',
      'visitor data',
      'po_token',
      'po token',
      'unable to extract',
      'extract',
      'sign in',
      'requested format',
      'format',
      'youtube',
      '403',
      'forbidden',
      'metadata',
      '元数据',
    ];
    return riskyKeywords.any(lower.contains);
  }

  DownloadSessionConfig _normalizeLoadedSessionConfig(
    DownloadSessionConfig config,
  ) {
    var normalized = config;
    final hasLegacyForcedClients =
        _sameStringList(normalized.enabledPlayerClients, const [
          'tv_embedded',
          'mweb',
        ]) &&
        !(normalized.visitorData?.trim().isNotEmpty ?? false) &&
        !normalized.poTokens.any((item) => item.enabled && item.hasValue) &&
        !normalized.useCookies &&
        !normalized.useCustomUserAgent &&
        !normalized.useProxy;
    if (hasLegacyForcedClients) {
      normalized = normalized.copyWith(enabledPlayerClients: const []);
    }
    if (normalized.useCookies &&
        !(normalized.cookiesFilePath?.trim().isNotEmpty ?? false)) {
      normalized = normalized.copyWith(
        useCookies: false,
        cookiesFilePath: null,
      );
    }
    if (normalized.useCustomUserAgent &&
        !(normalized.userAgent?.trim().isNotEmpty ?? false)) {
      normalized = normalized.copyWith(
        useCustomUserAgent: false,
        userAgent: null,
      );
    }
    if (normalized.useProxy &&
        !(normalized.proxy?.trim().isNotEmpty ?? false)) {
      normalized = normalized.copyWith(useProxy: false, proxy: null);
    }
    if (Platform.isAndroid && normalized.outputDirectory != null) {
      normalized = normalized.copyWith(outputDirectory: null);
    }
    return normalized;
  }

  bool _sameSessionConfig(
    DownloadSessionConfig left,
    DownloadSessionConfig right,
  ) {
    return _encodeMap(left.toJson()) == _encodeMap(right.toJson());
  }

  bool _sameStringList(List<String> left, List<String> right) {
    if (left.length != right.length) {
      return false;
    }
    for (var i = 0; i < left.length; i++) {
      if (left[i] != right[i]) {
        return false;
      }
    }
    return true;
  }

  DownloadFailureContext _buildFailureContext(
    YtDlpTaskRecord task,
    DownloadTaskEvent event,
  ) {
    final activeConfig = task.executionSessionConfig ?? _sessionConfig;
    return DownloadFailureContext(
      url: task.sourceUrl,
      extractor: task.meta?.source,
      selectedPlayerClient: activeConfig.enabledPlayerClients.isNotEmpty
          ? activeConfig.enabledPlayerClients.first
          : null,
      hasCookies: activeConfig.useCookies,
      hasProxy: activeConfig.useProxy,
      hasUserAgent: activeConfig.useCustomUserAgent,
      hasVisitorData: (activeConfig.visitorData?.isNotEmpty ?? false),
      hasPoToken: activeConfig.poTokens.any(
        (item) => item.enabled && item.hasValue,
      ),
      retryCount: task.fallbackAttemptCount,
      stderrTail: event.message,
      exitCode: _parseExitCode(event.errorCode),
    );
  }

  int? _parseExitCode(String? errorCode) {
    if (errorCode == null || !errorCode.startsWith('EXIT_')) {
      return null;
    }
    return int.tryParse(errorCode.substring(5));
  }

  String? _currentEnvironmentError({bool requireFfmpeg = false}) {
    if (!_binaryStatus.ytDlpReady) {
      final platformHint = Platform.isAndroid
          ? '当前 Android 运行时尚未就绪；应用现在改为通过内嵌 Python 运行 yt-dlp，需要构建时成功安装 Chaquopy 与 yt-dlp 模块。'
          : '当前平台未找到 yt-dlp 可执行文件。';
      final detail = _binaryStatus.diagnosticMessage?.trim();
      if (detail != null && detail.isNotEmpty) {
        return '$platformHint\n$detail';
      }
      return platformHint;
    }

    if (requireFfmpeg && !Platform.isAndroid && !_binaryStatus.ffmpegReady) {
      final detail = _binaryStatus.diagnosticMessage?.trim();
      final base = '当前平台未找到 ffmpeg，可解析但无法进行合并/转封装/音频提取/字幕嵌入等后处理。';
      if (detail != null && detail.isNotEmpty) {
        return '$base\n$detail';
      }
      return base;
    }

    return null;
  }

  bool get _shouldUseAndroidStagedFallback =>
      Platform.isAndroid && !_binaryStatus.ffmpegReady;

  static const Duration _activeTaskProgressThrottle = Duration(
    milliseconds: 250,
  );
  static const Duration _backgroundTaskProgressThrottle = Duration(
    milliseconds: 500,
  );

  Duration _effectiveTaskEventThrottleWindow() {
    if (!Platform.isWindows) {
      return _isPageActive
          ? _activeTaskProgressThrottle
          : _backgroundTaskProgressThrottle;
    }
    if (tasks.length >= 60) {
      return _isPageActive
          ? const Duration(milliseconds: 650)
          : const Duration(milliseconds: 1200);
    }
    if (tasks.length >= 25) {
      return _isPageActive
          ? const Duration(milliseconds: 450)
          : const Duration(milliseconds: 900);
    }
    return _isPageActive
        ? const Duration(milliseconds: 320)
        : const Duration(milliseconds: 650);
  }

  void _rebuildTaskIndex() {
    _taskIndexById.clear();
    for (var i = 0; i < tasks.length; i++) {
      _taskIndexById[tasks[i].taskId] = i;
    }
    // 同步更新缓存的任务 ID 列表
    _cachedTaskIds = tasks.map((t) => t.taskId).toList(growable: false);
  }

  /// 获取缓存的任务 ID 列表，仅在任务结构变更时更新
  List<String> get taskIds => _cachedTaskIds;

  int _indexOfTask(String taskId) {
    return _taskIndexById[taskId] ?? -1;
  }

  YtDlpTaskRecord? getTaskById(String taskId) {
    final idx = _taskIndexById[taskId];
    return idx != null ? tasks[idx] : null;
  }

  /// 计算任务卡片的渲染签名（整数哈希），仅在渲染相关属性变更时变化
  /// 用于 Selector 的 shouldRebuild 判断，避免不必要的 UI 重建
  int taskRenderSignature(String taskId) {
    final task = getTaskById(taskId);
    if (task == null) return 0;
    var hash = task.taskId.hashCode;
    hash = _combineHash(hash, task.status.index);
    hash = _combineHash(hash, task.isSelected.hashCode);
    hash = _combineHash(hash, (task.progress * 1000).round());
    hash = _combineHash(hash, task.speedText?.hashCode ?? 0);
    hash = _combineHash(hash, task.etaText?.hashCode ?? 0);
    hash = _combineHash(hash, task.statusMessage?.hashCode ?? 0);
    hash = _combineHash(hash, task.errorMessage?.hashCode ?? 0);
    hash = _combineHash(hash, task.outputPath?.hashCode ?? 0);
    hash = _combineHash(hash, task.failureType.index);
    hash = _combineHash(hash, task.meta?.title.hashCode ?? 0);
    hash = _combineHash(hash, task.selection.hashCode);
    hash = _combineHash(hash, task.stepMessages.length);
    hash = _combineHash(hash, task.taskThumbnailPath?.hashCode ?? 0);
    return hash;
  }

  static int _combineHash(int current, int value) {
    return current ^ (value * 0x9e3779b97f4a7c15).toInt() +
        0x9e3779b9 + (current << 6) + (current >> 2);
  }

  bool _shouldThrottleTaskEvent(DownloadTaskEvent event) {
    if (event.type != 'task_progress') {
      _lastTaskEventAt[event.taskId] = DateTime.now();
      return false;
    }
    final now = DateTime.now();
    final last = _lastTaskEventAt[event.taskId];
    final throttleWindow = _effectiveTaskEventThrottleWindow();
    if (last != null && now.difference(last) < throttleWindow) {
      return true;
    }
    _lastTaskEventAt[event.taskId] = now;
    return false;
  }

  String? _normalizeTaskStatusMessage(DownloadTaskEvent event) {
    final raw = event.message?.trim();
    String? message = raw;
    switch (event.type) {
      case 'task_queued':
        message ??= '已加入下载队列';
        break;
      case 'task_started':
        message ??= '开始下载';
        break;
      case 'task_step':
      case 'task_progress':
      case 'task_post_processing':
        break;
      case 'task_paused':
        message ??= '已暂停';
        break;
      case 'task_completed':
        message ??= '下载完成';
        break;
      case 'task_failed':
        message ??= '下载失败';
        break;
      case 'task_cancelled':
        message ??= '已取消';
        break;
      case 'task_retrying':
        message ??= '正在重试';
        break;
    }
    if (message == null || message.isEmpty) {
      return null;
    }
    final lower = message.toLowerCase();
    if (RegExp(r'^\[download\]\s+\d+(?:\.\d+)?%').hasMatch(lower)) {
      return null;
    }
    if (lower == 'downloading') {
      return '下载中';
    }
    if (lower == 'starting') {
      return '开始下载';
    }
    if (lower == 'queued') {
      return '已加入下载队列';
    }
    if (lower == 'completed') {
      return '下载完成';
    }
    if (lower == 'cancelled') {
      return '已取消';
    }
    if (lower == 'paused') {
      return '已暂停';
    }
    if (message.startsWith('ERROR:')) {
      message = message.substring(6).trim();
    }
    message = _shortenTaskStatusMessage(message);
    return message.isEmpty ? null : message;
  }

  List<String> _appendTaskStepMessage(List<String> current, String? message) {
    if (message == null || message.trim().isEmpty) {
      return current;
    }
    final normalized = message.trim();
    final next = <String>[...current];
    final nextKey = _taskStepMessageKey(normalized);
    if (next.isNotEmpty && _taskStepMessageKey(next.last) == nextKey) {
      return current;
    }
    final existingIndex = next.indexWhere(
      (item) => _taskStepMessageKey(item) == nextKey,
    );
    if (existingIndex >= 0) {
      next.removeAt(existingIndex);
    }
    next.add(normalized);
    if (next.length > 4) {
      next.removeRange(0, next.length - 4);
    }
    return next;
  }

  String _taskStepMessageKey(String message) {
    return message.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  String _shortenTaskStatusMessage(String raw) {
    var message = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
    final quotedPathMatch = RegExp(r'"([^"]+)"').firstMatch(message);
    if (quotedPathMatch != null) {
      final fullPath = quotedPathMatch.group(1);
      if (fullPath != null && fullPath.isNotEmpty) {
        message = message.replaceFirst(fullPath, p.basename(fullPath));
      }
    }
    const maxLength = 96;
    if (message.length <= maxLength) {
      return message;
    }
    return '${message.substring(0, maxLength - 3)}...';
  }

  bool _hasActiveTask({String? excludingTaskId}) {
    return tasks.any(
      (item) =>
          item.taskId != excludingTaskId &&
          _isActiveExecutionStatus(item.status),
    );
  }

  bool _hasBlockingTask({String? excludingTaskId}) {
    return tasks.any(
      (item) =>
          item.taskId != excludingTaskId && _isBlockingStatus(item.status),
    );
  }

  bool _isActiveExecutionStatus(YtDlpTaskStatus status) {
    return status == YtDlpTaskStatus.pausing ||
        status == YtDlpTaskStatus.downloading ||
        status == YtDlpTaskStatus.postProcessing ||
        status == YtDlpTaskStatus.resolving;
  }

  bool _isBlockingStatus(YtDlpTaskStatus status) {
    return _isActiveExecutionStatus(status);
  }

  int _priorityInsertIndex() {
    final blockingIndex = tasks.indexWhere(
      (item) => _isActiveExecutionStatus(item.status),
    );
    if (blockingIndex < 0) {
      return 0;
    }
    return blockingIndex + 1;
  }

  Future<void> _tryStartNextQueuedTask({String? excludingTaskId}) async {
    if (_hasBlockingTask(excludingTaskId: excludingTaskId)) {
      return;
    }
    final nextTask = tasks.firstWhere(
      (item) =>
          item.taskId != excludingTaskId &&
          item.status == YtDlpTaskStatus.queued &&
          item.meta != null,
      orElse: () => const YtDlpTaskRecord(
        taskId: '',
        sourceUrl: '',
        selection: DownloadSelection(),
        createdAtIso: '',
      ),
    );
    if (nextTask.taskId.isEmpty) {
      return;
    }
    await _launchQueuedTask(nextTask.taskId);
  }

  Future<void> _persistTaskState({SharedPreferences? prefs}) async {
    final targetPrefs = prefs ?? await SharedPreferences.getInstance();
    // 先在主线程转换为 JSON 基本类型
    final tasksMaps = tasks.map((t) => t.toJson()).toList();
    final completedMaps =
        recentCompletedTasks.map((t) => t.toJson()).toList();
    final failedMaps = recentFailedTasks.map((t) => t.toJson()).toList();
    // 在后台 Isolate 中并行执行 JSON 编码，避免主线程卡顿
    final results = await Future.wait([
      compute(_encodeJsonMaps, tasksMaps),
      compute(_encodeJsonMaps, completedMaps),
      compute(_encodeJsonMaps, failedMaps),
    ]);
    // 顺序写入 SharedPreferences
    await targetPrefs.setString(_tasksPrefsKey, results[0]);
    await targetPrefs.setString(
      _completedTasksPrefsKey,
      results[1],
    );
    await targetPrefs.setString(
      _failedTasksPrefsKey,
      results[2],
    );
  }

  void _refreshHistorySnapshots() {
    for (final task in tasks) {
      if (task.status == YtDlpTaskStatus.completed ||
          task.status == YtDlpTaskStatus.exported) {
        _upsertHistoryRecord(
          recentCompletedTasks,
          task,
          sortKey: (item) => item.completedAtIso ?? item.createdAtIso,
        );
      }
      if (task.status == YtDlpTaskStatus.failed ||
          task.status == YtDlpTaskStatus.cancelled) {
        _upsertHistoryRecord(
          recentFailedTasks,
          task,
          sortKey: (item) => item.lastFailedAtIso ?? item.createdAtIso,
        );
      }
    }
  }

  void _upsertHistoryRecord(
    List<YtDlpTaskRecord> target,
    YtDlpTaskRecord task, {
    required String Function(YtDlpTaskRecord item) sortKey,
  }) {
    final existingIndex = target.indexWhere(
      (item) => item.taskId == task.taskId,
    );
    if (existingIndex >= 0) {
      target[existingIndex] = task;
    } else {
      target.add(task);
    }
    target.sort((a, b) => sortKey(b).compareTo(sortKey(a)));
    if (target.length > _maxHistoryItems) {
      target.removeRange(_maxHistoryItems, target.length);
    }
  }

  Future<bool> _tryAutoFallback(YtDlpTaskRecord task) async {
    if (!_isRecoverableFailure(task.failureType)) {
      return false;
    }
    if (task.fallbackAttemptCount >= _maxFallbackAttempts) {
      return false;
    }

    final fallbackTask = _buildFallbackTask(task);
    if (fallbackTask == null) {
      return false;
    }

    final index = _indexOfTask(task.taskId);
    if (index < 0) {
      return false;
    }

    final step = fallbackTask.appliedFallbackSteps.last;
    tasks[index] = fallbackTask.copyWith(
      status: YtDlpTaskStatus.queued,
      errorMessage:
          '已触发回退(${_fallbackStepLabel(step)})，准备第 ${fallbackTask.fallbackAttemptCount}/$_maxFallbackAttempts 次重试',
      failureType: task.failureType,
      failureContext: task.failureContext,
      completedAtIso: null,
    );
    await saveTasks();

    await Future<void>.delayed(
      _buildRetryDelay(fallbackTask.fallbackAttemptCount),
    );
    if (_hasBlockingTask(excludingTaskId: task.taskId)) {
      return true;
    }
    await _launchQueuedTask(task.taskId);
    return true;
  }

  Duration _buildRetryDelay(int retryCount) {
    if (retryCount <= 1) {
      return const Duration(seconds: 1);
    }
    if (retryCount == 2) {
      return const Duration(seconds: 2);
    }
    if (retryCount == 3) {
      return const Duration(seconds: 4);
    }
    return const Duration(seconds: 6);
  }

  bool _isRecoverableFailure(YtDlpFailureType type) {
    switch (type) {
      case YtDlpFailureType.networkTimeout:
      case YtDlpFailureType.extractionFailed:
      case YtDlpFailureType.authFailed:
      case YtDlpFailureType.proxyFailed:
      case YtDlpFailureType.noFormatAvailable:
      case YtDlpFailureType.unknown:
        return true;
      case YtDlpFailureType.none:
      case YtDlpFailureType.postProcessingFailed:
      case YtDlpFailureType.fileWriteFailed:
      case YtDlpFailureType.userCancelled:
      case YtDlpFailureType.unsupported:
        return false;
    }
  }

  YtDlpTaskRecord? _buildFallbackTask(YtDlpTaskRecord task) {
    var attempt = task.fallbackAttemptCount;
    final applied = [...task.appliedFallbackSteps];
    final currentConfig = task.executionSessionConfig ?? _sessionConfig;

    for (final step in YtDlpFallbackStep.values) {
      if (applied.contains(step)) {
        continue;
      }
      final nextConfig = _applyFallbackStep(step, currentConfig);
      if (nextConfig == null) {
        continue;
      }
      applied.add(step);
      attempt += 1;
      return task.copyWith(
        executionSessionConfig: nextConfig,
        fallbackAttemptCount: attempt,
        appliedFallbackSteps: applied,
        request: null,
        downloadedBytes: null,
        totalBytes: null,
        speedText: null,
        etaText: null,
      );
    }
    return null;
  }

  DownloadSessionConfig? _applyFallbackStep(
    YtDlpFallbackStep step,
    DownloadSessionConfig currentConfig,
  ) {
    switch (step) {
      case YtDlpFallbackStep.originalRetry:
        return currentConfig;
      case YtDlpFallbackStep.reduceConcurrentFragments:
        final current = currentConfig.concurrentFragments;
        if (current == 1) {
          return null;
        }
        return currentConfig.copyWith(
          concurrentFragments: current == null
              ? 1
              : current > 1
              ? 1
              : current,
        );
      case YtDlpFallbackStep.increaseTimeout:
        final timeout = currentConfig.socketTimeoutSeconds;
        final nextTimeout = timeout == null
            ? 60
            : timeout >= 120
            ? null
            : timeout + 30;
        if (nextTimeout == null) {
          return null;
        }
        return currentConfig.copyWith(socketTimeoutSeconds: nextTimeout);
      case YtDlpFallbackStep.applyRateLimit:
        if ((currentConfig.rateLimit?.trim().isNotEmpty ?? false)) {
          return null;
        }
        return currentConfig.copyWith(rateLimit: '2M');
      case YtDlpFallbackStep.switchPlayerClient:
        final currentClients = currentConfig.enabledPlayerClients
            .map((item) => item.trim())
            .where((item) => item.isNotEmpty)
            .toList();
        final activeClient = currentClients.isEmpty
            ? null
            : currentClients.first;
        final nextClient = _fallbackPlayerClientCandidates.firstWhere(
          (candidate) => candidate != activeClient,
          orElse: () => '',
        );
        if (nextClient.isEmpty) {
          return null;
        }
        final nextClients = [
          nextClient,
          ...currentClients.where((item) => item != nextClient),
        ];
        return currentConfig.copyWith(enabledPlayerClients: nextClients);
      case YtDlpFallbackStep.enableCookies:
        if (currentConfig.useCookies) {
          return null;
        }
        final path =
            currentConfig.cookiesFilePath ?? _sessionConfig.cookiesFilePath;
        if (path == null || path.trim().isEmpty) {
          return null;
        }
        return currentConfig.copyWith(useCookies: true, cookiesFilePath: path);
      case YtDlpFallbackStep.applyCustomUserAgent:
        if (currentConfig.useCustomUserAgent &&
            (currentConfig.userAgent?.trim().isNotEmpty ?? false)) {
          return null;
        }
        final userAgent = (currentConfig.userAgent?.trim().isNotEmpty ?? false)
            ? currentConfig.userAgent!.trim()
            : (_sessionConfig.userAgent?.trim().isNotEmpty ?? false)
            ? _sessionConfig.userAgent!.trim()
            : _fallbackUserAgent;
        return currentConfig.copyWith(
          useCustomUserAgent: true,
          userAgent: userAgent,
        );
      case YtDlpFallbackStep.injectVisitorData:
        if (currentConfig.visitorData?.trim().isNotEmpty ?? false) {
          return null;
        }
        final visitorData = _sessionConfig.visitorData?.trim();
        if (visitorData == null || visitorData.isEmpty) {
          return null;
        }
        return currentConfig.copyWith(visitorData: visitorData);
      case YtDlpFallbackStep.injectPoToken:
        final hasToken = currentConfig.poTokens.any(
          (item) => item.enabled && item.hasValue,
        );
        if (hasToken) {
          return null;
        }
        final tokens = _sessionConfig.poTokens
            .where((item) => item.enabled && item.hasValue)
            .toList();
        if (tokens.isEmpty) {
          return null;
        }
        return currentConfig.copyWith(poTokens: tokens);
      case YtDlpFallbackStep.switchProxy:
        if (currentConfig.useProxy) {
          return null;
        }
        final proxy = (currentConfig.proxy?.trim().isNotEmpty ?? false)
            ? currentConfig.proxy!.trim()
            : _sessionConfig.proxy?.trim();
        if (proxy == null || proxy.isEmpty) {
          return null;
        }
        return currentConfig.copyWith(useProxy: true, proxy: proxy);
    }
  }

  String _fallbackStepLabel(YtDlpFallbackStep step) {
    switch (step) {
      case YtDlpFallbackStep.originalRetry:
        return '原始配置重试';
      case YtDlpFallbackStep.reduceConcurrentFragments:
        return '降低分片并发';
      case YtDlpFallbackStep.increaseTimeout:
        return '增加超时';
      case YtDlpFallbackStep.applyRateLimit:
        return '附加限速';
      case YtDlpFallbackStep.switchPlayerClient:
        return '切换 Player Client';
      case YtDlpFallbackStep.enableCookies:
        return '启用 Cookies';
      case YtDlpFallbackStep.applyCustomUserAgent:
        return '附加 User-Agent';
      case YtDlpFallbackStep.injectVisitorData:
        return '注入 Visitor Data';
      case YtDlpFallbackStep.injectPoToken:
        return '注入 PO Token';
      case YtDlpFallbackStep.switchProxy:
        return '切换代理';
    }
  }

  YtDlpFailureType _mapFailureText(String text) {
    final lower = text.toLowerCase();
    if (lower.contains('metadata') || lower.contains('元数据')) {
      return YtDlpFailureType.extractionFailed;
    }
    if (lower.contains('timed out') || lower.contains('timeout')) {
      return YtDlpFailureType.networkTimeout;
    }
    if (lower.contains('proxy')) {
      return YtDlpFailureType.proxyFailed;
    }
    if (lower.contains('login') ||
        lower.contains('sign in') ||
        lower.contains('cookies') ||
        lower.contains('403') ||
        lower.contains('401')) {
      return YtDlpFailureType.authFailed;
    }
    if (lower.contains('requested format') ||
        lower.contains('no video formats') ||
        lower.contains('no suitable format') ||
        lower.contains('formats not available')) {
      return YtDlpFailureType.noFormatAvailable;
    }
    if (lower.contains('未产出可用媒体文件') ||
        lower.contains('no media artifact') ||
        lower.contains('未找到 yt-dlp 生成的媒体临时文件')) {
      return YtDlpFailureType.postProcessingFailed;
    }
    if (lower.contains('permission denied') ||
        lower.contains('access is denied') ||
        lower.contains('read-only file system')) {
      return YtDlpFailureType.fileWriteFailed;
    }
    if (lower.contains('unsupported') || lower.contains('not supported')) {
      return YtDlpFailureType.unsupported;
    }
    if (lower.contains('cancelled') || lower.contains('canceled')) {
      return YtDlpFailureType.userCancelled;
    }
    if (lower.contains('ffmpeg') || lower.contains('postprocess')) {
      return YtDlpFailureType.postProcessingFailed;
    }
    if (lower.contains('extractorerror') ||
        lower.contains('unable to extract') ||
        lower.contains('failed to extract') ||
        lower.contains('dump-single-json')) {
      return YtDlpFailureType.extractionFailed;
    }
    return YtDlpFailureType.unknown;
  }

  String _failureTypeLabel(YtDlpFailureType type) {
    switch (type) {
      case YtDlpFailureType.networkTimeout:
        return '网络超时';
      case YtDlpFailureType.extractionFailed:
        return '提取失败';
      case YtDlpFailureType.authFailed:
        return '鉴权失败';
      case YtDlpFailureType.proxyFailed:
        return '代理失败';
      case YtDlpFailureType.postProcessingFailed:
        return '后处理失败';
      case YtDlpFailureType.noFormatAvailable:
        return '无可用格式';
      case YtDlpFailureType.fileWriteFailed:
        return '写入失败';
      case YtDlpFailureType.userCancelled:
        return '用户取消';
      case YtDlpFailureType.unsupported:
        return '当前平台不支持';
      case YtDlpFailureType.none:
      case YtDlpFailureType.unknown:
        return '未知错误';
    }
  }

  String _encodeMap(Map<String, dynamic> value) => jsonEncode(value);

  // Legacy staged Android path kept only for rollback/reference.
  // ignore: unused_element
  String _createAndroidTempArtifactKey(YtDlpTaskRecord task) {
    final metaId = task.meta?.id.trim();
    final sourceId = (metaId?.isNotEmpty ?? false) ? metaId! : task.taskId;
    final uuid = _uuid.v4().replaceAll('-', '');
    return '${sourceId}_$uuid';
  }

  String _sanitizeAndroidTempKey(String key) {
    return key.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
  }

  String _androidArtifactPrefix(String key) {
    return '$_androidTempPrefix${_sanitizeAndroidTempKey(key)}_';
  }

  Future<Set<String>> _loadPendingAndroidTempCleanupKeys() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(_pendingAndroidTempCleanupPrefsKey)?.toSet() ??
        <String>{};
  }

  Future<void> _savePendingAndroidTempCleanupKeys(Set<String> keys) async {
    final prefs = await SharedPreferences.getInstance();
    if (keys.isEmpty) {
      await prefs.remove(_pendingAndroidTempCleanupPrefsKey);
      return;
    }
    await prefs.setStringList(
      _pendingAndroidTempCleanupPrefsKey,
      keys.toList()..sort(),
    );
  }

  Future<void> _addPendingAndroidTempCleanupKey(String key) async {
    final keys = await _loadPendingAndroidTempCleanupKeys();
    if (keys.add(key)) {
      await _savePendingAndroidTempCleanupKeys(keys);
    }
  }

  Future<void> _removePendingAndroidTempCleanupKey(String key) async {
    final keys = await _loadPendingAndroidTempCleanupKeys();
    if (keys.remove(key)) {
      await _savePendingAndroidTempCleanupKeys(keys);
    }
  }

  // ignore: unused_element
  Future<NativeDownloadRequest> _buildAndroidStagedRequest({
    required YtDlpTaskRecord task,
    required NativeDownloadRequest baseRequest,
    required String tempArtifactKey,
  }) async {
    final tempDir = await getTemporaryDirectory();
    if (!await tempDir.exists()) {
      await tempDir.create(recursive: true);
    }
    await _cleanupAndroidTempArtifactsByKey(
      tempArtifactKey,
      removePendingKey: false,
    );
    await _addPendingAndroidTempCleanupKey(tempArtifactKey);

    final prefix = _androidArtifactPrefix(tempArtifactKey);
    final args = _rewriteAndroidRequestArgs(
      baseRequest.args,
      task: task,
      baseRequest: baseRequest,
      tempDirectoryPath: tempDir.path,
      outputTemplate: '$prefix%(format_id)s.%(ext)s',
    );
    return NativeDownloadRequest(
      taskId: baseRequest.taskId,
      url: baseRequest.url,
      outputDir: tempDir.path,
      outputTemplate: '$prefix%(format_id)s.%(ext)s',
      args: args,
      debugContext: {
        ...baseRequest.debugContext,
        'androidTempArtifactKey': tempArtifactKey,
        'androidPostProcessMode': true,
      },
    );
  }

  List<String> _rewriteAndroidRequestArgs(
    List<String> originalArgs, {
    required YtDlpTaskRecord task,
    required NativeDownloadRequest baseRequest,
    required String tempDirectoryPath,
    required String outputTemplate,
  }) {
    final args = <String>[];
    for (var i = 0; i < originalArgs.length; i++) {
      final arg = originalArgs[i];
      switch (arg) {
        case '--paths':
        case '-o':
        case '-f':
        case '--merge-output-format':
        case '--postprocessor-args':
        case '--audio-format':
          i += 1;
          continue;
        case '--embed-metadata':
        case '--embed-subs':
        case '--extract-audio':
          continue;
      }
      if (arg == task.sourceUrl || arg == baseRequest.url) {
        continue;
      }
      args.add(arg);
    }
    args.addAll(['--paths', tempDirectoryPath]);
    args.addAll(_buildAndroidFormatArgs(task, baseRequest));
    args.addAll(['-o', outputTemplate]);
    args.add(task.sourceUrl);
    return args;
  }

  List<String> _buildAndroidFormatArgs(
    YtDlpTaskRecord task,
    NativeDownloadRequest baseRequest,
  ) {
    final debugContext = baseRequest.debugContext;
    final resolvedVideoId =
        debugContext['resolvedVideoFormatId']?.toString().trim().isNotEmpty ==
            true
        ? debugContext['resolvedVideoFormatId'].toString().trim()
        : null;
    final resolvedAudioIds =
        (debugContext['resolvedAudioFormatIds'] as List? ?? const [])
            .map((item) => item.toString().trim())
            .where((item) => item.isNotEmpty)
            .toList();
    if (task.selection.audioOnly) {
      final audioId = resolvedAudioIds.isNotEmpty
          ? resolvedAudioIds.first
          : null;
      return ['-f', audioId ?? 'bestaudio'];
    }
    if (task.selection.removeAudio) {
      return ['-f', resolvedVideoId ?? 'bestvideo/best'];
    }
    if (resolvedVideoId != null && resolvedAudioIds.isNotEmpty) {
      return ['-f', '$resolvedVideoId+${resolvedAudioIds.first}'];
    }
    if (resolvedVideoId != null) {
      return ['-f', resolvedVideoId];
    }
    if (resolvedAudioIds.isNotEmpty) {
      return ['-f', resolvedAudioIds.first];
    }
    return ['-f', 'bestvideo+bestaudio/best'];
  }

  bool _shouldEmbedSubtitlesForAndroid(YtDlpTaskRecord task) {
    if (!Platform.isAndroid || task.selection.audioOnly) {
      return task.selection.embedSubtitles;
    }
    return task.selection.embedSubtitles ||
        task.selection.selectedSubtitleTrackKeys.isNotEmpty ||
        task.selection.subtitleLanguages.isNotEmpty;
  }

  // ignore: unused_element
  Future<YtDlpTaskRecord?> _finalizeAndroidTask(
    YtDlpTaskRecord task, {
    List<String> hintedProducedPaths = const [],
  }) async {
    final key = task.tempArtifactKey;
    if (key == null || key.isEmpty) {
      return task.copyWith(
        status: YtDlpTaskStatus.failed,
        failureType: YtDlpFailureType.postProcessingFailed,
        errorMessage: 'Android 临时产物追踪信息缺失，无法完成本地后处理',
        lastFailedAtIso: DateTime.now().toIso8601String(),
      );
    }
    String? finalOutputPath;
    try {
      final tempFiles = await _collectAndroidFinalizeFiles(
        task,
        hintedProducedPaths: hintedProducedPaths,
      );
      final selectedSubtitleTracks = _resolvedSubtitleTracksForTask(task);
      final subtitleFiles = _sortAndroidSubtitleFiles(
        tempFiles.where(_isSubtitleFile).toList(),
        selectedSubtitleTracks,
        task.selection.subtitleLanguages,
      );
      final mediaFiles =
          tempFiles.where((file) => !_isSubtitleFile(file)).toList()
            ..sort((a, b) => b.lengthSync().compareTo(a.lengthSync()));
      if (mediaFiles.isEmpty) {
        final hint = task.outputPath?.trim();
        final hintText = (hint != null && hint.isNotEmpty)
            ? '，输出提示路径: $hint'
            : '';
        throw Exception('未找到 yt-dlp 生成的媒体临时文件$hintText');
      }

      final outputDir = await _resolveOutputDirectory(
        task.executionSessionConfig,
      );
      final targetExtension = _resolveAndroidTargetExtension(task, mediaFiles);
      final outputBaseName = _sanitizeOutputBaseName(task.title);
      finalOutputPath = await _buildUniqueOutputPath(
        outputDir,
        outputBaseName,
        targetExtension,
      );

      final selectedSubtitleFiles = _pickAndroidSubtitleInputs(
        subtitleFiles,
        selectedSubtitleTracks,
      );
      final videoInput = _pickAndroidVideoInput(task, mediaFiles);
      final audioInput = _pickAndroidAudioInput(task, mediaFiles, videoInput);
      final shouldEmbedSubtitles = _shouldEmbedSubtitlesForAndroid(task);

      var usedFfmpeg = false;
      if (task.selection.audioOnly) {
        final source = audioInput ?? mediaFiles.first;
        usedFfmpeg = await _finalizeAndroidAudioOnlyTask(
          task: task,
          sourceFile: source,
          outputPath: finalOutputPath,
        );
        if (!usedFfmpeg) {
          await _moveFileToPath(source, finalOutputPath);
        }
      } else {
        final source = videoInput ?? mediaFiles.first;
        final needsFfmpeg =
            task.selection.embedSubtitles ||
            task.selection.removeAudio ||
            audioInput != null ||
            shouldEmbedSubtitles ||
            p.extension(source.path).replaceFirst('.', '').toLowerCase() !=
                targetExtension.toLowerCase() ||
            _needsVideoTranscodeForMp4(task, targetExtension) ||
            _needsAudioTranscodeForMp4(task, targetExtension);
        if (needsFfmpeg) {
          await _runAndroidVideoFinalizeFfmpeg(
            task: task,
            videoInput: source,
            audioInput: task.selection.removeAudio ? null : audioInput,
            subtitleInputs: shouldEmbedSubtitles
                ? selectedSubtitleFiles
                : const [],
            subtitleTracks: selectedSubtitleTracks,
            outputPath: finalOutputPath,
            targetExtension: targetExtension,
          );
          usedFfmpeg = true;
        } else {
          await _moveFileToPath(source, finalOutputPath);
        }
      }

      await _copyAndroidSubtitleOutputs(subtitleFiles, finalOutputPath);
      await _cleanupAndroidTempArtifactsByKey(key);
      return task.copyWith(
        status: YtDlpTaskStatus.completed,
        progress: 1,
        speedText: usedFfmpeg ? '已完成后处理' : '已下载完成',
        etaText: '00:00',
        outputPath: finalOutputPath,
        errorMessage: null,
        failureType: YtDlpFailureType.none,
        failureContext: null,
        completedAtIso: DateTime.now().toIso8601String(),
        tempArtifactKey: null,
      );
    } catch (e) {
      if (finalOutputPath != null) {
        await _deleteAndroidFinalOutputArtifacts(finalOutputPath);
      }
      await _cleanupAndroidTempArtifactsByKey(key);
      return task.copyWith(
        status: YtDlpTaskStatus.failed,
        failureType: YtDlpFailureType.postProcessingFailed,
        errorMessage: 'Android 本地 FFmpeg 后处理失败: $e',
        lastFailedAtIso: DateTime.now().toIso8601String(),
        tempArtifactKey: null,
      );
    }
  }

  Future<List<File>> _collectAndroidTempFiles(String key) async {
    final tempDir = await getTemporaryDirectory();
    if (!await tempDir.exists()) {
      return const [];
    }
    final prefix = _androidArtifactPrefix(key);
    final files = <File>[];
    await for (final entity in tempDir.list(recursive: true)) {
      if (entity is! File) {
        continue;
      }
      final name = p.basename(entity.path);
      if (!name.startsWith(prefix)) {
        continue;
      }
      files.add(entity);
    }
    return files;
  }

  Future<List<File>> _collectAndroidFinalizeFiles(
    YtDlpTaskRecord task, {
    List<String> hintedProducedPaths = const [],
  }) async {
    const maxAttempts = 12;
    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      final files = await _collectAndroidFinalizeFilesOnce(
        task,
        hintedProducedPaths: hintedProducedPaths,
      );
      final hasMedia = files.any((file) => !_isSubtitleFile(file));
      if (hasMedia) {
        return files;
      }
      if (attempt < maxAttempts - 1) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
    }
    return _collectAndroidFinalizeFilesOnce(
      task,
      hintedProducedPaths: hintedProducedPaths,
    );
  }

  Future<List<File>> _collectAndroidFinalizeFilesOnce(
    YtDlpTaskRecord task, {
    List<String> hintedProducedPaths = const [],
  }) async {
    final collected = <String, File>{};
    final key = task.tempArtifactKey?.trim();
    final outputPath = task.outputPath?.trim();

    void addFile(File file) {
      collected.putIfAbsent(file.path, () => file);
    }

    Future<void> collectFromDirectory(
      Directory directory, {
      String? preferredPrefix,
      String? preferredFileName,
      String? preferredBaseName,
    }) async {
      if (!await directory.exists()) {
        return;
      }
      await for (final entity in directory.list(recursive: true)) {
        if (entity is! File) {
          continue;
        }
        if (!await entity.exists() || _isAndroidTransientArtifact(entity)) {
          continue;
        }
        final name = p.basename(entity.path);
        final baseName = p.basenameWithoutExtension(entity.path);
        final matchesPrefix =
            preferredPrefix != null && name.startsWith(preferredPrefix);
        final matchesFileName =
            preferredFileName != null && name == preferredFileName;
        final matchesBaseName =
            preferredBaseName != null &&
            (baseName == preferredBaseName ||
                name.startsWith('$preferredBaseName.'));
        if (matchesPrefix || matchesFileName || matchesBaseName) {
          addFile(entity);
        }
      }
    }

    Future<void> collectFromHintedPath(String path) async {
      final hintedFile = File(path);
      if (await hintedFile.exists() &&
          !_isAndroidTransientArtifact(hintedFile)) {
        addFile(hintedFile);
      }
      await collectFromDirectory(
        hintedFile.parent,
        preferredPrefix: key != null && key.isNotEmpty
            ? _androidArtifactPrefix(key)
            : null,
        preferredFileName: p.basename(path),
        preferredBaseName: p.basenameWithoutExtension(path),
      );
    }

    if (outputPath != null && outputPath.isNotEmpty) {
      final hintedFile = File(outputPath);
      if (await hintedFile.exists() &&
          !_isAndroidTransientArtifact(hintedFile)) {
        addFile(hintedFile);
      }
      final hintedDirectory = hintedFile.parent;
      await collectFromDirectory(
        hintedDirectory,
        preferredPrefix: key != null && key.isNotEmpty
            ? _androidArtifactPrefix(key)
            : null,
        preferredFileName: p.basename(outputPath),
        preferredBaseName: p.basenameWithoutExtension(outputPath),
      );
    }

    for (final hintedPath in hintedProducedPaths) {
      final normalized = hintedPath.trim();
      if (normalized.isEmpty) {
        continue;
      }
      await collectFromHintedPath(normalized);
    }

    if (key != null && key.isNotEmpty) {
      for (final file in await _collectAndroidTempFiles(key)) {
        if (!_isAndroidTransientArtifact(file)) {
          addFile(file);
        }
      }
    }

    return collected.values.toList();
  }

  bool _isAndroidTransientArtifact(File file) {
    final lowerPath = file.path.toLowerCase();
    if (lowerPath.endsWith('.part') || lowerPath.endsWith('.ytdl')) {
      return true;
    }
    return false;
  }

  bool _isSubtitleFile(File file) {
    final ext = p.extension(file.path).replaceFirst('.', '').toLowerCase();
    return {
      'srt',
      'ass',
      'ssa',
      'vtt',
      'lrc',
      'srv1',
      'srv2',
      'srv3',
      'ttml',
      'json3',
    }.contains(ext);
  }

  List<File> _sortAndroidSubtitleFiles(
    List<File> files,
    List<SubtitleTrack> preferredTracks,
    List<String> preferredLanguages,
  ) {
    final ranked = [...files];
    ranked.sort((a, b) {
      final aName = p.basename(a.path).toLowerCase();
      final bName = p.basename(b.path).toLowerCase();
      final aScore = _subtitleFileScore(
        aName,
        preferredTracks,
        preferredLanguages,
      );
      final bScore = _subtitleFileScore(
        bName,
        preferredTracks,
        preferredLanguages,
      );
      if (aScore != bScore) {
        return bScore.compareTo(aScore);
      }
      return aName.compareTo(bName);
    });
    return ranked;
  }

  int _subtitleFileScore(
    String name,
    List<SubtitleTrack> preferredTracks,
    List<String> preferredLanguages,
  ) {
    var score = 0;
    for (var i = 0; i < preferredTracks.length; i++) {
      final track = preferredTracks[i];
      final exactCode = track.languageCode.trim().toLowerCase();
      final normalized = _normalizeSubtitleToken(exactCode);
      if (exactCode.isNotEmpty && name.contains(exactCode)) {
        score += 3000 - (i * 150);
      } else if (normalized.isNotEmpty && name.contains(normalized)) {
        score += 2200 - (i * 120);
      }
      if (track.isAutoGenerated) {
        if (name.contains('auto') ||
            name.contains('asr') ||
            name.contains('.srv') ||
            name.contains('caption')) {
          score += 80;
        }
      } else {
        if (!name.contains('auto') && !name.contains('asr')) {
          score += 40;
        }
      }
    }
    for (var i = 0; i < preferredLanguages.length; i++) {
      final language = preferredLanguages[i].trim().toLowerCase();
      if (language.isNotEmpty && name.contains(language)) {
        score += 1000 - (i * 100);
      }
    }
    if (name.endsWith('.srt')) score += 50;
    if (name.contains('.live_chat.')) score -= 500;
    return score;
  }

  List<File> _pickAndroidSubtitleInputs(
    List<File> subtitleFiles,
    List<SubtitleTrack> selectedTracks,
  ) {
    if (subtitleFiles.isEmpty) {
      return const [];
    }
    if (selectedTracks.isEmpty) {
      return [subtitleFiles.first];
    }
    final picked = <File>[];
    final usedPaths = <String>{};
    for (final track in selectedTracks) {
      File? best;
      var bestScore = -1 << 20;
      for (final file in subtitleFiles) {
        if (usedPaths.contains(file.path)) {
          continue;
        }
        final score = _subtitleFileScore(
          p.basename(file.path).toLowerCase(),
          [track],
          [track.languageCode],
        );
        if (score > bestScore) {
          bestScore = score;
          best = file;
        }
      }
      if (best != null) {
        picked.add(best);
        usedPaths.add(best.path);
      }
    }
    if (picked.isEmpty) {
      picked.add(subtitleFiles.first);
    }
    return picked;
  }

  List<SubtitleTrack> _resolvedSubtitleTracksForTask(YtDlpTaskRecord task) {
    final rawTracks =
        task.request?.debugContext['resolvedSubtitleTracks'] as List? ??
        const [];
    return rawTracks
        .whereType<Map>()
        .map((item) => SubtitleTrack.fromJson(Map<String, dynamic>.from(item)))
        .toList();
  }

  String _normalizeSubtitleToken(String code) {
    final normalized = code.trim().replaceAll('_', '-').toLowerCase();
    if (normalized.isEmpty) {
      return '';
    }
    final parts = normalized
        .split('-')
        .where((item) => item.trim().isNotEmpty)
        .toList();
    if (parts.isEmpty) {
      return '';
    }
    if (parts.length == 1) {
      return parts.first;
    }
    final second = parts[1];
    if (second.length == 2 || second.length == 4) {
      return '${parts.first}-$second';
    }
    return parts.first;
  }

  File? _pickAndroidVideoInput(YtDlpTaskRecord task, List<File> mediaFiles) {
    final videoId = task.request?.debugContext['resolvedVideoFormatId']
        ?.toString()
        .trim();
    final matched = _matchAndroidFileByFormatId(mediaFiles, videoId);
    if (matched != null) {
      return matched;
    }
    if (task.selection.audioOnly) {
      return null;
    }
    return mediaFiles.isEmpty ? null : mediaFiles.first;
  }

  File? _pickAndroidAudioInput(
    YtDlpTaskRecord task,
    List<File> mediaFiles,
    File? videoInput,
  ) {
    final audioIds =
        (task.request?.debugContext['resolvedAudioFormatIds'] as List? ??
                const [])
            .map((item) => item.toString().trim())
            .where((item) => item.isNotEmpty)
            .toList();
    for (final audioId in audioIds) {
      final matched = _matchAndroidFileByFormatId(mediaFiles, audioId);
      if (matched != null && matched.path != videoInput?.path) {
        return matched;
      }
    }
    final remaining = mediaFiles.where((file) => file.path != videoInput?.path);
    return remaining.isEmpty ? null : remaining.first;
  }

  File? _matchAndroidFileByFormatId(List<File> files, String? formatId) {
    if (formatId == null || formatId.isEmpty) {
      return null;
    }
    final escapedFormatId = RegExp.escape(formatId.toLowerCase());
    final patterns = <RegExp>[
      RegExp(r'(?:^|[_\-.])' + escapedFormatId + r'(?:\.|$)'),
      RegExp(r'(?:^|[_\-.])f' + escapedFormatId + r'(?:\.|$)'),
    ];
    for (final file in files) {
      final name = p.basename(file.path).toLowerCase();
      for (final pattern in patterns) {
        if (pattern.hasMatch(name)) {
          return file;
        }
      }
    }
    return null;
  }

  String _resolveAndroidTargetExtension(
    YtDlpTaskRecord task,
    List<File> mediaFiles,
  ) {
    if (task.selection.audioOnly) {
      final requested = task.selection.outputContainer.trim().toLowerCase();
      switch (requested) {
        case 'mp3':
        case 'aac':
        case 'm4a':
        case 'wav':
        case 'opus':
          return requested;
        case 'best':
          return p
              .extension(mediaFiles.first.path)
              .replaceFirst('.', '')
              .toLowerCase();
        default:
          return 'm4a';
      }
    }
    return 'mkv';
  }

  String _sanitizeOutputBaseName(String title) {
    var safe = title.trim();
    if (safe.isEmpty) {
      safe = 'youtube_download';
    }
    safe = safe.replaceAll(RegExp(r'[^\w\u4e00-\u9fa5\.-]'), '_');
    safe = safe.replaceAll(RegExp(r'_+'), '_').replaceAll(RegExp(r'\.+$'), '');
    if (safe.isEmpty) {
      safe = 'youtube_download';
    }
    if (safe.length > 64) {
      safe = safe.substring(0, 64);
    }
    return safe;
  }

  Future<String> _buildUniqueOutputPath(
    Directory directory,
    String baseName,
    String extension,
  ) async {
    final cleanExt = extension.trim().replaceFirst('.', '');
    var candidate = File(p.join(directory.path, '$baseName.$cleanExt'));
    var index = 1;
    while (await candidate.exists()) {
      candidate = File(p.join(directory.path, '${baseName}_$index.$cleanExt'));
      index += 1;
    }
    return candidate.path;
  }

  Future<bool> _finalizeAndroidAudioOnlyTask({
    required YtDlpTaskRecord task,
    required File sourceFile,
    required String outputPath,
  }) async {
    final sourceExt = p
        .extension(sourceFile.path)
        .replaceFirst('.', '')
        .toLowerCase();
    final targetExt = p
        .extension(outputPath)
        .replaceFirst('.', '')
        .toLowerCase();
    if (targetExt == sourceExt && targetExt != 'aac') {
      return false;
    }
    final args = <String>['-y', '-i', sourceFile.path, '-vn'];
    switch (targetExt) {
      case 'mp3':
        args.addAll(['-c:a', 'libmp3lame', '-b:a', '192k']);
        break;
      case 'aac':
        args.addAll(['-c:a', 'aac', '-b:a', '192k']);
        break;
      case 'wav':
        args.addAll(['-c:a', 'pcm_s16le']);
        break;
      case 'm4a':
        if (sourceExt == 'm4a') {
          args.addAll(['-c:a', 'copy']);
        } else {
          args.addAll(['-c:a', 'aac', '-b:a', '192k']);
        }
        break;
      case 'opus':
        args.addAll(['-c:a', 'libopus', '-b:a', '160k']);
        break;
      default:
        args.addAll(['-c:a', 'copy']);
        break;
    }
    args.add(outputPath);
    await _runAndroidFfmpeg(args);
    return true;
  }

  Future<void> _runAndroidVideoFinalizeFfmpeg({
    required YtDlpTaskRecord task,
    required File videoInput,
    required File? audioInput,
    required List<File> subtitleInputs,
    required List<SubtitleTrack> subtitleTracks,
    required String outputPath,
    required String targetExtension,
  }) async {
    final args = <String>['-y', '-i', videoInput.path];
    final subtitleStreamIndexes = <int>[];
    if (audioInput != null && audioInput.path != videoInput.path) {
      args.addAll(['-i', audioInput.path]);
    }
    for (final subtitleInput in subtitleInputs) {
      final inputIndex =
          1 +
          (audioInput != null && audioInput.path != videoInput.path ? 1 : 0) +
          subtitleStreamIndexes.length;
      subtitleStreamIndexes.add(inputIndex);
      args.addAll(['-i', subtitleInput.path]);
    }

    args.addAll(['-map', '0:v:0']);
    if (!task.selection.removeAudio) {
      if (audioInput != null && audioInput.path != videoInput.path) {
        args.addAll(['-map', '1:a:0']);
      } else {
        args.addAll(['-map', '0:a?']);
      }
    }
    for (final subtitleIndex in subtitleStreamIndexes) {
      args.addAll(['-map', '$subtitleIndex:0']);
    }

    final targetIsMp4 = targetExtension.toLowerCase() == 'mp4';
    final needsVideoTranscode = _needsVideoTranscodeForMp4(
      task,
      targetExtension,
    );
    final needsAudioTranscode = _needsAudioTranscodeForMp4(
      task,
      targetExtension,
    );
    if (targetIsMp4 && needsVideoTranscode) {
      args.addAll([
        '-c:v',
        'libx264',
        '-preset',
        'veryfast',
        '-crf',
        '20',
        '-pix_fmt',
        'yuv420p',
      ]);
    } else {
      args.addAll(['-c:v', 'copy']);
    }
    if (!task.selection.removeAudio) {
      if (targetIsMp4 && needsAudioTranscode) {
        args.addAll(['-c:a', 'aac', '-b:a', '192k']);
      } else {
        args.addAll(['-c:a', 'copy']);
      }
    } else {
      args.addAll(['-an']);
    }

    if (subtitleStreamIndexes.isNotEmpty) {
      args.addAll([
        '-c:s',
        targetExtension.toLowerCase() == 'mp4' ? 'mov_text' : 'srt',
      ]);
      for (var i = 0; i < subtitleStreamIndexes.length; i++) {
        final matchedTrack = i < subtitleTracks.length
            ? subtitleTracks[i]
            : null;
        final languageCode = matchedTrack?.languageCode.trim();
        if (languageCode != null && languageCode.isNotEmpty) {
          args.addAll([
            '-metadata:s:s:$i',
            'language=${_ffmpegLanguageTag(languageCode)}',
          ]);
        }
        final title = matchedTrack?.displayName.trim();
        if (title != null && title.isNotEmpty) {
          args.addAll(['-metadata:s:s:$i', 'title=$title']);
        }
      }
    }
    if (targetExtension.toLowerCase() == 'mp4') {
      args.addAll(['-movflags', '+faststart']);
    }
    args.add(outputPath);
    await _runAndroidFfmpeg(args);
  }

  String _ffmpegLanguageTag(String languageCode) {
    final normalized = _normalizeSubtitleToken(languageCode);
    if (normalized.isEmpty) {
      return 'und';
    }
    return normalized.replaceAll('-', '_');
  }

  bool _needsVideoTranscodeForMp4(
    YtDlpTaskRecord task,
    String targetExtension,
  ) {
    if (targetExtension.toLowerCase() != 'mp4') {
      return false;
    }
    if (task.selection.enableCompatibilityMode) {
      return true;
    }
    final videoCodec = (_resolvedSelectedVideoFormat(task)?.videoCodec ?? '')
        .toLowerCase();
    return !_isMp4CompatibleVideoCodec(videoCodec);
  }

  bool _needsAudioTranscodeForMp4(
    YtDlpTaskRecord task,
    String targetExtension,
  ) {
    if (targetExtension.toLowerCase() != 'mp4' || task.selection.removeAudio) {
      return false;
    }
    if (task.selection.enableCompatibilityMode) {
      return true;
    }
    final audioCodec = (_resolvedSelectedAudioFormat(task)?.audioCodec ?? '')
        .toLowerCase();
    if (audioCodec.isEmpty) {
      return false;
    }
    return !_isMp4CompatibleAudioCodec(audioCodec);
  }

  VideoFormat? _resolvedSelectedVideoFormat(YtDlpTaskRecord task) {
    final videoId = task.request?.debugContext['resolvedVideoFormatId']
        ?.toString()
        .trim();
    if (videoId == null || videoId.isEmpty) {
      return null;
    }
    return task.meta?.videoFormats.firstWhere(
      (item) => item.formatId == videoId,
      orElse: () => const VideoFormat(formatId: '', ext: ''),
    );
  }

  AudioFormat? _resolvedSelectedAudioFormat(YtDlpTaskRecord task) {
    final audioIds =
        (task.request?.debugContext['resolvedAudioFormatIds'] as List? ??
                const [])
            .map((item) => item.toString().trim())
            .where((item) => item.isNotEmpty)
            .toList();
    if (audioIds.isEmpty) {
      return null;
    }
    return task.meta?.audioFormats.firstWhere(
      (item) => item.formatId == audioIds.first,
      orElse: () => const AudioFormat(formatId: '', ext: ''),
    );
  }

  bool _isMp4CompatibleVideoCodec(String codec) {
    return codec.isEmpty ||
        codec.contains('avc') ||
        codec.contains('h264') ||
        codec.contains('hevc') ||
        codec.contains('h265') ||
        codec.contains('av01');
  }

  bool _isMp4CompatibleAudioCodec(String codec) {
    return codec.isEmpty ||
        codec.contains('aac') ||
        codec.contains('mp3') ||
        codec.contains('ac3') ||
        codec.contains('eac3');
  }

  Future<void> _runAndroidFfmpeg(List<String> args) async {
    final session = await FFmpegKit.executeWithArguments(args);
    final returnCode = await session.getReturnCode();
    if (ReturnCode.isSuccess(returnCode)) {
      return;
    }
    final logs = await session.getAllLogsAsString();
    throw Exception(logs ?? 'FFmpeg 退出码异常');
  }

  Future<void> _moveFileToPath(File source, String targetPath) async {
    final targetFile = File(targetPath);
    if (!await targetFile.parent.exists()) {
      await targetFile.parent.create(recursive: true);
    }
    if (p.normalize(source.path) == p.normalize(targetPath)) {
      return;
    }
    try {
      await source.rename(targetPath);
    } catch (_) {
      final rafSource = await source.open(mode: FileMode.read);
      final rafTarget = await File(targetPath).open(mode: FileMode.write);
      try {
        final length = await rafSource.length();
        int offset = 0;
        const chunkSize = 1024 * 1024 * 4; // 4MB
        while (offset < length) {
          final bytes = await rafSource.read(chunkSize);
          await rafTarget.writeFrom(bytes);
          offset += bytes.length;
          await Future.delayed(const Duration(milliseconds: 1)); // Yield
        }
      } finally {
        await rafSource.close();
        await rafTarget.close();
      }
      if (await source.exists()) {
        await source.delete();
      }
    }
  }

  Future<void> _copyAndroidSubtitleOutputs(
    List<File> subtitleFiles,
    String finalOutputPath,
  ) async {
    if (subtitleFiles.isEmpty) {
      return;
    }
    final base = p.withoutExtension(finalOutputPath);
    for (var i = 0; i < subtitleFiles.length; i++) {
      final source = subtitleFiles[i];
      final ext = p.extension(source.path);
      final targetPath = i == 0 ? '$base$ext' : '$base.subtitle${i + 1}$ext';
      final target = File(targetPath);
      if (!await target.parent.exists()) {
        await target.parent.create(recursive: true);
      }
      await source.copy(targetPath);
    }
  }

  Future<void> _cleanupAndroidArtifactsForTask(
    YtDlpTaskRecord task, {
    bool deleteCompletedOutput = false,
    bool forgetTrackedKey = false,
  }) async {
    final key = task.tempArtifactKey;
    if (key != null && key.isNotEmpty) {
      await _addPendingAndroidTempCleanupKey(key);
      final cleared = await _cleanupAndroidTempArtifactsByKey(key);
      if (!cleared && !forgetTrackedKey) {
        await _addPendingAndroidTempCleanupKey(key);
      }
    }
    if (deleteCompletedOutput && task.outputPath != null) {
      await _deleteAndroidFinalOutputArtifacts(task.outputPath!);
    }
  }

  Future<bool> _cleanupAndroidTempArtifactsByKey(
    String key, {
    bool removePendingKey = true,
  }) async {
    var allCleared = true;
    for (final file in await _collectAndroidTempFiles(key)) {
      try {
        if (await file.exists()) {
          await file.delete();
        }
      } catch (_) {
        allCleared = false;
      }
      if (await file.exists()) {
        allCleared = false;
      }
    }
    if (allCleared && removePendingKey) {
      await _removePendingAndroidTempCleanupKey(key);
    }
    return allCleared;
  }

  Future<void> _deleteAndroidFinalOutputArtifacts(String outputPath) async {
    try {
      final outputFile = File(outputPath);
      if (await outputFile.exists()) {
        await outputFile.delete();
      }
      final parent = outputFile.parent;
      final baseName = p.basenameWithoutExtension(outputPath);
      if (!await parent.exists()) {
        return;
      }
      await for (final entity in parent.list()) {
        if (entity is! File) {
          continue;
        }
        final name = p.basename(entity.path);
        final sameBase = p.basenameWithoutExtension(entity.path) == baseName;
        final prefixedExtra = name.startsWith('$baseName.subtitle');
        if ((sameBase || prefixedExtra) && _isSubtitleFile(entity)) {
          await entity.delete();
        }
      }
    } catch (_) {}
  }

  Future<bool> _isAndroidTempPath(String? path) async {
    if (path == null || path.isEmpty) {
      return false;
    }
    final tempDir = await getTemporaryDirectory();
    return p.isWithin(tempDir.path, path);
  }

  Future<void> _cleanupAndroidTempOrphans({Duration? maxAge}) async {
    try {
      final trackedKeys = await _loadPendingAndroidTempCleanupKeys();
      final taskKeys = tasks
          .map((item) => item.tempArtifactKey)
          .whereType<String>()
          .where((item) => item.isNotEmpty)
          .toSet();
      trackedKeys.addAll(taskKeys);

      var changed = false;
      for (final key in trackedKeys.toList()) {
        final cleared = await _cleanupAndroidTempArtifactsByKey(key);
        if (!cleared) {
          continue;
        }
        for (var i = 0; i < tasks.length; i++) {
          final task = tasks[i];
          if (task.tempArtifactKey != key) {
            continue;
          }
          tasks[i] = task.copyWith(
            tempArtifactKey: null,
            outputPath: await _isAndroidTempPath(task.outputPath)
                ? null
                : task.outputPath,
          );
          changed = true;
        }
      }

      final tempDir = await getTemporaryDirectory();
      if (!await tempDir.exists()) {
        if (changed) {
          await _persistTaskState();
        }
        return;
      }
      final threshold = maxAge ?? const Duration(hours: 24);
      final now = DateTime.now();
      await for (final entity in tempDir.list()) {
        if (entity is! File) {
          continue;
        }
        final name = p.basename(entity.path);
        if (!name.startsWith(_androidTempPrefix)) {
          continue;
        }
        final stat = await entity.stat();
        if (threshold > Duration.zero &&
            now.difference(stat.modified) < threshold) {
          continue;
        }
        try {
          await entity.delete();
        } catch (_) {}
      }
      if (changed) {
        await _persistTaskState();
      }
    } catch (e) {
      debugPrint('Failed to cleanup Android yt-dlp temp files: $e');
    }
  }

  Future<TemporaryStorageCategoryReport> buildTemporaryStorageReport() async {
    final androidFiles = await _collectClearableAndroidTemporaryFiles();
    final thumbnailFiles = await _collectOrphanTaskThumbnailFiles();
    final files = <File>[...androidFiles, ...thumbnailFiles];
    var totalBytes = 0;
    for (final file in files) {
      totalBytes += await _safeTemporaryStorageFileSize(file);
    }
    final hasProtectedTempTasks = _getProtectedAndroidTempKeys().isNotEmpty;

    return TemporaryStorageCategoryReport(
      id: 'yt_dlp_temp',
      title: 'YT-DLP 临时文件',
      description: 'yt-dlp 下载页残留的临时媒体文件与无引用任务缩略图',
      fileCount: files.length,
      totalBytes: totalBytes,
      canClean: files.isNotEmpty,
      note: files.isEmpty
          ? (hasProtectedTempTasks
                ? '当前存在可继续的 yt-dlp 任务，相关临时文件已受保护。'
                : '未发现可安全清理的 yt-dlp 临时文件。')
          : (hasProtectedTempTasks ? '可继续任务的临时文件已自动跳过。' : null),
    );
  }

  Future<void> clearTemporaryStorageArtifacts() async {
    if (Platform.isAndroid) {
      final protectedKeys = _getProtectedAndroidTempKeys();
      final pendingKeys = await _loadPendingAndroidTempCleanupKeys();
      final clearableKeys = <String>{...pendingKeys};

      for (final task in tasks) {
        final key = task.tempArtifactKey?.trim();
        if (key == null || key.isEmpty || protectedKeys.contains(key)) {
          continue;
        }
        clearableKeys.add(key);
      }

      for (final key in clearableKeys) {
        await _cleanupAndroidTempArtifactsByKey(key);
      }

      final remainingFiles = await _collectClearableAndroidTemporaryFiles();
      for (final file in remainingFiles) {
        try {
          if (await file.exists()) {
            await file.delete();
          }
        } catch (_) {}
      }

      var changed = false;
      for (var i = 0; i < tasks.length; i++) {
        final task = tasks[i];
        final key = task.tempArtifactKey?.trim();
        if (key == null || key.isEmpty || !clearableKeys.contains(key)) {
          continue;
        }
        tasks[i] = task.copyWith(
          tempArtifactKey: null,
          outputPath: await _isAndroidTempPath(task.outputPath)
              ? null
              : task.outputPath,
        );
        changed = true;
      }
      if (changed) {
        await saveTasks();
      }
    }

    for (final file in await _collectOrphanTaskThumbnailFiles()) {
      await _deleteTaskThumbnailArtifact(file.path);
    }
  }

  Set<String> _getProtectedAndroidTempKeys() {
    final protectedKeys = <String>{};
    if (!Platform.isAndroid) {
      return protectedKeys;
    }
    for (final task in tasks) {
      final key = task.tempArtifactKey?.trim();
      if (key == null || key.isEmpty) {
        continue;
      }
      switch (task.status) {
        case YtDlpTaskStatus.pending:
        case YtDlpTaskStatus.queued:
        case YtDlpTaskStatus.resolving:
        case YtDlpTaskStatus.pausing:
        case YtDlpTaskStatus.downloading:
        case YtDlpTaskStatus.postProcessing:
        case YtDlpTaskStatus.paused:
          protectedKeys.add(key);
          break;
        case YtDlpTaskStatus.completed:
        case YtDlpTaskStatus.exported:
        case YtDlpTaskStatus.failed:
        case YtDlpTaskStatus.cancelled:
          break;
      }
    }
    return protectedKeys;
  }

  Future<Set<String>> _collectProtectedAndroidTempPaths() async {
    final protectedPaths = <String>{};
    if (!Platform.isAndroid) {
      return protectedPaths;
    }

    for (final key in _getProtectedAndroidTempKeys()) {
      for (final file in await _collectAndroidTempFiles(key)) {
        protectedPaths.add(p.normalize(file.path));
      }
    }

    for (final task in tasks) {
      final key = task.tempArtifactKey?.trim();
      if (key == null ||
          key.isEmpty ||
          !_getProtectedAndroidTempKeys().contains(key)) {
        continue;
      }
      final outputPath = task.outputPath?.trim();
      if (outputPath != null && outputPath.isNotEmpty) {
        protectedPaths.add(p.normalize(outputPath));
      }
    }
    return protectedPaths;
  }

  Future<List<File>> _collectClearableAndroidTemporaryFiles() async {
    if (!Platform.isAndroid) {
      return const <File>[];
    }

    final tempDir = await getTemporaryDirectory();
    if (!await tempDir.exists()) {
      return const <File>[];
    }

    final protectedKeys = _getProtectedAndroidTempKeys();
    final protectedPaths = await _collectProtectedAndroidTempPaths();
    final clearableFiles = <String, File>{};
    final pendingKeys = await _loadPendingAndroidTempCleanupKeys();

    for (final key in pendingKeys) {
      if (protectedKeys.contains(key)) {
        continue;
      }
      for (final file in await _collectAndroidTempFiles(key)) {
        final normalizedPath = p.normalize(file.path);
        if (protectedPaths.contains(normalizedPath)) {
          continue;
        }
        if (await file.exists()) {
          clearableFiles[normalizedPath] = file;
        }
      }
    }

    await for (final entity in tempDir.list()) {
      if (entity is! File) {
        continue;
      }
      final name = p.basename(entity.path);
      if (!name.startsWith(_androidTempPrefix)) {
        continue;
      }
      final normalizedPath = p.normalize(entity.path);
      if (protectedPaths.contains(normalizedPath)) {
        continue;
      }
      clearableFiles[normalizedPath] = entity;
    }

    return clearableFiles.values.toList();
  }

  Future<List<File>> _collectOrphanTaskThumbnailFiles() async {
    final dir = await _resolveTaskThumbnailDirectory();
    if (!await dir.exists()) {
      return const <File>[];
    }

    final retainedPaths = tasks
        .map((item) => item.localThumbnailPath?.trim())
        .whereType<String>()
        .where((item) => item.isNotEmpty)
        .map(p.normalize)
        .toSet();

    final files = <File>[];
    await for (final entity in dir.list()) {
      if (entity is! File) {
        continue;
      }
      if (!retainedPaths.contains(p.normalize(entity.path))) {
        files.add(entity);
      }
    }
    return files;
  }

  Future<int> _safeTemporaryStorageFileSize(File file) async {
    try {
      if (!await file.exists()) {
        return 0;
      }
      return await file.length();
    } catch (_) {
      return 0;
    }
  }

  Future<Directory> _resolveLibrarySubtitleDirectory() async {
    final dataRoot = await SettingsService().resolveLargeDataRootDir();
    final dir = Directory(p.join(dataRoot.path, 'subtitles'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<Directory> _resolveTaskThumbnailDirectory() async {
    final dataRoot = await SettingsService().resolveLargeDataRootDir();
    final dir = Directory(p.join(dataRoot.path, 'yt_dlp_task_thumbnails'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<Directory> _resolveLibraryThumbnailDirectory() async {
    final dataRoot = await SettingsService().resolveLargeDataRootDir();
    final dir = Directory(p.join(dataRoot.path, 'thumbnails'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<String?> _copyLibraryThumbnailArtifact({
    required YtDlpTaskRecord candidate,
    required Directory thumbnailDir,
  }) async {
    final cachedTaskThumbnailPath = _normalizeLocalFilePath(
      candidate.localThumbnailPath,
    );
    if (cachedTaskThumbnailPath != null && cachedTaskThumbnailPath.isNotEmpty) {
      final cachedFile = File(cachedTaskThumbnailPath);
      if (await cachedFile.exists()) {
        try {
          final ext = _resolveThumbnailExtension(cachedFile.path);
          final fileName =
              '${_uuid.v4()}_${_sanitizeOutputBaseName(candidate.title)}.$ext';
          final savedPath = p.join(thumbnailDir.path, fileName);
          await cachedFile.copy(savedPath);
          return savedPath;
        } catch (e) {
          debugPrint('Failed to reuse cached yt-dlp thumbnail: $e');
        }
      }
    }
    if (candidate.sourceUrl.isEmpty) {
      return null;
    }
    final filePrefix =
        '${_uuid.v4()}_${_sanitizeOutputBaseName(candidate.title)}';
    // 桌面端优先用 yt-dlp 进程下载缩略图
    final ytDlpResult = await _downloadThumbnailViaYtDlp(
      sourceUrl: candidate.sourceUrl,
      targetDirectory: thumbnailDir,
      baseFileName: filePrefix,
      sessionConfig: candidate.executionSessionConfig,
    );
    if (ytDlpResult != null && ytDlpResult.isNotEmpty) {
      return ytDlpResult;
    }
    // Android 端或 yt-dlp 失败时，回退到 HTTP 客户端
    if (candidate.thumbnailCandidateUrls.isEmpty) {
      return null;
    }
    return _downloadThumbnailArtifactWithFallback(
      candidateUrls: candidate.thumbnailCandidateUrls,
      targetDirectory: thumbnailDir,
      fileNamePrefix: filePrefix,
      failureLabel: '复制 yt-dlp 缩略图到媒体库',
    );
  }

  String _resolveThumbnailExtension(String path) {
    final ext = p.extension(path).replaceFirst('.', '').toLowerCase();
    switch (ext) {
      case 'jpg':
      case 'jpeg':
      case 'png':
      case 'webp':
        return ext;
      default:
        return 'jpg';
    }
  }

  Future<String?> _downloadThumbnailArtifactWithFallback({
    required List<String> candidateUrls,
    required Directory targetDirectory,
    required String fileNamePrefix,
    required String failureLabel,
  }) async {
    final triedUrls = <String>[];
    for (final candidateUrl in candidateUrls) {
      final thumbnailUrl = candidateUrl.trim();
      if (thumbnailUrl.isEmpty || triedUrls.contains(thumbnailUrl)) {
        continue;
      }
      triedUrls.add(thumbnailUrl);
      HttpClient? client;
      try {
        final uri = Uri.tryParse(thumbnailUrl);
        if (uri == null || !(uri.isScheme('http') || uri.isScheme('https'))) {
          continue;
        }
        client = HttpClient();
        client.connectionTimeout = _thumbnailRequestTimeout;
        final request = await client
            .getUrl(uri)
            .timeout(_thumbnailRequestTimeout);
        final response = await request.close().timeout(
          _thumbnailResponseTimeout,
        );
        if (response.statusCode < 200 || response.statusCode >= 300) {
          debugPrint(
            '$failureLabel 失败，状态码 ${response.statusCode}: $thumbnailUrl',
          );
          continue;
        }
        final bytes = await consolidateHttpClientResponseBytes(
          response,
        ).timeout(_thumbnailResponseTimeout);
        if (bytes.isEmpty) {
          debugPrint('$failureLabel 失败，返回空内容: $thumbnailUrl');
          continue;
        }
        final ext = _resolveThumbnailExtension(uri.path);
        final savedPath = p.join(targetDirectory.path, '$fileNamePrefix.$ext');
        await File(savedPath).writeAsBytes(bytes, flush: true);
        final repairedSavedPath = await _repairWindowsThumbnailArtifact(
          savedPath,
        );
        if (repairedSavedPath == null || repairedSavedPath.isEmpty) {
          try {
            final savedFile = File(savedPath);
            if (await savedFile.exists()) {
              await savedFile.delete();
            }
          } catch (_) {}
          continue;
        }
        return repairedSavedPath;
      } catch (e) {
        debugPrint('$failureLabel 失败: $thumbnailUrl, error: $e');
      } finally {
        client?.close(force: true);
      }
    }
    return null;
  }

  /// 通过 yt-dlp 原生进程下载缩略图（当 Dart HTTP 客户端失败时的后备方案）
  /// yt-dlp 使用自己的 HTTP 栈，不受 Dart HttpClient 平台限制影响
  Future<String?> _downloadThumbnailViaYtDlp({
    required String sourceUrl,
    required Directory targetDirectory,
    required String baseFileName,
    DownloadSessionConfig? sessionConfig,
  }) async {
    if (!kIsWeb && !Platform.isWindows && !Platform.isMacOS) {
      return null; // 仅桌面端需要此后备
    }
    try {
      final ytDlpPath = await YtDlpBinaryInstaller.resolveInstalledBinaryPath(
        Platform.isWindows ? 'yt-dlp.exe' : 'yt-dlp',
      );
      if (ytDlpPath == null || ytDlpPath.isEmpty) {
        debugPrint('yt-dlp 二进制未安装，无法下载缩略图');
        return null;
      }
      await targetDirectory.create(recursive: true);
      final outputTemplate =
          p.join(targetDirectory.path, '$baseFileName.%(ext)s');
      final config = sessionConfig ?? DownloadSessionConfig.defaults();
      final args = <String>[
        '--write-thumbnail',
        '--skip-download',
        '--no-warnings',
        '--convert-thumbnails',
        'png',
        '-o',
        outputTemplate,
      ];
      // 会话参数（cookies、代理等）
      if (config.useProxy && (config.proxy?.isNotEmpty ?? false)) {
        args.addAll(['--proxy', config.proxy!]);
      }
      if (config.useCookies && (config.cookiesFilePath?.isNotEmpty ?? false)) {
        args.addAll(['--cookies', config.cookiesFilePath!]);
      }
      if (config.forceIpv4) {
        args.add('-4');
      }
      if (config.useCustomUserAgent &&
          (config.userAgent?.isNotEmpty ?? false)) {
        args.addAll(['--user-agent', config.userAgent!]);
      }
      args.add(sourceUrl);
      debugPrint('通过 yt-dlp 进程下载缩略图: $sourceUrl');
      final result = await Process.run(
        ytDlpPath,
        args,
        workingDirectory: targetDirectory.path,
      ).timeout(const Duration(seconds: 25));
      if (result.exitCode != 0) {
        debugPrint('yt-dlp 缩略图下载失败 (exit=${result.exitCode}): '
            '${result.stderr}');
        return null;
      }
      // 扫描目标目录，查找 yt-dlp 生成的缩略图文件
      final entries = await targetDirectory.list().toList();
      for (final entry in entries) {
        if (entry is! File) continue;
        final name = p.basename(entry.path);
        if (!name.startsWith(baseFileName)) continue;
        final ext = p.extension(entry.path).toLowerCase();
        if (ext == '.jpg' ||
            ext == '.jpeg' ||
            ext == '.png' ||
            ext == '.webp') {
          debugPrint('yt-dlp 缩略图下载成功: ${entry.path}');
          return entry.path;
        }
      }
      debugPrint('yt-dlp 缩略图下载完成但未找到匹配文件');
    } catch (e) {
      debugPrint('yt-dlp 缩略图下载异常: $e');
    }
    return null;
  }

  String? _normalizeLocalFilePath(String? path) {
    final trimmed = path?.trim();
    if (trimmed == null || trimmed.isEmpty) {
      return null;
    }
    if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
      return trimmed;
    }
    if (trimmed.startsWith('file://')) {
      try {
        return p.normalize(Uri.parse(trimmed).toFilePath());
      } catch (_) {
        return p.normalize(trimmed.replaceFirst(RegExp(r'^file:/+'), ''));
      }
    }
    return p.normalize(trimmed);
  }

  Future<String?> _repairWindowsThumbnailArtifact(String thumbnailPath) async {
    final normalizedPath = _normalizeLocalFilePath(thumbnailPath);
    if (normalizedPath == null || normalizedPath.isEmpty) {
      return null;
    }
    final file = File(normalizedPath);
    if (!await file.exists()) {
      return null;
    }
    if (!Platform.isWindows) {
      return normalizedPath;
    }
    if (!_requiresWindowsThumbnailTranscode(normalizedPath)) {
      return normalizedPath;
    }
    return _transcodeThumbnailToWindowsCompatiblePng(normalizedPath);
  }

  bool _requiresWindowsThumbnailTranscode(String path) {
    final ext = p.extension(path).toLowerCase();
    return ext == '.webp';
  }

  Future<String?> _transcodeThumbnailToWindowsCompatiblePng(
    String sourcePath,
  ) async {
    final ffmpegPath = await YtDlpBinaryInstaller.resolveInstalledBinaryPath(
      'ffmpeg.exe',
    );
    if (ffmpegPath == null || ffmpegPath.isEmpty) {
      debugPrint('Windows 缩略图转码失败：未找到 ffmpeg.exe');
      return null;
    }
    final sourceFile = File(sourcePath);
    if (!await sourceFile.exists()) {
      return null;
    }
    final outputPath = p.setExtension(sourcePath, '.png');
    try {
      final result = await Process.run(ffmpegPath, [
        '-y',
        '-i',
        sourcePath,
        outputPath,
      ]).timeout(_thumbnailImageConvertTimeout);
      final outputFile = File(outputPath);
      if (result.exitCode == 0 &&
          await outputFile.exists() &&
          await outputFile.length() > 0) {
        if (!_sameNormalizedPath(sourcePath, outputPath)) {
          try {
            await sourceFile.delete();
          } catch (_) {}
        }
        return outputPath;
      }
      debugPrint('Windows 缩略图转码失败(exit=${result.exitCode}): ${result.stderr}');
    } catch (e) {
      debugPrint('Windows 缩略图转码异常: $e');
    }
    return null;
  }

  bool _sameNormalizedPath(String left, String right) {
    return p.normalize(left) == p.normalize(right);
  }

  Future<Map<String, String>> _copyLibrarySubtitleArtifacts({
    required YtDlpTaskRecord task,
    required String outputPath,
    required Directory subtitleDir,
    required List<String> preferredLanguages,
  }) async {
    final subtitleFiles = await _resolveImportSubtitleFiles(task, outputPath);
    if (subtitleFiles.isEmpty) {
      return const {};
    }
    final sortedFiles = [...subtitleFiles]
      ..sort(
        (a, b) => _subtitleImportScore(b.path, outputPath, preferredLanguages)
            .compareTo(
              _subtitleImportScore(a.path, outputPath, preferredLanguages),
            ),
      );

    final preferredTracks = _resolveImportSubtitleTracks(
      task,
      preferredLanguages,
    );
    final matchedTrackByPath = <String, SubtitleTrack>{};
    final remainingFiles = <File>[...sortedFiles];
    for (final track in preferredTracks) {
      File? best;
      var bestScore = -1 << 20;
      for (final file in remainingFiles) {
        final score = _subtitleTrackImportMatchScore(
          p.basename(file.path).toLowerCase(),
          track,
        );
        if (score > bestScore) {
          bestScore = score;
          best = file;
        }
      }
      if (best == null || bestScore <= 0) {
        continue;
      }
      matchedTrackByPath[best.path] = track;
      remainingFiles.remove(best);
    }

    final copied = <String, String>{};
    for (var i = 0; i < sortedFiles.length; i++) {
      final file = sortedFiles[i];
      final matchedTrack = matchedTrackByPath[file.path];
      final label = matchedTrack?.displayName.trim().isNotEmpty == true
          ? matchedTrack!.displayName.trim()
          : _resolveSubtitleImportLabel(
              subtitlePath: file.path,
              outputPath: outputPath,
              fallbackIndex: i,
            );
      final ext = p.extension(file.path).replaceFirst('.', '').toLowerCase();
      final copiedPath = p.join(
        subtitleDir.path,
        '${_uuid.v4()}_${_sanitizeOutputBaseName(label)}.${ext.isEmpty ? 'srt' : ext}',
      );
      await file.copy(copiedPath);
      var uniqueLabel = label;
      var duplicateIndex = 2;
      while (copied.containsKey(uniqueLabel)) {
        uniqueLabel = '$label $duplicateIndex';
        duplicateIndex += 1;
      }
      copied[uniqueLabel] = copiedPath;
    }
    return copied;
  }

  int _subtitleTrackImportMatchScore(String fileName, SubtitleTrack track) {
    var score = 0;
    var matchedLanguage = false;

    void addTokenScore(String token, int tokenScore) {
      if (_subtitleFileNameContainsLanguageToken(fileName, token)) {
        score += tokenScore;
        matchedLanguage = true;
      }
    }

    final exactCode = track.languageCode.trim().toLowerCase();
    final normalizedCode = _normalizeSubtitleToken(exactCode);
    final preferenceKey = YtDlpMetaParser.preferenceLanguageKey(
      track.languageCode,
    );
    final displayName = track.displayName.trim().toLowerCase();

    addTokenScore(exactCode, 6000);
    if (normalizedCode != exactCode) {
      addTokenScore(normalizedCode, 5200);
    }
    if (preferenceKey.isNotEmpty &&
        preferenceKey != normalizedCode &&
        preferenceKey != exactCode) {
      addTokenScore(preferenceKey, 2800);
    }
    for (final token in _subtitleTrackImportTokens(track, displayName)) {
      addTokenScore(token, 3600);
    }

    if (!matchedLanguage) {
      return 0;
    }
    if (track.isAutoGenerated) {
      if (fileName.contains('auto') ||
          fileName.contains('asr') ||
          fileName.contains('.srv') ||
          fileName.contains('caption')) {
        score += 120;
      }
    } else if (!fileName.contains('auto') && !fileName.contains('asr')) {
      score += 40;
    }
    if (fileName.endsWith('.srt')) {
      score += 50;
    }
    return score;
  }

  Set<String> _subtitleTrackImportTokens(
    SubtitleTrack track,
    String displayName,
  ) {
    final tokens = <String>{};
    final normalizedDisplay = displayName.trim().toLowerCase();
    if (normalizedDisplay.isNotEmpty) {
      tokens.add(normalizedDisplay);
    }

    final normalizedCode = _normalizeSubtitleToken(track.languageCode);
    if (normalizedCode.startsWith('en')) {
      tokens.addAll(const {'english', 'eng'});
    }
    if (normalizedCode.contains('hans')) {
      tokens.addAll(const {'simplified', '简体', '简中', 'chs', 'sc'});
    }
    if (normalizedCode.contains('hant')) {
      tokens.addAll(const {'traditional', '繁体', '繁中', 'cht', 'tc'});
    }
    if (normalizedCode == 'zh' || normalizedCode.startsWith('zh-')) {
      tokens.addAll(const {'chinese', '中文'});
    }

    return tokens
        .map((item) => item.trim().toLowerCase())
        .where((item) => item.isNotEmpty)
        .toSet();
  }

  bool _subtitleFileNameContainsLanguageToken(String fileName, String token) {
    final normalizedToken = token.trim().toLowerCase();
    if (normalizedToken.isEmpty) {
      return false;
    }
    if (RegExp(r'[^\x00-\x7F]').hasMatch(normalizedToken)) {
      return fileName.contains(normalizedToken);
    }
    final escaped = RegExp.escape(normalizedToken);
    return RegExp(
      r'(^|[._\-\s\(\)\[\]])' + escaped + r'($|[._\-\s\(\)\[\]])',
    ).hasMatch(fileName);
  }

  Future<List<File>> _resolveImportSubtitleFiles(
    YtDlpTaskRecord task,
    String outputPath,
  ) async {
    final deduped = <String, File>{};
    for (final rawPath in task.producedPaths) {
      final normalizedPath = rawPath.trim();
      if (normalizedPath.isEmpty ||
          !_isSidecarSubtitlePath(normalizedPath) ||
          p.normalize(normalizedPath) == p.normalize(outputPath)) {
        continue;
      }
      final file = File(normalizedPath);
      if (!await file.exists()) {
        continue;
      }
      deduped[p.normalize(file.path)] = file;
    }
    final discovered = await _collectSidecarSubtitleFiles(outputPath);
    for (final file in discovered) {
      deduped[p.normalize(file.path)] = file;
    }
    return deduped.values.toList();
  }

  List<SubtitleTrack> _resolveImportSubtitleTracks(
    YtDlpTaskRecord task,
    List<String> preferredLanguages,
  ) {
    final resolvedTracks = _resolvedSubtitleTracksForTask(task);
    if (resolvedTracks.isNotEmpty) {
      return resolvedTracks;
    }
    final metaTracks = task.meta?.subtitles ?? const <SubtitleTrack>[];
    if (metaTracks.isEmpty || preferredLanguages.isEmpty) {
      return const <SubtitleTrack>[];
    }
    return _resolveTracksForPreferredLanguagesOrdered(
      metaTracks,
      preferredLanguages,
    );
  }

  Future<void> _deleteExportedSubtitleSidecars(
    YtDlpTaskRecord task,
    String outputPath,
  ) async {
    final subtitleFiles = await _resolveImportSubtitleFiles(task, outputPath);
    for (final file in subtitleFiles) {
      try {
        if (await file.exists()) {
          await file.delete();
        }
      } catch (e) {
        debugPrint('Failed to delete yt-dlp sidecar subtitle: $e');
      }
    }
  }

  Future<List<File>> _collectSidecarSubtitleFiles(String outputPath) async {
    final outputFile = File(outputPath);
    final parent = outputFile.parent;
    if (!await parent.exists()) {
      return const [];
    }
    final outputFileName = p.basename(outputPath).toLowerCase();
    final outputBaseName = p.basenameWithoutExtension(outputPath).toLowerCase();
    final files = <File>[];
    await for (final entity in parent.list()) {
      if (entity is! File) {
        continue;
      }
      final fileName = p.basename(entity.path).toLowerCase();
      if (fileName == outputFileName || !_isSidecarSubtitlePath(entity.path)) {
        continue;
      }
      final fileBaseName = p
          .basenameWithoutExtension(entity.path)
          .toLowerCase();
      if (fileBaseName == outputBaseName ||
          fileBaseName.startsWith('$outputBaseName.') ||
          fileBaseName.startsWith('${outputBaseName}_') ||
          fileBaseName.startsWith('$outputBaseName-')) {
        files.add(entity);
      }
    }
    return files;
  }

  bool _isSidecarSubtitlePath(String path) {
    final ext = p.extension(path).replaceFirst('.', '').toLowerCase();
    return {
      'srt',
      'ass',
      'ssa',
      'vtt',
      'lrc',
      'srv1',
      'srv2',
      'srv3',
      'ttml',
      'json3',
    }.contains(ext);
  }

  int _subtitleImportScore(
    String subtitlePath,
    String outputPath,
    List<String> preferredLanguages,
  ) {
    final lowerName = p.basename(subtitlePath).toLowerCase();
    var score = 0;
    for (var i = 0; i < preferredLanguages.length; i++) {
      final language = preferredLanguages[i].trim().toLowerCase();
      if (language.isEmpty) {
        continue;
      }
      if (lowerName.contains(language)) {
        score += 1000 - (i * 100);
      }
    }
    final label = _resolveSubtitleImportLabel(
      subtitlePath: subtitlePath,
      outputPath: outputPath,
      fallbackIndex: 0,
    );
    if (label == '默认字幕') {
      score += 80;
    }
    if (lowerName.endsWith('.srt')) {
      score += 50;
    }
    if (lowerName.contains('.live_chat.')) {
      score -= 400;
    }
    return score;
  }

  String _resolveSubtitleImportLabel({
    required String subtitlePath,
    required String outputPath,
    required int fallbackIndex,
  }) {
    final outputBaseName = p.basenameWithoutExtension(outputPath);
    final subtitleBaseName = p.basenameWithoutExtension(subtitlePath);
    var suffix = subtitleBaseName;
    for (final prefix in [
      '$outputBaseName.',
      '${outputBaseName}_',
      '$outputBaseName-',
    ]) {
      if (suffix.startsWith(prefix)) {
        suffix = suffix.substring(prefix.length);
        break;
      }
    }
    suffix = suffix.trim().replaceAll(RegExp(r'[_-]+'), ' ');
    if (suffix.isEmpty || suffix == subtitleBaseName) {
      return fallbackIndex == 0 ? '默认字幕' : '字幕 ${fallbackIndex + 1}';
    }
    return suffix;
  }

  String _resolveLibraryItemTitle(YtDlpTaskRecord task, String outputPath) {
    final taskTitle = task.meta?.title.trim() ?? '';
    if (taskTitle.isNotEmpty) {
      return taskTitle;
    }
    return p.basenameWithoutExtension(outputPath);
  }

  MediaType _resolveLibraryMediaType(YtDlpTaskRecord task, String outputPath) {
    if (task.selection.audioOnly) {
      return MediaType.audio;
    }
    final ext = p.extension(outputPath).replaceFirst('.', '').toLowerCase();
    return {
          'm4a',
          'mp3',
          'aac',
          'wav',
          'flac',
          'ogg',
          'opus',
          'wma',
        }.contains(ext)
        ? MediaType.audio
        : MediaType.video;
  }

  String? _inferLibraryCodec(YtDlpTaskRecord task) {
    final videoFormatId = task.selection.selectedVideoFormatId;
    if (videoFormatId == null || videoFormatId.isEmpty) {
      return null;
    }
    VideoFormat? matchedVideo;
    for (final format in task.meta?.videoFormats ?? const <VideoFormat>[]) {
      if (format.formatId == videoFormatId) {
        matchedVideo = format;
        break;
      }
    }
    final codec = matchedVideo?.videoCodec?.toLowerCase();
    if (codec == null || codec.isEmpty) {
      return null;
    }
    if (codec.contains('avc') || codec.contains('h264')) {
      return 'avc';
    }
    if (codec.contains('hev1') ||
        codec.contains('hvc1') ||
        codec.contains('hevc') ||
        codec.contains('h265')) {
      return 'hevc';
    }
    return codec.split('.').first;
  }
}

VideoMeta _parseResolvedMetaOnWorker(Map<String, dynamic> rawPayload) {
  final structured = rawPayload['rawInfo'];
  Map<String, dynamic> rawInfo;
  if (structured is Map) {
    rawInfo = Map<String, dynamic>.from(structured);
  } else {
    final rawJson = rawPayload['rawInfoJson']?.toString();
    if (rawJson == null || rawJson.isEmpty) {
      throw Exception('yt-dlp 返回了空或不可解析的元数据，请检查日志或调整会话设置');
    }
    try {
      rawInfo = Map<String, dynamic>.from(jsonDecode(rawJson) as Map);
    } catch (_) {
      throw Exception('yt-dlp 返回的元数据无法解析，请检查日志或调整会话设置');
    }
  }
  if (rawInfo.isEmpty) {
    throw Exception('yt-dlp 返回了空或不可解析的元数据，请检查日志或调整会话设置');
  }
  final resolvedThumbnailUrl = rawPayload['thumbnailUrl']?.toString().trim();
  if (resolvedThumbnailUrl != null && resolvedThumbnailUrl.isNotEmpty) {
    rawInfo['thumbnail'] = resolvedThumbnailUrl;
    final existingThumbnails = (rawInfo['thumbnails'] as List? ?? const [])
        .whereType<Object?>()
        .map((item) => item is Map ? Map<String, dynamic>.from(item) : null)
        .whereType<Map<String, dynamic>>()
        .toList();
    final alreadyExists = existingThumbnails.any(
      (item) => item['url']?.toString().trim() == resolvedThumbnailUrl,
    );
    if (!alreadyExists) {
      existingThumbnails.insert(0, {'url': resolvedThumbnailUrl});
      rawInfo['thumbnails'] = existingThumbnails;
    }
  }
  return const YtDlpMetaParser().parse(rawInfo);
}

DownloadSelection _applyMetaRecommendationsOnWorker(
  Map<String, dynamic> payload,
) {
  final selection = DownloadSelection.fromJson(
    Map<String, dynamic>.from(payload['selection'] as Map),
  );
  final meta = VideoMeta.fromJson(
    Map<String, dynamic>.from(payload['meta'] as Map),
  );
  final preferences = YtDlpDownloadPreferences.fromJson(
    Map<String, dynamic>.from(
      payload['preferences'] as Map? ?? const <String, dynamic>{},
    ),
  );
  return _buildSelectionFromPreferences(
    selection: selection,
    meta: meta,
    preferences: preferences,
  );
}

DownloadSelection _buildSelectionFromPreferences({
  required DownloadSelection selection,
  required VideoMeta meta,
  required YtDlpDownloadPreferences preferences,
  bool forceVideoPreference = false,
}) {
  final resolvedVideoId =
      forceVideoPreference ||
          selection.selectedVideoFormatId?.isNotEmpty != true
      ? _pickPreferredVideoFormatId(meta, preferences.preferredQuality)
      : selection.selectedVideoFormatId;
  final selectedVideoFormat = meta.videoFormats
      .where((item) => item.formatId == resolvedVideoId)
      .cast<VideoFormat?>()
      .firstOrNull;
  final resolvedAudioIds = selection.selectedAudioFormatIds.isNotEmpty
      ? selection.selectedAudioFormatIds
      : (selectedVideoFormat?.hasAudio ?? false)
      ? const <String>[]
      : [
          if ((_pickPreferredAudioFormatId(meta)?.isNotEmpty ?? false))
            _pickPreferredAudioFormatId(meta)!,
        ];
  final preferredSubtitleLanguages =
      selection.selectedSubtitleTrackKeys.isNotEmpty ||
          selection.subtitleLanguages.isNotEmpty
      ? selection.subtitleLanguages
      : preferences.preferredSubtitleLanguages.isNotEmpty
      ? preferences.preferredSubtitleLanguages
      : meta.recommendedSubtitleLanguages;
  final resolvedSubtitleTracks = selection.selectedSubtitleTrackKeys.isNotEmpty
      ? selection.selectedSubtitleTrackKeys
            .map(
              (item) => {
                for (final track in meta.subtitles) track.selectionKey: track,
              }[item],
            )
            .whereType<SubtitleTrack>()
            .toList()
      : _resolveTracksForPreferredLanguagesOrdered(
          meta.subtitles,
          preferredSubtitleLanguages,
        );
  final resolvedSubtitleLanguages = _orderedUniqueStrings(
    resolvedSubtitleTracks.map((item) => item.languageCode),
  );

  return selection.copyWith(
    selectedVideoFormatId: resolvedVideoId,
    selectedAudioFormatIds: resolvedAudioIds,
    outputContainer: selection.audioOnly
        ? _normalizeAudioOnlyOutputContainerValue(selection.outputContainer)
        : 'mkv',
    selectedSubtitleTrackKeys: resolvedSubtitleTracks
        .map((item) => item.selectionKey)
        .toList(),
    subtitleLanguages: resolvedSubtitleLanguages,
    writeSubtitles: resolvedSubtitleTracks.any((item) => !item.isAutoGenerated),
    writeAutoSubtitles: resolvedSubtitleTracks.any(
      (item) => item.isAutoGenerated,
    ),
    embedSubtitles: resolvedSubtitleTracks.isNotEmpty,
  );
}

String? _pickPreferredVideoFormatId(VideoMeta meta, String preferredQuality) {
  if (meta.videoFormats.isEmpty) {
    return meta.recommendedVideoFormatId;
  }
  final targetHeight = _preferredQualityTargetHeight(preferredQuality);
  final sorted = [...meta.videoFormats]
    ..sort((a, b) {
      final aScore = _scorePreferredVideoFormat(a, targetHeight: targetHeight);
      final bScore = _scorePreferredVideoFormat(b, targetHeight: targetHeight);
      return bScore.compareTo(aScore);
    });
  return sorted.first.formatId;
}

String? _pickPreferredAudioFormatId(VideoMeta meta) {
  if (meta.audioFormats.isEmpty) {
    return meta.recommendedAudioFormatId;
  }
  final sorted = [...meta.audioFormats]
    ..sort((a, b) {
      final aScore = _scorePreferredAudioFormat(a);
      final bScore = _scorePreferredAudioFormat(b);
      return bScore.compareTo(aScore);
    });
  return sorted.first.formatId;
}

int? _preferredQualityTargetHeight(String rawPreference) {
  switch (rawPreference.trim().toLowerCase()) {
    case '2160p':
      return 2160;
    case '1440p':
      return 1440;
    case '1080p':
      return 1080;
    case '720p':
      return 720;
    case '480p':
      return 480;
    case '360p':
      return 360;
    default:
      return null;
  }
}

int _scorePreferredVideoFormat(
  VideoFormat format, {
  required int? targetHeight,
}) {
  var score = 0;
  final height = format.height ?? 0;
  if (targetHeight != null && height > 0) {
    if (height == targetHeight) {
      score += 1000000;
    } else if (height < targetHeight) {
      score += 800000 - (targetHeight - height);
    } else {
      score += 500000 - (height - targetHeight);
    }
  } else {
    score += height * 100;
  }
  final codec = (format.videoCodec ?? '').toLowerCase();
  if (format.hasAudio) {
    score += 400;
  }
  if (format.ext.toLowerCase() == 'mp4') {
    score += 200;
  }
  if (codec.contains('avc') || codec.contains('h264')) {
    score += 120;
  } else if (codec.contains('vp9')) {
    score += 90;
  } else if (codec.contains('av01') || codec.contains('av1')) {
    score += 80;
  }
  if ((format.fps ?? 0) >= 50) {
    score += 40;
  }
  return score;
}

int _scorePreferredAudioFormat(AudioFormat format) {
  var score = 0;
  if (format.isDefaultTrack) {
    score += 500;
  }
  score += format.bitrate ?? 0;
  final codec = (format.audioCodec ?? '').toLowerCase();
  if (codec.contains('opus')) {
    score += 120;
  } else if (codec.contains('aac')) {
    score += 100;
  } else if (codec.contains('mp4a')) {
    score += 90;
  }
  return score;
}

List<SubtitleTrack> _resolveTracksForPreferredLanguagesOrdered(
  List<SubtitleTrack> subtitles,
  List<String> preferredLanguages,
) {
  final tracks = <SubtitleTrack>[];
  final used = <String>{};
  for (final language in preferredLanguages) {
    for (final track in subtitles) {
      if (!YtDlpMetaParser.matchesPreferenceLanguage(
        language,
        track.languageCode,
      )) {
        continue;
      }
      if (used.add(track.selectionKey)) {
        tracks.add(track);
      }
    }
  }
  return tracks;
}

List<String> _orderedUniqueStrings(Iterable<String> values) {
  final result = <String>[];
  final seen = <String>{};
  for (final value in values) {
    final trimmed = value.trim();
    if (trimmed.isEmpty || !seen.add(trimmed)) {
      continue;
    }
    result.add(trimmed);
  }
  return result;
}

String _normalizeAudioOnlyOutputContainerValue(String raw) {
  switch (raw.trim().toLowerCase()) {
    case 'mp3':
    case 'aac':
    case 'm4a':
    case 'wav':
    case 'opus':
    case 'best':
      return raw.trim().toLowerCase();
    default:
      return 'm4a';
  }
}
