import 'dart:convert';
import 'dart:io';

import 'package:video_player_app/features/youtube_download/models/youtube_download_models.dart';

/// Guest fallback for X posts whose media is hidden from yt-dlp.
///
/// The public FixTweet status endpoint does not use a browser session.
/// See https://github.com/FixTweet/FixTweet
class XPostMediaFallback {
  const XPostMediaFallback._();

  static final RegExp _statusIdPattern = RegExp(
    r'/status(?:es)?/(\d+)',
    caseSensitive: false,
  );

  static String? statusIdFromUrl(String url) {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || !_isXHost(uri.host)) {
      return null;
    }
    return _statusIdPattern.firstMatch(uri.path)?.group(1);
  }

  static bool shouldAttempt(String url, Object error) {
    if (statusIdFromUrl(url) == null) {
      return false;
    }
    final text = error.toString().toLowerCase();
    return text.contains('no video could be found') ||
        text.contains('no video formats') ||
        text.contains('没有可用格式');
  }

  static Future<Map<String, dynamic>?> fetchInfo(String pageUrl) async {
    final statusId = statusIdFromUrl(pageUrl);
    if (statusId == null) {
      return null;
    }
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 20);
    try {
      final request = await client
          .getUrl(Uri.https('api.fxtwitter.com', '/status/$statusId'))
          .timeout(const Duration(seconds: 20));
      request.headers.set(HttpHeaders.userAgentHeader, 'Mozilla/5.0');
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final response = await request.close().timeout(
        const Duration(seconds: 20),
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        await response.drain<void>();
        return null;
      }
      final body = await response.transform(utf8.decoder).join();
      final decoded = jsonDecode(body);
      if (decoded is! Map) {
        return null;
      }
      return infoFromPayload(
        Map<String, dynamic>.from(decoded),
        pageUrl: pageUrl,
        statusId: statusId,
      );
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  static Map<String, dynamic>? infoFromPayload(
    Map<String, dynamic> payload, {
    required String pageUrl,
    required String statusId,
  }) {
    final tweet = payload['tweet'];
    if (tweet is! Map) {
      return null;
    }
    final media = tweet['media'];
    final videos = media is Map ? media['videos'] : null;
    if (videos is! List || videos.isEmpty) {
      return null;
    }

    final formats = <Map<String, dynamic>>[];
    final thumbnails = <Map<String, dynamic>>[];
    var durationSeconds = 0;
    for (var videoIndex = 0; videoIndex < videos.length; videoIndex++) {
      final video = videos[videoIndex];
      if (video is! Map) {
        continue;
      }
      final width = _intValue(video['width']);
      final height = _intValue(video['height']);
      final duration = _doubleValue(video['duration']);
      if (duration != null && duration > durationSeconds) {
        durationSeconds = duration.round();
      }
      final thumbnailUrl = _stringValue(video['thumbnail_url']);
      if (thumbnailUrl != null) {
        thumbnails.add({
          'url': thumbnailUrl,
          if (width != null) 'width': width,
          if (height != null) 'height': height,
        });
      }
      final variants = video['variants'];
      if (variants is List && variants.isNotEmpty) {
        for (
          var variantIndex = 0;
          variantIndex < variants.length;
          variantIndex++
        ) {
          final variant = variants[variantIndex];
          if (variant is! Map) {
            continue;
          }
          final format = _formatFromVariant(
            variant,
            formatId: 'x-$videoIndex-$variantIndex',
            width: width,
            height: height,
            videoLabel: videos.length > 1 ? '视频 ${videoIndex + 1}' : null,
          );
          if (format != null) {
            formats.add(format);
          }
        }
        continue;
      }
      final singleUrl = _stringValue(video['url']);
      if (singleUrl == null) {
        continue;
      }
      formats.add(
        _formatMap(
          formatId: 'x-$videoIndex-0',
          url: singleUrl,
          contentType: _stringValue(video['content_type']) ?? 'video/mp4',
          width: width,
          height: height,
          bitrate: _intValue(video['bitrate']),
          videoLabel: videos.length > 1 ? '视频 ${videoIndex + 1}' : null,
        ),
      );
    }
    if (formats.isEmpty) {
      return null;
    }

    final author = tweet['author'];
    final uploader = author is Map
        ? (_stringValue(author['name']) ?? _stringValue(author['screen_name']))
        : null;
    final text = _stringValue(tweet['text']);
    final title = _titleFromText(text, statusId);

    return {
      'id': statusId,
      'extractor': 'twitter',
      'extractor_key': 'twitter',
      'webpage_url': pageUrl,
      'title': title,
      'uploader': uploader ?? 'X',
      'duration': durationSeconds,
      'thumbnail': thumbnails.isEmpty ? null : thumbnails.first['url'],
      'thumbnails': thumbnails,
      'formats': formats,
      'direct_media': true,
      'http_headers': {
        'Referer': 'https://x.com/',
        'User-Agent': 'Mozilla/5.0',
      },
    };
  }

  static String? downloadUrlForFormat(VideoMeta meta, String? formatId) {
    if (meta.rawInfo['direct_media'] != true) {
      return null;
    }
    final formats = meta.rawInfo['formats'];
    if (formats is! List) {
      return null;
    }
    String? bestUrl;
    var bestBitrate = -1.0;
    for (final item in formats) {
      if (item is! Map) {
        continue;
      }
      final url = item['url']?.toString().trim() ?? '';
      if (!url.startsWith('http://') && !url.startsWith('https://')) {
        continue;
      }
      if (formatId != null && item['format_id']?.toString() == formatId) {
        return url;
      }
      final bitrate = _doubleValue(item['tbr']) ?? 0;
      if (bitrate >= bestBitrate) {
        bestBitrate = bitrate;
        bestUrl = url;
      }
    }
    return formatId == null ? bestUrl : bestUrl;
  }

  static bool _isXHost(String host) {
    final normalized = host.toLowerCase();
    const names = {
      'x.com',
      'twitter.com',
      'mobile.twitter.com',
      'mobile.x.com',
      'fxtwitter.com',
      'vxtwitter.com',
      'fixupx.com',
    };
    return names.contains(normalized) ||
        normalized.endsWith('.x.com') ||
        normalized.endsWith('.twitter.com') ||
        normalized.endsWith('.fxtwitter.com') ||
        normalized.endsWith('.vxtwitter.com') ||
        normalized.endsWith('.fixupx.com');
  }

  static Map<String, dynamic>? _formatFromVariant(
    Map<dynamic, dynamic> variant, {
    required String formatId,
    required int? width,
    required int? height,
    required String? videoLabel,
  }) {
    final url = _stringValue(variant['url']);
    if (url == null) {
      return null;
    }
    return _formatMap(
      formatId: formatId,
      url: url,
      contentType: _stringValue(variant['content_type']) ?? 'video/mp4',
      width: _intValue(variant['width']) ?? width,
      height: _intValue(variant['height']) ?? height,
      bitrate: _intValue(variant['bitrate']),
      videoLabel: videoLabel,
    );
  }

  static Map<String, dynamic> _formatMap({
    required String formatId,
    required String url,
    required String contentType,
    required int? width,
    required int? height,
    required int? bitrate,
    required String? videoLabel,
  }) {
    final lowerType = contentType.toLowerCase();
    final ext = lowerType.contains('mp4')
        ? 'mp4'
        : lowerType.contains('webm')
        ? 'webm'
        : lowerType.contains('mpegurl') || lowerType.contains('m3u8')
        ? 'm3u8'
        : 'mp4';
    final noteParts = <String>[
      if (videoLabel != null) videoLabel,
      if (height != null) '${height}p',
    ];
    return {
      'format_id': formatId,
      'url': url,
      'ext': ext,
      'vcodec': 'h264',
      'acodec': 'aac',
      if (width != null) 'width': width,
      if (height != null) 'height': height,
      if (bitrate != null) 'tbr': bitrate / 1000,
      if (noteParts.isNotEmpty) 'format_note': noteParts.join(' '),
    };
  }

  static String _titleFromText(String? text, String statusId) {
    final trimmed = text?.trim() ?? '';
    if (trimmed.isEmpty) {
      return 'X $statusId';
    }
    final line = trimmed.split(RegExp(r'\s+')).join(' ');
    if (line.length <= 80) {
      return line;
    }
    return '${line.substring(0, 77)}...';
  }

  static String? _stringValue(Object? value) {
    final text = value?.toString().trim() ?? '';
    if (text.isEmpty || text == 'null') {
      return null;
    }
    return text;
  }

  static int? _intValue(Object? value) {
    if (value is int) {
      return value;
    }
    if (value is double) {
      return value.round();
    }
    return int.tryParse(value?.toString() ?? '');
  }

  static double? _doubleValue(Object? value) {
    if (value is num) {
      return value.toDouble();
    }
    return double.tryParse(value?.toString() ?? '');
  }
}
