import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../models/video_compose_models.dart';

class VideoComposeTaskStore {
  const VideoComposeTaskStore();

  Future<List<VideoComposeTaskState>> loadTasks() async {
    try {
      final File file = await _taskFile();
      if (!await file.exists()) {
        return const <VideoComposeTaskState>[];
      }
      final String content = await file.readAsString();
      final List<dynamic> list = jsonDecode(content) as List<dynamic>;
      final List<VideoComposeTaskState> tasks = <VideoComposeTaskState>[];
      for (final dynamic item in list) {
        try {
          tasks.add(VideoComposeTaskState.fromJson(item as Map<String, dynamic>));
        } catch (error) {
          debugPrint('Failed to load task: $error');
        }
      }
      return tasks;
    } catch (error) {
      debugPrint('Failed to load compose tasks: $error');
      return const <VideoComposeTaskState>[];
    }
  }

  Future<void> saveTasks(Iterable<VideoComposeTaskState> tasks) async {
    try {
      final File file = await _taskFile();
      final List<Map<String, dynamic>> list =
          tasks.map((VideoComposeTaskState task) => task.toJson()).toList();
      await file.writeAsString(jsonEncode(list));
    } catch (error) {
      debugPrint('Failed to save compose tasks: $error');
    }
  }

  Future<File> _taskFile() async {
    final Directory dir = await getApplicationDocumentsDirectory();
    return File(p.join(dir.path, 'compose_tasks.json'));
  }
}
