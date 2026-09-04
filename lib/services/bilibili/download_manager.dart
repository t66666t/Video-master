import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:dio/dio.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:ffmpeg_kit_flutter_new/media_information.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:video_player_app/models/bilibili_models.dart';
import 'package:video_player_app/models/bilibili_download_task.dart';
import 'package:video_player_app/models/media_chapter.dart';
import 'package:video_player_app/services/bilibili/bilibili_api_service.dart';
import 'package:video_player_app/services/bilibili/download_integrity.dart';
import 'package:video_player_app/services/bilibili/media_connection_pool.dart';
import 'package:video_player_app/services/bilibili/media_probe_result.dart';
import 'package:video_player_app/services/bilibili/post_process_task_queue.dart';
import 'package:video_player_app/utils/subtitle_util.dart';
import 'package:video_player_app/utils/ffmpeg_utils.dart';
import 'package:video_player/video_player.dart'; // Import video_player for validation

class DownloadUrlExpiredException implements Exception {
  final String url;
  final int? statusCode;

  DownloadUrlExpiredException(this.url, {this.statusCode});

  @override
  String toString() =>
      "DownloadUrlExpiredException(statusCode: $statusCode, url: $url)";
}

class DownloadProgressStalledException implements Exception {
  final String url;
  final Duration idleDuration;

  DownloadProgressStalledException(this.url, {required this.idleDuration});

  @override
  String toString() =>
      "DownloadProgressStalledException(idleDuration: ${idleDuration.inSeconds}s, url: $url)";
}

class _RangeDownloadUnsupportedException implements Exception {
  const _RangeDownloadUnsupportedException(this.message);

  final String message;

  @override
  String toString() => 'RangeDownloadUnsupportedException: $message';
}

class _RestartSequentialDownloadException implements Exception {
  const _RestartSequentialDownloadException();
}

class _ProcessTimeoutSignal {
  const _ProcessTimeoutSignal();
}

class _ProcessCancelledSignal {
  const _ProcessCancelledSignal();
}

class _MediaProbeResult {
  const _MediaProbeResult({required this.duration, required this.videoCodec});

  final Duration duration;
  final String? videoCodec;
}

class BilibiliDownloadManager {
  final BilibiliApiService _apiService;
  final int _rangeMinBytesPerConnection;

  BilibiliDownloadManager(
    this._apiService, {
    int rangeMinBytesPerConnection =
        BilibiliDownloadIntegrity.defaultMinBytesPerConnection,
  }) : assert(rangeMinBytesPerConnection > 0),
       _rangeMinBytesPerConnection = rangeMinBytesPerConnection;

  @visibleForTesting
  Future<DownloadPartResumeState> downloadVideoStreamForTesting({
    required StreamItem stream,
    required String filePath,
    required int maxConnections,
    DownloadPartResumeState? initialState,
    CancelToken? cancelToken,
    void Function(DownloadPartResumeState state, String? speedText)? onProgress,
  }) async {
    final primed = await _primeResumeState(
      stream: stream,
      filePath: filePath,
      initialState: initialState,
      cancelToken: cancelToken,
    );
    return _downloadVideoStreamAdaptive(
      stream: stream,
      filePath: filePath,
      cancelToken: cancelToken,
      maxConnections: maxConnections,
      initialState: primed,
      onProgress: onProgress ?? (_, _) {},
    );
  }

  static final SerialPostProcessQueue _mergeQueue = SerialPostProcessQueue();
  static final SerialPostProcessQueue _repairQueue = SerialPostProcessQueue();
  static final BilibiliMediaConnectionPool _mediaConnectionPool =
      BilibiliMediaConnectionPool(limit: 8);
  static const Duration _mediaStallTimeout = Duration(seconds: 20);
  static const int _maximumRangeRequestRounds = 2;
  static const Duration _mergeTimeout = Duration(minutes: 6);
  static const Duration _mergeQueueWatchdog = Duration(minutes: 8);
  static const Duration _probeTimeout = Duration(seconds: 15);
  static const Duration _compatibilityCheckTimeout = Duration(seconds: 8);
  static const Duration _repairTimeout = Duration(minutes: 45);
  static const Duration _repairQueueWatchdog = Duration(minutes: 50);

  Future<String> downloadAndMerge({
    required StreamItem videoStream,
    required StreamItem audioStream,
    required String fileName,
    required String tempArtifactKey,
    required Function(double) onProgress,
    Function(String)? onSpeedUpdate,
    Function(String)? onSizeUpdate,
    Function(DownloadStatus)?
    onStatusUpdate, // Callback for checking/repairing status
    VoidCallback?
    onDownloadPhaseFinished, // New callback for releasing download slot
    Function(DownloadPartResumeState?, DownloadPartResumeState?)?
    onResumeStateChanged,
    BilibiliSubtitle? subtitle,
    List<MediaChapter> chapters = const <MediaChapter>[],
    DownloadPartResumeState? videoResumeState,
    DownloadPartResumeState? audioResumeState,
    CancelToken? cancelToken,
    int maxVideoConnections = 2,
  }) async {
    final tempDir = await getTemporaryDirectory();
    final sanitizedKey = tempArtifactKey.replaceAll(
      RegExp(r'[^A-Za-z0-9_-]'),
      '_',
    );
    final artifactPrefix = "bbdown_$sanitizedKey";
    final videoPath = videoResumeState?.tempPath.isNotEmpty == true
        ? videoResumeState!.tempPath
        : p.join(tempDir.path, "${artifactPrefix}_video.m4s");
    final audioPath = audioResumeState?.tempPath.isNotEmpty == true
        ? audioResumeState!.tempPath
        : p.join(tempDir.path, "${artifactPrefix}_audio.m4s");
    final subtitlePath = p.join(tempDir.path, "${artifactPrefix}_subtitle.srt");
    final chapterMetadataPath = p.join(
      tempDir.path,
      "${artifactPrefix}_chapters.ffmeta",
    );
    final outputPath = p.join(tempDir.path, "${artifactPrefix}_output.mp4");

    if (await File(subtitlePath).exists()) await File(subtitlePath).delete();
    if (await File(outputPath).exists()) await File(outputPath).delete();

    DownloadPartResumeState? currentVideoState = videoResumeState;
    DownloadPartResumeState? currentAudioState = audioResumeState;
    bool mergeSucceeded = false;
    _MediaProbeResult? mergedProbe;

    void emitResumeState() {
      if (currentVideoState != null || currentAudioState != null) {
        onResumeStateChanged?.call(currentVideoState, currentAudioState);
      }

      final videoDownloaded = currentVideoState?.downloadedBytes ?? 0;
      final audioDownloaded = currentAudioState?.downloadedBytes ?? 0;
      final videoTotal = currentVideoState?.totalBytes;
      final audioTotal = currentAudioState?.totalBytes;

      final totalKnown = (videoTotal ?? 0) + (audioTotal ?? 0);
      if (totalKnown > 0) {
        final downloaded = videoDownloaded + audioDownloaded;
        final phaseProgress = (downloaded / totalKnown).clamp(0.0, 1.0);
        onProgress(phaseProgress * 0.85);
        onSizeUpdate?.call(
          "${_formatBytes(downloaded)} / ${_formatBytes(totalKnown)}",
        );
      }
    }

    try {
      currentVideoState = await _primeResumeState(
        stream: videoStream,
        filePath: videoPath,
        initialState: currentVideoState,
        cancelToken: cancelToken,
      );
      currentAudioState = await _primeResumeState(
        stream: audioStream,
        filePath: audioPath,
        initialState: currentAudioState,
        cancelToken: cancelToken,
      );
      emitResumeState();

      currentVideoState = await _downloadVideoStreamAdaptive(
        stream: videoStream,
        initialState: currentVideoState,
        filePath: videoPath,
        cancelToken: cancelToken,
        maxConnections: maxVideoConnections.clamp(1, 4),
        onProgress: (state, speedText) {
          currentVideoState = state;
          if (speedText != null) {
            onSpeedUpdate?.call(speedText);
          }
          emitResumeState();
        },
      );
      emitResumeState();

      if (cancelToken?.isCancelled == true) {
        throw DioException(
          requestOptions: RequestOptions(path: ''),
          type: DioExceptionType.cancel,
        );
      }

      currentAudioState = await _downloadStreamWithResume(
        stream: audioStream,
        initialState: currentAudioState,
        filePath: audioPath,
        cancelToken: cancelToken,
        onProgress: (state, speedText) {
          currentAudioState = state;
          if (speedText != null) {
            onSpeedUpdate?.call(speedText);
          }
          emitResumeState();
        },
      );
      emitResumeState();

      if (cancelToken?.isCancelled == true) {
        throw DioException(
          requestOptions: RequestOptions(path: ''),
          type: DioExceptionType.cancel,
        );
      }

      if (onSpeedUpdate != null) onSpeedUpdate("正在合成...");
      if (onStatusUpdate != null) onStatusUpdate(DownloadStatus.merging);

      // 3. Download & Convert Subtitle (if selected)
      bool hasSubtitle = false;
      if (subtitle != null) {
        try {
          final jsonContent = await _apiService.fetchSubtitleContent(
            subtitle.url,
          );
          final srtContent = SubtitleUtil.convertJsonToSrt(jsonContent);
          if (srtContent.isNotEmpty) {
            await File(subtitlePath).writeAsString(srtContent);
            hasSubtitle = true;
          }
        } catch (e) {
          developer.log('Subtitle download failed', error: e);
        }
      }

      final hasChapters = chapters.isNotEmpty;
      if (hasChapters) {
        await _writeChapterMetadataFile(chapterMetadataPath, chapters);
      }

      onProgress(0.85); // Downloads done

      // Notify download phase finished to release concurrency slot
      if (onDownloadPhaseFinished != null) onDownloadPhaseFinished();
      _throwIfCancelled(cancelToken);

      // 4. Merge with FFmpeg (Serialized)
      await _enqueueMerge(() async {
        _throwIfCancelled(cancelToken);
        developer.log('Starting FFmpeg merge for $fileName...');

        final sourceVideoProbe = await _probeAndValidateMediaFile(
          File(videoPath),
          label: '视频分片',
          requireVideo: true,
          requireAudio: false,
        );
        final sourceAudioProbe = await _probeAndValidateMediaFile(
          File(audioPath),
          label: '音频分片',
          requireVideo: false,
          requireAudio: true,
        );

        int attempts = 0;
        bool success = false;
        String? lastError;

        while (attempts < 2 && !success) {
          _throwIfCancelled(cancelToken);
          attempts++;
          try {
            // Check for HEVC to apply tag fix
            bool isHevc =
                videoStream.codecs.startsWith('hev1') ||
                videoStream.codecs.startsWith('hvc1') ||
                videoStream.codecs.contains('hevc');

            // Force AVC (H.264) transcoding if it's HEVC to ensure maximum compatibility.
            // Using "libx264" for re-encoding. This is slower but guarantees playback.
            // Or if user prefers "copy", we can try that first.
            // But user asked for "Force MP4 encapsulation" which usually implies compatibility.
            // However, "encapsulation" means container (mp4), which we already do.
            // The issue is the CODEC inside the MP4.
            // If the user says "video encoding parsing failed", maybe re-encoding is too heavy.
            // But simply copying HEVC into MP4 with -tag:v hvc1 SHOULD work on modern Android.
            // If that failed, maybe the video stream itself is corrupted or weirdly sliced (DASH).

            // Let's try one more robust approach:
            // 1. Force MP4 container (already doing).
            // 2. If HEVC, maybe the "hvc1" tag isn't enough for some extractors.
            // 3. User might mean "Force H.264 codec" when they say "use mp4 format to encapsulate" colloquially.
            //    But re-encoding 1080p/4k on mobile is VERY slow.
            // 4. Let's try to act on "Force MP4" by using `-c:v copy` but with stricter standards.
            //    Maybe removing the `-strict experimental` and just using standard flags?

            // Actually, the error `IndexOutOfBoundsException` in `HevcConfig.parseImpl` strongly suggests
            // the `hvcC` atom (configuration record) is malformed or missing in the output MP4.
            // This happens when ffmpeg copies `hev1` stream to `hvc1` container without regenerating the bitstream filter.

            // FIX: Add `-bsf:v hevc_mp4toannexb`? No, that's for TS.
            // For MP4, we usually don't need BSF if source is already MP4/DASH.
            // BUT, Bilibili DASH HEVC is often "hev1".
            // To make it "hvc1" compatible, we might need `-tag:v hvc1`. We did that.

            // Maybe we should just NOT use `-strict experimental`?
            // And ensure we use `-movflags +faststart`.

            // Let's try to remove `tag:v hvc1` and let FFmpeg decide, BUT force `iso4` brand?
            // Or maybe the user literally means "Transcode to H264" so it plays everywhere?
            // "I hope all videos can be forced to use mp4 format to encapsulate." -> This usually means "Make it a standard MP4".
            // If the source is HEVC, a standard MP4 can contain HEVC.

            // Let's try a safer FFmpeg command that regenerates the timing/index completely.
            // Removing `-c:v copy` and using `-c:v libx264` would solve it 100% but is too slow.
            // Let's stick to copy but try to fix the bitstream.

            // Build args list for _executeFFmpeg
            List<String> args = ['-y', '-i', videoPath, '-i', audioPath];
            if (hasSubtitle) {
              args.addAll(['-i', subtitlePath]);
            }
            final chapterInputIndex = hasChapters
                ? (hasSubtitle ? 3 : 2)
                : null;
            if (hasChapters) {
              args.addAll(['-f', 'ffmetadata', '-i', chapterMetadataPath]);
            }

            // Codec args
            if (isHevc) {
              args.addAll(['-c:v', 'copy', '-tag:v', 'hvc1']);
            } else {
              args.addAll(['-c:v', 'copy']);
            }

            args.addAll(['-c:a', 'copy']);

            if (hasSubtitle) {
              args.addAll(['-c:s', 'mov_text']);
            }
            if (chapterInputIndex != null) {
              args.addAll(['-map_chapters', '$chapterInputIndex']);
            }

            args.addAll(['-movflags', '+faststart', outputPath]);

            final returnCode = await _executeFFmpeg(
              args,
              cancelToken: cancelToken,
            );
            _throwIfCancelled(cancelToken);

            if (ReturnCode.isSuccess(returnCode)) {
              // Verify output file size
              final file = File(outputPath);
              if (!await file.exists() || await file.length() < 1024) {
                throw Exception(
                  "FFmpeg merge success but output file is invalid (too small or missing)",
                );
              }

              onProgress(0.97);

              // Save sidecar subtitle if available
              if (hasSubtitle) {
                try {
                  final srtOutputPath = "${tempDir.path}/$fileName.srt";
                  await File(subtitlePath).copy(srtOutputPath);
                } catch (e) {
                  developer.log('Failed to save sidecar subtitle', error: e);
                }
              }
              success = true;
            } else {
              // Fallback: If subtitle merge failed (ffmpeg error), try without subtitle
              if (hasSubtitle) {
                developer.log(
                  'Merge with subtitle failed, trying without subtitle...',
                );

                // Fallback args (no subtitle)
                List<String> fallbackArgs = [
                  '-y',
                  '-i',
                  videoPath,
                  '-i',
                  audioPath,
                ];
                if (hasChapters) {
                  fallbackArgs.addAll([
                    '-f',
                    'ffmetadata',
                    '-i',
                    chapterMetadataPath,
                    '-map_chapters',
                    '2',
                  ]);
                }
                if (isHevc) {
                  fallbackArgs.addAll(['-c:v', 'copy', '-tag:v', 'hvc1']);
                } else {
                  fallbackArgs.addAll(['-c:v', 'copy']);
                }
                fallbackArgs.addAll([
                  '-c:a',
                  'copy',
                  '-strict',
                  'experimental',
                  '-movflags',
                  '+faststart',
                  outputPath,
                ]);

                final fbReturnCode = await _executeFFmpeg(
                  fallbackArgs,
                  cancelToken: cancelToken,
                );
                _throwIfCancelled(cancelToken);
                if (ReturnCode.isSuccess(fbReturnCode)) {
                  // Verify output file size for fallback
                  final fbFile = File(outputPath);
                  if (!await fbFile.exists() || await fbFile.length() < 1024) {
                    throw Exception(
                      "FFmpeg fallback merge success but output file is invalid",
                    );
                  }

                  onProgress(0.97);

                  // Save sidecar subtitle since embedding failed
                  try {
                    final srtOutputPath = "${tempDir.path}/$fileName.srt";
                    await File(subtitlePath).copy(srtOutputPath);
                  } catch (e) {
                    developer.log(
                      'Failed to save sidecar subtitle (fallback)',
                      error: e,
                    );
                  }
                  success = true;
                  continue;
                }
              }
              throw Exception("FFmpeg merge failed (Check logs in console)");
            }
          } on PostProcessTimeoutException {
            rethrow;
          } on DioException catch (error) {
            if (error.type == DioExceptionType.cancel) rethrow;
            developer.log('Merge attempt $attempts failed', error: error);
            lastError = error.toString();
          } catch (e) {
            developer.log('Merge attempt $attempts failed', error: e);
            lastError = e.toString();
            if (attempts < 2) {
              // Cleanup output before retry just in case
              if (await File(outputPath).exists()) {
                await File(outputPath).delete();
              }
            }
          }
        }

        if (!success) {
          throw PostProcessFailureException(
            'FFmpeg 合成',
            '尝试 $attempts 次仍失败：$lastError',
          );
        }
        mergedProbe = await _probeAndValidateMediaFile(
          File(outputPath),
          label: '合成文件',
          requireVideo: true,
          requireAudio: true,
        );
        _validateMergedDuration(
          output: mergedProbe!.duration,
          sourceVideo: sourceVideoProbe.duration,
          sourceAudio: sourceAudioProbe.duration,
        );
        onProgress(1.0);
      });
      _throwIfCancelled(cancelToken);

      // 5. Only initialize a real player for codecs that are known to be
      // platform-sensitive. Normal H.264/AAC MP4 files have already passed
      // ffprobe validation and do not need the expensive decoder check.
      final File mergedFile = File(outputPath);
      bool isCompatible = true;
      final requiresStrictCheck =
          !Platform.isWindows &&
          _requiresStrictCompatibilityCheck(
            sourceCodec: videoStream.codecs,
            outputCodec: mergedProbe?.videoCodec,
          );
      if (requiresStrictCheck) {
        onStatusUpdate?.call(DownloadStatus.checking);
        onSpeedUpdate?.call("正在检测兼容性...");
        isCompatible = await _verifyVideo(mergedFile);
      } else {
        onSpeedUpdate?.call("合成文件校验通过");
      }
      _throwIfCancelled(cancelToken);

      if (!isCompatible) {
        // 6. Repair if incompatible (Repairing)
        onStatusUpdate?.call(DownloadStatus.repairing);
        onSpeedUpdate?.call("修复兼容性中（不阻塞后续合成）...");
        try {
          await _repairVideo(
            mergedFile,
            onProgress: onProgress,
            cancelToken: cancelToken,
          );
        } on PostProcessTimeoutException {
          rethrow;
        } on DownloadIntegrityException {
          rethrow;
        } catch (error) {
          throw PostProcessFailureException('兼容性修复', error.toString());
        }
      }
      _throwIfCancelled(cancelToken);
      mergeSucceeded = true;

      return outputPath;
    } catch (e) {
      developer.log('Download error', error: e);
      rethrow;
    } finally {
      if (mergeSucceeded) {
        try {
          if (await File(videoPath).exists()) await File(videoPath).delete();
        } catch (_) {}
        try {
          if (await File(audioPath).exists()) await File(audioPath).delete();
        } catch (_) {}
      }
      try {
        if (await File(subtitlePath).exists()) {
          await File(subtitlePath).delete();
        }
      } catch (_) {}
      try {
        if (await File(chapterMetadataPath).exists()) {
          await File(chapterMetadataPath).delete();
        }
      } catch (_) {}
    }
  }

  Future<DownloadPartResumeState> _primeResumeState({
    required StreamItem stream,
    required String filePath,
    required CancelToken? cancelToken,
    DownloadPartResumeState? initialState,
  }) async {
    final file = File(filePath);
    final fileExists = await file.exists();
    var fileLength = fileExists ? await file.length() : 0;
    final totalBytes =
        initialState?.totalBytes ??
        await _probeStreamTotalBytes(stream: stream, cancelToken: cancelToken);

    var rangeParts = const <DownloadRangePartState>[];
    if (initialState?.rangeParts.isNotEmpty == true) {
      final hasValidPlan =
          totalBytes != null &&
          BilibiliDownloadIntegrity.isValidRangePlan(
            initialState!.rangeParts,
            totalBytes: totalBytes,
          );
      if (hasValidPlan) {
        final recovered = <DownloadRangePartState>[];
        for (final part in initialState.rangeParts) {
          final partPath = _rangePartPath(filePath, part);
          final partFile = File(partPath);
          var actualBytes = await partFile.exists()
              ? await partFile.length()
              : 0;
          if (actualBytes > part.length) {
            await partFile.delete();
            actualBytes = 0;
          }
          recovered.add(
            part.copyWith(downloadedBytes: actualBytes, tempPath: partPath),
          );
        }
        final recoveredBytes = recovered.fold<int>(
          0,
          (sum, part) => sum + part.downloadedBytes,
        );
        final assemblyHadCompleted =
            fileExists &&
            fileLength == totalBytes &&
            initialState.rangeParts.every((part) => part.isComplete) &&
            recoveredBytes == 0;
        if (assemblyHadCompleted) {
          // The app may have stopped after the atomic rename and part cleanup,
          // but before the final non-segmented state was persisted.
          rangeParts = const <DownloadRangePartState>[];
        } else {
          rangeParts = List<DownloadRangePartState>.unmodifiable(recovered);
          // The final path may contain an interrupted assembly. Range-part
          // files remain the source of truth until assembly completes.
          fileLength = 0;
        }
      } else {
        await _deleteRangePartFiles(
          initialState!.rangeParts.map(
            (part) => part.copyWith(tempPath: _rangePartPath(filePath, part)),
          ),
        );
        if (fileExists) {
          await file.delete();
        }
        fileLength = 0;
      }
    }
    final downloadedBytes = rangeParts.isNotEmpty
        ? rangeParts.fold<int>(0, (sum, part) => sum + part.downloadedBytes)
        : fileLength;

    return DownloadPartResumeState(
      tempPath: filePath,
      url: initialState?.url ?? stream.baseUrl,
      downloadedBytes: downloadedBytes,
      totalBytes: totalBytes,
      streamId: stream.id,
      codecid: stream.codecid,
      codecs: stream.codecs,
      mimeType: stream.mimeType,
      supportsRange: initialState?.supportsRange ?? false,
      rangeParts: rangeParts,
    );
  }

  Future<DownloadPartResumeState> _downloadVideoStreamAdaptive({
    required StreamItem stream,
    required String filePath,
    required CancelToken? cancelToken,
    required int maxConnections,
    DownloadPartResumeState? initialState,
    required void Function(DownloadPartResumeState state, String? speedText)
    onProgress,
  }) async {
    final totalBytes = initialState?.totalBytes;
    if (maxConnections <= 1 ||
        totalBytes == null ||
        totalBytes <= 0 ||
        (initialState?.rangeParts.isEmpty == true &&
            (initialState?.downloadedBytes ?? 0) > 0)) {
      return _downloadStreamWithResume(
        stream: stream,
        filePath: filePath,
        cancelToken: cancelToken,
        initialState: initialState,
        onProgress: onProgress,
      );
    }

    final persistedParts = initialState?.rangeParts ?? const [];
    final hasPersistedPlan =
        persistedParts.isNotEmpty &&
        BilibiliDownloadIntegrity.isValidRangePlan(
          persistedParts,
          totalBytes: totalBytes,
        );
    final rawParts = hasPersistedPlan
        ? List<DownloadRangePartState>.from(persistedParts)
        : BilibiliDownloadIntegrity.createRangePlan(
            totalBytes: totalBytes,
            requestedConnections: maxConnections,
            minBytesPerConnection: _rangeMinBytesPerConnection,
          );
    final parts = rawParts
        .map(
          (part) => part.copyWith(
            tempPath: part.tempPath?.isNotEmpty == true
                ? part.tempPath
                : _rangePartPath(filePath, part),
          ),
        )
        .toList(growable: false);

    // Small files do not benefit enough to justify another HTTP request. A
    // persisted one-part range plan is still resumed through the range engine.
    if (parts.length < 2 && !hasPersistedPlan) {
      return _downloadStreamWithResume(
        stream: stream,
        filePath: filePath,
        cancelToken: cancelToken,
        initialState: initialState,
        onProgress: onProgress,
      );
    }

    try {
      return await _downloadRangePlan(
        stream: stream,
        filePath: filePath,
        totalBytes: totalBytes,
        parts: parts,
        maxConnections: maxConnections,
        cancelToken: cancelToken,
        onProgress: onProgress,
      );
    } on _RangeDownloadUnsupportedException catch (error) {
      developer.log(
        'Bilibili CDN rejected byte ranges; falling back to one connection',
        error: error,
      );
      _throwIfCancelled(cancelToken);
      await _deleteRangePartFiles(parts);
      final file = File(filePath);
      if (await file.exists()) await file.delete();
      final resetState = DownloadPartResumeState(
        tempPath: filePath,
        url: stream.baseUrl,
        downloadedBytes: 0,
        totalBytes: totalBytes,
        streamId: stream.id,
        codecid: stream.codecid,
        codecs: stream.codecs,
        mimeType: stream.mimeType,
      );
      onProgress(resetState, null);
      return _downloadStreamWithResume(
        stream: stream,
        filePath: filePath,
        cancelToken: cancelToken,
        initialState: resetState,
        onProgress: onProgress,
      );
    }
  }

  Future<DownloadPartResumeState> _downloadRangePlan({
    required StreamItem stream,
    required String filePath,
    required int totalBytes,
    required List<DownloadRangePartState> parts,
    required int maxConnections,
    required CancelToken? cancelToken,
    required void Function(DownloadPartResumeState state, String? speedText)
    onProgress,
  }) async {
    if (!BilibiliDownloadIntegrity.isValidRangePlan(
      parts,
      totalBytes: totalBytes,
    )) {
      throw const DownloadIntegrityException('并行下载分片状态无效');
    }

    final workingParts = List<DownloadRangePartState>.from(parts);
    await File(filePath).parent.create(recursive: true);
    var lastSpeedBytes = workingParts.fold<int>(
      0,
      (sum, part) => sum + part.downloadedBytes,
    );
    var lastSpeedAt = DateTime.now();

    DownloadPartResumeState buildState() {
      final downloaded = workingParts.fold<int>(
        0,
        (sum, part) => sum + part.downloadedBytes,
      );
      return DownloadPartResumeState(
        tempPath: filePath,
        url: stream.baseUrl,
        downloadedBytes: downloaded,
        totalBytes: totalBytes,
        streamId: stream.id,
        codecid: stream.codecid,
        codecs: stream.codecs,
        mimeType: stream.mimeType,
        supportsRange: true,
        rangeParts: List<DownloadRangePartState>.unmodifiable(workingParts),
      );
    }

    void emitProgress({bool force = false}) {
      final state = buildState();
      final now = DateTime.now();
      final elapsedMs = now.difference(lastSpeedAt).inMilliseconds;
      String? speedText;
      if (elapsedMs >= 500 || force) {
        if (elapsedMs > 0) {
          final delta = state.downloadedBytes - lastSpeedBytes;
          final speed = (delta / 1024 / 1024) / (elapsedMs / 1000);
          speedText = '${math.max(0, speed).toStringAsFixed(1)} MB/s';
        }
        lastSpeedBytes = state.downloadedBytes;
        lastSpeedAt = now;
      }
      onProgress(state, speedText);
    }

    emitProgress();
    var concurrency = math.min(maxConnections.clamp(1, 4), workingParts.length);
    while (true) {
      _throwIfCancelled(cancelToken);
      try {
        await _runRangeWorkers(
          stream: stream,
          totalBytes: totalBytes,
          parts: workingParts,
          concurrency: concurrency,
          cancelToken: cancelToken,
          onPartProgress: (index, downloadedBytes) {
            final current = workingParts[index];
            if (downloadedBytes < current.downloadedBytes ||
                downloadedBytes > current.length) {
              throw const DownloadIntegrityException('并行下载分片进度越界');
            }
            workingParts[index] = current.copyWith(
              downloadedBytes: downloadedBytes,
            );
            emitProgress();
          },
        );
        break;
      } catch (error) {
        if (error is _RangeDownloadUnsupportedException ||
            error is DownloadUrlExpiredException ||
            !_isRetryableMediaError(error) ||
            concurrency <= 1) {
          rethrow;
        }
        concurrency = math.max(1, concurrency ~/ 2);
        developer.log(
          'Parallel Bilibili download failed; retrying with $concurrency connection(s)',
          error: error,
        );
        final retryAfter = _retryAfterForMediaError(error);
        final adaptiveDelay = Duration(
          milliseconds: 500 * (maxConnections - concurrency + 1),
        );
        await _waitForMediaRetry(
          retryAfter > adaptiveDelay ? retryAfter : adaptiveDelay,
          cancelToken,
        );
      }
    }

    if (workingParts.any((part) => !part.isComplete)) {
      throw const DownloadIntegrityException('并行下载结束时仍有未完成分片');
    }
    await _assembleRangeParts(
      filePath: filePath,
      parts: workingParts,
      totalBytes: totalBytes,
      cancelToken: cancelToken,
    );
    final finalState = DownloadPartResumeState(
      tempPath: filePath,
      url: stream.baseUrl,
      downloadedBytes: totalBytes,
      totalBytes: totalBytes,
      streamId: stream.id,
      codecid: stream.codecid,
      codecs: stream.codecs,
      mimeType: stream.mimeType,
      supportsRange: true,
    );
    onProgress(finalState, null);
    return finalState;
  }

  Future<void> _runRangeWorkers({
    required StreamItem stream,
    required int totalBytes,
    required List<DownloadRangePartState> parts,
    required int concurrency,
    required CancelToken? cancelToken,
    required void Function(int index, int downloadedBytes) onPartProgress,
  }) async {
    final pendingIndexes = <int>[
      for (var index = 0; index < parts.length; index++)
        if (!parts[index].isComplete) index,
    ];
    if (pendingIndexes.isEmpty) return;

    var cursor = 0;
    Object? firstError;
    StackTrace? firstStack;

    Future<void> worker() async {
      while (firstError == null) {
        _throwIfCancelled(cancelToken);
        if (cursor >= pendingIndexes.length) return;
        final index = pendingIndexes[cursor++];
        try {
          await _downloadRangePartWithFallback(
            stream: stream,
            totalBytes: totalBytes,
            getPart: () => parts[index],
            cancelToken: cancelToken,
            onProgress: (downloadedBytes) {
              onPartProgress(index, downloadedBytes);
            },
          );
        } catch (error, stack) {
          firstError ??= error;
          firstStack ??= stack;
          return;
        }
      }
    }

    final workerCount = math.min(concurrency, pendingIndexes.length);
    await Future.wait<void>([for (var i = 0; i < workerCount; i++) worker()]);
    if (firstError != null) {
      Error.throwWithStackTrace(firstError!, firstStack ?? StackTrace.current);
    }
  }

  Future<void> _downloadRangePartWithFallback({
    required StreamItem stream,
    required int totalBytes,
    required DownloadRangePartState Function() getPart,
    required CancelToken? cancelToken,
    required void Function(int downloadedBytes) onProgress,
  }) async {
    final urls = _candidateMediaUrls(stream);
    Object? lastError;
    StackTrace? lastStack;
    var attempts = 0;
    var unsupportedAttempts = 0;
    var expiredAttempts = 0;
    var rateLimitedAttempts = 0;

    for (var round = 0; round < _maximumRangeRequestRounds; round++) {
      for (final url in urls) {
        _throwIfCancelled(cancelToken);
        if (getPart().isComplete) return;
        attempts++;
        try {
          await _downloadRangePartOnce(
            url: url,
            totalBytes: totalBytes,
            getPart: getPart,
            cancelToken: cancelToken,
            onProgress: onProgress,
          );
          return;
        } on _RangeDownloadUnsupportedException catch (error, stack) {
          unsupportedAttempts++;
          lastError = error;
          lastStack = stack;
        } on DownloadUrlExpiredException catch (error, stack) {
          expiredAttempts++;
          lastError = error;
          lastStack = stack;
        } catch (error, stack) {
          if (!_isRetryableMediaError(error)) rethrow;
          if (_isRateLimitError(error)) rateLimitedAttempts++;
          lastError = error;
          lastStack = stack;
        }
      }
      if (attempts > 0 &&
          (unsupportedAttempts == attempts ||
              expiredAttempts == attempts ||
              rateLimitedAttempts == attempts)) {
        break;
      }
      if (round + 1 < _maximumRangeRequestRounds) {
        await _waitForMediaRetry(
          Duration(milliseconds: 400 * (round + 1)),
          cancelToken,
        );
      }
    }

    if (attempts > 0 && unsupportedAttempts == attempts) {
      throw _RangeDownloadUnsupportedException(
        'all ${urls.length} CDN URL(s) rejected byte ranges',
      );
    }
    if (attempts > 0 && expiredAttempts == attempts) {
      throw DownloadUrlExpiredException(
        urls.first,
        statusCode: (lastError as DownloadUrlExpiredException?)?.statusCode,
      );
    }
    if (lastError != null) {
      Error.throwWithStackTrace(lastError, lastStack ?? StackTrace.current);
    }
    throw StateError('No Bilibili media URL is available');
  }

  Future<void> _downloadRangePartOnce({
    required String url,
    required int totalBytes,
    required DownloadRangePartState Function() getPart,
    required CancelToken? cancelToken,
    required void Function(int downloadedBytes) onProgress,
  }) async {
    final initialPart = getPart();
    if (initialPart.isComplete) return;
    final partPath = initialPart.tempPath;
    if (partPath == null || partPath.isEmpty) {
      throw const DownloadIntegrityException('并行下载分片缺少临时路径');
    }
    final partFile = File(partPath);
    await partFile.parent.create(recursive: true);
    final actualBytes = await partFile.exists() ? await partFile.length() : 0;
    if (actualBytes != initialPart.downloadedBytes) {
      throw DownloadIntegrityException(
        '并行下载分片状态与文件不一致：$actualBytes/${initialPart.downloadedBytes}',
      );
    }
    final requestStart = initialPart.nextByte;
    final requestEnd = initialPart.endInclusive;
    final permit = await _mediaConnectionPool.acquire(cancelToken: cancelToken);
    try {
      final response = await _apiService.dio.get<ResponseBody>(
        url,
        cancelToken: cancelToken,
        options: Options(
          responseType: ResponseType.stream,
          headers: <String, dynamic>{
            'Referer': 'https://www.bilibili.com/',
            'User-Agent':
                'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
                'AppleWebKit/537.36 (KHTML, like Gecko) '
                'Chrome/120.0.0.0 Safari/537.36',
            'Accept-Encoding': 'identity',
            'Range': 'bytes=$requestStart-$requestEnd',
          },
          validateStatus: (_) => true,
        ),
      );
      final statusCode = response.statusCode ?? 0;
      if (statusCode == 401 || statusCode == 403 || statusCode == 404) {
        await _discardResponseBody(response.data);
        throw DownloadUrlExpiredException(url, statusCode: statusCode);
      }
      if (statusCode == 200) {
        await _discardResponseBody(response.data);
        throw _RangeDownloadUnsupportedException(
          'server ignored Range bytes=$requestStart-$requestEnd',
        );
      }
      if (statusCode != 206) {
        await _discardResponseBody(response.data);
        throw DioException.badResponse(
          statusCode: statusCode,
          requestOptions: response.requestOptions,
          response: response,
        );
      }
      if (!BilibiliDownloadIntegrity.matchesRequestedRange(
        contentRange: response.headers.value('content-range'),
        start: requestStart,
        endInclusive: requestEnd,
        totalBytes: totalBytes,
      )) {
        await _discardResponseBody(response.data);
        throw _RangeDownloadUnsupportedException(
          'mismatched Content-Range for bytes=$requestStart-$requestEnd',
        );
      }
      final body = response.data;
      if (body == null) {
        throw const DownloadIntegrityException('并行下载响应为空');
      }

      final raf = await partFile.open(mode: FileMode.writeOnlyAppend);
      try {
        await for (final chunk in body.stream.timeout(_mediaStallTimeout)) {
          _throwIfCancelled(cancelToken);
          if (chunk.isEmpty) continue;
          final current = getPart();
          final remaining = current.length - current.downloadedBytes;
          if (remaining <= 0 || chunk.length > remaining) {
            throw const DownloadIntegrityException('CDN 返回的数据超过请求分片边界');
          }
          await raf.writeFrom(chunk);
          onProgress(current.downloadedBytes + chunk.length);
        }
      } on TimeoutException {
        throw DownloadProgressStalledException(
          url,
          idleDuration: _mediaStallTimeout,
        );
      } finally {
        await raf.close();
      }

      if (!getPart().isComplete) {
        throw DownloadIntegrityException(
          'CDN 提前结束分片：${getPart().downloadedBytes}/${getPart().length} bytes',
        );
      }
    } finally {
      permit.release();
    }
  }

  String _rangePartPath(String filePath, DownloadRangePartState part) {
    return '$filePath.range_${part.start}_${part.endInclusive}.part';
  }

  Future<void> _deleteRangePartFiles(
    Iterable<DownloadRangePartState> parts,
  ) async {
    for (final part in parts) {
      final path = part.tempPath;
      if (path == null || path.isEmpty) continue;
      try {
        final file = File(path);
        if (await file.exists()) await file.delete();
      } catch (_) {}
    }
  }

  Future<void> _assembleRangeParts({
    required String filePath,
    required List<DownloadRangePartState> parts,
    required int totalBytes,
    required CancelToken? cancelToken,
  }) async {
    final stagingFile = File('$filePath.assembling');
    if (await stagingFile.exists()) await stagingFile.delete();
    final output = await stagingFile.open(mode: FileMode.writeOnly);
    var writtenBytes = 0;
    try {
      for (final part in parts) {
        _throwIfCancelled(cancelToken);
        final partPath = part.tempPath;
        if (partPath == null || partPath.isEmpty) {
          throw const DownloadIntegrityException('待拼接分片缺少临时路径');
        }
        final partFile = File(partPath);
        final actualLength = await partFile.exists()
            ? await partFile.length()
            : -1;
        if (actualLength != part.length || !part.isComplete) {
          throw DownloadIntegrityException(
            '待拼接分片不完整：$actualLength/${part.length} bytes',
          );
        }
        final input = await partFile.open(mode: FileMode.read);
        try {
          var partWritten = 0;
          const copyChunkSize = 4 * 1024 * 1024;
          while (partWritten < part.length) {
            _throwIfCancelled(cancelToken);
            final chunk = await input.read(
              math.min(copyChunkSize, part.length - partWritten),
            );
            if (chunk.isEmpty) {
              throw const DownloadIntegrityException('拼接分片时意外读到文件结尾');
            }
            await output.writeFrom(chunk);
            partWritten += chunk.length;
            writtenBytes += chunk.length;
            await Future<void>.delayed(Duration.zero);
          }
        } finally {
          await input.close();
        }
      }
      await output.flush();
    } finally {
      await output.close();
    }

    BilibiliDownloadIntegrity.validateCompletedLength(
      label: '视频分片拼接结果',
      actualBytes: writtenBytes,
      expectedBytes: totalBytes,
    );
    final stagingLength = await stagingFile.length();
    BilibiliDownloadIntegrity.validateCompletedLength(
      label: '视频分片拼接文件',
      actualBytes: stagingLength,
      expectedBytes: totalBytes,
    );

    final finalFile = File(filePath);
    if (await finalFile.exists()) await finalFile.delete();
    await stagingFile.rename(filePath);
    await _deleteRangePartFiles(parts);
  }

  List<String> _candidateMediaUrls(StreamItem stream) {
    final seen = <String>{};
    return <String>[
      stream.baseUrl,
      ...stream.backupUrls,
    ].where((url) => url.isNotEmpty && seen.add(url)).toList(growable: false);
  }

  Future<void> _discardResponseBody(ResponseBody? body) async {
    if (body == null) return;
    try {
      final subscription = body.stream.listen((_) {});
      await subscription.cancel();
    } catch (_) {}
  }

  bool _isRetryableMediaError(Object error) {
    if (error is DownloadProgressStalledException ||
        error is DownloadIntegrityException ||
        error is TimeoutException ||
        error is SocketException) {
      return true;
    }
    if (error is! DioException || error.type == DioExceptionType.cancel) {
      return false;
    }
    if (error.type == DioExceptionType.connectionTimeout ||
        error.type == DioExceptionType.receiveTimeout ||
        error.type == DioExceptionType.sendTimeout ||
        error.type == DioExceptionType.connectionError ||
        error.type == DioExceptionType.unknown) {
      return true;
    }
    final status = error.response?.statusCode;
    return status == 408 ||
        status == 412 ||
        status == 416 ||
        status == 429 ||
        (status != null && status >= 500);
  }

  bool _isRateLimitError(Object error) {
    if (error is! DioException) return false;
    final status = error.response?.statusCode;
    return status == 412 || status == 429;
  }

  Duration _retryAfterForMediaError(Object error) {
    if (error is! DioException) return Duration.zero;
    final value = error.response?.headers.value('retry-after')?.trim();
    if (value == null || value.isEmpty) return Duration.zero;
    final seconds = int.tryParse(value);
    if (seconds != null) {
      return Duration(seconds: seconds.clamp(1, 30));
    }
    try {
      final delay = HttpDate.parse(value).difference(DateTime.now().toUtc());
      if (delay <= Duration.zero) return Duration.zero;
      return delay > const Duration(seconds: 30)
          ? const Duration(seconds: 30)
          : delay;
    } catch (_) {
      return Duration.zero;
    }
  }

  Future<void> _waitForMediaRetry(
    Duration delay,
    CancelToken? cancelToken,
  ) async {
    final deadline = DateTime.now().add(delay);
    while (true) {
      _throwIfCancelled(cancelToken);
      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) return;
      await Future.delayed(
        remaining > const Duration(milliseconds: 100)
            ? const Duration(milliseconds: 100)
            : remaining,
      );
    }
  }

  Future<DownloadPartResumeState> _downloadStreamWithResume({
    required StreamItem stream,
    required String filePath,
    required CancelToken? cancelToken,
    DownloadPartResumeState? initialState,
    required void Function(DownloadPartResumeState state, String? speedText)
    onProgress,
  }) async {
    Object? lastError;
    StackTrace? lastStack;
    var latestState = initialState;

    for (final url in _candidateMediaUrls(stream)) {
      var restartCount = 0;
      while (true) {
        _throwIfCancelled(cancelToken);
        final permit = await _mediaConnectionPool.acquire(
          cancelToken: cancelToken,
        );
        try {
          return await _downloadStreamFromSingleUrl(
            stream: _streamWithUrl(stream, url),
            filePath: filePath,
            cancelToken: cancelToken,
            initialState: latestState,
            onProgress: (state, speedText) {
              latestState = state;
              onProgress(state, speedText);
            },
          );
        } on _RestartSequentialDownloadException {
          restartCount++;
          latestState = null;
          if (restartCount > 1) {
            throw const DownloadIntegrityException('CDN 连续返回不一致的断点响应');
          }
          continue;
        } catch (error, stack) {
          if (error is DioException && error.type == DioExceptionType.cancel) {
            rethrow;
          }
          if (error is! DownloadUrlExpiredException &&
              !_isRetryableMediaError(error)) {
            rethrow;
          }
          lastError = error;
          lastStack = stack;
          break;
        } finally {
          permit.release();
        }
      }
    }

    if (lastError != null) {
      Error.throwWithStackTrace(lastError, lastStack ?? StackTrace.current);
    }
    throw StateError('No Bilibili media URL is available');
  }

  StreamItem _streamWithUrl(StreamItem stream, String url) {
    return StreamItem(
      id: stream.id,
      baseUrl: url,
      bandwidth: stream.bandwidth,
      codecs: stream.codecs,
      codecid: stream.codecid,
      mimeType: stream.mimeType,
      qualityName: stream.qualityName,
    );
  }

  Future<DownloadPartResumeState> _downloadStreamFromSingleUrl({
    required StreamItem stream,
    required String filePath,
    required CancelToken? cancelToken,
    DownloadPartResumeState? initialState,
    required void Function(DownloadPartResumeState state, String? speedText)
    onProgress,
  }) async {
    const stallTimeout = _mediaStallTimeout;
    final file = File(filePath);
    await file.parent.create(recursive: true);

    int existingBytes = await file.exists() ? await file.length() : 0;
    int? knownTotal = initialState?.totalBytes;
    if (knownTotal != null && existingBytes > knownTotal) {
      await file.delete();
      existingBytes = 0;
      knownTotal = null;
    }

    final requestResume = existingBytes > 0;
    final headers = <String, dynamic>{
      "Referer": "https://www.bilibili.com/",
      "User-Agent":
          "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
      "Accept-Encoding": "identity",
      if (requestResume) "Range": "bytes=$existingBytes-",
    };

    final response = await _apiService.dio.get<ResponseBody>(
      stream.baseUrl,
      cancelToken: cancelToken,
      options: Options(
        responseType: ResponseType.stream,
        headers: headers,
        validateStatus: (_) => true,
      ),
    );

    final statusCode = response.statusCode ?? 0;
    if (statusCode == 401 || statusCode == 403 || statusCode == 404) {
      await _discardResponseBody(response.data);
      throw DownloadUrlExpiredException(stream.baseUrl, statusCode: statusCode);
    }

    if (requestResume && statusCode == 416) {
      if (knownTotal != null && existingBytes >= knownTotal) {
        await _discardResponseBody(response.data);
        final completed = DownloadPartResumeState(
          tempPath: file.path,
          url: stream.baseUrl,
          downloadedBytes: existingBytes,
          totalBytes: knownTotal,
          streamId: stream.id,
          codecid: stream.codecid,
          codecs: stream.codecs,
          mimeType: stream.mimeType,
          supportsRange: true,
        );
        onProgress(completed, null);
        return completed;
      }
      try {
        await file.delete();
      } catch (_) {}
      await _discardResponseBody(response.data);
      throw const _RestartSequentialDownloadException();
    }

    if (statusCode < 200 || statusCode >= 300) {
      await _discardResponseBody(response.data);
      throw DioException.badResponse(
        statusCode: statusCode,
        requestOptions: response.requestOptions,
        response: response,
      );
    }

    if (requestResume && statusCode == 206) {
      final rangeStart = BilibiliDownloadIntegrity.contentRangeStart(
        response.headers.value('content-range'),
      );
      if (rangeStart != existingBytes) {
        developer.log(
          'Resume range mismatch; restarting part from zero',
          error: 'expected=$existingBytes actual=$rangeStart',
        );
        try {
          final subscription = response.data?.stream.listen((_) {});
          await subscription?.cancel();
        } catch (_) {}
        try {
          await file.delete();
        } catch (_) {}
        throw const _RestartSequentialDownloadException();
      }
    }

    if (requestResume && statusCode != 206) {
      try {
        await file.delete();
      } catch (_) {}
      await _discardResponseBody(response.data);
      throw const _RestartSequentialDownloadException();
    }

    final supportsRange =
        statusCode == 206 ||
        response.headers
                .value('accept-ranges')
                ?.toLowerCase()
                .contains('bytes') ==
            true;

    final totalBytes = _resolveTotalBytes(
      headers: response.headers,
      statusCode: statusCode,
      existingBytes: requestResume ? existingBytes : 0,
    );
    final startOffset = requestResume && statusCode == 206 ? existingBytes : 0;

    if (!requestResume && await file.exists()) {
      await file.delete();
    }

    final raf = await file.open(
      mode: startOffset > 0 ? FileMode.append : FileMode.writeOnly,
    );
    try {
      int downloadedBytes = startOffset;
      int lastReportedBytes = downloadedBytes;
      DateTime lastReportTime = DateTime.now();

      var state = DownloadPartResumeState(
        tempPath: file.path,
        url: stream.baseUrl,
        downloadedBytes: downloadedBytes,
        totalBytes: totalBytes,
        streamId: stream.id,
        codecid: stream.codecid,
        codecs: stream.codecs,
        mimeType: stream.mimeType,
        supportsRange: supportsRange,
      );
      onProgress(state, null);

      try {
        await for (final chunk in response.data!.stream.timeout(stallTimeout)) {
          _throwIfCancelled(cancelToken);
          await raf.writeFrom(chunk);
          downloadedBytes += chunk.length;

          String? speedText;
          final now = DateTime.now();
          final elapsedMs = now.difference(lastReportTime).inMilliseconds;
          if (elapsedMs >= 500) {
            final bytesDelta = downloadedBytes - lastReportedBytes;
            final speed = elapsedMs > 0
                ? (bytesDelta / 1024 / 1024) / (elapsedMs / 1000)
                : 0.0;
            speedText = "${speed.toStringAsFixed(1)} MB/s";
            lastReportedBytes = downloadedBytes;
            lastReportTime = now;
          }

          state = DownloadPartResumeState(
            tempPath: file.path,
            url: stream.baseUrl,
            downloadedBytes: downloadedBytes,
            totalBytes: totalBytes,
            streamId: stream.id,
            codecid: stream.codecid,
            codecs: stream.codecs,
            mimeType: stream.mimeType,
            supportsRange: supportsRange,
          );
          onProgress(state, speedText);
        }
      } on TimeoutException {
        throw DownloadProgressStalledException(
          stream.baseUrl,
          idleDuration: stallTimeout,
        );
      }

      final finalState = DownloadPartResumeState(
        tempPath: file.path,
        url: stream.baseUrl,
        downloadedBytes: downloadedBytes,
        totalBytes: totalBytes,
        streamId: stream.id,
        codecid: stream.codecid,
        codecs: stream.codecs,
        mimeType: stream.mimeType,
        supportsRange: supportsRange,
      );
      BilibiliDownloadIntegrity.validateCompletedLength(
        label: stream.mimeType?.startsWith('audio') == true ? '音频分片' : '视频分片',
        actualBytes: downloadedBytes,
        expectedBytes: totalBytes,
      );
      onProgress(finalState, null);
      return finalState;
    } finally {
      await raf.close();
    }
  }

  Future<int?> _probeStreamTotalBytes({
    required StreamItem stream,
    required CancelToken? cancelToken,
  }) async {
    final baseHeaders = <String, dynamic>{
      "Referer": "https://www.bilibili.com/",
      "User-Agent":
          "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
      "Accept-Encoding": "identity",
    };

    // Some Bilibili CDN links reject HEAD or 0-0 range probes even though the
    // real stream GET still works, so probing must never block a fresh download.
    for (final url in _candidateMediaUrls(stream)) {
      try {
        final permit = await _mediaConnectionPool.acquire(
          cancelToken: cancelToken,
        );
        try {
          final headResponse = await _apiService.dio.head(
            url,
            cancelToken: cancelToken,
            options: Options(headers: baseHeaders, validateStatus: (_) => true),
          );

          final headStatus = headResponse.statusCode ?? 0;
          if (headStatus >= 200 && headStatus < 300) {
            final total = _resolveTotalBytes(
              headers: headResponse.headers,
              statusCode: headStatus,
              existingBytes: 0,
            );
            if (total != null) return total;
          }
        } finally {
          permit.release();
        }
      } on DioException catch (error) {
        if (error.type == DioExceptionType.cancel) rethrow;
        developer.log('Bilibili HEAD probe failed for $url', error: error);
      }

      try {
        final permit = await _mediaConnectionPool.acquire(
          cancelToken: cancelToken,
        );
        try {
          final probeResponse = await _apiService.dio.get<ResponseBody>(
            url,
            cancelToken: cancelToken,
            options: Options(
              responseType: ResponseType.stream,
              headers: {...baseHeaders, "Range": "bytes=0-0"},
              validateStatus: (_) => true,
            ),
          );
          final probeStatus = probeResponse.statusCode ?? 0;
          final total = probeStatus >= 200 && probeStatus < 300
              ? _resolveTotalBytes(
                  headers: probeResponse.headers,
                  statusCode: probeStatus,
                  existingBytes: 0,
                )
              : null;
          // A server that ignores Range may return the complete media body.
          // Cancel it immediately; never drain a potentially multi-gigabyte
          // response merely to inspect its headers.
          await _discardResponseBody(probeResponse.data);
          if (total != null) return total;
        } finally {
          permit.release();
        }
      } on DioException catch (error) {
        if (error.type == DioExceptionType.cancel) rethrow;
        developer.log('Bilibili Range probe failed for $url', error: error);
      }
    }
    return null;
  }

  int? _resolveTotalBytes({
    required Headers headers,
    required int statusCode,
    required int existingBytes,
  }) {
    final contentRange = headers.value('content-range');
    if (contentRange != null) {
      final match = RegExp(
        r'bytes\s+\d+-\d+/(\d+|\*)',
        caseSensitive: false,
      ).firstMatch(contentRange);
      final totalValue = match?.group(1);
      if (totalValue != null && totalValue != '*') {
        return int.tryParse(totalValue);
      }
    }

    final contentLength = int.tryParse(headers.value('content-length') ?? '');
    if (contentLength == null) return null;
    if (statusCode == 206) {
      return existingBytes + contentLength;
    }
    return contentLength;
  }

  String _formatBytes(int bytes) {
    if (bytes >= 1024 * 1024 * 1024) {
      return "${(bytes / 1024 / 1024 / 1024).toStringAsFixed(1)} GB";
    }
    return "${(bytes / 1024 / 1024).toStringAsFixed(1)} MB";
  }

  void _throwIfCancelled(CancelToken? cancelToken) {
    if (cancelToken?.isCancelled == true) {
      throw cancelToken?.cancelError ??
          DioException(
            requestOptions: RequestOptions(path: ''),
            type: DioExceptionType.cancel,
          );
    }
  }

  bool _requiresStrictCompatibilityCheck({
    required String sourceCodec,
    required String? outputCodec,
  }) {
    final codec = (outputCodec ?? sourceCodec).toLowerCase();
    return !(codec.contains('h264') || codec.startsWith('avc1'));
  }

  void _validateMergedDuration({
    required Duration output,
    required Duration sourceVideo,
    required Duration sourceAudio,
  }) {
    final expectedMs = sourceVideo.inMilliseconds;
    final outputMs = output.inMilliseconds;
    final minimumMs = (expectedMs * 0.9).round();
    final longestSourceMs = sourceAudio.inMilliseconds > expectedMs
        ? sourceAudio.inMilliseconds
        : expectedMs;
    final maximumMs = (longestSourceMs * 1.1).round() + 5000;
    if (outputMs < minimumMs || outputMs > maximumMs) {
      throw DownloadIntegrityException(
        '合成文件时长异常：成品 ${outputMs}ms，视频分片 ${expectedMs}ms，'
        '音频分片 ${sourceAudio.inMilliseconds}ms',
      );
    }
  }

  Future<_MediaProbeResult> _probeAndValidateMediaFile(
    File file, {
    required String label,
    required bool requireVideo,
    required bool requireAudio,
  }) async {
    if (!await file.exists()) {
      throw DownloadIntegrityException('$label 不存在');
    }
    final length = await file.length();
    if (length < 1024) {
      throw DownloadIntegrityException('$label 过小：$length bytes');
    }

    final BilibiliMediaProbeResult? probe = Platform.isWindows
        ? await _probeMediaOnWindows(file)
        : _fromMediaInformation(await _probeMediaWithKit(file));
    if (probe == null) {
      throw DownloadIntegrityException('$label 无法解析媒体信息');
    }

    if (requireVideo && !probe.hasVideo) {
      throw DownloadIntegrityException('$label 缺少视频流');
    }
    if (requireAudio && !probe.hasAudio) {
      throw DownloadIntegrityException('$label 缺少音频流');
    }
    return _MediaProbeResult(
      duration: probe.duration,
      videoCodec: probe.videoCodec,
    );
  }

  BilibiliMediaProbeResult? _fromMediaInformation(
    MediaInformation? information,
  ) {
    if (information == null) return null;
    final durationSeconds = double.tryParse(information.getDuration() ?? '');
    if (durationSeconds == null || durationSeconds <= 0) return null;
    final streams = information.getStreams();
    final videoStreams = streams.where((stream) => stream.getType() == 'video');
    return BilibiliMediaProbeResult(
      duration: Duration(milliseconds: (durationSeconds * 1000).round()),
      hasVideo: videoStreams.isNotEmpty,
      hasAudio: streams.any((stream) => stream.getType() == 'audio'),
      videoCodec: videoStreams.isEmpty ? null : videoStreams.first.getCodec(),
    );
  }

  Future<BilibiliMediaProbeResult?> _probeMediaOnWindows(File file) async {
    try {
      final ffprobePath = await FFmpegUtils.ffprobePath;
      final result = await _runProbeProcess(ffprobePath, [
        '-v',
        'error',
        '-print_format',
        'json',
        '-show_format',
        '-show_streams',
        file.path,
      ]);
      if (result.exitCode == 0) {
        final parsed = BilibiliMediaProbeResult.fromFfprobeJson(result.stdout);
        if (parsed != null) return parsed;
      }
      developer.log(
        'Windows ffprobe was unavailable or returned invalid output; '
        'falling back to ffmpeg media-header probing',
        error: result.stderr,
      );
    } catch (error, stack) {
      developer.log(
        'Windows ffprobe could not be started; falling back to ffmpeg',
        error: error,
        stackTrace: stack,
      );
    }

    final ffmpegPath = await FFmpegUtils.ffmpegPath;
    final fallback = await _runProbeProcess(ffmpegPath, [
      '-hide_banner',
      '-i',
      file.path,
    ]);
    return BilibiliMediaProbeResult.fromFfmpegHeader(fallback.stderr);
  }

  Future<({int exitCode, String stdout, String stderr})> _runProbeProcess(
    String executable,
    List<String> arguments,
  ) async {
    final process = await Process.start(executable, arguments);
    final stdoutFuture = process.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .join();
    final stderrFuture = process.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .join();
    try {
      final exitCode = await process.exitCode.timeout(_probeTimeout);
      return (
        exitCode: exitCode,
        stdout: await stdoutFuture,
        stderr: await stderrFuture,
      );
    } on TimeoutException {
      process.kill();
      await _settleProcessOutput(stdoutFuture.then((_) {}), stderrFuture);
      throw const PostProcessTimeoutException('媒体文件校验', _probeTimeout);
    }
  }

  Future<MediaInformation?> _probeMediaWithKit(File file) async {
    final result = Completer<MediaInformation?>();
    final session = await FFprobeKit.getMediaInformationAsync(file.path, (
      completedSession,
    ) {
      if (!result.isCompleted) {
        result.complete(completedSession.getMediaInformation());
      }
    });
    try {
      return await result.future.timeout(_probeTimeout);
    } on TimeoutException {
      try {
        await session.cancel();
      } catch (_) {}
      throw const PostProcessTimeoutException('ffprobe', _probeTimeout);
    }
  }

  // Verify if video can be played by ExoPlayer
  Future<bool> _verifyVideo(File file) async {
    VideoPlayerController? controller;
    try {
      controller = VideoPlayerController.file(file);
      await controller.initialize().timeout(_compatibilityCheckTimeout);

      // Optional: Check duration > 0
      if (controller.value.duration.inMilliseconds == 0) {
        return false;
      }

      return true;
    } catch (e) {
      developer.log('Verification failed for ${file.path}', error: e);
      return false;
    } finally {
      try {
        await controller?.dispose().timeout(const Duration(seconds: 3));
      } catch (e) {
        developer.log('Video verification cleanup failed', error: e);
      }
    }
  }

  // Repair video by transcoding to broadly supported H.264/AAC. The repaired
  // output is validated before it replaces the original merged file.
  Future<void> _repairVideo(
    File file, {
    Function(double)? onProgress,
    CancelToken? cancelToken,
  }) async {
    final tempDir = file.parent;
    final filename = file.uri.pathSegments.last;
    final repairPath = "${tempDir.path}/repaired_$filename";

    final args = <String>[
      '-y',
      '-i',
      file.path,
      '-map',
      '0:v:0',
      '-map',
      '0:a:0?',
      '-map_chapters',
      '0',
      '-c:v',
      'libx264',
      '-preset',
      'ultrafast',
      '-crf',
      '23',
      '-pix_fmt',
      'yuv420p',
      '-c:a',
      'aac',
      '-movflags',
      '+faststart',
      repairPath,
    ];

    developer.log('Starting repair transcoding');
    onProgress?.call(0.0);

    final sourceProbe = await _probeAndValidateMediaFile(
      file,
      label: '待修复文件',
      requireVideo: true,
      requireAudio: true,
    );
    final durationMs = sourceProbe.duration.inMilliseconds;
    final staleRepairFile = File(repairPath);
    if (await staleRepairFile.exists()) {
      await staleRepairFile.delete();
    }

    await _enqueueRepair(() async {
      _throwIfCancelled(cancelToken);
      ReturnCode returnCode;
      if (Platform.isWindows) {
        final ffmpegPath = await FFmpegUtils.ffmpegPath;
        final process = await Process.start(ffmpegPath, args);
        final stdoutDrain = process.stdout.drain<void>();
        final stderrFuture = process.stderr.transform(utf8.decoder).join();
        final outcome = await _waitForOperationOutcome(
          process.exitCode,
          timeout: _repairTimeout,
          cancelToken: cancelToken,
        );
        if (outcome is int) {
          final exitCode = outcome;
          await stdoutDrain;
          final stderr = await stderrFuture;
          if (exitCode != 0) {
            developer.log('FFmpeg repair failed', error: stderr);
          }
          returnCode = ReturnCode(exitCode == 0 ? 0 : 1);
        } else {
          process.kill();
          try {
            await process.exitCode.timeout(const Duration(seconds: 3));
          } catch (_) {}
          await _settleProcessOutput(stdoutDrain, stderrFuture);
          if (outcome is _ProcessCancelledSignal) {
            _throwIfCancelled(cancelToken);
          }
          throw const PostProcessTimeoutException('兼容性修复', _repairTimeout);
        }
      } else {
        final completed = Completer<ReturnCode>();
        final session = await FFmpegKit.executeWithArgumentsAsync(
          args,
          (completedSession) async {
            final code = await completedSession.getReturnCode();
            if (!completed.isCompleted) {
              completed.complete(code ?? ReturnCode(1));
            }
          },
          (log) {},
          (statistics) {
            if (durationMs > 0 && onProgress != null) {
              final progress = (statistics.getTime() / durationMs).clamp(
                0.0,
                0.99,
              );
              onProgress(progress);
            }
          },
        );
        final outcome = await _waitForOperationOutcome(
          completed.future,
          timeout: _repairTimeout,
          cancelToken: cancelToken,
        );
        if (outcome is ReturnCode) {
          returnCode = outcome;
        } else {
          try {
            await session.cancel();
          } catch (_) {}
          if (outcome is _ProcessCancelledSignal) {
            _throwIfCancelled(cancelToken);
          }
          throw const PostProcessTimeoutException('兼容性修复', _repairTimeout);
        }
      }

      if (!ReturnCode.isSuccess(returnCode)) {
        throw const PostProcessFailureException('兼容性修复', 'FFmpeg 返回失败状态');
      }

      final repairedFile = File(repairPath);
      await _probeAndValidateMediaFile(
        repairedFile,
        label: '修复文件',
        requireVideo: true,
        requireAudio: true,
      );
      if (!Platform.isWindows && !await _verifyVideo(repairedFile)) {
        throw const DownloadIntegrityException('修复文件仍无法通过播放器检查');
      }

      await _replaceFileWithValidatedRepair(
        original: file,
        repaired: repairedFile,
      );
      onProgress?.call(1.0);
    });
  }

  Future<void> _writeChapterMetadataFile(
    String outputPath,
    List<MediaChapter> chapters,
  ) async {
    final buffer = StringBuffer(';FFMETADATA1\n');
    for (final chapter in chapters) {
      if (chapter.endMs <= chapter.startMs) continue;
      buffer
        ..writeln('[CHAPTER]')
        ..writeln('TIMEBASE=1/1000')
        ..writeln('START=${chapter.startMs}')
        ..writeln('END=${chapter.endMs}')
        ..writeln('title=${_escapeFfmetadata(chapter.title)}');
    }
    await File(outputPath).writeAsString(buffer.toString(), flush: true);
  }

  String _escapeFfmetadata(String value) {
    return value
        .replaceAll('\\', '\\\\')
        .replaceAll('\n', r'\n')
        .replaceAll('=', r'\=')
        .replaceAll(';', r'\;')
        .replaceAll('#', r'\#');
  }

  Future<void> _replaceFileWithValidatedRepair({
    required File original,
    required File repaired,
  }) async {
    final backup = File('${original.path}.before_repair');
    if (await backup.exists()) {
      await backup.delete();
    }
    await original.rename(backup.path);
    try {
      await repaired.rename(original.path);
    } catch (_) {
      if (!await original.exists() && await backup.exists()) {
        await backup.rename(original.path);
      }
      rethrow;
    }
    try {
      await backup.delete();
    } catch (error) {
      developer.log('Failed to remove repair backup', error: error);
    }
  }

  // Helper for executing FFmpeg based on platform
  Future<ReturnCode> _executeFFmpeg(
    List<String> args, {
    CancelToken? cancelToken,
  }) async {
    _throwIfCancelled(cancelToken);
    if (Platform.isWindows) {
      final ffmpegPath = await FFmpegUtils.ffmpegPath;
      final process = await Process.start(ffmpegPath, args);
      final stdoutDrain = process.stdout.drain<void>();
      final stderrFuture = process.stderr.transform(utf8.decoder).join();
      final outcome = await _waitForOperationOutcome(
        process.exitCode,
        timeout: _mergeTimeout,
        cancelToken: cancelToken,
      );
      if (outcome is int) {
        final exitCode = outcome;
        await stdoutDrain;
        final stderr = await stderrFuture;
        if (exitCode != 0) {
          developer.log('FFmpeg Windows Error', error: stderr);
        }
        return ReturnCode(exitCode == 0 ? 0 : 1);
      } else {
        process.kill();
        try {
          await process.exitCode.timeout(const Duration(seconds: 3));
        } catch (_) {}
        await _settleProcessOutput(stdoutDrain, stderrFuture);
        if (outcome is _ProcessCancelledSignal) {
          _throwIfCancelled(cancelToken);
        }
        throw const PostProcessTimeoutException('FFmpeg 合成', _mergeTimeout);
      }
    }

    final result = Completer<ReturnCode>();
    final session = await FFmpegKit.executeWithArgumentsAsync(args, (
      completedSession,
    ) async {
      final code = await completedSession.getReturnCode();
      if (!result.isCompleted) result.complete(code ?? ReturnCode(1));
    });
    final outcome = await _waitForOperationOutcome(
      result.future,
      timeout: _mergeTimeout,
      cancelToken: cancelToken,
    );
    if (outcome is ReturnCode) return outcome;
    try {
      await session.cancel();
    } catch (_) {}
    if (outcome is _ProcessCancelledSignal) {
      _throwIfCancelled(cancelToken);
    }
    throw const PostProcessTimeoutException('FFmpeg 合成', _mergeTimeout);
  }

  Future<void> _settleProcessOutput(
    Future<void> stdoutDrain,
    Future<String> stderrFuture,
  ) async {
    try {
      await stdoutDrain.timeout(const Duration(seconds: 3));
    } catch (_) {}
    try {
      await stderrFuture.timeout(const Duration(seconds: 3));
    } catch (_) {}
  }

  Future<Object> _waitForOperationOutcome(
    Future<Object> completion, {
    required Duration timeout,
    CancelToken? cancelToken,
  }) {
    final result = Completer<Object>();
    final timer = Timer(timeout, () {
      if (!result.isCompleted) result.complete(const _ProcessTimeoutSignal());
    });
    completion.then(
      (value) {
        if (!result.isCompleted) result.complete(value);
      },
      onError: (Object error, StackTrace stack) {
        if (!result.isCompleted) result.completeError(error, stack);
      },
    );
    if (cancelToken != null) {
      unawaited(
        cancelToken.whenCancel.then((_) {
          if (!result.isCompleted) {
            result.complete(const _ProcessCancelledSignal());
          }
        }),
      );
    }
    return result.future.whenComplete(timer.cancel);
  }

  // Helper for serial execution
  static Future<T> _enqueueMerge<T>(Future<T> Function() task) {
    return _mergeQueue.enqueue(
      task,
      phase: '合成队列',
      timeout: _mergeQueueWatchdog,
    );
  }

  static Future<T> _enqueueRepair<T>(Future<T> Function() task) {
    return _repairQueue.enqueue(
      task,
      phase: '兼容性修复队列',
      timeout: _repairQueueWatchdog,
    );
  }
}
