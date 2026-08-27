import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/subtitle_source_type.dart';
import '../utils/subtitle_file_matcher.dart';

class DiscoveredSubtitleFile {
  final String path;
  final DateTime modifiedAt;
  final int length;
  final int matchQuality;
  final SubtitleSourceType sourceType;

  const DiscoveredSubtitleFile({
    required this.path,
    required this.modifiedAt,
    required this.length,
    required this.matchQuality,
    this.sourceType = SubtitleSourceType.sidecar,
  });
}

class SubtitleDiscoveryService {
  const SubtitleDiscoveryService();

  Future<List<DiscoveredSubtitleFile>> scanVideoDirectory({
    required String videoPath,
    required SubtitleScanRules rules,
  }) async {
    final directory = File(videoPath).parent;
    if (!await directory.exists()) return const <DiscoveredSubtitleFile>[];

    final candidates = <Future<DiscoveredSubtitleFile?>>[];
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! File) continue;
      if (!SubtitleFileMatcher.matches(
        videoPath: videoPath,
        subtitlePath: entity.path,
        rules: rules,
      )) {
        continue;
      }
      candidates.add(_readMetadata(entity, videoPath, rules));
    }

    final entries = (await Future.wait(
      candidates,
    )).whereType<DiscoveredSubtitleFile>().toList();
    entries.sort((first, second) {
      final quality = second.matchQuality.compareTo(first.matchQuality);
      if (quality != 0) return quality;
      final modified = second.modifiedAt.compareTo(first.modifiedAt);
      if (modified != 0) return modified;
      return _pathKey(first.path).compareTo(_pathKey(second.path));
    });
    return entries;
  }

  Future<DiscoveredSubtitleFile?> _readMetadata(
    File file,
    String videoPath,
    SubtitleScanRules rules,
  ) async {
    try {
      final stat = await file.stat();
      return DiscoveredSubtitleFile(
        path: p.normalize(file.path),
        modifiedAt: stat.modified,
        length: stat.size,
        matchQuality: _matchQuality(videoPath, file.path, rules),
      );
    } on FileSystemException {
      return null;
    }
  }

  int _matchQuality(
    String videoPath,
    String subtitlePath,
    SubtitleScanRules rules,
  ) {
    var videoStem = p.basenameWithoutExtension(videoPath);
    var subtitleStem = p.basenameWithoutExtension(subtitlePath);
    if (!rules.caseSensitive) {
      videoStem = videoStem.toLowerCase();
      subtitleStem = subtitleStem.toLowerCase();
    }
    return subtitleStem == videoStem ? 2 : 1;
  }

  String _pathKey(String path) {
    final normalized = p.normalize(path);
    return Platform.isWindows ? normalized.toLowerCase() : normalized;
  }
}
