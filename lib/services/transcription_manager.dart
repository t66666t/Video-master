import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:ffmpeg_kit_flutter/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter/return_code.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/services/bcut_asr_service.dart';
import 'package:video_player_app/services/library_service.dart';
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
  final BcutAsrService _asrService = BcutAsrService();
  
  // State
  TranscriptionStatus _status = TranscriptionStatus.idle;
  String _statusMessage = "";
  double _progress = 0.0;
  String? _currentVideoPath;
  String? _lastGeneratedSrtPath;
  
  // New fields for tracking consumption and persistence
  bool _isResultConsumed = false;
  String? _currentVideoId;
  LibraryService? _libraryService;
  bool _autoCache = false;

  // Getters
  TranscriptionStatus get status => _status;
  String get statusMessage => _statusMessage;
  double get progress => _progress;
  String? get currentVideoPath => _currentVideoPath;
  String? get lastGeneratedSrtPath => _lastGeneratedSrtPath;
  bool get isResultConsumed => _isResultConsumed;
  
  bool get isProcessing => _status != TranscriptionStatus.idle && 
                           _status != TranscriptionStatus.completed && 
                           _status != TranscriptionStatus.error;

  void markResultConsumed() {
    _isResultConsumed = true;
    notifyListeners();
  }

  // 开始转录
  Future<void> startTranscription(
    String videoPath, {
    String? videoId,
    LibraryService? libraryService,
    bool autoCache = false,
  }) async {
    if (isProcessing) {
      // 如果正在处理同一个视频，忽略；如果是不同视频，提示忙碌
      if (_currentVideoPath == videoPath) return;
      throw Exception("当前已有转录任务正在进行中");
    }
    
    _resetState();
    _currentVideoPath = videoPath;
    _currentVideoId = videoId;
    _libraryService = libraryService;
    _autoCache = autoCache;
    
    _status = TranscriptionStatus.extracting;
    notifyListeners();
    
    String? audioPath;
    try {
      // 1. 提取音频
      _updateStatus(TranscriptionStatus.extracting, "正在从视频提取音频...", 0.0);
      audioPath = await _extractAudio(videoPath);
      
      // 2. 开始转录 (上传 -> 转录)
      _updateStatus(TranscriptionStatus.uploading, "准备上传音频...", 0.1);
      
      final subtitles = await _asrService.transcribeAudio(
        audioPath, 
        onProgress: (p, msg) {
          TranscriptionStatus newStatus = _status;
          if (p < 0.6) {
             newStatus = TranscriptionStatus.uploading;
          } else {
             newStatus = TranscriptionStatus.transcribing;
          }
          _updateStatus(newStatus, msg, p);
        }
      );
      
      // 3. 生成 SRT 文件
      _updateStatus(TranscriptionStatus.transcribing, "正在保存字幕文件...", 0.95);
      final srtContent = _generateSrt(subtitles);
      final srtPath = await _saveSrtFile(videoPath, srtContent);
      
      _lastGeneratedSrtPath = srtPath;
      
      // 4. 自动持久化保存 (解决后台完成后未保存的问题)
      if (_currentVideoId != null && _libraryService != null) {
         try {
           // 获取当前视频项，保留原有的副字幕
           final currentVideo = _libraryService!.getVideo(_currentVideoId!);
           String? existingSecondaryPath = currentVideo?.secondarySubtitlePath;
           bool isSecondaryCached = currentVideo?.isSecondarySubtitleCached ?? false;

           await _libraryService!.updateVideoSubtitles(
             _currentVideoId!, 
             srtPath, 
             _autoCache, 
             secondarySubtitlePath: existingSecondaryPath, // 保留原有副字幕
             isSecondaryCached: isSecondaryCached
           );
           debugPrint("AI字幕已自动保存到库: $_currentVideoId");
         } catch (e) {
           debugPrint("自动保存字幕失败: $e");
         }
      }

      _updateStatus(TranscriptionStatus.completed, "转录完成", 1.0);
      
    } catch (e) {
      _updateStatus(TranscriptionStatus.error, "转录失败: $e", 0.0);
      rethrow;
    } finally {
      // 统一清理临时音频文件
      if (audioPath != null) {
        final audioFile = File(audioPath);
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
  
  void _resetState() {
    _status = TranscriptionStatus.idle;
    _statusMessage = "";
    _progress = 0.0;
    _currentVideoPath = null;
    _lastGeneratedSrtPath = null;
    _isResultConsumed = false;
    _currentVideoId = null;
    _libraryService = null;
  }
  
  void _updateStatus(TranscriptionStatus status, String message, double progress) {
    _status = status;
    _statusMessage = message;
    _progress = progress;
    notifyListeners();
  }
  
  // 获取音频编码格式
  Future<String?> _getAudioCodec(String videoPath) async {
    try {
      if (Platform.isWindows) {
        final ffprobePath = await FFmpegUtils.ffprobePath;
        // ffprobe -v quiet -print_format json -show_streams -select_streams a:0 input
        final result = await Process.run(ffprobePath, [
          '-v', 'quiet',
          '-print_format', 'json',
          '-show_streams',
          '-select_streams', 'a:0',
          videoPath
        ]);
        
        if (result.exitCode == 0) {
           final json = jsonDecode(result.stdout.toString());
           final streams = json['streams'] as List?;
           if (streams != null && streams.isNotEmpty) {
             return streams[0]['codec_name']?.toString().toLowerCase();
           }
        }
      } else {
        // Android/iOS 使用 FFprobeKit
        final session = await FFprobeKit.getMediaInformation(videoPath);
        final info = session.getMediaInformation();
        if (info != null) {
          final streams = info.getStreams();
          for (final stream in streams) {
            if (stream.getType() == "audio") {
               return stream.getCodec()?.toLowerCase();
            }
          }
        }
      }
    } catch (e) {
      debugPrint("获取音频编码失败: $e");
    }
    return null;
  }

  // 提取音频逻辑 (参考旧的 AiTranscriptionService)
  Future<String> _extractAudio(String videoPath) async {
    final tempDir = await getTemporaryDirectory();
    // 使用 .m4a (AAC) 格式
    final audioPath = p.join(tempDir.path, 'temp_audio_${DateTime.now().millisecondsSinceEpoch}.m4a');
    
    // 1. 检测音频编码
    final codec = await _getAudioCodec(videoPath);
    final isAac = codec != null && codec == 'aac';
    
    debugPrint("音频编码: $codec, 是否直接复制: $isAac");

    // 检查是否 Windows，使用 Process.run
    if (Platform.isWindows) {
       final args = [
         '-y',
         '-i', videoPath,
         '-vn',
       ];
       
       if (isAac) {
         // 直接复制流，速度极快
         args.addAll(['-c:a', 'copy']);
       } else {
         // 重新编码
         args.addAll([
           '-c:a', 'aac',
           '-ar', '16000', // 16kHz 对语音识别足够了
           '-ac', '1',     // 单声道即可
           '-b:a', '64k',  // 降低码率
         ]);
       }
       
       args.add(audioPath);
       
       final ffmpegPath = await FFmpegUtils.ffmpegPath;
       final result = await Process.run(ffmpegPath, args);
       
       if (result.exitCode != 0) {
         throw Exception("FFmpeg 提取音频失败 (Windows): ${result.stderr}");
       }
       return audioPath;
    } else {
       // Android/iOS 使用 FFmpegKit
       final StringBuffer cmd = StringBuffer();
       cmd.write('-y -i "$videoPath" -vn ');
       
       if (isAac) {
         cmd.write('-c:a copy ');
       } else {
         cmd.write('-c:a aac -ar 16000 -ac 1 -b:a 64k ');
       }
       
       cmd.write('"$audioPath"');
       
       final session = await FFmpegKit.execute(cmd.toString());
       final returnCode = await session.getReturnCode();
       
       if (ReturnCode.isSuccess(returnCode)) {
         return audioPath;
       } else {
         final logs = await session.getLogs();
         final fullLog = logs.map((l) => l.getMessage()).join('\n');
         throw Exception("FFmpeg 提取音频失败: $fullLog");
       }
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
  Future<String> _saveSrtFile(String videoPath, String srtContent) async {
    try {
      if (srtContent.trim().isEmpty) {
        throw Exception("生成的字幕内容为空");
      }

      // 优先保存到应用私有目录，避免 Android 11+ 权限问题
      final appDocDir = await getApplicationDocumentsDirectory();
      final subDir = Directory(p.join(appDocDir.path, 'subtitles'));
      if (!await subDir.exists()) {
        await subDir.create(recursive: true);
      }
      
      final name = p.basenameWithoutExtension(videoPath);
      final srtPath = p.join(subDir.path, "$name.ai.srt");
      
      await File(srtPath).writeAsString(srtContent);
      debugPrint("AI字幕已保存到私有目录: $srtPath");

      // 自动导出到公共下载目录 (仅 Android)
      if (Platform.isAndroid) {
        try {
          final downloadDir = Directory('/storage/emulated/0/Download');
          if (await downloadDir.exists()) {
             final publicPath = p.join(downloadDir.path, "$name.ai.srt");
             // 如果文件已存在，添加时间戳避免覆盖或混淆? 或者直接覆盖方便用户?
             // 这里选择直接覆盖，或者简单的重命名策略
             await File(srtPath).copy(publicPath);
             debugPrint("AI字幕已自动导出到公共目录: $publicPath");
          }
        } catch (e) {
          debugPrint("自动导出到公共目录失败: $e");
        }
      }

      return srtPath;
    } catch (e) {
      debugPrint("保存字幕到私有目录失败: $e");
      // 如果私有目录也失败，尝试保存到视频目录（作为备选，虽然可能也会失败）
      try {
        final videoFile = File(videoPath);
        final dir = videoFile.parent.path;
        final name = p.basenameWithoutExtension(videoPath);
        final srtPath = p.join(dir, "$name.ai.srt");
        await File(srtPath).writeAsString(srtContent);
        debugPrint("AI字幕已保存到视频目录: $srtPath");
        return srtPath;
      } catch (e2) {
        throw Exception("保存字幕文件失败: $e");
      }
    }
  }
}
