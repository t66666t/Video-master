import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/bilibili_browse_models.dart';
import 'package:video_player_app/services/bilibili/bilibili_interaction_gate.dart';
import 'package:video_player_app/services/bilibili/bilibili_video_actions.dart';
import 'package:video_player_app/services/bilibili/bilibili_video_detail_cache.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/utils/app_toast.dart';
import 'package:video_player_app/widgets/bilibili_player_panel.dart';

const _bvid = 'BV1xx411c7mD';

BilibiliVideoDetail _detail() => const BilibiliVideoDetail(
  bvid: _bvid,
  title: '面板标题',
  description: '简介正文',
  owner: BilibiliVideoOwner(mid: 7, name: '测试UP'),
  stat: BilibiliVideoStat(view: 1200, like: 30),
  parts: <BilibiliVideoPart>[
    BilibiliVideoPart(cid: 1, page: 1, title: '第一节'),
    BilibiliVideoPart(cid: 2, page: 2, title: '第二节'),
    BilibiliVideoPart(cid: 3, page: 3, title: '第三节'),
  ],
  season: BilibiliVideoSeason(
    id: 9,
    title: '系列',
    episodes: <BilibiliSeasonEpisode>[
      BilibiliSeasonEpisode(bvid: _bvid, title: '本集'),
      BilibiliSeasonEpisode(bvid: 'BV1bb411c7mB', title: '下一集'),
    ],
  ),
  tags: <String>['标签甲', '标签乙'],
);

/// Account actions that never reach the network: reads fail (states stay
/// unknown) and the write gate has no login and an adapter that refuses.
BilibiliVideoActions _offlineActions() => BilibiliVideoActions(
  readData: (_) async => throw StateError('no network in tests'),
  gate: BilibiliInteractionGate(
    loginCookies: () async => const <String, String>{},
    writesAllowed: () => false,
    httpClientAdapter: _RefusingAdapter(),
    log: (_) {},
  ),
  hasLogin: () async => false,
  accountMid: () async => 0,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    SettingsService().resetForTest();
  });

  Future<void> pumpPanel(
    WidgetTester tester, {
    required BilibiliVideoDetailCache cache,
    int page = 2,
    VoidCallback? onCollapse,
    VoidCallback? onOpenEpisodes,
    List<String>? watched,
    BilibiliVideoActions? actions,
  }) async {
    tester.view.physicalSize = const Size(420, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: AppToast.navigatorKey,
        home: Scaffold(
          body: BilibiliPlayerPanel(
            bvid: _bvid,
            page: page,
            fallbackTitle: '卡片标题',
            cache: cache,
            actions: actions,
            onCollapse: onCollapse,
            onOpenEpisodes: onOpenEpisodes,
            onWatchVideo: (context, {required bvid, page, startAt}) async {
              watched?.add('$bvid#${page ?? 0}');
            },
          ),
        ),
      ),
    );
  }

  Future<void> finish(WidgetTester tester) async {
    await AppToast.dismiss(immediate: true);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  }

  testWidgets('shows every block of the detail', (tester) async {
    final cache = BilibiliVideoDetailCache(fetch: (_) async => _detail());
    await pumpPanel(tester, cache: cache, actions: _offlineActions());
    await tester.pumpAndSettle();

    expect(find.text('哔哩哔哩'), findsOneWidget);
    expect(find.text('面板标题'), findsOneWidget);
    expect(find.text('测试UP'), findsOneWidget);
    expect(find.byKey(const ValueKey('bilibili-panel-stats')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('bilibili-action-like')),
      findsOneWidget,
      reason: 'like / coin / favourite bar',
    );
    expect(find.text('导入'), findsWidgets);
    expect(
      find.byKey(const ValueKey('bilibili-panel-download')),
      findsOneWidget,
    );
    expect(find.text('合集 · 系列（2）'), findsOneWidget);
    expect(find.text('标签甲'), findsOneWidget);
    expect(find.text('简介正文', findRichText: true), findsOneWidget);
    // No play button and no big cover: the video is already playing.
    expect(find.text('播放'), findsNothing);
    await finish(tester);
  });

  testWidgets('the part list entry opens the player\'s own list', (
    tester,
  ) async {
    var opened = 0;
    final cache = BilibiliVideoDetailCache(fetch: (_) async => _detail());
    await pumpPanel(tester, cache: cache, onOpenEpisodes: () => opened++);
    await tester.pumpAndSettle();

    expect(find.text('选集（3）'), findsOneWidget);
    expect(find.text('P2 第二节'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('bilibili-panel-episodes')));
    expect(opened, 1);
    await finish(tester);
  });

  testWidgets('no part list entry without a list to open', (tester) async {
    final cache = BilibiliVideoDetailCache(fetch: (_) async => _detail());
    await pumpPanel(tester, cache: cache);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('bilibili-panel-episodes')), findsNothing);
    await finish(tester);
  });

  testWidgets('a collection entry plays in place of this page', (tester) async {
    final watched = <String>[];
    final cache = BilibiliVideoDetailCache(fetch: (_) async => _detail());
    await pumpPanel(tester, cache: cache, watched: watched);
    await tester.pumpAndSettle();

    await tester.tap(find.text('本集'));
    await tester.tap(find.text('下一集'));
    await tester.pump();
    expect(watched, <String>['BV1bb411c7mB#1']);
    await finish(tester);
  });

  testWidgets('collapse button', (tester) async {
    var collapsed = 0;
    final cache = BilibiliVideoDetailCache(fetch: (_) async => _detail());
    await pumpPanel(tester, cache: cache, onCollapse: () => collapsed++);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('bilibili-panel-collapse')));
    expect(collapsed, 1);
    await finish(tester);
  });

  testWidgets('a failed request shows the card title and a retry, '
      'never a spinner', (tester) async {
    var fail = true;
    var asked = 0;
    final cache = BilibiliVideoDetailCache(
      fetch: (_) async {
        asked++;
        if (fail) throw StateError('offline');
        return _detail();
      },
    );
    await pumpPanel(tester, cache: cache);
    await tester.pumpAndSettle();

    expect(find.text('卡片标题'), findsOneWidget);
    expect(find.byKey(const ValueKey('bilibili-panel-failed')), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('正在加载详情…'), findsNothing);

    fail = false;
    await tester.tap(find.byKey(const ValueKey('bilibili-panel-retry')));
    await tester.pumpAndSettle();
    expect(asked, 2);
    expect(find.text('面板标题'), findsOneWidget);
    expect(find.byKey(const ValueKey('bilibili-panel-failed')), findsNothing);
    await finish(tester);
  });

  testWidgets('a request that never answers ends in the retry hint', (
    tester,
  ) async {
    final cache = BilibiliVideoDetailCache(
      fetch: (_) => Completer<BilibiliVideoDetail>().future,
      timeout: const Duration(seconds: 5),
    );
    await pumpPanel(tester, cache: cache);
    await tester.pump();
    expect(find.text('正在加载详情…'), findsOneWidget);
    await tester.pump(const Duration(seconds: 6));
    await tester.pump();
    expect(find.byKey(const ValueKey('bilibili-panel-failed')), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await finish(tester);
  });

  testWidgets('reopening the panel uses the kept detail', (tester) async {
    var asked = 0;
    final cache = BilibiliVideoDetailCache(
      fetch: (_) async {
        asked++;
        return _detail();
      },
    );
    await pumpPanel(tester, cache: cache);
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    await pumpPanel(tester, cache: cache);
    await tester.pump();
    expect(find.text('面板标题'), findsOneWidget);
    expect(asked, 1);
    await finish(tester);
  });
}

class _RefusingAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    throw StateError('no network in tests');
  }

  @override
  void close({bool force = false}) {}
}
