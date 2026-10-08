import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/bilibili_browse_models.dart';
import 'package:video_player_app/services/bilibili/bilibili_api_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_interaction_gate.dart';
import 'package:video_player_app/services/bilibili/bilibili_offline_details.dart';
import 'package:video_player_app/services/bilibili/bilibili_public_api_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_video_actions.dart';
import 'package:video_player_app/services/bilibili/bilibili_video_detail_cache.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/utils/app_toast.dart';
import 'package:video_player_app/widgets/bilibili_player_panel.dart';

const _bvid = 'BV1xx411c7mD';

BilibiliVideoDetail _detail() => const BilibiliVideoDetail(
  bvid: _bvid,
  aid: 170001,
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
    BilibiliOfflineDetails? offlineDetails,
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
            offlineDetails: offlineDetails ?? BilibiliOfflineDetails(),
            onCollapse: onCollapse,
            onOpenEpisodes: onOpenEpisodes,
            onWatchVideo:
                (context, {required bvid, page, startAt, preview}) async {
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
    // No answer at all reads as offline.
    expect(
      find.byKey(const ValueKey('bilibili-panel-offline')),
      findsOneWidget,
    );
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await finish(tester);
  });

  testWidgets(
    'not logged in: no account reads, every action shows its default',
    (tester) async {
      final reads = <String>[];
      final actions = BilibiliVideoActions(
        readData: (uri) async {
          reads.add(uri.path);
          throw StateError('must not be called');
        },
        gate: BilibiliInteractionGate(
          loginCookies: () async => const <String, String>{},
          writesAllowed: () => false,
          httpClientAdapter: _RefusingAdapter(),
          log: (_) {},
        ),
        hasLogin: () async => false,
        accountMid: () async => 0,
      );
      final cache = BilibiliVideoDetailCache(fetch: (_) async => _detail());
      await pumpPanel(tester, cache: cache, actions: actions);
      await tester.pumpAndSettle();
      expect(reads, isEmpty);
      expect(find.text('点赞'), findsOneWidget);
      expect(find.text('投币'), findsOneWidget);
      expect(find.text('收藏'), findsOneWidget);
      expect(find.text('关注'), findsOneWidget);
      await finish(tester);
    },
  );

  testWidgets('logged in: like / coin / favourite / follow load with the '
      'account (cookie) reads and light up', (tester) async {
    final reads = <String>[];
    final cache = BilibiliVideoDetailCache(fetch: (_) async => _detail());
    await pumpPanel(
      tester,
      cache: cache,
      actions: _loggedInActions(reads: reads),
    );
    await tester.pumpAndSettle();
    expect(
      reads.toSet(),
      containsAll(<String>{
        '/x/web-interface/archive/has/like',
        '/x/web-interface/archive/coins',
        '/x/v2/fav/video/favoured',
        '/x/relation',
      }),
    );
    expect(find.text('已赞'), findsOneWidget);
    expect(find.text('已投 1'), findsOneWidget);
    expect(find.text('已收藏'), findsOneWidget);
    expect(find.text('已关注'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('account read-only still shows the states, marks the bar and '
      'sends no write', (tester) async {
    SettingsService().bilibiliAccountReadOnly = true;
    final writes = _CountingAdapter();
    final cache = BilibiliVideoDetailCache(fetch: (_) async => _detail());
    await pumpPanel(
      tester,
      cache: cache,
      actions: _loggedInActions(
        answers: <String, Object?>{'/x/web-interface/archive/has/like': 0},
        writes: writes,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('bilibili-action-read-only')), findsOne);
    expect(find.text('已收藏'), findsOneWidget, reason: 'reads still run');
    await tester.tap(find.byKey(const ValueKey('bilibili-action-like')));
    await tester.pumpAndSettle();
    expect(writes.requests, 0);
    expect(find.text('点赞'), findsOneWidget);
    expect(find.text(BilibiliInteractionGate.readOnlyMessage), findsOneWidget);
    await finish(tester);
  });

  testWidgets('an expired login (-101) shows the defaults, never "already"', (
    tester,
  ) async {
    final cache = BilibiliVideoDetailCache(fetch: (_) async => _detail());
    await pumpPanel(
      tester,
      cache: cache,
      actions: _loggedInActions(
        answers: <String, Object?>{
          '/x/web-interface/archive/has/like':
              const BilibiliAccountReadException('过期', code: -101),
          '/x/web-interface/archive/coins': const BilibiliAccountReadException(
            '过期',
            code: -101,
          ),
          '/x/v2/fav/video/favoured': const BilibiliAccountReadException(
            '过期',
            code: -101,
          ),
          '/x/relation': const BilibiliAccountReadException('过期', code: -101),
        },
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('点赞'), findsOneWidget);
    expect(find.text('投币'), findsOneWidget);
    expect(find.text('收藏'), findsOneWidget);
    expect(find.text('关注'), findsOneWidget);
    expect(find.text('已赞'), findsNothing);
    expect(find.text('已关注'), findsNothing);
    await finish(tester);
  });

  group('offline', () {
    BilibiliVideoDetailCache offlineCache() => BilibiliVideoDetailCache(
      fetch: (_) async => throw const BilibiliPublicApiException(
        '视频详情加载失败，请检查网络后重试',
        isNetworkError: true,
      ),
    );

    testWidgets('a downloaded video shows the title, UP and description it '
        'had, greyed actions and the offline hint, no error, no spinner', (
      tester,
    ) async {
      final known = BilibiliOfflineDetails();
      await known.remember(
        const BilibiliOfflineDetail(
          bvid: _bvid,
          title: '离线标题',
          ownerName: '离线UP',
          ownerMid: 7,
          description: '离线简介',
        ),
      );
      final reads = <String>[];
      await pumpPanel(
        tester,
        cache: offlineCache(),
        actions: _loggedInActions(reads: reads),
        offlineDetails: known,
      );
      await tester.pumpAndSettle();

      expect(find.text('离线标题'), findsOneWidget);
      expect(find.text('卡片标题'), findsNothing);
      expect(find.text('离线UP'), findsOneWidget);
      expect(find.text('离线简介', findRichText: true), findsOneWidget);
      expect(find.text('离线，联网后可加载'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.byKey(const ValueKey('bilibili-panel-failed')), findsNothing);
      final bar = find.byKey(const ValueKey('bilibili-panel-offline-actions'));
      expect(bar, findsOneWidget);
      final buttons = tester.widgetList<OutlinedButton>(
        find.descendant(of: bar, matching: find.byType(OutlinedButton)),
      );
      expect(buttons, hasLength(3));
      expect(buttons.every((b) => b.onPressed == null), isTrue);
      await tester.tap(find.text('点赞'), warnIfMissed: false);
      await tester.pump();
      expect(reads, isEmpty, reason: 'nothing is asked while offline');
      await finish(tester);
    });

    testWidgets('never seen online: the card title with the offline hint', (
      tester,
    ) async {
      await pumpPanel(tester, cache: offlineCache());
      await tester.pumpAndSettle();
      expect(find.text('卡片标题'), findsOneWidget);
      expect(find.text('离线，联网后可加载'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      await finish(tester);
    });

    testWidgets('back online, 重试 shows the full panel', (tester) async {
      var online = false;
      final cache = BilibiliVideoDetailCache(
        fetch: (_) async {
          if (!online) {
            throw const BilibiliPublicApiException('x', isNetworkError: true);
          }
          return _detail();
        },
      );
      await pumpPanel(tester, cache: cache, actions: _offlineActions());
      await tester.pumpAndSettle();
      expect(find.text('离线，联网后可加载'), findsOneWidget);
      online = true;
      await tester.tap(find.byKey(const ValueKey('bilibili-panel-retry')));
      await tester.pumpAndSettle();
      expect(find.text('面板标题'), findsOneWidget);
      expect(find.text('离线，联网后可加载'), findsNothing);
      await finish(tester);
    });

    test(
      'details seen online are kept, newest last, up to the capacity',
      () async {
        final store = BilibiliOfflineDetails(capacity: 2);
        await store.rememberDetail(_detail());
        await store.remember(
          const BilibiliOfflineDetail(bvid: 'BV1bb411c7mB', title: '二'),
        );
        await store.remember(
          const BilibiliOfflineDetail(bvid: 'BV1cc411c7mC', title: '三'),
        );
        // A new instance reads what was saved.
        final again = BilibiliOfflineDetails(capacity: 2);
        expect(await again.lookup(_bvid), isNull);
        expect((await again.lookup('BV1bb411c7mB'))!.title, '二');
        expect((await again.lookup('BV1cc411c7mC'))!.title, '三');

        await store.rememberDetail(_detail());
        final third = BilibiliOfflineDetails(capacity: 2);
        final kept = (await third.lookup(_bvid))!;
        expect(kept.title, '面板标题');
        expect(kept.ownerName, '测试UP');
        expect(kept.description, '简介正文');
      },
    );
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

BilibiliVideoActions _loggedInActions({
  Map<String, Object?>? answers,
  List<String>? reads,
  bool Function()? writesAllowed,
  HttpClientAdapter? writes,
}) {
  final map = <String, Object?>{
    '/x/web-interface/archive/has/like': 1,
    '/x/web-interface/archive/coins': {'multiply': 1},
    '/x/v2/fav/video/favoured': {'count': 1, 'favoured': true},
    '/x/relation': {'attribute': 1},
    ...?answers,
  };
  return BilibiliVideoActions(
    readData: (uri) async {
      reads?.add(uri.path);
      final answer = map[uri.path];
      if (answer is Exception) throw answer;
      if (answer == null) {
        throw const BilibiliAccountReadException('no answer');
      }
      return answer;
    },
    gate: BilibiliInteractionGate(
      loginCookies: () async => const {'SESSDATA': 'sess', 'bili_jct': 'jct'},
      // Null: the app's account read-only setting decides.
      writesAllowed: writesAllowed,
      httpClientAdapter: writes ?? _RefusingAdapter(),
      log: (_) {},
    ),
    hasLogin: () async => true,
    accountMid: () async => 42,
  );
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

class _CountingAdapter implements HttpClientAdapter {
  int requests = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests++;
    throw StateError('no network in tests');
  }

  @override
  void close({bool force = false}) {}
}
