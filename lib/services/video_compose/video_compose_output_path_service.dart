import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class VideoComposeOutputPathService {
  const VideoComposeOutputPathService();

  Future<void> ensureParentDirectory(String outputPath) async {
    final Directory dir = Directory(p.dirname(outputPath));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
  }

  Future<String> buildOutputPath(String title) async {
    final Directory base = await _resolveDefaultBaseDirectory();
    final Directory outputDir = Directory(p.join(base.path, 'ComposedVideos'));
    if (!await outputDir.exists()) {
      await outputDir.create(recursive: true);
    }
    final String fileName = buildOutputFileName(title);
    return p.join(outputDir.path, fileName);
  }

  String buildOutputFileName(String title) {
    final String safeTitle = title
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    final String baseName = safeTitle.isEmpty ? 'video' : safeTitle;
    return '${baseName}_compose_${DateTime.now().millisecondsSinceEpoch}.mp4';
  }

  Future<Directory> _resolveDefaultBaseDirectory() async {
    if (Platform.isWindows || Platform.isMacOS) {
      return File(Platform.resolvedExecutable).parent;
    }
    if (Platform.isAndroid) {
      final Directory downloadDir = Directory('/storage/emulated/0/Download');
      if (await downloadDir.exists()) {
        return downloadDir;
      }
      return getApplicationDocumentsDirectory();
    }
    return getApplicationDocumentsDirectory();
  }
}
