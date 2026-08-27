import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/models/danmaku_model.dart';
import 'package:video_player_app/widgets/danmaku_overlay.dart';

DanmakuItem _item(int index, int startSeconds) {
  return DanmakuItem(
    index: index,
    startTime: Duration(seconds: startSeconds),
    duration: const Duration(seconds: 6),
    text: '弹幕 $index',
    type: DanmakuType.scroll,
    colorValue: 0xFFFFFFFF,
    sourceY: 40,
  );
}

void main() {
  test('active range is found with binary-search boundaries', () {
    final items = <DanmakuItem>[for (var i = 0; i < 40; i++) _item(i, i)];

    final normal = resolveDanmakuActiveRange(
      items,
      positionUs: const Duration(seconds: 20).inMicroseconds,
      speed: 1,
    );
    expect(normal.start, 4);
    expect(normal.endExclusive, 21);

    final fast = resolveDanmakuActiveRange(
      items,
      positionUs: const Duration(seconds: 20).inMicroseconds,
      speed: 2,
    );
    expect(fast.start, 12);
    expect(fast.endExclusive, 21);
  });

  test('prefetch keeps a 640-item active burst available for the atlas', () {
    final items = <DanmakuItem>[for (var i = 0; i < 1000; i++) _item(i, 10)];

    final indices = resolveDanmakuPrefetchIndices(
      items,
      positionUs: const Duration(seconds: 10).inMicroseconds,
      speed: 1,
    );

    expect(indices, hasLength(640));
    expect(indices.first, 999);
    expect(indices.last, 360);
  });

  test('prefetch includes a ten-second upcoming window', () {
    final items = <DanmakuItem>[for (var i = 0; i < 30; i++) _item(i, i)];

    final indices = resolveDanmakuPrefetchIndices(
      items,
      positionUs: const Duration(seconds: 10).inMicroseconds,
      speed: 1,
    );

    expect(indices, containsAll(<int>[11, 12, 13, 14, 15, 16, 17, 18, 19, 20]));
    expect(indices, isNot(contains(21)));
  });

  test('prefetch rounds future work to a stable five-second atlas segment', () {
    final items = <DanmakuItem>[for (var i = 0; i < 40; i++) _item(i, i)];

    final indices = resolveDanmakuPrefetchIndices(
      items,
      positionUs: const Duration(seconds: 11).inMicroseconds,
      speed: 1,
    );

    // 11s + 10s look-ahead is rounded to the end of the 20-25s segment,
    // so the entire segment is rasterized as a page instead of one tiny page
    // per subsequent maintenance tick.
    expect(indices, contains(25));
    expect(indices, isNot(contains(26)));
  });
}
