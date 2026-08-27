import 'dart:io';

import 'package:path/path.dart' as p;

import '../utils/subtitle_file_matcher.dart';
import 'settings_service.dart';

class TaskSubtitleStorageService {
  final Directory? _dataRootOverride;

  const TaskSubtitleStorageService({Directory? dataRootOverride})
    : _dataRootOverride = dataRootOverride;

  Future<Directory> dataRoot() async {
    return _dataRootOverride ?? SettingsService().resolveLargeDataRootDir();
  }

  Future<Directory> tasksRoot({bool create = false}) async {
    final root = await dataRoot();
    final directory = Directory(p.join(root.path, 'subtitles', 'tasks'));
    if (create && !await directory.exists()) {
      await directory.create(recursive: true);
    }
    return directory;
  }

  Future<Directory> taskDirectory(String videoId, {bool create = false}) async {
    _validateVideoId(videoId);
    final root = await tasksRoot(create: create);
    final directory = Directory(p.join(root.path, videoId));
    _ensureWithin(root.path, directory.path);
    if (create && !await directory.exists()) {
      await directory.create(recursive: true);
    }
    return directory;
  }

  Future<bool> isTaskOwnedPath(String path, String videoId) async {
    final directory = await taskDirectory(videoId);
    return _samePath(path, directory.path) || p.isWithin(directory.path, path);
  }

  Future<List<File>> listTaskSubtitles(String videoId) async {
    final directory = await taskDirectory(videoId);
    if (!await directory.exists()) return const <File>[];
    final files = <File>[];
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! File) continue;
      final extension = p.extension(entity.path).toLowerCase();
      if (SubtitleFileMatcher.supportedExtensions.contains(extension)) {
        files.add(entity);
      }
    }
    return files;
  }

  Future<String> allocatePath(String videoId, String preferredFileName) async {
    final directory = await taskDirectory(videoId, create: true);
    final safeName = _safeFileName(preferredFileName);
    final extension = p.extension(safeName);
    final stem = p.basenameWithoutExtension(safeName);
    var candidate = p.join(directory.path, safeName);
    var serial = 2;
    while (await File(candidate).exists()) {
      candidate = p.join(directory.path, '$stem.$serial$extension');
      serial++;
    }
    _ensureWithin(directory.path, candidate);
    return candidate;
  }

  Future<String> copyIntoTask(
    String videoId,
    String sourcePath, {
    String? preferredFileName,
  }) async {
    final source = File(sourcePath);
    if (!await source.exists()) {
      throw FileSystemException('字幕源文件不存在', sourcePath);
    }
    final outputPath = await allocatePath(
      videoId,
      preferredFileName ?? p.basename(sourcePath),
    );
    await source.copy(outputPath);
    return outputPath;
  }

  Future<void> deleteTaskDirectory(String videoId) async {
    final root = await tasksRoot();
    final directory = await taskDirectory(videoId);
    _ensureWithin(root.path, directory.path);
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  }

  Future<int> taskDirectorySize(String videoId) async {
    final directory = await taskDirectory(videoId);
    if (!await directory.exists()) return 0;
    var total = 0;
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is File) {
        try {
          total += await entity.length();
        } on FileSystemException {
          // A file may disappear while size calculation is in progress.
        }
      }
    }
    return total;
  }

  void _validateVideoId(String videoId) {
    if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(videoId)) {
      throw ArgumentError.value(videoId, 'videoId', '非法媒体任务 ID');
    }
  }

  String _safeFileName(String value) {
    final baseName = p.basename(value.trim());
    final sanitized = baseName.replaceAll(
      RegExp(r'[<>:"/\\|?*\x00-\x1F]'),
      '_',
    );
    if (sanitized.isEmpty || sanitized == '.' || sanitized == '..') {
      throw ArgumentError.value(value, 'preferredFileName', '非法字幕文件名');
    }
    final extension = p.extension(sanitized).toLowerCase();
    if (!SubtitleFileMatcher.supportedExtensions.contains(extension)) {
      throw ArgumentError.value(value, 'preferredFileName', '不支持的字幕格式');
    }
    return sanitized;
  }

  void _ensureWithin(String root, String candidate) {
    if (!_samePath(root, candidate) && !p.isWithin(root, candidate)) {
      throw StateError('字幕路径越过任务目录边界');
    }
  }

  bool _samePath(String first, String second) {
    final left = p.normalize(p.absolute(first));
    final right = p.normalize(p.absolute(second));
    return Platform.isWindows
        ? left.toLowerCase() == right.toLowerCase()
        : left == right;
  }
}
