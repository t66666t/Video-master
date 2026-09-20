import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/models/media_library_group_expand_policy.dart';

void main() {
  test('tiny groups stay open; huge groups are exclusive candidates', () {
    expect(MediaLibraryGroupExpandPolicy.alwaysExpanded(3), isTrue);
    expect(MediaLibraryGroupExpandPolicy.alwaysExpanded(4), isFalse);
    expect(MediaLibraryGroupExpandPolicy.isHuge(49), isFalse);
    expect(MediaLibraryGroupExpandPolicy.isHuge(50), isTrue);
  });

  test('only the newest small import batch auto-opens', () {
    expect(
      MediaLibraryGroupExpandPolicy.recentDefaultExpanded(
        isNewestMultiItemBatch: true,
        count: 12,
        isUnknownBucket: false,
      ),
      isTrue,
    );
    expect(
      MediaLibraryGroupExpandPolicy.recentDefaultExpanded(
        isNewestMultiItemBatch: true,
        count: 100,
        isUnknownBucket: false,
      ),
      isFalse,
    );
    expect(
      MediaLibraryGroupExpandPolicy.recentDefaultExpanded(
        isNewestMultiItemBatch: false,
        count: 12,
        isUnknownBucket: false,
      ),
      isFalse,
    );
    expect(
      MediaLibraryGroupExpandPolicy.recentDefaultExpanded(
        isNewestMultiItemBatch: false,
        count: 2,
        isUnknownBucket: true,
      ),
      isTrue,
    );
  });

  test('history opens today and a short yesterday, not older days', () {
    final now = DateTime(2026, 9, 20, 12);
    final today = DateTime(2026, 9, 20).millisecondsSinceEpoch;
    final yesterday = DateTime(2026, 9, 19).millisecondsSinceEpoch;
    final older = DateTime(2026, 9, 17).millisecondsSinceEpoch;
    expect(
      MediaLibraryGroupExpandPolicy.historyDefaultExpanded(
        count: 20,
        dayStartMs: today,
        now: now,
      ),
      isTrue,
    );
    expect(
      MediaLibraryGroupExpandPolicy.historyDefaultExpanded(
        count: 12,
        dayStartMs: yesterday,
        now: now,
      ),
      isTrue,
    );
    expect(
      MediaLibraryGroupExpandPolicy.historyDefaultExpanded(
        count: 13,
        dayStartMs: yesterday,
        now: now,
      ),
      isFalse,
    );
    expect(
      MediaLibraryGroupExpandPolicy.historyDefaultExpanded(
        count: 4,
        dayStartMs: older,
        now: now,
      ),
      isFalse,
    );
    expect(
      MediaLibraryGroupExpandPolicy.historyDefaultExpanded(
        count: 8,
        dayStartMs: 0,
        now: now,
      ),
      isFalse,
    );
  });

  test('user close wins over the default on the next read', () {
    final memory = MediaLibraryGroupExpandMemory();
    expect(memory.isExpanded('a', defaultExpanded: true), isTrue);
    memory.toggle('a', currentlyExpanded: true);
    expect(memory.isExpanded('a', defaultExpanded: true), isFalse);
    memory.forceOpen('a');
    expect(memory.isExpanded('a', defaultExpanded: false), isTrue);
  });
}
