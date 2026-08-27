class BilibiliNormalizedInput {
  final String cleanedInput;
  final BilibiliUrlType type;
  final String? id;

  const BilibiliNormalizedInput({
    required this.cleanedInput,
    required this.type,
    required this.id,
  });
}

class BilibiliUrlParser {
  static const String _bvPattern = r'(BV[a-zA-Z0-9]{10})';
  static const String _avPattern = r'(av\d+)';
  static const String _epPattern = r'(ep\d+)';
  static const String _ssPattern = r'(ss\d+)';

  static BilibiliNormalizedInput? normalizeInput(String rawInput) {
    final trimmed = rawInput.trim();
    if (trimmed.isEmpty) {
      return null;
    }

    String cleanedInput = trimmed;
    final linkMatch = RegExp(r'(https?://[^\s]+)').firstMatch(trimmed);
    if (linkMatch != null) {
      cleanedInput = linkMatch.group(0)!;
      cleanedInput = cleanedInput.replaceAll(RegExp(r'[.,!?;:")]*$'), '');
    } else {
      final bvMatch = RegExp(_bvPattern, caseSensitive: false).firstMatch(trimmed);
      if (bvMatch != null) {
        cleanedInput = _normalizeBv(bvMatch.group(0)!);
      } else {
        final ssMatch = RegExp(_ssPattern, caseSensitive: false).firstMatch(trimmed);
        if (ssMatch != null) {
          cleanedInput = ssMatch.group(0)!.toLowerCase();
        } else {
          final epMatch = RegExp(_epPattern, caseSensitive: false).firstMatch(trimmed);
          if (epMatch != null) {
            cleanedInput = epMatch.group(0)!.toLowerCase();
          } else {
            final avMatch = RegExp(_avPattern, caseSensitive: false).firstMatch(trimmed);
            if (avMatch != null) {
              cleanedInput = avMatch.group(0)!.toLowerCase();
            }
          }
        }
      }
    }

    final type = determineType(cleanedInput);
    final id = extractId(cleanedInput, type);
    // A short link does not contain a BV/AV/EP/SS id until its redirect is
    // resolved by BilibiliApiService. Keep it as a valid normalized input so
    // the download service gets a chance to resolve it.
    if (type == BilibiliUrlType.unknown ||
        (type != BilibiliUrlType.shortLink && id == null)) {
      return null;
    }
    return BilibiliNormalizedInput(
      cleanedInput: cleanedInput,
      type: type,
      id: id,
    );
  }

  static BilibiliUrlType determineType(String input) {
    if (input.contains("b23.tv") || input.contains("bili2233.cn")) {
      return BilibiliUrlType.shortLink;
    }
    if (RegExp(_bvPattern).hasMatch(input)) return BilibiliUrlType.videoBv;
    if (RegExp(_avPattern, caseSensitive: false).hasMatch(input)) {
      return BilibiliUrlType.videoAv;
    }
    if (RegExp(_epPattern, caseSensitive: false).hasMatch(input)) {
      return BilibiliUrlType.bangumiEp;
    }
    if (RegExp(_ssPattern, caseSensitive: false).hasMatch(input)) {
      return BilibiliUrlType.bangumiSs;
    }
    
    return BilibiliUrlType.unknown;
  }

  static String? extractId(String input, BilibiliUrlType type) {
    switch (type) {
      case BilibiliUrlType.videoBv:
        final match = RegExp(_bvPattern, caseSensitive: false)
            .firstMatch(input)
            ?.group(1);
        return match == null ? null : _normalizeBv(match);
      case BilibiliUrlType.videoAv:
        return RegExp(
          _avPattern,
          caseSensitive: false,
        ).firstMatch(input)?.group(1)?.toLowerCase();
      case BilibiliUrlType.bangumiEp:
        return RegExp(
          _epPattern,
          caseSensitive: false,
        ).firstMatch(input)?.group(1)?.toLowerCase();
      case BilibiliUrlType.bangumiSs:
        return RegExp(
          _ssPattern,
          caseSensitive: false,
        ).firstMatch(input)?.group(1)?.toLowerCase();
      default:
        return null;
    }
  }

  static String normalizeBvValue(String value) {
    return _normalizeBv(value);
  }

  static String _normalizeBv(String input) {
    if (input.length < 2) {
      return input;
    }
    return 'BV${input.substring(2)}';
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
