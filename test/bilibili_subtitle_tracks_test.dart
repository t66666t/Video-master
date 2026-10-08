import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:video_player_app/models/managed_subtitle_asset.dart';
import 'package:video_player_app/models/media_source_ref.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/bilibili/bilibili_public_api_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_subtitle_tracks.dart';

const _bvid = 'BV1xx411c7mD';

Map<String, Object?> _player(List<Map<String, Object?>> subtitles) =>
    <String, Object?>{
      'subtitle': <String, Object?>{'subtitles': subtitles},
    };

Map<String, Object?> _cc(String lan, String doc) => <String, Object?>{
  'lan': lan,
  'lan_doc': doc,
  'subtitle_url': '//aisubtitle.hdslb.com/bfs/subtitle/$lan.json',
};

const _json = <String, Object?>{
  'body': <Object?>[
    <String, Object?>{'from': 0.0, 'to': 1.5, 'content': '你好'},
  ],
};

VideoItem _online(String id, {int cid = 101}) => VideoItem(
  id: id,
  path: 'bilibili://stream/$_bvid?cid=$cid',
  title: '测试',
  durationMs: 600000,
  lastUpdated: 0,
  sourceRef: MediaSourceRef(
    value: _bvid,
    kind: MediaSourceKind.bilibiliStream,
    bvid: _bvid,
    cid: cid,
    page: cid - 100,
  ),
);

class _Fake {
  _Fake(this.dir);

  final Directory dir;
  final Map<String, VideoItem> items = <String, VideoItem>{};
  final changes = ChangeNotifier();
  bool loggedIn = false;
  Map<int, List<BilibiliSubtitleTrack>> cc =
      <int, List<BilibiliSubtitleTrack>>{};
  Map<int, List<BilibiliSubtitleTrack>> withLogin =
      <int, List<BilibiliSubtitleTrack>>{};
  Object? ccError;
  Future<bool> Function(String itemId)? completePending;
  final List<int> ccCalls = <int>[];
  final List<int> aiCalls = <int>[];
  int loginChecks = 0;
  final List<String> contentCalls = <String>[];
  int noted = 0;

  BilibiliSubtitleTracks build() => BilibiliSubtitleTracks(
    source: BilibiliSubtitleTrackSource(
      fetchCcTracks: (bvid, cid) async {
        ccCalls.add(cid);
        final error = ccError;
        if (error != null) throw error;
        return cc[cid] ?? const <BilibiliSubtitleTrack>[];
      },
      fetchAiTracks: (bvid, cid) async {
        aiCalls.add(cid);
        return withLogin[cid] ?? const <BilibiliSubtitleTrack>[];
      },
      isLoggedIn: () async {
        loginChecks++;
        return loggedIn;
      },
      fetchContent: (url) async {
        contentCalls.add(url);
        return _json;
      },
      completePending: (id) => completePending?.call(id) ?? Future.value(false),
    ),
    store: BilibiliSubtitleTrackStore(
      itemOf: (id) => items[id],
      noteChanged: (id) async => noted++,
      writeSubtitle: (id, label, contents) async {
        final file = File(p.join(dir.path, id, '$label.srt'));
        await file.create(recursive: true);
        await file.writeAsString(contents);
        return file.path;
      },
      changes: changes,
    ),
  );
}

List<BilibiliSubtitleTrack> _tracks(List<Map<String, Object?>> raw) =>
    parseBilibiliSubtitleTracks(_player(raw));

void main() {
  late Directory dir;
  late _Fake fake;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('bili_sub_tracks_');
    fake = _Fake(dir);
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  group('track list parsing', () {
    test('CC tracks: name, code and https address', () {
      final tracks = _tracks([_cc('zh-CN', '中文（中国）'), _cc('en-US', '英语')]);
      expect(tracks.map((t) => t.label), ['中文（中国）', '英语']);
      expect(tracks.map((t) => t.lan), ['zh-CN', 'en-US']);
      expect(tracks.every((t) => !t.isAi), isTrue);
      expect(tracks.first.url, startsWith('https://aisubtitle.hdslb.com/'));
    });

    test('AI tracks are marked by their ai- code or their name', () {
      final tracks = _tracks([
        _cc('ai-zh', '中文'),
        _cc('zh-Hans', '中文（自动生成）'),
        _cc('th', 'Thai'),
      ]);
      expect(tracks.map((t) => t.isAi), [true, true, false]);
    });

    test('no subtitles: missing, empty or without address', () {
      expect(parseBilibiliSubtitleTracks(null), isEmpty);
      expect(parseBilibiliSubtitleTracks(<String, Object?>{}), isEmpty);
      expect(_tracks(const []), isEmpty);
      expect(
        _tracks([
          <String, Object?>{'lan': 'zh', 'lan_doc': '中文', 'subtitle_url': ''},
        ]),
        isEmpty,
      );
    });
  });

  test(
    'logged out: only CC tracks, the login hint, no logged-in request',
    () async {
      fake
        ..items['a'] = _online('a')
        ..cc[101] = _tracks([_cc('zh-CN', '中文'), _cc('ai-zh', '中文（自动生成）')]);
      final tracks = fake.build();
      await tracks.ensureLoaded('a');
      final list = tracks.listFor('a');
      expect(list.tracks.map((t) => t.label), ['中文']);
      expect(list.aiNeedsLogin, isTrue);
      expect(list.emptyMessage, isNull);
      expect(fake.ccCalls, [101]);
      expect(fake.aiCalls, isEmpty);
    },
  );

  test('logged in: AI tracks come from the logged-in request', () async {
    fake
      ..loggedIn = true
      ..items['a'] = _online('a')
      ..cc[101] = _tracks([_cc('zh-CN', '中文')])
      ..withLogin[101] = _tracks([
        _cc('zh-CN', '中文'),
        _cc('ai-zh', '中文（自动生成）'),
      ]);
    final tracks = fake.build();
    await tracks.ensureLoaded('a');
    final list = tracks.listFor('a');
    expect(list.tracks.map((t) => '${t.label}/${t.isAi}'), [
      '中文/false',
      '中文（自动生成）/true',
    ]);
    expect(list.aiNeedsLogin, isFalse);
    expect(fake.ccCalls, [101]);
    expect(fake.aiCalls, [101]);
  });

  test('no subtitles: a plain line, nothing loading', () async {
    fake
      ..loggedIn = true
      ..items['a'] = _online('a');
    final tracks = fake.build();
    final pending = tracks.ensureLoaded('a');
    await pending;
    final list = tracks.listFor('a');
    expect(list.loading, isFalse);
    expect(list.tracks, isEmpty);
    expect(list.emptyMessage, '这个视频没有字幕');

    fake.loggedIn = false;
    await tracks.ensureLoaded('a');
    expect(tracks.listFor('a').emptyMessage, '这个视频没有 CC 字幕');
    expect(tracks.listFor('a').aiNeedsLogin, isTrue);
  });

  test('picking a track saves it with the card and returns its file', () async {
    fake
      ..items['a'] = _online('a')
      ..cc[101] = _tracks([_cc('en-US', '英语')]);
    final tracks = fake.build();
    await tracks.ensureLoaded('a');
    final track = tracks.listFor('a').tracks.single;
    expect(track.isDownloaded, isFalse);

    final path = await tracks.load('a', track);
    expect(path, isNotNull);
    expect(File(path!).readAsStringSync(), contains('你好'));
    final item = fake.items['a']!;
    expect(item.downloadAssociatedSubtitles.values, [path]);
    expect(item.managedSubtitleAssets.single.language, 'en-US');
    expect(
      item.managedSubtitleAssets.single.kind,
      ManagedSubtitleAssetKind.downloaded,
    );
    expect(fake.noted, 1);
    expect(tracks.listFor('a').tracks.single.path, path);

    // Picked again: the saved file, nothing fetched.
    final again = await tracks.load('a', tracks.listFor('a').tracks.single);
    expect(again, path);
    expect(fake.contentCalls, hasLength(1));
  });

  test(
    'a part still waiting for its data gets it first, no second fetch',
    () async {
      fake
        ..items['a'] = _online('a')
        ..cc[101] = _tracks([_cc('zh-CN', '中文')]);
      fake.completePending = (id) async {
        final file = File(p.join(dir.path, 'built', '中文.srt'));
        await file.create(recursive: true);
        fake.items[id]!
          ..usesManagedAssociatedSubtitles = true
          ..additionalSubtitles = <String, String>{'中文': file.path}
          ..managedSubtitleAssets = <ManagedSubtitleAsset>[
            ManagedSubtitleAsset(
              assetId: 'x',
              path: file.path,
              kind: ManagedSubtitleAssetKind.downloaded,
              displayName: '中文',
              language: 'zh-CN',
              createdAt: 0,
            ),
          ];
        return true;
      };
      final tracks = fake.build();
      await tracks.ensureLoaded('a');
      final path = await tracks.load('a', tracks.listFor('a').tracks.single);
      expect(path, endsWith(p.join('built', '中文.srt')));
      expect(fake.contentCalls, isEmpty);
    },
  );

  test(
    'a failed fetch is reported on the track and can be tried again',
    () async {
      fake
        ..items['a'] = _online('a')
        ..cc[101] = const [
          BilibiliSubtitleTrack(lan: 'zh', label: '中文', isAi: false),
        ];
      final tracks = fake.build();
      await tracks.ensureLoaded('a');
      final track = tracks.listFor('a').tracks.single;
      expect(await tracks.load('a', track), isNull);
      expect(tracks.hasFailed('a', track), isTrue);
      expect(tracks.isLoading('a', track), isFalse);
    },
  );

  test('switching parts lists that part\'s tracks, each asked once', () async {
    fake
      ..items['p1'] = _online('p1', cid: 101)
      ..items['p2'] = _online('p2', cid: 102)
      ..cc[101] = _tracks([_cc('zh-CN', '中文')])
      ..cc[102] = _tracks([_cc('ja', '日语')]);
    final tracks = fake.build();
    await tracks.ensureLoaded('p1');
    expect(tracks.listFor('p1').tracks.single.label, '中文');
    await tracks.ensureLoaded('p2');
    expect(tracks.listFor('p2').tracks.single.label, '日语');
    await tracks.ensureLoaded('p1');
    expect(tracks.listFor('p1').tracks.single.label, '中文');
    expect(fake.ccCalls, [101, 102]);
  });

  test('logging in later asks again and adds the AI tracks', () async {
    fake
      ..items['a'] = _online('a')
      ..cc[101] = _tracks([_cc('zh-CN', '中文')])
      ..withLogin[101] = _tracks([_cc('ai-zh', '中文（自动生成）')]);
    final tracks = fake.build();
    await tracks.ensureLoaded('a');
    expect(tracks.listFor('a').tracks, hasLength(1));
    fake.loggedIn = true;
    await tracks.ensureLoaded('a');
    expect(tracks.listFor('a').tracks, hasLength(2));
    expect(tracks.listFor('a').aiNeedsLogin, isFalse);
  });

  test('downloaded video: its saved files, no request at all', () async {
    final zh = File(p.join(dir.path, 'd', '中文.srt'))
      ..createSync(recursive: true);
    final ai = File(p.join(dir.path, 'd', '中文 自动.srt'))
      ..createSync(recursive: true);
    fake.items['d'] = VideoItem(
      id: 'd',
      path: p.join(dir.path, 'video.mp4'),
      title: '已下载',
      durationMs: 1000,
      lastUpdated: 0,
      isBilibiliExported: true,
      usesManagedAssociatedSubtitles: true,
      additionalSubtitles: <String, String>{'中文': zh.path, '中文2': ai.path},
      managedSubtitleAssets: <ManagedSubtitleAsset>[
        ManagedSubtitleAsset(
          assetId: '1',
          path: zh.path,
          kind: ManagedSubtitleAssetKind.downloaded,
          displayName: '中文',
          language: 'zh-CN',
          createdAt: 0,
        ),
        ManagedSubtitleAsset(
          assetId: '2',
          path: ai.path,
          kind: ManagedSubtitleAssetKind.downloaded,
          displayName: '中文',
          language: 'ai-zh',
          createdAt: 0,
        ),
      ],
      sourceRef: const MediaSourceRef(
        value: _bvid,
        kind: MediaSourceKind.bilibiliBv,
        bvid: _bvid,
      ),
    );
    final tracks = fake.build();
    expect(BilibiliSubtitleTracks.covers(fake.items['d']), isTrue);
    await tracks.ensureLoaded('d');
    final list = tracks.listFor('d');
    expect(list.savedOnly, isTrue);
    expect(list.loading, isFalse);
    expect(list.aiNeedsLogin, isFalse);
    expect(list.tracks.map((t) => '${t.path}/${t.isAi}'), [
      '${zh.path}/false',
      '${ai.path}/true',
    ]);
    expect(await tracks.load('d', list.tracks.first), zh.path);
    expect(fake.ccCalls, isEmpty);
    expect(fake.aiCalls, isEmpty);
    expect(fake.loginChecks, 0);
    expect(fake.contentCalls, isEmpty);
  });

  test('no network: the saved files are listed without an error', () async {
    final zh = File(p.join(dir.path, 'a', '中文.srt'))
      ..createSync(recursive: true);
    fake
      ..ccError = const BilibiliPublicApiException('x', isNetworkError: true)
      ..items['a'] = (_online('a')
        ..usesManagedAssociatedSubtitles = true
        ..additionalSubtitles = <String, String>{'中文': zh.path});
    final tracks = fake.build();
    await tracks.ensureLoaded('a');
    final list = tracks.listFor('a');
    expect(list.tracks.single.path, zh.path);
    expect(list.networkFailed, isTrue);
    expect(list.emptyMessage, isNull);

    fake.items['a']!.additionalSubtitles = <String, String>{};
    expect(tracks.listFor('a').emptyMessage, '联网后可查看 B 站字幕');
  });

  test('saved tracks are matched to the listed ones, extra files kept', () {
    final merged = mergeBilibiliSubtitleTracks(
      _tracks([_cc('zh-CN', '中文'), _cc('en', '英语')]),
      const [
        BilibiliSubtitleTrack(
          lan: '',
          label: '英语',
          isAi: false,
          path: '/s/en.srt',
        ),
        BilibiliSubtitleTrack(
          lan: 'ai-zh',
          label: '中文（自动生成）',
          isAi: true,
          path: '/s/ai.srt',
        ),
      ],
    );
    expect(merged.map((t) => t.path), [null, '/s/en.srt', '/s/ai.srt']);
  });

  test('the list is asked once while it is on its way', () async {
    final gate = Completer<List<BilibiliSubtitleTrack>>();
    fake.items['a'] = _online('a');
    final tracks = BilibiliSubtitleTracks(
      source: BilibiliSubtitleTrackSource(
        fetchCcTracks: (bvid, cid) {
          fake.ccCalls.add(cid);
          return gate.future;
        },
        fetchAiTracks: (bvid, cid) async => const [],
        isLoggedIn: () async => false,
        fetchContent: (url) async => _json,
      ),
      store: BilibiliSubtitleTrackStore(
        itemOf: (id) => fake.items[id],
        noteChanged: (id) async {},
        writeSubtitle: (id, label, contents) async => '',
      ),
    );
    final first = tracks.ensureLoaded('a');
    await Future<void>.delayed(Duration.zero);
    expect(tracks.listFor('a').loading, isTrue);
    expect(tracks.listFor('a').emptyMessage, isNull);
    await tracks.ensureLoaded('a');
    gate.complete(const []);
    await first;
    expect(fake.ccCalls, [101]);
  });
}
