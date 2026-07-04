import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import '../../models/bilibili_download_task.dart';

/// 后台 Isolate 中执行的 JSON 编码 + 文件写入
Future<void> _saveTaskListToDisk(
    (String, List<Map<String, dynamic>>) args) async {
  final jsonString = jsonEncode(args.$2);
  await File(args.$1).writeAsString(jsonString);
}

/// 后台 Isolate 中执行的 JSON 解析
(String, List<dynamic>) _decodeRawJson((String, String) args) {
  final decoded = jsonDecode(args.$2) as List<dynamic>;
  return (args.$1, decoded);
}

class BilibiliDownloadStateManager {
  static const String _fileName = 'bilibili_download_tasks.json';
  
  static Future<String> _getFilePath() async {
    final directory = await getApplicationDocumentsDirectory();
    return '${directory.path}/$_fileName';
  }

  static Future<void> saveTasks(List<BilibiliDownloadTask> tasks) async {
    try {
      final path = await _getFilePath();
      final List<Map<String, dynamic>> jsonList =
          tasks.map((t) => t.toJson()).toList().cast<Map<String, dynamic>>();
      // 在后台 Isolate 中执行 JSON 编码和文件写入，避免主线程卡顿
      await compute(_saveTaskListToDisk, (path, jsonList));
    } catch (e) {
      debugPrint("Error saving Bilibili download tasks: $e");
    }
  }

  static Future<List<BilibiliDownloadTask>> loadTasks() async {
    try {
      final path = await _getFilePath();
      final file = File(path);
      
      if (!await file.exists()) {
        return [];
      }

      final String jsonString = await file.readAsString();
      if (jsonString.isEmpty) return [];

      // 在后台 Isolate 中执行 JSON 解析
      List<dynamic> jsonList;
      try {
        final result = await compute(_decodeRawJson, (path, jsonString));
        jsonList = result.$2;
      } catch (_) {
        // 后台解析失败时回退到主线程
        jsonList = jsonDecode(jsonString) as List<dynamic>;
      }

      return jsonList.map<BilibiliDownloadTask>((e) {
        final task = BilibiliDownloadTask.fromJson(e);
        // 重启后状态修正：保留任务列表，但将活跃任务标记为已中断
        for (var video in task.videos) {
          for (var ep in video.episodes) {
             if (ep.status == DownloadStatus.downloading ||
                 ep.status == DownloadStatus.merging ||
                 ep.status == DownloadStatus.fetchingInfo ||
                 ep.status == DownloadStatus.checking ||
                 ep.status == DownloadStatus.repairing) {
                if (ep.hasResumeData) {
                  ep.status = DownloadStatus.pending;
                  ep.error = "已暂停";
                  ep.progress = ep.resumableProgress;
                } else {
                  ep.status = DownloadStatus.failed;
                  ep.error = "进程中断";
                }
             } else if (ep.status == DownloadStatus.queued) {
                ep.status = DownloadStatus.pending;
             } else if (ep.hasResumeData) {
                ep.progress = ep.resumableProgress;
             }
          }
        }
        return task;
      }).toList();
    } catch (e) {
      debugPrint("Error loading Bilibili download tasks: $e");
      return [];
    }
  }
}
