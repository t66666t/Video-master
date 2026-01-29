import 'dart:async';
import 'dart:io';
import 'package:ffmpeg_kit_flutter_min_gpl/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_min_gpl/return_code.dart';
import 'package:flutter/foundation.dart';

class FFmpegService {
  // Singleton pattern
  static final FFmpegService _instance = FFmpegService._internal();
  factory FFmpegService() => _instance;
  FFmpegService._internal();

  final List<Function> _queue = [];
  int _activeTasks = 0;
  int _maxConcurrency = 2; // Default, user can change

  void setConcurrency(int count) {
    _maxConcurrency = count;
  }

  /// Adds a merge task to the queue
  Future<void> mergeVideo({
    required String videoPath,
    required String audioPath,
    required String outputPath,
    required Function(double) onProgress, // 0.0 to 1.0 (approx)
    required Function(bool success, String? error) onComplete,
  }) async {
    _queue.add(() async {
      await _executeMerge(videoPath, audioPath, outputPath, onProgress, onComplete);
    });
    _processQueue();
  }

  void _processQueue() {
    if (_activeTasks >= _maxConcurrency || _queue.isEmpty) return;

    final task = _queue.removeAt(0);
    _activeTasks++;
    
    // Run task
    task().then((_) {
      _activeTasks--;
      _processQueue();
    });
  }

  Future<void> _executeMerge(
    String videoPath,
    String audioPath,
    String outputPath,
    Function(double) onProgress,
    Function(bool success, String? error) onComplete,
  ) async {
    if (Platform.isWindows) {
      onComplete(false, "Windows 平台暂不支持 FFmpeg 合并功能");
      return;
    }

    // Check if files exist
    if (!File(videoPath).existsSync() || !File(audioPath).existsSync()) {
      onComplete(false, "源文件缺失");
      return;
    }

    // Ensure output directory exists
    final outputDir = Directory(outputPath.substring(0, outputPath.lastIndexOf(Platform.pathSeparator)));
    if (!await outputDir.exists()) {
      await outputDir.create(recursive: true);
    }
    
    // Delete if output exists
    final outputFile = File(outputPath);
    if (await outputFile.exists()) {
      await outputFile.delete();
    }

    // Command: ffmpeg -i video -i audio -c copy output.mp4
    // -y: overwrite output files
    final command = '-i "$videoPath" -i "$audioPath" -c copy -y "$outputPath"';
    
    debugPrint("FFmpeg Start: $command");

    // We can't easily get percentage progress for "copy" operations because frames aren't re-encoded.
    // However, we can fake it or just set it to 'indeterminate'. 
    // For now, we'll just set 0.5 when running and 1.0 when done.
    onProgress(0.1);

    await FFmpegKit.executeAsync(command, (session) async {
      final returnCode = await session.getReturnCode();
      
      if (ReturnCode.isSuccess(returnCode)) {
        debugPrint("FFmpeg Success");
        onProgress(1.0);
        onComplete(true, null);
      } else {
        final logs = await session.getAllLogsAsString();
        debugPrint("FFmpeg Failed: $logs");
        onComplete(false, "FFmpeg 失败: $logs"); // Simplified error
      }
    }, (log) {
       // Optional: Parse logs for more detailed progress if needed
    }, (statistics) {
       // Optional: Parse stats
       // For copy codec, stats are fast.
       onProgress(0.5); 
    });
  }
}
