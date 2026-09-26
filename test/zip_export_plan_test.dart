import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:video_player_app/features/portable_transfer/portable_transfer_models.dart';
import 'package:video_player_app/features/portable_transfer/zip_export_plan.dart';
import 'package:video_player_app/models/managed_subtitle_asset.dart';
import 'package:video_player_app/models/media_chapter.dart';
import 'package:video_player_app/models/media_source_ref.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/library_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('zip export plan', () {
    late Directory tempDir;
    late LibraryService library;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('zip_export_plan_');
      library = LibraryService();
      library.writeLibrarySnapshotOverrideForTesting = () async {};
    });

    tearDown(() async {
      library.resetLibraryForTesting();
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('names cards, keeps folders, and disambiguates duplicates', () async {
      final folder = await library.createCollection('旅行', null);
      final kyoto = _file(tempDir, 'original-a.mp4');
      final osaka = _file(tempDir, 'original-b.mp4');
      final loose = _file(tempDir, 'disk-name.mkv');
      await _add(library, id: 'a', path: kyoto, title: '京都夜景', parentId: folder.id);
      await _add(library, id: 'b', path: osaka, title: '京都夜景', parentId: folder.id);
      await _add(library, id: 'c', path: loose, title: '首页视频', parentId: null);
      await _add(
        library,
        id: 'online',
        path: 'bilibili://stream/1',
        title: '在线',
        parentId: null,
        online: true,
      );

      final layout = buildZipExportLayout(
        library: library,
        rootIds: <String>[folder.id, 'c', 'online'],
        packageName: '我的导出',
        subtitleMode: ZipSubtitleMode.none,
        includeDanmaku: false,
        factsFor: (_) => const ZipSourceFacts(hasAttachedCover: true),
      );

      expect(layout.skippedOnline, 1);
      expect(layout.media.map((item) => item.archivePath), <String>[
        '我的导出/旅行/京都夜景.mp4',
        '我的导出/旅行/京都夜景 (2).mp4',
        '我的导出/首页视频.mkv',
      ]);
      expect(layout.media.every((item) => item.remux), isFalse);
    });

    test('omits unused outer folders and skips a missing file', () async {
      final outer = await library.createCollection('外层', null);
      final inner = await library.createCollection('内层', outer.id);
      final kept = _file(tempDir, 'kept.mp4');
      await _add(library, id: 'kept', path: kept, title: '保留', parentId: inner.id);
      await _add(
        library,
        id: 'missing',
        path: p.join(tempDir.path, 'nope.mp4'),
        title: '缺失',
        parentId: inner.id,
      );

      final layout = buildZipExportLayout(
        library: library,
        rootIds: const <String>['kept', 'missing'],
        packageName: '包',
        subtitleMode: ZipSubtitleMode.none,
        includeDanmaku: false,
      );

      expect(layout.skippedMissing, 1);
      expect(layout.media.single.archivePath, '包/内层/保留.mp4');
    });

    test('embeds associated subtitles and leaves styled tracks in mkv', () async {
      final video = _file(tempDir, 'source.mp4');
      final primary = _file(tempDir, 'primary.srt');
      final embedded = _file(tempDir, 'embedded.srt');
      final styled = _file(tempDir, 'styled.ass');
      final danmaku = _file(tempDir, 'danmaku.ass');
      await _add(
        library,
        id: 'clip',
        path: video,
        title: '讲座',
        parentId: null,
        subtitlePath: primary,
        managed: <ManagedSubtitleAsset>[
          ManagedSubtitleAsset(
            assetId: 'emb',
            path: embedded,
            kind: ManagedSubtitleAssetKind.embedded,
            displayName: '内嵌副本',
            createdAt: 1,
          ),
          ManagedSubtitleAsset(
            assetId: 'ass',
            path: styled,
            kind: ManagedSubtitleAssetKind.imported,
            displayName: '中文',
            language: 'zh',
            createdAt: 2,
          ),
        ],
        danmakuPath: danmaku,
      );

      final layout = buildZipExportLayout(
        library: library,
        rootIds: const <String>['clip'],
        packageName: '包',
        subtitleMode: ZipSubtitleMode.embed,
        includeDanmaku: true,
        factsFor: (_) => const ZipSourceFacts(
          hasAttachedCover: true,
          fileChapters: <MediaChapter>[],
        ),
      );
      final media = layout.media.single;
      expect(media.remux, isTrue);
      expect(media.archivePath, '包/讲座.mkv');
      expect(media.embedTracks.map((track) => track.title), <String>[
        '主字幕',
        '中文',
        '弹幕',
      ]);
      expect(media.embedTracks.last.isDefault, isFalse);
      expect(media.sidecars, isEmpty);

      final args = buildZipRemuxArguments(
        sourcePath: media.sourcePath,
        outputPath: 'out.mkv',
        tracks: media.embedTracks,
        coverPath: null,
        chapterMetadataPath: null,
        existingSubtitleStreams: 1,
        existingVideoStreams: 1,
        outputIsMp4Family: false,
        progressPipe: true,
      );
      expect(args, contains('copy'));
      expect(args, isNot(contains('libx264')));
      expect(args, isNot(contains('mov_text')));
      expect(args, contains('-c:s:1'));
      expect(args[args.indexOf('-disposition:s:3') + 1], '0');
    });

    test('plain subtitles stay in mp4 and chapters already in the file are kept', () async {
      final video = _file(tempDir, 'source.mp4');
      final primary = _file(tempDir, 'primary.srt');
      const chapters = <MediaChapter>[
        MediaChapter(title: '开场', startMs: 0, endMs: 1000),
      ];
      await _add(
        library,
        id: 'clip',
        path: video,
        title: '课',
        parentId: null,
        subtitlePath: primary,
        chapters: chapters,
      );
      final layout = buildZipExportLayout(
        library: library,
        rootIds: const <String>['clip'],
        packageName: '包',
        subtitleMode: ZipSubtitleMode.embed,
        includeDanmaku: false,
        factsFor: (_) => const ZipSourceFacts(
          hasAttachedCover: true,
          fileChapters: chapters,
        ),
      );
      final media = layout.media.single;
      expect(media.archivePath, '包/课.mp4');
      expect(media.replacementChapters, isNull);
      expect(media.embedTracks.single.isDefault, isTrue);
    });

    test('writes app chapters and a cover only when the file does not have them', () async {
      final video = _file(tempDir, 'song.m4a');
      final cover = _file(tempDir, 'cover.jpg');
      await _add(
        library,
        id: 'song',
        path: video,
        title: '歌',
        parentId: null,
        thumbnailPath: cover,
        chapters: const <MediaChapter>[
          MediaChapter(title: '副歌', startMs: 5000, endMs: 8000),
        ],
      );
      final layout = buildZipExportLayout(
        library: library,
        rootIds: const <String>['song'],
        packageName: '包',
        subtitleMode: ZipSubtitleMode.none,
        includeDanmaku: false,
        factsFor: (_) => const ZipSourceFacts(
          hasAttachedCover: false,
          videoStreamCount: 0,
          fileChapters: <MediaChapter>[],
        ),
      );
      final media = layout.media.single;
      expect(media.remux, isTrue);
      expect(media.coverPath, cover);
      expect(media.replacementChapters, isNotNull);
      expect(media.archivePath, '包/歌.m4a');
    });

    test('external subtitles sit beside the video and danmaku stays named', () async {
      final video = _file(tempDir, 'source.mp4');
      final zh = _file(tempDir, 'zh.srt');
      final en = _file(tempDir, 'en.vtt');
      final danmaku = _file(tempDir, 'dm.ass');
      await _add(
        library,
        id: 'clip',
        path: video,
        title: '对话',
        parentId: null,
        subtitlePath: zh,
        secondarySubtitlePath: en,
        danmakuPath: danmaku,
      );
      final layout = buildZipExportLayout(
        library: library,
        rootIds: const <String>['clip'],
        packageName: '包',
        subtitleMode: ZipSubtitleMode.external,
        includeDanmaku: true,
        factsFor: (_) => const ZipSourceFacts(hasAttachedCover: true),
      );
      final media = layout.media.single;
      expect(media.remux, isFalse);
      expect(media.embedTracks, isEmpty);
      expect(media.sidecars.map((item) => item.archivePath), <String>[
        '包/对话.主字幕.srt',
        '包/对话.副字幕.vtt',
        '包/对话.弹幕.ass',
      ]);
    });

    test('retries the full remux once, then subtitles only, then stops', () {
      const full = ZipRemuxPlan(
        tracks: <ZipSubtitleTrack>[
          ZipSubtitleTrack(
            path: 'a.srt',
            title: '主字幕',
            language: null,
            isDefault: true,
            isDanmaku: false,
          ),
        ],
        includeCover: true,
        includeChapters: true,
      );
      expect(zipRemuxAttemptAfterFailures(full, 1)!.includeCover, isTrue);
      final third = zipRemuxAttemptAfterFailures(full, 2)!;
      expect(third.includeCover, isFalse);
      expect(third.includeChapters, isFalse);
      expect(third.tracks, isNotEmpty);
      expect(zipRemuxAttemptAfterFailures(full, 3), isNull);
      expect(
        zipRemuxAttemptAfterFailures(full.withoutExtras(), 2),
        isNull,
      );
    });

    test('sanitizes names and reads ffmpeg progress', () {
      expect(sanitizeZipName('a:b/c'), 'a b c');
      expect(sanitizeZipName('CON'), '_CON');
      expect(sanitizeZipName('   '), '未命名');
      expect(zipFfmpegProgressFraction('out_time_ms=2500000', 5000), 0.5);
      expect(
        buildZipExportSummary(
          mediaCount: 2,
          outputBytes: 2048,
          skippedOnline: 1,
          skippedMissing: 0,
          sidecarFallbacks: 1,
          keptOriginals: 0,
          droppedExtras: 0,
        ),
        '2 个媒体 · 2.0 KB · 已跳过 1 个在线卡片 · 1 个改为外挂字幕',
      );
    });
  });
}

String _file(Directory directory, String name) {
  final file = File(p.join(directory.path, name));
  file.writeAsStringSync('x');
  return file.path;
}

Future<void> _add(
  LibraryService library, {
  required String id,
  required String path,
  required String title,
  required String? parentId,
  bool online = false,
  String? subtitlePath,
  String? secondarySubtitlePath,
  String? danmakuPath,
  String? thumbnailPath,
  List<ManagedSubtitleAsset> managed = const <ManagedSubtitleAsset>[],
  List<MediaChapter> chapters = const <MediaChapter>[],
}) async {
  library.seedVideoForTesting(
    VideoItem(
      id: id,
      path: path,
      title: title,
      durationMs: 1000,
      lastUpdated: 1,
      parentId: 'pending',
      hasProbedChapters: true,
      subtitlePath: subtitlePath,
      secondarySubtitlePath: secondarySubtitlePath,
      danmakuPath: danmakuPath,
      thumbnailPath: thumbnailPath,
      managedSubtitleAssets: managed,
      chapters: chapters,
      sourceRef: online
          ? const MediaSourceRef(value: 'bv', kind: MediaSourceKind.bilibiliStream)
          : null,
    ),
  );
  await library.moveItemToCollection(id, parentId);
}
