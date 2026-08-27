import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'package:video_player_app/models/bilibili_download_task.dart';
import 'package:video_player_app/models/bilibili_models.dart';
import 'package:video_player_app/models/media_source_ref.dart';
import 'package:video_player_app/models/video_collection.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/app_wakelock_coordinator.dart';
import 'package:video_player_app/services/bilibili/bilibili_api_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_download_state_manager.dart';
import 'package:video_player_app/services/bilibili/download_manager.dart';
import 'package:video_player_app/services/bilibili/download_integrity.dart';
import 'package:video_player_app/services/bilibili/post_process_task_queue.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/services/task_subtitle_storage_service.dart';
import 'package:video_player_app/services/temporary_storage_cleanup_models.dart';
import 'package:video_player_app/services/thumbnail_cache_service.dart';
import 'package:video_player_app/utils/bilibili_url_parser.dart';
import 'package:video_player_app/utils/bilibili_danmaku_ass.dart';
import 'package:video_player_app/utils/subtitle_util.dart';

class BilibiliDownloadService extends ChangeNotifier {
  static const String _pendingTempCleanupPrefsKey =
      'bilibili_pending_temp_cleanup_keys';
  static const int _maxDownloadRetryCount = 5;
  static const int _maxRetryDelaySeconds = 8;
  static const int _windowsMaxConcurrentDownloadsCap = 2;
  static const Duration _baseProgressNotifyInterval = Duration(
    milliseconds: 280,
  );
  static const Duration _baseTaskPersistDebounce = Duration(milliseconds: 900);
  final BilibiliApiService apiService = BilibiliApiService();
  final Uuid _uuid = const Uuid();
  late BilibiliDownloadManager _downloadManager;
  Future<void>? _initFuture;
  Future<void>? _shutdownFuture;
  Timer? _persistDebounceTimer;
  Timer? _progressNotifyTimer;
  bool _hasPendingTaskPersistence = false;
  bool _hasPendingProgressNotify = false;
  List<String> _cachedTaskIds = const [];
  final Map<String, int> _taskRevisions = <String, int>{};
  final Map<BilibiliDownloadEpisode, int> _episodeRevisions =
      Map<BilibiliDownloadEpisode, int>.identity();
  final Map<BilibiliDownloadEpisode, String> _episodeOwnerTaskIds =
      Map<BilibiliDownloadEpisode, String>.identity();
  final Set<BilibiliDownloadEpisode> _pendingProgressEpisodes =
      Set<BilibiliDownloadEpisode>.identity();
  final Map<String, Map<String, dynamic>> _taskJsonSnapshots =
      <String, Map<String, dynamic>>{};
  final Set<String> _dirtyPersistenceTaskIds = <String>{};
  int _listStructureRevision = 0;
  int _coarseRenderRevision = 0;

  // State
  List<BilibiliDownloadTask> tasks = [];
  final Map<String, BilibiliDownloadTask> _taskIndex = {};
  int maxConcurrentDownloads = 1;
  int maxConnectionsPerVideo = 2;
  int preferredQuality = 116;
  String preferredSubtitleLang = "zh";
  bool preferAiSubtitles = false;
  bool downloadDanmaku = true;
  bool autoImportToLibrary = true;
  bool autoDeleteTaskAfterImport = false;
  bool sequentialExport = false;
  bool keepScreenAwakeDuringProcessing = false;
  String? customDownloadPath;
  LibraryService? libraryService;
  final List<BilibiliDownloadEpisode> _downloadQueue = [];
  final Set<String> _importingEpisodeKeys = <String>{};
  final Set<String> _sequentialImportFailedKeys = <String>{};
  final Map<String, DateTime> _lastResumePersistAt = <String, DateTime>{};
  final Map<BilibiliDownloadEpisode, Future<void>> _runningEpisodeOperations =
      Map<BilibiliDownloadEpisode, Future<void>>.identity();
  int _activeDownloads = 0;
  bool _isSequentialExportPumpRunning = false;
  int _taskCount = 0;
  int _selectedEpisodeCount = 0;
  BilibiliSelectionSummary _selectionSummary = const BilibiliSelectionSummary();
  int _processingEpisodeCount = 0;
  bool _lastAppliedKeepAwakeActive = false;
  bool _metricsDirty = true;

  bool isParsing = false;
  String? parsingStatus;

  BilibiliDownloadService() {
    _downloadManager = BilibiliDownloadManager(apiService);
  }

  @override
  void notifyListeners() {
    // Unknown/non-progress mutations invalidate mounted rows in O(1). The hot
    // progress path bypasses this generation and invalidates only its episode.
    _coarseRenderRevision++;
    _notifyListenersWithoutRenderInvalidation();
  }

  void _notifyListenersWithoutRenderInvalidation() {
    if (_metricsDirty) {
      _refreshTaskMetrics();
      _metricsDirty = false;
    }
    _syncDownloadKeepAwake();
    super.notifyListeners();
  }

  Future<void> _reportDebugEvent(
    String hypothesisId,
    String location,
    String msg, {
    Map<String, Object?>? data,
  }) async {
    if (!kDebugMode) return;
    try {
      final client = HttpClient();
      final request = await client.postUrl(
        Uri.parse('http://127.0.0.1:7777/event'),
      );
      request.headers.contentType = ContentType.json;
      request.write(
        jsonEncode({
          'sessionId': 'bilibili-export-crash',
          'runId': 'pre-fix',
          'hypothesisId': hypothesisId,
          'location': location,
          'msg': '[DEBUG] $msg',
          'data': data ?? <String, Object?>{},
          'ts': DateTime.now().millisecondsSinceEpoch,
        }),
      );
      await request.close();
      client.close(force: true);
    } catch (_) {}
  }

  int _sanitizeMaxConcurrentDownloads(int value) {
    final normalized = value.clamp(1, 10);
    if (!Platform.isWindows) {
      return normalized;
    }
    return normalized.clamp(1, _windowsMaxConcurrentDownloadsCap);
  }

  int _sanitizeMaxConnectionsPerVideo(int value) {
    if (value >= 4) return 4;
    if (value >= 2) return 2;
    return 1;
  }

  int get effectiveMaxConnectionsPerVideo {
    // Keep newly-created media connections within an eight-connection budget.
    // Existing task concurrency remains respected, and high task concurrency
    // automatically turns per-video acceleration down to one connection.
    final perTaskBudget = 8 ~/ maxConcurrentDownloads.clamp(1, 10);
    return _sanitizeMaxConnectionsPerVideo(
      maxConnectionsPerVideo.clamp(1, perTaskBudget.clamp(1, 4)),
    );
  }

  Duration get _effectiveProgressNotifyInterval {
    if (!Platform.isWindows) {
      return tasks.length >= 60
          ? const Duration(milliseconds: 520)
          : _baseProgressNotifyInterval;
    }
    if (tasks.length >= 60) {
      return const Duration(milliseconds: 950);
    }
    if (tasks.length >= 25 || _activeDownloads >= 4) {
      return const Duration(milliseconds: 680);
    }
    if (_activeDownloads >= 2) {
      return const Duration(milliseconds: 500);
    }
    return const Duration(milliseconds: 420);
  }

  Duration get _effectiveTaskPersistDebounce {
    if (!Platform.isWindows) {
      return _baseTaskPersistDebounce;
    }
    if (tasks.length >= 60) {
      return const Duration(seconds: 3);
    }
    if (tasks.length >= 25 || _activeDownloads >= 2) {
      return const Duration(milliseconds: 1800);
    }
    return const Duration(milliseconds: 1300);
  }

  List<String> get taskIds => _cachedTaskIds;

  int get listStructureRevision => _listStructureRevision;

  int taskRevision(String taskId) =>
      Object.hash(_coarseRenderRevision, _taskRevisions[taskId] ?? 0);

  int episodeRevision(BilibiliDownloadEpisode episode) =>
      Object.hash(_coarseRenderRevision, _episodeRevisions[episode] ?? 0);

  String episodeKey(BilibiliDownloadEpisode episode) =>
      '${episode.bvid}_${episode.page.cid}_${episode.page.page}';

  void _rebuildTaskIndex() {
    _taskIndex.clear();
    _episodeOwnerTaskIds.clear();
    final liveEpisodes = Set<BilibiliDownloadEpisode>.identity();
    for (final task in tasks) {
      _taskIndex[task.taskId] = task;
      _taskRevisions.putIfAbsent(task.taskId, () => 0);
      for (final video in task.videos) {
        for (final episode in video.episodes) {
          liveEpisodes.add(episode);
          _episodeOwnerTaskIds[episode] = task.taskId;
          _episodeRevisions.putIfAbsent(episode, () => 0);
        }
      }
    }
    _taskRevisions.removeWhere((taskId, _) => !_taskIndex.containsKey(taskId));
    _taskJsonSnapshots.removeWhere(
      (taskId, _) => !_taskIndex.containsKey(taskId),
    );
    for (final taskId in _taskIndex.keys) {
      if (!_taskJsonSnapshots.containsKey(taskId)) {
        _dirtyPersistenceTaskIds.add(taskId);
      }
    }
    _episodeRevisions.removeWhere(
      (episode, _) => !liveEpisodes.contains(episode),
    );
    _cachedTaskIds = List<String>.unmodifiable(
      tasks.map((task) => task.taskId),
    );
    _listStructureRevision++;
  }

  BilibiliDownloadTask? getTaskById(String taskId) {
    return _taskIndex[taskId];
  }

  @visibleForTesting
  void replaceTasksForTesting(List<BilibiliDownloadTask> replacement) {
    tasks = replacement;
    _rebuildTaskIndex();
    _metricsDirty = true;
  }

  @visibleForTesting
  void markEpisodeProgressChangedForTesting(BilibiliDownloadEpisode episode) {
    _episodeRevisions[episode] = (_episodeRevisions[episode] ?? 0) + 1;
    _notifyListenersWithoutRenderInvalidation();
  }

  void _notifyTaskRows(
    BilibiliDownloadTask task, {
    Iterable<BilibiliDownloadEpisode> episodes = const [],
    bool structureChanged = false,
  }) {
    _taskRevisions[task.taskId] = (_taskRevisions[task.taskId] ?? 0) + 1;
    for (final episode in episodes) {
      _episodeRevisions[episode] = (_episodeRevisions[episode] ?? 0) + 1;
    }
    if (structureChanged) {
      _listStructureRevision++;
    }
    _notifyListenersWithoutRenderInvalidation();
  }

  void setTaskExpanded(BilibiliDownloadTask task, bool expanded) {
    if (task.isExpanded == expanded) return;
    task.isExpanded = expanded;
    scheduleSaveTasks(task: task);
    _notifyTaskRows(task, structureChanged: true);
  }

  /// Moves one top-level Bilibili task to an insertion boundary.
  ///
  /// [insertionIndex] is in the unmodified task list and may range from zero
  /// (before the first task) through [tasks.length] (after the last task).
  /// Keeping the conversion here gives every UI the same stable semantics and
  /// ensures collections and multipart videos always move as one unit.
  bool moveTaskToInsertionIndex(String taskId, int insertionIndex) {
    if (tasks.length < 2) return false;
    final oldIndex = tasks.indexWhere((task) => task.taskId == taskId);
    if (oldIndex < 0) return false;

    final boundary = insertionIndex.clamp(0, tasks.length);
    final newIndex = (boundary > oldIndex ? boundary - 1 : boundary).clamp(
      0,
      tasks.length - 1,
    );
    if (newIndex == oldIndex) return false;

    final task = tasks.removeAt(oldIndex);
    tasks.insert(newIndex, task);
    _cachedTaskIds = List<String>.unmodifiable(
      tasks.map((item) => item.taskId),
    );
    _listStructureRevision++;
    _scheduleTaskOrderPersistence();
    if (sequentialExport) {
      _refreshCompletedEpisodeHints();
    }
    _notifyListenersWithoutRenderInvalidation();
    return true;
  }

  void setTaskSelected(BilibiliDownloadTask task, bool selected) {
    task.isSelected = selected;
    final changedEpisodes = <BilibiliDownloadEpisode>[];
    for (final video in task.videos) {
      video.isSelected = selected;
      for (final episode in video.episodes) {
        episode.isSelected = selected;
        changedEpisodes.add(episode);
      }
    }
    _metricsDirty = true;
    scheduleSaveTasks(task: task);
    _notifyTaskRows(task, episodes: changedEpisodes);
  }

  void setVideoSelected(
    BilibiliDownloadTask task,
    BilibiliVideoItem video,
    bool selected,
  ) {
    video.isSelected = selected;
    for (final episode in video.episodes) {
      episode.isSelected = selected;
    }
    task.isSelected = task.videos.every((item) => item.isSelected);
    _metricsDirty = true;
    scheduleSaveTasks(task: task);
    _notifyTaskRows(task, episodes: video.episodes);
  }

  void setEpisodeSelected(
    BilibiliDownloadTask task,
    BilibiliVideoItem video,
    BilibiliDownloadEpisode episode,
    bool selected,
  ) {
    episode.isSelected = selected;
    video.isSelected = video.episodes.every((item) => item.isSelected);
    task.isSelected = task.videos.every((item) => item.isSelected);
    _metricsDirty = true;
    scheduleSaveTasks(task: task);
    _notifyTaskRows(task, episodes: [episode]);
  }

  void setEpisodeVideoQuality(
    BilibiliDownloadTask task,
    BilibiliDownloadEpisode episode,
    StreamItem? quality,
  ) {
    if (identical(episode.selectedVideoQuality, quality)) return;
    episode.selectedVideoQuality = quality;
    scheduleSaveTasks(task: task);
    _notifyTaskRows(task, episodes: [episode]);
  }

  void setEpisodeSubtitle(
    BilibiliDownloadTask task,
    BilibiliDownloadEpisode episode,
    BilibiliSubtitle? subtitle,
  ) {
    if (identical(episode.selectedSubtitle, subtitle)) return;
    episode.selectedSubtitle = subtitle;
    scheduleSaveTasks(task: task);
    _notifyTaskRows(task, episodes: [episode]);
  }

  Future<void> init() {
    _initFuture ??= _initInternal();
    return _initFuture!;
  }

  Future<void> _initInternal() async {
    await apiService.init();
    await _loadTasks();
    await _loadSettings();
    await _cleanupPersistedTempArtifacts();
    await _cleanupTempOrphans();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    maxConcurrentDownloads = _sanitizeMaxConcurrentDownloads(
      prefs.getInt('bilibili_max_concurrent') ?? 1,
    );
    maxConnectionsPerVideo = _sanitizeMaxConnectionsPerVideo(
      prefs.getInt('bilibili_connections_per_video') ?? 2,
    );
    preferredQuality = prefs.getInt('bilibili_preferred_quality') ?? 116;
    preferredSubtitleLang =
        prefs.getString('bilibili_preferred_subtitle_lang') ?? "zh";
    preferAiSubtitles = prefs.getBool('bilibili_prefer_ai_subtitles') ?? false;
    downloadDanmaku = prefs.getBool('bilibili_download_danmaku') ?? true;
    autoImportToLibrary = prefs.getBool('bilibili_auto_import') ?? true;
    autoDeleteTaskAfterImport =
        prefs.getBool('bilibili_auto_delete_import') ?? false;
    sequentialExport = prefs.getBool('bilibili_sequential_export') ?? false;
    keepScreenAwakeDuringProcessing =
        prefs.getBool('bilibili_keep_screen_awake_during_processing') ?? false;
    customDownloadPath = prefs.getString('bilibili_custom_download_path');
    notifyListeners();
  }

  Future<void> saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('bilibili_max_concurrent', maxConcurrentDownloads);
    await prefs.setInt(
      'bilibili_connections_per_video',
      maxConnectionsPerVideo,
    );
    await prefs.setInt('bilibili_preferred_quality', preferredQuality);
    await prefs.setString(
      'bilibili_preferred_subtitle_lang',
      preferredSubtitleLang,
    );
    await prefs.setBool('bilibili_prefer_ai_subtitles', preferAiSubtitles);
    await prefs.setBool('bilibili_download_danmaku', downloadDanmaku);
    await prefs.setBool('bilibili_auto_import', autoImportToLibrary);
    await prefs.setBool(
      'bilibili_auto_delete_import',
      autoDeleteTaskAfterImport,
    );
    await prefs.setBool('bilibili_sequential_export', sequentialExport);
    await prefs.setBool(
      'bilibili_keep_screen_awake_during_processing',
      keepScreenAwakeDuringProcessing,
    );
    if (customDownloadPath != null) {
      await prefs.setString(
        'bilibili_custom_download_path',
        customDownloadPath!,
      );
    } else {
      await prefs.remove('bilibili_custom_download_path');
    }
    notifyListeners();
  }

  void updateSettings(
    int maxConcurrent,
    int quality,
    String subLang,
    bool preferAi,
    bool autoImport,
    bool autoDelete,
    bool seqExport, {
    String? customPath,
    int? videoConnections,
  }) {
    maxConcurrentDownloads = _sanitizeMaxConcurrentDownloads(maxConcurrent);
    if (videoConnections != null) {
      maxConnectionsPerVideo = _sanitizeMaxConnectionsPerVideo(
        videoConnections,
      );
    }
    preferredQuality = quality;
    preferredSubtitleLang = subLang;
    preferAiSubtitles = preferAi;
    autoImportToLibrary = autoImport;
    autoDeleteTaskAfterImport = autoDelete;
    sequentialExport = seqExport;
    customDownloadPath = customPath;
    saveSettings();
    applyQualitySettingsToPendingTasks();
    processQueue();
    _refreshCompletedEpisodeHints();
    if (autoImportToLibrary && sequentialExport && libraryService != null) {
      unawaited(_processSequentialAutoImports());
    }
  }

  Future<void> setDownloadDanmaku(bool value) async {
    if (downloadDanmaku == value) return;
    downloadDanmaku = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('bilibili_download_danmaku', value);
  }

  bool get supportsProcessingKeepAwakeToggle =>
      Platform.isAndroid || Platform.isIOS || Platform.isMacOS;

  bool get hasProcessingEpisodes {
    return _processingEpisodeCount > 0;
  }

  int get taskCount => _taskCount;

  int get selectedEpisodeCount => _selectedEpisodeCount;

  BilibiliSelectionSummary get selectionSummary => _selectionSummary;

  bool get isProcessingKeepAwakeActive =>
      supportsProcessingKeepAwakeToggle &&
      keepScreenAwakeDuringProcessing &&
      hasProcessingEpisodes;

  Future<bool> toggleKeepScreenAwakeDuringProcessing() async {
    keepScreenAwakeDuringProcessing = !keepScreenAwakeDuringProcessing;
    _syncDownloadKeepAwake();
    await saveSettings();
    return keepScreenAwakeDuringProcessing;
  }

  Future<void> _loadTasks() async {
    final loaded = await BilibiliDownloadStateManager.loadTasks();
    if (loaded.isNotEmpty) {
      tasks = loaded;
      _rebuildTaskIndex();
      _metricsDirty = true;
      notifyListeners();
    }
  }

  Future<void> saveTasks({
    BilibiliDownloadTask? task,
    BilibiliDownloadEpisode? episode,
  }) async {
    final taskId =
        task?.taskId ??
        (episode == null ? null : _episodeOwnerTaskIds[episode]);
    if (taskId == null) {
      _dirtyPersistenceTaskIds.addAll(_cachedTaskIds);
    } else {
      _dirtyPersistenceTaskIds.add(taskId);
    }
    _hasPendingTaskPersistence = true;
    await _flushPendingTaskPersistence();
    notifyListeners();
  }

  Future<void> _saveAllTaskSnapshotsNow() async {
    _dirtyPersistenceTaskIds.addAll(_cachedTaskIds);
    _hasPendingTaskPersistence = true;
    await _flushPendingTaskPersistence();
  }

  void scheduleSaveTasks({
    bool notifyNow = false,
    BilibiliDownloadTask? task,
    BilibiliDownloadEpisode? episode,
  }) {
    _hasPendingTaskPersistence = true;
    _metricsDirty = true;
    final taskId =
        task?.taskId ??
        (episode == null ? null : _episodeOwnerTaskIds[episode]);
    if (taskId == null) {
      _dirtyPersistenceTaskIds.addAll(_cachedTaskIds);
    } else {
      _dirtyPersistenceTaskIds.add(taskId);
    }
    _persistDebounceTimer?.cancel();
    _persistDebounceTimer = Timer(_effectiveTaskPersistDebounce, () {
      _persistDebounceTimer = null;
      if (!_hasPendingTaskPersistence) {
        return;
      }
      unawaited(_flushPendingTaskPersistence());
    });
    if (notifyNow) {
      _metricsDirty = true;
      notifyListeners();
    }
  }

  void _scheduleTaskOrderPersistence() {
    // Reordering changes only the snapshot order. Existing task snapshots can
    // be reused, avoiding an O(total episode count) JSON rebuild on every drop.
    _hasPendingTaskPersistence = true;
    _persistDebounceTimer?.cancel();
    _persistDebounceTimer = Timer(_effectiveTaskPersistDebounce, () {
      _persistDebounceTimer = null;
      if (_hasPendingTaskPersistence) {
        unawaited(_flushPendingTaskPersistence());
      }
    });
  }

  Future<void> _flushPendingTaskPersistence() async {
    final hadPending = _hasPendingTaskPersistence;
    _persistDebounceTimer?.cancel();
    _persistDebounceTimer = null;
    if (!hadPending) {
      return;
    }
    _hasPendingTaskPersistence = false;
    _refreshDirtyTaskSnapshots();
    final snapshots = <Map<String, dynamic>>[
      for (final taskId in _cachedTaskIds) _taskJsonSnapshots[taskId]!,
    ];
    await BilibiliDownloadStateManager.saveTaskSnapshots(snapshots);
  }

  int _refreshDirtyTaskSnapshots() {
    var refreshedCount = 0;
    for (final taskId in _dirtyPersistenceTaskIds.toList(growable: false)) {
      final task = _taskIndex[taskId];
      if (task != null) {
        _taskJsonSnapshots[taskId] = task.toJson();
        refreshedCount++;
      }
    }
    _dirtyPersistenceTaskIds.clear();
    return refreshedCount;
  }

  @visibleForTesting
  int refreshDirtyTaskSnapshotsForTesting() => _refreshDirtyTaskSnapshots();

  @visibleForTesting
  Map<String, dynamic>? taskSnapshotForTesting(String taskId) =>
      _taskJsonSnapshots[taskId];

  void _scheduleProgressNotify(BilibiliDownloadEpisode episode) {
    _hasPendingProgressNotify = true;
    _pendingProgressEpisodes.add(episode);
    if (_progressNotifyTimer != null) {
      return;
    }
    final interval = _effectiveProgressNotifyInterval;
    _progressNotifyTimer = Timer(interval, () {
      _progressNotifyTimer = null;
      if (!_hasPendingProgressNotify) {
        return;
      }
      _hasPendingProgressNotify = false;
      for (final episode in _pendingProgressEpisodes) {
        _episodeRevisions[episode] = (_episodeRevisions[episode] ?? 0) + 1;
      }
      _pendingProgressEpisodes.clear();
      _notifyListenersWithoutRenderInvalidation();
    });
  }

  Future<void> shutdown() {
    _shutdownFuture ??= _shutdownInternal();
    return _shutdownFuture!;
  }

  @override
  void dispose() {
    _persistDebounceTimer?.cancel();
    _progressNotifyTimer?.cancel();
    _pendingProgressEpisodes.clear();
    super.dispose();
  }

  Future<void> _shutdownInternal() async {
    try {
      if (_initFuture != null) {
        await _initFuture;
      }
    } catch (_) {}

    _downloadQueue.clear();

    for (final episode in _runningEpisodeOperations.keys.toList()) {
      episode.cancelToken?.cancel('App shutdown');
    }
    await Future.wait<void>([
      for (final operation in _runningEpisodeOperations.values.toList())
        operation.catchError((_) {}),
    ]);
    _activeDownloads = 0;

    bool changed = false;
    for (final task in tasks) {
      for (final video in task.videos) {
        for (final ep in video.episodes) {
          if (_isEpisodeRunning(ep.status)) {
            ep.cancelToken?.cancel("App shutdown");
            if (ep.hasResumeData) {
              ep.status = DownloadStatus.pending;
              ep.error = "已暂停";
              ep.progress = ep.resumableProgress;
            } else {
              ep.status = DownloadStatus.failed;
              ep.error = "进程中断";
            }
            ep.downloadSpeed = null;
            ep.downloadSize = null;
            changed = true;
          } else if (ep.status == DownloadStatus.queued) {
            ep.status = DownloadStatus.pending;
            changed = true;
          }

          if (ep.tempArtifactKey != null) {
            if (ep.hasResumeData) {
              await _removePendingTempCleanupKey(ep.tempArtifactKey!);
            } else {
              await _addPendingTempCleanupKey(ep.tempArtifactKey!);
              await _cleanupTrackedTempArtifacts(ep.tempArtifactKey!);
            }
          }
        }
      }
    }

    if (changed) {
      await _saveAllTaskSnapshotsNow();
    } else {
      await _flushPendingTaskPersistence();
    }
  }

  // --- Parsing ---

  Future<bool> parseVideo(
    String rawInput, {
    Future<bool> Function(String title)? onConfirmCollection,
  }) async {
    if (rawInput.trim().isEmpty) return false;

    isParsing = true;
    parsingStatus = "正在解析...";
    notifyListeners();

    final lines = rawInput.split('\n');
    bool hasSuccess = false;
    List<String> failedLines = [];
    List<BilibiliDownloadTask> newTasks = [];

    for (var line in lines) {
      if (line.trim().isEmpty) continue;

      try {
        final task = await parseSingleLine(
          line,
          onConfirmCollection: onConfirmCollection,
        );
        if (task != null) {
          newTasks.add(task);
          hasSuccess = true;
          // Auto-fetch logic handled by caller or explicit call
        } else {
          failedLines.add(line);
        }
      } catch (e) {
        debugPrint("Parse error for line '$line': $e");
        failedLines.add(line);
      }
    }

    // Insert new tasks at the top (index 0)
    if (newTasks.isNotEmpty) {
      tasks.insertAll(0, newTasks);
      _rebuildTaskIndex();
      _metricsDirty = true;
    }

    await saveTasks();

    isParsing = false;
    parsingStatus = hasSuccess ? "解析完成" : "解析失败";
    notifyListeners();

    if (hasSuccess) {
      fetchAllInfos();
    }

    return hasSuccess;
  }

  Future<BilibiliDownloadTask?> parseSingleLine(
    String line, {
    Future<bool> Function(String title)? onConfirmCollection,
  }) async {
    final normalizedInput = BilibiliUrlParser.normalizeInput(line);
    if (normalizedInput == null) {
      throw Exception("无法识别 ID");
    }
    final taskSourceRef = _buildTaskSourceRef(normalizedInput.cleanedInput);
    var parseInput = normalizedInput.cleanedInput;
    var type = normalizedInput.type;

    if (type == BilibiliUrlType.shortLink) {
      final resolvedUrl = await apiService.resolveShortLink(parseInput);
      parseInput = resolvedUrl;
      type = BilibiliUrlParser.determineType(parseInput);
    }

    final id = BilibiliUrlParser.extractId(parseInput, type);
    if (id == null) throw Exception("无法识别 ID");

    if (type == BilibiliUrlType.bangumiEp ||
        type == BilibiliUrlType.bangumiSs) {
      final isSs = type == BilibiliUrlType.bangumiSs;
      final data = await apiService.fetchBangumiInfo(
        epId: isSs ? null : id.substring(2),
        seasonId: isSs ? id.substring(2) : null,
      );

      final seasonTitle = data['title'] ?? "Bangumi Season";
      final episodesList = data['episodes'] as List? ?? [];

      List<BilibiliVideoItem> videoItems = episodesList.asMap().entries.map((
        entry,
      ) {
        final idx = entry.key;
        final e = entry.value;

        final videoInfo = BilibiliVideoInfo(
          title: e['long_title']?.isNotEmpty == true
              ? e['long_title']
              : (e['title'] ?? "EP${idx + 1}"),
          desc: '',
          pic: e['cover'] ?? data['cover'] ?? '',
          bvid: e['bvid'] ?? "",
          aid: e['aid']?.toString() ?? "",
          ownerName: "Bangumi",
          ownerMid: "",
          pubDate: 0,
          pages: [
            BilibiliPage(
              cid: e['cid'] ?? 0,
              page: 1,
              part: "EP${idx + 1}",
              duration: 0,
              bvid: e['bvid'],
              aid: e['aid']?.toString(),
            ),
          ],
        );

        final ep = BilibiliDownloadEpisode(
          page: videoInfo.pages.first,
          bvid: videoInfo.bvid,
          isSelected: true,
        );

        return BilibiliVideoItem(
          videoInfo: videoInfo,
          episodes: [ep],
          sourceRef: _buildVideoSourceRef(videoInfo.bvid, taskSourceRef),
          isSelected: true,
        );
      }).toList();

      final collectionInfo = BilibiliCollectionInfo(
        title: seasonTitle,
        cover: data['cover'] ?? '',
        videos: videoItems.map((v) => v.videoInfo).toList(),
      );

      return BilibiliDownloadTask(
        taskId: _uuid.v4(),
        collectionInfo: collectionInfo,
        videos: videoItems,
        sourceRef: taskSourceRef,
        isExpanded: true,
        isSelected: true,
      );
    } else {
      final info = await apiService.fetchVideoInfo(id);

      if (info.collectionInfo != null) {
        // Use collection info
        final collection = info.collectionInfo!;

        bool useCollection = true;
        if (onConfirmCollection != null) {
          useCollection = await onConfirmCollection(collection.title);
        }

        if (useCollection) {
          List<BilibiliVideoItem> videoItems = collection.videos.map((v) {
            List<BilibiliDownloadEpisode> episodes = v.pages
                .map(
                  (p) => BilibiliDownloadEpisode(
                    page: p,
                    bvid: v.bvid,
                    isSelected: true,
                  ),
                )
                .toList();

            return BilibiliVideoItem(
              videoInfo: v,
              episodes: episodes,
              sourceRef: _buildVideoSourceRef(v.bvid, taskSourceRef),
              isExpanded: false, // Default collapsed for cleaner UI
              isSelected: true,
            );
          }).toList();

          return BilibiliDownloadTask(
            taskId: _uuid.v4(),
            collectionInfo: collection,
            videos: videoItems,
            sourceRef: taskSourceRef,
            isExpanded: true,
            isSelected: true,
          );
        } else {
          // Fallback to single video logic (same as 'else' block below)
          List<BilibiliDownloadEpisode> episodes = info.pages
              .map(
                (p) => BilibiliDownloadEpisode(
                  page: p,
                  bvid: info.bvid,
                  isSelected: true,
                ),
              )
              .toList();

          final videoItem = BilibiliVideoItem(
            videoInfo: info,
            episodes: episodes,
            sourceRef: _buildSingleVideoSourceRef(taskSourceRef, info.bvid),
            isExpanded: true,
            isSelected: true,
          );

          return BilibiliDownloadTask(
            taskId: _uuid.v4(),
            singleVideoInfo: info,
            videos: [videoItem],
            sourceRef: taskSourceRef,
            isExpanded: true,
            isSelected: true,
          );
        }
      } else {
        List<BilibiliDownloadEpisode> episodes = info.pages
            .map(
              (p) => BilibiliDownloadEpisode(
                page: p,
                bvid: info.bvid,
                isSelected: true,
              ),
            )
            .toList();

        final videoItem = BilibiliVideoItem(
          videoInfo: info,
          episodes: episodes,
          sourceRef: _buildSingleVideoSourceRef(taskSourceRef, info.bvid),
          isExpanded: true,
          isSelected: true,
        );

        return BilibiliDownloadTask(
          taskId: _uuid.v4(),
          singleVideoInfo: info,
          videos: [videoItem],
          sourceRef: taskSourceRef,
          isExpanded: true,
          isSelected: true,
        );
      }
    }
  }

  MediaSourceRef _buildTaskSourceRef(String cleanedInput) {
    final type = BilibiliUrlParser.determineType(cleanedInput);
    switch (type) {
      case BilibiliUrlType.videoBv:
        return MediaSourceRef(
          value: BilibiliUrlParser.normalizeBvValue(cleanedInput),
          kind: MediaSourceKind.bilibiliBv,
        );
      case BilibiliUrlType.videoAv:
      case BilibiliUrlType.bangumiEp:
      case BilibiliUrlType.bangumiSs:
        return MediaSourceRef(
          value: cleanedInput.toLowerCase(),
          kind: MediaSourceKind.bilibiliId,
        );
      case BilibiliUrlType.shortLink:
      case BilibiliUrlType.unknown:
        return MediaSourceRef(value: cleanedInput, kind: MediaSourceKind.url);
    }
  }

  MediaSourceRef _buildVideoSourceRef(String bvid, MediaSourceRef fallback) {
    final normalizedBvid = bvid.trim();
    if (normalizedBvid.isEmpty) {
      return fallback;
    }
    return MediaSourceRef(
      value: BilibiliUrlParser.normalizeBvValue(normalizedBvid),
      kind: MediaSourceKind.bilibiliBv,
    );
  }

  MediaSourceRef _buildSingleVideoSourceRef(
    MediaSourceRef taskSourceRef,
    String bvid,
  ) {
    return taskSourceRef.kind == MediaSourceKind.url
        ? taskSourceRef
        : _buildVideoSourceRef(bvid, taskSourceRef);
  }

  // --- Sequential Export Logic ---

  String _episodeKey(BilibiliDownloadEpisode episode) {
    if (episode.outputPath != null && episode.outputPath!.isNotEmpty) {
      return episode.outputPath!;
    }
    return '${episode.bvid}_${episode.page.cid}_${episode.page.page}';
  }

  List<BilibiliDownloadEpisode> _getEpisodesInDisplayOrder() {
    final episodes = <BilibiliDownloadEpisode>[];
    for (final task in tasks) {
      for (final video in task.videos) {
        episodes.addAll(video.episodes);
      }
    }
    return episodes;
  }

  int _findEpisodeIndex(
    List<BilibiliDownloadEpisode> episodes,
    BilibiliDownloadEpisode target,
  ) {
    for (int i = 0; i < episodes.length; i++) {
      if (identical(episodes[i], target)) return i;
    }

    if (target.outputPath != null && target.outputPath!.isNotEmpty) {
      for (int i = 0; i < episodes.length; i++) {
        if (episodes[i].outputPath == target.outputPath) return i;
      }
    }

    return -1;
  }

  bool _isSequentialBlocker(BilibiliDownloadEpisode episode) {
    if (episode.isExported) return false;
    if (_importingEpisodeKeys.contains(_episodeKey(episode))) return true;

    return episode.status == DownloadStatus.queued ||
        episode.status == DownloadStatus.fetchingInfo ||
        episode.status == DownloadStatus.downloading ||
        episode.status == DownloadStatus.merging ||
        episode.status == DownloadStatus.checking ||
        episode.status == DownloadStatus.repairing ||
        episode.status == DownloadStatus.completed;
  }

  void _refreshCompletedEpisodeHints() {
    bool changed = false;

    for (final episode in _getEpisodesInDisplayOrder()) {
      if (episode.status != DownloadStatus.completed || episode.isExported) {
        continue;
      }

      final key = _episodeKey(episode);
      String desiredText = "已合成";

      if (_importingEpisodeKeys.contains(key)) {
        desiredText = "正在导出...";
      } else if (_sequentialImportFailedKeys.contains(key)) {
        desiredText = "导入失败，请手动重试";
      } else if (sequentialExport && _hasActivePredecessor(episode)) {
        desiredText = "等待前置导出...";
      }

      if (episode.downloadSpeed != desiredText) {
        episode.downloadSpeed = desiredText;
        changed = true;
      }
    }

    if (changed) {
      notifyListeners();
    }
  }

  BilibiliDownloadEpisode? _findNextSequentialExportCandidate() {
    for (final episode in _getEpisodesInDisplayOrder()) {
      final key = _episodeKey(episode);
      if (episode.status != DownloadStatus.completed ||
          episode.isExported ||
          episode.outputPath == null ||
          _importingEpisodeKeys.contains(key) ||
          _sequentialImportFailedKeys.contains(key)) {
        continue;
      }

      if (!_hasActivePredecessor(episode)) {
        return episode;
      }
    }

    return null;
  }

  Future<void> _processSequentialAutoImports() async {
    if (!autoImportToLibrary || !sequentialExport || libraryService == null) {
      _refreshCompletedEpisodeHints();
      return;
    }

    if (_isSequentialExportPumpRunning) {
      _refreshCompletedEpisodeHints();
      return;
    }

    _isSequentialExportPumpRunning = true;
    try {
      while (true) {
        _refreshCompletedEpisodeHints();
        final nextEpisode = _findNextSequentialExportCandidate();
        if (nextEpisode == null) break;

        final key = _episodeKey(nextEpisode);
        _importingEpisodeKeys.add(key);
        _sequentialImportFailedKeys.remove(key);
        nextEpisode.downloadSpeed = "正在导出...";
        notifyListeners();

        try {
          await importToLibrary(
            libraryService!,
            episode: nextEpisode,
            suppressSequentialPump: true,
          );
        } catch (e) {
          debugPrint(
            "Sequential export failed for ${nextEpisode.page.part}: $e",
          );
          _sequentialImportFailedKeys.add(key);
          nextEpisode.error = "导入媒体库失败，请手动重试";
        } finally {
          _importingEpisodeKeys.remove(key);
        }
      }
    } finally {
      _isSequentialExportPumpRunning = false;
      _refreshCompletedEpisodeHints();
      await saveTasks();
    }
  }

  bool _hasActivePredecessor(BilibiliDownloadEpisode currentEp) {
    final episodes = _getEpisodesInDisplayOrder();
    final currentIndex = _findEpisodeIndex(episodes, currentEp);
    if (currentIndex <= 0) return false;

    for (int i = 0; i < currentIndex; i++) {
      if (_isSequentialBlocker(episodes[i])) {
        return true;
      }
    }

    return false;
  }

  // Batch Pause
  void pauseSelected() {
    unawaited(_pauseSelectedImpl());
  }

  Future<void> _pauseSelectedImpl() async {
    final selectedEpisodes = _getSelectedEpisodes();
    bool changed = false;
    for (var ep in selectedEpisodes) {
      changed = _pauseEpisodeState(ep) || changed;
    }
    if (!changed) return;

    await saveTasks();
  }

  // --- Info Fetching ---

  Future<void> fetchAllInfos() async {
    final episodes = tasks
        .expand((t) => t.videos)
        .expand((v) => v.episodes)
        .where(
          (e) =>
              e.availableVideoQualities.isEmpty &&
              e.status != DownloadStatus.fetchingInfo &&
              e.status != DownloadStatus.downloading &&
              e.status != DownloadStatus.completed,
        )
        .toList();

    if (episodes.isEmpty) return;

    for (var ep in episodes) {
      await fetchEpisodeInfo(ep);
      await Future.delayed(const Duration(milliseconds: 200));
    }
    saveTasks();
  }

  BilibiliSubtitle? _selectBestSubtitle(List<BilibiliSubtitle> subtitles) {
    if (subtitles.isEmpty) return null;
    if (preferredSubtitleLang == "none") return null;

    final lang = preferredSubtitleLang.toLowerCase();

    // Match by 'lan' (e.g. zh-CN) OR 'lanDoc' (e.g. 中文)
    final candidates = subtitles.where((s) {
      final sLan = s.lan.toLowerCase();
      final sDoc = s.lanDoc.toLowerCase();

      // Check lan code (standard)
      if (sLan.startsWith(lang)) return true;

      // Check extended codes
      if (lang == "zh" && (sLan == "zho" || sLan == "chi")) return true;
      if (lang == "en" && (sLan == "eng")) return true;
      if (lang == "ja" && (sLan == "jpn" || sLan == "jap")) return true;

      // Check display name map (Case Insensitive)
      if (lang == "zh" &&
          (sDoc.contains("中文") ||
              sDoc.contains("chinese") ||
              sDoc.contains("han"))) {
        return true;
      }
      if (lang == "en" &&
          (sDoc.contains("english") ||
              sDoc.contains("英语") ||
              sDoc.contains("英文"))) {
        return true;
      }
      if (lang == "ja" &&
          (sDoc.contains("日本語") ||
              sDoc.contains("japanese") ||
              sDoc.contains("日语"))) {
        return true;
      }

      return false;
    }).toList();

    if (candidates.isEmpty) return null;

    // Create list of (index, subtitle) to ensure stable sort (tie-breaker)
    final candidatesWithIndex = candidates.asMap().entries.toList();

    candidatesWithIndex.sort((a, b) {
      final subA = a.value;
      final subB = b.value;

      // 1. AI Preference
      if (preferAiSubtitles) {
        if (subA.isAi && !subB.isAi) return -1;
        if (!subA.isAi && subB.isAi) return 1;
      } else {
        if (!subA.isAi && subB.isAi) return -1;
        if (subA.isAi && !subB.isAi) return 1;
      }

      // 2. Tie-breaker: Original Index
      return a.key.compareTo(b.key);
    });

    return candidatesWithIndex.first.value;
  }

  StreamItem? _restoreVideoQuality(
    List<StreamItem> streams,
    StreamItem? previous,
  ) {
    if (previous == null || streams.isEmpty) return null;
    try {
      return streams.firstWhere(
        (s) =>
            s.id == previous.id &&
            s.codecid == previous.codecid &&
            s.codecs == previous.codecs,
      );
    } catch (_) {}
    try {
      return streams.firstWhere(
        (s) => s.id == previous.id && s.codecid == previous.codecid,
      );
    } catch (_) {}
    try {
      return streams.firstWhere(
        (s) => s.id == previous.id && s.codecs == previous.codecs,
      );
    } catch (_) {}
    try {
      return streams.firstWhere((s) => s.id == previous.id);
    } catch (_) {}
    return null;
  }

  Future<void> fetchEpisodeInfo(
    BilibiliDownloadEpisode episode, {
    bool preserveRunningState = false,
  }) async {
    if (episode.status == DownloadStatus.fetchingInfo) return;

    final previousStatus = episode.status;
    final previousError = episode.error;
    final shouldPreserveState =
        preserveRunningState &&
        (previousStatus == DownloadStatus.queued ||
            previousStatus == DownloadStatus.downloading ||
            previousStatus == DownloadStatus.merging ||
            previousStatus == DownloadStatus.checking ||
            previousStatus == DownloadStatus.repairing);

    if (!shouldPreserveState) {
      episode.status = DownloadStatus.fetchingInfo;
      episode.error = null;
    }
    notifyListeners();

    try {
      final oldQuality = episode.selectedVideoQuality;
      final streamInfo = await apiService.fetchPlayUrl(
        episode.bvid,
        episode.page.cid,
      );

      final task = tasks.firstWhere(
        (t) => t.videos.any((v) => v.episodes.contains(episode)),
      );
      final video = task.videos.firstWhere((v) => v.episodes.contains(episode));

      final playerMetadata = await apiService.fetchPlayerMetadata(
        episode.bvid,
        episode.page.cid,
        aid: episode.page.aid ?? video.videoInfo.aid,
        durationSeconds: episode.page.duration,
      );

      episode.availableVideoQualities = streamInfo.videoStreams;
      final restoredQuality = _restoreVideoQuality(
        streamInfo.videoStreams,
        oldQuality,
      );
      if (restoredQuality != null) {
        episode.selectedVideoQuality = restoredQuality;
      } else if (streamInfo.videoStreams.isNotEmpty) {
        try {
          episode.selectedVideoQuality = streamInfo.videoStreams.firstWhere(
            (q) => q.id <= preferredQuality,
          );
        } catch (_) {
          episode.selectedVideoQuality = streamInfo.videoStreams.first;
        }
      }

      episode.availableSubtitles = playerMetadata.subtitles;
      episode.selectedSubtitle = _selectBestSubtitle(playerMetadata.subtitles);
      episode.chapters = playerMetadata.chapters;

      if (!shouldPreserveState) {
        episode.status = DownloadStatus.pending;
        episode.error = null;
      } else {
        episode.status = previousStatus;
        episode.error = previousError;
      }
    } catch (e) {
      if (!shouldPreserveState) {
        episode.error = "获取信息失败: $e";
        episode.status = DownloadStatus.failed;
      } else {
        episode.status = previousStatus;
        episode.error = previousError;
      }
    }
    notifyListeners();
  }

  Future<void> refreshEpisodeInfo(BilibiliDownloadEpisode episode) {
    return fetchEpisodeInfo(episode, preserveRunningState: true);
  }

  // --- Download Logic ---

  Future<void> startDownloadSelected() async {
    final selectedEpisodes = _getSelectedEpisodes()
        .where(
          (e) =>
              e.status == DownloadStatus.pending ||
              e.status == DownloadStatus.failed,
        )
        .toList();

    if (selectedEpisodes.isEmpty) return;

    for (var ep in selectedEpisodes) {
      if (!await _waitForPreviousEpisodeOperation(ep)) continue;
      if (ep.selectedVideoQuality == null) {
        await fetchEpisodeInfo(ep);
        if (ep.selectedVideoQuality == null) continue;
      }

      if (!_downloadQueue.contains(ep) &&
          ep.status != DownloadStatus.downloading) {
        ep.status = DownloadStatus.queued;
        _downloadQueue.add(ep);
      }
    }
    notifyListeners();
    processQueue();
  }

  Future<void> startSingleDownload(
    BilibiliDownloadEpisode ep, {
    bool toTop = false,
  }) async {
    if (!await _waitForPreviousEpisodeOperation(ep)) return;
    if (ep.selectedVideoQuality == null) {
      await fetchEpisodeInfo(ep);
      if (ep.selectedVideoQuality == null) return;
    }

    // If paused/failed/pending/queued, restart/queue it.
    if (ep.status != DownloadStatus.downloading) {
      ep.status = DownloadStatus.queued;
      if (!_downloadQueue.contains(ep)) {
        if (toTop) {
          _downloadQueue.insert(0, ep);
        } else {
          _downloadQueue.add(ep);
        }
      } else if (toTop) {
        // If already in queue but user wants toTop, move it
        _downloadQueue.remove(ep);
        _downloadQueue.insert(0, ep);
      }
      notifyListeners();
      processQueue();
    }
  }

  Future<void> pauseDownload(BilibiliDownloadEpisode ep) async {
    if (_pauseEpisodeState(ep)) {
      await saveTasks(episode: ep);
    }
  }

  bool _pauseEpisodeState(BilibiliDownloadEpisode ep) {
    if (_isEpisodeRunning(ep.status)) {
      final cancelToken = ep.cancelToken;
      ep.status = DownloadStatus.pending;
      ep.error = "已暂停";
      ep.downloadSpeed = null;
      ep.downloadSize = null;
      cancelToken?.cancel("User paused");
      return true;
    }
    if (_downloadQueue.remove(ep)) {
      ep.status = DownloadStatus.pending; // Exit queue
      ep.error = "已暂停";
      ep.downloadSpeed = null;
      ep.downloadSize = null;
      return true;
    }
    return false;
  }

  Duration _buildRetryDelay(int retryCount) {
    final attempt = retryCount <= 1 ? 1 : retryCount;
    if (attempt == 1) return const Duration(seconds: 1);
    if (attempt == 2) return const Duration(seconds: 2);
    if (attempt == 3) return const Duration(seconds: 4);
    return Duration(seconds: _maxRetryDelaySeconds);
  }

  Future<bool> _waitForRetryDelay(
    BilibiliDownloadEpisode ep,
    Duration delay,
  ) async {
    final deadline = DateTime.now().add(delay);
    while (true) {
      if (_isPauseRequestedDuringRetryDelay(ep)) {
        return false;
      }
      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) {
        return !_isPauseRequestedDuringRetryDelay(ep);
      }
      final slice = remaining > const Duration(milliseconds: 200)
          ? const Duration(milliseconds: 200)
          : remaining;
      await Future.delayed(slice);
    }
  }

  bool _isPauseRequestedDuringRetryDelay(BilibiliDownloadEpisode ep) {
    return ep.status == DownloadStatus.pending && ep.error == "已暂停";
  }

  void processQueue() {
    // 迭代替代递归，避免队列很大时栈溢出
    while (_activeDownloads < maxConcurrentDownloads &&
        _downloadQueue.isNotEmpty) {
      final ep = _downloadQueue.removeAt(0);
      if (_runningEpisodeOperations.containsKey(ep)) {
        ep.status = DownloadStatus.pending;
        ep.error = '上一次下载仍在停止中，请稍后重试';
        continue;
      }
      _activeDownloads++;
      late final Future<void> operation;
      operation = _processDownload(ep);
      _runningEpisodeOperations[ep] = operation;
      unawaited(
        operation
            .then<void>(
              (_) {},
              onError: (Object error, StackTrace stack) {
                developer.log(
                  'Unhandled Bilibili episode operation error',
                  error: error,
                  stackTrace: stack,
                );
              },
            )
            .whenComplete(() {
              if (identical(_runningEpisodeOperations[ep], operation)) {
                _runningEpisodeOperations.remove(ep);
              }
            }),
      );
    }
  }

  Future<bool> _waitForPreviousEpisodeOperation(
    BilibiliDownloadEpisode episode,
  ) async {
    final operation = _runningEpisodeOperations[episode];
    if (operation == null) return true;
    if (_isEpisodeRunning(episode.status) &&
        episode.cancelToken?.isCancelled != true) {
      return false;
    }
    try {
      await operation.timeout(const Duration(seconds: 20));
      if (identical(_runningEpisodeOperations[episode], operation)) {
        _runningEpisodeOperations.remove(episode);
      }
      return true;
    } on TimeoutException {
      episode.status = DownloadStatus.failed;
      episode.error = '上一次下载未能及时停止，请稍后重试';
      notifyListeners();
      return false;
    } catch (_) {
      if (identical(_runningEpisodeOperations[episode], operation)) {
        _runningEpisodeOperations.remove(episode);
      }
      return true;
    }
  }

  Future<void> _awaitEpisodeOperationStopped(
    BilibiliDownloadEpisode episode,
  ) async {
    final operation = _runningEpisodeOperations[episode];
    if (operation == null) return;
    try {
      await operation;
    } catch (_) {}
    if (identical(_runningEpisodeOperations[episode], operation)) {
      _runningEpisodeOperations.remove(episode);
    }
  }

  Future<void> _processDownload(BilibiliDownloadEpisode ep) async {
    if (ep.selectedVideoQuality == null) {
      _activeDownloads--; // Release slot immediately if invalid
      processQueue();
      return;
    }

    await _invalidateMissingResumeStateIfNeeded(ep);

    if (ep.hasResumeData && !_resumeMatchesSelectedQuality(ep)) {
      await _cleanupEpisodeArtifacts(
        ep,
        deleteCompletedOutput: true,
        forgetTrackedKey: true,
        clearResumeState: true,
      );
    }

    int retryCount = 0;
    bool success = false;
    bool slotReleased = false;
    bool preferSavedResumeUrls = ep.hasResumeData;
    bool suppressRetryBannerForNextAttempt = false;

    // Record original choices to restore after refresh
    // Subtitle logic: Index + Name as requested by user
    int? oldSubtitleIndex;
    String? oldSubtitleName;
    bool hadSubtitle = ep.selectedSubtitle != null;

    if (hadSubtitle) {
      oldSubtitleName = ep.selectedSubtitle!.lanDoc;
      oldSubtitleIndex = ep.availableSubtitles.indexOf(ep.selectedSubtitle!);
    }

    final oldQuality = ep.selectedVideoQuality;

    while (retryCount <= _maxDownloadRetryCount && !success) {
      ep.status = DownloadStatus.downloading;
      ep.progress = ep.hasResumeData ? ep.resumableProgress : 0.0;
      ep.downloadSpeed = ep.hasResumeData ? "继续下载中..." : null;
      ep.downloadSize = ep.hasResumeData ? _buildResumeSizeText(ep) : null;
      if (retryCount > 0 && !suppressRetryBannerForNextAttempt) {
        ep.error = "重试 $retryCount/$_maxDownloadRetryCount";
      } else {
        ep.error = null;
      }
      suppressRetryBannerForNextAttempt = false;
      ep.cancelToken = CancelToken(); // Create new token
      notifyListeners();

      try {
        // Find AID
        String? aid = ep.page.aid;
        if (aid == null) {
          try {
            final task = tasks.firstWhere(
              (t) => t.videos.any((v) => v.episodes.contains(ep)),
            );
            final video = task.videos.firstWhere(
              (v) => v.episodes.contains(ep),
            );
            aid = video.videoInfo.aid;
          } catch (_) {}
        }

        // Fetch Subtitles
        final playerMetadata = await apiService.fetchPlayerMetadata(
          ep.bvid,
          ep.page.cid,
          aid: aid,
          durationSeconds: ep.page.duration,
        );
        ep.availableSubtitles = playerMetadata.subtitles;
        ep.chapters = playerMetadata.chapters;

        // Restore Subtitle Logic
        if (hadSubtitle) {
          BilibiliSubtitle? match;

          // 1. Try Index + Name Match (Priority)
          if (oldSubtitleIndex != null &&
              oldSubtitleIndex >= 0 &&
              oldSubtitleIndex < ep.availableSubtitles.length) {
            if (ep.availableSubtitles[oldSubtitleIndex].lanDoc ==
                oldSubtitleName) {
              match = ep.availableSubtitles[oldSubtitleIndex];
            }
          }

          // 2. Try Name Match (Fallback)
          if (match == null && oldSubtitleName != null) {
            try {
              match = ep.availableSubtitles.firstWhere(
                (s) => s.lanDoc == oldSubtitleName,
              );
            } catch (_) {
              // Not found
            }
          }

          // 3. Fallback to default preference
          ep.selectedSubtitle =
              match ?? _selectBestSubtitle(ep.availableSubtitles);
        } else {
          ep.selectedSubtitle = null;
        }

        StreamItem? videoStream;
        StreamItem? audioStream;
        bool preparedForResume = ep.hasResumeData;

        if (preferSavedResumeUrls && ep.hasResumeData) {
          videoStream = _buildResumeStream(ep.videoResumeState);
          audioStream = _buildResumeStream(ep.audioResumeState);
        }

        if (videoStream == null || audioStream == null) {
          final streamInfo = await apiService.fetchPlayUrl(
            ep.bvid,
            ep.page.cid,
          );
          ep.availableVideoQualities = streamInfo.videoStreams;

          final restoredQuality = _restoreVideoQuality(
            streamInfo.videoStreams,
            oldQuality,
          );
          if (restoredQuality != null) {
            ep.selectedVideoQuality = restoredQuality;
          }

          StreamItem? fallbackVideoStream;
          if (ep.selectedVideoQuality != null &&
              streamInfo.videoStreams.any(
                (s) => s.id == ep.selectedVideoQuality!.id,
              )) {
            fallbackVideoStream = streamInfo.videoStreams.firstWhere(
              (s) => s.id == ep.selectedVideoQuality!.id,
            );
          } else if (streamInfo.videoStreams.isNotEmpty) {
            fallbackVideoStream = streamInfo.videoStreams.firstWhere(
              (s) => s.id <= preferredQuality,
              orElse: () => streamInfo.videoStreams.first,
            );
          }

          audioStream = streamInfo.audioStreams.isNotEmpty
              ? streamInfo.audioStreams.first
              : null;
          if (audioStream == null) throw Exception("No audio stream");

          if (ep.hasResumeData) {
            final matchedVideo = _matchStreamFromResume(
              streamInfo.videoStreams,
              ep.videoResumeState,
              fallback: fallbackVideoStream,
            );
            final matchedAudio = _matchStreamFromResume(
              streamInfo.audioStreams,
              ep.audioResumeState,
              fallback: audioStream,
            );

            if (matchedVideo == null || matchedAudio == null) {
              await _cleanupEpisodeArtifacts(
                ep,
                deleteCompletedOutput: true,
                forgetTrackedKey: true,
                clearResumeState: true,
              );
              await _prepareEpisodeTempArtifacts(ep);
              preparedForResume = false;
              ep.progress = 0.0;
              ep.downloadSize = null;
              ep.downloadSpeed = null;
              videoStream = fallbackVideoStream;
              audioStream = streamInfo.audioStreams.isNotEmpty
                  ? streamInfo.audioStreams.first
                  : null;
            } else {
              videoStream = matchedVideo;
              audioStream = matchedAudio;
            }
          } else {
            videoStream = fallbackVideoStream;
          }
        }

        if (videoStream == null || audioStream == null) {
          throw Exception("No media stream");
        }

        await _prepareEpisodeTempArtifacts(
          ep,
          preserveExisting: preparedForResume && ep.hasResumeData,
        );

        // Use a safe, unique filename
        final String safeFileName =
            "merged_${ep.bvid}_${ep.page.cid}_${DateTime.now().millisecondsSinceEpoch}";

        final outputPath = await _downloadManager.downloadAndMerge(
          videoStream: videoStream,
          audioStream: audioStream,
          subtitle: ep.selectedSubtitle,
          fileName: safeFileName,
          tempArtifactKey: ep.tempArtifactKey!,
          videoResumeState: ep.videoResumeState,
          audioResumeState: ep.audioResumeState,
          cancelToken: ep.cancelToken,
          maxVideoConnections: effectiveMaxConnectionsPerVideo,
          onProgress: (p) {
            ep.progress = p;
            _scheduleProgressNotify(ep);
          },
          onSpeedUpdate: (speed) {
            ep.downloadSpeed = speed;
            _scheduleProgressNotify(ep);
          },
          onSizeUpdate: (size) {
            ep.downloadSize = size;
            _scheduleProgressNotify(ep);
          },
          onStatusUpdate: (status) {
            ep.status = status;
            if (status != DownloadStatus.failed) {
              ep.error = null;
            }
            notifyListeners();
            scheduleSaveTasks(episode: ep);
          },
          onResumeStateChanged: (videoState, audioState) {
            _updateEpisodeResumeState(ep, videoState, audioState);
            if (retryCount == 0) {
              ep.error = null;
            }
            _persistResumeStateIfNeeded(ep);
            _scheduleProgressNotify(ep);
          },
          chapters: ep.chapters,
          onDownloadPhaseFinished: () {
            if (!slotReleased) {
              slotReleased = true;
              if (_activeDownloads > 0) _activeDownloads--;
              processQueue();
            }
          },
        );

        ep.status = DownloadStatus.completed;
        ep.outputPath = outputPath;
        ep.downloadSpeed = "合成完成，正在处理附加内容...";
        _scheduleProgressNotify(ep);
        if (downloadDanmaku) {
          try {
            final xml = await apiService.fetchDanmakuXml(ep.page.cid);
            final ass = BilibiliDanmakuAss.xmlToAss(xml);
            final danmakuPath = '${p.withoutExtension(outputPath)}.danmaku.ass';
            await File(danmakuPath).writeAsString(ass, flush: true);
            ep.danmakuPath = danmakuPath;
            ep.danmakuError = null;
          } catch (e, stack) {
            developer.log(
              'Danmaku download failed for cid=${ep.page.cid}',
              error: e,
              stackTrace: stack,
            );
            ep.danmakuPath = null;
            ep.danmakuError = 'download_failed';
          }
        } else {
          ep.danmakuPath = null;
          ep.danmakuError = null;
        }
        _clearEpisodeResumeState(ep);
        await _removePendingTempCleanupKey(ep.tempArtifactKey!);
        ep.tempArtifactKey = null;
        ep.progress = 1.0;
        ep.downloadSpeed = "已合成";
        ep.downloadSize = null;
        ep.error = null;
        await saveTasks(episode: ep);

        // Auto Import
        if (autoImportToLibrary && libraryService != null) {
          if (sequentialExport) {
            _refreshCompletedEpisodeHints();
            await saveTasks(episode: ep);
            await _processSequentialAutoImports();
          } else {
            await importToLibrary(libraryService!, episode: ep);
          }
        }

        success = true;
      } catch (e) {
        if (_shouldKeepPausedState(ep, e)) {
          ep.status = DownloadStatus.pending; // Reset to pending if cancelled
          ep.error = "已暂停";
          ep.downloadSpeed = null;
          ep.downloadSize = null;
          if (ep.hasResumeData) {
            ep.progress = ep.resumableProgress;
            _persistResumeStateIfNeeded(ep, force: true);
          }
          await saveTasks(episode: ep);
          break; // Stop retrying if cancelled
        } else if (e is DownloadUrlExpiredException &&
            ep.hasResumeData &&
            preferSavedResumeUrls) {
          preferSavedResumeUrls = false;
          ep.error = "恢复中";
          _scheduleProgressNotify(ep);
          final shouldRetry = await _waitForRetryDelay(
            ep,
            const Duration(seconds: 1),
          );
          if (!shouldRetry) {
            await saveTasks(episode: ep);
            break;
          }
          continue;
        } else if (e is DownloadUrlExpiredException &&
            retryCount < _maxDownloadRetryCount) {
          retryCount++;
          preferSavedResumeUrls = false;
          ep.error = '下载链接已刷新，正在继续下载';
          _scheduleProgressNotify(ep);
          final shouldRetry = await _waitForRetryDelay(
            ep,
            _buildRetryDelay(retryCount),
          );
          if (!shouldRetry) {
            await saveTasks(episode: ep);
            break;
          }
          continue;
        } else if (e is DownloadProgressStalledException) {
          developer.log(
            'Download stalled for ${ep.page.part}, retrying in background',
            error: e,
          );
          ep.error = null;
          ep.downloadSpeed = null;
          if (ep.hasResumeData) {
            ep.progress = ep.resumableProgress;
            ep.downloadSize = _buildResumeSizeText(ep);
            _persistResumeStateIfNeeded(ep, force: true);
          }
          _scheduleProgressNotify(ep);
          if (retryCount < _maxDownloadRetryCount) {
            retryCount++;
            suppressRetryBannerForNextAttempt = true;
            final shouldRetry = await _waitForRetryDelay(
              ep,
              const Duration(milliseconds: 300),
            );
            if (!shouldRetry) {
              await saveTasks(episode: ep);
              break;
            }
            continue;
          }
          ep.status = DownloadStatus.failed;
          ep.error = "下载错误，请重试";
          ep.downloadSize = null;
          await saveTasks(episode: ep);
          break;
        } else if (e is PostProcessTimeoutException) {
          ep.status = DownloadStatus.failed;
          ep.error = '${e.phase}超时，已跳过以继续后续队列';
          ep.downloadSpeed = null;
          ep.downloadSize = null;
          if (ep.hasResumeData) {
            ep.progress = ep.resumableProgress;
            _persistResumeStateIfNeeded(ep, force: true);
          }
          await saveTasks(episode: ep);
          break;
        } else if (e is DownloadIntegrityException) {
          ep.status = DownloadStatus.failed;
          ep.error = e.message;
          ep.downloadSpeed = null;
          ep.downloadSize = null;
          if (ep.hasResumeData) {
            ep.progress = ep.resumableProgress;
            _persistResumeStateIfNeeded(ep, force: true);
          }
          await saveTasks(episode: ep);
          break;
        } else if (e is PostProcessFailureException) {
          ep.status = DownloadStatus.failed;
          ep.error = '${e.phase}失败，请重试';
          ep.downloadSpeed = null;
          ep.downloadSize = null;
          if (ep.hasResumeData) {
            ep.progress = ep.resumableProgress;
            _persistResumeStateIfNeeded(ep, force: true);
          }
          await saveTasks(episode: ep);
          break;
        } else {
          bool isRetryable = false;
          if (e is DioException) {
            final statusCode = e.response?.statusCode;
            isRetryable =
                e.type == DioExceptionType.connectionTimeout ||
                e.type == DioExceptionType.receiveTimeout ||
                e.type == DioExceptionType.sendTimeout ||
                e.type == DioExceptionType.connectionError ||
                (e.error is SocketException) ||
                statusCode == 408 ||
                statusCode == 412 ||
                statusCode == 416 ||
                statusCode == 429 ||
                (statusCode != null && statusCode >= 500);
          }
          if (!isRetryable && e.toString().contains("Connection reset")) {
            isRetryable = true;
          }

          if (retryCount < _maxDownloadRetryCount && isRetryable) {
            retryCount++;
            final retryDelay = _buildRetryDelay(retryCount);
            ep.error =
                "${retryDelay.inSeconds}秒后重试 $retryCount/$_maxDownloadRetryCount";
            _scheduleProgressNotify(ep);

            final shouldRetry = await _waitForRetryDelay(ep, retryDelay);
            if (!shouldRetry) {
              await saveTasks(episode: ep);
              break;
            }
            continue;
          }

          ep.status = DownloadStatus.failed;
          ep.error = "下载错误，请重试"; // Specific text requested
          ep.downloadSpeed = null;
          ep.downloadSize = null;
          if (ep.hasResumeData) {
            ep.progress = ep.resumableProgress;
            _persistResumeStateIfNeeded(ep, force: true);
          }
          await saveTasks(episode: ep);
          break;
        }
      } finally {
        ep.cancelToken = null;
      }
    }

    // Ensure slot is released if download failed or finished without triggering callback
    if (!slotReleased) {
      if (_activeDownloads > 0) _activeDownloads--;
      processQueue();
    }
    _scheduleProgressNotify(ep);
  }

  // --- Management ---

  void _evictThumbnailUrl(String url) {
    if (url.isEmpty) return;
    final imageCache = PaintingBinding.instance.imageCache;
    imageCache.evict(NetworkImage(url));
    if (!url.contains('@') &&
        (url.contains('hdslb.com') || url.contains('bilivideo.com'))) {
      final sizes = <List<int>>[
        [80, 50],
        [44, 28],
        [40, 26],
      ];
      final scales = <double>[1.0, 1.25];
      for (final size in sizes) {
        for (final scale in scales) {
          final w = (size[0] * scale).round();
          final h = (size[1] * scale).round();
          final processedUrl = "$url@${w}w_${h}h_1c.webp";
          imageCache.evict(NetworkImage(processedUrl));
        }
      }
    }
  }

  void _evictTaskThumbnails(BilibiliDownloadTask task) {
    _evictThumbnailUrl(task.cover);
    for (var video in task.videos) {
      _evictThumbnailUrl(video.videoInfo.pic);
    }
  }

  bool _isEpisodeRunning(DownloadStatus status) {
    return status == DownloadStatus.fetchingInfo ||
        status == DownloadStatus.downloading ||
        status == DownloadStatus.merging ||
        status == DownloadStatus.checking ||
        status == DownloadStatus.repairing;
  }

  bool _isEpisodeKeepingAwake(BilibiliDownloadEpisode episode) {
    if (_importingEpisodeKeys.contains(_episodeKey(episode))) {
      return true;
    }
    switch (episode.status) {
      case DownloadStatus.downloading:
      case DownloadStatus.merging:
      case DownloadStatus.checking:
      case DownloadStatus.repairing:
        return true;
      case DownloadStatus.pending:
      case DownloadStatus.queued:
      case DownloadStatus.fetchingInfo:
      case DownloadStatus.completed:
      case DownloadStatus.failed:
        return false;
    }
  }

  void _syncDownloadKeepAwake() {
    final shouldKeepAwake =
        supportsProcessingKeepAwakeToggle &&
        keepScreenAwakeDuringProcessing &&
        hasProcessingEpisodes;
    if (_lastAppliedKeepAwakeActive == shouldKeepAwake) {
      return;
    }
    _lastAppliedKeepAwakeActive = shouldKeepAwake;
    AppWakelockCoordinator.setActive(
      AppWakelockCoordinator.bilibiliDownloadReason,
      shouldKeepAwake,
    );
  }

  void _refreshTaskMetrics() {
    var nextTaskCount = tasks.length;
    final nextSelectionSummary = BilibiliSelectionSummary.fromTasks(tasks);
    var nextProcessingEpisodeCount = _importingEpisodeKeys.length;
    for (final task in tasks) {
      for (final video in task.videos) {
        for (final episode in video.episodes) {
          if (_isEpisodeKeepingAwake(episode)) {
            nextProcessingEpisodeCount++;
          }
        }
      }
    }
    _taskCount = nextTaskCount;
    _selectionSummary = nextSelectionSummary;
    _selectedEpisodeCount = nextSelectionSummary.selectedItemCount;
    _processingEpisodeCount = nextProcessingEpisodeCount;
  }

  bool _shouldKeepPausedState(BilibiliDownloadEpisode ep, Object error) {
    if (ep.status == DownloadStatus.pending && ep.error == "已暂停") {
      return true;
    }

    if (error is DioException && error.type == DioExceptionType.cancel) {
      return ep.status == DownloadStatus.pending || ep.error == "已暂停";
    }

    return ep.cancelToken?.isCancelled == true &&
        ep.status == DownloadStatus.pending &&
        ep.error == "已暂停";
  }

  String _episodeRuntimeKey(BilibiliDownloadEpisode ep) {
    return ep.tempArtifactKey ?? "${ep.bvid}_${ep.page.cid}";
  }

  Future<bool> _episodeResumeFilesExist(BilibiliDownloadEpisode ep) async {
    for (final state in <DownloadPartResumeState?>[
      ep.videoResumeState,
      ep.audioResumeState,
    ]) {
      if (state == null || !state.hasData) continue;
      for (final path in _resumeArtifactPaths(state)) {
        if (await File(path).exists()) {
          return true;
        }
      }
    }
    return false;
  }

  Iterable<String> _resumeArtifactPaths(DownloadPartResumeState state) sync* {
    if (state.tempPath.isNotEmpty) {
      yield state.tempPath;
      yield '${state.tempPath}.assembling';
    }
    for (final part in state.rangeParts) {
      final path = part.tempPath;
      if (path != null && path.isNotEmpty) yield path;
    }
  }

  Future<void> _invalidateMissingResumeStateIfNeeded(
    BilibiliDownloadEpisode ep,
  ) async {
    if (!ep.hasResumeData) return;
    if (await _episodeResumeFilesExist(ep)) return;

    _clearEpisodeResumeState(ep);
    if (ep.status == DownloadStatus.pending && ep.error == "已暂停") {
      ep.error = null;
      ep.progress = 0.0;
    }
    await saveTasks();
  }

  bool _resumeMatchesSelectedQuality(BilibiliDownloadEpisode ep) {
    final selected = ep.selectedVideoQuality;
    final resume = ep.videoResumeState;
    if (selected == null || resume == null) return true;
    return selected.id == resume.streamId &&
        selected.codecid == resume.codecid &&
        selected.codecs == resume.codecs;
  }

  StreamItem? _buildResumeStream(DownloadPartResumeState? state) {
    final url = state?.url;
    if (state == null || url == null || url.isEmpty) return null;
    return StreamItem(
      id: state.streamId,
      baseUrl: url,
      bandwidth: 0,
      codecs: state.codecs,
      codecid: state.codecid,
      mimeType: state.mimeType,
    );
  }

  StreamItem? _matchStreamFromResume(
    List<StreamItem> streams,
    DownloadPartResumeState? state, {
    StreamItem? fallback,
  }) {
    if (streams.isEmpty) return fallback;
    if (state == null) return fallback ?? streams.first;
    try {
      return streams.firstWhere(
        (stream) =>
            stream.id == state.streamId &&
            stream.codecid == state.codecid &&
            stream.codecs == state.codecs,
      );
    } catch (_) {}
    try {
      return streams.firstWhere(
        (stream) =>
            stream.id == state.streamId && stream.codecid == state.codecid,
      );
    } catch (_) {}
    try {
      return streams.firstWhere((stream) => stream.id == state.streamId);
    } catch (_) {}
    return fallback;
  }

  void _updateEpisodeResumeState(
    BilibiliDownloadEpisode ep,
    DownloadPartResumeState? videoState,
    DownloadPartResumeState? audioState,
  ) {
    ep.videoResumeState = videoState;
    ep.audioResumeState = audioState;
    ep.canResume =
        (videoState?.hasData ?? false) || (audioState?.hasData ?? false);
    if (ep.canResume) {
      ep.progress = ep.resumableProgress;
    }
  }

  void _clearEpisodeResumeState(BilibiliDownloadEpisode ep) {
    ep.clearResumeState();
    _lastResumePersistAt.remove(_episodeRuntimeKey(ep));
  }

  void _persistResumeStateIfNeeded(
    BilibiliDownloadEpisode ep, {
    bool force = false,
  }) {
    if (!ep.canResume) return;
    final key = _episodeRuntimeKey(ep);
    final now = DateTime.now();
    final last = _lastResumePersistAt[key];
    if (!force &&
        last != null &&
        now.difference(last) < const Duration(milliseconds: 900)) {
      return;
    }
    _lastResumePersistAt[key] = now;
    scheduleSaveTasks(episode: ep);
  }

  String _formatBytes(int bytes) {
    if (bytes >= 1024 * 1024 * 1024) {
      return "${(bytes / 1024 / 1024 / 1024).toStringAsFixed(1)} GB";
    }
    return "${(bytes / 1024 / 1024).toStringAsFixed(1)} MB";
  }

  String? _buildResumeSizeText(BilibiliDownloadEpisode ep) {
    final videoDownloaded = ep.videoResumeState?.downloadedBytes ?? 0;
    final audioDownloaded = ep.audioResumeState?.downloadedBytes ?? 0;
    final videoTotal = ep.videoResumeState?.totalBytes;
    final audioTotal = ep.audioResumeState?.totalBytes;
    final downloaded = videoDownloaded + audioDownloaded;
    final total = (videoTotal ?? 0) + (audioTotal ?? 0);
    if (downloaded <= 0) return null;
    if (total > 0) {
      return "${_formatBytes(downloaded)} / ${_formatBytes(total)}";
    }
    return _formatBytes(downloaded);
  }

  String _createTempArtifactKey(BilibiliDownloadEpisode ep) {
    final uuid = const Uuid().v4().replaceAll('-', '');
    return "${ep.bvid}_${ep.page.cid}_$uuid";
  }

  Future<Set<String>> _loadPendingTempCleanupKeys() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(_pendingTempCleanupPrefsKey)?.toSet() ??
        <String>{};
  }

  Future<void> _savePendingTempCleanupKeys(Set<String> keys) async {
    final prefs = await SharedPreferences.getInstance();
    if (keys.isEmpty) {
      await prefs.remove(_pendingTempCleanupPrefsKey);
      return;
    }
    await prefs.setStringList(
      _pendingTempCleanupPrefsKey,
      keys.toList()..sort(),
    );
  }

  Future<void> _addPendingTempCleanupKey(String key) async {
    final keys = await _loadPendingTempCleanupKeys();
    if (keys.add(key)) {
      await _savePendingTempCleanupKeys(keys);
    }
  }

  Future<void> _removePendingTempCleanupKey(String key) async {
    final keys = await _loadPendingTempCleanupKeys();
    if (keys.remove(key)) {
      await _savePendingTempCleanupKeys(keys);
    }
  }

  Future<List<String>> _buildTrackedTempPaths(String key) async {
    final tempDir = await getTemporaryDirectory();
    final safeKey = key.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    final prefix = "bbdown_$safeKey";
    final outputPath = p.join(tempDir.path, "${prefix}_output.mp4");
    return <String>[
      p.join(tempDir.path, "${prefix}_video.m4s"),
      p.join(tempDir.path, "${prefix}_video.m4s.assembling"),
      p.join(tempDir.path, "${prefix}_audio.m4s"),
      p.join(tempDir.path, "${prefix}_subtitle.srt"),
      p.join(tempDir.path, "${prefix}_chapters.ffmeta"),
      outputPath,
      _deriveSidecarPath(outputPath),
      p.join(tempDir.path, "repaired_${p.basename(outputPath)}"),
    ];
  }

  Future<bool> _cleanupTrackedTempArtifacts(String key) async {
    bool allCleared = true;
    for (final path in await _buildTrackedTempPaths(key)) {
      await _deleteFileIfExists(path);
      if (await File(path).exists()) {
        allCleared = false;
      }
    }
    final tempDir = await getTemporaryDirectory();
    final safeKey = key.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    final rangePrefix = 'bbdown_${safeKey}_video.m4s.range_';
    if (await tempDir.exists()) {
      await for (final entity in tempDir.list()) {
        if (entity is! File) continue;
        final name = entity.uri.pathSegments.last;
        if (!name.startsWith(rangePrefix) || !name.endsWith('.part')) {
          continue;
        }
        await _deleteFileIfExists(entity.path);
        if (await entity.exists()) allCleared = false;
      }
    }
    if (allCleared) {
      await _removePendingTempCleanupKey(key);
    }
    return allCleared;
  }

  Future<void> _cleanupEpisodeArtifacts(
    BilibiliDownloadEpisode ep, {
    bool deleteCompletedOutput = false,
    bool forgetTrackedKey = false,
    bool clearResumeState = false,
  }) async {
    final trackedKey = ep.tempArtifactKey;
    if (trackedKey != null) {
      await _addPendingTempCleanupKey(trackedKey);
      final cleared = await _cleanupTrackedTempArtifacts(trackedKey);
      if (cleared || forgetTrackedKey) {
        ep.tempArtifactKey = null;
      }
    }

    if (deleteCompletedOutput && ep.outputPath != null) {
      await _deleteTempArtifacts(ep.outputPath!);
      if (forgetTrackedKey || await _isWithinTempDir(ep.outputPath!)) {
        ep.outputPath = null;
      }
    }

    if (deleteCompletedOutput && ep.danmakuPath != null) {
      final danmakuPath = ep.danmakuPath!;
      if (await _isWithinTempDir(danmakuPath)) {
        await _deleteFileIfExists(danmakuPath);
        ep.danmakuPath = null;
      }
      ep.danmakuError = null;
    }

    if (clearResumeState) {
      _clearEpisodeResumeState(ep);
    }
  }

  Future<void> _prepareEpisodeTempArtifacts(
    BilibiliDownloadEpisode ep, {
    bool preserveExisting = false,
  }) async {
    if (preserveExisting && ep.tempArtifactKey != null) {
      ep.outputPath = null;
      await _saveAllTaskSnapshotsNow();
      return;
    }
    if (ep.tempArtifactKey != null) {
      await _cleanupEpisodeArtifacts(ep, forgetTrackedKey: true);
    }
    ep.tempArtifactKey = _createTempArtifactKey(ep);
    ep.outputPath = null;
    await _saveAllTaskSnapshotsNow();
  }

  Future<void> _cleanupPersistedTempArtifacts() async {
    final trackedKeys = await _loadPendingTempCleanupKeys();
    final protectedKeys = <String>{};
    for (final task in tasks) {
      for (final video in task.videos) {
        for (final ep in video.episodes) {
          if (ep.tempArtifactKey != null && ep.hasResumeData) {
            protectedKeys.add(ep.tempArtifactKey!);
          } else if (ep.tempArtifactKey != null) {
            trackedKeys.add(ep.tempArtifactKey!);
          }
        }
      }
    }

    trackedKeys.removeAll(protectedKeys);

    if (trackedKeys.isEmpty) {
      return;
    }

    bool changed = false;
    for (final key in trackedKeys.toList()) {
      final cleared = await _cleanupTrackedTempArtifacts(key);
      if (!cleared) {
        continue;
      }
      for (final task in tasks) {
        for (final video in task.videos) {
          for (final ep in video.episodes) {
            if (ep.tempArtifactKey == key) {
              ep.tempArtifactKey = null;
              _clearEpisodeResumeState(ep);
              if (ep.outputPath != null &&
                  await _isWithinTempDir(ep.outputPath!)) {
                ep.outputPath = null;
              }
              changed = true;
            }
          }
        }
      }
    }

    if (changed) {
      await _saveAllTaskSnapshotsNow();
    }
  }

  String _deriveSidecarPath(String path) {
    return path.replaceAll(RegExp(r'\.[a-zA-Z0-9]+$'), '.srt');
  }

  Future<bool> _isWithinTempDir(String path) async {
    final tempDir = await getTemporaryDirectory();
    return p.isWithin(tempDir.path, path);
  }

  Future<void> _safeMoveFile(File source, String targetPath) async {
    final targetFile = File(targetPath);
    if (!await targetFile.parent.exists()) {
      await targetFile.parent.create(recursive: true);
    }

    // 1. Try rename first (instant if on same drive)
    try {
      await source.rename(targetPath);
      return;
    } catch (e) {
      debugPrint("Rename failed: $e, falling back to safe chunked copy.");
    }

    // 2. Fallback to chunked copy to avoid OOM or OS limits
    final rafSource = await source.open(mode: FileMode.read);
    final rafTarget = await targetFile.open(mode: FileMode.write);
    try {
      final length = await rafSource.length();
      int offset = 0;
      const chunkSize = 1024 * 1024 * 4; // 4MB chunks
      while (offset < length) {
        final bytes = await rafSource.read(chunkSize);
        await rafTarget.writeFrom(bytes);
        offset += bytes.length;
        // Yield to event loop to prevent UI freezing
        await Future.delayed(const Duration(milliseconds: 1));
      }
    } finally {
      await rafSource.close();
      await rafTarget.close();
    }

    // 3. Delete source after successful copy
    await source.delete();
  }

  Future<void> _deleteFileIfExists(String path) async {
    try {
      final file = File(path);
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {}
  }

  Future<void> _deleteTempArtifacts(String outputPath) async {
    if (await _isWithinTempDir(outputPath)) {
      await _deleteFileIfExists(outputPath);
    }
    final sidecarPath = _deriveSidecarPath(outputPath);
    if (sidecarPath != outputPath && await _isWithinTempDir(sidecarPath)) {
      await _deleteFileIfExists(sidecarPath);
    }
  }

  bool _isTempArtifactName(String name) {
    return name.startsWith("temp_") ||
        name.startsWith("merged_") ||
        name.startsWith("repaired_") ||
        name.startsWith("bbdown_");
  }

  Future<void> _cleanupTempOrphans({Duration? maxAge}) async {
    try {
      final tempDir = await getTemporaryDirectory();
      if (!await tempDir.exists()) return;

      final activePaths = <String>{};
      for (var task in tasks) {
        for (var video in task.videos) {
          for (var ep in video.episodes) {
            if (ep.outputPath != null) {
              final outputPath = p.normalize(ep.outputPath!);
              activePaths.add(outputPath);
              final sidecar = _deriveSidecarPath(outputPath);
              if (sidecar != outputPath) {
                activePaths.add(p.normalize(sidecar));
              }
            }
            if (ep.videoResumeState != null) {
              activePaths.addAll(
                _resumeArtifactPaths(ep.videoResumeState!).map(p.normalize),
              );
            }
            if (ep.audioResumeState != null) {
              activePaths.addAll(
                _resumeArtifactPaths(ep.audioResumeState!).map(p.normalize),
              );
            }
          }
        }
      }

      final threshold = maxAge ?? const Duration(hours: 24);
      final now = DateTime.now();

      await for (final entity in tempDir.list()) {
        if (entity is! File) continue;
        final name = entity.uri.pathSegments.last;
        if (!_isTempArtifactName(name)) continue;
        final path = p.normalize(entity.path);
        if (activePaths.contains(path)) continue;

        final stat = await entity.stat();
        final age = now.difference(stat.modified);
        if (threshold > Duration.zero && age < threshold) continue;

        try {
          await entity.delete();
        } catch (_) {}
      }
    } catch (e) {
      debugPrint("Failed to clean temp orphans: $e");
    }
  }

  Future<TemporaryStorageCategoryReport> buildTemporaryStorageReport() async {
    final files = await _collectClearableTemporaryStorageFiles();
    var totalBytes = 0;
    for (final file in files) {
      totalBytes += await _safeTempFileSize(file);
    }
    final hasProtectedTasks = _getProtectedTempArtifactKeys().isNotEmpty;

    return TemporaryStorageCategoryReport(
      id: 'bilibili_download_temp',
      title: 'B 站下载临时文件',
      description: 'BBDown 下载、合成、校验与断点续传过程中生成的临时媒体文件',
      fileCount: files.length,
      totalBytes: totalBytes,
      canClean: files.isNotEmpty,
      note: files.isEmpty
          ? (hasProtectedTasks
                ? '当前存在运行中或可续传的下载任务，本类临时文件已受保护。'
                : '未发现可安全清理的 B 站下载临时文件。')
          : (hasProtectedTasks ? '运行中或可续传任务的临时文件已自动跳过。' : null),
    );
  }

  Future<void> clearTemporaryStorageArtifacts() async {
    final protectedKeys = _getProtectedTempArtifactKeys();
    final pendingKeys = await _loadPendingTempCleanupKeys();
    final clearableKeys = <String>{...pendingKeys};

    for (final task in tasks) {
      for (final video in task.videos) {
        for (final ep in video.episodes) {
          final key = ep.tempArtifactKey;
          if (key != null && key.isNotEmpty && !protectedKeys.contains(key)) {
            clearableKeys.add(key);
          }
        }
      }
    }

    for (final key in clearableKeys) {
      await _cleanupTrackedTempArtifacts(key);
    }

    final orphanFiles = await _collectClearableTemporaryStorageFiles();
    for (final file in orphanFiles) {
      try {
        if (await file.exists()) {
          await file.delete();
        }
      } catch (_) {}
    }

    var changed = false;
    for (final task in tasks) {
      for (final video in task.videos) {
        for (final ep in video.episodes) {
          final key = ep.tempArtifactKey;
          if (key != null && clearableKeys.contains(key)) {
            ep.tempArtifactKey = null;
            _clearEpisodeResumeState(ep);
            if (ep.outputPath != null &&
                await _isWithinTempDir(ep.outputPath!)) {
              ep.outputPath = null;
            }
            changed = true;
          }
        }
      }
    }
    if (changed) {
      await saveTasks();
    }
  }

  Set<String> _getProtectedTempArtifactKeys() {
    final protectedKeys = <String>{};
    for (final task in tasks) {
      for (final video in task.videos) {
        for (final ep in video.episodes) {
          final key = ep.tempArtifactKey;
          if (key == null || key.isEmpty) {
            continue;
          }
          if (_isEpisodeRunning(ep.status) || ep.hasResumeData) {
            protectedKeys.add(key);
          }
        }
      }
    }
    return protectedKeys;
  }

  Future<Set<String>> _collectProtectedTemporaryStoragePaths() async {
    final protectedPaths = <String>{};
    final protectedKeys = _getProtectedTempArtifactKeys();
    for (final key in protectedKeys) {
      for (final path in await _buildTrackedTempPaths(key)) {
        protectedPaths.add(p.normalize(path));
      }
    }

    for (final task in tasks) {
      for (final video in task.videos) {
        for (final ep in video.episodes) {
          if (!_isEpisodeRunning(ep.status) && !ep.hasResumeData) {
            continue;
          }
          final outputPath = ep.outputPath;
          if (outputPath != null && outputPath.isNotEmpty) {
            protectedPaths.add(p.normalize(outputPath));
            protectedPaths.add(p.normalize(_deriveSidecarPath(outputPath)));
          }
          if (ep.videoResumeState != null) {
            protectedPaths.addAll(
              _resumeArtifactPaths(ep.videoResumeState!).map(p.normalize),
            );
          }
          if (ep.audioResumeState != null) {
            protectedPaths.addAll(
              _resumeArtifactPaths(ep.audioResumeState!).map(p.normalize),
            );
          }
        }
      }
    }
    return protectedPaths;
  }

  Future<List<File>> _collectClearableTemporaryStorageFiles() async {
    final tempDir = await getTemporaryDirectory();
    if (!await tempDir.exists()) {
      return const <File>[];
    }

    final protectedPaths = await _collectProtectedTemporaryStoragePaths();
    final clearableFiles = <String, File>{};
    final pendingKeys = await _loadPendingTempCleanupKeys();

    for (final key in pendingKeys) {
      if (_getProtectedTempArtifactKeys().contains(key)) {
        continue;
      }
      for (final path in await _buildTrackedTempPaths(key)) {
        final file = File(path);
        if (protectedPaths.contains(p.normalize(file.path))) {
          continue;
        }
        if (await file.exists()) {
          clearableFiles[p.normalize(file.path)] = file;
        }
      }
    }

    await for (final entity in tempDir.list()) {
      if (entity is! File) {
        continue;
      }
      final name = entity.uri.pathSegments.last;
      if (!_isTempArtifactName(name)) {
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

  Future<int> _safeTempFileSize(File file) async {
    try {
      if (!await file.exists()) {
        return 0;
      }
      return await file.length();
    } catch (_) {
      return 0;
    }
  }

  void removeSelected() async {
    final selectedEpisodes = _getSelectedEpisodes();
    final tasksToEvict = <BilibiliDownloadTask>{};
    for (var ep in selectedEpisodes) {
      BilibiliDownloadTask? task;
      for (var t in tasks) {
        if (t.videos.any((v) => v.episodes.contains(ep))) {
          task = t;
          break;
        }
      }
      if (task != null) {
        tasksToEvict.add(task);
      }
    }
    for (var task in tasksToEvict) {
      _evictTaskThumbnails(task);
    }

    // Stop any active episodes first
    for (var ep in selectedEpisodes) {
      if (_isEpisodeRunning(ep.status)) {
        ep.cancelToken?.cancel("Task deleted");
        ep.status = DownloadStatus.failed;
      }

      if (_downloadQueue.contains(ep)) {
        _downloadQueue.remove(ep);
      }
    }

    await Future.wait<void>([
      for (final ep in selectedEpisodes) _awaitEpisodeOperationStopped(ep),
    ]);

    for (var ep in selectedEpisodes) {
      await _cleanupEpisodeArtifacts(
        ep,
        deleteCompletedOutput: true,
        forgetTrackedKey: true,
        clearResumeState: true,
      );
    }

    for (var task in tasks) {
      for (var video in task.videos) {
        video.episodes.removeWhere((e) => e.isSelected);
      }
      task.videos.removeWhere((v) => v.episodes.isEmpty);
    }
    tasks.removeWhere((t) => t.videos.isEmpty);
    _rebuildTaskIndex();
    _metricsDirty = true;

    await saveTasks();
  }

  Future<void> removeEpisode(
    BilibiliDownloadEpisode ep,
    BilibiliDownloadTask task,
  ) async {
    if (_isEpisodeRunning(ep.status)) {
      ep.cancelToken?.cancel("Task deleted");
      ep.status = DownloadStatus.failed;
    }
    _evictTaskThumbnails(task);
    if (_downloadQueue.contains(ep)) {
      _downloadQueue.remove(ep);
    }

    await _awaitEpisodeOperationStopped(ep);

    await _cleanupEpisodeArtifacts(
      ep,
      deleteCompletedOutput: true,
      forgetTrackedKey: true,
      clearResumeState: true,
    );

    for (var v in task.videos) {
      if (v.episodes.contains(ep)) {
        v.episodes.remove(ep);
        break;
      }
    }
    task.videos.removeWhere((v) => v.episodes.isEmpty);
    if (task.videos.isEmpty) {
      tasks.remove(task);
    }
    _rebuildTaskIndex();
    _metricsDirty = true;
    await saveTasks();
  }

  void deleteAllTasks() async {
    for (var task in tasks) {
      _evictTaskThumbnails(task);
    }
    // 1. Clear Queue and Cancel All Active
    _downloadQueue.clear();

    for (var task in tasks) {
      for (var video in task.videos) {
        for (var ep in video.episodes) {
          if (_isEpisodeRunning(ep.status)) {
            ep.cancelToken?.cancel("Deleting all tasks");
          }
        }
      }
    }

    await Future.wait<void>([
      for (final operation in _runningEpisodeOperations.values.toList())
        operation.catchError((_) {}),
    ]);
    _activeDownloads = 0;

    for (var task in tasks) {
      for (var video in task.videos) {
        for (var ep in video.episodes) {
          await _cleanupEpisodeArtifacts(
            ep,
            deleteCompletedOutput: true,
            forgetTrackedKey: true,
            clearResumeState: true,
          );
        }
      }
    }

    tasks.clear();
    _rebuildTaskIndex();
    _metricsDirty = true;
    await _cleanupTempOrphans(maxAge: Duration.zero);
    await saveTasks();
  }

  List<BilibiliDownloadEpisode> _getSelectedEpisodes() {
    return tasks
        .expand((t) => t.videos)
        .expand((v) => v.episodes)
        .where((e) => e.isSelected)
        .toList();
  }

  void selectAll() {
    bool anyUnselected = tasks.any((t) => !t.isSelected);
    bool target = anyUnselected;

    for (var t in tasks) {
      t.isSelected = target;
      for (var v in t.videos) {
        v.isSelected = target;
        for (var e in v.episodes) {
          e.isSelected = target;
        }
      }
    }
    _metricsDirty = true;
    notifyListeners();
  }

  void applyQualitySettingsToPendingTasks() {
    for (var task in tasks) {
      for (var video in task.videos) {
        for (var ep in video.episodes) {
          if (ep.status == DownloadStatus.pending ||
              ep.status == DownloadStatus.failed ||
              (ep.status == DownloadStatus.completed &&
                  ep.outputPath == null)) {
            // Update Video Quality
            if (ep.availableVideoQualities.isNotEmpty) {
              StreamItem? bestMatch;
              try {
                bestMatch = ep.availableVideoQualities.firstWhere(
                  (q) => q.id <= preferredQuality,
                );
              } catch (_) {
                bestMatch = ep.availableVideoQualities.first;
              }
              ep.selectedVideoQuality = bestMatch;
            }

            // Update Subtitle Selection
            if (ep.availableSubtitles.isNotEmpty) {
              ep.selectedSubtitle = _selectBestSubtitle(ep.availableSubtitles);
            }
          }
        }
      }
    }
    notifyListeners();
  }

  // --- Helper Methods for Library Import ---

  Future<String?> _findCollectionId(
    LibraryService library,
    String name,
    String? parentId,
  ) async {
    final contents = library.getContents(parentId);
    for (var item in contents) {
      if (item is VideoCollection && item.name == name) {
        return item.id;
      }
    }
    return null;
  }

  Future<String> _getOrCreateCollection(
    LibraryService library,
    String name,
    String? parentId,
    MediaSourceRef? sourceRef,
  ) async {
    final existingId = await _findCollectionId(library, name, parentId);
    if (existingId != null) {
      await library.updateCollectionSourceRefIfMissing(existingId, sourceRef);
      return existingId;
    }

    final newCollection = await library.createCollection(
      name,
      parentId,
      sourceRef: sourceRef,
    );
    return newCollection.id;
  }

  Future<String?> _downloadCoverToThumbDir(
    Directory thumbDir,
    String key,
    String coverUrl,
  ) async {
    if (coverUrl.isEmpty) return null;
    try {
      final ext = coverUrl.split('.').last.split('?').first;
      final safeExt = (ext.length > 4 || ext.isEmpty) ? 'jpg' : ext;
      final filePath = "${thumbDir.path}/$key.$safeExt";

      final file = File(filePath);
      if (await file.exists()) return filePath;

      final resp = await apiService.dio.get(
        coverUrl,
        options: Options(responseType: ResponseType.bytes),
      );
      await file.writeAsBytes(resp.data);
      return filePath;
    } catch (e) {
      return null;
    }
  }

  Future<void> _ensureCollectionThumbnail(
    LibraryService library,
    Directory thumbDir,
    String collectionId,
    String coverUrl,
  ) async {
    final col = library.getCollection(collectionId);
    if (col == null) return;

    final currentPath = col.thumbnailPath;
    if (currentPath != null && currentPath.isNotEmpty) {
      final file = File(currentPath);
      if (await file.exists()) return;
    }

    final savedPath = await _downloadCoverToThumbDir(
      thumbDir,
      "collection_$collectionId",
      coverUrl,
    );
    if (savedPath == null) return;

    ThumbnailCacheService().evictFromCache(collectionId);
    await library.updateCollectionThumbnail(collectionId, savedPath);
  }

  // --- Import ---

  Future<int> importToLibrary(
    LibraryService library, {
    BilibiliDownloadEpisode? episode,
    String? targetFolderId,
    bool suppressSequentialPump = false,
  }) async {
    List<BilibiliDownloadEpisode> completedEpisodes;
    if (episode != null) {
      if (episode.status != DownloadStatus.completed ||
          episode.outputPath == null) {
        return 0;
      }
      completedEpisodes = [episode];
    } else {
      completedEpisodes = _getSelectedEpisodes()
          .where(
            (e) => e.status == DownloadStatus.completed && e.outputPath != null,
          )
          .toList();
    }

    if (completedEpisodes.isEmpty) return 0;

    Directory baseDir;
    if (customDownloadPath != null && customDownloadPath!.isNotEmpty) {
      baseDir = Directory(customDownloadPath!);
      if (!await baseDir.exists()) {
        try {
          await baseDir.create(recursive: true);
        } catch (e) {
          debugPrint(
            "Failed to create custom dir, falling back to default: $e",
          );
          baseDir = Directory(
            '${(await getApplicationDocumentsDirectory()).path}/imported_videos',
          );
        }
      }
    } else {
      if (Platform.isMacOS) {
        final downloadDir = await getDownloadsDirectory();
        if (downloadDir != null) {
          baseDir = Directory(p.join(downloadDir.path, 'imported_videos'));
        } else {
          final dataRoot = await SettingsService().resolveLargeDataRootDir();
          baseDir = Directory(p.join(dataRoot.path, 'imported_videos'));
        }
      } else {
        final dataRoot = await SettingsService().resolveLargeDataRootDir();
        baseDir = Directory(p.join(dataRoot.path, 'imported_videos'));
      }
    }

    if (!await baseDir.exists()) await baseDir.create(recursive: true);

    final dataRoot = await SettingsService().resolveLargeDataRootDir();
    final thumbDir = Directory(p.join(dataRoot.path, 'thumbnails'));
    if (!await thumbDir.exists()) await thumbDir.create(recursive: true);
    final danmakuDir = Directory(p.join(dataRoot.path, 'danmaku'));
    if (!await danmakuDir.exists()) await danmakuDir.create(recursive: true);

    int count = 0;
    final ensuredCollectionIds = <String>{};

    for (var ei = 0; ei < completedEpisodes.length; ei++) {
      var ep = completedEpisodes[ei];
      // 每处理 5 个集数时让出主线程，保持 UI 响应
      if (ei > 0 && ei % 5 == 0) {
        await Future<void>.delayed(Duration.zero);
      }
      final file = File(ep.outputPath!);
      if (!file.existsSync()) continue;

      try {
        if (await file.length() < 1024) continue;
      } catch (e) {
        continue;
      }

      final key = _episodeKey(ep);
      final insertedImportingKey = _importingEpisodeKeys.add(key);
      if (insertedImportingKey) {
        ep.downloadSpeed = "正在导出...";
        notifyListeners();
      }

      try {
        final task = tasks.firstWhere(
          (t) => t.videos.any((v) => v.episodes.contains(ep)),
        );
        final video = task.videos.firstWhere((v) => v.episodes.contains(ep));

        // --- Hierarchy Logic ---

        // 1. Level 1: Collection/Season
        String? rootCollectionId;
        if (task.collectionInfo != null) {
          rootCollectionId = await _getOrCreateCollection(
            library,
            task.collectionInfo!.title,
            targetFolderId,
            task.sourceRef,
          );
          if (!ensuredCollectionIds.contains(rootCollectionId)) {
            ensuredCollectionIds.add(rootCollectionId);
            await _ensureCollectionThumbnail(
              library,
              thumbDir,
              rootCollectionId,
              task.collectionInfo!.cover,
            );
          }
        } else {
          rootCollectionId = targetFolderId;
        }

        // 2. Level 2: Video Folder (if multi-part)
        String? targetParentId = rootCollectionId;
        if (video.videoInfo.pages.length > 1) {
          final folderId = await _getOrCreateCollection(
            library,
            video.videoInfo.title,
            rootCollectionId,
            video.sourceRef,
          );
          targetParentId = folderId;
          if (!ensuredCollectionIds.contains(folderId)) {
            ensuredCollectionIds.add(folderId);
            await _ensureCollectionThumbnail(
              library,
              thumbDir,
              folderId,
              video.videoInfo.pic,
            );
          }
        }

        // --- End Hierarchy Logic ---

        final uuid = const Uuid().v4();
        final taskSubtitleDir = await const TaskSubtitleStorageService()
            .taskDirectory(uuid, create: true);
        final extension = file.path.split('.').last;

        // Sanitize and truncate for filename to avoid OS limits (max 255 bytes)
        // Use stricter regex to avoid potential issues with special chars in player
        // Allow only alphanumeric, Chinese, dots, dashes, underscores
        String safeTitle = video.videoInfo.title.replaceAll(
          RegExp(r'[^\w\u4e00-\u9fa5\.-]'),
          '_',
        );
        if (safeTitle.length > 30) safeTitle = safeTitle.substring(0, 30);

        String safePart = ep.page.part.replaceAll(
          RegExp(r'[^\w\u4e00-\u9fa5\.-]'),
          '_',
        );
        if (safePart.length > 20) safePart = safePart.substring(0, 20);

        final finalName = "${safeTitle}_${safePart}_$uuid.$extension";
        final finalPath = "${baseDir.path}/$finalName";

        debugPrint("=== Import Debug Info ===");
        debugPrint("Source path: ${file.path}");
        debugPrint("Target path: $finalPath");
        debugPrint("Base dir: ${baseDir.path}");
        debugPrint("File exists: ${file.existsSync()}");
        debugPrint("========================");

        final targetFile = File(finalPath);
        if (!await targetFile.parent.exists()) {
          await targetFile.parent.create(recursive: true);
        }

        if (file.path != finalPath) {
          try {
            await _safeMoveFile(file, finalPath);
            debugPrint("File moved safely to: $finalPath");
            debugPrint("Target file exists: ${await File(finalPath).exists()}");
            await _deleteTempArtifacts(file.path);
          } catch (e, stack) {
            debugPrint("Failed to move file during export: $e\n$stack");
            // If file moving failed, throw to abort this task's export
            throw Exception("Export failed: unable to move file. $e");
          }
        }

        final playbackPath = finalPath;

        String? thumbPath;
        try {
          final coverUrl = video.videoInfo.pic;
          if (coverUrl.isNotEmpty) {
            final resp = await apiService.dio.get(
              coverUrl,
              options: Options(responseType: ResponseType.bytes),
            );
            final ext = coverUrl.split('.').last.split('?').first;
            final safeExt = (ext.length > 4 || ext.isEmpty) ? 'jpg' : ext;
            thumbPath = "${thumbDir.path}/$uuid.$safeExt";
            await File(thumbPath).writeAsBytes(resp.data);
          }
        } catch (e) {
          debugPrint("Failed to download cover: $e");
        }

        Map<String, String> extraSubtitles = {};
        final srtPath = ep.outputPath!.replaceAll(RegExp(r'\.mp4$'), '.srt');
        final srtFile = File(srtPath);
        String? defaultSubtitlePath;

        final hasLocalSubtitle = await srtFile.exists();
        if (hasLocalSubtitle) {
          final finalSrtPath = p.join(taskSubtitleDir.path, 'downloaded.srt');
          await srtFile.copy(finalSrtPath);
          defaultSubtitlePath = finalSrtPath;
          await _deleteTempArtifacts(srtFile.path);
        }

        if (defaultSubtitlePath != null) {
          final selected = ep.selectedSubtitle;
          if (selected != null) {
            String label = selected.lanDoc;
            if (label.isEmpty) {
              label = selected.lan;
            }
            if (label.isEmpty) {
              label = "默认字幕";
            }
            if (!extraSubtitles.containsKey(label)) {
              extraSubtitles[label] = defaultSubtitlePath;
            }
          }
        }

        if (ep.availableSubtitles.isNotEmpty) {
          for (var sub in ep.availableSubtitles) {
            try {
              if (hasLocalSubtitle) {
                final selected = ep.selectedSubtitle;
                if (selected != null) {
                  if (sub.lan == selected.lan ||
                      sub.lanDoc == selected.lanDoc) {
                    continue;
                  }
                } else if (ep.availableSubtitles.length == 1) {
                  continue;
                }
              }
              final lang = sub.lan;
              final url = sub.url;
              final resp = await apiService.dio.get(url);
              final srtContent = SubtitleUtil.convertJsonToSrt(resp.data);

              if (srtContent.isNotEmpty) {
                final safeLanguage = lang.replaceAll(
                  RegExp(r'[^A-Za-z0-9_-]'),
                  '_',
                );
                final subPath = await const TaskSubtitleStorageService()
                    .allocatePath(uuid, 'downloaded.$safeLanguage.srt');
                await File(subPath).writeAsString(srtContent);
                extraSubtitles[sub.lanDoc] = subPath;
              }
            } catch (e) {
              debugPrint("Failed to download subtitle ${sub.lanDoc}: $e");
            }
          }
        }

        String? finalDanmakuPath;
        final sourceDanmakuPath = ep.danmakuPath;
        if (sourceDanmakuPath != null) {
          final sourceDanmaku = File(sourceDanmakuPath);
          if (await sourceDanmaku.exists()) {
            finalDanmakuPath = p.join(danmakuDir.path, '${uuid}_danmaku.ass');
            await sourceDanmaku.copy(finalDanmakuPath);
            if (await _isWithinTempDir(sourceDanmakuPath)) {
              await _deleteFileIfExists(sourceDanmakuPath);
            }
            ep.danmakuPath = finalDanmakuPath;
          }
        }

        // Determine Display Title
        // If inside a video-specific folder (multi-part), use part name.
        // If standing alone (single-part), use video title.
        String displayTitle;
        if (video.videoInfo.pages.length > 1) {
          displayTitle = ep.page.part;
        } else {
          displayTitle = video.videoInfo.title;
        }

        // Determine Codec
        String? codec;
        if (ep.selectedVideoQuality != null) {
          final c = ep.selectedVideoQuality!.codecs;
          if (c.startsWith("hev1") ||
              c.startsWith("hvc1") ||
              c.contains("hevc")) {
            codec = "hevc";
          } else if (c.startsWith("avc1")) {
            codec = "avc";
          } else {
            codec = c.split('.').first;
          }
        }

        final item = VideoItem(
          id: uuid,
          path: playbackPath,
          title: displayTitle,
          thumbnailPath: thumbPath,
          durationMs: 0,
          lastUpdated: DateTime.now().millisecondsSinceEpoch,
          parentId: targetParentId,
          subtitlePath: defaultSubtitlePath,
          additionalSubtitles: extraSubtitles,
          danmakuPath: finalDanmakuPath,
          usesManagedAssociatedSubtitles: extraSubtitles.isNotEmpty,
          codec: codec,
          isBilibiliExported: true,
          sourceRef: video.sourceRef,
          chapters: ep.chapters,
          hasProbedChapters: true,
        );

        // #region debug-point B:import-before-library-add
        unawaited(
          _reportDebugEvent(
            'B',
            'bilibili_download_service.dart:importToLibrary',
            'Export move completed, about to add video into library',
            data: <String, Object?>{
              'episodeKey': key,
              'outputPath': playbackPath,
              'hasThumbPath': thumbPath != null,
              'hasSubtitle': defaultSubtitlePath != null,
            },
          ),
        );
        // #endregion
        await library.addSingleVideo(item);
        count++;

        // Update Export Status
        final importedEp = tasks
            .expand((t) => t.videos)
            .expand((v) => v.episodes)
            .firstWhere((e) => e.outputPath == ep.outputPath, orElse: () => ep);
        if (importedEp.outputPath == ep.outputPath) {
          _sequentialImportFailedKeys.remove(_episodeKey(importedEp));
          importedEp.isExported = true;
          final normalizedOutputPath = p.normalize(importedEp.outputPath!);
          if (importedEp.importedOutputPath != normalizedOutputPath) {
            importedEp.importedOutputPath = normalizedOutputPath;
            importedEp.importedVideoIds = [item.id];
          } else {
            importedEp.importedVideoIds = [
              ...importedEp.importedVideoIds.where((id) => id != item.id),
              item.id,
            ];
          }
          importedEp.downloadSpeed = "已导出";
        }

        // Auto Delete Task
        if (autoDeleteTaskAfterImport) {
          await removeEpisode(importedEp, task);
        } else {
          // Save state immediately to ensure consistency
          await saveTasks();
        }
      } finally {
        if (insertedImportingKey) {
          _importingEpisodeKeys.remove(key);
          _refreshCompletedEpisodeHints();
          // #region debug-point B:import-final-notify
          unawaited(
            _reportDebugEvent(
              'B',
              'bilibili_download_service.dart:importToLibrary',
              'Import final notifyListeners about to fire',
              data: <String, Object?>{
                'episodeKey': key,
                'count': count,
                'activeDownloads': _activeDownloads,
              },
            ),
          );
          // #endregion
          notifyListeners();
        }
      }
    }

    // Final save (redundant if loop ran, but safe)
    if (count > 0 && !autoDeleteTaskAfterImport) {
      await saveTasks();
    }
    if (count > 0) {
      _refreshCompletedEpisodeHints();
      if (!suppressSequentialPump &&
          autoImportToLibrary &&
          sequentialExport &&
          libraryService != null) {
        await _processSequentialAutoImports();
      }
    }
    return count;
  }
}
