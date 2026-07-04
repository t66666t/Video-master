import 'dart:io';
import 'dart:async';
import 'dart:developer' as developer;
import 'package:flutter/foundation.dart';
import 'package:dio/dio.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:video_player_app/models/bilibili_models.dart';
import 'package:video_player_app/models/bilibili_download_task.dart';
import 'package:video_player_app/services/bilibili/bilibili_api_service.dart';
import 'package:video_player_app/utils/subtitle_util.dart';
import 'package:video_player_app/utils/ffmpeg_utils.dart';
import 'package:video_player/video_player.dart'; // Import video_player for validation

class DownloadUrlExpiredException implements Exception {
  final String url;
  final int? statusCode;

  DownloadUrlExpiredException(this.url, {this.statusCode});

  @override
  String toString() => "DownloadUrlExpiredException(statusCode: $statusCode, url: $url)";
}

class DownloadProgressStalledException implements Exception {
  final String url;
  final Duration idleDuration;

  DownloadProgressStalledException(this.url, {required this.idleDuration});

  @override
  String toString() =>
      "DownloadProgressStalledException(idleDuration: ${idleDuration.inSeconds}s, url: $url)";
}

class BilibiliDownloadManager {
  final BilibiliApiService _apiService;

  BilibiliDownloadManager(this._apiService);

  // Static queue for FFmpeg operations
  static Future<void> _lastMergeTask = Future.value();

  Future<String> downloadAndMerge({
    required StreamItem videoStream,
    required StreamItem audioStream,
    required String fileName,
    required String tempArtifactKey,
    required Function(double) onProgress,
    Function(String)? onSpeedUpdate,
    Function(String)? onSizeUpdate,
    Function(DownloadStatus)? onStatusUpdate, // Callback for checking/repairing status
    VoidCallback? onDownloadPhaseFinished, // New callback for releasing download slot
    Function(DownloadPartResumeState?, DownloadPartResumeState?)? onResumeStateChanged,
    BilibiliSubtitle? subtitle,
    DownloadPartResumeState? videoResumeState,
    DownloadPartResumeState? audioResumeState,
    CancelToken? cancelToken,
  }) async {
    final tempDir = await getTemporaryDirectory();
    final sanitizedKey = tempArtifactKey.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    final artifactPrefix = "bbdown_$sanitizedKey";
    final videoPath = videoResumeState?.tempPath.isNotEmpty == true
        ? videoResumeState!.tempPath
        : p.join(tempDir.path, "${artifactPrefix}_video.m4s");
    final audioPath = audioResumeState?.tempPath.isNotEmpty == true
        ? audioResumeState!.tempPath
        : p.join(tempDir.path, "${artifactPrefix}_audio.m4s");
    final subtitlePath = p.join(tempDir.path, "${artifactPrefix}_subtitle.srt");
    final outputPath = p.join(tempDir.path, "${artifactPrefix}_output.mp4");

    if (await File(subtitlePath).exists()) await File(subtitlePath).delete();
    if (await File(outputPath).exists()) await File(outputPath).delete();

    DownloadPartResumeState? currentVideoState = videoResumeState;
    DownloadPartResumeState? currentAudioState = audioResumeState;
    bool mergeSucceeded = false;

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
        onSizeUpdate?.call("${_formatBytes(downloaded)} / ${_formatBytes(totalKnown)}");
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

      currentVideoState = await _downloadStreamWithResume(
        stream: videoStream,
        initialState: currentVideoState,
        filePath: videoPath,
        cancelToken: cancelToken,
        onProgress: (state, speedText) {
          currentVideoState = state;
          if (speedText != null) {
            onSpeedUpdate?.call(speedText);
          }
          emitResumeState();
        },
      );
      emitResumeState();

      if (cancelToken?.isCancelled == true) throw DioException(requestOptions: RequestOptions(path: ''), type: DioExceptionType.cancel);

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
      
      if (cancelToken?.isCancelled == true) throw DioException(requestOptions: RequestOptions(path: ''), type: DioExceptionType.cancel);
      
      if (onSpeedUpdate != null) onSpeedUpdate("正在合成...");
      if (onStatusUpdate != null) onStatusUpdate(DownloadStatus.merging);
      
      // 3. Download & Convert Subtitle (if selected)
      bool hasSubtitle = false;
      if (subtitle != null) {
        try {
          final jsonContent = await _apiService.fetchSubtitleContent(subtitle.url);
          final srtContent = SubtitleUtil.convertJsonToSrt(jsonContent);
          if (srtContent.isNotEmpty) {
            await File(subtitlePath).writeAsString(srtContent);
            hasSubtitle = true;
          }
        } catch (e) {
          developer.log('Subtitle download failed', error: e);
        }
      }
      
      onProgress(0.85); // Downloads done
      
      // Notify download phase finished to release concurrency slot
      if (onDownloadPhaseFinished != null) onDownloadPhaseFinished();
      _throwIfCancelled(cancelToken);

      // 4. Merge with FFmpeg (Serialized)
      await _enqueueMerge(() async {
        developer.log('Starting FFmpeg merge for $fileName...');
        
        int attempts = 0;
        bool success = false;
        String? lastError;

        while (attempts < 2 && !success) {
          attempts++;
          try {
            // Check for HEVC to apply tag fix
            bool isHevc = videoStream.codecs.startsWith('hev1') || 
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
            
            args.addAll(['-movflags', '+faststart', outputPath]);
            
            final returnCode = await _executeFFmpeg(args);

            if (ReturnCode.isSuccess(returnCode)) {
               // Verify output file size
               final file = File(outputPath);
               if (!await file.exists() || await file.length() < 1024) {
                  throw Exception("FFmpeg merge success but output file is invalid (too small or missing)");
               }

               onProgress(1.0);
               
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
                  developer.log('Merge with subtitle failed, trying without subtitle...');
                  
                  // Fallback args (no subtitle)
                  List<String> fallbackArgs = ['-y', '-i', videoPath, '-i', audioPath];
                  if (isHevc) {
                    fallbackArgs.addAll(['-c:v', 'copy', '-tag:v', 'hvc1']);
                  } else {
                     fallbackArgs.addAll(['-c:v', 'copy']);
                  }
                  fallbackArgs.addAll(['-c:a', 'copy', '-strict', 'experimental', '-movflags', '+faststart', outputPath]);

                  final fbReturnCode = await _executeFFmpeg(fallbackArgs);
                  if (ReturnCode.isSuccess(fbReturnCode)) {
                    // Verify output file size for fallback
                    final fbFile = File(outputPath);
                    if (!await fbFile.exists() || await fbFile.length() < 1024) {
                       throw Exception("FFmpeg fallback merge success but output file is invalid");
                    }

                    onProgress(1.0);
                    
                    // Save sidecar subtitle since embedding failed
                    try {
                      final srtOutputPath = "${tempDir.path}/$fileName.srt";
                      await File(subtitlePath).copy(srtOutputPath);
                    } catch (e) {
                      developer.log('Failed to save sidecar subtitle (fallback)', error: e);
                    }
                    success = true;
                    return; 
                  }
               }
               throw Exception("FFmpeg merge failed (Check logs in console)");
             }
          } catch (e) {
            developer.log('Merge attempt $attempts failed', error: e);
            lastError = e.toString();
            if (attempts < 2) {
               // Cleanup output before retry just in case
               if (await File(outputPath).exists()) await File(outputPath).delete();
            }
          }
        }

        if (!success) {
          throw Exception("Merge failed after $attempts attempts: $lastError");
        }
      });
      _throwIfCancelled(cancelToken);
      
      // 5. Verify Playback Compatibility (Checking)
      if (onStatusUpdate != null) onStatusUpdate(DownloadStatus.checking);
      
      final File mergedFile = File(outputPath);
      bool isCompatible = true;
      
      // On Windows, we skip strict compatibility check (VideoPlayerController.initialize).
      // Windows usually supports most codecs via external players, and we don't want to block
      // download with a heavy transcoding process just for in-app playback compatibility.
      // We assume if FFmpeg merge succeeded (exit code 0), file is valid.
      if (!Platform.isWindows) {
         if (onSpeedUpdate != null) onSpeedUpdate("正在检测兼容性...");
         isCompatible = await _verifyVideo(mergedFile);
      } else {
         if (onSpeedUpdate != null) onSpeedUpdate("下载完成");
      }
      _throwIfCancelled(cancelToken);
      
      if (!isCompatible) {
         // 6. Repair if incompatible (Repairing)
         // Only run repair on mobile/non-Windows platforms where compatibility is strict
         if (onStatusUpdate != null) onStatusUpdate(DownloadStatus.repairing);
         if (onSpeedUpdate != null) onSpeedUpdate("修复兼容性中...");
         
         await _repairVideo(mergedFile, onProgress: onProgress);
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
          if (await File(subtitlePath).exists()) await File(subtitlePath).delete();
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
    final downloadedBytes = await file.exists() ? await file.length() : 0;
    final totalBytes =
        initialState?.totalBytes ??
        await _probeStreamTotalBytes(stream: stream, cancelToken: cancelToken);

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
    );
  }

  Future<DownloadPartResumeState> _downloadStreamWithResume({
    required StreamItem stream,
    required String filePath,
    required CancelToken? cancelToken,
    DownloadPartResumeState? initialState,
    required void Function(DownloadPartResumeState state, String? speedText) onProgress,
  }) async {
    const stallTimeout = Duration(seconds: 3);
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
      "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
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
      throw DownloadUrlExpiredException(stream.baseUrl, statusCode: statusCode);
    }

    if (requestResume && statusCode == 416) {
      if (knownTotal != null && existingBytes >= knownTotal) {
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
      return _downloadStreamWithResume(
        stream: stream,
        filePath: filePath,
        cancelToken: cancelToken,
        initialState: null,
        onProgress: onProgress,
      );
    }

    if (statusCode < 200 || statusCode >= 300) {
      throw DioException.badResponse(
        statusCode: statusCode,
        requestOptions: response.requestOptions,
        response: response,
      );
    }

    if (requestResume && statusCode != 206) {
      try {
        await file.delete();
      } catch (_) {}
      return _downloadStreamWithResume(
        stream: stream,
        filePath: filePath,
        cancelToken: cancelToken,
        initialState: null,
        onProgress: onProgress,
      );
    }

    final supportsRange = statusCode == 206 ||
        response.headers.value('accept-ranges')?.toLowerCase().contains('bytes') == true;

    final totalBytes = _resolveTotalBytes(
      headers: response.headers,
      statusCode: statusCode,
      existingBytes: requestResume ? existingBytes : 0,
    );
    final startOffset = requestResume && statusCode == 206 ? existingBytes : 0;

    if (!requestResume && await file.exists()) {
      await file.delete();
    }

    final raf = await file.open(mode: startOffset > 0 ? FileMode.append : FileMode.writeOnly);
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
    };

    // Some Bilibili CDN links reject HEAD or 0-0 range probes even though the
    // real stream GET still works, so probing must never block a fresh download.
    try {
      final headResponse = await _apiService.dio.head(
        stream.baseUrl,
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
        if (total != null) {
          return total;
        }
      }
    } on DioException catch (e) {
      if (e.type == DioExceptionType.cancel) {
        rethrow;
      }
      developer.log('HEAD probe failed, falling back to stream download', error: e);
    }

    try {
      final probeResponse = await _apiService.dio.get<ResponseBody>(
        stream.baseUrl,
        cancelToken: cancelToken,
        options: Options(
          responseType: ResponseType.stream,
          headers: {...baseHeaders, "Range": "bytes=0-0"},
          validateStatus: (_) => true,
        ),
      );

      final probeStatus = probeResponse.statusCode ?? 0;
      try {
        if (probeStatus >= 200 && probeStatus < 300) {
          return _resolveTotalBytes(
            headers: probeResponse.headers,
            statusCode: probeStatus,
            existingBytes: 0,
          );
        }
        developer.log(
          'Range probe unavailable, continue without total size',
          error: 'status=$probeStatus url=${stream.baseUrl}',
        );
        return null;
      } finally {
        try {
          await probeResponse.data?.stream.drain<void>();
        } catch (_) {}
      }
    } on DioException catch (e) {
      if (e.type == DioExceptionType.cancel) {
        rethrow;
      }
      developer.log(
        'Range probe failed, continue without total size',
        error: e,
      );
      return null;
    }
  }

  int? _resolveTotalBytes({
    required Headers headers,
    required int statusCode,
    required int existingBytes,
  }) {
    final contentRange = headers.value('content-range');
    if (contentRange != null) {
      final match = RegExp(r'bytes\s+\d+-\d+/(\d+|\*)', caseSensitive: false).firstMatch(contentRange);
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
      throw DioException(
        requestOptions: RequestOptions(path: ''),
        type: DioExceptionType.cancel,
      );
    }
  }

  // Verify if video can be played by ExoPlayer
  Future<bool> _verifyVideo(File file) async {
    VideoPlayerController? controller;
    try {
      controller = VideoPlayerController.file(file);
      
      // Set a timeout for initialization
      // If it takes too long, or throws, it's bad.
      await controller.initialize().timeout(const Duration(seconds: 5));
      
      // Optional: Check duration > 0
      if (controller.value.duration.inMilliseconds == 0) {
        return false;
      }
      
      return true;
    } catch (e) {
      developer.log('Verification failed for ${file.path}', error: e);
      return false;
    } finally {
      controller?.dispose();
    }
  }

    // Repair video by transcoding to H.264
  Future<void> _repairVideo(File file, {Function(double)? onProgress}) async {
    final tempDir = file.parent;
    final filename = file.uri.pathSegments.last;
    final repairPath = "${tempDir.path}/repaired_$filename";
    
    // Transcode command: Force H.264 (libx264)
    List<String> args = [
      '-y',
      '-i', file.path,
      '-c:v', 'libx264',
      '-preset', 'ultrafast',
      '-crf', '23',
      '-c:a', 'copy',
      repairPath
    ];
    
    developer.log('Starting repair transcoding');

    // Reset progress to 0 for repair phase
    if (onProgress != null) onProgress(0.0);

    // Get duration for progress calculation
    int durationMs = 0;
    try {
       if (Platform.isWindows) {
          // Use ffprobe on Windows
          final ffprobePath = await FFmpegUtils.ffprobePath;
          final result = await Process.run(ffprobePath, [
            '-v', 'error',
            '-show_entries', 'format=duration',
            '-of', 'default=noprint_wrappers=1:nokey=1',
            file.path
          ]).timeout(const Duration(seconds: 10));
          if (result.exitCode == 0) {
             final dStr = result.stdout.toString().trim();
             final d = double.tryParse(dStr) ?? 0.0;
             durationMs = (d * 1000).toInt();
          }
       } else {
          final session = await FFprobeKit.getMediaInformation(file.path);
          final info = session.getMediaInformation();
          if (info != null) {
              final dStr = info.getDuration();
              if (dStr != null) {
                final d = double.tryParse(dStr) ?? 0.0;
                durationMs = (d * 1000).toInt();
              }
          }
       }
    } catch (e) {
       developer.log('Probe duration failed', error: e);
    }
    
    await _enqueueMerge(() async {
      final completer = Completer<void>();

      if (Platform.isWindows) {
         // Windows Process execution
         try {
           // Process.start allows us to monitor it, but parsing progress from stderr is hard
           // For simplicity in this pair programming task, we use run() and skip progress for now
           // or we can implement a simple progress simulation
           final ffmpegPath = await FFmpegUtils.ffmpegPath;
           final process = await Process.start(ffmpegPath, args);
           
           // Consume streams to prevent blocking
           process.stdout.listen((_) {});
           process.stderr.listen((data) {
             // Optional: parse progress
           });
           
           final exitCode = await process.exitCode;
           if (exitCode == 0) {
              if (await File(repairPath).exists()) {
                 await file.delete();
                 await File(repairPath).rename(file.path);
                 completer.complete();
              } else {
                 completer.completeError(Exception("Repair output missing"));
              }
           } else {
              completer.completeError(Exception("Repair failed with exit code $exitCode"));
           }
         } catch (e) {
           completer.completeError(e);
         }
      } else {
        // Mobile execution
        FFmpegKit.executeWithArgumentsAsync(
          args,
          (session) async {
            final returnCode = await session.getReturnCode();
            
            if (ReturnCode.isSuccess(returnCode)) {
              // Replace original with repaired
              if (await File(repairPath).exists()) {
                 await file.delete();
                 await File(repairPath).rename(file.path);
                 completer.complete();
              } else {
                 completer.completeError(Exception("Repair output missing"));
              }
            } else {
              final logs = await session.getAllLogsAsString();
              completer.completeError(Exception("Repair failed: $logs"));
            }
          },
          (log) {},
          (statistics) {
             if (durationMs > 0 && onProgress != null) {
                final time = statistics.getTime();
                final p = (time / durationMs).clamp(0.0, 1.0);
                onProgress(p);
             }
          }
        );
      }

      return completer.future;
    });
  }

  // Helper for executing FFmpeg based on platform
  Future<ReturnCode> _executeFFmpeg(List<String> args) async {
    if (Platform.isWindows) {
       try {
         final ffmpegPath = await FFmpegUtils.ffmpegPath;
         final result = await Process.run(ffmpegPath, args).timeout(const Duration(minutes: 5));
         if (result.exitCode == 0) {
           return ReturnCode(0);
         } else {
           developer.log('FFmpeg Windows Error', error: result.stderr);
           return ReturnCode(1);
         }
       } catch (e) {
         developer.log('Failed to run ffmpeg on Windows', error: e);
         return ReturnCode(1);
       }
    } else {
       // Android/iOS/macOS
       final session = await FFmpegKit.executeWithArguments(args);
       final code = await session.getReturnCode();
       return code ?? ReturnCode(1); // Handle null return code
    }
  }

  // Helper for serial execution
  static Future<T> _enqueueMerge<T>(Future<T> Function() task) {
    final completer = Completer<T>();
    _lastMergeTask = _lastMergeTask.whenComplete(() async {
      try {
        final result = await task();
        completer.complete(result);
      } catch (e) {
        completer.completeError(e);
      }
    });
    return completer.future;
  }
}
