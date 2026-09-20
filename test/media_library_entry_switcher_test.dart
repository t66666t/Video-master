import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/models/media_library_root_entry.dart';
import 'package:video_player_app/widgets/media_library_entry_switcher.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('selects on pointer down so a short click is not waiting on splash', (
    tester,
  ) async {
    MediaLibraryRootEntry selected = MediaLibraryRootEntry.folders;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          appBar: AppBar(
            title: MediaLibraryEntrySwitcher(
              selected: selected,
              availableEntries: MediaLibraryRootEntry.values.toSet(),
              onSelected: (entry) => selected = entry,
            ),
          ),
        ),
      ),
    );

    final gesture = await tester.startGesture(
      tester.getCenter(find.text('最近添加')),
    );
    await tester.pump();
    expect(selected, MediaLibraryRootEntry.folders);

    await gesture.up();
    await tester.pump();
    expect(selected, MediaLibraryRootEntry.recent);
    expect(find.byType(InkWell), findsNothing);
  });

  testWidgets('padding around the label is still tappable', (tester) async {
    MediaLibraryRootEntry selected = MediaLibraryRootEntry.folders;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          appBar: AppBar(
            title: MediaLibraryEntrySwitcher(
              selected: selected,
              availableEntries: MediaLibraryRootEntry.values.toSet(),
              onSelected: (entry) => selected = entry,
            ),
          ),
        ),
      ),
    );

    final label = tester.getRect(find.text('最近添加'));
    await tester.tapAt(Offset(label.center.dx, label.top - 5));
    await tester.pump();
    expect(selected, MediaLibraryRootEntry.recent);
  });

  testWidgets('fractional highlight paints the neighbor chip', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          appBar: AppBar(
            title: MediaLibraryEntrySwitcher(
              selected: MediaLibraryRootEntry.continueLearning,
              highlightIndex: 1,
              availableEntries: MediaLibraryRootEntry.values.toSet(),
              onSelected: (_) {},
            ),
          ),
        ),
      ),
    );

    final foldersChip = tester.widget<Text>(find.text('文件夹'));
    final continueChip = tester.widget<Text>(find.text('继续学习'));
    expect(
      foldersChip.style?.color,
      Color.lerp(Colors.white70, Colors.blueAccent, 1),
    );
    expect(
      continueChip.style?.color,
      Color.lerp(Colors.white70, Colors.blueAccent, 0),
    );
  });

  testWidgets('default chip order puts folders between the activity pages', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          appBar: AppBar(
            title: MediaLibraryEntrySwitcher(
              selected: MediaLibraryRootEntry.folders,
              availableEntries: MediaLibraryRootEntry.values.toSet(),
              onSelected: (_) {},
            ),
          ),
        ),
      ),
    );

    final continueX = tester.getTopLeft(find.text('继续学习')).dx;
    final foldersX = tester.getTopLeft(find.text('文件夹')).dx;
    final recentX = tester.getTopLeft(find.text('最近添加')).dx;
    expect(continueX < foldersX, isTrue);
    expect(foldersX < recentX, isTrue);
  });
}
