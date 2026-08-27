import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/level.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'package:video_player_app/features/youtube_download/models/youtube_download_models.dart';
import 'package:video_player_app/features/youtube_download/platform/yt_dlp_native_bridge.dart';
import 'package:video_player_app/features/youtube_download/services/yt_dlp_android_post_process_policy.dart';
import 'package:video_player_app/features/youtube_download/services/yt_dlp_binary_installer.dart';
import 'package:video_player_app/features/youtube_download/services/yt_dlp_binary_location_store.dart';
import 'package:video_player_app/features/youtube_download/services/yt_dlp_binary_updater.dart';
import 'package:video_player_app/features/youtube_download/services/yt_dlp_platform_asset.dart';
import 'package:video_player_app/features/youtube_download/services/yt_dlp_version.dart';
import 'package:video_player_app/features/youtube_download/services/yt_dlp_meta_parser.dart';
import 'package:video_player_app/features/youtube_download/services/yt_dlp_request_builder.dart';
import 'package:video_player_app/features/youtube_download/services/yt_dlp_video_format_selector.dart';
import 'package:video_player_app/models/media_source_ref.dart';
import 'package:video_player_app/models/media_chapter.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/app_wakelock_coordinator.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/services/task_subtitle_storage_service.dart';
import 'package:video_player_app/services/temporary_storage_cleanup_models.dart';

/// 任务状态的 JSON 编解码全部在后台 Isolate 中完成，避免任务较多时阻塞 UI。
@visibleForTesting
String encodeYtDlpTaskStateV2(List<YtDlpTaskRecord> tasks) => jsonEncode({
  'version': 2,
  'tasks': tasks.map((task) => task.toJson()).toList(growable: false),
});

@visibleForTesting
List<YtDlpTaskRecord> decodeYtDlpTaskState(String raw) {
  final decoded = jsonDecode(raw);
  final rawTasks = decoded is Map
      ? (decoded['tasks'] as List? ?? const [])
      : (decoded as List? ?? const []);
  return rawTasks
      .whereType<Map>()
      .map((item) => YtDlpTaskRecord.fromJson(Map<String, dynamic>.from(item)))
      .toList(growable: false);
}

/// Task removal may delete resumable/intermediate artifacts only. Final media,
/// subtitles, thumbnails copied to the library, and any unrelated file are
/// never eligible, even when their name contains the task marker.
@visibleForTesting
bool isSafeYtDlpTaskRemovalArtifact(String filePath, String taskId) {
  final name = p.basename(filePath);
  if (!name.contains('__$taskId.')) {
    return false;
  }
  final lower = name.toLowerCase();
  return lower.endsWith('.part') ||
      lower.endsWith('.ytdl') ||
      lower.endsWith('.tmp') ||
      lower.endsWith('.temp') ||
      lower.endsWith('.frag') ||
      RegExp(r'\.f\d+\.[^.]+$').hasMatch(lower);
}

class _YtDlpPauseCancellation implements Exception {
  const _YtDlpPauseCancellation();

  @override
  String toString() => '任务已暂停';
}

class YtDlpDownloadService extends ChangeNotifier {
  static const String _tasksPrefsKey = 'yt_dlp_tasks_v1';
  static const String _taskStateV2PrefsKey = 'yt_dlp_state_v2';
  static const String _sessionPrefsKey = 'yt_dlp_session_config_v1';
  static const String _speedAndRetryDefaultsV2PrefsKey =
      'yt_dlp_speed_and_retry_defaults_v2';
  static const String _downloadPreferencesPrefsKey =
      'yt_dlp_download_preferences_v1';
  static const String _pendingAndroidTempCleanupPrefsKey =
      'yt_dlp_android_pending_temp_cleanup_keys';
  static const String _androidTempPrefix = 'ytdlp_';
  static const String _selectedContainerPrefsKey =
      'yt_dlp_last_output_container';
  static const String _audioOnlyPrefsKey = 'yt_dlp_last_audio_only';
  static const int _maxFallbackAttempts = 2;
  static const Duration _thumbnailRequestTimeout = Duration(seconds: 8);
  static const Duration _thumbnailResponseTimeout = Duration(seconds: 12);
  static const Duration _thumbnailImageConvertTimeout = Duration(seconds: 10);
  static const String _fallbackUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';
  static const List<String> _fallbackPlayerClientCandidates = [
    'android',
    'visionos',
  ];

  final Uuid _uuid = const Uuid();
  final YtDlpRequestBuilder _requestBuilder = const YtDlpRequestBuilder();
  final YtDlpNativeBridge _nativeBridge = YtDlpNativeBridge();
  final YtDlpBinaryUpdater _binaryUpdater = const YtDlpBinaryUpdater();

  final List<YtDlpTaskRecord> tasks = [];
  final Map<String, int> _taskIndexById = {};
  // 缓存的任务 ID 列表，仅在任务结构变更时更新，避免 Selector 每次 notify 都重建列表
  List<String> _cachedTaskIds = const [];

  Future<void>? _initFuture;
  Future<void>? _runtimePrepareFuture;
  StreamSubscription<DownloadTaskEvent>? _taskEventSub;
  Timer? _persistDebounceTimer;
  Timer? _progressNotifyTimer;
  Future<void>? _persistenceDrainFuture;
  int _taskStateRevision = 0;
  int _persistedTaskStateRevision = 0;
  bool _persistenceDrainRequested = false;
  DownloadSessionConfig _sessionConfig = DownloadSessionConfig.defaults();
  YtDlpDownloadPreferences _downloadPreferences =
      YtDlpDownloadPreferences.defaults();
  YtDlpBinaryStatus _binaryStatus = const YtDlpBinaryStatus();
  YtDlpBinaryLocationSettings? _binaryLocationSettings;
  YtDlpBinaryReleaseInfo? _latestYtDlpRelease;
  final Map<String, DateTime> _lastTaskEventAt = <String, DateTime>{};
  final Set<String> _pauseRequestedTaskIds = <String>{};
  final Map<String, Completer<void>> _pauseConfirmationCompleters =
      <String, Completer<void>>{};
  final Map<String, int> _executionGenerations = <String, int>{};
  final Set<String> _androidFinalizeCancellationRequested = <String>{};
  final Map<String, int> _androidFfmpegSessionIds = <String, int>{};
  bool _isInitialized = false;
  bool _runtimePrepared = false;
  bool _isPageActive = false;
  bool _hasPendingProgressUiRefresh = false;
  bool _isUpdatingYtDlp = false;
  double? _ytDlpUpdateProgress;
  String _ytDlpUpdateStage = '准备更新';
  String? _ytDlpUpdateError;
  String? _managedYtDlpVersion;
  String? _customYtDlpVersion;
  String? _managedYtDlpPathError;
  String? _customYtDlpPathError;
  bool _isApplyingYtDlpPath = false;
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
  YtDlpBinaryLocationSettings? get binaryLocationSettings =>
      _binaryLocationSettings;
  YtDlpBinaryReleaseInfo? get latestYtDlpRelease => _latestYtDlpRelease;
  bool get supportsOnlineYtDlpUpdate =>
      YtDlpBinaryUpdater.supportsOnlineUpdate &&
      (!supportsDesktopYtDlpPaths || usesManagedYtDlp);
  bool get supportsLatestYtDlpReleaseCheck =>
      YtDlpBinaryUpdater.supportsLatestReleaseCheck;
  bool get isUpdatingYtDlp => _isUpdatingYtDlp;
  double? get ytDlpUpdateProgress => _ytDlpUpdateProgress;
  String get ytDlpUpdateStage => _ytDlpUpdateStage;
  String? get ytDlpUpdateError => _ytDlpUpdateError;
  String? get managedYtDlpVersion => _managedYtDlpVersion;
  String? get customYtDlpVersion => _customYtDlpVersion;
  String? get managedYtDlpPathError => _managedYtDlpPathError;
  String? get customYtDlpPathError => _customYtDlpPathError;
  bool get isApplyingYtDlpPath => _isApplyingYtDlpPath;
  bool get supportsDesktopYtDlpPaths =>
      !kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux);
  bool get usesManagedYtDlp =>
      _binaryLocationSettings?.source != YtDlpBinarySource.custom;
  String get bundledYtDlpVersion => YtDlpBinaryInstaller.bundledYtDlpVersion;
  bool get hasNewerYtDlpRelease {
    final latest = _normalizeBinaryVersion(_latestYtDlpRelease?.version);
    final current = _normalizeBinaryVersion(_binaryStatus.ytDlpVersion);
    return latest != null &&
        current != null &&
        YtDlpBinaryUpdater.compareVersions(latest, current) > 0;
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
    await _flushTaskStatePersistence();
  }

  Future<void> _initInternal() async {
    final prefs = await SharedPreferences.getInstance();
    if (supportsDesktopYtDlpPaths) {
      _binaryLocationSettings = await YtDlpBinaryLocationStore.load();
    }
    keepScreenAwakeDuringProcessing =
        prefs.getBool('yt_dlp_keep_screen_awake_during_processing') ?? false;
    await _loadPersistedState(prefs);
    _isInitialized = true;
    await _syncTaskEventBinding();
    _syncKeepAwake();
    _metricsDirty = true;
    notifyListeners();
    // 维护型磁盘与网络工作不得与页面首帧竞争。
    unawaited(
      Future<void>.delayed(const Duration(seconds: 1), () async {
        if (Platform.isAndroid) {
          await _cleanupAndroidTempOrphans();
        }
        await _restoreTaskThumbnailArtifacts();
      }),
    );
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
    if (prefs.getBool(_speedAndRetryDefaultsV2PrefsKey) != true) {
      _sessionConfig = _migrateSpeedAndRetryDefaults(_sessionConfig);
      await prefs.setBool(_speedAndRetryDefaultsV2PrefsKey, true);
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

    final rawV2State = prefs.getString(_taskStateV2PrefsKey);
    final rawLegacyTasks = prefs.getString(_tasksPrefsKey);
    final rawTasks = rawV2State?.isNotEmpty == true
        ? rawV2State!
        : rawLegacyTasks;
    var needsTaskStateMigration = rawV2State?.isNotEmpty != true;
    if (rawTasks != null && rawTasks.isNotEmpty) {
      try {
        final restoredTasks = await compute(decodeYtDlpTaskState, rawTasks);
        tasks
          ..clear()
          ..addAll(restoredTasks);
      } catch (_) {
        tasks.clear();
      }
    }

    var recoveredInterruptedTask = false;
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
        recoveredInterruptedTask = true;
      }
    }

    _rebuildTaskIndex();
    if (needsTaskStateMigration || recoveredInterruptedTask) {
      _taskStateRevision++;
      _scheduleTaskStatePersistence(delay: Duration.zero);
    }
  }

  Future<void> _restoreTaskThumbnailArtifacts() async {
    try {
      // Historical thumbnails are intentionally restored lazily by each card.
      // Eagerly probing/downloading every thumbnail here made page entry and
      // scrolling contend with filesystem and network work.
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

  Future<void> _ensureRuntimeReady({bool forceRefresh = false}) {
    if (_runtimePrepared && !forceRefresh) {
      return Future<void>.value();
    }
    final active = _runtimePrepareFuture;
    if (active != null) return active;
    final future = _prepareRuntime();
    _runtimePrepareFuture = future;
    return future.whenComplete(() {
      if (identical(_runtimePrepareFuture, future)) {
        _runtimePrepareFuture = null;
      }
    });
  }

  Future<void> _prepareRuntime() async {
    await YtDlpBinaryInstaller.ensureInstalled();
    if (supportsDesktopYtDlpPaths) {
      await _configureDesktopBinaryPaths();
    }
    _binaryStatus = await _nativeBridge.getBinaryStatus();
    _runtimePrepared = true;
    notifyListeners();
  }

  Future<void> _configureDesktopBinaryPaths() async {
    _binaryLocationSettings ??= await YtDlpBinaryLocationStore.load();
    final platformAsset = await YtDlpPlatformAsset.current();
    final managedPath = platformAsset == null
        ? null
        : await YtDlpBinaryInstaller.resolveInstalledBinaryPath(
            platformAsset.installedFileName,
          );
    final configuredCustomPath =
        _binaryLocationSettings?.customBinaryPath.trim() ?? '';
    final ytDlpPath =
        _binaryLocationSettings?.source == YtDlpBinarySource.custom
        ? (configuredCustomPath.isEmpty ? null : configuredCustomPath)
        : managedPath;
    final ffmpegPath = await YtDlpBinaryInstaller.resolveInstalledBinaryPath(
      Platform.isWindows ? 'ffmpeg.exe' : 'ffmpeg',
    );
    await _nativeBridge.configureBinaryPaths(
      ytDlpPath: ytDlpPath,
      ffmpegPath: ffmpegPath,
    );
  }

  Future<String?> _resolveActiveDesktopYtDlpPath() async {
    _binaryLocationSettings ??= await YtDlpBinaryLocationStore.load();
    if (_binaryLocationSettings?.source == YtDlpBinarySource.custom) {
      final customPath = _binaryLocationSettings!.customBinaryPath.trim();
      return customPath.isEmpty ? null : customPath;
    }
    return YtDlpBinaryInstaller.resolveManagedYtDlpPath();
  }

  Future<void> refreshDesktopYtDlpPaths() async {
    if (!supportsDesktopYtDlpPaths) return;
    _binaryLocationSettings = await YtDlpBinaryLocationStore.load();
    await _refreshDesktopBinaryPathVersions();
    notifyListeners();
  }

  Future<bool> selectYtDlpBinarySource(YtDlpBinarySource source) async {
    if (!supportsDesktopYtDlpPaths || _isApplyingYtDlpPath) return false;
    if (isResolving || hasProcessingTasks) {
      final message = '请等待当前解析或下载任务结束后再切换 yt-dlp';
      if (source == YtDlpBinarySource.managed) {
        _managedYtDlpPathError = message;
      } else {
        _customYtDlpPathError = message;
      }
      notifyListeners();
      return false;
    }
    _isApplyingYtDlpPath = true;
    notifyListeners();
    try {
      _binaryLocationSettings ??= await YtDlpBinaryLocationStore.load();
      await _refreshDesktopBinaryPathVersions();
      if (source == YtDlpBinarySource.managed && _managedYtDlpVersion == null) {
        _managedYtDlpPathError ??= '软件管理的 yt-dlp 不可用，请迁移到可写目录或重新安装';
        return false;
      }
      if (source == YtDlpBinarySource.custom && _customYtDlpVersion == null) {
        _customYtDlpPathError ??= '请先选择有效的 yt-dlp 文件';
        return false;
      }
      _binaryLocationSettings = _binaryLocationSettings!.copyWith(
        source: source,
      );
      await YtDlpBinaryLocationStore.save(_binaryLocationSettings!);
      _runtimePrepared = false;
      await _ensureRuntimeReady(forceRefresh: true);
      return true;
    } finally {
      _isApplyingYtDlpPath = false;
      notifyListeners();
    }
  }

  Future<bool> applyCustomYtDlpPath(String path) async {
    if (!supportsDesktopYtDlpPaths || _isApplyingYtDlpPath) return false;
    if (isResolving || hasProcessingTasks) {
      _customYtDlpPathError = '请等待当前解析或下载任务结束后再更改 yt-dlp';
      notifyListeners();
      return false;
    }
    _isApplyingYtDlpPath = true;
    _customYtDlpPathError = null;
    notifyListeners();
    try {
      final normalized = path.trim();
      final probe = await _probeDesktopYtDlp(normalized);
      if (probe.error != null) {
        _customYtDlpVersion = null;
        _customYtDlpPathError = probe.error;
        return false;
      }
      _binaryLocationSettings ??= await YtDlpBinaryLocationStore.load();
      _binaryLocationSettings = _binaryLocationSettings!.copyWith(
        customBinaryPath: p.normalize(normalized),
      );
      _customYtDlpVersion = probe.version;
      await YtDlpBinaryLocationStore.save(_binaryLocationSettings!);
      if (_binaryLocationSettings!.source == YtDlpBinarySource.custom) {
        _runtimePrepared = false;
        await _ensureRuntimeReady(forceRefresh: true);
      }
      return true;
    } finally {
      _isApplyingYtDlpPath = false;
      notifyListeners();
    }
  }

  Future<bool> migrateManagedYtDlpDirectory(String path) async {
    if (!supportsDesktopYtDlpPaths || _isApplyingYtDlpPath) return false;
    if (isResolving || hasProcessingTasks) {
      _managedYtDlpPathError = '请等待当前解析或下载任务结束后再迁移 yt-dlp';
      notifyListeners();
      return false;
    }
    _isApplyingYtDlpPath = true;
    _managedYtDlpPathError = null;
    notifyListeners();
    try {
      await YtDlpBinaryInstaller.migrateInstallDirectory(path);
      _binaryLocationSettings = await YtDlpBinaryLocationStore.load();
      await YtDlpBinaryInstaller.ensureInstalled();
      await _refreshDesktopBinaryPathVersions();
      if (_managedYtDlpVersion == null) {
        _managedYtDlpPathError ??= '迁移后未能运行 yt-dlp';
        return false;
      }
      _runtimePrepared = false;
      await _ensureRuntimeReady(forceRefresh: true);
      return true;
    } catch (error) {
      _managedYtDlpPathError = _cleanBinaryPathError(error);
      return false;
    } finally {
      _isApplyingYtDlpPath = false;
      notifyListeners();
    }
  }

  Future<void> _refreshDesktopBinaryPathVersions() async {
    if (!supportsDesktopYtDlpPaths) return;
    _binaryLocationSettings ??= await YtDlpBinaryLocationStore.load();
    final platformAsset = await YtDlpPlatformAsset.current();
    if (platformAsset == null) {
      _managedYtDlpVersion = null;
      _managedYtDlpPathError = '当前处理器架构没有对应的官方 yt-dlp 稳定版';
      return;
    }
    final managedPath = p.join(
      _binaryLocationSettings!.managedDirectory,
      platformAsset.installedFileName,
    );
    final managedProbe = await _probeDesktopYtDlp(managedPath);
    _managedYtDlpVersion = managedProbe.version;
    _managedYtDlpPathError = managedProbe.error;

    final customPath = _binaryLocationSettings!.customBinaryPath.trim();
    if (customPath.isEmpty) {
      _customYtDlpVersion = null;
      _customYtDlpPathError =
          _binaryLocationSettings!.source == YtDlpBinarySource.custom
          ? '请选择有效的 yt-dlp 文件'
          : null;
      return;
    }
    final customProbe = await _probeDesktopYtDlp(customPath);
    _customYtDlpVersion = customProbe.version;
    _customYtDlpPathError = customProbe.error;
  }

  Future<({String? version, String? error})> _probeDesktopYtDlp(
    String path,
  ) async {
    final trimmed = path.trim();
    if (trimmed.isEmpty) {
      return (version: null, error: '路径不能为空');
    }
    if (!p.isAbsolute(trimmed)) {
      return (version: null, error: '必须使用绝对文件路径');
    }
    final file = File(trimmed);
    if (!await file.exists()) {
      return (version: null, error: '文件不存在，请重新选择');
    }
    try {
      final result = await Process.run(file.path, const [
        '--version',
      ]).timeout(const Duration(seconds: 15));
      final output = '${result.stdout}\n${result.stderr}'.trim();
      final version = YtDlpVersions.extractStableVersion(output);
      if (result.exitCode != 0 || version == null) {
        return (version: null, error: '所选文件不是可用的 yt-dlp，请重新选择');
      }
      return (version: version, error: null);
    } catch (error) {
      return (version: null, error: '无法运行所选文件：${_cleanBinaryPathError(error)}');
    }
  }

  String _cleanBinaryPathError(Object error) {
    return error.toString().replaceFirst(RegExp(r'^\w+(?:Exception)?:\s*'), '');
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

  void _markTaskStateDirty({Duration delay = const Duration(seconds: 1)}) {
    _taskStateRevision++;
    _scheduleTaskStatePersistence(delay: delay);
  }

  void _scheduleTaskStatePersistence({required Duration delay}) {
    _persistenceDrainRequested = true;
    _persistDebounceTimer?.cancel();
    _persistDebounceTimer = Timer(delay, () {
      _persistDebounceTimer = null;
      unawaited(_drainTaskStatePersistence());
    });
  }

  Future<void> _drainTaskStatePersistence() {
    final active = _persistenceDrainFuture;
    if (active != null) {
      _persistenceDrainRequested = true;
      return active;
    }
    final future = _drainTaskStatePersistenceInternal();
    _persistenceDrainFuture = future;
    return future.whenComplete(() {
      _persistenceDrainFuture = null;
      if (_persistenceDrainRequested ||
          _persistedTaskStateRevision < _taskStateRevision) {
        unawaited(_drainTaskStatePersistence());
      }
    });
  }

  Future<void> _drainTaskStatePersistenceInternal() async {
    while (_persistenceDrainRequested ||
        _persistedTaskStateRevision < _taskStateRevision) {
      _persistenceDrainRequested = false;
      final revision = _taskStateRevision;
      final snapshot = List<YtDlpTaskRecord>.of(tasks, growable: false);
      final encoded = await compute(encodeYtDlpTaskStateV2, snapshot);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_taskStateV2PrefsKey, encoded);
      _persistedTaskStateRevision = revision;
    }
  }

  Future<void> _flushTaskStatePersistence() async {
    _persistDebounceTimer?.cancel();
    _persistDebounceTimer = null;
    if (_persistedTaskStateRevision >= _taskStateRevision &&
        !_persistenceDrainRequested) {
      return;
    }
    _persistenceDrainRequested = true;
    await _drainTaskStatePersistence();
    final inFlight = _persistenceDrainFuture;
    if (inFlight != null) {
      await inFlight;
    }
  }

  void _notifyProgressUpdate() {
    _syncKeepAwake();
    _markTaskStateDirty();
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
    await _flushTaskStatePersistence();
    await _taskEventSub?.cancel();
    _taskEventSub = null;
    await saveTasks(flush: true);
  }

  Future<void> saveTasks({bool flush = false}) async {
    _clearPendingProgressUiRefresh();
    _rebuildTaskIndex();
    _metricsDirty = true;
    _syncKeepAwake();
    notifyListeners();
    _markTaskStateDirty(delay: const Duration(milliseconds: 250));
    unawaited(_syncTaskEventBinding());
    if (flush) {
      await _flushTaskStatePersistence();
    }
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
    final pauseConfirmation = _pauseConfirmationCompleters[task.taskId];
    if (_pauseRequestedTaskIds.contains(task.taskId) &&
        pauseConfirmation != null &&
        !pauseConfirmation.isCompleted) {
      try {
        await pauseConfirmation.future.timeout(
          const Duration(milliseconds: 500),
        );
      } catch (_) {
        // Native pause already reported a stopped result. The execution fence
        // below still rejects any late paused event from the previous run.
      }
    }
    _pauseRequestedTaskIds.remove(task.taskId);
    _pauseConfirmationCompleters.remove(task.taskId);
    _androidFinalizeCancellationRequested.remove(task.taskId);
    final previousTempArtifactKey = current.tempArtifactKey;
    final isResumingPausedTask = current.status == YtDlpTaskStatus.paused;

    if (Platform.isAndroid &&
        !isResumingPausedTask &&
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
      tempArtifactKey: isResumingPausedTask ? previousTempArtifactKey : null,
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
      final reusableKey = task.tempArtifactKey?.trim();
      final resolvedTempArtifactKey = reusableKey?.isNotEmpty == true
          ? reusableKey!
          : _createAndroidTempArtifactKey(task);
      tempArtifactKey = resolvedTempArtifactKey;
      launchRequest = await _buildAndroidStagedRequest(
        task: task,
        baseRequest: request,
        tempArtifactKey: resolvedTempArtifactKey,
        resumePartial: reusableKey?.isNotEmpty == true,
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

    final generation = (_executionGenerations[taskId] ?? 0) + 1;
    _executionGenerations[taskId] = generation;
    final started = await _nativeBridge.startYoutubeDownload(
      launchRequest,
      generation: generation,
    );
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
    _pauseRequestedTaskIds.add(task.taskId);
    _pauseConfirmationCompleters[task.taskId] = Completer<void>();
    tasks[index] = current.copyWith(
      status: YtDlpTaskStatus.pausing,
      errorMessage: '正在暂停...',
    );
    // 先让 UI 在当前事件循环中得到反馈，再发原生命令；持久化在后台合并。
    _rebuildTaskIndex();
    _metricsDirty = true;
    _syncKeepAwake();
    notifyListeners();
    _markTaskStateDirty(delay: const Duration(milliseconds: 250));

    if (Platform.isAndroid &&
        current.status == YtDlpTaskStatus.postProcessing) {
      _androidFinalizeCancellationRequested.add(task.taskId);
      final sessionId = _androidFfmpegSessionIds[task.taskId];
      if (sessionId != null) {
        try {
          await FFmpegKit.cancel(sessionId);
        } catch (_) {}
      }
      final latestIndex = _indexOfTask(task.taskId);
      if (latestIndex >= 0) {
        tasks[latestIndex] = tasks[latestIndex].copyWith(
          status: YtDlpTaskStatus.paused,
          speedText: null,
          etaText: null,
          errorMessage: '已暂停，可继续下载',
        );
        await saveTasks();
        await _tryStartNextQueuedTask(excludingTaskId: task.taskId);
      }
      return;
    }

    YtDlpPauseResult pauseResult;
    try {
      pauseResult = await _nativeBridge
          .pauseYoutubeDownload(task.taskId)
          .timeout(
            const Duration(milliseconds: 500),
            onTimeout: () => const YtDlpPauseResult.rejected('暂停确认超时'),
          );
    } catch (error) {
      pauseResult = YtDlpPauseResult.rejected(error.toString());
    }
    final latestIndex = _indexOfTask(task.taskId);
    if (latestIndex < 0) return;
    if (pauseResult.accepted && pauseResult.stopped) {
      final latest = tasks[latestIndex];
      tasks[latestIndex] = latest.copyWith(
        status: YtDlpTaskStatus.paused,
        speedText: null,
        etaText: null,
        errorMessage: '已暂停，可继续下载',
      );
      await saveTasks();
      await _tryStartNextQueuedTask(excludingTaskId: task.taskId);
      return;
    }

    final platformStatus = await _nativeBridge.getYoutubeTaskStatus(
      task.taskId,
    );
    final nativeStatus = platformStatus?['status']?.toString();
    if (nativeStatus == 'paused' ||
        (nativeStatus == null && pauseResult.reason == '暂停确认超时')) {
      tasks[latestIndex] = tasks[latestIndex].copyWith(
        status: YtDlpTaskStatus.paused,
        speedText: null,
        etaText: null,
        errorMessage: '已暂停，可继续下载',
      );
      await saveTasks();
      await _tryStartNextQueuedTask(excludingTaskId: task.taskId);
      return;
    }

    if (!pauseResult.accepted) {
      _pauseRequestedTaskIds.remove(task.taskId);
      final confirmation = _pauseConfirmationCompleters.remove(task.taskId);
      if (confirmation != null && !confirmation.isCompleted) {
        confirmation.complete();
      }
      tasks[latestIndex] = tasks[latestIndex].copyWith(
        status: current.status,
        errorMessage: pauseResult.reason?.isNotEmpty == true
            ? '暂停失败：${pauseResult.reason}'
            : '暂停失败，请稍后重试',
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
    await _cleanupArtifactsBeforeRetry(current);
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

  Future<void> removeTask(YtDlpTaskRecord task) async {
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
      await _cleanupAndroidArtifactsForTask(task, forgetTrackedKey: true);
    } else {
      await _cleanupDesktopTaskArtifacts(task, deleteAllTaskArtifacts: false);
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
    await ensureReady(activatePage: true);
    final selected = tasks
        .where((item) => item.isSelected && item.canPause)
        .toList();
    await Future.wait(selected.map(pauseTask));
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
        executionSessionConfig:
            current.executionSessionConfig ?? _sessionConfig,
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

      final itemId = _uuid.v4();
      final subtitleDir = await const TaskSubtitleStorageService()
          .taskDirectory(itemId, create: true);
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

      final mediaChapters = MediaChapter.normalize(
        (candidate.meta?.chapters ?? const <ChapterInfo>[]).map(
          (chapter) => MediaChapter(
            title: chapter.title,
            startMs: ((chapter.startTimeSeconds ?? 0) * 1000).round(),
            endMs: ((chapter.endTimeSeconds ?? 0) * 1000).round(),
          ),
        ),
        durationMs: (candidate.meta?.durationSeconds ?? 0) * 1000,
      );

      final item = VideoItem(
        id: itemId,
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
        chapters: mediaChapters,
        hasProbedChapters: mediaChapters.isNotEmpty,
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
    if (!supportsLatestYtDlpReleaseCheck) {
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
      _latestYtDlpRelease = null;
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
    _ytDlpUpdateStage = '正在检查最新稳定版';
    _ytDlpUpdateError = null;
    notifyListeners();
    try {
      final result = await _binaryUpdater.updateToLatest(
        currentVersion: _binaryStatus.ytDlpVersion,
        validateBinary: Platform.isAndroid
            ? _nativeBridge.reloadAndroidRuntime
            : null,
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
      final activeVersion = _normalizeBinaryVersion(_binaryStatus.ytDlpVersion);
      final expectedVersion = _normalizeBinaryVersion(result.currentVersion);
      if (!_binaryStatus.ytDlpReady || activeVersion != expectedVersion) {
        throw StateError(
          'yt-dlp 已写入 ${result.currentVersion}，但运行环境未加载该版本。'
          '当前路径: ${_binaryStatus.ytDlpPath ?? '未找到'}，'
          '当前版本: ${_binaryStatus.ytDlpVersion ?? 'unknown'}',
        );
      }
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
    final activeGeneration = _executionGenerations[event.taskId];
    if (event.generation != null &&
        activeGeneration != null &&
        event.generation != activeGeneration) {
      return;
    }
    if (event.type == 'task_paused' &&
        !_pauseRequestedTaskIds.contains(event.taskId) &&
        current.status != YtDlpTaskStatus.pausing &&
        current.status != YtDlpTaskStatus.paused) {
      // A terminal event from the previous native execution must never pause
      // a newly resumed generation of the same task.
      return;
    }
    final normalizedStatusMessage = _normalizeTaskStatusMessage(event);
    final updatedStepMessages = _appendTaskStepMessage(
      current.stepMessages,
      normalizedStatusMessage,
    );
    final isPauseTransition =
        _pauseRequestedTaskIds.contains(event.taskId) ||
        current.status == YtDlpTaskStatus.pausing;
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
        errorMessage: current.status == YtDlpTaskStatus.paused
            ? '已暂停，可继续下载'
            : '正在暂停...',
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
    if (event.type == 'task_paused' ||
        event.type == 'task_completed' ||
        event.type == 'task_failed' ||
        event.type == 'task_cancelled') {
      _pauseRequestedTaskIds.remove(event.taskId);
      final confirmation = _pauseConfirmationCompleters.remove(event.taskId);
      if (confirmation != null && !confirmation.isCompleted) {
        confirmation.complete();
      }
    }
    if (event.type == 'task_failed' || event.type == 'task_cancelled') {
      if (Platform.isAndroid) {
        await _cleanupAndroidArtifactsForTask(updated, forgetTrackedKey: true);
        tasks[index] = tasks[index].copyWith(
          tempArtifactKey: null,
          outputPath: await _isAndroidTempPath(updated.outputPath)
              ? null
              : tasks[index].outputPath,
        );
      } else {
        await _cleanupDesktopTaskArtifacts(
          updated,
          deleteAllTaskArtifacts: true,
        );
        tasks[index] = tasks[index].copyWith(
          outputPath: null,
          producedPaths: const [],
        );
      }
    }
    if (event.type == 'task_progress') {
      _notifyProgressUpdate();
    } else {
      final isDurableTerminalEvent =
          event.type == 'task_paused' ||
          event.type == 'task_failed' ||
          event.type == 'task_cancelled' ||
          (event.type == 'task_completed' &&
              !(Platform.isAndroid && current.tempArtifactKey != null));
      await saveTasks(flush: isDurableTerminalEvent);
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
        } else if (finalized.status == YtDlpTaskStatus.failed) {
          final didFallback = await _tryAutoFallback(finalized);
          if (didFallback) {
            return;
          }
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
      await removeTask(current);
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
    normalized = normalized.copyWith(
      retries: (normalized.retries ?? 2).clamp(0, 2),
      fragmentRetries: (normalized.fragmentRetries ?? 2).clamp(0, 2),
      concurrentFragments: (normalized.concurrentFragments ?? 4).clamp(1, 16),
    );
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

  DownloadSessionConfig _migrateSpeedAndRetryDefaults(
    DownloadSessionConfig config,
  ) {
    final oldConcurrentFragments = config.concurrentFragments;
    return config.copyWith(
      retries: config.retries == null || config.retries! > 2
          ? 2
          : config.retries,
      fragmentRetries:
          config.fragmentRetries == null || config.fragmentRetries! > 2
          ? 2
          : config.fragmentRetries,
      concurrentFragments:
          oldConcurrentFragments == null || oldConcurrentFragments == 1
          ? 4
          : oldConcurrentFragments,
    );
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
      Platform.isAndroid && !_binaryStatus.ffmpegCliReady;

  static const Duration _activeTaskProgressThrottle = Duration(
    milliseconds: 50,
  );
  static const Duration _backgroundTaskProgressThrottle = Duration(
    milliseconds: 350,
  );

  Duration _effectiveTaskEventThrottleWindow() {
    if (!Platform.isWindows) {
      return _isPageActive
          ? _activeTaskProgressThrottle
          : _backgroundTaskProgressThrottle;
    }
    if (tasks.length >= 60) {
      return _isPageActive
          ? const Duration(milliseconds: 240)
          : const Duration(milliseconds: 800);
    }
    if (tasks.length >= 25) {
      return _isPageActive
          ? const Duration(milliseconds: 160)
          : const Duration(milliseconds: 600);
    }
    return _isPageActive
        ? const Duration(milliseconds: 80)
        : const Duration(milliseconds: 400);
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

  bool _shouldThrottleTaskEvent(DownloadTaskEvent event) {
    if (event.type != 'task_progress') {
      _lastTaskEventAt[event.taskId] = DateTime.now();
      return false;
    }
    final now = DateTime.now();
    // The Android Python bridge already limits a task to about 20 progress
    // events per second. Do not throw away another layer of foreground events;
    // the UI notifier below will coalesce rebuilds at frame-friendly intervals.
    if (Platform.isAndroid && _isPageActive && tasks.length < 10) {
      _lastTaskEventAt[event.taskId] = now;
      return false;
    }
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

  Future<void> _persistTaskState() async {
    _markTaskStateDirty(delay: Duration.zero);
    await _flushTaskStatePersistence();
  }

  Future<bool> _tryAutoFallback(YtDlpTaskRecord task) async {
    if (!_isRecoverableFailure(task.failureType)) {
      return false;
    }
    if (task.fallbackAttemptCount >= _maxFallbackAttempts) {
      return false;
    }

    await _cleanupArtifactsBeforeRetry(task);

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
        tempArtifactKey: null,
        outputPath: null,
        producedPaths: const [],
        progress: 0,
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
        lower.contains('formats not available') ||
        lower.contains('without a usable media artifact') ||
        lower.contains('no media artifact')) {
      return YtDlpFailureType.noFormatAvailable;
    }
    if (lower.contains('未产出可用媒体文件') ||
        lower.contains('no media artifact') ||
        lower.contains('未找到 yt-dlp 生成的媒体临时文件')) {
      return YtDlpFailureType.noFormatAvailable;
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
    bool resumePartial = false,
  }) async {
    final tempDir = await getTemporaryDirectory();
    if (!await tempDir.exists()) {
      await tempDir.create(recursive: true);
    }
    if (!resumePartial) {
      await _cleanupAndroidTempArtifactsByKey(
        tempArtifactKey,
        removePendingKey: false,
      );
    }
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
    final sourceArgs = YtDlpAndroidPostProcessPolicy.withoutThumbnailOutputArgs(
      originalArgs,
    );
    for (var i = 0; i < sourceArgs.length; i++) {
      final arg = sourceArgs[i];
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
        case '--embed-chapters':
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
    final selectedVideoHasAudio =
        task.meta?.videoFormats.any(
          (format) => format.formatId == resolvedVideoId && format.hasAudio,
        ) ==
        true;
    final shouldMergeAudio =
        resolvedAudioIds.isNotEmpty &&
        (!selectedVideoHasAudio ||
            task.selection.selectedAudioFormatIds.isNotEmpty);
    if (resolvedVideoId != null && shouldMergeAudio) {
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
      _throwIfAndroidFinalizeCancelled(task.taskId);
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
      final mediaFiles = tempFiles.where(_isPossibleMediaContainer).toList()
        ..sort((a, b) => b.lengthSync().compareTo(a.lengthSync()));
      debugPrint(
        '[Android Finalize] 收集到${tempFiles.length}个临时文件: '
        '${tempFiles.map((f) => '${p.basename(f.path)}(${f.lengthSync()}B)').toList()}',
      );
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
      debugPrint(
        '[Android Finalize] 目标扩展名: $targetExtension, '
        'audioOnly=${task.selection.audioOnly}, '
        'embedSubtitles=${task.selection.embedSubtitles}, '
        'removeAudio=${task.selection.removeAudio}',
      );
      final outputBaseName = _sanitizeOutputBaseName(task.title);
      finalOutputPath = await _buildUniqueOutputPath(
        outputDir,
        outputBaseName,
        targetExtension,
      );
      _throwIfAndroidFinalizeCancelled(task.taskId);

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
          await _moveFileToPath(source, finalOutputPath, taskId: task.taskId);
        }
      } else {
        final source = videoInput ?? mediaFiles.first;
        final needsFfmpeg =
            task.selection.embedSubtitles ||
            (task.meta?.chapters.isNotEmpty ?? false) ||
            task.selection.removeAudio ||
            audioInput != null ||
            shouldEmbedSubtitles ||
            p.extension(source.path).replaceFirst('.', '').toLowerCase() !=
                targetExtension.toLowerCase() ||
            _needsVideoTranscodeForMp4(task, targetExtension) ||
            _needsAudioTranscodeForMp4(task, targetExtension);
        if (needsFfmpeg) {
          debugPrint(
            '[Android Finalize] 需要FFmpeg处理: '
            'videoInput=${videoInput != null ? p.basename(videoInput.path) : "null"}'
            '(${videoInput != null ? videoInput.lengthSync() : 0}B), '
            'audioInput=${audioInput != null ? p.basename(audioInput.path) : "null"}'
            '(${audioInput != null ? audioInput.lengthSync() : 0}B), '
            'subtitleInputs=${selectedSubtitleFiles.map((f) => p.basename(f.path)).toList()}, '
            'outputPath=${p.basename(finalOutputPath)}',
          );
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
          await _moveFileToPath(source, finalOutputPath, taskId: task.taskId);
        }
      }

      _throwIfAndroidFinalizeCancelled(task.taskId);
      await _copyAndroidSubtitleOutputs(
        subtitleFiles,
        finalOutputPath,
        taskId: task.taskId,
      );
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
    } on _YtDlpPauseCancellation {
      if (finalOutputPath != null) {
        await _deleteAndroidFinalOutputArtifacts(finalOutputPath);
      }
      return task.copyWith(
        status: YtDlpTaskStatus.paused,
        speedText: null,
        etaText: null,
        errorMessage: '已暂停，可继续下载',
      );
    } catch (e) {
      if (finalOutputPath != null) {
        await _deleteAndroidFinalOutputArtifacts(finalOutputPath);
      }
      await _cleanupAndroidTempArtifactsByKey(key);
      return task.copyWith(
        status: YtDlpTaskStatus.failed,
        failureType: _mapFailureText(e.toString()),
        errorMessage: 'Android 本地 FFmpeg 后处理失败: $e',
        lastFailedAtIso: DateTime.now().toIso8601String(),
        tempArtifactKey: null,
      );
    }
  }

  void _throwIfAndroidFinalizeCancelled(String taskId) {
    if (_androidFinalizeCancellationRequested.contains(taskId)) {
      throw const _YtDlpPauseCancellation();
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
    // 兜底：只从可能是音频/视频的扩展名中选取，避免把 jpg/json/info 等非媒体文件当音频输入
    final remaining = mediaFiles
        .where((file) => file.path != videoInput?.path)
        .where(_isPossibleMediaContainer)
        .toList();
    return remaining.isEmpty ? null : remaining.first;
  }

  /// 扩展名是否可能是音频/视频容器（排除图片、JSON、纯字幕等）。
  bool _isPossibleMediaContainer(File file) {
    final ext = p.extension(file.path).replaceFirst('.', '').toLowerCase();
    if (!YtDlpAndroidPostProcessPolicy.isMediaContainerPath(file.path)) {
      return false;
    }
    // Thumbnail files use the same format-id output template as their source
    // video. Keep them out of candidate selection even when their name matches.
    // 注意：.webm 可能同时包含视频和音频，应归入音频候选
    return {
      'm4a',
      'mp3',
      'aac',
      'opus',
      'ogg',
      'oga',
      'wav',
      'flac',
      'wma',
      'mp4',
      'mkv',
      'mka',
      'webm',
      'avi',
      'mov',
      'flv',
      '3gp',
      'ts',
      'm2ts',
      'mpeg',
      'mpg',
      'wmv',
      'm4v',
      'ogv',
    }.contains(ext);
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
    await _runAndroidFfmpeg(args, task: task, stageLabel: '正在本地转换音频');
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
    var nextInputIndex = 1;
    if (audioInput != null && audioInput.path != videoInput.path) {
      args.addAll(['-i', audioInput.path]);
      nextInputIndex++;
    }
    for (final subtitleInput in subtitleInputs) {
      final inputIndex = nextInputIndex++;
      subtitleStreamIndexes.add(inputIndex);
      args.addAll(['-i', subtitleInput.path]);
    }
    final chapterMetadataFile = await _createAndroidChapterMetadataFile(task);
    final chapterInputIndex = chapterMetadataFile == null
        ? null
        : nextInputIndex++;
    if (chapterMetadataFile != null) {
      args.addAll(['-f', 'ffmetadata', '-i', chapterMetadataFile.path]);
    }

    // Upper-case V excludes attached pictures/cover-art streams. Mapping
    // 0:v:0 can pick an embedded WebP cover and break Matroska muxing.
    args.addAll([
      '-map',
      YtDlpAndroidPostProcessPolicy.primaryVideoStreamSpecifier,
    ]);
    if (!task.selection.removeAudio) {
      if (audioInput != null && audioInput.path != videoInput.path) {
        // ? 可选映射：如果音频文件不含音频流也不报错，兜底保护
        args.addAll(['-map', '1:a?']);
      } else {
        args.addAll(['-map', '0:a?']);
      }
    }
    for (final subtitleIndex in subtitleStreamIndexes) {
      args.addAll(['-map', '$subtitleIndex:0']);
    }
    if (chapterInputIndex != null) {
      args.addAll(['-map_chapters', '$chapterInputIndex']);
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
    try {
      await _runAndroidFfmpeg(
        args,
        task: task,
        stageLabel: needsVideoTranscode || needsAudioTranscode
            ? '正在本地转码并合成'
            : '正在本地合并音视频',
      );
    } finally {
      if (chapterMetadataFile != null && await chapterMetadataFile.exists()) {
        await chapterMetadataFile.delete();
      }
    }
  }

  Future<File?> _createAndroidChapterMetadataFile(YtDlpTaskRecord task) async {
    final chapters = task.meta?.chapters ?? const <ChapterInfo>[];
    if (chapters.isEmpty) return null;
    final buffer = StringBuffer(';FFMETADATA1\n');
    var chapterCount = 0;
    for (final chapter in chapters) {
      final startMs = ((chapter.startTimeSeconds ?? 0) * 1000).round();
      final endMs = ((chapter.endTimeSeconds ?? 0) * 1000).round();
      if (endMs <= startMs) continue;
      chapterCount++;
      buffer
        ..writeln('[CHAPTER]')
        ..writeln('TIMEBASE=1/1000')
        ..writeln('START=$startMs')
        ..writeln('END=$endMs')
        ..writeln('title=${_escapeAndroidFfmetadata(chapter.title)}');
    }
    if (chapterCount == 0) return null;
    final tempDirectory = await getTemporaryDirectory();
    final safeTaskId = task.taskId.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    final file = File(
      p.join(tempDirectory.path, 'ytdlp_${safeTaskId}_chapters.ffmeta'),
    );
    await file.writeAsString(buffer.toString(), flush: true);
    return file;
  }

  String _escapeAndroidFfmetadata(String value) {
    return value
        .replaceAll('\\', '\\\\')
        .replaceAll('\n', r'\n')
        .replaceAll('=', r'\=')
        .replaceAll(';', r'\;')
        .replaceAll('#', r'\#');
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

  Future<void> _runAndroidFfmpeg(
    List<String> args, {
    required YtDlpTaskRecord task,
    required String stageLabel,
  }) async {
    final cmdSummary = args.length > 20
        ? [...args.take(20), '...(共${args.length}个参数)'].join(' ')
        : args.join(' ');
    debugPrint('[Android FFmpeg] 执行: $cmdSummary');

    _throwIfAndroidFinalizeCancelled(task.taskId);
    _updateAndroidFinalizeProgress(task, 0.92, stageLabel);
    final completedSession = Completer<dynamic>();
    final startedSession = await FFmpegKit.executeWithArgumentsAsync(
      args,
      (session) {
        if (!completedSession.isCompleted) {
          completedSession.complete(session);
        }
      },
      null,
      (statistics) {
        final durationSeconds = task.meta?.durationSeconds;
        if (durationSeconds == null || durationSeconds <= 0) {
          return;
        }
        final fraction = (statistics.getTime() / (durationSeconds * 1000))
            .clamp(0.0, 1.0);
        final progress = 0.92 + fraction * 0.07;
        final speed = statistics.getSpeed();
        final detail = speed > 0
            ? '$stageLabel · ${speed.toStringAsFixed(1)}×'
            : stageLabel;
        _updateAndroidFinalizeProgress(task, progress, detail);
      },
    );
    final sessionId = startedSession.getSessionId();
    if (sessionId != null) {
      _androidFfmpegSessionIds[task.taskId] = sessionId;
    }
    if (_androidFinalizeCancellationRequested.contains(task.taskId)) {
      await startedSession.cancel();
    }
    final session = await completedSession.future;
    _androidFfmpegSessionIds.remove(task.taskId);
    _throwIfAndroidFinalizeCancelled(task.taskId);
    final returnCode = await session.getReturnCode();
    if (ReturnCode.isSuccess(returnCode)) {
      debugPrint('[Android FFmpeg] 成功');
      return;
    }

    // 先检查 failTrace（仅 state=FAILED 时有）
    final failTrace = await session.getFailStackTrace();
    debugPrint(
      '[Android FFmpeg] 失败, returnCode=$returnCode, failTrace=$failTrace',
    );

    // getAllLogsAsString 带 timeout 等待异步日志全部到达；
    // 注意：getLogs() 明确不等待，不可依赖它做错误过滤。
    final allLogs = await session.getAllLogsAsString(5000) ?? '';
    // 补充用 getLogs() 再取一次（此时大概率已到齐），做分级过滤
    final logs = await session.getLogs();

    debugPrint('[Android FFmpeg] 完整日志(${allLogs.length}chars): $allLogs');

    final shortMessage = _extractFfmpegErrorSummary(
      allLogs: allLogs,
      logs: logs,
      returnCode: returnCode,
      failTrace: failTrace,
    );
    throw Exception(shortMessage);
  }

  void _updateAndroidFinalizeProgress(
    YtDlpTaskRecord task,
    double progress,
    String message,
  ) {
    final index = _indexOfTask(task.taskId);
    if (index < 0) {
      return;
    }
    final current = tasks[index];
    if (current.status != YtDlpTaskStatus.postProcessing) {
      return;
    }
    tasks[index] = current.copyWith(
      progress: progress.clamp(0.92, 0.99),
      statusMessage: message,
      speedText: null,
      etaText: null,
    );
    _notifyProgressUpdate();
  }

  /// 从 FFmpeg 大量日志中提取简短有效的错误摘要。
  ///
  /// 策略：
  /// 1) failStackTrace（FFmpegKit 内置错误栈）
  /// 2) 从 getLogs() 按级别过滤 ERROR/FATAL/PANIC/STDERR
  /// 3) 取 getAllyLogsAsString() 末尾 60 行 + 关键错误过滤
  /// 4) 末尾 1500 字符兜底
  String _extractFfmpegErrorSummary({
    required String allLogs,
    required List<dynamic>? logs,
    required dynamic returnCode,
    String? failTrace,
  }) {
    final rcStr = returnCode?.toString() ?? '?';

    // 1) failStackTrace
    if (failTrace != null && failTrace.trim().isNotEmpty) {
      final short = failTrace.length > 1500
          ? failTrace.substring(failTrace.length - 1500)
          : failTrace;
      return 'FFmpeg 退出码=$rcStr\n$short';
    }

    // 2) 分级日志：ERROR / FATAL / PANIC / STDERR
    final errorLines = <String>[];
    final warningLines = <String>[];
    if (logs != null && logs.isNotEmpty) {
      for (final log in logs) {
        try {
          final lv = (log as dynamic).getLevel() as int;
          final msg = (log as dynamic).getMessage()?.toString() ?? '';
          if (lv == Level.avLogError ||
              lv == Level.avLogFatal ||
              lv == Level.avLogPanic ||
              lv == Level.avLogStderr) {
            errorLines.add(msg);
          } else if (lv == Level.avLogWarning) {
            warningLines.add(msg);
          }
        } catch (_) {}
      }
    }

    if (errorLines.isNotEmpty) {
      var result = 'FFmpeg 退出码=$rcStr';
      final tail = errorLines.length > 12
          ? errorLines.sublist(errorLines.length - 12)
          : errorLines;
      result += '\n${tail.join('\n')}';
      if (warningLines.isNotEmpty) {
        final warnTail = warningLines.length > 5
            ? warningLines.sublist(warningLines.length - 5)
            : warningLines;
        result += '\n[警告]\n${warnTail.join('\n')}';
      }
      return result;
    }

    // 3) 取全部日志末尾（部分 FFmpeg 错误不用 ERROR 级别）
    final lines = allLogs
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();

    if (lines.isEmpty) {
      return 'FFmpeg 退出码=$rcStr（无日志输出）';
    }

    final tailCount = lines.length > 60 ? 60 : lines.length;
    final tail = lines.sublist(lines.length - tailCount);

    // 过滤可能的错误行
    final tailErrors = tail.where((l) {
      final lower = l.toLowerCase();
      return lower.contains('error') ||
          lower.contains('fatal') ||
          lower.contains('invalid') ||
          lower.contains('failed') ||
          lower.contains('cannot') ||
          lower.contains('unable') ||
          lower.contains('no such') ||
          lower.contains('permission') ||
          lower.contains('denied') ||
          lower.contains('not found') ||
          lower.contains('could not') ||
          lower.contains('conversion failed') ||
          lower.contains('output file') ||
          lower.contains('does not contain') ||
          (lower.startsWith('[') && lower.contains(' @ '));
    }).toList();

    if (tailErrors.isNotEmpty) {
      final show = tailErrors.length > 15
          ? tailErrors.sublist(tailErrors.length - 15)
          : tailErrors;
      return 'FFmpeg 退出码=$rcStr\n${show.join('\n')}';
    }

    // 4) 兜底：末尾 1500 字符
    final tailText = tail.join('\n');
    final snippet = tailText.length > 1500
        ? '..(截断)..\n${tailText.substring(tailText.length - 1500)}'
        : tailText;

    if (warningLines.isNotEmpty) {
      final warnTail = warningLines.length > 5
          ? warningLines.sublist(warningLines.length - 5)
          : warningLines;
      return 'FFmpeg 退出码=$rcStr\n[警告]\n${warnTail.join('\n')}\n---\n$snippet';
    }
    return 'FFmpeg 退出码=$rcStr\n$snippet';
  }

  Future<void> _moveFileToPath(
    File source,
    String targetPath, {
    required String taskId,
  }) async {
    _throwIfAndroidFinalizeCancelled(taskId);
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
          _throwIfAndroidFinalizeCancelled(taskId);
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
    String finalOutputPath, {
    required String taskId,
  }) async {
    if (subtitleFiles.isEmpty) {
      return;
    }
    final base = p.withoutExtension(finalOutputPath);
    for (var i = 0; i < subtitleFiles.length; i++) {
      _throwIfAndroidFinalizeCancelled(taskId);
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

  Future<void> _cleanupArtifactsBeforeRetry(YtDlpTaskRecord task) async {
    if (Platform.isAndroid) {
      await _cleanupAndroidArtifactsForTask(task, forgetTrackedKey: true);
      return;
    }
    await _cleanupDesktopTaskArtifacts(task, deleteAllTaskArtifacts: true);
  }

  Future<void> _cleanupDesktopTaskArtifacts(
    YtDlpTaskRecord task, {
    required bool deleteAllTaskArtifacts,
  }) async {
    if (kIsWeb || Platform.isAndroid || Platform.isIOS) {
      return;
    }
    final marker = '__${task.taskId}.';
    final candidates = <String>{
      ...task.producedPaths,
      if (task.outputPath != null) task.outputPath!,
    };
    final outputDirPath = task.request?.outputDir.trim();
    if (outputDirPath != null && outputDirPath.isNotEmpty) {
      final outputDir = Directory(outputDirPath);
      if (await outputDir.exists()) {
        try {
          await for (final entity in outputDir.list()) {
            if (entity is File && p.basename(entity.path).contains(marker)) {
              candidates.add(entity.path);
            }
          }
        } catch (_) {}
      }
    }
    for (final path in candidates) {
      if (!isSafeYtDlpTaskRemovalArtifact(path, task.taskId) &&
          !deleteAllTaskArtifacts) {
        continue;
      }
      final name = p.basename(path);
      if (!name.contains(marker)) {
        continue;
      }
      try {
        final file = File(path);
        if (await file.exists()) {
          await file.delete();
        }
      } catch (_) {}
    }
  }

  Future<void> _cleanupAndroidArtifactsForTask(
    YtDlpTaskRecord task, {
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
    if (!supportsDesktopYtDlpPaths) {
      return null; // 仅桌面端需要此后备
    }
    try {
      final ytDlpPath = await _resolveActiveDesktopYtDlpPath();
      if (ytDlpPath == null || ytDlpPath.isEmpty) {
        debugPrint('yt-dlp 二进制未安装，无法下载缩略图');
        return null;
      }
      await targetDirectory.create(recursive: true);
      final outputTemplate = p.join(
        targetDirectory.path,
        '$baseFileName.%(ext)s',
      );
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
        debugPrint(
          'yt-dlp 缩略图下载失败 (exit=${result.exitCode}): '
          '${result.stderr}',
        );
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
  return YtDlpVideoFormatSelector.pickFormatId(
        meta.videoFormats,
        preferredQuality: preferredQuality,
      ) ??
      meta.recommendedVideoFormatId;
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
