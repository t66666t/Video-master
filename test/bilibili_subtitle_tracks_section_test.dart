import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:video_player_app/models/managed_subtitle_asset.dart';
import 'package:video_player_app/models/media_source_ref.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/bilibili/bilibili_subtitle_tracks.dart';
import 'package:video_player_app/widgets/bilibili_subtitle_tracks_section.dart';

const _bvid = 'BV1xx411c7mD';

BilibiliSubtitleTrack _track(String lan, String label) => BilibiliSubtitleTrack(
  lan: lan,
  label: label,
  isAi: isBilibiliAiSubtitle(lan: lan, label: label),
  url: 'https://aisubtitle.hdslb.com/$lan.json',
);

VideoItem _online(String id, int cid) => VideoItem(
  id: id,
  path: 'bilibili://stream/$_bvid?cid=$cid',
  title: '测试',
  durationMs: 1000,
  lastUpdated: 0,
  sourceRef: MediaSourceRef(
    value: _bvid,
    kind: MediaSourceKind.bilibiliStream,
    bvid: _bvid,
    cid: cid,
  ),
);

class _Env {
  _Env(this.dir);

  final Directory dir;
  final Map<String, VideoItem> items = <String, VideoItem>{};
  final Map<int, List<BilibiliSubtitleTrack>> cc = {};
  final Map<int, List<BilibiliSubtitleTrack>> ai = {};
  bool loggedIn = false;
  int requests = 0;

  late final BilibiliSubtitleTracks tracks = BilibiliSubtitleTracks(
    source: BilibiliSubtitleTrackSource(
      fetchCcTracks: (bvid, cid) async {
        requests++;
        return cc[cid] ?? const [];
      },
      fetchAiTracks: (bvid, cid) async {
        requests++;
        return ai[cid] ?? const [];
      },
      isLoggedIn: () async => loggedIn,
      fetchContent: (url) async {
        requests++;
        return <String, Object?>{
          'body': <Object?>[
            <String, Object?>{'from': 0.0, 'to': 1.0, 'content': url},
          ],
        };
      },
    ),
    store: BilibiliSubtitleTrackStore(
      itemOf: (id) => items[id],
      noteChanged: (id) async {},
      writeSubtitle: (id, label, contents) async {
        final file = File(p.join(dir.path, id, '$label.srt'));
        file.createSync(recursive: true);
        file.writeAsStringSync(contents);
        return file.path;
      },
    ),
  );
}

void main() {
  late Directory dir;
  late _Env env;
  late List<String> picked;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('bili_sub_section_');
    env = _Env(dir);
    picked = <String>[];
  });

  tearDown(() {
    env.tracks.dispose();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  Future<void> pump(WidgetTester tester, String itemId) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            backgroundColor: Colors.black,
            body: SingleChildScrollView(
              child: BilibiliSubtitleTracksSection(
                itemId: itemId,
                tracks: env.tracks,
                onPick: picked.add,
                savedRow: (track) => ListTile(
                  key: ValueKey('saved-${track.path}'),
                  title: Row(
                    children: [
                      Text(track.label),
                      if (track.isAi) const BilibiliAiBadge(),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await env.tracks.ensureLoaded(itemId);
    });
    await tester.pump();
  }

  testWidgets('logged out: CC tracks and the login line, no AI', (
    tester,
  ) async {
    env.items['a'] = _online('a', 101);
    env.cc[101] = [_track('zh-CN', '中文'), _track('en', '英语')];
    await pump(tester, 'a');
    expect(find.text('B 站字幕'), findsOneWidget);
    expect(find.text('中文'), findsOneWidget);
    expect(find.text('英语'), findsOneWidget);
    expect(find.text('登录后可加载 AI 字幕'), findsOneWidget);
    expect(find.byType(BilibiliAiBadge), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('logged in: AI tracks listed with the AI mark', (tester) async {
    env
      ..loggedIn = true
      ..items['a'] = _online('a', 101)
      ..cc[101] = [_track('zh-CN', '中文')]
      ..ai[101] = [_track('ai-zh', '中文（自动生成）')];
    await pump(tester, 'a');
    expect(find.text('中文（自动生成）'), findsOneWidget);
    expect(find.byType(BilibiliAiBadge), findsOneWidget);
    expect(find.text('登录后可加载 AI 字幕'), findsNothing);
  });

  testWidgets('tapping a track loads it and hands its file over', (
    tester,
  ) async {
    env.items['a'] = _online('a', 101);
    env.cc[101] = [_track('en', '英语')];
    await pump(tester, 'a');
    expect(find.text('点一下加载'), findsOneWidget);
    await tester.runAsync(() async {
      await tester.tap(find.text('英语'));
      for (var i = 0; i < 20 && picked.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    await tester.pump();
    expect(picked, hasLength(1));
    expect(File(picked.single).existsSync(), isTrue);
    // Now a file of the card: shown as a saved row.
    expect(find.byKey(ValueKey('saved-${picked.single}')), findsOneWidget);
    expect(find.text('点一下加载'), findsNothing);
  });

  testWidgets('no subtitles: one line, no spinner', (tester) async {
    env
      ..loggedIn = true
      ..items['a'] = _online('a', 101);
    await pump(tester, 'a');
    expect(find.text('这个视频没有字幕'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('switching parts shows that part\'s tracks', (tester) async {
    env.items['p1'] = _online('p1', 101);
    env.items['p2'] = _online('p2', 102);
    env.cc[101] = [_track('zh-CN', '中文')];
    env.cc[102] = [_track('ja', '日语')];
    await pump(tester, 'p1');
    expect(find.text('中文'), findsOneWidget);
    await pump(tester, 'p2');
    expect(find.text('日语'), findsOneWidget);
    expect(find.text('中文'), findsNothing);
  });

  testWidgets('downloaded video: saved files only, nothing asked', (
    tester,
  ) async {
    final zh = File(p.join(dir.path, 'd', 'zh.srt'))
      ..createSync(recursive: true);
    env.items['d'] = VideoItem(
      id: 'd',
      path: p.join(dir.path, 'v.mp4'),
      title: '已下载',
      durationMs: 1000,
      lastUpdated: 0,
      usesManagedAssociatedSubtitles: true,
      additionalSubtitles: <String, String>{'中文': zh.path},
      managedSubtitleAssets: <ManagedSubtitleAsset>[
        ManagedSubtitleAsset(
          assetId: '1',
          path: zh.path,
          kind: ManagedSubtitleAssetKind.downloaded,
          displayName: '中文',
          language: 'zh-CN',
          createdAt: 0,
        ),
      ],
      sourceRef: const MediaSourceRef(
        value: _bvid,
        kind: MediaSourceKind.bilibiliBv,
        bvid: _bvid,
      ),
    );
    await pump(tester, 'd');
    expect(find.byKey(ValueKey('saved-${zh.path}')), findsOneWidget);
    expect(find.text('登录后可加载 AI 字幕'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(env.requests, 0);
  });
}
