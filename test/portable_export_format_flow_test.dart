import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/portable_transfer/portable_export_format_page.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/library_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('export settings can return to the format choice', (tester) async {
    final library = LibraryService();
    library.writeLibrarySnapshotOverrideForTesting = () async {};
    addTearDown(library.resetLibraryForTesting);
    library.seedVideoForTesting(
      VideoItem(
        id: 'clip',
        path: 'C:/unused/clip.mp4',
        title: 'clip',
        durationMs: 1000,
        lastUpdated: 1,
        parentId: 'pending',
        hasProbedChapters: true,
      ),
    );
    await library.moveItemToCollection('clip', null);

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: PortableExportFormatPage(
          library: library,
          rootIds: const <String>['clip'],
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('export-format-zip')));
    await tester.pumpAndSettle();
    expect(find.text('Zip 导出设置'), findsOneWidget);
    expect(find.text('软字幕内嵌'), findsOneWidget);
    expect(find.text('最外层包一层文件夹'), findsNothing);

    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.text('选择导出格式'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('export-format-fluentpack')));
    await tester.pumpAndSettle();
    expect(find.text('最外层包一层文件夹'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('选择导出格式'), findsOneWidget);
    expect(find.text('Fluent Pack'), findsOneWidget);
    expect(find.text('Zip'), findsOneWidget);
  });
}
