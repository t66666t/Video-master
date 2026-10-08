import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/managed_subtitle_asset.dart';
import 'package:video_player_app/models/media_source_ref.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/bilibili/bilibili_subtitle_tracks.dart';
import 'package:video_player_app/services/embedded_subtitle_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/widgets/bilibili_subtitle_tracks_section.dart';
import 'package:video_player_app/widgets/subtitle_management_sheet.dart';

const _bvid = 'BV1xx411c7mD';
const _path = 'bilibili://stream/$_bvid?cid=101';

void main() {
  late Directory dir;
  late File saved;
  late VideoItem item;
  late List<List<String>> selections;
  late int fetches;
  late BilibiliSubtitleTracks tracks;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    dir = Directory.systemTemp.createTempSync('sheet_bili_tracks_');
    await SettingsService().init();
    SettingsService().largeDataRootPath = dir.path;
    saved = File(p.join(dir.path, 'zh.srt'))
      ..createSync(recursive: true)
      ..writeAsStringSync('1\n00:00:00,000 --> 00:00:01,000\n你好\n');
    item = VideoItem(
      id: 'card',
      path: _path,
      title: '测试',
      durationMs: 1000,
      lastUpdated: 0,
      usesManagedAssociatedSubtitles: true,
      additionalSubtitles: <String, String>{'中文': saved.path},
      managedSubtitleAssets: <ManagedSubtitleAsset>[
        ManagedSubtitleAsset(
          assetId: '1',
          path: saved.path,
          kind: ManagedSubtitleAssetKind.downloaded,
          displayName: '中文',
          language: 'zh-CN',
          createdAt: 0,
        ),
      ],
      sourceRef: const MediaSourceRef(
        value: _bvid,
        kind: MediaSourceKind.bilibiliStream,
        bvid: _bvid,
        cid: 101,
      ),
    );
    selections = <List<String>>[];
    fetches = 0;
    tracks = BilibiliSubtitleTracks(
      source: BilibiliSubtitleTrackSource(
        fetchCcTracks: (bvid, cid) async => const [
          BilibiliSubtitleTrack(
            lan: 'zh-CN',
            label: '中文',
            isAi: false,
            url: 'https://aisubtitle.hdslb.com/zh.json',
          ),
        ],
        fetchAiTracks: (bvid, cid) async => const [
          BilibiliSubtitleTrack(
            lan: 'ai-en',
            label: '英语（自动生成）',
            isAi: true,
            url: 'https://aisubtitle.hdslb.com/ai-en.json',
          ),
        ],
        isLoggedIn: () async => true,
        fetchContent: (url) async {
          fetches++;
          return <String, Object?>{
            'body': <Object?>[
              <String, Object?>{'from': 0.0, 'to': 1.0, 'content': 'hello'},
            ],
          };
        },
      ),
      store: BilibiliSubtitleTrackStore(
        itemOf: (id) => id == item.id ? item : null,
        noteChanged: (id) async {},
        writeSubtitle: (id, label, contents) async {
          final file = File(p.join(dir.path, 'ai-en.srt'))
            ..writeAsStringSync(contents);
          return file.path;
        },
      ),
    );
  });

  tearDown(() {
    SettingsService().largeDataRootPath = null;
    tracks.dispose();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  Future<void> pumpSheet(
    WidgetTester tester, {
    List<String> selected = const <String>[],
  }) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      await tester.pumpWidget(
        ChangeNotifierProvider<EmbeddedSubtitleService>(
          create: (_) => EmbeddedSubtitleService(),
          child: MaterialApp(
            home: Scaffold(
              body: SubtitleManagementSheet(
                videoPath: _path,
                videoId: item.id,
                showEmbeddedSubtitles: false,
                associatedSubtitles: item.downloadAssociatedSubtitles,
                initialSelectedPaths: selected,
                bilibiliTracks: tracks,
                onSubtitleChanged: () {},
                onOpenAi: () {},
                onSubtitleSelected: (paths) =>
                    selections.add(List<String>.of(paths)),
              ),
            ),
          ),
        ),
      );
      await tracks.ensureLoaded(item.id);
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();
  }

  testWidgets('a Bilibili video lists its tracks once, under「B 站字幕」', (
    tester,
  ) async {
    await pumpSheet(tester);
    expect(find.text('B 站字幕'), findsOneWidget);
    expect(find.text('媒体库关联字幕'), findsNothing);
    expect(find.text('中文'), findsOneWidget);
    expect(find.text('英语（自动生成）'), findsOneWidget);
    expect(find.byType(BilibiliAiBadge), findsOneWidget);
    expect(find.text('暂无关联字幕文件'), findsNothing);
  });

  testWidgets('pick, switch and turn off like a local subtitle', (
    tester,
  ) async {
    await pumpSheet(tester);
    // Pick the saved CC track.
    await tester.tap(find.text('中文'));
    await tester.pump();
    expect(selections.last, [saved.path]);

    // Pick the AI track: fetched, then selected next to it.
    await tester.runAsync(() async {
      await tester.tap(find.text('英语（自动生成）'));
      for (var i = 0; i < 30 && selections.length < 2; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    await tester.pump();
    expect(fetches, 1);
    final aiPath = p.join(dir.path, 'ai-en.srt');
    expect(selections.last, [saved.path, aiPath]);

    // Tap again: turned off, one by one.
    await tester.tap(find.text('英语（自动生成）'));
    await tester.pump();
    expect(selections.last, [saved.path]);
    await tester.tap(find.text('中文'));
    await tester.pump();
    expect(selections.last, isEmpty);
  });

  testWidgets('a fetched track that is already selected stays selected', (
    tester,
  ) async {
    await pumpSheet(tester, selected: <String>[saved.path]);
    final state = tester.state(find.byType(BilibiliSubtitleTracksSection));
    final section = state.widget as BilibiliSubtitleTracksSection;
    section.onPick(saved.path);
    await tester.pump();
    expect(selections, isEmpty);
  });
}
