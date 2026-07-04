import 'dart:math' as math;

import 'package:path/path.dart' as p;

import '../models/media_source_ref.dart';
import '../models/subtitle_model.dart';
import '../models/video_item.dart';

class YouTubeAutoCaptionNormalizer {
  static const Set<String> _autoMarkers = <String>{
    'auto',
    'asr',
    'caption',
    'srv',
    '自动',
  };

  static bool shouldNormalize({
    required List<SubtitleItem> subtitles,
    required String subtitlePath,
    VideoItem? videoItem,
  }) {
    if (subtitles.length < 3) {
      return false;
    }
    if (!_isYtDlpYouTubeVideo(videoItem)) {
      return false;
    }
    if (!_looksLikeManagedSubtitlePath(subtitlePath, videoItem)) {
      return false;
    }
    if (!_hasAutoMarker(subtitlePath)) {
      return false;
    }
    return _looksLikeSlidingWindowAutoCaptions(subtitles);
  }

  static String cacheKey({
    required String subtitlePath,
    required List<SubtitleItem> subtitles,
    VideoItem? videoItem,
  }) {
    final suffix =
        shouldNormalize(
          subtitles: subtitles,
          subtitlePath: subtitlePath,
          videoItem: videoItem,
        )
        ? 'yt_auto'
        : 'plain';
    return '$subtitlePath::$suffix';
  }

  static List<SubtitleItem> normalize(List<SubtitleItem> subtitles) {
    if (subtitles.length < 2) {
      return subtitles;
    }

    final normalized = <SubtitleItem>[];
    for (var i = 0; i < subtitles.length; i++) {
      final current = subtitles[i];
      final currentStartMs = current.startTime.inMilliseconds;
      final currentEndMs = current.endTime.inMilliseconds;
      final nextStartMs = i + 1 < subtitles.length
          ? subtitles[i + 1].startTime.inMilliseconds
          : currentEndMs;
      final cappedEndMs = math.min(currentEndMs, nextStartMs);
      if (cappedEndMs <= currentStartMs) {
        continue;
      }
      normalized.add(
        SubtitleItem(
          index: normalized.length + 1,
          startTime: Duration(milliseconds: currentStartMs),
          endTime: Duration(milliseconds: cappedEndMs),
          text: current.text,
          imageLoader: current.imageLoader,
        ),
      );
    }

    return normalized.isEmpty ? subtitles : normalized;
  }

  static bool _isYtDlpYouTubeVideo(VideoItem? videoItem) {
    if (videoItem == null) {
      return false;
    }
    if (videoItem.isBilibiliExported ||
        !videoItem.usesManagedAssociatedSubtitles) {
      return false;
    }
    final sourceRef = videoItem.sourceRef;
    if (sourceRef == null || sourceRef.kind != MediaSourceKind.url) {
      return false;
    }
    final raw = (sourceRef.originalValue ?? sourceRef.value).trim();
    final uri = Uri.tryParse(raw);
    final host = (uri?.host ?? raw).toLowerCase();
    if (!host.contains('youtube.com') && !host.contains('youtu.be')) {
      return false;
    }
    return true;
  }

  static bool _looksLikeManagedSubtitlePath(
    String subtitlePath,
    VideoItem? videoItem,
  ) {
    final baseName = p.basename(subtitlePath).toLowerCase();
    if (baseName.isEmpty) {
      return false;
    }

    final likelySubtitleExt = p.extension(baseName).toLowerCase();
    const supported = <String>{'.srt', '.vtt', '.ass', '.ssa', '.lrc'};
    if (!supported.contains(likelySubtitleExt)) {
      return false;
    }

    final normalizedPath = subtitlePath.replaceAll('\\', '/').toLowerCase();
    if (!normalizedPath.contains('/subtitles/')) {
      return false;
    }

    if (videoItem == null) {
      return true;
    }

    final candidatePrefixes = <String>{
      videoItem.id.toLowerCase(),
      p.basenameWithoutExtension(videoItem.path).toLowerCase(),
    }..removeWhere((e) => e.trim().isEmpty);

    if (candidatePrefixes.isEmpty) {
      return true;
    }

    for (final prefix in candidatePrefixes) {
      if (baseName.startsWith(prefix)) {
        return true;
      }
    }

    return false;
  }

  static bool _hasAutoMarker(String subtitlePath) {
    final baseName = p.basename(subtitlePath).toLowerCase();
    return _autoMarkers.any((marker) => baseName.contains(marker));
  }

  static bool _looksLikeSlidingWindowAutoCaptions(
    List<SubtitleItem> subtitles,
  ) {
    var overlapCount = 0;
    var sameEndOverlapCount = 0;
    var textPairCount = 0;
    for (var i = 0; i + 1 < subtitles.length; i++) {
      final current = subtitles[i];
      final next = subtitles[i + 1];
      if (current.imageLoader != null || next.imageLoader != null) {
        continue;
      }
      if (current.text.trim().isEmpty || next.text.trim().isEmpty) {
        continue;
      }
      textPairCount += 1;
      final currentStartMs = current.startTime.inMilliseconds;
      final currentEndMs = current.endTime.inMilliseconds;
      final nextStartMs = next.startTime.inMilliseconds;
      final nextEndMs = next.endTime.inMilliseconds;
      if (nextStartMs > currentStartMs && nextStartMs < currentEndMs) {
        overlapCount += 1;
        if (currentEndMs == nextEndMs) {
          sameEndOverlapCount += 1;
        }
      }
    }
    if (overlapCount < 3 || textPairCount < 3) {
      return false;
    }
    if (sameEndOverlapCount >= 2) {
      return true;
    }
    return overlapCount * 4 >= textPairCount;
  }
}
