import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:ffmpeg_kit_flutter_min_gpl/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_min_gpl/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_min_gpl/return_code.dart';
import 'package:path/path.dart' as p;

class EmbeddedSubtitleTrack {
  final int index;
  final String title;
  final String language;
  final String codecName;

  EmbeddedSubtitleTrack({
    required this.index,
    required this.title,
    required this.language,
    required this.codecName,
  });
}

class EmbeddedSubtitleService extends ChangeNotifier {
  
  /// 获取视频文件中的内嵌字幕流信息
  Future<List<EmbeddedSubtitleTrack>> getEmbeddedSubtitles(String videoPath) async {
    if (Platform.isWindows) return [];

    List<EmbeddedSubtitleTrack> tracks = [];
    
    try {
      // 优化：使用 executeAsync 配合 Completer，或者直接使用 Future.wait 来避免主线程阻塞
      // FFprobeKit.getMediaInformation 本身是异步的，应该不会阻塞 UI。
      // 但解析大文件元数据可能耗时。
      
      final session = await FFprobeKit.getMediaInformation(videoPath);
      final info = session.getMediaInformation();
      
      if (info == null) {
        debugPrint("FFprobe failed to get media info for $videoPath");
        return [];
      }

      final streams = info.getStreams();
      for (var stream in streams) {
        if (stream.getType() == "subtitle") {
          final props = stream.getAllProperties();
          final index = stream.getIndex();
          
          if (index == null) continue; // Skip if index is missing

          // 尝试获取元数据
          String title = "未知标题";
          String language = "未知语言";
          String codec = stream.getCodec() ?? "unknown";

          if (props != null) {
             if (props['tags'] != null) {
               final tags = props['tags'];
               if (tags['title'] != null) title = tags['title'];
               if (tags['language'] != null) language = tags['language'];
             }
          }
          
          tracks.add(EmbeddedSubtitleTrack(
            index: index,
            title: title,
            language: language,
            codecName: codec,
          ));
        }
      }
    } catch (e) {
      debugPrint("Error probing subtitles: $e");
    }
    
    return tracks;
  }

  /// 提取指定索引的字幕流
  /// 返回提取后的文件路径
  Future<String?> extractSubtitle(String videoPath, int streamIndex, String outputDir, {String? codecName}) async {
    try {
      // 构造输出文件名
      final videoName = p.basenameWithoutExtension(videoPath);
      
      String extension = ".srt";
      String codec = codecName ?? "unknown";

      // 如果未提供 codec，则尝试探测
      if (codec == "unknown") {
        final probeSession = await FFprobeKit.getMediaInformation(videoPath);
        final info = probeSession.getMediaInformation();
        if (info != null) {
          final streams = info.getStreams();
          for (var stream in streams) {
            if (stream.getIndex() == streamIndex) {
              codec = stream.getCodec() ?? "unknown";
              break;
            }
          }
        }
      }
      
      if (codec == "hdmv_pgs_subtitle") {
        extension = ".sup";
      } else if (codec == "dvd_subtitle") {
        // 将 DVD Subtitle 转码为 PGS (.sup) 以便统一解析
        extension = ".sup"; 
      } else if (codec == "ass" || codec == "ssa") {
        extension = ".ass";
      }
      
      final fileName = "$videoName.stream_$streamIndex$extension";
      final outputPath = p.join(outputDir, fileName);
      final outputFile = File(outputPath);

      // 如果文件已存在，直接返回（简单的缓存策略）
      if (await outputFile.exists()) {
        debugPrint("Subtitle already extracted: $outputPath");
        return outputPath;
      }

      // 构造提取命令
      String command;
      if (extension == ".sup") {
        if (codec == "dvd_subtitle") {
           // VobSub -> PGS 转码
           command = "-i \"$videoPath\" -map 0:$streamIndex -c:s hdmv_pgs_subtitle \"$outputPath\"";
        } else {
           // PGS: 直接拷贝流
           command = "-i \"$videoPath\" -map 0:$streamIndex -c:s copy \"$outputPath\"";
        }
      } else if (extension == ".ass") {
         command = "-i \"$videoPath\" -map 0:$streamIndex \"$outputPath\"";
      } else {
         // 默认尝试转 SRT (text)
         command = "-i \"$videoPath\" -map 0:$streamIndex \"$outputPath\"";
      }
      
      debugPrint("Executing FFmpeg: $command");

      // Use execute() synchronously to ensure completion before returning.
      // executeAsync caused race conditions if the user clicked multiple times or if UI updated too fast.
      final syncSession = await FFmpegKit.execute(command);
      final returnCode = await syncSession.getReturnCode();

      if (ReturnCode.isSuccess(returnCode)) {
        return outputPath;
      } else {
        final logs = await syncSession.getAllLogsAsString();
        debugPrint("Extraction failed logs: $logs");
        return null;
      }
    } catch (e) {
      debugPrint("Error extracting subtitle: $e");
      return null;
    }
  }
}
