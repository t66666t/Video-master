import 'package:dio/dio.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart';
import 'package:cookie_jar/cookie_jar.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:developer' as developer;
import 'package:video_player_app/models/bilibili_models.dart';
import 'package:video_player_app/models/bilibili_download_task.dart';
import 'package:video_player_app/services/bilibili/wbi_signer.dart';
import 'package:video_player_app/utils/subtitle_util.dart';

class BilibiliApiService {
  late Dio _dio;
  late CookieJar _cookieJar;
  String? _imgKey;
  String? _subKey;

  static const String _userAgent =
      "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";
  static const String _referer = "https://www.bilibili.com/";

  BilibiliApiService() {
    _dio = Dio(BaseOptions(
      headers: {
        "User-Agent": _userAgent,
        "Referer": _referer,
      },
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 30),
    ));
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
    await _cookieJar.saveFromResponse(
        Uri.parse("https://api.bilibili.com"), [cookie]);
  }
  
  Future<bool> hasCookie() async {
     final cookies = await _cookieJar.loadForRequest(Uri.parse("https://api.bilibili.com"));
     return cookies.any((c) => c.name == "SESSDATA" && c.value.isNotEmpty);
  }

  /// Checks if the current cookie is valid by calling the nav API.
  /// Returns true if logged in (isLogin: true), false otherwise.
  Future<bool> checkLoginStatus() async {
    try {
      final response = await _dio.get("https://api.bilibili.com/x/web-interface/nav");
      if (response.statusCode == 200) {
        final data = response.data['data'];
        if (data != null && data['isLogin'] == true) {
          return true;
        }
      }
      return false;
    } catch (e) {
      developer.log('Error checking login status', error: e);
      return false;
    }
  }

  // --- QR Code Login ---
  
  Future<Map<String, String>> generateQrCode() async {
    try {
      final response = await _dio.get("https://passport.bilibili.com/x/passport-login/web/qrcode/generate");
      final data = response.data['data'];
      return {
        'url': data['url'],
        'qrcode_key': data['qrcode_key']
      };
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
      final response = await _dio.get("https://api.bilibili.com/x/web-interface/nav");
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
          validateStatus: (status) => status! < 400,
        ),
      );
      if (response.statusCode == 301 || response.statusCode == 302) {
        final location = response.headers.value('location');
        if (location != null) return location;
      }
      // If no redirect, maybe it's already resolved or handled by JS (less likely for b23.tv)
      // Or maybe Dio followed it? (followRedirects: false)
      return url;
    } catch (e) {
      developer.log('Error resolving short link', error: e);
      // Fallback: try GET with followRedirects true and get realUri
      try {
        final response = await _dio.get(url);
        return response.realUri.toString();
      } catch (e2) {
        return url;
      }
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

  Future<Map<String, dynamic>> fetchBangumiInfo({String? epId, String? seasonId}) async {
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
    final cookies = await _cookieJar.loadForRequest(Uri.parse("https://api.bilibili.com"));
    final hasCookie = cookies.any((c) => c.name == "SESSDATA" && c.value.isNotEmpty);

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

  Future<List<BilibiliSubtitle>> fetchSubtitles(String bvid, int cid, {String? aid, bool skipAi = false}) async {
    try {
      final List<BilibiliSubtitle> subtitles = [];
      final Set<String> seenUrls = {};
      
      developer.log('Fetching subtitles for bvid=$bvid, cid=$cid, aid=$aid');

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
        
        final subtitlesList = wbiV2Response.data['data']?['subtitle']?['subtitles'];
        if (subtitlesList is List && subtitlesList.isNotEmpty) {
          for (var item in subtitlesList) {
            _addSubtitleToList(item, subtitles, seenUrls);
          }
          if (subtitles.isNotEmpty) {
            developer.log('Fetched subtitles from player/wbi/v2');
          }
        }
      } catch (e) {
        developer.log('Warning: Failed to fetch from player/wbi/v2', error: e);
      }

      // Fallback methods removed as requested by user to avoid incorrect matches.

      return skipAi ? subtitles.where((s) => !s.isAi).toList() : subtitles;
    } catch (e) {
      developer.log('Error fetching subtitles', error: e);
      return [];
    }
  }

  void _addSubtitleToList(dynamic item, List<BilibiliSubtitle> list, Set<String> seenUrls) {
    final url = (item['subtitle_url'] ?? '').toString();
    if (url.isEmpty || seenUrls.contains(url)) return;

    String finalUrl = url;
    if (finalUrl.startsWith("//")) finalUrl = "https:$finalUrl";

    final lan = item['lan'] ?? '';
    final lanDoc = item['lan_doc'] ?? SubtitleUtil.getLanguageName(lan);
    
    // AI detection
    final isLock = item['is_lock'];
    final bool isLocked = isLock == true || isLock == 1;
    final bool isAi = isLocked || 
                     lan.toString().startsWith("ai-") || 
                     lanDoc.toString().toUpperCase().contains("AI") ||
                     lanDoc.toString().contains("自动") ||
                     lanDoc.toString().contains("机器");

    list.add(BilibiliSubtitle(
      id: item['id']?.toString() ?? '',
      lan: lan,
      lanDoc: lanDoc,
      url: finalUrl,
      isAi: isAi,
    ));
    seenUrls.add(url);
  }

  Future<dynamic> fetchSubtitleContent(String url) async {
    try {
      final response = await _dio.get(
        url,
        options: Options(headers: {
          "User-Agent": _userAgent,
          "Referer": _referer,
        }),
      );
      return response.data; // Return raw data (Map or String)
    } catch (e) {
      developer.log('Error downloading subtitle content', error: e);
      return null;
    }
  }
  
  // Helper to get Dio instance for downloading
  Dio get dio => _dio;
}
