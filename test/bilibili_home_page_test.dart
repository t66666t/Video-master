import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/screens/bilibili/bilibili_home_page.dart';
import 'package:video_player_app/services/bilibili/bilibili_public_api_service.dart';

const _bvid = 'BV1GJ411x7h7';

class _FakeAdapter implements HttpClientAdapter {
  final List<RequestOptions> requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final path = options.path;
    Object body;
    if (path.endsWith('/wbi/search/type')) {
      body = {
        'code': 0,
        'data': {
          'numPages': 1,
          'result': [
            {
              'bvid': _bvid,
              'title': '<em class="keyword">测试</em>视频',
              'author': 'UP甲',
              'duration': '3:05',
              'play': 23456,
            },
          ],
        },
      };
    } else if (path.endsWith('/x/web-interface/view')) {
      body = {
        'code': 0,
        'data': {
          'bvid': _bvid,
          'title': '详情标题',
          'desc': '上一集 BV1xx411c7mD',
          'owner': {'mid': 1, 'name': 'UP甲'},
          'stat': {'view': 100, 'like': 20},
          'pages': [
            {'cid': 1, 'page': 1, 'part': '第一部分'},
            {'cid': 2, 'page': 2, 'part': '第二部分'},
          ],
        },
      };
    } else if (path.endsWith('/x/tag/archive/tags')) {
      body = {
        'code': 0,
        'data': [
          {'tag_name': '标签一'},
        ],
      };
    } else {
      body = {'code': 0, 'result': {}};
    }
    return ResponseBody.fromString(
      jsonEncode(body),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  testWidgets('search shows videos and opens the detail page', (tester) async {
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final adapter = _FakeAdapter();
    final api = BilibiliPublicApiService(httpClientAdapter: adapter);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: BilibiliHomePage(isActive: true, api: api)),
      ),
    );
    expect(find.text('输入关键词搜索 B 站内容'), findsOneWidget);
    expect(adapter.requests, isEmpty);

    await tester.enterText(find.byType(TextField), '测试');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();

    expect(find.text('测试视频'), findsOneWidget);
    expect(find.text('03:05'), findsOneWidget);
    expect(find.text('没有更多了'), findsOneWidget);

    await tester.tap(find.text('测试视频'));
    await tester.pumpAndSettle();

    expect(find.text('详情标题'), findsOneWidget);
    expect(find.text('播放'), findsOneWidget);
    expect(find.text('导入为卡片'), findsOneWidget);
    expect(find.text('下载'), findsOneWidget);
    expect(find.text('分P（2）'), findsOneWidget);
    expect(find.text('标签一'), findsOneWidget);
    for (final request in adapter.requests) {
      expect(
        request.headers.keys.map((k) => k.toLowerCase()),
        isNot(contains('cookie')),
      );
    }
  });

  testWidgets('a BV id opens detail directly without searching', (
    tester,
  ) async {
    final adapter = _FakeAdapter();
    final api = BilibiliPublicApiService(httpClientAdapter: adapter);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: BilibiliHomePage(isActive: true, api: api)),
      ),
    );
    await tester.enterText(find.byType(TextField), _bvid);
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();

    expect(find.text('详情标题'), findsOneWidget);
    expect(
      adapter.requests.where((r) => r.path.endsWith('/wbi/search/type')),
      isEmpty,
    );
  });
}
