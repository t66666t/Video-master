import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:video_player_app/models/subtitle_source_type.dart';
import 'package:video_player_app/services/subtitle_discovery_service.dart';
import 'package:video_player_app/utils/subtitle_file_matcher.dart';

void main() {
  group('SubtitleFileMatcher', () {
    const recommended = SubtitleScanRules.defaults;
    const video = r'C:\Videos\Movie.mkv';

    test('recommended mode accepts exact and conventional suffixes', () {
      expect(
        SubtitleFileMatcher.matches(
          videoPath: video,
          subtitlePath: r'C:\Videos\Movie.srt',
          rules: recommended,
        ),
        isTrue,
      );
      expect(
        SubtitleFileMatcher.matches(
          videoPath: video,
          subtitlePath: r'C:\Videos\Movie.zh-CN.ass',
          rules: recommended,
        ),
        isTrue,
      );
      expect(
        SubtitleFileMatcher.matches(
          videoPath: video,
          subtitlePath: r'C:\Videos\Movie [English].vtt',
          rules: recommended,
        ),
        isTrue,
      );
    });

    test('recommended mode rejects broad prefixes and unsupported files', () {
      for (final path in <String>[
        r'C:\Videos\Movie2.srt',
        r'C:\Videos\MovieTrailer.srt',
        r'C:\Videos\Movie.txt',
        r'C:\Videos\Movie.stream_0.srt',
      ]) {
        expect(
          SubtitleFileMatcher.matches(
            videoPath: video,
            subtitlePath: path,
            rules: recommended,
          ),
          isFalse,
          reason: path,
        );
      }
    });

    test('case sensitivity and prefix modes are configurable', () {
      expect(
        SubtitleFileMatcher.matches(
          videoPath: video,
          subtitlePath: r'C:\Videos\movie.srt',
          rules: recommended,
        ),
        isTrue,
      );
      expect(
        SubtitleFileMatcher.matches(
          videoPath: video,
          subtitlePath: r'C:\Videos\movie.srt',
          rules: const SubtitleScanRules(caseSensitive: true),
        ),
        isFalse,
      );
      expect(
        SubtitleFileMatcher.matches(
          videoPath: video,
          subtitlePath: r'C:\Videos\Movie2.srt',
          rules: const SubtitleScanRules(
            prefixMatchMode: SubtitlePrefixMatchMode.startsWith,
          ),
        ),
        isTrue,
      );
      expect(
        SubtitleFileMatcher.matches(
          videoPath: video,
          subtitlePath: r'C:\Videos\Movie.zh.srt',
          rules: const SubtitleScanRules(
            prefixMatchMode: SubtitlePrefixMatchMode.exactOnly,
          ),
        ),
        isFalse,
      );
    });
  });

  test(
    'discovery returns every match and prioritizes the exact name',
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
      final exact = File(p.join(directory.path, 'Episode 01.srt'));
      final chinese = File(p.join(directory.path, 'Episode 01.zh-CN.srt'));
      final english = File(p.join(directory.path, 'Episode 01.en.ass'));
      final unrelated = File(p.join(directory.path, 'Episode 010.srt'));
      await exact.writeAsString('exact');
      await chinese.writeAsString('chinese');
      await english.writeAsString('english');
      await unrelated.writeAsString('unrelated');
      await chinese.setLastModified(
        DateTime.now().add(const Duration(days: 1)),
      );

      final entries = await const SubtitleDiscoveryService().scanVideoDirectory(
        videoPath: videoPath,
        rules: SubtitleScanRules.defaults,
      );

      expect(entries.map((entry) => p.basename(entry.path)), <String>[
        'Episode 01.srt',
        'Episode 01.zh-CN.srt',
        'Episode 01.en.ass',
      ]);
      expect(
        entries.map((entry) => entry.sourceType),
        everyElement(SubtitleSourceType.sidecar),
      );
    },
  );
}
