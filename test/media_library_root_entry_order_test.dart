import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/models/media_library_root_entry.dart';
import 'package:video_player_app/models/media_library_root_entry_order.dart';

void main() {
  test('empty storage uses folders in the middle', () {
    expect(
      MediaLibraryRootEntryOrder.parse(''),
      MediaLibraryRootEntryOrder.defaults,
    );
    expect(MediaLibraryRootEntryOrder.defaults, [
      MediaLibraryRootEntry.continueLearning,
      MediaLibraryRootEntry.folders,
      MediaLibraryRootEntry.recent,
    ]);
  });

  test('parse fills missing pages and drops unknown tokens', () {
    expect(MediaLibraryRootEntryOrder.parse('recent,nope'), [
      MediaLibraryRootEntry.recent,
      MediaLibraryRootEntry.continueLearning,
      MediaLibraryRootEntry.folders,
    ]);
  });

  test('moved uses Flutter onReorder indices', () {
    final order = MediaLibraryRootEntryOrder.defaults;
    expect(
      MediaLibraryRootEntryOrder.moved(order, oldIndex: 1, newIndex: 0),
      [
        MediaLibraryRootEntry.folders,
        MediaLibraryRootEntry.continueLearning,
        MediaLibraryRootEntry.recent,
      ],
    );
    expect(
      MediaLibraryRootEntryOrder.moved(order, oldIndex: 0, newIndex: 2),
      [
        MediaLibraryRootEntry.folders,
        MediaLibraryRootEntry.recent,
        MediaLibraryRootEntry.continueLearning,
      ],
    );
  });
}
