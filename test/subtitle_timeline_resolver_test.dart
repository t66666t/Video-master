import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/services/subtitle_timeline_resolver.dart';

SubtitleItem _subtitle(
  int index,
  int startMs,
  int endMs,
  String text,
) {
  return SubtitleItem(
    index: index,
    startTime: Duration(milliseconds: startMs),
    endTime: Duration(milliseconds: endMs),
    text: text,
  );
}

void main() {
  group('SubtitleTimelineResolver', () {
    final subtitles = <SubtitleItem>[
      _subtitle(1, 1000, 2000, 'first'),
      _subtitle(2, 2000, 3200, 'second'),
      _subtitle(3, 4000, 5200, 'third'),
    ];
    final resolver = SubtitleTimelineResolver(subtitles);

    test('在字幕区间内返回当前字幕索引', () {
      expect(resolver.indexAtMs(1000), 0);
      expect(resolver.indexAtMs(1999), 0);
      expect(resolver.indexAtMs(2000), 1);
      expect(resolver.indexAtMs(4500), 2);
    });

    test('遵循现有时间轴规则处理间隙与越界', () {
      expect(resolver.indexAtMs(999), -1);
      expect(resolver.indexAtMs(3200), 1);
      expect(resolver.indexAtMs(3999), 1);
      expect(resolver.indexAtMs(5300), -1);
      expect(
        resolver.subtitleAt(const Duration(milliseconds: 3200))?.text,
        'second',
      );
    });

    test('preferredIndex 命中当前或下一条字幕', () {
      expect(resolver.indexAtMs(1500, preferredIndex: 0), 0);
      expect(resolver.indexAtMs(2100, preferredIndex: 0), 1);
      expect(resolver.indexAtMs(4500, preferredIndex: 1), 2);
    });

    test('可计算下一个字幕边界', () {
      expect(
        resolver.nextBoundaryAfter(const Duration(milliseconds: 1500)),
        const Duration(milliseconds: 2000),
      );
      expect(
        resolver.nextBoundaryAfter(const Duration(milliseconds: 3200)),
        const Duration(milliseconds: 4000),
      );
      expect(
        resolver.nextBoundaryAfter(const Duration(milliseconds: 4500)),
        const Duration(milliseconds: 5200),
      );
      expect(
        resolver.nextBoundaryAfter(const Duration(milliseconds: 5200)),
        isNull,
      );
    });
  });
}
