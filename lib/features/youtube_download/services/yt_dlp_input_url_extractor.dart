class YtDlpInputUrlExtractor {
  const YtDlpInputUrlExtractor._();

  static final RegExp _candidatePattern = RegExp(
    r'''(?<![@\w])(?:[a-z][a-z0-9+.-]*://)?(?:localhost|(?:\d{1,3}\.){3}\d{1,3}|(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63})(?::\d{1,5})?(?:/[^\s<>"'`，。！？、；：【】《》「」『』]*)?(?:\?[^\s<>"'`，。！？、；：【】《》「」『』#]*)?(?:#[^\s<>"'`，。！？、；：【】《》「」『』]*)?''',
    caseSensitive: false,
  );

  static final RegExp _schemePattern = RegExp(
    r'^[a-z][a-z0-9+.-]*://',
    caseSensitive: false,
  );

  static final RegExp _ipv4Pattern = RegExp(
    r'^(?:\d{1,3}\.){3}\d{1,3}$',
  );

  static final RegExp _domainPattern = RegExp(
    r'^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$',
    caseSensitive: false,
  );

  static const Set<String> _leadingNoiseChars = {
    '(',
    '[',
    '{',
    '<',
    '"',
    '\'',
    '`',
    '（',
    '【',
    '《',
    '「',
    '『',
    '〈',
    '〔',
    '“',
    '‘',
  };

  static const Set<String> _trailingNoiseChars = {
    '.',
    ',',
    ';',
    ':',
    '!',
    '?',
    '"',
    '\'',
    '`',
    '。',
    '，',
    '、',
    '；',
    '：',
    '！',
    '？',
    '…',
    '”',
    '’',
  };

  static const Map<String, String> _closingPairs = {
    ')': '(',
    ']': '[',
    '}': '{',
    '>': '<',
    '）': '（',
    '】': '【',
    '》': '《',
    '」': '「',
    '』': '『',
    '〉': '〈',
    '〕': '〔',
  };

  static List<String> extractUrls(String rawInput) {
    if (rawInput.trim().isEmpty) {
      return const [];
    }

    final urls = <String>[];
    final seen = <String>{};
    for (final match in _candidatePattern.allMatches(rawInput)) {
      final candidate = rawInput.substring(match.start, match.end);
      final normalized = _normalizeCandidate(candidate);
      if (normalized == null || !seen.add(normalized)) {
        continue;
      }
      urls.add(normalized);
    }
    return urls;
  }

  static String? _normalizeCandidate(String candidate) {
    var value = candidate.trim();
    if (value.isEmpty) {
      return null;
    }

    value = _trimLeadingNoise(value);
    value = _trimTrailingNoise(value);
    if (value.isEmpty) {
      return null;
    }

    final url = _schemePattern.hasMatch(value) ? value : 'https://$value';
    final uri = Uri.tryParse(url);
    if (uri == null || uri.host.isEmpty || !_isValidHost(uri.host)) {
      return null;
    }
    return url;
  }

  static String _trimLeadingNoise(String input) {
    var value = input;
    while (value.isNotEmpty && _leadingNoiseChars.contains(value[0])) {
      value = value.substring(1);
    }
    return value;
  }

  static String _trimTrailingNoise(String input) {
    var value = input;
    while (value.isNotEmpty) {
      final last = value[value.length - 1];
      if (_trailingNoiseChars.contains(last)) {
        value = value.substring(0, value.length - 1);
        continue;
      }
      final opening = _closingPairs[last];
      if (opening != null &&
          _countChar(value, last) > _countChar(value, opening)) {
        value = value.substring(0, value.length - 1);
        continue;
      }
      break;
    }
    return value;
  }

  static bool _isValidHost(String host) {
    if (host.isEmpty) {
      return false;
    }
    if (host == 'localhost') {
      return true;
    }
    if (_ipv4Pattern.hasMatch(host)) {
      return host.split('.').every((segment) {
        final octet = int.tryParse(segment);
        return octet != null && octet >= 0 && octet <= 255;
      });
    }
    return _domainPattern.hasMatch(host);
  }

  static int _countChar(String text, String char) {
    var count = 0;
    for (var i = 0; i < text.length; i++) {
      if (text[i] == char) {
        count++;
      }
    }
    return count;
  }
}
