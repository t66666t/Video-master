import 'package:dio/dio.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart';
import 'package:cookie_jar/cookie_jar.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:typed_data';
import 'dart:io';
import 'dart:convert';
import 'dart:math'; // Added for min
import 'package:video_player_app/models/bilibili_models.dart';
import 'package:video_player_app/models/bilibili_download_task.dart';
import 'package:video_player_app/services/bilibili/wbi_signer.dart';
import 'package:video_player_app/utils/subtitle_util.dart';
import 'package:video_player_app/services/bilibili/grpc_models.dart';

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
      print("Error checking login status: $e");
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
      print("Error generating QR code: $e");
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
       print("Error polling QR code: $e");
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
      print("Error fetching WBI keys: $e");
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
      print("Error resolving short link: $e");
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
      print("Error fetching video info: $e");
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
      print("Error fetching bangumi info: $e");
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
      print("Error fetching play url: $e");
      rethrow;
    }
  }

  Future<List<BilibiliSubtitle>> fetchSubtitles(String bvid, int cid, {String? aid, bool skipAi = false}) async {
    try {
      final List<BilibiliSubtitle> subtitles = [];
      final Set<String> seenUrls = {};
      
      print("Fetching subtitles for bvid=$bvid, cid=$cid, aid=$aid");

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
             print("Fetched subtitles from player/wbi/v2");
          }
        }
      } catch (e) {
        print("Warning: Failed to fetch from player/wbi/v2: $e");
      }

      // Fallback methods removed as requested by user to avoid incorrect matches.

      return skipAi ? subtitles.where((s) => !s.isAi).toList() : subtitles;
    } catch (e) {
      print("Error fetching subtitles: $e");
      return [];
    }
  }

  // Header Generators
  String _generateMetadataBin() {
    return base64Encode(Metadata(accessKey: "").toBytes());
  }

  String _generateDeviceBin() {
    return base64Encode(Device().toBytes());
  }

  String _generateNetworkBin() {
    return base64Encode(Network().toBytes());
  }

  String _generateLocaleBin() {
    return base64Encode(Locale().toBytes());
  }

  String _generateFawkesReqBin() {
    return base64Encode(FawkesReq().toBytes());
  }

  Future<List<BilibiliSubtitle>> _fetchSubtitlesFromGrpc(int aid, int cid) async {
    try {
       print("--> gRPC: Starting request for aid=$aid, cid=$cid");
       final safeAid = aid > 0 ? aid : 0;
       final req = DmViewReq(pid: safeAid, oid: cid);
       final reqBytes = req.toBytes();
       print("--> gRPC: Request bytes length: ${reqBytes.length}");
       
       // BBDown uses Gzip compression for the request body
       final compressedReqBytes = gzip.encode(reqBytes);
       print("--> gRPC: Compressed bytes length: ${compressedReqBytes.length}");
       
       // Pack with gRPC header: [1 (compressed), length(4 bytes)]
       final header = Uint8List(5);
       header[0] = 1; // Compressed
       ByteData.view(header.buffer).setUint32(1, compressedReqBytes.length, Endian.big);
       
       final body = BytesBuilder();
       body.add(header);
       body.add(compressedReqBytes);
       
       final headers = {
         "content-type": "application/grpc",
         "user-agent": "Dalvik/2.1.0 (Linux; U; Android 6.0.1; oneplus a5010 Build/V417IR) 6.10.0 os/android model/oneplus a5010 mobi_app/android build/6100500 channel/bili innerVer/6100500 osVer/6.0.1 network/2",
         "te": "trailers",
         "grpc-encoding": "gzip",
         "x-bili-metadata-bin": _generateMetadataBin(),
         "x-bili-device-bin": _generateDeviceBin(),
         "x-bili-network-bin": _generateNetworkBin(),
         "x-bili-locale-bin": _generateLocaleBin(),
         "x-bili-fawkes-req-bin": _generateFawkesReqBin(),
         "authorization": "identify_v1 ",
       };
       print("--> gRPC: Headers prepared with x-bili bins (app endpoint).");

       final response = await _dio.post(
         "https://app.biliapi.net/bilibili.community.service.dm.v1.DM/DmView", 
         data: body.toBytes(), 
         options: Options(
           responseType: ResponseType.bytes,
           headers: headers,
           validateStatus: (status) => true, 
         ),
       );
       
       print("<-- gRPC: Response status: ${response.statusCode}");
       final respBytes = response.data as Uint8List;
       print("<-- gRPC: Response bytes length: ${respBytes.length}");
       
       if (response.statusCode != 200) {
           print("<-- gRPC: Error response body: ${utf8.decode(respBytes, allowMalformed: true)}");
           return [];
       }

       // Read gRPC response header
       if (respBytes.length < 5) {
         print("<-- gRPC: Invalid response length < 5");
         throw Exception("Invalid gRPC response");
       }
       
       final compressedFlag = respBytes[0];
       final len = ByteData.view(respBytes.buffer).getUint32(1, Endian.big);
       print("<-- gRPC: Flag=$compressedFlag, Payload Length=$len");
       
       Uint8List payload;
       if (len > 10000000) { 
          print("<-- gRPC: Length is suspicious. Checking for text response...");
          try {
            final text = utf8.decode(respBytes.sublist(0, min(100, respBytes.length)));
            print("<-- gRPC: Response start (text): $text");
          } catch (_) {}
          
          // Fallback: Assume the entire body IS the payload (maybe uncompressed, or raw Gzip)
          // If flag is "T" (0x54), it's text.
          
          // Let's try to ignore framing and treat the whole body as Gzip if it starts with Gzip magic header (0x1F 0x8B)
          if (respBytes.length > 2 && respBytes[0] == 0x1F && respBytes[1] == 0x8B) {
             print("<-- gRPC: Detected raw Gzip stream without gRPC framing.");
             payload = respBytes;
             // Force decompress logic below
          } else {
             final ct = response.headers.value("content-type") ?? "";
             if (ct.contains("grpc-web")) {
               try {
                 final text = ascii.decode(respBytes);
                 final cleaned = text.trim();
                 final decoded = base64.decode(cleaned);
                 print("<-- gRPC: Detected gRPC-Web base64 payload, decoded length: ${decoded.length}");
                 payload = decoded.sublist(5);
               } catch (e) {
                 print("<-- gRPC: gRPC-Web base64 decode failed: $e");
                 final text = utf8.decode(respBytes, allowMalformed: true);
                 print("<-- gRPC: Full text response: $text");
                 throw Exception("Server returned text instead of gRPC: ${text.substring(0, min(50, text.length))}...");
               }
             } else {
               // If not Gzip, and framing is broken, we can't do much. 
               // But wait, the previous log said: Response bytes length: 703.
               // Maybe the response IS gRPC-Web text encoded? No, content-type is application/grpc.
               
               // Let's try to find the gRPC frame. Maybe it's not at offset 0?
               // Or maybe it is gRPC-Web which uses base64?
               
               // CRITICAL FIX: The log shows Payload Length=1414811695 (0x5454502F -> "TTP/").
               // This means the first 5 bytes are "HTTP/".
               // This implies Dio is NOT stripping the HTTP headers, OR the server is returning a double-wrapped HTTP response?
               // No, Dio usually strips headers.
               // UNLESS the server is returning "HTTP/2 200 OK" inside the body? Unlikely.
               // OR, we are talking to a proxy that returns HTTP/1.1 text.
               
               // Let's assume the response is GZIPPED but NOT framed if the header check fails.
               // Actually, if the first bytes are "HTTP/", it's likely a proxy error message (e.g., 502/504) that Dio treated as 200 because the status line says 200? No.
               
               // Let's try to decode it as text to see what it says.
               final text = utf8.decode(respBytes, allowMalformed: true);
               print("<-- gRPC: Full text response: $text");
               throw Exception("Server returned text instead of gRPC: ${text.substring(0, min(50, text.length))}...");
             }
          }
       } else if (respBytes.length < 5 + len) {
          print("<-- gRPC: Incomplete response. Expected ${5+len}, got ${respBytes.length}");
          // Try to use what we have if it looks like Gzip?
          if (respBytes.length > 5 + 2 && respBytes[5] == 0x1F && respBytes[6] == 0x8B) {
             print("<-- gRPC: Trying to decompress partial/broken frame...");
             payload = respBytes.sublist(5);
          } else {
             throw Exception("Incomplete gRPC response");
          }
       } else {
          payload = respBytes.sublist(5, 5 + len);
       }
       
       Uint8List decodedPayload;
       // Check for Gzip magic number (0x1F 0x8B)
       bool isGzip = payload.length > 2 && payload[0] == 0x1F && payload[1] == 0x8B;
       
       if (compressedFlag == 1 || isGzip) {
           print("<-- gRPC: Decompressing Gzip payload...");
           decodedPayload = Uint8List.fromList(gzip.decode(payload));
           print("<-- gRPC: Decompressed length: ${decodedPayload.length}");
       } else {
          decodedPayload = payload;
       }
       
       print("<-- gRPC: Parsing Protobuf...");
       final reply = DmViewReply.parse(decodedPayload);
       print("<-- gRPC: Parsed subtitles count: ${reply.subtitles.length}");
       
       return reply.subtitles.map((s) {
         print("    Subtitle: ${s.lan} (${s.lanDoc}) -> ${s.subtitleUrl}");
         return BilibiliSubtitle(
           id: s.subtitleUrl.hashCode.toString(), 
           lan: s.lan,
           lanDoc: s.lanDoc.isEmpty ? SubtitleUtil.getLanguageName(s.lan) : s.lanDoc,
           url: s.subtitleUrl.startsWith("//") ? "https:${s.subtitleUrl}" : s.subtitleUrl,
           isAi: s.lan.startsWith("ai-"),
         );
       }).toList();
       
    } catch (e) {
      print("gRPC error details: $e");
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
      print("Error downloading subtitle content: $e");
      return null;
    }
  }
  
  // Helper to get Dio instance for downloading
  Dio get dio => _dio;
}
