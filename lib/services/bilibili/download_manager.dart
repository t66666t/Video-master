import 'dart:io';
import 'dart:async';
import 'dart:developer' as developer;
import 'package:flutter/foundation.dart';
import 'package:dio/dio.dart';
import 'package:ffmpeg_kit_flutter_new_min_gpl/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_min_gpl/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new_min_gpl/return_code.dart';
import 'package:path_provider/path_provider.dart';
import 'package:video_player_app/models/bilibili_models.dart';
import 'package:video_player_app/models/bilibili_download_task.dart';
import 'package:video_player_app/services/bilibili/bilibili_api_service.dart';
import 'package:video_player_app/utils/subtitle_util.dart';
import 'package:video_player_app/utils/ffmpeg_utils.dart';
import 'package:video_player/video_player.dart'; // Import video_player for validation

class BilibiliDownloadManager {
  final BilibiliApiService _apiService;

  BilibiliDownloadManager(this._apiService);

  // Static queue for FFmpeg operations
  static Future<void> _lastMergeTask = Future.value();

  Future<String> downloadAndMerge({
    required StreamItem videoStream,
    required StreamItem audioStream,
    required String fileName,
    required Function(double) onProgress,
    Function(String)? onSpeedUpdate,
    Function(String)? onSizeUpdate,
    Function(DownloadStatus)? onStatusUpdate, // Callback for checking/repairing status
    VoidCallback? onDownloadPhaseFinished, // New callback for releasing download slot
    BilibiliSubtitle? subtitle,
    CancelToken? cancelToken,
  }) async {
    final tempDir = await getTemporaryDirectory();
    final uniqueId = DateTime.now().millisecondsSinceEpoch.toString();
    final videoPath = "${tempDir.path}/temp_video_$uniqueId.m4s";
    final audioPath = "${tempDir.path}/temp_audio_$uniqueId.m4s";
    final subtitlePath = "${tempDir.path}/temp_subtitle_$uniqueId.srt";
    final outputPath = "${tempDir.path}/$fileName.mp4";

    // Delete existing temp files
    if (await File(videoPath).exists()) await File(videoPath).delete();
    if (await File(audioPath).exists()) await File(audioPath).delete();
    if (await File(subtitlePath).exists()) await File(subtitlePath).delete();
    if (await File(outputPath).exists()) await File(outputPath).delete();

    try {
      // 1. Download Video
      int lastVideoBytes = 0;
      DateTime lastVideoTime = DateTime.now();
      
      await _apiService.dio.download(
        videoStream.baseUrl,
        videoPath,
        cancelToken: cancelToken,
        onReceiveProgress: (received, total) {
          if (total != -1) {
             // Calculate Speed
             final now = DateTime.now();
             final duration = now.difference(lastVideoTime).inMilliseconds;
             if (duration > 500) { // Update every 500ms
                final bytes = received - lastVideoBytes;
                final speed = (bytes / 1024 / 1024) / (duration / 1000); // MB/s
                if (onSpeedUpdate != null) {
                   onSpeedUpdate("${speed.toStringAsFixed(1)} MB/s");
                }
                lastVideoBytes = received;
                lastVideoTime = now;
             }
             
             // Update Size
             if (onSizeUpdate != null) {
                final currentMB = (received / 1024 / 1024).toStringAsFixed(1);
                final totalMB = (total / 1024 / 1024).toStringAsFixed(1);
                onSizeUpdate("$currentMB MB / $totalMB MB");
             }
             
             // Video is roughly 70% of the work
             onProgress((received / total) * 0.7);
          }
        },
        options: Options(
          responseType: ResponseType.stream,
          headers: {
            "Referer": "https://www.bilibili.com/",
            "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
          }
        ),
      );

      if (cancelToken?.isCancelled == true) throw DioException(requestOptions: RequestOptions(path: ''), type: DioExceptionType.cancel);

      // 2. Download Audio
      await _apiService.dio.download(
        audioStream.baseUrl,
        audioPath,
        cancelToken: cancelToken,
        onReceiveProgress: (received, total) {
           // Audio is quick, maybe skip speed check or reuse
           if (onSpeedUpdate != null && received % 100 == 0) { // Simple update
              // Could implement similar logic but audio is fast
              onSpeedUpdate("正在下载音频...");
           }
        },
        options: Options(
          responseType: ResponseType.stream,
          headers: {
            "Referer": "https://www.bilibili.com/",
            "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
          }
        ),
      );
      
      if (cancelToken?.isCancelled == true) throw DioException(requestOptions: RequestOptions(path: ''), type: DioExceptionType.cancel);
      
      if (onSpeedUpdate != null) onSpeedUpdate("正在合成...");
      
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
      
      if (!isCompatible) {
         // 6. Repair if incompatible (Repairing)
         // Only run repair on mobile/non-Windows platforms where compatibility is strict
         if (onStatusUpdate != null) onStatusUpdate(DownloadStatus.repairing);
         if (onSpeedUpdate != null) onSpeedUpdate("修复兼容性中...");
         
         await _repairVideo(mergedFile, onProgress: onProgress);
      }
      
      return outputPath;

    } catch (e) {
      developer.log('Download error', error: e);
      rethrow;
    } finally {
        // Cleanup temp files
        if (await File(videoPath).exists()) await File(videoPath).delete();
        if (await File(audioPath).exists()) await File(audioPath).delete();
        if (await File(subtitlePath).exists()) await File(subtitlePath).delete();
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
          ]);
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
         final result = await Process.run(ffmpegPath, args);
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
