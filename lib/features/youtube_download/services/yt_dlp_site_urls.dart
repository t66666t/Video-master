import 'dart:io';

/// URL helpers for sites yt-dlp already supports.
///
/// Xiaohongshu share links (`xhslink.cn` / `xhslink.com`) redirect anonymous
/// clients through the real note URL and then to `/login`. yt-dlp follows
/// that last hop and reports an unsupported URL. The note URL itself matches
/// the official XiaoHongShu extractor.
class YtDlpSiteUrls {
  const YtDlpSiteUrls._();

  static final RegExp _noteUrlPattern = RegExp(
    r'^https?://www\.xiaohongshu\.com/(?:explore|discovery/item)/[\da-f]+',
    caseSensitive: false,
  );

  static bool isYoutube(String url) {
    final host = Uri.tryParse(url.trim())?.host.toLowerCase() ?? '';
    return host == 'youtu.be' ||
        host == 'youtube.com' ||
        host.endsWith('.youtube.com') ||
        host.endsWith('youtube-nocookie.com');
  }

  static bool isXiaohongshuShareHost(Uri uri) {
    final host = uri.host.toLowerCase();
    return host == 'xhslink.com' ||
        host == 'xhslink.cn' ||
        host.endsWith('.xhslink.com') ||
        host.endsWith('.xhslink.cn');
  }

  /// Returns a Xiaohongshu note URL when [url] already is one, or when it is
  /// the login page whose `redirectPath` points at one.
  static String? xiaohongshuNoteUrl(String url, {int depth = 0}) {
    if (depth > 2) {
      return null;
    }
    final uri = Uri.tryParse(url.trim());
    if (uri == null || uri.host.isEmpty) {
      return null;
    }
    if (_noteUrlPattern.hasMatch(uri.toString())) {
      return _preferHttps(uri).toString();
    }
    if (!uri.host.toLowerCase().endsWith('xiaohongshu.com')) {
      return null;
    }
    if (uri.path.toLowerCase() != '/login') {
      return null;
    }
    final redirect = uri.queryParameters['redirectPath'];
    if (redirect == null || redirect.isEmpty) {
      return null;
    }
    return xiaohongshuNoteUrl(redirect, depth: depth + 1);
  }

  static Future<String> canonicalizeForResolve(String url) async {
    final direct = xiaohongshuNoteUrl(url);
    if (direct != null) {
      return direct;
    }
    final uri = Uri.tryParse(url.trim());
    if (uri == null || !isXiaohongshuShareHost(uri)) {
      return url;
    }
    return await _followShareLink(uri) ?? url;
  }

  static String explainResolveFailure(String message, String url) {
    final combined = '$url\n$message'.toLowerCase();
    final isXiaohongshu =
        combined.contains('xiaohongshu') || combined.contains('xhslink');
    if (!isXiaohongshu) {
      return message;
    }
    final needsCookies =
        combined.contains('/login') ||
        combined.contains('unsupported url') ||
        combined.contains('initial state') ||
        combined.contains('no video formats');
    if (!needsCookies || message.contains('web_session')) {
      return message;
    }
    return '$message。若仍然失败，请在设置中导入包含 xiaohongshu.com 的 web_session 的 cookies.txt';
  }

  static Uri _preferHttps(Uri uri) {
    if (uri.scheme == 'http') {
      return uri.replace(scheme: 'https');
    }
    return uri;
  }

  static Future<String?> _followShareLink(Uri start) async {
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 8);
    try {
      var current = start;
      for (var hop = 0; hop < 5; hop++) {
        final request = await client.getUrl(current);
        request.followRedirects = false;
        request.headers.set(HttpHeaders.userAgentHeader, 'Mozilla/5.0');
        final response = await request.close().timeout(
          const Duration(seconds: 8),
        );
        final location = response.headers.value(HttpHeaders.locationHeader);
        await response.drain<void>();
        if (location == null || location.isEmpty) {
          return xiaohongshuNoteUrl(current.toString());
        }
        final next = _preferHttps(current.resolve(location));
        final note = xiaohongshuNoteUrl(next.toString());
        if (note != null) {
          return note;
        }
        current = next;
      }
      return xiaohongshuNoteUrl(current.toString());
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }
}
