import 'package:path/path.dart' as p;

enum SubtitlePrefixMatchMode {
  exactOrDelimited,
  startsWith,
  exactOnly;

  static SubtitlePrefixMatchMode fromStorage(String value) {
    return SubtitlePrefixMatchMode.values.firstWhere(
      (mode) => mode.name == value,
      orElse: () => SubtitlePrefixMatchMode.exactOrDelimited,
    );
  }
}

class SubtitleScanRules {
  static const SubtitleScanRules defaults = SubtitleScanRules();

  final SubtitlePrefixMatchMode prefixMatchMode;
  final bool caseSensitive;

  const SubtitleScanRules({
    this.prefixMatchMode = SubtitlePrefixMatchMode.exactOrDelimited,
    this.caseSensitive = false,
  });
}

class SubtitleFileMatcher {
  static const Set<String> supportedExtensions = <String>{
    '.srt',
    '.vtt',
    '.ass',
    '.ssa',
    '.sup',
    '.lrc',
    '.sub',
    '.idx',
    '.scc',
  };

  static final RegExp _metadataSuffix = RegExp(
    r'^(?:[._\-\s\[(].*)?$',
    unicode: true,
  );

  static bool matches({
    required String videoPath,
    required String subtitlePath,
    required SubtitleScanRules rules,
  }) {
    final extension = p.extension(subtitlePath).toLowerCase();
    if (!supportedExtensions.contains(extension)) return false;

    final videoStem = p.basenameWithoutExtension(videoPath);
    final subtitleStem = p.basenameWithoutExtension(subtitlePath);
    final comparedVideo = rules.caseSensitive
        ? videoStem
        : videoStem.toLowerCase();
    final comparedSubtitle = rules.caseSensitive
        ? subtitleStem
        : subtitleStem.toLowerCase();

    if (comparedSubtitle.startsWith('$comparedVideo.stream_')) return false;

    switch (rules.prefixMatchMode) {
      case SubtitlePrefixMatchMode.exactOnly:
        return comparedSubtitle == comparedVideo;
      case SubtitlePrefixMatchMode.startsWith:
        return comparedSubtitle.startsWith(comparedVideo);
      case SubtitlePrefixMatchMode.exactOrDelimited:
        if (!comparedSubtitle.startsWith(comparedVideo)) return false;
        final suffix = comparedSubtitle.substring(comparedVideo.length);
        return _metadataSuffix.hasMatch(suffix);
    }
  }
}
