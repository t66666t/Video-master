/// Recognizes a search-box input that should open a video directly instead
/// of running a keyword search.
library;

class BilibiliVideoInputTarget {
  final String? bvid;
  final int? aid;

  /// b23.tv / bili2233.cn link that still needs redirect resolution.
  final Uri? shortLink;

  /// 1-based part number from `?p=`, defaults to 1.
  final int page;

  const BilibiliVideoInputTarget({
    this.bvid,
    this.aid,
    this.shortLink,
    this.page = 1,
  });

  bool get needsResolve => bvid == null && aid == null && shortLink != null;
}

final RegExp _bvExact = RegExp(r'^BV[0-9A-Za-z]{10}$', caseSensitive: false);
final RegExp _avExact = RegExp(r'^av(\d{1,19})$', caseSensitive: false);
final RegExp _bvInText = RegExp(r'BV[0-9A-Za-z]{10}');
final RegExp _avInPath = RegExp(r'/av(\d{1,19})(?:/|$)', caseSensitive: false);
final RegExp _urlInText = RegExp(r'https?://[^\s，。！？、；：“”‘’（）【】<>"]+');

const List<String> _videoHosts = <String>['bilibili.com'];
const List<String> _shortHosts = <String>['b23.tv', 'bili2233.cn'];

bool _hostIn(String host, List<String> domains) =>
    domains.any((d) => host == d || host.endsWith('.$d'));

/// Normalizes the "bv" prefix casing: `bv1xx` -> `BV1xx`.
String normalizeBvidCase(String value) =>
    value.length < 2 ? value : 'BV${value.substring(2)}';

/// Returns a target when [raw] is a bare BV/av id or contains a Bilibili video
/// (or short) link. Ordinary keywords return null.
BilibiliVideoInputTarget? parseBilibiliVideoInput(String raw) {
  final text = raw.trim();
  if (text.isEmpty) return null;

  if (_bvExact.hasMatch(text)) {
    return BilibiliVideoInputTarget(bvid: normalizeBvidCase(text));
  }
  final av = _avExact.firstMatch(text);
  if (av != null) {
    final aid = int.tryParse(av.group(1)!);
    if (aid != null && aid > 0) return BilibiliVideoInputTarget(aid: aid);
  }

  final urlMatch = _urlInText.firstMatch(text);
  if (urlMatch == null) return null;
  final cleaned = urlMatch.group(0)!.replaceAll(RegExp(r'[.,!?;:)\]]+$'), '');
  final uri = Uri.tryParse(cleaned);
  if (uri == null || !uri.hasAuthority) return null;
  final host = uri.host.toLowerCase();
  final page = int.tryParse(uri.queryParameters['p'] ?? '') ?? 1;
  final safePage = page < 1 ? 1 : page;

  if (_hostIn(host, _shortHosts)) {
    return BilibiliVideoInputTarget(
      shortLink: uri.replace(scheme: 'https'),
      page: safePage,
    );
  }
  if (!_hostIn(host, _videoHosts)) return null;
  final bv = _bvInText.firstMatch(uri.path);
  if (bv != null) {
    return BilibiliVideoInputTarget(bvid: bv.group(0), page: safePage);
  }
  final avPath = _avInPath.firstMatch(uri.path);
  if (avPath != null) {
    final aid = int.tryParse(avPath.group(1)!);
    if (aid != null && aid > 0) {
      return BilibiliVideoInputTarget(aid: aid, page: safePage);
    }
  }
  final bvQuery = uri.queryParameters['bvid'] ?? '';
  if (_bvExact.hasMatch(bvQuery)) {
    return BilibiliVideoInputTarget(
      bvid: normalizeBvidCase(bvQuery),
      page: safePage,
    );
  }
  return null;
}

/// Finds a video target inside a resolved redirect URL.
BilibiliVideoInputTarget? parseResolvedBilibiliUrl(Uri uri) {
  final host = uri.host.toLowerCase();
  if (!_hostIn(host, _videoHosts)) return null;
  return parseBilibiliVideoInput(uri.toString());
}
