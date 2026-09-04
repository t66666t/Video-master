import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:video_player_app/models/subtitle_source_type.dart';
import 'package:video_player_app/services/subtitle_discovery_service.dart';
import 'package:video_player_app/utils/subtitle_file_matcher.dart';

void main() {
  test(
    'discovery returns full candidates and sorts auto group by language weight',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'subtitle_discovery_test_',
      );
      addTearDown(() async {
        if (await directory.exists()) {
          await directory.delete(recursive: true);
        }
      });

      final videoPath = p.join(directory.path, 'Episode 01.mkv');
      await File(videoPath).writeAsBytes(const <int>[0]);

      // 语言权重期望顺序：zh-Hans(0) → zh-Hant(1) → 无标记(2) → en(3)。
      final files = <String, String>{
        'Episode 01.zh-CN.srt': 'zh',
        'Episode 01.srt': 'none',
        'Episode 01.cht.srt': 'cht',
        'Episode 01.en.ass': 'en',
        'Episode 010.srt': 'unrelated-numeric',
        'Other Movie.srt': 'other-movie',
      };
      for (final entry in files.entries) {
        await File(p.join(directory.path, entry.key))
            .writeAsString(entry.value);
      }

      final entries = await const SubtitleDiscoveryService().scanVideoDirectory(
        videoPath: videoPath,
      );

      final byName = <String, DiscoveredSubtitleFile>{
        for (final e in entries) p.basename(e.path): e,
      };
      // 全量候选都应返回（供手动面板展示），来源均为 sidecar。
      expect(
        entries.map((e) => p.basename(e.path)).toSet(),
        containsAll(files.keys),
      );
      expect(
        entries.map((e) => e.sourceType),
        everyElement(SubtitleSourceType.sidecar),
      );

      final autos = entries.where((e) => e.isAuto).toList();
      expect(
        autos.map((e) => p.basename(e.path)),
        <String>[
          'Episode 01.zh-CN.srt',
          'Episode 01.cht.srt',
          'Episode 01.srt',
          'Episode 01.en.ass',
        ],
      );
      expect(byName['Episode 010.srt']!.grade, SubtitleMatchGrade.rejected);
      expect(byName['Other Movie.srt']!.grade, SubtitleMatchGrade.rejected);
      expect(byName['Episode 01.en.ass']!.analysis.languageCode, 'en');
    },
  );

  test(
    'duration mismatch demotes an auto candidate and keeps it out of autos',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'subtitle_duration_test_',
      );
      addTearDown(() async {
        if (await directory.exists()) {
          await directory.delete(recursive: true);
        }
      });

      final videoPath = p.join(directory.path, 'Movie.mp4');
      await File(videoPath).writeAsBytes(const <int>[0]);
      // 视频时长约 60 秒。
      const videoDurationMs = 60 * 1000;

      // 时长接近 60s → 应保持 auto 并排在前面。
      final good = File(p.join(directory.path, 'Movie.zh.srt'));
      await good.writeAsString(
        '1\n00:00:00,000 --> 00:00:59,500\n内容\n',
      );
      // 时长只有 5s（明显不符）→ 由 auto 降级为 manual，禁止自动匹配。
      final short = File(p.join(directory.path, 'Movie.srt'));
      await short.writeAsString(
        '1\n00:00:00,000 --> 00:00:05,000\n片段\n',
      );

      final entries = await const SubtitleDiscoveryService().scanVideoDirectory(
        videoPath: videoPath,
        videoDurationMs: videoDurationMs,
      );

      final byName = <String, DiscoveredSubtitleFile>{
        for (final e in entries) p.basename(e.path): e,
      };
      final autos = entries.where((e) => e.isAuto).toList();
      expect(autos.map((e) => p.basename(e.path)), <String>['Movie.zh.srt']);
      expect(byName['Movie.srt']!.grade, SubtitleMatchGrade.manualOnly);

      // 控制变量：不提供视频时长时不做否决，两者都是 auto。
      final entriesNoDuration =
          await const SubtitleDiscoveryService().scanVideoDirectory(
        videoPath: videoPath,
      );
      expect(
        entriesNoDuration.where((e) => e.isAuto).map((e) => p.basename(e.path)),
        containsAll(<String>['Movie.zh.srt', 'Movie.srt']),
      );
    },
  );
}
