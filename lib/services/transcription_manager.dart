import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/models/batch_subtitle_task_view.dart';
import 'package:video_player_app/models/subtitle_output_path_strategy.dart';
import 'package:video_player_app/models/transcription_status.dart';
import 'package:video_player_app/models/managed_subtitle_asset.dart';
import 'package:video_player_app/models/media_source_ref.dart';
import 'package:video_player_app/services/bcut_asr_service.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/media_materialization_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/services/temporary_storage_cleanup_models.dart';
import 'package:video_player_app/services/task_subtitle_storage_service.dart';
import 'package:video_player_app/utils/ffmpeg_utils.dart';

class TranscriptionManager extends ChangeNotifier {
  static const String _managedTempAudioDirName = 'ai_transcription_temp_audio';
  static const String _managedTempAudioPrefix = 'temp_audio_';
  static const String _persistenceFileName = 'transcription_queue_cache.json';
  final BcutAsrService _asrService = BcutAsrService();
  final SettingsService _settings;
  final List<_TranscriptionJob> _queue = <_TranscriptionJob>[];
  final Set<String> _queuedMediaKeys = <String>{};
  final Map<String, String> _resultSrtByMediaKey = <String, String>{};
  final Set<String> _consumedResultMediaKeys = <String>{};
  final Map<String, _TranscriptionJob> _failedJobs =
      <String, _TranscriptionJob>{};
  final Map<String, _TranscriptionJob> _completedJobs =
      <String, _TranscriptionJob>{};
  final Set<String> _startedMediaKeys = <String>{};
  final Map<String, String> _statusMessagesByMediaKey = <String, String>{};

  // State
  TranscriptionStatus _status = TranscriptionStatus.idle;
  String _statusMessage = "";
  double _progress = 0.0;
  String? _currentVideoPath;
  String? _lastGeneratedSrtPath;
  bool _isQueueProcessing = false;

  String? _currentVideoId;
  LibraryService? _libraryService;
  bool _autoCache = false;
  bool _initialized = false;
  _TranscriptionJob? _currentJob;
  _JobCancellation? _currentCancellation;
  bool _currentTaskRemoved = false;

  // ── 持久化 ──
  Timer? _saveDebounceTimer;
  String? _persistenceDirPath;
  static const Duration _saveDebounce = Duration(milliseconds: 500);
  bool _savePending = false;

  TranscriptionManager({SettingsService? settings})
    : _settings = settings ?? SettingsService();

  // Getters
  TranscriptionStatus get status => _status;
  String get statusMessage => _statusMessage;
  double get progress => _progress;
  String? get currentVideoPath => _currentVideoPath;
  String? get currentVideoId => _currentVideoId;
  String? get lastGeneratedSrtPath => _lastGeneratedSrtPath;
  bool get isResultConsumed {
    final mediaKey = _currentMediaKey;
    if (mediaKey == null) return true;
    return !_resultSrtByMediaKey.containsKey(mediaKey) ||
        _consumedResultMediaKeys.contains(mediaKey);
  }

  int get queuedCount => _queue.length;
  int get processingCount => isProcessing ? 1 : 0;
  int get pendingCount => queuedCount + processingCount;

  bool get isProcessing =>
      _status != TranscriptionStatus.idle &&
      _status != TranscriptionStatus.completed &&
      _status != TranscriptionStatus.error;

  void markResultConsumed() {
    final mediaKey = _currentMediaKey;
    if (mediaKey == null) return;
    if (_consumedResultMediaKeys.add(mediaKey)) {
      _scheduleSave();
      notifyListeners();
    }
  }

  void markResultConsumedForVideo(String videoPath, {String? videoId}) {
    final mediaKey = _mediaKey(videoPath, videoId: videoId);
    if (_consumedResultMediaKeys.add(mediaKey)) {
      _scheduleSave();
      notifyListeners();
    }
  }

  /// Atomically claims the one-time notification for the latest generated
  /// subtitle of this video. A new transcription clears the claim again.
  bool consumeResultNotificationForVideo(String videoPath, {String? videoId}) {
    final mediaKey = _mediaKey(videoPath, videoId: videoId);
    if (!_resultSrtByMediaKey.containsKey(mediaKey) ||
        !_consumedResultMediaKeys.add(mediaKey)) {
      return false;
    }
    _scheduleSave();
    notifyListeners();
    return true;
  }

  bool hasUnconsumedResultForVideo(String videoPath, {String? videoId}) {
    final mediaKey = _mediaKey(videoPath, videoId: videoId);
    return _resultSrtByMediaKey.containsKey(mediaKey) &&
        !_consumedResultMediaKeys.contains(mediaKey);
  }

  String? getGeneratedSrtPathForVideo(String videoPath, {String? videoId}) {
    final mediaKey = _mediaKey(videoPath, videoId: videoId);
    return _resultSrtByMediaKey[mediaKey];
  }

  bool isVideoQueued(String videoPath, {String? videoId}) {
    final mediaKey = _mediaKey(videoPath, videoId: videoId);
    return _queuedMediaKeys.contains(mediaKey);
  }

  bool isVideoRunning(String videoPath, {String? videoId}) {
    final mediaKey = _mediaKey(videoPath, videoId: videoId);
    return _currentMediaKey == mediaKey && isProcessing;
  }

  int queuePositionForVideo(String videoPath, {String? videoId}) {
    final mediaKey = _mediaKey(videoPath, videoId: videoId);
    if (isVideoRunning(videoPath, videoId: videoId)) {
      return 1;
    }
    int index = 0;
    for (final job in _queue) {
      index++;
      if (job.mediaKey == mediaKey) {
        return processingCount + index;
      }
    }
    return -1;
  }

  void clearPendingQueue() {
    _queue.clear();
    _queuedMediaKeys.clear();
    _startedMediaKeys.clear();
    _failedJobs.clear();
    _statusMessagesByMediaKey.clear();
    _scheduleSave();
    notifyListeners();
  }

  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
    await _cleanupManagedTempAudioDirectory();
    await _initPersistenceDir();
    await _loadState();
  }

  Future<void> shutdown() async {
    _saveDebounceTimer?.cancel();
    if (_savePending) {
      await _flushSave();
    }
    await _cleanupManagedTempAudioDirectory();
  }

  // ──────────────── 持久化 ────────────────

  Future<void> _initPersistenceDir() async {
    try {
      final appDir = await getApplicationDocumentsDirectory();
      _persistenceDirPath = appDir.path;
    } catch (e) {
      debugPrint('初始化持久化目录失败: $e');
    }
  }

  /// 带防抖的保存调度：500ms 内的多次变更合并为一次写入
  void _scheduleSave() {
    if (_persistenceDirPath == null) return;
    _savePending = true;
    _saveDebounceTimer?.cancel();
    _saveDebounceTimer = Timer(_saveDebounce, () {
      _flushSave();
    });
  }

  Future<void> _flushSave() async {
    _saveDebounceTimer?.cancel();
    if (!_savePending) return;
    _savePending = false;
    await _saveState();
  }

  Future<void> _saveState() async {
    if (_persistenceDirPath == null) return;
    try {
      final file = File(p.join(_persistenceDirPath!, _persistenceFileName));

      final queueJson = _queue.map((j) => j.toJson()).toList();

      final completedJson = <Map<String, dynamic>>[];
      for (final entry in _completedJobs.entries) {
        final jobJson = entry.value.toJson();
        jobJson['resultSrtPath'] = _resultSrtByMediaKey[entry.key];
        jobJson['message'] = _statusMessagesByMediaKey[entry.key] ?? '转录完成';
        completedJson.add(jobJson);
      }

      final failedJson = <Map<String, dynamic>>[];
      for (final entry in _failedJobs.entries) {
        final jobJson = entry.value.toJson();
        jobJson['message'] = _statusMessagesByMediaKey[entry.key] ?? '转录失败';
        failedJson.add(jobJson);
      }

      final data = <String, dynamic>{
        'version': 2,
        'queue': queueJson,
        'active': _currentTaskRemoved ? null : _currentJob?.toJson(),
        'completed': completedJson,
        'failed': failedJson,
        'startedKeys': _startedMediaKeys.toList(),
        // 持久化已消费标记，确保“AI 字幕已自动加载”提示在转录完成后
        // 仅向用户展示一次，应用重启后不会重复弹出。
        'consumedKeys': _consumedResultMediaKeys.toList(),
      };

      await file.writeAsString(json.encode(data));
    } catch (e) {
      debugPrint('保存转录队列状态失败: $e');
    }
  }

  Future<void> _loadState() async {
    if (_persistenceDirPath == null) return;
    try {
      final file = File(p.join(_persistenceDirPath!, _persistenceFileName));
      if (!await file.exists()) return;

      final raw = await file.readAsString();
      if (raw.isEmpty) return;

      final data = json.decode(raw) as Map<String, dynamic>;

      // 恢复排队任务。应用重启后统一回到未开始状态，避免旧的
      // “正在提取”标记再次自动占住队首。
      if (data['queue'] != null) {
        final queueList = data['queue'] as List;
        for (final item in queueList) {
          if (item is Map<String, dynamic>) {
            final job = _TranscriptionJob.fromJson(item);
            // 跳过不存在的文件
            if (job.videoPath.isNotEmpty) {
              _queue.add(job);
              _queuedMediaKeys.add(job.mediaKey);
            }
          }
        }
      }

      // 上次运行时仍处于 active 的任务说明进程被中断。将它恢复为
      // 可重试/可删除的失败任务，而不是重新塞回队首自动执行。
      final activeJson = data['active'];
      if (activeJson is Map<String, dynamic>) {
        final activeJob = _TranscriptionJob.fromJson(activeJson);
        if (activeJob.videoPath.isNotEmpty) {
          _queue.removeWhere((job) => job.mediaKey == activeJob.mediaKey);
          _queuedMediaKeys.remove(activeJob.mediaKey);
          _failedJobs[activeJob.mediaKey] = activeJob;
          _statusMessagesByMediaKey[activeJob.mediaKey] = '上次运行异常中断，请重试或删除此任务';
        }
      }

      // 恢复已完成任务
      if (data['completed'] != null) {
        final completedList = data['completed'] as List;
        for (final item in completedList) {
          if (item is Map<String, dynamic>) {
            final job = _TranscriptionJob.fromJson(item);
            _completedJobs[job.mediaKey] = job;
            final srtPath = item['resultSrtPath'] as String?;
            if (srtPath != null && srtPath.isNotEmpty) {
              // 仅当 SRT 文件确实存在时才恢复引用
              if (await File(srtPath).exists()) {
                _resultSrtByMediaKey[job.mediaKey] = srtPath;
              }
            }
            final msg = item['message'] as String?;
            if (msg != null && msg.isNotEmpty) {
              _statusMessagesByMediaKey[job.mediaKey] = msg;
            }
          }
        }
      }

      // 恢复失败任务
      if (data['failed'] != null) {
        final failedList = data['failed'] as List;
        for (final item in failedList) {
          if (item is Map<String, dynamic>) {
            final job = _TranscriptionJob.fromJson(item);
            _failedJobs[job.mediaKey] = job;
            final msg = item['message'] as String?;
            if (msg != null && msg.isNotEmpty) {
              _statusMessagesByMediaKey[job.mediaKey] = msg;
            }
          }
        }
      }

      // 恢复已消费标记：转录完成后“AI 字幕已自动加载”提示只应在第一次
      // 进入该视频时弹出，重启后对已消费过的结果不再重复提示。
      final consumedKeys = data['consumedKeys'];
      if (consumedKeys is List) {
        for (final key in consumedKeys) {
          if (key is String) {
            _consumedResultMediaKeys.add(key);
          }
        }
      }

      // startedKeys 只代表上次会话中的运行意图，不跨进程恢复。
      // 用户可以再次点击“开始全部”，不会出现幽灵任务自动堵队列。
      _startedMediaKeys.clear();

      if (_queue.isNotEmpty ||
          _completedJobs.isNotEmpty ||
          _failedJobs.isNotEmpty) {
        debugPrint(
          '已恢复转录队列: ${_queue.length} 排队, ${_completedJobs.length} 完成, ${_failedJobs.length} 失败',
        );
      }
    } catch (e) {
      debugPrint('加载转录队列状态失败: $e');
    }
  }

  Future<TemporaryStorageCategoryReport> buildTemporaryStorageReport() async {
    if (isProcessing) {
      return const TemporaryStorageCategoryReport(
        id: 'ai_transcription_temp_audio',
        title: 'AI 识别临时音频',
        description: 'AI 字幕识别过程中提取到临时目录的音频文件',
        fileCount: 0,
        totalBytes: 0,
        canClean: false,
        note: '当前正在进行 AI 识别，临时音频已受保护，暂不允许清理。',
      );
    }

    final files = await _listManagedTempAudioFiles();
    var totalBytes = 0;
    for (final file in files) {
      totalBytes += await _safeFileSize(file);
    }

    return TemporaryStorageCategoryReport(
      id: 'ai_transcription_temp_audio',
      title: 'AI 识别临时音频',
      description: 'AI 字幕识别过程中提取到临时目录的音频文件',
      fileCount: files.length,
      totalBytes: totalBytes,
      canClean: files.isNotEmpty,
      note: files.isEmpty ? '未发现残留的 AI 临时音频。' : null,
    );
  }

  Future<void> clearTemporaryStorageArtifacts() async {
    if (isProcessing) {
      return;
    }
    await _cleanupManagedTempAudioDirectory();
  }

  // 开始转录
  Future<void> startTranscription(
    String videoPath, {
    String? videoId,
    String? videoTitle,
    String? videoDuration,
    LibraryService? libraryService,
    bool autoCache = false,
    bool autoStart = false,
  }) async {
    if (videoPath.trim().isEmpty) {
      throw Exception("视频路径不能为空");
    }
    final mediaKey = _mediaKey(videoPath, videoId: videoId);
    if (isVideoRunning(videoPath, videoId: videoId) ||
        isVideoQueued(videoPath, videoId: videoId)) {
      return;
    }

    final libraryTitle = videoId == null
        ? null
        : libraryService?.getVideo(videoId)?.title;
    final displayName =
        _nonEmpty(videoTitle) ??
        _nonEmpty(libraryTitle) ??
        p.basename(videoPath);
    _queue.add(
      _TranscriptionJob(
        videoPath: videoPath,
        videoId: videoId,
        mediaKey: mediaKey,
        libraryService: libraryService,
        autoCache: autoCache,
        isExternal: false,
        outputPathStrategy: null,
        customOutputDir: null,
        createdAt: DateTime.now().millisecondsSinceEpoch,
        displayName: displayName,
        durationLabel: videoDuration ?? '',
      ),
    );
    _queuedMediaKeys.add(mediaKey);
    if (autoStart) {
      _startedMediaKeys.add(mediaKey);
    }
    _scheduleSave();
    notifyListeners();
    if (autoStart) {
      _ensureQueueProcessing();
    }
  }

  /// 开始处理单个任务（只处理这一个，处理完不会自动开始下一个）
  void startTask(String mediaKey) {
    _startedMediaKeys.add(mediaKey);
    _scheduleSave();
    notifyListeners();
    _ensureQueueProcessing();
  }

  /// 开始处理所有排队任务（逐个处理直到全部完成）
  void startAllTasks() {
    for (final job in _queue) {
      _startedMediaKeys.add(job.mediaKey);
    }
    _scheduleSave();
    notifyListeners();
    _ensureQueueProcessing();
  }

  /// 某任务是否已被用户显式开始
  bool isTaskStarted(String mediaKey) => _startedMediaKeys.contains(mediaKey);

  /// 队列是否正在处理中
  bool get isQueueRunning => _isQueueProcessing;

  /// 已开始的排队任务数量（不含当前正在处理的）
  int get startedCount => _startedMediaKeys.length;

  void _ensureQueueProcessing() {
    if (_isQueueProcessing) return;
    unawaited(_processQueue());
  }

  Future<void> _processQueue() async {
    if (_isQueueProcessing) return;
    _isQueueProcessing = true;
    try {
      while (true) {
        // 在队列中查找第一个已被用户"开始"的任务
        final startIndex = _queue.indexWhere(
          (job) => _startedMediaKeys.contains(job.mediaKey),
        );
        if (startIndex < 0) break; // 没有更多已开始的任务，停止

        final job = _queue.removeAt(startIndex);
        _startedMediaKeys.remove(job.mediaKey);
        _queuedMediaKeys.remove(job.mediaKey);
        final cancellation = _JobCancellation();
        _currentJob = job;
        _currentCancellation = cancellation;
        _currentTaskRemoved = false;
        _scheduleSave();
        final timeoutTimer = Timer(const Duration(minutes: 30), () {
          cancellation.cancel('转录任务超时（30 分钟），已自动中断', timedOut: true);
        });
        try {
          await _runJob(job, cancellation);
        } on _JobCancelledException catch (e) {
          if (e.timedOut && !_currentTaskRemoved) {
            _failedJobs[job.mediaKey] = job;
            _statusMessagesByMediaKey[job.mediaKey] = e.message;
            debugPrint("转录任务超时，已中断并跳过: ${job.videoPath}");
          } else {
            if (_currentTaskRemoved) {
              _removeTaskRecords(job.mediaKey);
            }
            debugPrint("转录任务已取消: ${job.videoPath}");
          }
        } finally {
          timeoutTimer.cancel();
          if (identical(_currentCancellation, cancellation)) {
            _currentCancellation = null;
            _currentJob = null;
            _currentTaskRemoved = false;
            _currentVideoPath = null;
            _currentVideoId = null;
            _status = TranscriptionStatus.idle;
            _statusMessage = '';
            _progress = 0.0;
            notifyListeners();
          }
          _scheduleSave();
        }
      }
    } finally {
      _isQueueProcessing = false;
      _libraryService = null;
      _autoCache = false;
      _currentJobIsExternal = false;
      _currentJobOutputPathStrategy = null;
      _currentJobCustomOutputDir = null;
      _currentJobCreatedAt = 0;
      _scheduleSave();
    }
  }

  Future<void> _runJob(
    _TranscriptionJob job,
    _JobCancellation cancellation,
  ) async {
    _currentVideoPath = job.videoPath;
    _currentVideoId = job.videoId;
    _libraryService =
        job.libraryService ?? (job.videoId == null ? null : LibraryService());
    _autoCache = job.autoCache;
    _currentJobIsExternal = job.isExternal;
    _currentJobOutputPathStrategy = job.outputPathStrategy;
    _currentJobCustomOutputDir = job.customOutputDir;
    _currentJobCreatedAt = job.createdAt;
    _status = TranscriptionStatus.extracting;
    _statusMessage = "";
    _progress = 0.0;
    notifyListeners();

    _PreparedAudioResult? preparedAudio;
    MaterializedMediaLease? materializedLease;
    try {
      cancellation.throwIfCancelled();
      var transcriptionMediaPath = job.videoPath;
      final libraryItem = job.videoId == null
          ? null
          : _libraryService?.getVideo(job.videoId!);
      final isBilibiliStream =
          !job.isExternal &&
          libraryItem != null &&
          (libraryItem.sourceRef?.kind == MediaSourceKind.bilibiliStream ||
              libraryItem.path.startsWith('bilibili://stream/'));
      if (isBilibiliStream) {
        _updateStatus(
          TranscriptionStatus.downloading,
          '正在准备下载 Bilibili 音频...',
          0.0,
        );
        try {
          materializedLease = await _libraryService!.acquireMaterializedMedia(
            job.videoId!,
            MediaMaterializationRequirement.audioOnly,
            cancelSignal: cancellation.whenCancelled,
            onProgress: (download) {
              if (cancellation.isCancelled) return;
              final fraction = download.progress.clamp(0.0, 1.0);
              final percent = ' ${(fraction * 100).toStringAsFixed(0)}%';
              final total = download.totalBytes == null
                  ? ''
                  : ' / ${_formatTransferBytes(download.totalBytes!)}';
              final speed = download.bytesPerSecond > 0
                  ? ' · ${_formatTransferBytes(download.bytesPerSecond.round())}/s'
                  : '';
              final eta = download.remaining == null
                  ? ''
                  : ' · 剩余约 ${download.remaining!.inSeconds}s';
              _updateStatus(
                TranscriptionStatus.downloading,
                '正在下载音频$percent · ${_formatTransferBytes(download.receivedBytes)}$total$speed$eta',
                fraction * 0.1,
              );
            },
          );
          transcriptionMediaPath = materializedLease.requiredAudioPath;
        } catch (_) {
          cancellation.throwIfCancelled();
          rethrow;
        }
        cancellation.throwIfCancelled();
        _updateStatus(
          TranscriptionStatus.downloading,
          'Bilibili 音频下载完成，正在检查格式...',
          0.1,
        );
      }
      _updateStatus(TranscriptionStatus.extracting, "正在准备识别音频...", 0.0);
      preparedAudio = await _prepareAudioForTranscription(
        transcriptionMediaPath,
        cancellation,
      );
      cancellation.throwIfCancelled();

      _updateStatus(TranscriptionStatus.uploading, "准备上传音频...", 0.1);

      final subtitles = await _asrService.transcribeAudio(
        preparedAudio.audioPath,
        cancelToken: cancellation.dioCancelToken,
        onProgress: (p, msg) {
          if (cancellation.isCancelled) return;
          TranscriptionStatus newStatus = _status;
          if (p < 0.6) {
            newStatus = TranscriptionStatus.uploading;
          } else {
            newStatus = TranscriptionStatus.transcribing;
          }
          _updateStatus(newStatus, msg, p);
        },
      );
      cancellation.throwIfCancelled();

      _updateStatus(TranscriptionStatus.transcribing, "正在保存字幕文件...", 0.95);
      final srtContent = _generateSrt(subtitles);
      final srtPath = await _saveSrtFile(
        job.videoPath,
        srtContent,
        videoId: job.videoId,
      );
      cancellation.throwIfCancelled();

      _lastGeneratedSrtPath = srtPath;
      _resultSrtByMediaKey[job.mediaKey] = srtPath;
      _consumedResultMediaKeys.remove(job.mediaKey);

      // ── 外部视频软字幕内嵌 ──
      if (job.isExternal) {
        await _embedSoftSubtitlesIfNeeded(
          videoPath: job.videoPath,
          srtPath: srtPath,
          mediaKey: job.mediaKey,
          cancellation: cancellation,
        );
      }
      cancellation.throwIfCancelled();

      if (!job.isExternal &&
          _currentVideoId != null &&
          _libraryService != null) {
        try {
          await _libraryService!.registerManagedSubtitleAsset(
            _currentVideoId!,
            path: srtPath,
            kind: ManagedSubtitleAssetKind.ai,
            displayName: 'AI 字幕',
          );
          final currentVideo = _libraryService!.getVideo(_currentVideoId!);
          String? existingSecondaryPath = currentVideo?.secondarySubtitlePath;
          bool isSecondaryCached =
              currentVideo?.isSecondarySubtitleCached ?? false;

          await _libraryService!.updateVideoSubtitles(
            _currentVideoId!,
            srtPath,
            _autoCache,
            secondarySubtitlePath: existingSecondaryPath,
            isSecondaryCached: isSecondaryCached,
          );
          cancellation.throwIfCancelled();
          debugPrint("AI字幕已自动保存到库: $_currentVideoId");
        } catch (e) {
          if (e is _JobCancelledException) rethrow;
          debugPrint("自动保存字幕失败: $e");
        }
      }

      _updateStatus(TranscriptionStatus.completed, "转录完成", 1.0);
      _completedJobs[job.mediaKey] = job;
      _scheduleSave();
    } on _JobCancelledException {
      rethrow;
    } catch (e) {
      cancellation.throwIfCancelled();
      _failedJobs[job.mediaKey] = job;
      _updateStatus(TranscriptionStatus.error, "转录失败: $e", 0.0);
      _scheduleSave();
      debugPrint("转录任务失败: ${job.videoPath}, $e");
    } finally {
      if (preparedAudio?.isTemporary == true) {
        final audioFile = File(preparedAudio!.audioPath);
        if (await audioFile.exists()) {
          try {
            await audioFile.delete();
          } catch (e) {
            debugPrint("清理临时音频失败: $e");
          }
        }
      }
      await materializedLease?.release();
    }
  }

  void _updateStatus(
    TranscriptionStatus status,
    String message,
    double progress,
  ) {
    _status = status;
    _statusMessage = message;
    final normalized = progress.clamp(0.0, 1.0);
    _progress = status == TranscriptionStatus.error
        ? normalized
        : normalized < _progress
        ? _progress
        : normalized;
    final key = _currentMediaKey;
    if (key != null) {
      _statusMessagesByMediaKey[key] = message;
    }
    notifyListeners();
  }

  String _formatTransferBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    final kib = bytes / 1024;
    if (kib < 1024) return '${kib.toStringAsFixed(1)} KB';
    final mib = kib / 1024;
    if (mib < 1024) return '${mib.toStringAsFixed(1)} MB';
    return '${(mib / 1024).toStringAsFixed(2)} GB';
  }

  Future<_MediaProbeInfo> _probeMedia(
    String mediaPath, [
    _JobCancellation? cancellation,
  ]) async {
    cancellation?.throwIfCancelled();
    final isAudioInput = _looksLikeAudioInput(mediaPath);
    Object? lastError;
    try {
      if (Platform.isWindows) {
        final ffprobePath = await FFmpegUtils.ffprobePath;
        final probeProcess = await Process.start(ffprobePath, [
          '-v',
          'quiet',
          '-print_format',
          'json',
          '-show_streams',
          '-show_format',
          mediaPath,
        ]);

        final stdoutBuffer = StringBuffer();
        final stderrBuffer = StringBuffer();
        final stdoutSub = probeProcess.stdout
            .transform(utf8.decoder)
            .listen(stdoutBuffer.write);
        final stderrSub = probeProcess.stderr
            .transform(utf8.decoder)
            .listen(stderrBuffer.write);

        String? abortReason;
        final probeStartedAt = DateTime.now();
        final probeTimer = Timer.periodic(const Duration(milliseconds: 250), (
          _,
        ) {
          if (abortReason != null) return;
          if (cancellation?.isCancelled == true) {
            abortReason = cancellation!.reason;
            probeProcess.kill();
          } else if (DateTime.now().difference(probeStartedAt) >
              const Duration(seconds: 12)) {
            abortReason = 'ffprobe 探测超时，已强制终止';
            probeProcess.kill();
          }
        });

        final exitCode = await probeProcess.exitCode;
        probeTimer.cancel();
        await stdoutSub.cancel();
        await stderrSub.cancel();

        cancellation?.throwIfCancelled();
        if (abortReason != null) {
          lastError = StateError(abortReason!);
        } else if (exitCode == 0) {
          try {
            return _parseMediaProbeInfo(
              jsonDecode(stdoutBuffer.toString()) as Map<String, dynamic>,
              isAudioInput: isAudioInput,
            );
          } catch (e) {
            lastError = e;
          }
        } else {
          lastError = StateError(
            'ffprobe 退出码 $exitCode: ${_summarizeText(stderrBuffer.toString(), fallback: "未知错误")}',
          );
        }
        final fallbackInfo = await _probeMediaWithFfmpegCli(
          mediaPath,
          isAudioInput: isAudioInput,
          cancellation: cancellation,
        );
        if (fallbackInfo != null) {
          return fallbackInfo;
        }
      } else {
        if (cancellation != null) {
          unawaited(cancellation.whenCancelled.then((_) => FFmpegKit.cancel()));
        }
        final session = await FFprobeKit.getMediaInformation(mediaPath);
        cancellation?.throwIfCancelled();
        final info = session.getMediaInformation();
        if (info != null) {
          String? codec;
          bool hasAudioStream = false;
          final streams = info.getStreams();
          for (final stream in streams) {
            if (stream.getType() == "audio") {
              hasAudioStream = true;
              codec = stream.getCodec()?.toLowerCase();
              break;
            }
          }
          return _MediaProbeInfo(
            codec: codec,
            durationSeconds: _parseDurationSeconds(info.getDuration()),
            hasAudioStream: hasAudioStream,
            isAudioInput: isAudioInput,
          );
        }
      }
    } catch (e) {
      if (e is _JobCancelledException) rethrow;
      lastError = e;
      if (Platform.isWindows) {
        final fallbackInfo = await _probeMediaWithFfmpegCli(
          mediaPath,
          isAudioInput: isAudioInput,
          cancellation: cancellation,
        );
        if (fallbackInfo != null) {
          return fallbackInfo;
        }
      }
    }
    debugPrint("探测媒体音频信息失败: ${lastError ?? '未知错误'}");
    return _MediaProbeInfo(
      codec: null,
      durationSeconds: null,
      hasAudioStream: isAudioInput,
      isAudioInput: isAudioInput,
    );
  }

  _MediaProbeInfo _parseMediaProbeInfo(
    Map<String, dynamic> json, {
    required bool isAudioInput,
  }) {
    final streams = (json['streams'] as List?) ?? const [];
    String? codec;
    bool hasAudioStream = false;
    for (final stream in streams) {
      if (stream is Map && stream['codec_type']?.toString() == 'audio') {
        hasAudioStream = true;
        codec = stream['codec_name']?.toString().toLowerCase();
        break;
      }
    }
    final format = json['format'];
    final durationSeconds = _parseDurationSeconds(
      format is Map ? format['duration'] : null,
    );
    return _MediaProbeInfo(
      codec: codec,
      durationSeconds: durationSeconds,
      hasAudioStream: hasAudioStream,
      isAudioInput: isAudioInput,
    );
  }

  Future<_MediaProbeInfo?> _probeMediaWithFfmpegCli(
    String mediaPath, {
    required bool isAudioInput,
    _JobCancellation? cancellation,
  }) async {
    try {
      cancellation?.throwIfCancelled();
      final ffmpegPath = await FFmpegUtils.ffmpegPath;
      final process = await Process.start(ffmpegPath, [
        '-hide_banner',
        '-i',
        mediaPath,
      ]);
      final stdoutBuffer = StringBuffer();
      final stderrBuffer = StringBuffer();
      final stdoutSub = process.stdout
          .transform(utf8.decoder)
          .listen(stdoutBuffer.write);
      final stderrSub = process.stderr
          .transform(utf8.decoder)
          .listen(stderrBuffer.write);
      String? abortReason;
      final startedAt = DateTime.now();
      final monitor = Timer.periodic(const Duration(milliseconds: 250), (_) {
        if (abortReason != null) return;
        if (cancellation?.isCancelled == true) {
          abortReason = cancellation!.reason;
          process.kill();
        } else if (DateTime.now().difference(startedAt) >
            const Duration(seconds: 12)) {
          abortReason = 'ffmpeg 回退探测超时';
          process.kill();
        }
      });
      await process.exitCode;
      monitor.cancel();
      await stdoutSub.cancel();
      await stderrSub.cancel();
      cancellation?.throwIfCancelled();
      if (abortReason != null) return null;
      final combinedOutput =
          '${stderrBuffer.toString()}\n${stdoutBuffer.toString()}'.replaceAll(
            '\r',
            '\n',
          );
      final hasAudioStream = RegExp(
        r'^\s*Stream #.*Audio:',
        multiLine: true,
      ).hasMatch(combinedOutput);
      if (!hasAudioStream && !isAudioInput) {
        return null;
      }

      final codecMatch = RegExp(
        r'Audio:\s*([A-Za-z0-9_]+)',
      ).firstMatch(combinedOutput);
      final durationMatch = RegExp(
        r'Duration:\s*(\d{2}):(\d{2}):(\d{2}(?:\.\d+)?)',
      ).firstMatch(combinedOutput);
      double? durationSeconds;
      if (durationMatch != null) {
        final hours = int.tryParse(durationMatch.group(1) ?? '') ?? 0;
        final minutes = int.tryParse(durationMatch.group(2) ?? '') ?? 0;
        final seconds = double.tryParse(durationMatch.group(3) ?? '') ?? 0;
        durationSeconds = hours * 3600 + minutes * 60 + seconds;
      }

      return _MediaProbeInfo(
        codec: codecMatch?.group(1)?.toLowerCase(),
        durationSeconds: durationSeconds,
        hasAudioStream: hasAudioStream || isAudioInput,
        isAudioInput: isAudioInput,
      );
    } catch (e) {
      if (e is _JobCancelledException) rethrow;
      debugPrint("ffmpeg CLI 回退探测失败: $e");
      return null;
    }
  }

  Future<_PreparedAudioResult> _prepareAudioForTranscription(
    String mediaPath,
    _JobCancellation cancellation,
  ) async {
    final probe = await _probeMedia(mediaPath, cancellation);
    cancellation.throwIfCancelled();
    if (!probe.hasAudioStream) {
      throw Exception("未检测到可用于转录的音频流");
    }

    if (_canDirectlyUploadAudio(mediaPath, probe)) {
      _updateStatus(TranscriptionStatus.extracting, "音频已符合上传格式，跳过转码...", 0.05);
      return _PreparedAudioResult(audioPath: mediaPath, isTemporary: false);
    }

    final maxAttempts = probe.isAudioInput ? 2 : 3;
    Object? lastError;
    for (int attempt = 1; attempt <= maxAttempts; attempt++) {
      cancellation.throwIfCancelled();
      final bool preferCopy = _shouldUseCopyMode(probe, attempt);
      final String tempAudioPath = await _createManagedTempAudioPath();
      try {
        _updateStatus(
          TranscriptionStatus.extracting,
          _buildPreparationStatusMessage(
            probe: probe,
            preferCopy: preferCopy,
            attempt: attempt,
            maxAttempts: maxAttempts,
          ),
          attempt == 1 ? 0.0 : 0.03,
        );
        await _extractAudioToPath(
          mediaPath,
          tempAudioPath,
          useCopy: preferCopy,
          probe: probe,
          cancellation: cancellation,
        );
        return _PreparedAudioResult(
          audioPath: tempAudioPath,
          isTemporary: true,
        );
      } catch (e) {
        if (e is _JobCancelledException) rethrow;
        lastError = e;
        await _deleteFileIfExists(tempAudioPath);
        if (!_shouldRetryPreparation(e, attempt, maxAttempts, probe)) {
          rethrow;
        }
        _updateStatus(
          TranscriptionStatus.extracting,
          "准备音频异常，正在自动重试 ($attempt/$maxAttempts)...",
          0.02,
        );
        await cancellation.delay(Duration(milliseconds: 600 * attempt));
      }
    }
    throw lastError ?? Exception("准备音频失败");
  }

  String _buildPreparationStatusMessage({
    required _MediaProbeInfo probe,
    required bool preferCopy,
    required int attempt,
    required int maxAttempts,
  }) {
    if (attempt > 1) {
      return preferCopy
          ? "正在重试准备音频 ($attempt/$maxAttempts)，优先快速拷贝音轨..."
          : "正在重试准备音频 ($attempt/$maxAttempts)，改为稳妥转码模式...";
    }
    if (probe.isAudioInput) {
      return preferCopy ? "正在快速整理音频格式..." : "正在转码音频为识别格式...";
    }
    return preferCopy ? "正在快速提取音轨..." : "正在提取并转码音轨...";
  }

  bool _shouldUseCopyMode(_MediaProbeInfo probe, int attempt) {
    if (probe.codec != 'aac') return false;
    return attempt == 1;
  }

  bool _shouldRetryPreparation(
    Object error,
    int attempt,
    int maxAttempts,
    _MediaProbeInfo probe,
  ) {
    if (attempt >= maxAttempts) {
      return false;
    }
    if (error is _AudioPreparationException) {
      return error.retryable;
    }
    return !probe.isAudioInput;
  }

  bool _canDirectlyUploadAudio(String mediaPath, _MediaProbeInfo probe) {
    final ext = p.extension(mediaPath).toLowerCase();
    return probe.isAudioInput && probe.codec == 'aac' && ext == '.m4a';
  }

  bool _looksLikeAudioInput(String mediaPath) {
    return LibraryService.supportedAudioExtensions.contains(
      p.extension(mediaPath).toLowerCase(),
    );
  }

  double? _parseDurationSeconds(Object? rawValue) {
    if (rawValue == null) return null;
    if (rawValue is num) return rawValue.toDouble();
    return double.tryParse(rawValue.toString());
  }

  Duration _buildExtractionTimeout(
    _MediaProbeInfo probe, {
    required bool useCopy,
  }) {
    final seconds = probe.durationSeconds ?? 0;
    final int rounded = seconds.isFinite ? seconds.ceil() : 0;
    final int baseSeconds;
    final int scaleSeconds;
    if (useCopy) {
      baseSeconds = probe.isAudioInput ? 30 : 45;
      scaleSeconds = (rounded * 0.35).ceil();
    } else {
      baseSeconds = probe.isAudioInput ? 60 : 90;
      scaleSeconds = (rounded * 0.5).ceil();
    }
    final totalSeconds = (baseSeconds + scaleSeconds).clamp(45, 1800);
    return Duration(seconds: totalSeconds);
  }

  Duration _buildInactivityTimeout({required bool useCopy}) {
    return Duration(seconds: useCopy ? 20 : 35);
  }

  Future<void> _extractAudioToPath(
    String mediaPath,
    String audioPath, {
    required bool useCopy,
    required _MediaProbeInfo probe,
    required _JobCancellation cancellation,
  }) async {
    final args = <String>[
      '-y',
      '-i',
      mediaPath,
      '-map',
      '0:a:0',
      '-vn',
      '-sn',
      '-dn',
    ];
    if (useCopy) {
      args.addAll(['-c:a', 'copy']);
    } else {
      args.addAll(['-c:a', 'aac', '-b:a', '64k']);
    }
    args.add(audioPath);

    final timeout = _buildExtractionTimeout(probe, useCopy: useCopy);
    final inactivityTimeout = _buildInactivityTimeout(useCopy: useCopy);
    debugPrint(
      "准备音频: codec=${probe.codec}, isAudio=${probe.isAudioInput}, useCopy=$useCopy, timeout=${timeout.inSeconds}s",
    );

    if (Platform.isWindows) {
      await _runWindowsFfmpeg(
        args,
        timeout: timeout,
        inactivityTimeout: inactivityTimeout,
        cancellation: cancellation,
      );
      return;
    }

    await _runFfmpegKit(
      args,
      timeout: timeout,
      inactivityTimeout: inactivityTimeout,
      cancellation: cancellation,
    );
  }

  Future<void> _runWindowsFfmpeg(
    List<String> args, {
    required Duration timeout,
    required Duration inactivityTimeout,
    required _JobCancellation cancellation,
  }) async {
    final ffmpegPath = await FFmpegUtils.ffmpegPath;
    final process = await Process.start(ffmpegPath, args);
    final stdoutBuffer = StringBuffer();
    final stderrBuffer = StringBuffer();
    final startedAt = DateTime.now();
    DateTime lastActivityAt = startedAt;
    String? abortReason;
    bool killRequested = false;

    void recordOutput(List<int> data, StringBuffer buffer) {
      if (data.isEmpty) return;
      lastActivityAt = DateTime.now();
      buffer.write(utf8.decode(data, allowMalformed: true));
    }

    final stdoutSub = process.stdout.listen(
      (data) => recordOutput(data, stdoutBuffer),
    );
    final stderrSub = process.stderr.listen(
      (data) => recordOutput(data, stderrBuffer),
    );
    final monitor = Timer.periodic(const Duration(seconds: 1), (_) {
      if (killRequested) return;
      final now = DateTime.now();
      if (cancellation.isCancelled) {
        abortReason = cancellation.reason;
        killRequested = true;
        process.kill();
      } else if (now.difference(lastActivityAt) > inactivityTimeout) {
        abortReason = "FFmpeg 输出长时间无变化，已自动中断";
        killRequested = true;
        process.kill();
      } else if (now.difference(startedAt) > timeout) {
        abortReason = "FFmpeg 提取超时，已自动中断";
        killRequested = true;
        process.kill();
      }
    });

    try {
      final exitCode = await process.exitCode;
      cancellation.throwIfCancelled();
      if (abortReason != null) {
        throw _AudioPreparationException(abortReason!, retryable: true);
      }
      if (exitCode != 0) {
        final errorText = _summarizeProcessLogs(stdoutBuffer, stderrBuffer);
        throw _AudioPreparationException(
          "FFmpeg 提取失败: $errorText",
          retryable: true,
        );
      }
    } finally {
      monitor.cancel();
      await stdoutSub.cancel();
      await stderrSub.cancel();
    }
  }

  Future<void> _runFfmpegKit(
    List<String> args, {
    required Duration timeout,
    required Duration inactivityTimeout,
    required _JobCancellation cancellation,
  }) async {
    final completer = Completer<dynamic>();
    final startedAt = DateTime.now();
    DateTime lastActivityAt = startedAt;
    bool cancelRequested = false;
    String? cancelReason;

    final session = await FFmpegKit.executeWithArgumentsAsync(
      args,
      (session) async {
        if (!completer.isCompleted) {
          completer.complete(session);
        }
      },
      (_) {
        lastActivityAt = DateTime.now();
      },
      (_) {
        lastActivityAt = DateTime.now();
      },
    );

    final monitor = Timer.periodic(const Duration(seconds: 1), (_) {
      if (cancelRequested) return;
      final now = DateTime.now();
      if (cancellation.isCancelled) {
        cancelRequested = true;
        cancelReason = cancellation.reason;
        unawaited(FFmpegKit.cancel(session.getSessionId()));
      } else if (now.difference(lastActivityAt) > inactivityTimeout) {
        cancelRequested = true;
        cancelReason = "FFmpeg 输出长时间无变化，已自动中断";
        unawaited(FFmpegKit.cancel(session.getSessionId()));
      } else if (now.difference(startedAt) > timeout) {
        cancelRequested = true;
        cancelReason = "FFmpeg 提取超时，已自动中断";
        unawaited(FFmpegKit.cancel(session.getSessionId()));
      }
    });

    try {
      final completedSession = await completer.future;
      cancellation.throwIfCancelled();
      final returnCode = await completedSession.getReturnCode();
      if (cancelRequested || ReturnCode.isCancel(returnCode)) {
        final logs = await completedSession.getAllLogsAsString();
        throw _AudioPreparationException(
          cancelReason ?? _summarizeText(logs, fallback: "FFmpeg 任务已取消"),
          retryable: true,
        );
      }
      if (!ReturnCode.isSuccess(returnCode)) {
        final logs = await completedSession.getAllLogsAsString();
        throw _AudioPreparationException(
          "FFmpeg 提取失败: ${_summarizeText(logs, fallback: '未知错误')}",
          retryable: true,
        );
      }
    } finally {
      monitor.cancel();
    }
  }

  String _summarizeProcessLogs(
    StringBuffer stdoutBuffer,
    StringBuffer stderrBuffer,
  ) {
    final stderrText = stderrBuffer.toString().trim();
    if (stderrText.isNotEmpty) {
      return _summarizeText(stderrText, fallback: "未知错误");
    }
    final stdoutText = stdoutBuffer.toString().trim();
    return _summarizeText(stdoutText, fallback: "未知错误");
  }

  String _summarizeText(String text, {required String fallback}) {
    final normalized = text
        .replaceAll('\r', '\n')
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList();
    if (normalized.isEmpty) return fallback;
    return normalized.length > 4
        ? normalized.sublist(normalized.length - 4).join(' | ')
        : normalized.join(' | ');
  }

  Future<Directory> _managedTempAudioDirectory() async {
    final tempDir = await getTemporaryDirectory();
    final dir = Directory(p.join(tempDir.path, _managedTempAudioDirName));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<String> _createManagedTempAudioPath() async {
    final dir = await _managedTempAudioDirectory();
    return p.join(
      dir.path,
      '$_managedTempAudioPrefix${DateTime.now().millisecondsSinceEpoch}.m4a',
    );
  }

  Future<void> _cleanupManagedTempAudioDirectory() async {
    try {
      final dir = Directory(
        p.join((await getTemporaryDirectory()).path, _managedTempAudioDirName),
      );
      if (!await dir.exists()) {
        return;
      }
      await for (final entity in dir.list(
        recursive: true,
        followLinks: false,
      )) {
        try {
          if (entity is File) {
            await entity.delete();
          } else if (entity is Directory) {
            await entity.delete(recursive: true);
          }
        } catch (e) {
          debugPrint("清理临时音频目录成员失败: $e");
        }
      }
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
    } catch (e) {
      debugPrint("清理临时音频目录失败: $e");
    }
  }

  Future<List<File>> _listManagedTempAudioFiles() async {
    try {
      final dir = Directory(
        p.join((await getTemporaryDirectory()).path, _managedTempAudioDirName),
      );
      if (!await dir.exists()) {
        return const <File>[];
      }
      final files = <File>[];
      await for (final entity in dir.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is File) {
          files.add(entity);
        }
      }
      return files;
    } catch (e) {
      debugPrint("列出临时音频目录失败: $e");
      return const <File>[];
    }
  }

  Future<int> _safeFileSize(File file) async {
    try {
      if (!await file.exists()) {
        return 0;
      }
      return await file.length();
    } catch (_) {
      return 0;
    }
  }

  Future<void> _deleteFileIfExists(String path) async {
    final file = File(path);
    if (!await file.exists()) return;
    try {
      await file.delete();
    } catch (e) {
      debugPrint("删除文件失败: $path, $e");
    }
  }

  // 生成 SRT 格式
  String _generateSrt(List<SubtitleItem> subtitles) {
    final buffer = StringBuffer();
    for (int i = 0; i < subtitles.length; i++) {
      final item = subtitles[i];
      buffer.writeln((i + 1).toString());
      buffer.writeln(
        "${_formatDuration(item.startTime)} --> ${_formatDuration(item.endTime)}",
      );
      buffer.writeln(item.text);
      buffer.writeln();
    }
    return buffer.toString();
  }

  String _formatDuration(Duration d) {
    final h = d.inHours.toString().padLeft(2, '0');
    final m = (d.inMinutes % 60).toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    final ms = (d.inMilliseconds % 1000).toString().padLeft(3, '0');
    return "$h:$m:$s,$ms";
  }

  // 保存 SRT 文件
  Future<String> _saveSrtFile(
    String videoPath,
    String srtContent, {
    String? videoId,
  }) async {
    try {
      if (srtContent.trim().isEmpty) {
        throw Exception("生成的字幕内容为空");
      }

      if (_currentJobIsExternal) {
        // Output location is resolved at the last reversible boundary instead
        // of when the task was enqueued. A setting changed while extraction,
        // upload, or recognition is running therefore applies to this task.
        final strategy = _settings.batchSubtitleOutputPathStrategy;
        final customOutputDir = _settings.batchSubtitleCustomOutputDir;
        if (strategy == SubtitleOutputPathStrategy.customDirectory &&
            customOutputDir != null &&
            customOutputDir.isNotEmpty) {
          try {
            final customDir = Directory(customOutputDir);
            if (!await customDir.exists()) {
              await customDir.create(recursive: true);
            }
            final fileName = _aiSubtitleFileName(videoPath);
            final srtPath = p.join(customDir.path, fileName);
            await File(srtPath).writeAsString(srtContent);
            debugPrint("外部视频AI字幕已保存到指定目录: $srtPath");
            return srtPath;
          } catch (e) {
            debugPrint("保存字幕到指定目录失败，回退到私有目录: $e");
          }
        }

        try {
          final videoFile = File(videoPath);
          if (await videoFile.exists()) {
            final dir = videoFile.parent.path;
            final fileName = _aiSubtitleFileName(videoPath);
            final srtPath = p.join(dir, fileName);
            await File(srtPath).writeAsString(srtContent);
            debugPrint("外部视频AI字幕已保存到视频同目录: $srtPath");
            return srtPath;
          }
        } catch (e) {
          debugPrint("保存字幕到视频同目录失败，回退到私有目录: $e");
        }
      }

      final trimmedVideoId = videoId?.trim() ?? '';
      if (trimmedVideoId.isEmpty) {
        throw StateError('媒体库转录任务缺少 videoId');
      }
      final srtPath = await const TaskSubtitleStorageService().allocatePath(
        trimmedVideoId,
        'ai.srt',
      );

      await File(srtPath).writeAsString(srtContent);
      debugPrint("AI字幕已保存到私有目录: $srtPath");

      return srtPath;
    } catch (e) {
      debugPrint("保存字幕到私有目录失败: $e");
      if (!_currentJobIsExternal) {
        throw Exception("保存任务字幕文件失败: $e");
      }
      try {
        final videoFile = File(videoPath);
        final dir = videoFile.parent.path;
        final fallbackFileName = _aiSubtitleFileName(
          videoPath,
          videoId: videoId,
        );
        final srtPath = p.join(dir, fallbackFileName);
        await File(srtPath).writeAsString(srtContent);
        debugPrint("AI字幕已保存到视频目录: $srtPath");
        return srtPath;
      } catch (e2) {
        throw Exception("保存字幕文件失败: $e");
      }
    }
  }

  List<BatchSubtitleTaskView> getQueueSnapshot() {
    final tasks = <BatchSubtitleTaskView>[];

    if (isProcessing && _currentVideoPath != null && !_currentTaskRemoved) {
      final currentKey = _currentMediaKey;
      if (currentKey != null) {
        final videoName =
            _currentJob?.displayName ?? p.basename(_currentVideoPath!);
        final perJobMessage =
            _statusMessagesByMediaKey[currentKey] ?? _statusMessage;
        tasks.add(
          BatchSubtitleTaskView(
            mediaKey: currentKey,
            videoPath: _currentVideoPath!,
            videoId: _currentVideoId,
            videoName: videoName,
            videoDuration: _currentJob?.durationLabel ?? '',
            isExternal: _currentJobIsExternal,
            status: _status,
            progress: _progress,
            statusMessage: perJobMessage,
            createdAt: _currentJobCreatedAt,
            outputPathStrategy: _currentJobIsExternal
                ? _settings.batchSubtitleOutputPathStrategy
                : _currentJobOutputPathStrategy,
            customOutputDir: _currentJobIsExternal
                ? _settings.batchSubtitleCustomOutputDir
                : _currentJobCustomOutputDir,
            isStarted: true,
          ),
        );
      }
    }

    int queueIdx = 0;
    for (final job in _queue) {
      queueIdx++;
      final videoName = job.displayName;
      final isStarted = _startedMediaKeys.contains(job.mediaKey);
      // If started and waiting, compute queue position (1-based, after active job)
      final int effectiveQueuePos = isStarted
          ? (processingCount + queueIdx)
          : 0;
      tasks.add(
        BatchSubtitleTaskView(
          mediaKey: job.mediaKey,
          videoPath: job.videoPath,
          videoId: job.videoId,
          videoName: videoName,
          videoDuration: job.durationLabel,
          isExternal: job.isExternal,
          status: TranscriptionStatus.idle,
          progress: 0.0,
          statusMessage: isStarted ? '已加入队列，当前顺位：$effectiveQueuePos' : '',
          createdAt: job.createdAt,
          outputPathStrategy: job.isExternal
              ? _settings.batchSubtitleOutputPathStrategy
              : job.outputPathStrategy,
          customOutputDir: job.isExternal
              ? _settings.batchSubtitleCustomOutputDir
              : job.customOutputDir,
          isStarted: isStarted,
        ),
      );
    }

    for (final entry in _failedJobs.entries) {
      final job = entry.value;
      final videoName = job.displayName;
      final failMsg = _statusMessagesByMediaKey[entry.key] ?? _statusMessage;
      tasks.add(
        BatchSubtitleTaskView(
          mediaKey: entry.key,
          videoPath: job.videoPath,
          videoId: job.videoId,
          videoName: videoName,
          videoDuration: job.durationLabel,
          isExternal: job.isExternal,
          status: TranscriptionStatus.error,
          progress: 0.0,
          statusMessage: failMsg.isNotEmpty ? failMsg : '转录失败',
          createdAt: job.createdAt,
          outputPathStrategy: job.outputPathStrategy,
          customOutputDir: job.customOutputDir,
        ),
      );
    }

    for (final entry in _completedJobs.entries) {
      final job = entry.value;
      final videoName = job.displayName;
      final completeMsg = _statusMessagesByMediaKey[entry.key] ?? '转录完成';
      tasks.add(
        BatchSubtitleTaskView(
          mediaKey: entry.key,
          videoPath: job.videoPath,
          videoId: job.videoId,
          videoName: videoName,
          videoDuration: job.durationLabel,
          isExternal: job.isExternal,
          status: TranscriptionStatus.completed,
          progress: 1.0,
          statusMessage: completeMsg,
          createdAt: job.createdAt,
          outputPathStrategy: job.outputPathStrategy,
          customOutputDir: job.customOutputDir,
        ),
      );
    }

    return tasks;
  }

  bool removeFromQueue(String mediaKey) {
    if (_currentMediaKey == mediaKey && isProcessing) {
      _currentTaskRemoved = true;
      _currentCancellation?.cancel('用户取消并删除了任务');
      _removeTaskRecords(mediaKey);
      _scheduleSave();
      notifyListeners();
      return true;
    }

    final queueIndex = _queue.indexWhere((job) => job.mediaKey == mediaKey);
    if (queueIndex >= 0) {
      _queue.removeAt(queueIndex);
      _queuedMediaKeys.remove(mediaKey);
      _startedMediaKeys.remove(mediaKey);
      _failedJobs.remove(mediaKey);
      _completedJobs.remove(mediaKey);
      _statusMessagesByMediaKey.remove(mediaKey);
      _scheduleSave();
      notifyListeners();
      return true;
    }

    if (_failedJobs.containsKey(mediaKey)) {
      _failedJobs.remove(mediaKey);
      _queuedMediaKeys.remove(mediaKey);
      _statusMessagesByMediaKey.remove(mediaKey);
      _scheduleSave();
      notifyListeners();
      return true;
    }

    if (_completedJobs.containsKey(mediaKey)) {
      _completedJobs.remove(mediaKey);
      _resultSrtByMediaKey.remove(mediaKey);
      _consumedResultMediaKeys.remove(mediaKey);
      _statusMessagesByMediaKey.remove(mediaKey);
      _scheduleSave();
      notifyListeners();
      return true;
    }

    if (_resultSrtByMediaKey.containsKey(mediaKey)) {
      _resultSrtByMediaKey.remove(mediaKey);
      _consumedResultMediaKeys.remove(mediaKey);
      _statusMessagesByMediaKey.remove(mediaKey);
      _scheduleSave();
      notifyListeners();
      return true;
    }

    return false;
  }

  bool retryTask(String mediaKey) {
    final failedJob = _failedJobs.remove(mediaKey);
    if (failedJob == null) return false;

    _queuedMediaKeys.remove(mediaKey);
    _statusMessagesByMediaKey.remove(mediaKey);

    final newJob = _TranscriptionJob(
      videoPath: failedJob.videoPath,
      videoId: failedJob.videoId,
      mediaKey: failedJob.mediaKey,
      libraryService: failedJob.libraryService,
      autoCache: failedJob.autoCache,
      isExternal: failedJob.isExternal,
      outputPathStrategy: failedJob.outputPathStrategy,
      customOutputDir: failedJob.customOutputDir,
      createdAt: DateTime.now().millisecondsSinceEpoch,
      displayName: failedJob.displayName,
      durationLabel: failedJob.durationLabel,
    );

    _queue.add(newJob);
    _queuedMediaKeys.add(mediaKey);
    _scheduleSave();
    notifyListeners();
    return true;
  }

  /// Moves a pending task to its final zero-based position in [_queue].
  ///
  /// [newIndex] is a final item index, not ReorderableListView's insertion
  /// gap. Keeping the UI-specific gap semantics out of the manager prevents
  /// downward moves from being adjusted twice and allows moving to the last
  /// queue position.
  bool reorderTask(String mediaKey, int newIndex) {
    if (_currentMediaKey == mediaKey && isProcessing) {
      return false;
    }

    final currentIndex = _queue.indexWhere((job) => job.mediaKey == mediaKey);
    if (currentIndex < 0) return false;

    if (newIndex < 0 || newIndex >= _queue.length) return false;

    if (currentIndex == newIndex) return true;

    final job = _queue.removeAt(currentIndex);
    _queue.insert(newIndex, job);
    _scheduleSave();
    notifyListeners();
    return true;
  }

  Future<void> startExternalTranscription(
    String videoPath, {
    required SubtitleOutputPathStrategy outputPathStrategy,
    String? customOutputDir,
  }) async {
    if (videoPath.trim().isEmpty) {
      throw Exception("视频路径不能为空");
    }
    final mediaKey = _mediaKey(videoPath);
    if (isVideoRunning(videoPath) || isVideoQueued(videoPath)) {
      return;
    }

    _queue.add(
      _TranscriptionJob(
        videoPath: videoPath,
        videoId: null,
        mediaKey: mediaKey,
        libraryService: null,
        autoCache: false,
        isExternal: true,
        outputPathStrategy: outputPathStrategy,
        customOutputDir: customOutputDir,
        createdAt: DateTime.now().millisecondsSinceEpoch,
        displayName: p.basename(videoPath),
        durationLabel: '',
      ),
    );
    _queuedMediaKeys.add(mediaKey);
    _scheduleSave();
    notifyListeners();
  }

  /// 清除所有已完成的任务
  void clearAllCompleted() {
    _completedJobs.clear();
    for (final key in List<String>.from(_statusMessagesByMediaKey.keys)) {
      if (_resultSrtByMediaKey.containsKey(key) &&
          !_failedJobs.containsKey(key) &&
          _currentMediaKey != key) {
        _statusMessagesByMediaKey.remove(key);
      }
    }
    _resultSrtByMediaKey.clear();
    _consumedResultMediaKeys.clear();
    _scheduleSave();
    notifyListeners();
  }

  /// 清除所有排队的任务（不删除已完成和失败的任务）
  void clearQueuedTasks() {
    _queue.clear();
    _queuedMediaKeys.clear();
    _startedMediaKeys.clear();
    _scheduleSave();
    notifyListeners();
  }

  /// 清除所有任务；若当前任务正在处理，会先取消底层工作。
  void clearAllTasks() {
    final currentKey = _currentMediaKey;
    if (currentKey != null && isProcessing) {
      _currentTaskRemoved = true;
      _currentCancellation?.cancel('用户清除了全部任务');
    }
    _queue.clear();
    _queuedMediaKeys.clear();
    _startedMediaKeys.clear();
    _failedJobs.clear();
    _completedJobs.clear();
    _resultSrtByMediaKey.clear();
    _consumedResultMediaKeys.clear();
    _statusMessagesByMediaKey.clear();
    _scheduleSave();
    notifyListeners();
  }

  bool _currentJobIsExternal = false;
  SubtitleOutputPathStrategy? _currentJobOutputPathStrategy;
  String? _currentJobCustomOutputDir;
  int _currentJobCreatedAt = 0;

  @override
  void dispose() {
    _currentCancellation?.cancel('转录管理器已释放');
    _queue.clear();
    _queuedMediaKeys.clear();
    _startedMediaKeys.clear();
    _failedJobs.clear();
    _completedJobs.clear();
    _resultSrtByMediaKey.clear();
    _consumedResultMediaKeys.clear();
    _statusMessagesByMediaKey.clear();
    super.dispose();
  }

  String? get _currentMediaKey {
    final currentPath = _currentVideoPath;
    if (currentPath == null || currentPath.isEmpty) return null;
    return _mediaKey(currentPath, videoId: _currentVideoId);
  }

  String _mediaKey(String videoPath, {String? videoId}) {
    final trimmedId = videoId?.trim();
    if (trimmedId != null && trimmedId.isNotEmpty) {
      return 'id:$trimmedId';
    }
    final normalizedPath = p.normalize(videoPath);
    final safePath = Platform.isWindows
        ? normalizedPath.toLowerCase()
        : normalizedPath;
    return 'path:$safePath';
  }

  String? _nonEmpty(String? value) {
    final trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }

  void _removeTaskRecords(String mediaKey) {
    _queue.removeWhere((job) => job.mediaKey == mediaKey);
    _queuedMediaKeys.remove(mediaKey);
    _startedMediaKeys.remove(mediaKey);
    _failedJobs.remove(mediaKey);
    _completedJobs.remove(mediaKey);
    _resultSrtByMediaKey.remove(mediaKey);
    _consumedResultMediaKeys.remove(mediaKey);
    _statusMessagesByMediaKey.remove(mediaKey);
  }

  String _aiSubtitleFileName(String videoPath, {String? videoId}) {
    final trimmedId = videoId?.trim();
    if (trimmedId != null && trimmedId.isNotEmpty) {
      return '$trimmedId.ai.srt';
    }
    final name = p.basenameWithoutExtension(videoPath);
    return '$name.ai.srt';
  }

  /// 外部视频软字幕内嵌入口：根据设置决定是否将 SRT 嵌入视频
  Future<void> _embedSoftSubtitlesIfNeeded({
    required String videoPath,
    required String srtPath,
    required String mediaKey,
    required _JobCancellation cancellation,
  }) async {
    cancellation.throwIfCancelled();
    // The picker also accepts external audio files, while these settings are
    // explicitly for video soft subtitles. Trying to mux mov_text into audio
    // containers would turn an otherwise successful transcription into an
    // embedding failure.
    if (_looksLikeAudioInput(videoPath)) return;

    // Keep a reference to the singleton/injected service rather than copying
    // values. Settings used after ffmpeg finishes (delete original/SRT) are
    // consequently re-read and can still change while embedding is running.
    final settings = _settings;
    final bool shouldEmbed =
        settings.batchSubtitleEmbedSoftCopyAndEmbed ||
        settings.batchSubtitleEmbedSoftDeleteOriginal;
    if (!shouldEmbed) return;

    // Always mux into a unique staging file. Besides avoiding partially
    // written final files, this lets prefix/suffix and copy/replace changes
    // made during ffmpeg execution apply at the final commit boundary.
    final String stagingPath = _buildEmbeddingStagingPath(videoPath);
    final File stagingFile = File(stagingPath);

    _updateStatus(TranscriptionStatus.embedding, '正在内嵌软字幕...', 0.96);
    try {
      await _embedSoftSubtitle(
        srcVideo: videoPath,
        srtPath: srtPath,
        outputPath: stagingPath,
        cancellation: cancellation,
        onProgress: (ratio) {
          final p = 0.96 + ratio * 0.04;
          _updateStatus(
            TranscriptionStatus.embedding,
            '正在内嵌软字幕 ${(ratio * 100).toInt()}%',
            p,
          );
        },
      );
      cancellation.throwIfCancelled();

      // 校验输出文件
      if (!await stagingFile.exists()) {
        throw Exception('内嵌软字幕失败：输出文件未生成');
      }
      final outputLength = await stagingFile.length();
      if (outputLength <= 0) {
        throw Exception('内嵌软字幕失败：输出文件大小为 0');
      }

      // Re-read every mode/naming field after ffmpeg. Turning embedding off
      // while it was running discards the staged result and preserves both
      // source video and SRT; changing modes or names affects this same task.
      final copyAndEmbed = settings.batchSubtitleEmbedSoftCopyAndEmbed;
      final replaceOriginal = settings.batchSubtitleEmbedSoftDeleteOriginal;
      if (!copyAndEmbed && !replaceOriginal) {
        await _safeDeleteFile(stagingPath);
        debugPrint('软字幕内嵌设置已关闭，丢弃暂存结果');
        return;
      }

      var outputPath = _buildEmbeddedOutputPath(videoPath, settings);
      final outputMatchesSource = _sameFilePath(outputPath, videoPath);
      if (copyAndEmbed && outputMatchesSource) {
        // A copy cannot share the source path. Use a deterministic safe name
        // when both naming switches are effectively empty/disabled.
        outputPath = _buildDefaultEmbeddedCopyPath(videoPath);
      }

      if (replaceOriginal && outputMatchesSource) {
        await _replaceFileSafely(
          sourcePath: videoPath,
          replacementPath: stagingPath,
        );
      } else {
        final outputFile = File(outputPath);
        if (await outputFile.exists()) {
          throw Exception('内嵌软字幕失败：目标文件已存在，为避免覆盖已保留原视频');
        }
        await stagingFile.rename(outputPath);

        // Delete only after the staged result has been validated and committed.
        if (replaceOriginal) {
          await _safeDeleteFile(videoPath);
        }
      }

      // This cleanup setting is intentionally read after committing the video,
      // so it remains live throughout the embedding stage.
      if (settings.batchSubtitleEmbedAutoDeleteSrt) {
        await _safeDeleteFile(srtPath);
        _resultSrtByMediaKey.remove(mediaKey);
        if (_lastGeneratedSrtPath == srtPath) {
          _lastGeneratedSrtPath = null;
        }
      } else {
        // 字幕未删除：SRT 仍在原位置，保留引用
        _resultSrtByMediaKey[mediaKey] = srtPath;
        _lastGeneratedSrtPath = srtPath;
      }
      debugPrint('软字幕内嵌完成: $outputPath');
    } catch (e) {
      // 嵌入失败 —— 保留原视频和 SRT，不删除任何文件
      debugPrint('软字幕内嵌失败: $e');
      // 清理可能产生的部分输出文件
      await _safeDeleteFile(stagingPath);
      rethrow;
    }
  }

  String _buildEmbeddingStagingPath(String videoPath) {
    final dir = p.dirname(videoPath);
    final baseName = p.basenameWithoutExtension(videoPath);
    final ext = p.extension(videoPath);
    final nonce = DateTime.now().microsecondsSinceEpoch;
    return p.join(dir, '.$baseName.ai_embedding_$nonce$ext');
  }

  String _buildDefaultEmbeddedCopyPath(String videoPath) {
    final dir = p.dirname(videoPath);
    final baseName = p.basenameWithoutExtension(videoPath);
    final ext = p.extension(videoPath);
    return p.join(dir, '${baseName}_AI字幕$ext');
  }

  bool _sameFilePath(String first, String second) {
    final normalizedFirst = p.normalize(p.absolute(first));
    final normalizedSecond = p.normalize(p.absolute(second));
    if (Platform.isWindows) {
      return normalizedFirst.toLowerCase() == normalizedSecond.toLowerCase();
    }
    return normalizedFirst == normalizedSecond;
  }

  Future<void> _replaceFileSafely({
    required String sourcePath,
    required String replacementPath,
  }) async {
    final source = File(sourcePath);
    final replacement = File(replacementPath);
    if (!await source.exists()) {
      throw Exception('替换原视频失败：原视频不存在');
    }

    final backupPath =
        '$sourcePath.ai_embedding_backup_${DateTime.now().microsecondsSinceEpoch}';
    final backup = File(backupPath);
    await source.rename(backupPath);
    try {
      await replacement.rename(sourcePath);
      final committed = File(sourcePath);
      if (!await committed.exists() || await committed.length() <= 0) {
        throw Exception('替换原视频失败：提交后的文件无效');
      }
    } catch (_) {
      await _safeDeleteFile(sourcePath);
      if (await backup.exists()) {
        await backup.rename(sourcePath);
      }
      rethrow;
    }

    try {
      await backup.delete();
    } catch (e) {
      debugPrint('清理原视频备份失败（嵌入结果已提交）: $backupPath, $e');
    }
  }

  /// 构建嵌入后的输出文件路径（含前缀/后缀命名）
  String _buildEmbeddedOutputPath(String videoPath, SettingsService settings) {
    final dir = p.dirname(videoPath);
    final ext = p.extension(videoPath);
    final baseName = p.basenameWithoutExtension(videoPath);
    String result = baseName;
    if (settings.batchSubtitleEmbedSoftPrefixEnabled &&
        settings.batchSubtitleEmbedSoftPrefix.isNotEmpty) {
      result = '${settings.batchSubtitleEmbedSoftPrefix}$result';
    }
    if (settings.batchSubtitleEmbedSoftSuffixEnabled &&
        settings.batchSubtitleEmbedSoftSuffix.isNotEmpty) {
      result = '$result${settings.batchSubtitleEmbedSoftSuffix}';
    }
    return p.join(dir, '$result$ext');
  }

  /// 使用 ffmpeg 将 SRT 软字幕嵌入视频（流拷贝模式，不重新编码）
  Future<void> _embedSoftSubtitle({
    required String srcVideo,
    required String srtPath,
    required String outputPath,
    required void Function(double ratio) onProgress,
    required _JobCancellation cancellation,
  }) async {
    final args = <String>[
      '-y',
      '-i',
      srcVideo,
      '-i',
      srtPath,
      '-c:v',
      'copy',
      '-c:a',
      'copy',
      '-map',
      '0:v?',
      '-map',
      '0:a?',
      '-map',
      '1:0',
      '-c:s',
      'mov_text',
      '-metadata:s:s:0',
      'title=AI字幕',
      '-metadata:s:s:0',
      'handler_name=AI字幕',
      '-metadata:s:s:0',
      'language=chi',
    ];

    // 探测视频时长用于进度计算
    double totalSeconds = 1.0;
    try {
      final probe = await _probeMedia(srcVideo, cancellation);
      totalSeconds = (probe.durationSeconds ?? 1.0).clamp(1.0, 99999.0);
    } catch (_) {
      cancellation.throwIfCancelled();
      // 探测失败使用默认时长
    }

    args.add(outputPath);

    if (Platform.isWindows) {
      await _runEmbedFfmpegWindows(
        args,
        totalSeconds: totalSeconds,
        onProgress: onProgress,
        cancellation: cancellation,
      );
      return;
    }

    await _runEmbedFfmpegKit(
      args,
      totalSeconds: totalSeconds,
      onProgress: onProgress,
      cancellation: cancellation,
    );
  }

  /// Windows 平台软字幕嵌入 ffmpeg 执行
  Future<void> _runEmbedFfmpegWindows(
    List<String> args, {
    required double totalSeconds,
    required void Function(double ratio) onProgress,
    required _JobCancellation cancellation,
  }) async {
    final ffmpegPath = await FFmpegUtils.ffmpegPath;
    final process = await Process.start(ffmpegPath, args);
    final stderrBuffer = StringBuffer();
    final startedAt = DateTime.now();
    DateTime lastActivityAt = startedAt;
    bool killRequested = false;
    String? abortReason;
    final timeout = Duration(
      seconds: (totalSeconds * 0.5 + 120).clamp(60, 3600).toInt(),
    );
    final inactivityTimeout = Duration(seconds: 30);

    void recordLine(String line) {
      lastActivityAt = DateTime.now();
      stderrBuffer.writeln(line);
      final match = RegExp(
        r'time=(\d{2}):(\d{2}):(\d{2}(?:\.\d+)?)',
      ).firstMatch(line);
      if (match != null) {
        final h = double.tryParse(match.group(1) ?? '') ?? 0;
        final m = double.tryParse(match.group(2) ?? '') ?? 0;
        final s = double.tryParse(match.group(3) ?? '') ?? 0;
        final current = h * 3600 + m * 60 + s;
        final ratio = (current / totalSeconds).clamp(0.0, 1.0);
        onProgress(ratio);
      }
    }

    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(recordLine);
    process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(recordLine);

    final monitor = Timer.periodic(const Duration(seconds: 2), (_) {
      if (killRequested) return;
      final now = DateTime.now();
      if (cancellation.isCancelled) {
        abortReason = cancellation.reason;
        killRequested = true;
        process.kill();
      } else if (now.difference(lastActivityAt) > inactivityTimeout) {
        abortReason = 'FFmpeg 内嵌软字幕超时（无输出），已自动中断';
        killRequested = true;
        process.kill();
      } else if (now.difference(startedAt) > timeout) {
        abortReason = 'FFmpeg 内嵌软字幕总超时，已自动中断';
        killRequested = true;
        process.kill();
      }
    });

    final exitCode = await process.exitCode;
    monitor.cancel();
    cancellation.throwIfCancelled();

    if (abortReason != null) {
      throw Exception(abortReason);
    }
    if (exitCode != 0) {
      final errorText = _summarizeText(
        stderrBuffer.toString(),
        fallback: '未知错误',
      );
      throw Exception('FFmpeg 内嵌软字幕失败 (exit=$exitCode): $errorText');
    }
  }

  /// 非 Windows 平台软字幕嵌入 ffmpeg 执行
  Future<void> _runEmbedFfmpegKit(
    List<String> args, {
    required double totalSeconds,
    required void Function(double ratio) onProgress,
    required _JobCancellation cancellation,
  }) async {
    final completer = Completer<dynamic>();
    final startedAt = DateTime.now();
    DateTime lastActivityAt = startedAt;
    bool cancelRequested = false;
    String? cancelReason;
    final timeout = Duration(
      seconds: (totalSeconds * 0.5 + 120).clamp(60, 3600).toInt(),
    );
    final inactivityTimeout = Duration(seconds: 30);

    final session = await FFmpegKit.executeWithArgumentsAsync(
      args,
      (session) async {
        if (!completer.isCompleted) {
          completer.complete(session);
        }
      },
      (log) {
        lastActivityAt = DateTime.now();
        final message = log.getMessage();
        final match = RegExp(
          r'time=(\d{2}):(\d{2}):(\d{2}(?:\.\d+)?)',
        ).firstMatch(message);
        if (match != null) {
          final h = double.tryParse(match.group(1) ?? '') ?? 0;
          final m = double.tryParse(match.group(2) ?? '') ?? 0;
          final s = double.tryParse(match.group(3) ?? '') ?? 0;
          final current = h * 3600 + m * 60 + s;
          final ratio = (current / totalSeconds).clamp(0.0, 1.0);
          onProgress(ratio);
        }
      },
      (_) {
        lastActivityAt = DateTime.now();
      },
    );

    final monitor = Timer.periodic(const Duration(seconds: 2), (_) {
      if (cancelRequested) return;
      final now = DateTime.now();
      if (cancellation.isCancelled) {
        cancelRequested = true;
        cancelReason = cancellation.reason;
        unawaited(FFmpegKit.cancel(session.getSessionId()));
      } else if (now.difference(lastActivityAt) > inactivityTimeout) {
        cancelRequested = true;
        cancelReason = 'FFmpeg 内嵌软字幕超时（无输出），已自动中断';
        unawaited(FFmpegKit.cancel(session.getSessionId()));
      } else if (now.difference(startedAt) > timeout) {
        cancelRequested = true;
        cancelReason = 'FFmpeg 内嵌软字幕总超时，已自动中断';
        unawaited(FFmpegKit.cancel(session.getSessionId()));
      }
    });

    try {
      final completedSession = await completer.future;
      cancellation.throwIfCancelled();
      final returnCode = await completedSession.getReturnCode();
      if (cancelRequested || ReturnCode.isCancel(returnCode)) {
        final logs = await completedSession.getAllLogsAsString();
        throw Exception(
          cancelReason ?? _summarizeText(logs ?? '', fallback: 'FFmpeg 已取消'),
        );
      }
      if (!ReturnCode.isSuccess(returnCode)) {
        final logs = await completedSession.getAllLogsAsString();
        throw Exception(
          'FFmpeg 内嵌软字幕失败: ${_summarizeText(logs ?? '', fallback: '未知错误')}',
        );
      }
    } finally {
      monitor.cancel();
    }
  }

  /// 安全删除文件（不抛异常）
  Future<void> _safeDeleteFile(String path) async {
    final file = File(path);
    if (!await file.exists()) return;
    try {
      await file.delete();
      debugPrint('已删除文件: $path');
    } catch (e) {
      debugPrint('删除文件失败（忽略）: $path, $e');
    }
  }
}

class _TranscriptionJob {
  final String videoPath;
  final String? videoId;
  final String mediaKey;
  final LibraryService? libraryService;
  final bool autoCache;
  final bool isExternal;
  final SubtitleOutputPathStrategy? outputPathStrategy;
  final String? customOutputDir;
  final int createdAt;
  final String displayName;
  final String durationLabel;

  _TranscriptionJob({
    required this.videoPath,
    required this.videoId,
    required this.mediaKey,
    required this.libraryService,
    required this.autoCache,
    this.isExternal = false,
    this.outputPathStrategy,
    this.customOutputDir,
    int? createdAt,
    String? displayName,
    this.durationLabel = '',
  }) : createdAt = createdAt ?? 0,
       displayName = (displayName == null || displayName.trim().isEmpty)
           ? p.basename(videoPath)
           : displayName.trim();

  /// 序列化为 JSON（不含非持久化字段：libraryService、autoCache）
  Map<String, dynamic> toJson() => {
    'videoPath': videoPath,
    'videoId': videoId,
    'mediaKey': mediaKey,
    'isExternal': isExternal,
    'outputPathStrategy': outputPathStrategy?.name,
    'customOutputDir': customOutputDir,
    'createdAt': createdAt,
    'displayName': displayName,
    'durationLabel': durationLabel,
  };

  /// 从 JSON 反序列化（libraryService 和 autoCache 在运行时重新注入）
  factory _TranscriptionJob.fromJson(Map<String, dynamic> json) {
    final strategyName = json['outputPathStrategy'] as String?;
    return _TranscriptionJob(
      videoPath: json['videoPath'] as String? ?? '',
      videoId: json['videoId'] as String?,
      mediaKey: json['mediaKey'] as String? ?? '',
      libraryService: null,
      autoCache: false,
      isExternal: json['isExternal'] as bool? ?? false,
      outputPathStrategy: strategyName != null
          ? SubtitleOutputPathStrategy.values.firstWhere(
              (e) => e.name == strategyName,
              orElse: () => SubtitleOutputPathStrategy.sameAsVideo,
            )
          : null,
      customOutputDir: json['customOutputDir'] as String?,
      createdAt: json['createdAt'] as int? ?? 0,
      displayName: json['displayName'] as String?,
      durationLabel: json['durationLabel'] as String? ?? '',
    );
  }
}

class _JobCancellation {
  final CancelToken dioCancelToken = CancelToken();
  final Completer<void> _cancelled = Completer<void>();
  bool _timedOut = false;
  String _reason = '任务已取消';

  bool get isCancelled => _cancelled.isCompleted;
  String get reason => _reason;
  Future<void> get whenCancelled => _cancelled.future;

  void cancel(String reason, {bool timedOut = false}) {
    if (isCancelled) return;
    _reason = reason;
    _timedOut = timedOut;
    dioCancelToken.cancel(reason);
    _cancelled.complete();
  }

  void throwIfCancelled() {
    if (isCancelled) {
      throw _JobCancelledException(_reason, timedOut: _timedOut);
    }
  }

  Future<void> delay(Duration duration) async {
    throwIfCancelled();
    await Future.any<void>([Future<void>.delayed(duration), whenCancelled]);
    throwIfCancelled();
  }
}

class _JobCancelledException implements Exception {
  final String message;
  final bool timedOut;

  const _JobCancelledException(this.message, {this.timedOut = false});

  @override
  String toString() => message;
}

class _PreparedAudioResult {
  final String audioPath;
  final bool isTemporary;

  const _PreparedAudioResult({
    required this.audioPath,
    required this.isTemporary,
  });
}

class _MediaProbeInfo {
  final String? codec;
  final double? durationSeconds;
  final bool hasAudioStream;
  final bool isAudioInput;

  const _MediaProbeInfo({
    required this.codec,
    required this.durationSeconds,
    required this.hasAudioStream,
    required this.isAudioInput,
  });
}

class _AudioPreparationException implements Exception {
  final String message;
  final bool retryable;

  const _AudioPreparationException(this.message, {this.retryable = false});

  @override
  String toString() => message;
}
