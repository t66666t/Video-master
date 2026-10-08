/// Image URL handling for Bilibili covers and avatars.
///
/// Only HTTPS images on Bilibili's own image CDNs are loaded. Anything else
/// (other hosts, credentials in the URL, literal IPs, odd schemes) is dropped
/// so the UI shows a placeholder instead.
library;

const List<String> _allowedImageDomains = <String>['hdslb.com', 'biliimg.com'];

/// Small cover variant used by lists and the detail header.
const String bilibiliCoverThumbnailSuffix = '@320w_200h_1c.webp';

final RegExp _hostPattern = RegExp(r'^[a-z0-9-]+(?:\.[a-z0-9-]+)+$');

/// Returns a normalized https URL for an allowed Bilibili image host, or null.
///
/// `//host/path` and `http://` are upgraded to https. Any existing `@...`
/// processing suffix is kept as-is.
String? normalizeBilibiliImageUrl(String? raw) {
  var value = raw?.trim() ?? '';
  if (value.isEmpty) return null;
  if (value.startsWith('//')) value = 'https:$value';
  var uri = Uri.tryParse(value);
  if (uri == null) return null;
  if (uri.scheme == 'http') {
    uri = uri.replace(scheme: 'https', port: uri.port == 80 ? 443 : uri.port);
  }
  if (uri.scheme != 'https' ||
      uri.userInfo.isNotEmpty ||
      !uri.hasAuthority ||
      uri.path.isEmpty ||
      (uri.hasPort && uri.port != 443)) {
    return null;
  }
  final host = uri.host.toLowerCase();
  if (!_hostPattern.hasMatch(host)) return null;
  final allowed = _allowedImageDomains.any(
    (domain) => host == domain || host.endsWith('.$domain'),
  );
  if (!allowed) return null;
  return Uri(
    scheme: 'https',
    host: host,
    path: uri.path,
    query: uri.hasQuery ? uri.query : null,
  ).toString();
}

/// Cover thumbnail: normalized URL with the size suffix replacing any
/// existing processing suffix. Null means "show the placeholder".
String? bilibiliCoverThumbnailUrl(String? raw) {
  final normalized = normalizeBilibiliImageUrl(raw);
  if (normalized == null) return null;
  final uri = Uri.parse(normalized);
  final path = _stripProcessingSuffix(uri.path);
  return Uri(
    scheme: 'https',
    host: uri.host,
    path: '$path$bilibiliCoverThumbnailSuffix',
  ).toString();
}

/// Avatar: normalized only. No crop suffix, so the original framing is kept.
String? bilibiliAvatarUrl(String? raw) => normalizeBilibiliImageUrl(raw);

String _stripProcessingSuffix(String path) {
  final slash = path.lastIndexOf('/');
  final at = path.indexOf('@', slash < 0 ? 0 : slash);
  return at < 0 ? path : path.substring(0, at);
}
