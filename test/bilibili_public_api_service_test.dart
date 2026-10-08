import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/models/bilibili_browse_models.dart';
import 'package:video_player_app/services/bilibili/bilibili_public_api_service.dart';
import 'package:video_player_app/services/bilibili/wbi_signer.dart';

const _bvid = 'BV1GJ411x7h7';

typedef _Handler = ResponseBody Function(RequestOptions options);

class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.handler);

  final _Handler handler;
  final List<RequestOptions> requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return handler(options);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _json(Object body, {int status = 200}) => ResponseBody.fromString(
  jsonEncode(body),
  status,
  headers: {
    Headers.contentTypeHeader: ['application/json; charset=utf-8'],
  },
);

void main() {
  test('detail is requested without cookie and survives tag failure', () async {
    final adapter = _FakeAdapter((options) {
      if (options.path.endsWith('/x/web-interface/view')) {
        return _json({
          'code': 0,
          'data': {'bvid': _bvid, 'title': '标题', 'cid': 5},
        });
      }
      if (options.path.endsWith('/x/tag/archive/tags')) {
        return _json({'code': -500}, status: 500);
      }
      throw StateError('unexpected ${options.uri}');
    });
    final api = BilibiliPublicApiService(httpClientAdapter: adapter);

    final detail = await api.fetchVideoDetail(bvid: _bvid);

    expect(detail.title, '标题');
    expect(detail.tags, isEmpty);
    expect(adapter.requests, hasLength(2));
    for (final request in adapter.requests) {
      expect(
        request.headers.keys.map((k) => k.toLowerCase()),
        isNot(contains('cookie')),
      );
      expect(
        request.headers['Referer'],
        'https://www.bilibili.com/video/$_bvid/',
      );
    }
  });

  test('detail error codes become Chinese messages', () async {
    final api = BilibiliPublicApiService(
      httpClientAdapter: _FakeAdapter((_) => _json({'code': -404})),
    );
    await expectLater(
      api.fetchVideoDetail(bvid: _bvid),
      throwsA(
        isA<BilibiliPublicApiException>().having(
          (e) => e.message,
          'message',
          '视频不存在或已被删除',
        ),
      ),
    );
    await expectLater(
      api.fetchVideoDetail(bvid: 'nope'),
      throwsA(isA<BilibiliPublicApiException>()),
    );
  });

  test('detail falls back once to the signed endpoint on HTTP 412', () async {
    final adapter = _FakeAdapter((options) {
      final path = options.path;
      if (path.endsWith('/x/web-interface/view')) {
        return ResponseBody.fromString('<html></html>', 412);
      }
      if (path.endsWith('/x/web-interface/wbi/view')) {
        return _json({
          'code': 0,
          'data': {'bvid': _bvid, 'title': '重试成功'},
        });
      }
      if (path.endsWith('/x/web-interface/nav')) {
        return _json({
          'code': -101,
          'data': {
            'wbi_img': {
              'img_url': 'https://i0.hdslb.com/bfs/wbi/${'a' * 32}.png',
              'sub_url': 'https://i0.hdslb.com/bfs/wbi/${'b' * 32}.png',
            },
          },
        });
      }
      if (path.endsWith('/x/frontend/finger/spi')) {
        return _json({
          'code': 0,
          'data': {'b_3': 'ANON-ID'},
        });
      }
      return _json({'code': 0, 'data': []});
    });
    final api = BilibiliPublicApiService(httpClientAdapter: adapter);

    final detail = await api.fetchVideoDetail(bvid: _bvid);

    expect(detail.title, '重试成功');
    final retry = adapter.requests.singleWhere(
      (r) => r.path.endsWith('/wbi/view'),
    );
    expect(retry.headers['Cookie'], 'buvid3=ANON-ID');
    expect(retry.queryParameters['w_rid'], isA<String>());
  });

  test('video search sends filters, clamps page and dedupes', () async {
    final adapter = _FakeAdapter((options) {
      return _json({
        'code': 0,
        'data': {
          'numPages': 99,
          'result': [
            {'bvid': _bvid, 'title': '<em class="keyword">猫</em>'},
            {'bvid': _bvid, 'title': 'dup'},
            {'title': 'no id'},
          ],
        },
      });
    });
    final api = BilibiliPublicApiService(httpClientAdapter: adapter);

    final page = await api.searchVideos(
      ' 猫 ',
      page: 80,
      filter: const BilibiliVideoSearchFilter(
        order: BilibiliVideoSearchOrder.pubdate,
        duration: BilibiliVideoDurationFilter.from10To30,
        published: BilibiliPublishedFilter.lastDay,
      ),
      now: DateTime.utc(2026, 1, 2),
    );

    final query = adapter.requests.single.queryParameters;
    expect(query['keyword'], '猫');
    expect(query['page'], 50);
    expect(query['order'], 'pubdate');
    expect(query['duration'], 2);
    expect(query['search_type'], 'video');
    expect(query['pubtime_end_s'] - query['pubtime_begin_s'], 86400);
    expect(page.items.single.title, '猫');
    expect(page.hasMore, isFalse);
    expect(
      adapter.requests.single.headers.keys.map((k) => k.toLowerCase()),
      isNot(contains('cookie')),
    );
  });

  test('risk control retries once signed with an anonymous id', () async {
    var searchCalls = 0;
    final adapter = _FakeAdapter((options) {
      final path = options.path;
      if (path.endsWith('/wbi/search/type')) {
        searchCalls++;
        if (searchCalls == 1) return _json({'code': -412});
        return _json({
          'code': 0,
          'data': {
            'numPages': 1,
            'result': [
              {'mid': 3, 'uname': 'UP'},
            ],
          },
        });
      }
      if (path.endsWith('/x/web-interface/nav')) {
        return _json({
          'code': -101,
          'data': {
            'wbi_img': {
              'img_url': 'https://i0.hdslb.com/bfs/wbi/${'a' * 32}.png',
              'sub_url': 'https://i0.hdslb.com/bfs/wbi/${'b' * 32}.png',
            },
          },
        });
      }
      if (path.endsWith('/x/frontend/finger/spi')) {
        return _json({
          'code': 0,
          'data': {'b_3': 'ANON-ID', 'b_4': 'x'},
        });
      }
      throw StateError('unexpected ${options.uri}');
    });
    final api = BilibiliPublicApiService(httpClientAdapter: adapter);

    final page = await api.searchUsers('up');

    expect(page.items.single.name, 'UP');
    expect(searchCalls, 2);
    final retry = adapter.requests.lastWhere(
      (r) => r.path.endsWith('/wbi/search/type'),
    );
    expect(retry.headers['Cookie'], 'buvid3=ANON-ID');
    expect(retry.queryParameters['w_rid'], isA<String>());
    expect(retry.queryParameters['wts'], isA<int>());
  });

  test('suggestions are capped at 10 and tolerate text/plain bodies', () async {
    final tags = [
      for (var i = 0; i < 15; i++) {'value': 'k$i'},
    ];
    final api = BilibiliPublicApiService(
      httpClientAdapter: _FakeAdapter(
        (_) => ResponseBody.fromString(
          jsonEncode({
            'code': 0,
            'result': {'tag': tags},
          }),
          200,
          headers: {
            Headers.contentTypeHeader: ['text/plain'],
          },
        ),
      ),
    );
    final result = await api.suggestKeywords('k');
    expect(result, hasLength(10));
    expect(result.first, 'k0');

    expect(
      BilibiliPublicApiService.parseBilibiliSuggestions({'result': {}}),
      isEmpty,
    );
    final failing = BilibiliPublicApiService(
      httpClientAdapter: _FakeAdapter((_) => _json({}, status: 503)),
    );
    expect(await failing.suggestKeywords('k'), isEmpty);
  });

  test('short link follows https redirects to a video', () async {
    final adapter = _FakeAdapter((options) {
      return ResponseBody.fromString(
        '',
        302,
        headers: {
          'location': ['https://www.bilibili.com/video/$_bvid?p=2&share=1'],
        },
      );
    });
    final api = BilibiliPublicApiService(httpClientAdapter: adapter);
    final target = await api.resolveShortLink(Uri.parse('https://b23.tv/abc'));
    expect(target!.bvid, _bvid);
    expect(target.page, 2);

    final http = await api.resolveShortLink(Uri.parse('http://b23.tv/abc'));
    expect(http, isNull);
  });

  test('wbi signing keeps ascii-only parameters unchanged', () {
    final signed = WbiSigner.sign(
      {'bvid': _bvid, 'cid': 123, 'keyword': "it's(1)"},
      'a' * 32,
      'b' * 32,
    );
    expect(signed['bvid'], _bvid);
    expect(signed['cid'], 123);
    expect(signed['keyword'], 'its1');
    expect(signed['w_rid'], hasLength(32));
  });
}
