import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_session.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as im;
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_thumbnail/video_thumbnail.dart';

import '../models/managed_subtitle_asset.dart';
import '../models/ocr_subtitle_models.dart';
import '../utils/ffmpeg_utils.dart';
import 'library_service.dart';
import 'media_materialization_service.dart';
import 'ocr_model_manager.dart';
import 'ocr_processing_worker.dart';
import 'settings_service.dart';
import 'task_subtitle_storage_service.dart';

class OcrSubtitleManager extends ChangeNotifier {
  static const _persistenceKey = 'ocrSubtitleActiveJobV1';
  static const _regionsPersistenceKey = 'ocrSubtitleRegionsV1';
  static const _tracksPersistenceKey = 'ocrSubtitleTracksV1';
  static const _performanceProfilePrefix = 'ocrSubtitlePerformanceV2';
  final LibraryService library;
  final OcrModelManager modelManager;
  OcrSubtitleJob? _job;
  bool _cancelled = false;
  FFmpegSession? _activeSession;
  Process? _activeProcess;
  Completer<void>? _materializationCancellation;
  MediaMaterializationProgress? _materializationProgress;
  List<String> _completedPaths = const <String>[];
  String _activeBackend = '自动选择中';
  Timer? _notifyTimer;
  Timer? _persistTimer;
  DateTime _lastNotifyAt = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastPersistAt = DateTime.fromMillisecondsSinceEpoch(0);
  Future<void> _persistChain = Future<void>.value();
  Future<void>? _initialization;
  final Map<String, List<OcrSubtitleTrack>> _tracksByVideo = {};

  OcrSubtitleManager({required this.library, OcrModelManager? modelManager})
    : modelManager = modelManager ?? const OcrModelManager() {
    library.addListener(_handleLibraryChanged);
  }

  OcrSubtitleJob? get job => _job;
  bool get isRunning => _job?.isRunning ?? false;
  String get activeBackend => _activeBackend;
  MediaMaterializationProgress? get materializationProgress =>
      _materializationProgress;

  List<OcrSubtitleTrack> tracksForVideo(String videoId) => List.unmodifiable(
    _tracksByVideo[videoId] ??
        (_job?.videoId == videoId ? _job!.tracks : null) ??
        const <OcrSubtitleTrack>[
          OcrSubtitleTrack(
            number: 1,
            region: NormalizedOcrRegion.subtitleDefault(),
            language: OcrSubtitleLanguage.chinese,
          ),
        ],
  );

  void rememberTracks(String videoId, List<OcrSubtitleTrack> tracks) {
    _tracksByVideo[videoId] = _normalizeTracks(tracks);
    unawaited(_persistTracks());
  }

  Future<void> initialize() => _initialization ??= _initialize();

  Future<void> _initialize() async {
    final prefs = await SharedPreferences.getInstance();
    // Removed feature cleanup: discard cached automatic region proposals from
    // previous app versions. Manual OCR regions are stored under a separate key.
    await prefs.remove('ocrRegionDiscoveryCacheV1');
    final tracksRaw = prefs.getString(_tracksPersistenceKey);
    if (tracksRaw != null && tracksRaw.isNotEmpty) {
      try {
        final tracksJson = jsonDecode(tracksRaw) as Map<String, dynamic>;
        for (final entry in tracksJson.entries) {
          final values = entry.value as List<dynamic>? ?? const <dynamic>[];
          final tracks = values
              .whereType<Map>()
              .map(
                (value) =>
                    OcrSubtitleTrack.fromJson(Map<String, dynamic>.from(value)),
              )
              .toList();
          if (tracks.isNotEmpty) _tracksByVideo[entry.key] = tracks;
        }
      } catch (error) {
        debugPrint('OCR track persistence restore failed: $error');
        await prefs.remove(_tracksPersistenceKey);
      }
    }
    final regionsRaw = prefs.getString(_regionsPersistenceKey);
    if (regionsRaw != null && regionsRaw.isNotEmpty) {
      try {
        final regionsJson = jsonDecode(regionsRaw) as Map<String, dynamic>;
        for (final entry in regionsJson.entries) {
          final value = entry.value;
          if (value is Map) {
            final region = NormalizedOcrRegion.fromJson(
              Map<String, dynamic>.from(value),
            );
            _tracksByVideo.putIfAbsent(
              entry.key,
              () => <OcrSubtitleTrack>[
                OcrSubtitleTrack(
                  number: 1,
                  region: region,
                  language: OcrSubtitleLanguage.chinese,
                ),
              ],
            );
          }
        }
      } catch (error) {
        debugPrint('OCR region persistence restore failed: $error');
        await prefs.remove(_regionsPersistenceKey);
      }
    }
    final raw = prefs.getString(_persistenceKey);
    if (raw != null && raw.isNotEmpty) {
      try {
        final json = jsonDecode(raw) as Map<String, dynamic>;
        final status = OcrSubtitleJobStatus.values.firstWhere(
          (value) => value.name == json['status'],
          orElse: () => OcrSubtitleJobStatus.interrupted,
        );
        final restoredTracks = (json['tracks'] as List<dynamic>?)
            ?.whereType<Map>()
            .map(
              (value) =>
                  OcrSubtitleTrack.fromJson(Map<String, dynamic>.from(value)),
            )
            .toList();
        final restored = OcrSubtitleJob(
          videoId: json['videoId']?.toString() ?? '',
          videoPath: json['videoPath']?.toString() ?? '',
          tracks: restoredTracks?.isNotEmpty == true
              ? _normalizeTracks(restoredTracks!)
              : <OcrSubtitleTrack>[
                  OcrSubtitleTrack(
                    number: 1,
                    language: OcrSubtitleLanguage.values.firstWhere(
                      (value) => value.name == json['language'],
                      orElse: () => OcrSubtitleLanguage.chinese,
                    ),
                    region: NormalizedOcrRegion.fromJson(
                      Map<String, dynamic>.from(
                        json['region'] as Map? ?? const {},
                      ),
                    ),
                  ),
                ],
          start: Duration(milliseconds: json['startMs'] as int? ?? 0),
          end: Duration(milliseconds: json['endMs'] as int? ?? 0),
          mirrorHorizontal: json['mirrorHorizontal'] as bool? ?? false,
          mirrorVertical: json['mirrorVertical'] as bool? ?? false,
          status: status,
          progress: (json['progress'] as num?)?.toDouble() ?? 0,
          statusMessage: json['statusMessage']?.toString() ?? '',
          outputPaths:
              (json['outputPaths'] as List<dynamic>?)
                  ?.map((value) => value.toString())
                  .toList() ??
              <String>[
                if (json['outputPath']?.toString().isNotEmpty == true)
                  json['outputPath'].toString(),
              ],
        );
        _job = restored.isRunning
            ? restored.copyWith(
                status: OcrSubtitleJobStatus.interrupted,
                statusMessage: '上次 OCR 任务被中断，临时帧已清理，可重新开始',
              )
            : restored;
      } catch (_) {
        await prefs.remove(_persistenceKey);
      }
    }
    await cleanupStaleTemporaryFiles();
  }

  bool isModelBundled(OcrSubtitleLanguage language) =>
      modelManager.isBundled(language);

  int bundledModelCountFor(OcrSubtitleLanguage language) =>
      modelManager.bundledModelCountFor(language);

  int get totalBundledOnnxModelCount => modelManager.totalBundledOnnxModelCount;

  List<String>? consumeCompletedPaths(String videoId) {
    if (_job?.videoId != videoId) return null;
    final value = _completedPaths;
    _completedPaths = const <String>[];
    return value;
  }

  Future<bool> isModelInstalled(OcrSubtitleLanguage language) =>
      modelManager.isInstalled(language);

  Future<Duration> estimateDuration({
    required Duration mediaDuration,
    required Duration start,
    required Duration end,
    int trackCount = 1,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final historicalRate = prefs.getDouble(_performanceProfileKey);
    return _estimateDurationValue(
      mediaDuration: mediaDuration,
      start: start,
      end: end,
      trackCount: trackCount,
      historicalRate: historicalRate,
    );
  }

  Duration _estimateDurationValue({
    required Duration mediaDuration,
    required Duration start,
    required Duration end,
    int trackCount = 1,
    double? historicalRate,
  }) {
    final span = (end - start).inMilliseconds.clamp(
      1,
      math.max(1, mediaDuration.inMilliseconds),
    );
    final workMs = span * math.max(1, trackCount);
    final fallbackRate = Platform.isAndroid || Platform.isIOS ? 1.5 : 3.0;
    final measuredRate = historicalRate?.isFinite == true && historicalRate! > 0
        ? historicalRate
        : fallbackRate;
    // Add a safety margin because dialogue-heavy chunks are slower than quiet
    // calibration chunks. A small fixed cost covers model/session startup.
    final processingMs = workMs / measuredRate * 1.25;
    return Duration(milliseconds: math.max(5000, processingMs.round() + 4000));
  }

  String get _performanceProfileKey =>
      '$_performanceProfilePrefix.${Platform.operatingSystem}.${Platform.numberOfProcessors}';

  Future<void> _recordObservedPerformance(double rate) async {
    if (!rate.isFinite || rate <= 0) return;
    final prefs = await SharedPreferences.getInstance();
    final previous = prefs.getDouble(_performanceProfileKey);
    final updated = previous == null
        ? rate
        : rate < previous
        ? previous * 0.35 + rate * 0.65
        : previous * 0.85 + rate * 0.15;
    await prefs.setDouble(_performanceProfileKey, updated.clamp(0.05, 200.0));
  }

  Future<String> captureFrame({
    required String videoId,
    required String videoPath,
    required Duration position,
    bool mirrorHorizontal = false,
    bool mirrorVertical = false,
    int? maxWidth,
    bool fastPreview = false,
    void Function(MediaMaterializationProgress progress)? onProgress,
    Future<void>? cancelSignal,
  }) async {
    await initialize();
    MaterializedMediaLease? frameLease;
    var effectiveVideoPath = videoPath;
    final sourceItem = library.getVideo(videoId);
    if (sourceItem?.path.startsWith('bilibili://stream/') == true) {
      frameLease = await library.acquireMaterializedMedia(
        videoId,
        MediaMaterializationRequirement.videoFrames,
        targetHeight: 1080,
        onProgress: onProgress,
        cancelSignal: cancelSignal,
      );
      effectiveVideoPath = frameLease.requiredVideoPath;
    }
    try {
      final root = await SettingsService().resolveLargeDataRootDir();
      final dir = Directory(
        p.join(root.path, 'ocr_temp', _safeId(videoId), 'preview'),
      );
      if (!await dir.exists()) await dir.create(recursive: true);
      final output = p.join(
        dir.path,
        'preview_${DateTime.now().microsecondsSinceEpoch}.jpg',
      );
      final attempts = fastPreview
          ? <Duration>[position]
          : <Duration>[
              position,
              if (position > const Duration(milliseconds: 500))
                position - const Duration(milliseconds: 500),
              if (position != Duration.zero) Duration.zero,
            ];
      String lastError = '';
      for (final at in attempts) {
        if (Platform.isAndroid || Platform.isIOS) {
          try {
            final bytes = await VideoThumbnail.thumbnailData(
              video: effectiveVideoPath,
              imageFormat: ImageFormat.JPEG,
              maxWidth: maxWidth ?? 0,
              timeMs: math.max(0, at.inMilliseconds),
              quality: fastPreview ? 40 : 90,
            );
            if (bytes != null && bytes.isNotEmpty) {
              List<int> outputBytes = bytes;
              if (mirrorHorizontal || mirrorVertical) {
                var image = im.decodeImage(bytes);
                if (image == null) throw StateError('无法解码原生预览帧');
                if (mirrorHorizontal) image = im.flipHorizontal(image);
                if (mirrorVertical) image = im.flipVertical(image);
                outputBytes = im.encodeJpg(
                  image,
                  quality: fastPreview ? 45 : 92,
                );
              }
              await File(output).writeAsBytes(outputBytes, flush: true);
              if (await _isUsableImage(output)) return output;
            }
          } catch (error) {
            lastError = '原生视频帧提取失败：$error';
            final failedOutput = File(output);
            if (await failedOutput.exists()) await failedOutput.delete();
          }
        }
        final args = <String>[
          '-hide_banner',
          '-loglevel',
          'error',
          '-y',
          '-ss',
          _seconds(at),
          if (fastPreview) '-noaccurate_seek',
          '-i',
          effectiveVideoPath,
          '-map',
          '0:v:0',
          '-frames:v',
          '1',
          if (mirrorHorizontal || mirrorVertical || maxWidth != null) ...[
            '-vf',
            [
              if (mirrorHorizontal) 'hflip',
              if (mirrorVertical) 'vflip',
              if (maxWidth != null)
                'scale=trunc(min(iw\\,$maxWidth)/2)*2:-2:flags=fast_bilinear',
            ].join(','),
          ],
          '-q:v',
          fastPreview ? '6' : '2',
          '-c:v',
          'mjpeg',
          '-f',
          'image2',
          output,
        ];
        if (Platform.isWindows) {
          try {
            final ffmpegPath = await FFmpegUtils.ffmpegPath;
            final result = await Process.run(
              ffmpegPath,
              args,
            ).timeout(const Duration(seconds: 30));
            if (result.exitCode == 0 && await _isUsableImage(output)) {
              return output;
            }
            lastError = result.stderr?.toString().trim() ?? '';
          } catch (error) {
            lastError = error.toString();
          }
        } else {
          final session = await FFmpegKit.executeWithArguments(args);
          if (ReturnCode.isSuccess(await session.getReturnCode()) &&
              await _isUsableImage(output)) {
            return output;
          }
          lastError = (await session.getAllLogsAsString() ?? '').trim();
        }
        final failedOutput = File(output);
        if (await failedOutput.exists()) await failedOutput.delete();
      }
      debugPrint('OCR preview frame extraction failed: $lastError');
      final reason = _shortFfmpegError(lastError);
      if (reason.isEmpty) {
        throw StateError('无法提取当前视频画面');
      }
      throw StateError('无法提取当前视频画面：$reason');
    } finally {
      await frameLease?.release();
    }
  }

  Future<void> deletePreview(String? path) async {
    if (path == null || path.isEmpty) return;
    try {
      final root = await SettingsService().resolveLargeDataRootDir();
      final previewRoot = p.join(root.path, 'ocr_temp');
      if (!p.isWithin(previewRoot, path)) return;
      final file = File(path);
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  Future<void> cleanupTemporaryFilesForVideo(String videoId) async {
    try {
      final root = await SettingsService().resolveLargeDataRootDir();
      final directory = Directory(
        p.join(root.path, 'ocr_temp', _safeId(videoId)),
      );
      if (await directory.exists()) await directory.delete(recursive: true);
    } catch (error) {
      debugPrint('OCR temporary cleanup failed for $videoId: $error');
    }
  }

  Future<void> cleanupStaleTemporaryFiles() async {
    try {
      final root = await SettingsService().resolveLargeDataRootDir();
      final temporaryRoot = Directory(p.join(root.path, 'ocr_temp'));
      if (await temporaryRoot.exists()) {
        await temporaryRoot.delete(recursive: true);
      }
      await temporaryRoot.create(recursive: true);

      final tasksRoot = Directory(p.join(root.path, 'subtitles', 'tasks'));
      if (await tasksRoot.exists()) {
        await for (final entity in tasksRoot.list(recursive: true)) {
          if (entity is File && entity.path.endsWith('.partial')) {
            try {
              await entity.delete();
            } catch (_) {}
          }
        }
      }
    } catch (error) {
      debugPrint('OCR stale temporary cleanup failed: $error');
    }
  }

  Future<bool> _isUsableImage(String path) async {
    final file = File(path);
    return await file.exists() && await file.length() > 0;
  }

  String _shortFfmpegError(String value) {
    final lines = value
        .split(RegExp(r'[\r\n]+'))
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList();
    if (lines.isEmpty) return '';
    final text = lines.last;
    return text.length <= 160 ? text : text.substring(text.length - 160);
  }

  Future<void> start(OcrSubtitleJob request) async {
    await initialize();
    if (isRunning) throw StateError('已有 OCR 字幕任务正在运行');
    final normalizedTracks = _normalizeTracks(request.tracks);
    if (normalizedTracks.isEmpty) throw StateError('请至少保留一个 OCR 字幕区域');
    request = request.copyWith(tracks: normalizedTracks);
    rememberTracks(request.videoId, normalizedTracks);
    if (request.end <= request.start) throw StateError('OCR 时间范围无效');
    _cancelled = false;
    _completedPaths = const <String>[];
    _activeBackend = '自动选择中';
    var initialEstimate = _estimateDurationValue(
      mediaDuration: request.end - request.start,
      start: Duration.zero,
      end: request.end - request.start,
      trackCount: normalizedTracks.length,
    );
    _update(
      request.copyWith(
        status: OcrSubtitleJobStatus.preparing,
        progress: 0,
        remaining: initialEstimate,
        statusMessage: '正在准备 OCR 字幕任务',
      ),
    );
    initialEstimate = await estimateDuration(
      mediaDuration: request.end - request.start,
      start: Duration.zero,
      end: request.end - request.start,
      trackCount: normalizedTracks.length,
    );
    _update(_job!.copyWith(remaining: initialEstimate));
    OcrProcessingWorker? worker;
    Directory? tempRoot;
    MaterializedMediaLease? materializedLease;
    final sourceItem = library.getVideo(request.videoId);
    final isOnline = sourceItem?.path.startsWith('bilibili://stream/') == true;
    final preparationEnd = isOnline ? 0.20 : 0.08;
    try {
      if (isOnline) {
        _materializationCancellation = Completer<void>();
        _materializationProgress = const MediaMaterializationProgress(
          stage: MediaMaterializationStage.resolving,
          progress: 0,
          message: '正在准备 Bilibili 视频素材',
        );
        materializedLease = await library.acquireMaterializedMedia(
          request.videoId,
          MediaMaterializationRequirement.videoFrames,
          targetHeight: 1080,
          cancelSignal: _materializationCancellation!.future,
          onProgress: (value) {
            _materializationProgress = value;
            _update(
              _job!.copyWith(
                status: OcrSubtitleJobStatus.materializing,
                progress: value.progress * 0.12,
                statusMessage:
                    '${value.message}${_materializationDetails(value)}',
              ),
            );
          },
        );
        request = request.copyWith(
          videoPath: materializedLease.requiredVideoPath,
        );
        _materializationProgress = null;
        // OCR 使用的 1080P 视频轨现已就位。后台补齐音频并封装出可直接
        // 播放的本地文件：之后在播放页播放同画质时命中本地文件，无需整段
        // 在线重播。用户离开 OCR 页也不影响该缓存补齐任务继续。
        final materialization = library.mediaMaterializationService;
        final sourceVideo = library.getVideo(request.videoId);
        if (materialization != null && sourceVideo != null) {
          unawaited(materialization.ensurePlaybackFileReady(sourceVideo));
        }
      }
      final languages = normalizedTracks
          .map((track) => track.language)
          .toSet()
          .toList();
      final modelFiles = <OcrSubtitleLanguage, OcrModelFiles>{};
      for (
        var languageIndex = 0;
        languageIndex < languages.length;
        languageIndex++
      ) {
        _throwIfCancelled();
        final language = languages[languageIndex];
        _update(
          _job!.copyWith(
            status: OcrSubtitleJobStatus.downloading,
            statusMessage: '正在校验 OCR 模型',
          ),
        );
        modelFiles[language] = await modelManager.ensureInstalled(
          language,
          isCancelled: () => _cancelled,
          onProgress: (progress, message) => _update(
            _job!.copyWith(
              status: OcrSubtitleJobStatus.downloading,
              progress:
                  (isOnline ? 0.12 : 0.0) +
                  0.08 * ((languageIndex + progress) / languages.length),
              statusMessage: message,
            ),
          ),
        );
      }
      final dataRoot = await SettingsService().resolveLargeDataRootDir();
      tempRoot = Directory(
        p.join(dataRoot.path, 'ocr_temp', _safeId(request.videoId)),
      );
      if (await tempRoot.exists()) await tempRoot.delete(recursive: true);
      await tempRoot.create(recursive: true);

      final spanMs = math.max(1, (request.end - request.start).inMilliseconds);
      final totalWorkMs = spanMs * normalizedTracks.length;
      final progressTracker = OcrTaskProgressTracker(
        totalMs: totalWorkMs,
        processingStart: preparationEnd,
      );
      const chunkDuration = Duration(seconds: 15);
      final results = <_OcrTrackResult>[];
      OcrSubtitleLanguage? workerLanguage;
      for (
        var trackIndex = 0;
        trackIndex < normalizedTracks.length;
        trackIndex++
      ) {
        _throwIfCancelled();
        final track = normalizedTracks[trackIndex];
        _activeBackend = '区域 ${track.number} · 自动选择中';
        _throwIfCancelled();
        _update(
          _job!.copyWith(
            status: OcrSubtitleJobStatus.preparing,
            statusMessage: workerLanguage == track.language
                ? '正在复用 OCR 工作线程'
                : '正在启动 OCR 工作线程并检测 CPU/GPU',
          ),
        );
        if (worker == null || workerLanguage != track.language) {
          await worker?.close();
          worker = await OcrProcessingWorker.start(modelFiles[track.language]!);
          workerLanguage = track.language;
        } else {
          await worker.resetFrameHistory();
        }
        final cues = <_OcrCue>[];
        String activeText = '';
        Duration? activeStart;
        Duration lastObserved = request.start;
        var chunkStart = request.start;
        var isCalibrationChunk = true;
        _update(
          _job!.copyWith(
            status: OcrSubtitleJobStatus.recognizing,
            statusMessage: '正在处理 OCR 字幕',
          ),
        );

        while (chunkStart < request.end) {
          _throwIfCancelled();
          final currentChunkDuration = isCalibrationChunk
              ? const Duration(seconds: 5)
              : chunkDuration;
          final chunkEnd = _minDuration(
            request.end,
            chunkStart + currentChunkDuration,
          );
          final chunkWatch = Stopwatch()..start();
          final chunkDir = Directory(
            p.join(
              tempRoot.path,
              'track_${track.number}',
              'chunk_${chunkStart.inMilliseconds}',
            ),
          );
          await chunkDir.create(recursive: true);
          final frameTimes = await _extractChunk(
            request,
            track,
            chunkStart,
            chunkEnd,
            chunkDir,
          );
          _throwIfCancelled();
          final frames =
              chunkDir
                  .listSync()
                  .whereType<File>()
                  .where((f) => p.extension(f.path).toLowerCase() == '.jpg')
                  .toList()
                ..sort((a, b) => a.path.compareTo(b.path));

          for (var index = 0; index < frames.length; index++) {
            _throwIfCancelled();
            final localFrameMs = index < frameTimes.length
                ? frameTimes[index]
                : index * 100;
            final at = chunkStart + Duration(milliseconds: localFrameMs);
            if (at > request.end) break;
            late final OcrFrameAnalysis analysis;
            try {
              analysis = await worker.analyzeFrame(
                frames[index].path,
                at.inMilliseconds,
              );
            } finally {
              if (await frames[index].exists()) await frames[index].delete();
            }
            _activeBackend = '区域 ${track.number} · ${analysis.backend}';
            final processed =
                trackIndex * spanMs +
                (at - request.start).inMilliseconds.clamp(0, spanMs);
            if (progressTracker.shouldPublish(processed)) {
              _update(
                _job!.copyWith(
                  progress: progressTracker.progressFor(processed),
                  remaining: progressTracker.remaining ?? initialEstimate,
                  statusMessage: '正在处理 OCR 字幕',
                ),
              );
            }
            if (!analysis.candidate) continue;

            final text = _normalizeText(analysis.text);
            final boundaryMs = analysis.boundaryMs
                .clamp(request.start.inMilliseconds, at.inMilliseconds)
                .toInt();
            final boundary = Duration(milliseconds: boundaryMs);
            if (text.isEmpty) {
              if (activeText.isNotEmpty && activeStart != null) {
                _appendCue(cues, activeStart, boundary, activeText);
                activeText = '';
                activeStart = null;
              }
            } else if (activeText.isEmpty) {
              activeText = text;
              activeStart = boundary;
            } else if (!_similar(activeText, text)) {
              _appendCue(cues, activeStart!, boundary, activeText);
              activeText = text;
              activeStart = boundary;
            }
            lastObserved = at;
          }
          await chunkDir.delete(recursive: true);
          chunkWatch.stop();
          final completedMs =
              trackIndex * spanMs +
              (chunkEnd - request.start).inMilliseconds.clamp(0, spanMs);
          final remaining = progressTracker.calibrateChunk(
            chunkMediaMs: (chunkEnd - chunkStart).inMilliseconds,
            wallMs: chunkWatch.elapsedMilliseconds,
            completedMs: completedMs,
          );
          unawaited(
            _recordObservedPerformance(progressTracker.observedRate).catchError(
              (Object error) {
                debugPrint('OCR performance profile save failed: $error');
              },
            ),
          );
          _update(
            _job!.copyWith(
              progress: progressTracker.progressFor(completedMs),
              remaining: remaining,
              statusMessage: '正在处理 OCR 字幕',
            ),
          );
          chunkStart = chunkEnd;
          isCalibrationChunk = false;
        }
        if (activeText.isNotEmpty && activeStart != null) {
          _appendCue(
            cues,
            activeStart,
            request.end > lastObserved ? request.end : lastObserved,
            activeText,
          );
        }
        results.add(
          _OcrTrackResult(track, _removePersistentOverlayLines(cues)),
        );
      }
      await worker?.close();
      worker = null;
      _throwIfCancelled();
      _update(
        _job!.copyWith(
          status: OcrSubtitleJobStatus.writing,
          progress: 0.97,
          statusMessage: '正在保存 OCR 字幕',
        ),
      );
      final now = DateTime.now();
      final outputs = <String>[];
      var cueCount = 0;
      for (final result in results) {
        final fileName =
            'subtitle.ocr.${result.track.language.code}.${DateFormat('yyyyMMdd_HHmmss').format(now)}.srt';
        final output = await const TaskSubtitleStorageService().allocatePath(
          request.videoId,
          fileName,
        );
        final partial = File('$output.partial');
        await partial.writeAsString(_toSrt(result.cues), flush: true);
        await partial.rename(output);
        final displayName =
            'OCR 字幕 · ${result.track.language.label.replaceAll('（简繁兼容）', '')} · ${DateFormat('yyyy-MM-dd HH:mm').format(now)}';
        await library.registerManagedLocalSubtitle(
          request.videoId,
          path: output,
          kind: ManagedSubtitleAssetKind.ocr,
          displayName: displayName,
          language: result.track.language.code,
        );
        outputs.add(output);
        cueCount += result.cues.length;
      }
      _completedPaths = List.unmodifiable(outputs);
      _update(
        _job!.copyWith(
          status: OcrSubtitleJobStatus.completed,
          progress: 1,
          remaining: Duration.zero,
          outputPaths: outputs,
          statusMessage: '已生成 ${outputs.length} 条字幕轨，共 $cueCount 条字幕',
        ),
      );
    } on OcrDownloadCancelled {
      _setCancelled();
    } on _OcrJobCancelled {
      _setCancelled();
    } catch (error, stack) {
      debugPrint('OCR subtitle failed: $error\n$stack');
      _update(
        _job!.copyWith(
          status: OcrSubtitleJobStatus.failed,
          statusMessage: 'OCR 字幕识别失败',
          error: error.toString(),
        ),
      );
    } finally {
      try {
        await worker?.close();
      } catch (_) {}
      _activeSession = null;
      _activeProcess = null;
      _materializationCancellation = null;
      _materializationProgress = null;
      await materializedLease?.release();
      if (tempRoot != null && await tempRoot.exists()) {
        await tempRoot.delete(recursive: true);
      }
    }
  }

  Future<void> cancel() async {
    if (!isRunning) return;
    _cancelled = true;
    final materialization = _materializationCancellation;
    if (materialization != null && !materialization.isCompleted) {
      materialization.complete();
    }
    await _activeSession?.cancel();
    _activeProcess?.kill();
  }

  String _formatTransferBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    final kb = bytes / 1024;
    if (kb < 1024) return '${kb.toStringAsFixed(1)} KB';
    return '${(kb / 1024).toStringAsFixed(1)} MB';
  }

  String _materializationDetails(MediaMaterializationProgress value) {
    if (value.stage != MediaMaterializationStage.downloadingVideo &&
        value.stage != MediaMaterializationStage.downloadingAudio) {
      return '';
    }
    final total = value.totalBytes == null
        ? _formatTransferBytes(value.receivedBytes)
        : '${_formatTransferBytes(value.receivedBytes)} / '
              '${_formatTransferBytes(value.totalBytes!)}';
    final speed = value.bytesPerSecond > 0
        ? ' · ${_formatTransferBytes(value.bytesPerSecond.round())}/s'
        : '';
    final eta = value.remaining == null
        ? ''
        : ' · 剩余约 ${value.remaining!.inSeconds}s';
    return ' · $total$speed$eta';
  }

  Future<List<int>> _extractChunk(
    OcrSubtitleJob request,
    OcrSubtitleTrack track,
    Duration start,
    Duration end,
    Directory output,
  ) async {
    final crop = buildOcrFrameFilter(
      region: track.region,
      mirrorHorizontal: request.mirrorHorizontal,
      mirrorVertical: request.mirrorVertical,
    );
    final args = <String>[
      '-hide_banner',
      '-loglevel',
      'info',
      '-nostats',
      '-y',
      '-ss',
      _seconds(start),
      '-t',
      _seconds(end - start),
      '-threads',
      Platform.isWindows || Platform.isMacOS ? '2' : '1',
      '-i',
      request.videoPath,
      '-an',
      '-filter_threads',
      '1',
      '-threads',
      '1',
      '-vf',
      crop,
      '-fps_mode',
      'vfr',
      '-q:v',
      '6',
      p.join(output.path, '%06d.jpg'),
    ];
    if (Platform.isWindows) {
      final ffmpegPath = await FFmpegUtils.ffmpegPath;
      final process = await Process.start(ffmpegPath, args);
      _activeProcess = process;
      unawaited(
        Process.run('powershell.exe', <String>[
          '-NoProfile',
          '-NonInteractive',
          '-Command',
          '(Get-Process -Id ${process.pid}).PriorityClass = "BelowNormal"',
        ]).then<void>((_) {}).catchError((_) {}),
      );
      final stdoutFuture = process.stdout.drain<void>();
      final stderrFuture = process.stderr
          .transform(systemEncoding.decoder)
          .join();
      final code = await process.exitCode;
      await stdoutFuture;
      final errors = await stderrFuture;
      _activeProcess = null;
      if (_cancelled) throw const _OcrJobCancelled();
      if (code != 0) {
        final reason = _shortFfmpegError(errors);
        throw StateError(reason.isEmpty ? 'FFmpeg 抽帧失败（退出码 $code）' : reason);
      }
      return parseOcrFrameTimes(errors);
    }

    final completer = Completer<List<int>>();
    _activeSession = await FFmpegKit.executeWithArgumentsAsync(args, (
      session,
    ) async {
      final code = await session.getReturnCode();
      if (_cancelled || ReturnCode.isCancel(code)) {
        completer.completeError(const _OcrJobCancelled());
      } else if (!ReturnCode.isSuccess(code)) {
        completer.completeError(
          StateError(await session.getAllLogsAsString() ?? 'FFmpeg 抽帧失败'),
        );
      } else {
        final logs = await session.getAllLogsAsString() ?? '';
        completer.complete(parseOcrFrameTimes(logs));
      }
    });
    final times = await completer.future;
    _activeSession = null;
    return times;
  }

  String _normalizeText(String text) => text
      .replaceAll('\r', '')
      .split('\n')
      .map((line) => line.replaceAll(RegExp(r'\s+'), ' ').trim())
      .where((line) => line.isNotEmpty)
      .join('\n');

  bool _similar(String a, String b) {
    final left = a.replaceAll(RegExp(r'\s+'), '').toLowerCase();
    final right = b.replaceAll(RegExp(r'\s+'), '').toLowerCase();
    if (left == right) return true;
    final longest = math.max(left.length, right.length);
    if (longest == 0) return true;
    return 1 - _editDistance(left, right) / longest >= 0.82;
  }

  int _editDistance(String a, String b) {
    var previous = List<int>.generate(b.length + 1, (i) => i);
    for (var i = 0; i < a.length; i++) {
      final current = <int>[i + 1];
      for (var j = 0; j < b.length; j++) {
        current.add(
          math.min(
            math.min(current[j] + 1, previous[j + 1] + 1),
            previous[j] + (a.codeUnitAt(i) == b.codeUnitAt(j) ? 0 : 1),
          ),
        );
      }
      previous = current;
    }
    return previous.last;
  }

  void _appendCue(
    List<_OcrCue> cues,
    Duration start,
    Duration end,
    String text,
  ) {
    if (end <= start) end = start + const Duration(milliseconds: 500);
    if (end - start < const Duration(milliseconds: 300)) return;
    if (cues.isNotEmpty &&
        cues.last.text == text &&
        start - cues.last.end <= const Duration(milliseconds: 400)) {
      cues[cues.length - 1] = _OcrCue(cues.last.start, end, text);
    } else {
      cues.add(_OcrCue(start, end, text));
    }
  }

  List<_OcrCue> _removePersistentOverlayLines(List<_OcrCue> cues) {
    if (cues.length < 4) return cues;
    final stats = <String, _OverlayLineStats>{};
    for (final cue in cues) {
      final lines = cue.text
          .split('\n')
          .map((line) => line.trim())
          .where((line) => line.isNotEmpty)
          .toList();
      final keys = lines.map(_overlayLineKey).toSet();
      for (final key in keys) {
        final value = stats.putIfAbsent(
          key,
          () => _OverlayLineStats(first: cue.start, last: cue.end),
        );
        value.appearances++;
        value.last = cue.end;
        value.companions.addAll(keys.where((other) => other != key));
      }
    }
    final persistent = stats.entries
        .where((entry) {
          final value = entry.value;
          return value.appearances >= 4 &&
              value.appearances / cues.length >= 0.55 &&
              value.last - value.first >= const Duration(seconds: 8) &&
              value.companions.length >= 3;
        })
        .map((entry) => entry.key)
        .toSet();
    if (persistent.isEmpty) return cues;

    final filtered = <_OcrCue>[];
    for (final cue in cues) {
      final text = cue.text
          .split('\n')
          .map((line) => line.trim())
          .where(
            (line) =>
                line.isNotEmpty && !persistent.contains(_overlayLineKey(line)),
          )
          .join('\n');
      if (text.isNotEmpty) _appendCue(filtered, cue.start, cue.end, text);
    }
    return filtered;
  }

  String _overlayLineKey(String line) =>
      line.replaceAll(RegExp(r'\s+'), '').toLowerCase();

  String _toSrt(List<_OcrCue> cues) {
    final out = StringBuffer();
    for (var i = 0; i < cues.length; i++) {
      final cue = cues[i];
      out.writeln(i + 1);
      out.writeln('${_srtTime(cue.start)} --> ${_srtTime(cue.end)}');
      out.writeln(cue.text);
      out.writeln();
    }
    return out.toString();
  }

  String _srtTime(Duration value) {
    final ms = value.inMilliseconds;
    final hours = ms ~/ 3600000;
    final minutes = (ms ~/ 60000) % 60;
    final seconds = (ms ~/ 1000) % 60;
    final millis = ms % 1000;
    return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')},${millis.toString().padLeft(3, '0')}';
  }

  void _update(OcrSubtitleJob value) {
    final previousStatus = _job?.status;
    _job = value;
    final immediate = previousStatus != value.status || !value.isRunning;
    final now = DateTime.now();
    if (immediate ||
        now.difference(_lastNotifyAt) >= const Duration(milliseconds: 250)) {
      _notifyTimer?.cancel();
      _notifyTimer = null;
      _lastNotifyAt = now;
      notifyListeners();
    } else {
      _notifyTimer ??= Timer(const Duration(milliseconds: 250), () {
        _notifyTimer = null;
        _lastNotifyAt = DateTime.now();
        notifyListeners();
      });
    }

    if (immediate ||
        now.difference(_lastPersistAt) >= const Duration(seconds: 1)) {
      _persistTimer?.cancel();
      _persistTimer = null;
      _lastPersistAt = now;
      _queuePersist(value);
    } else {
      _persistTimer ??= Timer(const Duration(seconds: 1), () {
        _persistTimer = null;
        final latest = _job;
        if (latest == null) return;
        _lastPersistAt = DateTime.now();
        _queuePersist(latest);
      });
    }
  }

  void _queuePersist(OcrSubtitleJob value) {
    _persistChain = _persistChain.then((_) => _persist(value)).catchError((
      Object error,
    ) {
      debugPrint('OCR state persistence failed: $error');
    });
  }

  Future<void> _persist(OcrSubtitleJob value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _persistenceKey,
      jsonEncode({
        'videoId': value.videoId,
        'videoPath': value.videoPath,
        'tracks': value.tracks.map((track) => track.toJson()).toList(),
        'language': value.language.name,
        'region': value.region.toJson(),
        'startMs': value.start.inMilliseconds,
        'endMs': value.end.inMilliseconds,
        'mirrorHorizontal': value.mirrorHorizontal,
        'mirrorVertical': value.mirrorVertical,
        'status': value.status.name,
        'progress': value.progress,
        'statusMessage': value.statusMessage,
        'outputPath': value.outputPath,
        'outputPaths': value.outputPaths,
      }),
    );
  }

  Future<void> _persistTracks() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _tracksPersistenceKey,
        jsonEncode(
          _tracksByVideo.map(
            (videoId, tracks) => MapEntry(
              videoId,
              tracks.map((track) => track.toJson()).toList(),
            ),
          ),
        ),
      );
    } catch (error) {
      debugPrint('OCR region persistence failed: $error');
    }
  }

  List<OcrSubtitleTrack> _normalizeTracks(List<OcrSubtitleTrack> tracks) => [
    for (var index = 0; index < tracks.length; index++)
      OcrSubtitleTrack(
        number: index + 1,
        region: tracks[index].region.normalized(),
        language: tracks[index].language,
      ),
  ];

  void _setCancelled() => _update(
    _job!.copyWith(
      status: OcrSubtitleJobStatus.cancelled,
      statusMessage: 'OCR 字幕任务已取消',
    ),
  );

  void _throwIfCancelled() {
    if (_cancelled) throw const _OcrJobCancelled();
  }

  void _handleLibraryChanged() {
    final current = _job;
    if (current != null &&
        current.isRunning &&
        library.getVideo(current.videoId) == null) {
      unawaited(cancel());
      unawaited(cleanupTemporaryFilesForVideo(current.videoId));
    }
    final removedVideoIds = _tracksByVideo.keys
        .where((videoId) => library.getVideo(videoId) == null)
        .toList(growable: false);
    if (removedVideoIds.isEmpty) return;
    for (final videoId in removedVideoIds) {
      _tracksByVideo.remove(videoId);
    }
    unawaited(_persistTracks());
  }

  String _safeId(String value) =>
      value.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');

  String _seconds(Duration value) =>
      (value.inMilliseconds / 1000).toStringAsFixed(3);
  Duration _minDuration(Duration a, Duration b) => a <= b ? a : b;

  @override
  void dispose() {
    library.removeListener(_handleLibraryChanged);
    _notifyTimer?.cancel();
    _persistTimer?.cancel();
    _activeProcess?.kill();
    unawaited(_activeSession?.cancel());
    super.dispose();
  }
}

class _OcrCue {
  final Duration start;
  final Duration end;
  final String text;
  const _OcrCue(this.start, this.end, this.text);
}

class _OverlayLineStats {
  final Duration first;
  Duration last;
  int appearances = 0;
  final Set<String> companions = <String>{};

  _OverlayLineStats({required this.first, required this.last});
}

class _OcrTrackResult {
  final OcrSubtitleTrack track;
  final List<_OcrCue> cues;
  const _OcrTrackResult(this.track, this.cues);
}

class _OcrJobCancelled implements Exception {
  const _OcrJobCancelled();
}

/// Keeps visible progress monotonic and calibrates ETA from completed chunks
/// instead of extrapolating from the first few frames of a chunk.
@visibleForTesting
class OcrTaskProgressTracker {
  static const double processingEnd = 0.97;

  final int totalMs;
  final double processingStart;
  late int _lastPublishedPercent;
  double? _mediaMsPerWallMs;
  int _cumulativeMediaMs = 0;
  int _cumulativeWallMs = 0;
  Duration? remaining;

  OcrTaskProgressTracker({required this.totalMs, this.processingStart = 0.08})
    : assert(totalMs > 0) {
    _lastPublishedPercent = (processingStart * 100).floor() - 1;
  }

  double progressFor(int completedMs) {
    final fraction = completedMs.clamp(0, totalMs) / totalMs;
    return processingStart + fraction * (processingEnd - processingStart);
  }

  bool shouldPublish(int completedMs) {
    final percent = (progressFor(completedMs) * 100).floor();
    if (percent <= _lastPublishedPercent) return false;
    _lastPublishedPercent = percent;
    return true;
  }

  Duration calibrateChunk({
    required int chunkMediaMs,
    required int wallMs,
    required int completedMs,
  }) {
    final sampleRate = math.max(1, chunkMediaMs) / math.max(1, wallMs);
    _cumulativeMediaMs += math.max(1, chunkMediaMs);
    _cumulativeWallMs += math.max(1, wallMs);
    _mediaMsPerWallMs = _mediaMsPerWallMs == null
        ? sampleRate
        : sampleRate < _mediaMsPerWallMs!
        ? _mediaMsPerWallMs! * 0.3 + sampleRate * 0.7
        : _mediaMsPerWallMs! * 0.85 + sampleRate * 0.15;
    final remainingMediaMs = math.max(0, totalMs - completedMs);
    remaining = Duration(
      milliseconds: (remainingMediaMs / observedRate * 1.15).round(),
    );
    return remaining!;
  }

  double get observedRate {
    final cumulativeRate = _cumulativeMediaMs / math.max(1, _cumulativeWallMs);
    return math.max(
      0.01,
      math.min(_mediaMsPerWallMs ?? cumulativeRate, cumulativeRate),
    );
  }
}

@visibleForTesting
List<int> parseOcrFrameTimes(String logs) =>
    RegExp(r'pts_time:([+-]?(?:\d+(?:\.\d*)?|\.\d+))')
        .allMatches(logs)
        .map((match) {
          final seconds = double.tryParse(match.group(1) ?? '') ?? 0;
          return math.max(0, (seconds * 1000).round());
        })
        .toList(growable: false);

@visibleForTesting
String buildOcrFrameFilter({
  required NormalizedOcrRegion region,
  required bool mirrorHorizontal,
  required bool mirrorVertical,
}) {
  final r = region.normalized();
  return <String>[
    // The editor frame is mirrored before the rectangle is drawn. Apply the
    // same display transform first so the normalized crop remains identical.
    if (mirrorHorizontal) 'hflip',
    if (mirrorVertical) 'vflip',
    'crop=iw*${r.width}:ih*${r.height}:iw*${r.left}:ih*${r.top}',
    'scale=min(640\\,iw):-2:flags=area',
    'fps=10:round=near',
    'setpts=PTS-STARTPTS',
    // Keep the first confirmation frame after a change, discard subsequent
    // near-duplicates, and force at least one frame every ~2 seconds. This
    // avoids JPEG-encoding and Dart-decoding all 10 FPS just to reject them.
    'mpdecimate=max=20:keep=1:hi=768:lo=320:frac=0.10',
    'showinfo',
  ].join(',');
}
