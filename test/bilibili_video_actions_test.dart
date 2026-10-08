import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/screens/bilibili/bilibili_video_detail_screen.dart';
import 'package:video_player_app/screens/bilibili/bilibili_video_interactions.dart';
import 'package:video_player_app/services/bilibili/bilibili_api_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_interaction_gate.dart';
import 'package:video_player_app/services/bilibili/bilibili_public_api_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_video_actions.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/utils/app_toast.dart';

const _bvid = 'BV1GJ411x7h7';
const _aid = 170001;
const _upMid = 9527;

/// Answers the cookie-free detail requests.
class _DetailAdapter implements HttpClientAdapter {
  _DetailAdapter({this.copyright = 1});

  final int copyright;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final Object body = options.path.endsWith('/x/web-interface/view')
        ? {
            'code': 0,
            'data': {
              'bvid': _bvid,
              'aid': _aid,
              'title': '详情标题',
              'copyright': copyright,
              'owner': {'mid': _upMid, 'name': 'UP甲'},
              'stat': {'view': 100, 'like': 20, 'coin': 5, 'favorite': 3},
              'pages': [
                {'cid': 1, 'page': 1, 'part': 'P1'},
              ],
            },
          }
        : {'code': 0, 'data': []};
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

/// Records every write the gate sends; never touches the network.
class _WriteAdapter implements HttpClientAdapter {
  final List<RequestOptions> requests = <RequestOptions>[];
  Completer<void>? hold;
  Object answer = {'code': 0, 'message': '0'};

  List<Map<dynamic, dynamic>> get forms => [
    for (final r in requests) r.data as Map<dynamic, dynamic>,
  ];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    await hold?.future;
    return ResponseBody.fromString(
      jsonEncode(answer),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class _Harness {
  _Harness({this.loggedIn = true});

  bool loggedIn;
  bool writesAllowed = true;
  final writes = _WriteAdapter();
  final List<String> reads = <String>[];

  /// Per-path read answers; a missing path or an Exception value fails.
  final Map<String, Object?> readAnswers = <String, Object?>{
    '/x/web-interface/archive/has/like': 0,
    '/x/web-interface/archive/coins': {'multiply': 0},
    '/x/v2/fav/video/favoured': {'count': 0, 'favoured': false},
    '/x/relation': {'attribute': 0},
    '/x/v3/fav/folder/created/list-all': {
      'list': [
        {'id': 11, 'title': '默认收藏夹', 'media_count': 3, 'fav_state': 1},
        {'id': 22, 'title': '学习', 'media_count': 8, 'fav_state': 0},
      ],
    },
  };

  late final BilibiliVideoActions actions = BilibiliVideoActions(
    readData: (uri) async {
      reads.add(uri.path);
      final answer = readAnswers[uri.path];
      if (answer == null || answer is Exception) {
        throw const BilibiliAccountReadException('失败', code: -500);
      }
      return answer;
    },
    gate: BilibiliInteractionGate(
      loginCookies: () async => loggedIn
          ? {'SESSDATA': 'sess', 'bili_jct': 'jct'}
          : const <String, String>{},
      writesAllowed: () => writesAllowed,
      httpClientAdapter: writes,
      log: (_) {},
    ),
    hasLogin: () async => loggedIn,
    accountMid: () async => 42,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    SettingsService().resetForTest();
  });

  group('service', () {
    test('coins left is two minus what was given', () {
      expect(BilibiliVideoActions.coinsLeft(null), 2);
      expect(BilibiliVideoActions.coinsLeft(0), 2);
      expect(BilibiliVideoActions.coinsLeft(1), 1);
      expect(BilibiliVideoActions.coinsLeft(2), 0);
      expect(BilibiliVideoActions.coinsLeft(5), 0);
    });

    test('coin cap: original 2, reprint 1, unknown counts as 2', () {
      expect(BilibiliVideoActions.coinLimit(1), 2);
      expect(BilibiliVideoActions.coinLimit(2), 1);
      expect(BilibiliVideoActions.coinLimit(0), 2);
      expect(BilibiliVideoActions.coinsLeft(0, copyright: 1), 2);
      expect(BilibiliVideoActions.coinsLeft(1, copyright: 1), 1);
      expect(BilibiliVideoActions.coinsLeft(0, copyright: 2), 1);
      expect(BilibiliVideoActions.coinsLeft(1, copyright: 2), 0);
    });

    test(
      'out-of-range coin counts fail at run time with zero requests',
      () async {
        final h = _Harness();
        final cases = <({int count, int copyright, int given})>[
          (count: 0, copyright: 1, given: 0),
          (count: 3, copyright: 1, given: 0),
          (count: -1, copyright: 1, given: 0),
          (count: 2, copyright: 2, given: 0), // reprint cap is 1
          (count: 1, copyright: 2, given: 1), // reprint already full
          (count: 2, copyright: 1, given: 1), // only one left
          (count: 1, copyright: 1, given: 2), // original already full
        ];
        for (final c in cases) {
          final result = await h.actions.addCoins(
            aid: _aid,
            count: c.count,
            copyright: c.copyright,
            alreadyGiven: c.given,
          );
          expect(
            result.outcome,
            BilibiliWriteOutcome.invalidRequest,
            reason: '$c',
          );
          expect(result.isSuccess, isFalse, reason: '$c');
          expect(result.requestSent, isFalse, reason: '$c');
        }
        expect(h.writes.requests, isEmpty);

        final ok = await h.actions.addCoins(aid: _aid, count: 1, copyright: 2);
        expect(ok.isSuccess, isTrue);
        expect(h.writes.forms.single['multiply'], '1');
      },
    );

    test(
      'other writes reject bad ids at run time with zero requests',
      () async {
        final h = _Harness();
        final results = [
          await h.actions.setLiked(aid: 0, liked: true),
          await h.actions.addCoins(aid: 0, count: 1),
          await h.actions.setFollowing(mid: 0, following: true),
          (await h.actions.updateFavorites(aid: 0, before: {}, after: {11}))!,
          (await h.actions.updateFavorites(
            aid: _aid,
            before: {},
            after: {-3},
          ))!,
        ];
        for (final r in results) {
          expect(r.outcome, BilibiliWriteOutcome.invalidRequest);
        }
        expect(h.writes.requests, isEmpty);
      },
    );

    test('favourites send only what changed, nothing when unchanged', () async {
      final h = _Harness();
      expect(
        await h.actions.updateFavorites(
          aid: _aid,
          before: {11, 22},
          after: {22, 11},
        ),
        isNull,
      );
      expect(h.writes.requests, isEmpty);

      final result = await h.actions.updateFavorites(
        aid: _aid,
        before: {11, 22},
        after: {22, 33},
      );
      expect(result!.isSuccess, isTrue);
      expect(h.writes.requests.single.uri.path, '/x/v3/fav/resource/deal');
      expect(h.writes.forms.single, {
        'rid': '$_aid',
        'type': '2',
        'add_media_ids': '33',
        'del_media_ids': '11',
        'csrf': 'jct',
      });
    });

    test('reads parse each state', () async {
      final h = _Harness()
        ..readAnswers['/x/web-interface/archive/has/like'] = 1
        ..readAnswers['/x/web-interface/archive/coins'] = {'multiply': 2}
        ..readAnswers['/x/v2/fav/video/favoured'] = {'favoured': true}
        ..readAnswers['/x/relation'] = {'attribute': 6};
      expect(await h.actions.fetchLiked(_bvid), isTrue);
      expect(await h.actions.fetchCoins(_bvid), 2);
      expect(await h.actions.fetchFavorited(_aid), isTrue);
      expect(await h.actions.fetchFollowing(_upMid), isTrue);
      final folders = await h.actions.fetchFavoriteFolders(_aid);
      expect(folders.map((f) => f.id), [11, 22]);
      expect(folders.first.containsVideo, isTrue);
      expect(h.writes.requests, isEmpty);
    });

    test('write forms', () async {
      final h = _Harness();
      await h.actions.setLiked(aid: _aid, liked: false);
      await h.actions.addCoins(aid: _aid, count: 2, alsoLike: true);
      await h.actions.setFollowing(mid: _upMid, following: true);
      expect(h.writes.requests.map((r) => r.uri.path), [
        '/x/web-interface/archive/like',
        '/x/web-interface/coin/add',
        '/x/relation/modify',
      ]);
      expect(h.writes.forms[0]['like'], '2');
      expect(h.writes.forms[1]['multiply'], '2');
      expect(h.writes.forms[1]['select_like'], '1');
      expect(h.writes.forms[2]['act'], '1');
    });
  });

  group('detail page', () {
    Future<void> pumpDetail(
      WidgetTester tester,
      _Harness h, {
      int copyright = 1,
    }) async {
      tester.view.physicalSize = const Size(900, 2000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await SettingsService().init();
      await SettingsService().updateSetting<bool>(
        'bilibiliAccountReadOnly',
        !h.writesAllowed,
      );
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: AppToast.navigatorKey,
          home: BilibiliVideoDetailScreen(
            bvid: _bvid,
            api: BilibiliPublicApiService(
              httpClientAdapter: _DetailAdapter(copyright: copyright),
            ),
            actions: h.actions,
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    Future<void> finish(WidgetTester tester) async {
      await AppToast.dismiss(immediate: true);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 10));
    }

    BilibiliActionButton button(WidgetTester tester, String name) =>
        tester.widget<BilibiliActionButton>(
          find.byKey(ValueKey('bilibili-action-$name')),
        );

    testWidgets('four states load separately; one failure stays unknown', (
      tester,
    ) async {
      final h = _Harness()
        ..readAnswers['/x/web-interface/archive/has/like'] = 1
        ..readAnswers.remove('/x/web-interface/archive/coins')
        ..readAnswers['/x/v2/fav/video/favoured'] = {'favoured': true}
        ..readAnswers['/x/relation'] = {'attribute': 2};
      await pumpDetail(tester, h);

      expect(find.text('详情标题'), findsOneWidget);
      expect(button(tester, 'like').active, isTrue);
      expect(button(tester, 'like').label, '已赞');
      expect(button(tester, 'coin').active, isNull);
      expect(button(tester, 'favorite').active, isTrue);
      expect(button(tester, 'follow').active, isTrue);
      expect(h.reads.toSet(), {
        '/x/web-interface/archive/has/like',
        '/x/web-interface/archive/coins',
        '/x/v2/fav/video/favoured',
        '/x/relation',
      });

      // The unknown coin button still opens the confirmation.
      await tester.tap(find.byKey(const ValueKey('bilibili-action-coin')));
      await tester.pumpAndSettle();
      expect(find.text('将投出 1 枚硬币，投出后无法撤回'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(h.writes.requests, isEmpty);
      await finish(tester);
    });

    testWidgets('logged out: no state reads, taps ask to log in', (
      tester,
    ) async {
      final h = _Harness(loggedIn: false);
      await pumpDetail(tester, h);
      expect(h.reads, isEmpty);
      expect(button(tester, 'like').active, isFalse);
      expect(button(tester, 'follow').active, isFalse);

      await tester.tap(find.byKey(const ValueKey('bilibili-action-like')));
      await tester.pump();
      await tester.pump();
      expect(find.text('请先登录 B 站'), findsOneWidget);
      expect(find.text('去登录'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('bilibili-action-coin')));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(h.writes.requests, isEmpty);
      await finish(tester);
    });

    testWidgets('read-only: buttons stay, every tap sends nothing', (
      tester,
    ) async {
      final h = _Harness()..writesAllowed = false;
      await pumpDetail(tester, h);
      expect(
        find.byKey(const ValueKey('bilibili-action-read-only')),
        findsOneWidget,
      );

      for (final name in ['like', 'coin', 'favorite', 'follow']) {
        await tester.tap(find.byKey(ValueKey('bilibili-action-$name')));
        await tester.pump();
        await tester.pump();
        expect(find.byType(AlertDialog), findsNothing, reason: name);
        expect(find.text('已开启账号只读，可在 B站设置中关闭'), findsOneWidget);
        expect(find.text('去设置'), findsOneWidget);
      }
      expect(h.writes.requests, isEmpty);
      expect(h.reads, isNotEmpty, reason: 'read-only does not block reads');
      await finish(tester);
    });

    testWidgets('coins: cancel, outside tap and back send nothing; '
        'confirm sends once with the chosen count', (tester) async {
      final h = _Harness()
        ..readAnswers['/x/web-interface/archive/coins'] = {'multiply': 1};
      await pumpDetail(tester, h);
      expect(button(tester, 'coin').label, '已投 1');

      Future<void> open() async {
        await tester.tap(find.byKey(const ValueKey('bilibili-action-coin')));
        await tester.pumpAndSettle();
        expect(find.text('将投出 1 枚硬币，投出后无法撤回'), findsOneWidget);
      }

      await open();
      // One coin already given: the 2-coin option is disabled.
      final two = tester.widget<ChoiceChip>(
        find.byKey(const ValueKey('bilibili-coin-option-2')),
      );
      expect(two.onSelected, isNull);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();

      await open();
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);

      await open();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(h.writes.requests, isEmpty);

      await open();
      await tester.tap(find.byKey(const ValueKey('bilibili-coin-confirm')));
      await tester.pumpAndSettle();
      expect(h.writes.requests, hasLength(1));
      expect(h.writes.requests.single.uri.path, '/x/web-interface/coin/add');
      expect(h.writes.forms.single['multiply'], '1');
      expect(h.writes.forms.single['select_like'], '0');
      expect(button(tester, 'coin').label, '已投满');
      expect(find.text('6 投币'), findsOneWidget);

      // Full: no dialog, no request.
      await tester.tap(find.byKey(const ValueKey('bilibili-action-coin')));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(h.writes.requests, hasLength(1));
      await finish(tester);
    });

    testWidgets('reprint: only the 1-coin option; one given shows full', (
      tester,
    ) async {
      final h = _Harness();
      await pumpDetail(tester, h, copyright: 2);
      await tester.tap(find.byKey(const ValueKey('bilibili-action-coin')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('bilibili-coin-option-1')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('bilibili-coin-option-2')),
        findsNothing,
      );
      expect(find.text('转载视频每人只能投 1 枚'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('bilibili-coin-confirm')));
      await tester.pumpAndSettle();
      expect(h.writes.forms.single['multiply'], '1');
      expect(button(tester, 'coin').label, '已投满');
      await finish(tester);

      final full = _Harness()
        ..readAnswers['/x/web-interface/archive/coins'] = {'multiply': 1};
      await pumpDetail(tester, full, copyright: 2);
      expect(button(tester, 'coin').label, '已投满');
      await tester.tap(find.byKey(const ValueKey('bilibili-action-coin')));
      await tester.pump();
      await tester.pump();
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('转载视频只能投 1 枚硬币，已经投满了'), findsOneWidget);
      expect(full.writes.requests, isEmpty);
      await finish(tester);
    });

    testWidgets('coins: two coins with like', (tester) async {
      final h = _Harness();
      await pumpDetail(tester, h);
      await tester.tap(find.byKey(const ValueKey('bilibili-action-coin')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('bilibili-coin-option-2')));
      await tester.tap(find.byKey(const ValueKey('bilibili-coin-also-like')));
      await tester.pumpAndSettle();
      expect(find.text('将投出 2 枚硬币，投出后无法撤回'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('bilibili-coin-confirm')));
      await tester.pumpAndSettle();
      expect(h.writes.forms.single['multiply'], '2');
      expect(h.writes.forms.single['select_like'], '1');
      expect(button(tester, 'like').active, isTrue);
      expect(find.text('21 点赞'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('favourites: unchanged sends nothing, changes send the diff', (
      tester,
    ) async {
      final h = _Harness();
      await pumpDetail(tester, h);

      await tester.tap(find.byKey(const ValueKey('bilibili-action-favorite')));
      await tester.pumpAndSettle();
      expect(find.text('默认收藏夹'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('bilibili-favorite-confirm')));
      await tester.pumpAndSettle();
      expect(h.writes.requests, isEmpty);

      await tester.tap(find.byKey(const ValueKey('bilibili-action-favorite')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('bilibili-favorite-folder-11')),
      );
      await tester.tap(
        find.byKey(const ValueKey('bilibili-favorite-folder-22')),
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('bilibili-favorite-confirm')));
      await tester.pumpAndSettle();
      expect(h.writes.requests, hasLength(1));
      expect(h.writes.forms.single['add_media_ids'], '22');
      expect(h.writes.forms.single['del_media_ids'], '11');
      expect(button(tester, 'favorite').active, isTrue);
      await finish(tester);
    });

    testWidgets('unfollow asks first; follow does not', (tester) async {
      final h = _Harness()..readAnswers['/x/relation'] = {'attribute': 2};
      await pumpDetail(tester, h);
      expect(button(tester, 'follow').label, '已关注');

      await tester.tap(find.byKey(const ValueKey('bilibili-action-follow')));
      await tester.pumpAndSettle();
      expect(find.text('确定不再关注「UP甲」吗？'), findsOneWidget);
      await tester.tap(find.text('再想想'));
      await tester.pumpAndSettle();
      expect(h.writes.requests, isEmpty);

      await tester.tap(find.byKey(const ValueKey('bilibili-action-follow')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '取消关注'));
      await tester.pumpAndSettle();
      expect(h.writes.forms.single['act'], '2');
      expect(h.writes.forms.single['fid'], '$_upMid');
      expect(button(tester, 'follow').label, '关注');

      await tester.tap(find.byKey(const ValueKey('bilibili-action-follow')));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(h.writes.forms.last['act'], '1');
      expect(button(tester, 'follow').label, '已关注');
      await finish(tester);
    });

    testWidgets('a running like ignores more taps and updates the count', (
      tester,
    ) async {
      final h = _Harness();
      await pumpDetail(tester, h);
      expect(find.text('20 点赞'), findsOneWidget);
      h.writes.hold = Completer<void>();

      await tester.tap(find.byKey(const ValueKey('bilibili-action-like')));
      for (var i = 0; i < 10 && h.writes.requests.isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(button(tester, 'like').busy, isTrue);
      await tester.tap(
        find.byKey(const ValueKey('bilibili-action-like')),
        warnIfMissed: false,
      );
      await tester.pump();
      expect(h.writes.requests, hasLength(1));

      h.writes.hold!.complete();
      await tester.pumpAndSettle();
      expect(button(tester, 'like').active, isTrue);
      expect(find.text('21 点赞'), findsOneWidget);
      expect(h.writes.forms.single['like'], '1');
      await finish(tester);
    });
  });
}
