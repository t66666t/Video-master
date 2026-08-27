import 'package:dio/dio.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart';
import 'package:cookie_jar/cookie_jar.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io' show ZLibDecoder, gzip;
import 'package:video_player_app/models/bilibili_models.dart';
import 'package:video_player_app/models/bilibili_download_task.dart';
import 'package:video_player_app/models/media_chapter.dart';
import 'package:video_player_app/services/bilibili/wbi_signer.dart';
import 'package:video_player_app/utils/subtitle_util.dart';

enum BilibiliLoginStatus { loggedIn, loggedOut, unavailable }

class BilibiliPlayerMetadata {
  final List<BilibiliSubtitle> subtitles;
  final List<MediaChapter> chapters;

  const BilibiliPlayerMetadata({
    this.subtitles = const <BilibiliSubtitle>[],
    this.chapters = const <MediaChapter>[],
  });
}

class BilibiliApiService {
  late Dio _dio;
  late CookieJar _cookieJar;
  String? _imgKey;
  String? _subKey;

  static const String _userAgent =
      "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";
  static const String _referer = "https://www.bilibili.com/";

  BilibiliApiService() {
    _dio = Dio(
      BaseOptions(
        headers: {"User-Agent": _userAgent, "Referer": _referer},
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 30),
      ),
    );
  }

  Future<void> init() async {
    final appDocDir = await getApplicationDocumentsDirectory();
    final cookiePath = "${appDocDir.path}/.bilibili_cookies";
    _cookieJar = PersistCookieJar(storage: FileStorage(cookiePath));
    _dio.interceptors.add(CookieManager(_cookieJar));
  }

  /// Update SESSDATA manually if needed
  Future<void> setCookie(String sessData) async {
    if (sessData.isEmpty) return;
    final cookie = Cookie("SESSDATA", sessData)
      ..domain = ".bilibili.com"
      ..path = "/";
    await _cookieJar.saveFromResponse(Uri.parse("https://api.bilibili.com"), [
      cookie,
    ]);
  }

  Future<bool> hasCookie() async {
    final cookies = await _cookieJar.loadForRequest(
      Uri.parse("https://api.bilibili.com"),
    );
    return cookies.any((c) => c.name == "SESSDATA" && c.value.isNotEmpty);
  }

  static BilibiliLoginStatus classifyLoginResponse({
    required int? statusCode,
    required dynamic responseData,
  }) {
    if (statusCode != 200 || responseData is! Map) {
      return BilibiliLoginStatus.unavailable;
    }
    final data = responseData['data'];
    if (data is! Map || data['isLogin'] is! bool) {
      return BilibiliLoginStatus.unavailable;
    }
    return data['isLogin'] == true
        ? BilibiliLoginStatus.loggedIn
        : BilibiliLoginStatus.loggedOut;
  }

  /// Checks the current cookie against Bilibili without treating a network
  /// failure as a confirmed logout.
  Future<BilibiliLoginStatus> checkLoginStatusDetailed() async {
    try {
      final response = await _dio.get(
        "https://api.bilibili.com/x/web-interface/nav",
      );
      return classifyLoginResponse(
        statusCode: response.statusCode,
        responseData: response.data,
      );
    } catch (e) {
      developer.log('Error checking login status', error: e);
      return BilibiliLoginStatus.unavailable;
    }
  }

  /// Compatibility helper for callers that only need a boolean result.
  Future<bool> checkLoginStatus() async =>
      await checkLoginStatusDetailed() == BilibiliLoginStatus.loggedIn;

  // --- QR Code Login ---

  Future<Map<String, String>> generateQrCode() async {
    try {
      final response = await _dio.get(
        "https://passport.bilibili.com/x/passport-login/web/qrcode/generate",
      );
      final data = response.data['data'];
      return {'url': data['url'], 'qrcode_key': data['qrcode_key']};
    } catch (e) {
      developer.log('Error generating QR code', error: e);
      rethrow;
    }
  }

  Future<Map<String, dynamic>> pollQrCode(String qrcodeKey) async {
    try {
      final response = await _dio.get(
        "https://passport.bilibili.com/x/passport-login/web/qrcode/poll",
        queryParameters: {'qrcode_key': qrcodeKey},
      );
      final data = response.data['data'];

      // data['code']: 0=Success, 86101=Unscanned, 86090=Scanned but not confirmed, 86038=Expired
      final code = data['code'];

      if (code == 0) {
        // Success! Cookies are automatically handled by Dio CookieManager from the response headers
        // But we might need to parse them from the URL if Set-Cookie header is missing (rare for web API)
        // Actually, passport-login/web/qrcode/poll returns Set-Cookie headers on success.
        // So _cookieJar should already have them.

        // Let's ensure we save them properly if they are in the url query params (sometimes happens)
        // But typically Set-Cookie header is used.
        return {'success': true, 'message': '登录成功'};
      } else {
        return {'success': false, 'code': code, 'message': data['message']};
      }
    } catch (e) {
      developer.log('Error polling QR code', error: e);
      return {'success': false, 'code': -1, 'message': e.toString()};
    }
  }

  Future<void> _fetchWbiKeys() async {
    try {
      final response = await _dio.get(
        "https://api.bilibili.com/x/web-interface/nav",
      );
      final data = response.data['data'];
      final wbiImg = data['wbi_img'];
      final imgUrl = wbiImg['img_url'] as String;
      final subUrl = wbiImg['sub_url'] as String;

      _imgKey = imgUrl.split('/').last.split('.').first;
      _subKey = subUrl.split('/').last.split('.').first;
    } catch (e) {
      developer.log('Error fetching WBI keys', error: e);
      rethrow;
    }
  }

  Future<String> resolveShortLink(String url) async {
    try {
      final response = await _dio.head(
        url,
        options: Options(
          followRedirects: false,
          validateStatus: (status) => status != null && status < 400,
        ),
      );
      final statusCode = response.statusCode ?? 0;
      if (statusCode >= 300 && statusCode < 400) {
        final location = response.headers.value('location');
        if (location != null && location.isNotEmpty) {
          return Uri.parse(url).resolve(location).toString();
        }
      }
    } catch (e) {
      developer.log('Error resolving short link', error: e);
    }

    // Some short-link services reject HEAD or return an HTML response for it.
    // A following GET still exposes the final redirect URI without depending
    // on a particular 3xx status code.
    try {
      final response = await _dio.get(url);
      return response.realUri.toString();
    } catch (e) {
      developer.log('Error resolving short link with GET fallback', error: e);
      return url;
    }
  }

  Future<BilibiliVideoInfo> fetchVideoInfo(String bvid, {String? aid}) async {
    try {
      final params = <String, dynamic>{};
      if (bvid.isNotEmpty) params['bvid'] = bvid;
      if (aid != null) params['aid'] = aid;

      final response = await _dio.get(
        "https://api.bilibili.com/x/web-interface/view",
        queryParameters: params,
      );
      return BilibiliVideoInfo.fromJson(response.data);
    } catch (e) {
      developer.log('Error fetching video info', error: e);
      rethrow;
    }
  }

  Future<Map<String, dynamic>> fetchBangumiInfo({
    String? epId,
    String? seasonId,
  }) async {
    try {
      final params = <String, dynamic>{};
      if (epId != null) params['ep_id'] = epId;
      if (seasonId != null) params['season_id'] = seasonId;

      final response = await _dio.get(
        "https://api.bilibili.com/pgc/view/web/season",
        queryParameters: params,
      );
      return response.data['result'];
    } catch (e) {
      developer.log('Error fetching bangumi info', error: e);
      rethrow;
    }
  }

  Future<BilibiliStreamInfo> fetchPlayUrl(String bvid, int cid) async {
    if (_imgKey == null || _subKey == null) {
      await _fetchWbiKeys();
    }

    // Check if we have cookies (roughly)
    final cookies = await _cookieJar.loadForRequest(
      Uri.parse("https://api.bilibili.com"),
    );
    final hasCookie = cookies.any(
      (c) => c.name == "SESSDATA" && c.value.isNotEmpty,
    );

    final params = {
      'bvid': bvid,
      'cid': cid,
      'qn': 0, // Highest quality
      'fnval': 4048, // DASH
      'fnver': 0,
      'fourk': 1,
    };

    // BBDown Logic: if cookie is empty, append try_look=1.
    // Although WbiSigner usually handles the map, we need to add it before signing.
    if (!hasCookie) {
      params['try_look'] = 1;
    }

    final signedParams = WbiSigner.sign(params, _imgKey!, _subKey!);

    try {
      final response = await _dio.get(
        "https://api.bilibili.com/x/player/wbi/playurl",
        queryParameters: signedParams,
      );
      return BilibiliStreamInfo.fromJson(response.data);
    } catch (e) {
      developer.log('Error fetching play url', error: e);
      rethrow;
    }
  }

  Future<List<BilibiliSubtitle>> fetchSubtitles(
    String bvid,
    int cid, {
    String? aid,
    bool skipAi = false,
  }) async {
    final metadata = await fetchPlayerMetadata(
      bvid,
      cid,
      aid: aid,
      skipAiSubtitles: skipAi,
    );
    return metadata.subtitles;
  }

  Future<BilibiliPlayerMetadata> fetchPlayerMetadata(
    String bvid,
    int cid, {
    String? aid,
    bool skipAiSubtitles = false,
    int durationSeconds = 0,
  }) async {
    try {
      final List<BilibiliSubtitle> subtitles = [];
      final Set<String> seenUrls = {};
      final List<MediaChapter> chapters = [];

      developer.log(
        'Fetching player metadata for bvid=$bvid, cid=$cid, aid=$aid',
      );

      // Step 1: Request x/player/wbi/v2 (Signed, most reliable)
      try {
        if (_imgKey == null || _subKey == null) {
          await _fetchWbiKeys();
        }

        final Map<String, dynamic> params = {'cid': cid};
        if (bvid.isNotEmpty) {
          params['bvid'] = bvid;
        } else if (aid != null && aid.isNotEmpty) {
          params['aid'] = aid;
        }

        final signedParams = WbiSigner.sign(params, _imgKey!, _subKey!);

        final wbiV2Response = await _dio.get(
          "https://api.bilibili.com/x/player/wbi/v2",
          queryParameters: signedParams,
        );

        final subtitlesList =
            wbiV2Response.data['data']?['subtitle']?['subtitles'];
        if (subtitlesList is List && subtitlesList.isNotEmpty) {
          for (var item in subtitlesList) {
            _addSubtitleToList(item, subtitles, seenUrls);
          }
          if (subtitles.isNotEmpty) {
            developer.log('Fetched subtitles from player/wbi/v2');
          }
        }
        final viewPoints = wbiV2Response.data['data']?['view_points'];
        if (viewPoints is List) {
          chapters.addAll(
            viewPoints.whereType<Map>().map(
              (item) => MediaChapter.fromJson(Map<String, dynamic>.from(item)),
            ),
          );
        }
      } catch (e) {
        developer.log(
          'Warning: Failed to fetch player metadata from player/wbi/v2',
          error: e,
        );
      }

      // Fallback methods removed as requested by user to avoid incorrect matches.
      return BilibiliPlayerMetadata(
        subtitles: skipAiSubtitles
            ? subtitles.where((subtitle) => !subtitle.isAi).toList()
            : subtitles,
        chapters: MediaChapter.normalize(
          chapters,
          durationMs: durationSeconds * 1000,
        ),
      );
    } catch (e) {
      developer.log('Error fetching player metadata', error: e);
      return const BilibiliPlayerMetadata();
    }
  }

  void _addSubtitleToList(
    dynamic item,
    List<BilibiliSubtitle> list,
    Set<String> seenUrls,
  ) {
    final url = (item['subtitle_url'] ?? '').toString();
    if (url.isEmpty || seenUrls.contains(url)) return;

    String finalUrl = url;
    if (finalUrl.startsWith("//")) finalUrl = "https:$finalUrl";

    final lan = item['lan'] ?? '';
    final lanDoc = item['lan_doc'] ?? SubtitleUtil.getLanguageName(lan);

    // AI detection
    final isLock = item['is_lock'];
    final bool isLocked = isLock == true || isLock == 1;
    final bool isAi =
        isLocked ||
        lan.toString().startsWith("ai-") ||
        lanDoc.toString().toUpperCase().contains("AI") ||
        lanDoc.toString().contains("自动") ||
        lanDoc.toString().contains("机器");

    list.add(
      BilibiliSubtitle(
        id: item['id']?.toString() ?? '',
        lan: lan,
        lanDoc: lanDoc,
        url: finalUrl,
        isAi: isAi,
      ),
    );
    seenUrls.add(url);
  }

  Future<dynamic> fetchSubtitleContent(String url) async {
    try {
      final response = await _dio.get(
        url,
        options: Options(
          headers: {"User-Agent": _userAgent, "Referer": _referer},
        ),
      );
      return response.data; // Return raw data (Map or String)
    } catch (e) {
      developer.log('Error downloading subtitle content', error: e);
      return null;
    }
  }

  Future<String> fetchDanmakuXml(int cid) async {
    final response = await _dio.get<List<int>>(
      'https://comment.bilibili.com/$cid.xml',
      options: Options(
        responseType: ResponseType.bytes,
        headers: const {'Accept': 'application/xml,text/xml,*/*'},
      ),
    );
    final bytes = response.data;
    if (bytes == null || bytes.isEmpty) {
      throw StateError('Bilibili returned an empty danmaku file.');
    }
    final content = decodeBilibiliDanmakuPayload(
      bytes,
      contentEncoding: response.headers.value('content-encoding'),
    );
    if (content.trim().isEmpty) {
      throw StateError('Bilibili returned an empty danmaku file.');
    }
    if (!RegExp(r'<i(?:\s|>)', caseSensitive: false).hasMatch(content) ||
        !RegExp(r'</i\s*>', caseSensitive: false).hasMatch(content)) {
      throw const FormatException('Bilibili returned invalid danmaku XML.');
    }
    return content;
  }

  // Helper to get Dio instance for downloading
  Dio get dio => _dio;
}

String decodeBilibiliDanmakuPayload(
  List<int> bytes, {
  String? contentEncoding,
}) {
  final encoding = contentEncoding?.toLowerCase() ?? '';
  try {
    final plain = utf8.decode(bytes, allowMalformed: false);
    if (RegExp(r'^\s*<', multiLine: true).hasMatch(plain)) {
      return plain;
    }
  } on FormatException {
    // Compressed data is expected to fail direct UTF-8 decoding.
  }

  List<int> decoded = bytes;
  final hasGzipHeader =
      bytes.length > 1 && bytes[0] == 0x1f && bytes[1] == 0x8b;
  final hasZlibHeader = bytes.length > 1 && bytes[0] == 0x78;
  if (encoding.contains('gzip') || hasGzipHeader) {
    decoded = gzip.decode(bytes);
  } else if (encoding.contains('deflate') || hasZlibHeader) {
    try {
      decoded = ZLibDecoder().convert(bytes);
    } on FormatException {
      decoded = ZLibDecoder(raw: true).convert(bytes);
    }
  }
  return utf8.decode(decoded, allowMalformed: false);
}
