import 'dart:convert';

import 'package:dio/dio.dart';

import '../../debug/developer_log.dart' as developer;
import '../settings_service.dart';
import 'bilibili_api_service.dart';

/// How an account write ended. Only [success], [loginExpired],
/// [riskControlled], [failed] and [networkError] mean a request was sent.
enum BilibiliWriteOutcome {
  success,

  /// Account read-only mode is on; nothing was sent.
  readOnly,

  /// No SESSDATA; nothing was sent.
  notLoggedIn,

  /// Logged in but without bili_jct, so there is no csrf; nothing was sent.
  missingCsrf,

  /// The write's own parameters were out of range (checked at run time, also
  /// in release builds); nothing was sent.
  invalidRequest,

  /// Bilibili answered -101. The stored login is kept as it is.
  loginExpired,

  /// Rate limited or blocked by risk control (-352, -412, -509, -799 or
  /// HTTP 412).
  riskControlled,

  /// Bilibili refused the request; see the result message.
  failed,

  /// The request did not get a usable answer.
  networkError,
}

/// Result of [BilibiliInteractionGate.post]. [message] is user-facing text
/// (Bilibili's own message where it gave one) and never holds cookie values.
class BilibiliWriteResult {
  final BilibiliWriteOutcome outcome;

  /// Bilibili business code, when a JSON answer came back.
  final int? code;
  final String message;

  /// `data` of a successful answer.
  final Object? data;

  const BilibiliWriteResult(
    this.outcome, {
    required this.message,
    this.code,
    this.data,
  });

  bool get isSuccess => outcome == BilibiliWriteOutcome.success;

  /// False when the gate stopped the write before any request.
  bool get requestSent => switch (outcome) {
    BilibiliWriteOutcome.readOnly ||
    BilibiliWriteOutcome.notLoggedIn ||
    BilibiliWriteOutcome.missingCsrf ||
    BilibiliWriteOutcome.invalidRequest => false,
    _ => true,
  };

  /// The user has to log in (again) before retrying.
  bool get needsLogin => switch (outcome) {
    BilibiliWriteOutcome.notLoggedIn ||
    BilibiliWriteOutcome.missingCsrf ||
    BilibiliWriteOutcome.loginExpired => true,
    _ => false,
  };
}

/// The single door for requests that change the Bilibili account (like,
/// coin, favourite, follow, ...). Nothing else in the app may send such a
/// request.
///
/// In order it checks read-only mode, the login (SESSDATA) and the csrf
/// token (bili_jct); any failed check returns without touching the network.
/// Otherwise it posts the form with the login cookies and `csrf`, and turns
/// the answer into a [BilibiliWriteResult]. Logs carry only the endpoint
/// path and the result code.
class BilibiliInteractionGate {
  BilibiliInteractionGate({
    required Future<Map<String, String>> Function() loginCookies,
    bool Function()? writesAllowed,
    HttpClientAdapter? httpClientAdapter,
    void Function(String line)? log,
  }) : _loginCookies = loginCookies,
       _writesAllowed =
           writesAllowed ??
           (() => SettingsService().bilibiliAccountWritesAllowed),
       _log = log ?? _defaultLog,
       _dio = Dio(
         BaseOptions(
           connectTimeout: const Duration(seconds: 10),
           receiveTimeout: const Duration(seconds: 15),
           headers: const {
             'User-Agent': _userAgent,
             'Referer': 'https://www.bilibili.com/',
             'Origin': 'https://www.bilibili.com',
             'Accept': 'application/json, text/plain, */*',
           },
         ),
       ) {
    if (httpClientAdapter != null) _dio.httpClientAdapter = httpClientAdapter;
  }

  /// Gate over the live login of [api].
  factory BilibiliInteractionGate.forApi(
    BilibiliApiService api, {
    bool Function()? writesAllowed,
    HttpClientAdapter? httpClientAdapter,
  }) {
    return BilibiliInteractionGate(
      loginCookies: api.readCookiesForWrite,
      writesAllowed: writesAllowed,
      httpClientAdapter: httpClientAdapter,
    );
  }

  static const String _userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

  /// Codes Bilibili uses for "too frequent" or risk control.
  static const Set<int> riskControlCodes = <int>{-352, -412, -509, -799};

  static const String readOnlyMessage = '已开启账号只读，可在 B站设置中关闭';
  static const String notLoggedInMessage = '请先登录 B 站';
  static const String missingCsrfMessage = '登录信息不完整，请重新登录';
  static const String loginExpiredMessage = '登录已过期，请重新登录';
  static const String riskControlledMessage = '操作过于频繁或被风控，请稍后再试';
  static const String networkErrorMessage = '网络异常，操作未完成';

  final Future<Map<String, String>> Function() _loginCookies;
  final bool Function() _writesAllowed;
  final void Function(String line) _log;
  final Dio _dio;

  static void _defaultLog(String line) =>
      developer.log(line, name: 'BilibiliWrite');

  /// Runs the same read-only / login / csrf checks as [post] without sending
  /// anything. Returns the blocking result, or null when a write could go
  /// out. Use it before opening a dialog (coins, favourites, unfollow) so a
  /// blocked user is not asked to choose first.
  Future<BilibiliWriteResult?> precheck() async =>
      (await _checkAccess('precheck')).$1;

  Future<(BilibiliWriteResult?, Map<String, String>)> _checkAccess(
    String name,
  ) async {
    const none = <String, String>{};
    if (!_writesAllowed()) {
      _log('$name -> readOnly');
      return (
        const BilibiliWriteResult(
          BilibiliWriteOutcome.readOnly,
          message: readOnlyMessage,
        ),
        none,
      );
    }
    Map<String, String> cookies;
    try {
      cookies = await _loginCookies();
    } catch (e) {
      _log('$name -> login unavailable (${e.runtimeType})');
      cookies = none;
    }
    if ((cookies['SESSDATA'] ?? '').isEmpty) {
      _log('$name -> notLoggedIn');
      return (
        const BilibiliWriteResult(
          BilibiliWriteOutcome.notLoggedIn,
          message: notLoggedInMessage,
        ),
        none,
      );
    }
    if ((cookies['bili_jct'] ?? '').isEmpty) {
      _log('$name -> missingCsrf');
      return (
        const BilibiliWriteResult(
          BilibiliWriteOutcome.missingCsrf,
          message: missingCsrfMessage,
        ),
        none,
      );
    }
    return (null, cookies);
  }

  /// Posts [form] to [endpoint] (https, a bilibili.com host) as the logged-in
  /// user. `csrf` is added from bili_jct; callers never pass it.
  Future<BilibiliWriteResult> post(
    Uri endpoint, {
    Map<String, String> form = const <String, String>{},
  }) async {
    final name = endpoint.path;
    if (!_isBilibiliEndpoint(endpoint)) {
      _log('$name -> rejected endpoint');
      return const BilibiliWriteResult(
        BilibiliWriteOutcome.failed,
        message: '不支持的 B 站接口',
      );
    }
    final (blocked, cookies) = await _checkAccess(name);
    if (blocked != null) return blocked;
    final csrf = cookies['bili_jct']!;

    final body = <String, String>{...form, 'csrf': csrf};
    final Response<dynamic> response;
    try {
      response = await _dio.postUri<dynamic>(
        endpoint,
        data: body,
        options: Options(
          contentType: Headers.formUrlEncodedContentType,
          responseType: ResponseType.plain,
          validateStatus: (_) => true,
          headers: {'Cookie': _cookieHeader(cookies)},
        ),
      );
    } on DioException catch (e) {
      _log('$name -> networkError (${e.type.name})');
      return const BilibiliWriteResult(
        BilibiliWriteOutcome.networkError,
        message: networkErrorMessage,
      );
    } catch (e) {
      _log('$name -> networkError (${e.runtimeType})');
      return const BilibiliWriteResult(
        BilibiliWriteOutcome.networkError,
        message: networkErrorMessage,
      );
    }
    final result = classifyResponse(
      statusCode: response.statusCode,
      body: response.data,
    );
    _log(
      '$name -> ${result.outcome.name}'
      '${result.code == null ? '' : ' code=${result.code}'}'
      '${response.statusCode == 200 ? '' : ' http=${response.statusCode}'}',
    );
    return result;
  }

  /// Maps an HTTP status and body to a result.
  static BilibiliWriteResult classifyResponse({
    required int? statusCode,
    required Object? body,
  }) {
    if (statusCode == 412) {
      return const BilibiliWriteResult(
        BilibiliWriteOutcome.riskControlled,
        message: riskControlledMessage,
      );
    }
    Object? payload = body;
    if (payload is String) {
      try {
        payload = jsonDecode(payload);
      } on FormatException {
        payload = null;
      }
    }
    if (payload is! Map) {
      return BilibiliWriteResult(
        BilibiliWriteOutcome.networkError,
        message: statusCode == 200 ? 'B 站返回了无法识别的结果' : '请求失败（HTTP $statusCode）',
      );
    }
    final code = (payload['code'] as num?)?.toInt();
    final remote = (payload['message'] ?? payload['msg'] ?? '')
        .toString()
        .trim();
    if (code == 0) {
      return BilibiliWriteResult(
        BilibiliWriteOutcome.success,
        code: 0,
        message: remote.isEmpty || remote == '0' ? '操作成功' : remote,
        data: payload['data'],
      );
    }
    if (code == -101) {
      return BilibiliWriteResult(
        BilibiliWriteOutcome.loginExpired,
        code: code,
        message: loginExpiredMessage,
      );
    }
    if (code != null && riskControlCodes.contains(code)) {
      return BilibiliWriteResult(
        BilibiliWriteOutcome.riskControlled,
        code: code,
        message: riskControlledMessage,
      );
    }
    return BilibiliWriteResult(
      BilibiliWriteOutcome.failed,
      code: code,
      message: remote.isEmpty ? '操作失败（${code ?? statusCode}）' : remote,
    );
  }

  static bool _isBilibiliEndpoint(Uri uri) {
    final host = uri.host.toLowerCase();
    return uri.scheme == 'https' &&
        (host == 'bilibili.com' || host.endsWith('.bilibili.com'));
  }

  static String _cookieHeader(Map<String, String> cookies) => [
    for (final entry in cookies.entries) '${entry.key}=${entry.value}',
  ].join('; ');
}
