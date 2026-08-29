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

  test('scroll duration scales with viewport width and speed multiplier', () {
    final item = _item(0, 0);

    expect(
      resolveDanmakuDurationUs(
        item,
        speed: 1,
        viewportWidth: 1920,
        referenceWidth: 1920,
      ),
      const Duration(seconds: 6).inMicroseconds,
    );
    expect(
      resolveDanmakuDurationUs(
        item,
        speed: 1,
        viewportWidth: 3840,
        referenceWidth: 1920,
      ),
      const Duration(seconds: 12).inMicroseconds,
    );
    expect(
      resolveDanmakuDurationUs(
        item,
        speed: 2,
        viewportWidth: 3840,
        referenceWidth: 1920,
      ),
      const Duration(seconds: 6).inMicroseconds,
    );
  });

  test('fixed danmaku dwell time does not scale with viewport width', () {
    final source = _item(0, 0);
    final item = DanmakuItem(
      index: source.index,
      startTime: source.startTime,
      duration: source.duration,
      text: source.text,
      type: DanmakuType.top,
      colorValue: source.colorValue,
      sourceY: source.sourceY,
    );

    expect(
      resolveDanmakuDurationUs(
        item,
        speed: 1,
        viewportWidth: 3840,
        referenceWidth: 1920,
      ),
      const Duration(seconds: 6).inMicroseconds,
    );

    final activeSet = DanmakuActiveSet(<DanmakuItem>[item]);
    expect(
      activeSet.update(
        positionUs: const Duration(seconds: 5).inMicroseconds,
        speed: 1,
        admissionCap: 0x3fffffff,
        viewportWidth: 320,
        referenceWidth: 1920,
      ),
      <int>[0],
    );
  });

  test('wide viewport keeps scrolling items active for the longer travel', () {
    final activeSet = DanmakuActiveSet(<DanmakuItem>[_item(0, 10)]);

    expect(
      activeSet.update(
        positionUs: const Duration(seconds: 17).inMicroseconds,
        speed: 1,
        admissionCap: 0x3fffffff,
        viewportWidth: 3840,
        referenceWidth: 1920,
      ),
      <int>[0],
    );
  });

  test('atlas destinations snap to physical pixels', () {
    expect(snapDanmakuLogicalPixel(10.3, 1.25), closeTo(10.4, 0.0001));
    expect(snapDanmakuLogicalPixel(10.3, double.nan), 10);
  });

  test('lowering the overload cap immediately trims an active burst', () {
    final items = <DanmakuItem>[for (var i = 0; i < 1000; i++) _item(i, 10)];
    final activeSet = DanmakuActiveSet(items);

    expect(
      activeSet.update(
        positionUs: const Duration(seconds: 11).inMicroseconds,
        speed: 1,
        admissionCap: 0x3fffffff,
      ),
      hasLength(1000),
    );

    final trimmed = activeSet.update(
      positionUs: const Duration(seconds: 11, milliseconds: 16).inMicroseconds,
      speed: 1,
      admissionCap: 200,
    );
    expect(trimmed, hasLength(200));
    expect(trimmed, orderedEquals(List<int>.of(trimmed)..sort()));
  });

  test('overload trimming prefers unique text and remains deterministic', () {
    final items = <DanmakuItem>[
      for (var i = 0; i < 20; i++)
        DanmakuItem(
          index: i,
          startTime: const Duration(seconds: 10),
          duration: const Duration(seconds: 6),
          text: i < 10 ? '重复' : '弹幕 $i',
          type: DanmakuType.scroll,
          colorValue: 0xFFFFFFFF,
          sourceY: 40,
        ),
    ];

    List<int> resolve() {
      final activeSet = DanmakuActiveSet(items);
      activeSet.update(
        positionUs: const Duration(seconds: 11).inMicroseconds,
        speed: 1,
        admissionCap: 0x3fffffff,
      );
      return List<int>.of(
        activeSet.update(
          positionUs: const Duration(
            seconds: 11,
            milliseconds: 16,
          ).inMicroseconds,
          speed: 1,
          admissionCap: 8,
        ),
      );
    }

    final first = resolve();
    final second = resolve();
    expect(first, second);
    expect(first.map((index) => items[index].text).toSet(), hasLength(8));
  });
}
