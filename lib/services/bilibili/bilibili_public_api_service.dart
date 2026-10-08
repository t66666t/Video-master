import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

import '../../debug/developer_log.dart' as developer;
import '../../models/bilibili_browse_models.dart';
import '../../utils/bilibili_url_parser.dart';
import 'bilibili_offline_details.dart';
import 'wbi_signer.dart';

/// User-facing error from a public Bilibili request. [message] is Chinese.
class BilibiliPublicApiException implements Exception {
  final String message;

  /// True when no answer came back at all (offline, connection failed or
  /// timed out), as opposed to Bilibili refusing the request.
  final bool isNetworkError;

  const BilibiliPublicApiException(this.message, {this.isNetworkError = false});

  @override
  String toString() => message;
}

/// Read-only Bilibili requests that never carry the login cookie: video
/// detail, tags, search and keyword suggestions.
///
/// Uses its own Dio client without a cookie interceptor, so the login session
/// held by `BilibiliApiService` is never attached. When search is blocked by
/// risk control it retries once with WBI signing and an anonymous device id
/// (`buvid3` from the public fingerprint endpoint), which is not an account
/// credential.
class BilibiliPublicApiService {
  BilibiliPublicApiService({
    HttpClientAdapter? httpClientAdapter,
    Dio? dio,
    @visibleForTesting DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now,
       _dio =
           dio ??
           Dio(
             BaseOptions(
               connectTimeout: const Duration(seconds: 10),
               receiveTimeout: const Duration(seconds: 20),
               headers: const {'User-Agent': userAgent},
               // Status codes are interpreted by this service.
               validateStatus: (_) => true,
             ),
           ) {
    if (httpClientAdapter != null) _dio.httpClientAdapter = httpClientAdapter;
  }

  static const String userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';
  static const String _api = 'https://api.bilibili.com';
  static const String _rootReferer = 'https://www.bilibili.com/';
  static const int maxSuggestions = 10;

  final Dio _dio;
  final DateTime Function() _clock;
  String? _anonymousBuvid3;
  Future<String?>? _buvidLoading;
  String? _imgKey;
  String? _subKey;
  DateTime? _wbiKeysAt;
  Future<void>? _wbiKeysLoading;

  /// How long the WBI signing keys are reused before `nav` is asked again
  /// (Bilibili rotates them about once a day).
  static const Duration wbiKeyLifetime = Duration(hours: 6);

  static String videoReferer(String bvid) =>
      'https://www.bilibili.com/video/$bvid/';

  // ---------------------------------------------------------------- detail

  /// Loads the video detail. Tags are fetched separately and a tag failure
  /// leaves [BilibiliVideoDetail.tags] empty instead of failing the page.
  Future<BilibiliVideoDetail> fetchVideoDetail({String? bvid, int? aid}) async {
    final hasBvid = bvid != null && isValidBvid(bvid);
    if (!hasBvid && (aid == null || aid <= 0)) {
      throw const BilibiliPublicApiException('无效的视频编号');
    }
    final query = <String, dynamic>{if (hasBvid) 'bvid': bvid else 'aid': aid};
    final referer = hasBvid
        ? videoReferer(bvid)
        : 'https://www.bilibili.com/video/av$aid/';
    var payload = await _getJson(
      '$_api/x/web-interface/view',
      query: query,
      referer: referer,
      what: '视频详情',
      allowRiskStatus: true,
    );
    if (_isRiskControl(payload)) {
      developer.log('Bilibili detail hit risk control, retrying once signed');
      payload = await _getJson(
        '$_api/x/web-interface/wbi/view',
        query: await _signedQuery(query),
        referer: referer,
        what: '视频详情',
        anonymousCookie: await _ensureAnonymousBuvid(),
        allowRiskStatus: true,
      );
    }
    if (_isRiskControl(payload)) {
      throw const BilibiliPublicApiException('请求被 B 站暂时拦截，请稍后再试');
    }
    if (payload['code'] != 0) {
      throw BilibiliPublicApiException(_detailError(payload['code']));
    }
    final detail = BilibiliVideoDetail.tryParse(readBiliMap(payload['data']));
    if (detail == null) {
      throw const BilibiliPublicApiException('视频详情数据不完整');
    }
    final tags = await fetchVideoTags(detail.bvid);
    final complete = tags.isEmpty ? detail : detail.withTags(tags);
    // Kept for the panel of a downloaded video when offline.
    unawaited(BilibiliOfflineDetails.instance.rememberDetail(complete));
    return complete;
  }

  /// Never throws; returns an empty list on any failure.
  Future<List<String>> fetchVideoTags(String bvid) async {
    if (!isValidBvid(bvid)) return const <String>[];
    try {
      final payload = await _getJson(
        '$_api/x/tag/archive/tags',
        query: {'bvid': bvid},
        referer: videoReferer(bvid),
        what: '视频标签',
      );
      if (payload['code'] != 0) return const <String>[];
      return parseBilibiliTags(payload['data']);
    } catch (e) {
      developer.log('Bilibili tags unavailable', error: e.runtimeType);
      return const <String>[];
    }
  }

  String _detailError(Object? raw) {
    return switch (raw) {
      -404 || 62002 => '视频不存在或已被删除',
      62004 => '视频正在审核中',
      62012 => '该视频仅 UP 主自己可见',
      -403 => '没有权限查看该视频',
      _ => 'B 站返回错误（$raw），请稍后重试',
    };
  }

  // ---------------------------------------------------------------- search

  Future<BilibiliSearchPage<BilibiliSearchVideo>> searchVideos(
    String keyword, {
    int page = 1,
    BilibiliVideoSearchFilter filter = const BilibiliVideoSearchFilter(),
    DateTime? now,
  }) async {
    final query = <String, dynamic>{
      'search_type': 'video',
      'keyword': _requireKeyword(keyword),
      'page': _safePage(page),
      'order': filter.order.apiValue,
      'duration': filter.duration.apiValue,
    };
    final window = filter.published.window;
    if (window != null) {
      final end =
          (now ?? DateTime.now()).toUtc().millisecondsSinceEpoch ~/ 1000;
      query['pubtime_begin_s'] = end - window.inSeconds;
      query['pubtime_end_s'] = end;
    }
    final data = await _search(query);
    final items = <BilibiliSearchVideo>[];
    final seen = <String>{};
    for (final raw in readBiliMapList(data['result'])) {
      final item = BilibiliSearchVideo.tryParse(raw);
      if (item != null && seen.add(item.bvid)) items.add(item);
    }
    return BilibiliSearchPage<BilibiliSearchVideo>(
      items: List<BilibiliSearchVideo>.unmodifiable(items),
      page: query['page'] as int,
      numPages: readBiliInt(data['numPages']),
    );
  }

  Future<BilibiliSearchPage<BilibiliSearchUser>> searchUsers(
    String keyword, {
    int page = 1,
  }) async {
    final query = <String, dynamic>{
      'search_type': 'bili_user',
      'keyword': _requireKeyword(keyword),
      'page': _safePage(page),
    };
    final data = await _search(query);
    final items = <BilibiliSearchUser>[];
    final seen = <int>{};
    for (final raw in readBiliMapList(data['result'])) {
      final item = BilibiliSearchUser.tryParse(raw);
      if (item != null && seen.add(item.mid)) items.add(item);
    }
    return BilibiliSearchPage<BilibiliSearchUser>(
      items: List<BilibiliSearchUser>.unmodifiable(items),
      page: query['page'] as int,
      numPages: readBiliInt(data['numPages']),
    );
  }

  /// Keyword suggestions, at most [maxSuggestions]. Never throws.
  Future<List<String>> suggestKeywords(String input) async {
    final term = input.trim();
    if (term.isEmpty) return const <String>[];
    try {
      final payload = await _getJson(
        'https://s.search.bilibili.com/main/suggest',
        query: {'term': term, 'main_ver': 'v1'},
        referer: _rootReferer,
        what: '搜索建议',
      );
      return parseBilibiliSuggestions(payload);
    } catch (e) {
      developer.log('Bilibili suggestions unavailable', error: e.runtimeType);
      return const <String>[];
    }
  }

  static List<String> parseBilibiliSuggestions(Map<String, dynamic> payload) {
    final result = payload['result'];
    final Object? tags = result is Map ? result['tag'] : result;
    final out = <String>[];
    final seen = <String>{};
    for (final item in readBiliMapList(tags)) {
      final value = readBiliText(item['value'], readBiliText(item['term']));
      if (value.isEmpty || !seen.add(value)) continue;
      out.add(value);
      if (out.length >= maxSuggestions) break;
    }
    return List<String>.unmodifiable(out);
  }

  Future<Map<String, dynamic>> _search(Map<String, dynamic> query) async {
    final keyword = query['keyword'] as String;
    final referer =
        'https://search.bilibili.com/all?keyword=${Uri.encodeQueryComponent(keyword)}';
    var payload = await _getJson(
      '$_api/x/web-interface/wbi/search/type',
      query: query,
      referer: referer,
      what: '搜索',
      allowRiskStatus: true,
    );
    if (_isRiskControl(payload)) {
      developer.log('Bilibili search hit risk control, retrying once signed');
      final signed = await _signedQuery(query);
      payload = await _getJson(
        '$_api/x/web-interface/wbi/search/type',
        query: signed,
        referer: referer,
        what: '搜索',
        anonymousCookie: await _ensureAnonymousBuvid(),
        allowRiskStatus: true,
      );
    }
    if (_isRiskControl(payload)) {
      throw const BilibiliPublicApiException('搜索请求被 B 站暂时拦截，请稍后再试');
    }
    if (payload['code'] != 0) {
      throw BilibiliPublicApiException('搜索失败（${payload['code']}），请稍后重试');
    }
    return readBiliMap(payload['data']);
  }

  bool _isRiskControl(Map<String, dynamic> payload) {
    final code = payload['code'];
    return code == -412 || code == -352 || payload['__http'] == 412;
  }

  Future<Map<String, dynamic>> _signedQuery(Map<String, dynamic> query) async {
    try {
      await _ensureWbiKeys();
      final img = _imgKey;
      final sub = _subKey;
      if (img == null || sub == null) return query;
      return WbiSigner.sign(query, img, sub);
    } catch (e) {
      developer.log('Bilibili WBI keys unavailable', error: e.runtimeType);
      return query;
    }
  }

  /// The WBI keys, reused for [wbiKeyLifetime]; concurrent callers share one
  /// `nav` request.
  Future<void> _ensureWbiKeys() {
    final at = _wbiKeysAt;
    if (_imgKey != null &&
        _subKey != null &&
        at != null &&
        _clock().difference(at) < wbiKeyLifetime) {
      return Future<void>.value();
    }
    final running = _wbiKeysLoading;
    if (running != null) return running;
    final loading = _fetchWbiKeys();
    _wbiKeysLoading = loading;
    return loading.whenComplete(() {
      if (identical(_wbiKeysLoading, loading)) _wbiKeysLoading = null;
    });
  }

  Future<void> _fetchWbiKeys() async {
    // nav answers -101 when signed out but still returns the WBI keys.
    final nav = await _getJson(
      '$_api/x/web-interface/nav',
      referer: _rootReferer,
      what: '签名密钥',
    );
    final wbi = readBiliMap(readBiliMap(nav['data'])['wbi_img']);
    String keyOf(Object? url) =>
        readBiliText(url).split('/').last.split('.').first;
    final img = keyOf(wbi['img_url']);
    final sub = keyOf(wbi['sub_url']);
    if (img.length + sub.length < 64) return;
    _imgKey = img;
    _subKey = sub;
    _wbiKeysAt = _clock();
  }

  /// The public device id, asked once per run; concurrent callers share one
  /// request and a failure is asked again next time.
  Future<String?> _ensureAnonymousBuvid() {
    final known = _anonymousBuvid3;
    if (known != null) return Future<String?>.value(known);
    final running = _buvidLoading;
    if (running != null) return running;
    final loading = _fetchAnonymousBuvid();
    _buvidLoading = loading;
    return loading.whenComplete(() {
      if (identical(_buvidLoading, loading)) _buvidLoading = null;
    });
  }

  Future<String?> _fetchAnonymousBuvid() async {
    try {
      final spi = await _getJson(
        '$_api/x/frontend/finger/spi',
        referer: _rootReferer,
        what: '设备标识',
      );
      final b3 = readBiliText(readBiliMap(spi['data'])['b_3']);
      if (b3.isNotEmpty) _anonymousBuvid3 = b3;
    } catch (e) {
      developer.log('Bilibili anonymous id unavailable', error: e.runtimeType);
    }
    return _anonymousBuvid3;
  }

  // ------------------------------------------------------- other readers

  /// Cookie-free GET for other public readers (e.g. uploader data) on
  /// `api.bilibili.com`. [path] starts with `/x/`.
  ///
  /// [signed] adds WBI signing with the shared [WbiSigner] (falls back to
  /// the plain query when the keys are unavailable). [anonymousDevice] sends
  /// only the public `buvid3` device id, never the login cookie.
  ///
  /// HTTP 412 comes back as `{'code': -412}` so callers can treat it as risk
  /// control; see [isRiskControlPayload]. Network, other HTTP and parse
  /// failures throw [BilibiliPublicApiException].
  Future<Map<String, dynamic>> getPublicJson(
    String path, {
    Map<String, dynamic> query = const <String, dynamic>{},
    required String referer,
    required String what,
    bool signed = false,
    bool anonymousDevice = false,
  }) async {
    if (!path.startsWith('/x/')) {
      throw BilibiliPublicApiException('$what请求地址无效');
    }
    return _getJson(
      '$_api$path',
      query: signed ? await _signedQuery(query) : query,
      referer: referer,
      what: what,
      anonymousCookie: anonymousDevice ? await _ensureAnonymousBuvid() : null,
      allowRiskStatus: true,
    );
  }

  /// Risk control / rate limiting: -352, -412, -799 or HTTP 412.
  static bool isRiskControlPayload(Map<String, dynamic> payload) {
    final code = payload['code'];
    return code == -352 ||
        code == -412 ||
        code == -799 ||
        payload['__http'] == 412;
  }

  // ------------------------------------------------------------ short link

  /// Resolves a b23.tv short link without the login cookie: https only, at
  /// most [kBilibiliShortLinkMaxRedirects] redirects within [timeout], and
  /// never leaving Bilibili. Never throws; see [BilibiliShortLinkResult].
  Future<BilibiliShortLinkResult> resolveShortLink(
    Uri link, {
    Duration timeout = kBilibiliShortLinkTimeout,
  }) async {
    final cancel = CancelToken();
    try {
      return await resolveBilibiliShortLink(
        link,
        timeout: timeout,
        fetchRedirect: (url) async {
          final response = await _dio.getUri<dynamic>(
            url,
            cancelToken: cancel,
            options: Options(
              followRedirects: false,
              responseType: ResponseType.plain,
              headers: const {'Referer': _rootReferer},
            ),
          );
          final status = response.statusCode ?? 0;
          final location = response.headers.value('location');
          if (status < 300 || status >= 400 || location == null) return null;
          return Uri.tryParse(location.trim());
        },
      );
    } finally {
      // Drops a request still in flight after a timeout.
      cancel.cancel();
    }
  }

  // ---------------------------------------------------------------- shared

  String _requireKeyword(String keyword) {
    final text = keyword.trim();
    if (text.isEmpty) {
      throw const BilibiliPublicApiException('请输入搜索关键词');
    }
    return text;
  }

  int _safePage(int page) => page.clamp(1, kBilibiliSearchMaxPages).toInt();

  /// GET without the login cookie. [anonymousCookie] is only the public
  /// device id used for the risk-control retry.
  Future<Map<String, dynamic>> _getJson(
    String url, {
    Map<String, dynamic>? query,
    required String referer,
    required String what,
    String? anonymousCookie,
    bool allowRiskStatus = false,
  }) async {
    final Response<dynamic> response;
    try {
      response = await _dio.get<dynamic>(
        url,
        queryParameters: query,
        options: Options(
          responseType: ResponseType.plain,
          headers: {
            'Accept': 'application/json, text/plain, */*',
            'Referer': referer,
            if (anonymousCookie != null) 'Cookie': 'buvid3=$anonymousCookie',
          },
        ),
      );
    } on DioException catch (e) {
      developer.log('Bilibili public request failed: $what', error: e.type);
      throw BilibiliPublicApiException(
        '$what加载失败，请检查网络后重试',
        isNetworkError:
            e.type != DioExceptionType.badResponse &&
            e.type != DioExceptionType.cancel &&
            e.type != DioExceptionType.badCertificate,
      );
    }
    final status = response.statusCode ?? 0;
    if (status == 412 && allowRiskStatus) {
      return const <String, dynamic>{'code': -412, '__http': 412};
    }
    if (status != 200) {
      throw BilibiliPublicApiException('$what暂时不可用（HTTP $status）');
    }
    final body = response.data;
    Object? decoded = body;
    if (body is String) {
      try {
        decoded = jsonDecode(body);
      } on FormatException {
        throw BilibiliPublicApiException('$what返回的数据无法解析');
      }
    }
    if (decoded is! Map) {
      throw BilibiliPublicApiException('$what返回的数据无法解析');
    }
    return readBiliMap(decoded);
  }
}
