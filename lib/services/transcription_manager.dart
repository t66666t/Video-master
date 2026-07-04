import 'dart:convert';
import 'dart:collection';
import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/services/bcut_asr_service.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/services/temporary_storage_cleanup_models.dart';
import 'package:video_player_app/utils/ffmpeg_utils.dart';

enum TranscriptionStatus {
  idle,
  extracting,
  uploading,
  transcribing,
  completed,
  error,
}

class TranscriptionManager extends ChangeNotifier {
  static const String _managedTempAudioDirName = 'ai_transcription_temp_audio';
  static const String _managedTempAudioPrefix = 'temp_audio_';
  static const Set<String> _audioExtensions = <String>{
    '.mp3',
    '.m4a',
    '.wav',
    '.flac',
    '.ogg',
    '.aac',
    '.wma',
    '.opus',
    '.m4b',
    '.aiff',
    '.aif',
    '.ape',
  };

  final BcutAsrService _asrService = BcutAsrService();
  final Queue<_TranscriptionJob> _queue = Queue<_TranscriptionJob>();
  final Set<String> _queuedMediaKeys = <String>{};
  final Map<String, String> _resultSrtByMediaKey = <String, String>{};
  final Set<String> _consumedResultMediaKeys = <String>{};
  
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
  
  bool get isProcessing => _status != TranscriptionStatus.idle && 
                           _status != TranscriptionStatus.completed && 
                           _status != TranscriptionStatus.error;

  void markResultConsumed() {
    final mediaKey = _currentMediaKey;
    if (mediaKey == null) return;
    _consumedResultMediaKeys.add(mediaKey);
    notifyListeners();
  }

  void markResultConsumedForVideo(String videoPath, {String? videoId}) {
    final mediaKey = _mediaKey(videoPath, videoId: videoId);
    _consumedResultMediaKeys.add(mediaKey);
    notifyListeners();
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
    notifyListeners();
  }

  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
    await _cleanupManagedTempAudioDirectory();
  }

  Future<void> shutdown() async {
    await _cleanupManagedTempAudioDirectory();
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
    LibraryService? libraryService,
    bool autoCache = false,
  }) async {
    if (videoPath.trim().isEmpty) {
      throw Exception("视频路径不能为空");
    }
    final mediaKey = _mediaKey(videoPath, videoId: videoId);
    if (isVideoRunning(videoPath, videoId: videoId) ||
        isVideoQueued(videoPath, videoId: videoId)) {
      return;
    }

    _queue.add(
      _TranscriptionJob(
        videoPath: videoPath,
        videoId: videoId,
        mediaKey: mediaKey,
        libraryService: libraryService,
        autoCache: autoCache,
      ),
    );
    _queuedMediaKeys.add(mediaKey);
    notifyListeners();
    _ensureQueueProcessing();
  }

  void _ensureQueueProcessing() {
    if (_isQueueProcessing) return;
    unawaited(_processQueue());
  }

  Future<void> _processQueue() async {
    if (_isQueueProcessing) return;
    _isQueueProcessing = true;
    try {
      while (_queue.isNotEmpty) {
        final job = _queue.removeFirst();
        _queuedMediaKeys.remove(job.mediaKey);
        await _runJob(job);
      }
    } finally {
      _isQueueProcessing = false;
      _libraryService = null;
      _autoCache = false;
    }
  }

  Future<void> _runJob(_TranscriptionJob job) async {
    _currentVideoPath = job.videoPath;
    _currentVideoId = job.videoId;
    _libraryService = job.libraryService;
    _autoCache = job.autoCache;
    _status = TranscriptionStatus.extracting;
    _statusMessage = "";
    _progress = 0.0;
    notifyListeners();

    _PreparedAudioResult? preparedAudio;
    try {
      _updateStatus(TranscriptionStatus.extracting, "正在准备识别音频...", 0.0);
      preparedAudio = await _prepareAudioForTranscription(job.videoPath);

      _updateStatus(TranscriptionStatus.uploading, "准备上传音频...", 0.1);

      final subtitles = await _asrService.transcribeAudio(
        preparedAudio.audioPath,
        onProgress: (p, msg) {
          TranscriptionStatus newStatus = _status;
          if (p < 0.6) {
            newStatus = TranscriptionStatus.uploading;
          } else {
            newStatus = TranscriptionStatus.transcribing;
          }
          _updateStatus(newStatus, msg, p);
        },
      );

      _updateStatus(TranscriptionStatus.transcribing, "正在保存字幕文件...", 0.95);
      final srtContent = _generateSrt(subtitles);
      final srtPath = await _saveSrtFile(
        job.videoPath,
        srtContent,
        videoId: job.videoId,
      );

      _lastGeneratedSrtPath = srtPath;
      _resultSrtByMediaKey[job.mediaKey] = srtPath;
      _consumedResultMediaKeys.remove(job.mediaKey);

      if (_currentVideoId != null && _libraryService != null) {
        try {
          final currentVideo = _libraryService!.getVideo(_currentVideoId!);
          String? existingSecondaryPath = currentVideo?.secondarySubtitlePath;
          bool isSecondaryCached = currentVideo?.isSecondarySubtitleCached ?? false;

          await _libraryService!.updateVideoSubtitles(
            _currentVideoId!,
            srtPath,
            _autoCache,
            secondarySubtitlePath: existingSecondaryPath,
            isSecondaryCached: isSecondaryCached,
          );
          debugPrint("AI字幕已自动保存到库: $_currentVideoId");
        } catch (e) {
          debugPrint("自动保存字幕失败: $e");
        }
      }

      _updateStatus(TranscriptionStatus.completed, "转录完成", 1.0);
    } catch (e) {
      _updateStatus(TranscriptionStatus.error, "转录失败: $e", 0.0);
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
    }
  }
  
  void _updateStatus(TranscriptionStatus status, String message, double progress) {
    _status = status;
    _statusMessage = message;
    _progress = progress;
    notifyListeners();
  }
  
  Future<_MediaProbeInfo> _probeMedia(String mediaPath) async {
    final isAudioInput = _looksLikeAudioInput(mediaPath);
    Object? lastError;
    try {
      if (Platform.isWindows) {
        final ffprobePath = await FFmpegUtils.ffprobePath;
        final result = await Process.run(ffprobePath, [
          '-v', 'quiet',
          '-print_format', 'json',
          '-show_streams',
          '-show_format',
          mediaPath,
        ]).timeout(const Duration(seconds: 12));

        if (result.exitCode == 0) {
          return _parseMediaProbeInfo(
            jsonDecode(result.stdout.toString()) as Map<String, dynamic>,
            isAudioInput: isAudioInput,
          );
        }
        lastError = StateError(
          'ffprobe 退出码 ${result.exitCode}: ${_summarizeProcessOutput(result)}',
        );
        final fallbackInfo = await _probeMediaWithFfmpegCli(
          mediaPath,
          isAudioInput: isAudioInput,
        );
        if (fallbackInfo != null) {
          return fallbackInfo;
        }
      } else {
        final session = await FFprobeKit.getMediaInformation(mediaPath);
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
      lastError = e;
      if (Platform.isWindows) {
        final fallbackInfo = await _probeMediaWithFfmpegCli(
          mediaPath,
          isAudioInput: isAudioInput,
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
  }) async {
    try {
      final ffmpegPath = await FFmpegUtils.ffmpegPath;
      final result = await Process.run(ffmpegPath, [
        '-hide_banner',
        '-i',
        mediaPath,
      ]).timeout(const Duration(seconds: 12));
      final combinedOutput =
          '${result.stderr}\n${result.stdout}'.replaceAll('\r', '\n');
      final hasAudioStream = RegExp(
        r'^\s*Stream #.*Audio:',
        multiLine: true,
      ).hasMatch(combinedOutput);
      if (!hasAudioStream && !isAudioInput) {
        return null;
      }

      final codecMatch = RegExp(r'Audio:\s*([A-Za-z0-9_]+)').firstMatch(
        combinedOutput,
      );
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
      debugPrint("ffmpeg CLI 回退探测失败: $e");
      return null;
    }
  }

  Future<_PreparedAudioResult> _prepareAudioForTranscription(String mediaPath) async {
    final probe = await _probeMedia(mediaPath);
    if (!probe.hasAudioStream) {
      throw Exception("未检测到可用于转录的音频流");
    }

    if (_canDirectlyUploadAudio(mediaPath, probe)) {
      _updateStatus(
        TranscriptionStatus.extracting,
        "音频已符合上传格式，跳过转码...",
        0.05,
      );
      return _PreparedAudioResult(audioPath: mediaPath, isTemporary: false);
    }

    final maxAttempts = probe.isAudioInput ? 2 : 3;
    Object? lastError;
    for (int attempt = 1; attempt <= maxAttempts; attempt++) {
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
        );
        return _PreparedAudioResult(audioPath: tempAudioPath, isTemporary: true);
      } catch (e) {
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
        await Future.delayed(Duration(milliseconds: 600 * attempt));
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
      return preferCopy
          ? "正在快速整理音频格式..."
          : "正在转码音频为识别格式...";
    }
    return preferCopy
        ? "正在快速提取音轨..."
        : "正在提取并转码音轨...";
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
    return _audioExtensions.contains(p.extension(mediaPath).toLowerCase());
  }

  double? _parseDurationSeconds(Object? rawValue) {
    if (rawValue == null) return null;
    if (rawValue is num) return rawValue.toDouble();
    return double.tryParse(rawValue.toString());
  }

  Duration _buildExtractionTimeout(_MediaProbeInfo probe, {required bool useCopy}) {
    final seconds = probe.durationSeconds ?? 0;
    final int rounded = seconds.isFinite ? seconds.ceil() : 0;
    final int baseSeconds;
    final int scaleSeconds;
    if (useCopy) {
      baseSeconds = probe.isAudioInput ? 30 : 45;
      scaleSeconds = (rounded * 0.35).ceil();
    } else {
      baseSeconds = probe.isAudioInput ? 90 : 120;
      scaleSeconds = (rounded * 1.2).ceil();
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
  }) async {
    final args = <String>[
      '-y',
      '-i', mediaPath,
      '-map', '0:a:0',
      '-vn',
      '-sn',
      '-dn',
    ];
    if (useCopy) {
      args.addAll(['-c:a', 'copy']);
    } else {
      args.addAll([
        '-c:a', 'aac',
        '-ar', '16000',
        '-ac', '1',
        '-b:a', '64k',
      ]);
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
      );
      return;
    }

    await _runFfmpegKit(
      args,
      timeout: timeout,
      inactivityTimeout: inactivityTimeout,
    );
  }

  Future<void> _runWindowsFfmpeg(
    List<String> args, {
    required Duration timeout,
    required Duration inactivityTimeout,
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

    final stdoutSub = process.stdout.listen((data) => recordOutput(data, stdoutBuffer));
    final stderrSub = process.stderr.listen((data) => recordOutput(data, stderrBuffer));
    final monitor = Timer.periodic(const Duration(seconds: 1), (_) {
      if (killRequested) return;
      final now = DateTime.now();
      if (now.difference(lastActivityAt) > inactivityTimeout) {
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
      if (now.difference(lastActivityAt) > inactivityTimeout) {
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

  String _summarizeProcessLogs(StringBuffer stdoutBuffer, StringBuffer stderrBuffer) {
    final stderrText = stderrBuffer.toString().trim();
    if (stderrText.isNotEmpty) {
      return _summarizeText(stderrText, fallback: "未知错误");
    }
    final stdoutText = stdoutBuffer.toString().trim();
    return _summarizeText(stdoutText, fallback: "未知错误");
  }

  String _summarizeProcessOutput(ProcessResult result) {
    final stderrText = result.stderr.toString().trim();
    if (stderrText.isNotEmpty) {
      return _summarizeText(stderrText, fallback: "未知错误");
    }
    final stdoutText = result.stdout.toString().trim();
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
      await for (final entity in dir.list(recursive: true, followLinks: false)) {
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
      await for (final entity in dir.list(recursive: true, followLinks: false)) {
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
      buffer.writeln("${_formatDuration(item.startTime)} --> ${_formatDuration(item.endTime)}");
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

      Directory baseDir;
      if (Platform.isWindows) {
        final settings = SettingsService();
        baseDir = await settings.resolveLargeDataRootDir();
      } else {
        baseDir = await getApplicationDocumentsDirectory();
      }
      final subDir = Directory(p.join(baseDir.path, 'subtitles'));
      if (!await subDir.exists()) {
        await subDir.create(recursive: true);
      }
      
      final privateFileName = _aiSubtitleFileName(videoPath, videoId: videoId);
      final srtPath = p.join(subDir.path, privateFileName);
      
      await File(srtPath).writeAsString(srtContent);
      debugPrint("AI字幕已保存到私有目录: $srtPath");

      return srtPath;
    } catch (e) {
      debugPrint("保存字幕到私有目录失败: $e");
      // 如果私有目录也失败，尝试保存到视频目录（作为备选，虽然可能也会失败）
      try {
        final videoFile = File(videoPath);
        final dir = videoFile.parent.path;
        final fallbackFileName = _aiSubtitleFileName(videoPath, videoId: videoId);
        final srtPath = p.join(dir, fallbackFileName);
        await File(srtPath).writeAsString(srtContent);
        debugPrint("AI字幕已保存到视频目录: $srtPath");
        return srtPath;
      } catch (e2) {
        throw Exception("保存字幕文件失败: $e");
      }
    }
  }

  @override
  void dispose() {
    _queue.clear();
    _queuedMediaKeys.clear();
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

  String _aiSubtitleFileName(String videoPath, {String? videoId}) {
    final trimmedId = videoId?.trim();
    if (trimmedId != null && trimmedId.isNotEmpty) {
      return '$trimmedId.ai.srt';
    }
    final name = p.basenameWithoutExtension(videoPath);
    return '$name.ai.srt';
  }
}

class _TranscriptionJob {
  final String videoPath;
  final String? videoId;
  final String mediaKey;
  final LibraryService? libraryService;
  final bool autoCache;

  const _TranscriptionJob({
    required this.videoPath,
    required this.videoId,
    required this.mediaKey,
    required this.libraryService,
    required this.autoCache,
  });
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

  const _AudioPreparationException(
    this.message, {
    this.retryable = false,
  });

  @override
  String toString() => message;
}
