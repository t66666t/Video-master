import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/services/bilibili/bilibili_api_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_cookie_store.dart';
import 'package:video_player_app/services/bilibili/bilibili_interaction_gate.dart';

const _sessdata = 'sess-secret-value-123';
const _jct = 'jct-secret-value-456';
final _like = Uri.parse(
  'https://api.bilibili.com/x/web-interface/archive/like',
);

class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.respond);

  ResponseBody Function(RequestOptions options) respond;
  final List<RequestOptions> requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return respond(options);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _json(Object body, {int status = 200}) => ResponseBody.fromString(
  jsonEncode(body),
  status,
  headers: {
    Headers.contentTypeHeader: [Headers.jsonContentType],
  },
);

class _MemoryStorage implements BilibiliSecretStorage {
  @override
  Future<String?> read(String key) async => null;
  @override
  Future<void> write(String key, String value) async {}
  @override
  Future<void> delete(String key) async {}
}

/// Login source that counts logouts, so tests can see -101 keeps the login.
class _FakeApi extends BilibiliApiService {
  _FakeApi(this.cookies)
    : super(cookieStore: BilibiliCookieStore(storage: _MemoryStorage()));

  Map<String, String> cookies;
  int logouts = 0;

  @override
  Future<Map<String, String>> readCookiesForWrite() async => cookies;

  @override
  Future<void> logout() async => logouts++;
}

void main() {
  late _FakeAdapter adapter;
  late List<String> logs;
  late bool writesAllowed;
  late Map<String, String> cookies;

  BilibiliInteractionGate gate() => BilibiliInteractionGate(
    loginCookies: () async => cookies,
    writesAllowed: () => writesAllowed,
    httpClientAdapter: adapter,
    log: logs.add,
  );

  setUp(() {
    adapter = _FakeAdapter((_) => _json({'code': 0, 'message': '0'}));
    logs = <String>[];
    writesAllowed = true;
    cookies = {'SESSDATA': _sessdata, 'bili_jct': _jct, 'DedeUserID': '42'};
  });

  tearDown(() {
    for (final line in logs) {
      expect(line, isNot(contains(_sessdata)));
      expect(line, isNot(contains(_jct)));
      expect(line, isNot(contains('SESSDATA')));
      expect(line, isNot(contains('bili_jct')));
      expect(line, isNot(contains('csrf')));
      expect(line, isNot(contains('Cookie')));
    }
  });

  test('read-only mode sends nothing', () async {
    writesAllowed = false;
    final result = await gate().post(_like, form: {'aid': '1', 'like': '1'});
    expect(result.outcome, BilibiliWriteOutcome.readOnly);
    expect(result.message, '已开启账号只读，可在 B站设置中关闭');
    expect(result.requestSent, isFalse);
    expect(adapter.requests, isEmpty);
  });

  test('without a login nothing is sent', () async {
    cookies = {'bili_jct': _jct};
    final result = await gate().post(_like, form: {'aid': '1'});
    expect(result.outcome, BilibiliWriteOutcome.notLoggedIn);
    expect(result.needsLogin, isTrue);
    expect(adapter.requests, isEmpty);

    cookies = const {};
    expect(
      (await gate().post(_like)).outcome,
      BilibiliWriteOutcome.notLoggedIn,
    );
    expect(adapter.requests, isEmpty);
  });

  test('a login source failure counts as not logged in', () async {
    final failing = BilibiliInteractionGate(
      loginCookies: () async => throw StateError('locked'),
      writesAllowed: () => true,
      httpClientAdapter: adapter,
      log: logs.add,
    );
    expect(
      (await failing.post(_like)).outcome,
      BilibiliWriteOutcome.notLoggedIn,
    );
    expect(adapter.requests, isEmpty);
  });

  test('without bili_jct nothing is sent', () async {
    cookies = {'SESSDATA': _sessdata};
    final result = await gate().post(_like, form: {'aid': '1'});
    expect(result.outcome, BilibiliWriteOutcome.missingCsrf);
    expect(result.message, contains('重新登录'));
    expect(adapter.requests, isEmpty);
  });

  test('read-only is checked before the login', () async {
    writesAllowed = false;
    cookies = const {};
    expect((await gate().post(_like)).outcome, BilibiliWriteOutcome.readOnly);
  });

  test('a normal write posts the form with csrf and login cookies', () async {
    adapter.respond = (_) => _json({
      'code': 0,
      'message': '0',
      'data': {'like': 1},
    });
    final result = await gate().post(
      _like,
      form: {'aid': '170001', 'like': '1'},
    );

    expect(result.isSuccess, isTrue);
    expect(result.code, 0);
    expect(result.data, {'like': 1});
    final request = adapter.requests.single;
    expect(request.method, 'POST');
    expect(request.uri.toString(), _like.toString());
    expect(request.contentType, startsWith(Headers.formUrlEncodedContentType));
    expect(request.data, {'aid': '170001', 'like': '1', 'csrf': _jct});
    final cookieHeader = request.headers['Cookie'] as String;
    expect(cookieHeader, contains('SESSDATA=$_sessdata'));
    expect(cookieHeader, contains('bili_jct=$_jct'));
    expect(request.headers['Referer'], 'https://www.bilibili.com/');
    expect(logs.single, '/x/web-interface/archive/like -> success code=0');
  });

  test('a caller csrf is replaced by bili_jct', () async {
    await gate().post(_like, form: {'aid': '1', 'csrf': 'forged'});
    expect((adapter.requests.single.data as Map)['csrf'], _jct);
  });

  test('-101 is an expired login and keeps the stored cookies', () async {
    adapter.respond = (_) => _json({'code': -101, 'message': '账号未登录'});
    final api = _FakeApi(cookies);
    final result = await BilibiliInteractionGate.forApi(
      api,
      writesAllowed: () => true,
      httpClientAdapter: adapter,
    ).post(_like, form: {'aid': '1'});
    expect(result.outcome, BilibiliWriteOutcome.loginExpired);
    expect(result.code, -101);
    expect(result.needsLogin, isTrue);
    expect(api.logouts, 0);
    expect(api.cookies['SESSDATA'], _sessdata);
  });

  test('risk control codes are grouped', () async {
    for (final code in [-352, -412, -509, -799]) {
      adapter.respond = (_) => _json({'code': code, 'message': 'x'});
      final result = await gate().post(_like);
      expect(
        result.outcome,
        BilibiliWriteOutcome.riskControlled,
        reason: '$code',
      );
      expect(result.message, '操作过于频繁或被风控，请稍后再试');
      expect(result.code, code);
    }
    adapter.respond = (_) => ResponseBody.fromString('blocked', 412);
    expect(
      (await gate().post(_like)).outcome,
      BilibiliWriteOutcome.riskControlled,
    );
  });

  test('other refusals carry Bilibili\'s message', () async {
    adapter.respond = (_) => _json({'code': 34005, 'message': '超过投币上限啦~'});
    final result = await gate().post(_like);
    expect(result.outcome, BilibiliWriteOutcome.failed);
    expect(result.code, 34005);
    expect(result.message, '超过投币上限啦~');
  });

  test('network trouble is reported, not thrown', () async {
    adapter.respond = (options) => throw DioException(
      requestOptions: options,
      type: DioExceptionType.connectionTimeout,
    );
    final result = await gate().post(_like);
    expect(result.outcome, BilibiliWriteOutcome.networkError);
    expect(result.requestSent, isTrue);

    adapter.respond = (_) => ResponseBody.fromString('<html>', 200);
    expect(
      (await gate().post(_like)).outcome,
      BilibiliWriteOutcome.networkError,
    );
  });

  test('only https bilibili.com endpoints are allowed', () async {
    for (final url in [
      'http://api.bilibili.com/x/web-interface/archive/like',
      'https://example.com/x/like',
      'https://bilibili.com.evil.cn/x/like',
    ]) {
      final result = await gate().post(Uri.parse(url));
      expect(result.isSuccess, isFalse, reason: url);
    }
    expect(adapter.requests, isEmpty);
  });

  test('logs name the endpoint and the result only', () async {
    adapter.respond = (_) => _json({'code': -352, 'message': '风控'});
    await gate().post(_like, form: {'aid': '1'});
    writesAllowed = false;
    await gate().post(_like);
    expect(logs, [
      '/x/web-interface/archive/like -> riskControlled code=-352',
      '/x/web-interface/archive/like -> readOnly',
    ]);
  });
}
