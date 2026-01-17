import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import '../../models/bilibili_download_task.dart';

class BilibiliDownloadStateManager {
  static const String _fileName = 'bilibili_download_tasks.json';
  
  static Future<String> _getFilePath() async {
    final directory = await getApplicationDocumentsDirectory();
    return '${directory.path}/$_fileName';
  }

  static Future<void> saveTasks(List<BilibiliDownloadTask> tasks) async {
    try {
      final path = await _getFilePath();
      final file = File(path);
      
      final List<Map<String, dynamic>> jsonList = tasks.map((t) => t.toJson()).toList().cast<Map<String, dynamic>>();
      final String jsonString = jsonEncode(jsonList);
      
      await file.writeAsString(jsonString);
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

      final List<dynamic> jsonList = jsonDecode(jsonString);
      return jsonList.map<BilibiliDownloadTask>((e) {
        final task = BilibiliDownloadTask.fromJson(e);
        // Sanitize status: Reset in-progress tasks to failed/pending
        for (var video in task.videos) {
          for (var ep in video.episodes) {
             if (ep.status == DownloadStatus.downloading || 
                 ep.status == DownloadStatus.merging || 
                 ep.status == DownloadStatus.fetchingInfo) {
                ep.status = DownloadStatus.failed;
                ep.error = "Process interrupted";
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
