class BilibiliUrlParser {
  static const String _bvPattern = r'(BV[a-zA-Z0-9]{10})';
  static const String _avPattern = r'(av\d+)';
  static const String _epPattern = r'(ep\d+)';
  static const String _ssPattern = r'(ss\d+)';
  
  static BilibiliUrlType determineType(String input) {
    if (input.contains("b23.tv") || input.contains("bili2233.cn")) {
      return BilibiliUrlType.shortLink;
    }
    if (RegExp(_bvPattern).hasMatch(input)) return BilibiliUrlType.videoBv;
    if (RegExp(_avPattern, caseSensitive: false).hasMatch(input)) return BilibiliUrlType.videoAv;
    if (RegExp(_epPattern, caseSensitive: false).hasMatch(input)) return BilibiliUrlType.bangumiEp;
    if (RegExp(_ssPattern, caseSensitive: false).hasMatch(input)) return BilibiliUrlType.bangumiSs;
    
    return BilibiliUrlType.unknown;
  }

  static String? extractId(String input, BilibiliUrlType type) {
    switch (type) {
      case BilibiliUrlType.videoBv:
        return RegExp(_bvPattern).firstMatch(input)?.group(1);
      case BilibiliUrlType.videoAv:
        return RegExp(_avPattern, caseSensitive: false).firstMatch(input)?.group(1);
      case BilibiliUrlType.bangumiEp:
        return RegExp(_epPattern, caseSensitive: false).firstMatch(input)?.group(1);
      case BilibiliUrlType.bangumiSs:
        return RegExp(_ssPattern, caseSensitive: false).firstMatch(input)?.group(1);
      default:
        return null;
    }
  }
}

enum BilibiliUrlType {
  videoBv,
  videoAv,
  bangumiEp,
  bangumiSs,
  shortLink,
  unknown
}
