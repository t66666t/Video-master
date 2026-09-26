import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/widgets/media_library_activity_menu.dart';
import 'package:video_player_app/widgets/media_library_anchor_menu.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late LibraryService library;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    library = LibraryService();
    library.resetLibraryForTesting();
    library.seedVideoForTesting(
      VideoItem(
        id: 'clip',
        path: '/tmp/clip.mp4',
        title: 'clip',
        durationMs: 1000,
        lastUpdated: 1,
        hasProbedChapters: true,
      ),
    );
  });

  tearDown(() {
    library.resetLibraryForTesting();
  });

  testWidgets('activity menu stays on screen and dismisses from a blank tap', (
    tester,
  ) async {
    await tester.pumpWidget(
      ChangeNotifierProvider<LibraryService>.value(
        value: library,
        child: MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomRight,
              child: MediaLibraryActivityMenuButton(
                targetId: 'clip',
                isCollection: false,
                allowHide: true,
                onLocate: () {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('media-library-activity-menu')));
    await tester.pumpAndSettle();
    expect(find.text('置顶到「继续学习」'), findsOneWidget);
    expect(find.text('显示所在目录'), findsOneWidget);
    expect(find.text('导出'), findsOneWidget);
    expect(find.text('移入回收站'), findsOneWidget);
    expect(find.text('从本页移除'), findsOneWidget);
    expect(find.text('移动到上一级'), findsNothing);

    final menu = tester.getRect(find.text('置顶到「继续学习」'));
    final screen = tester.getRect(find.byType(MaterialApp));
    expect(menu.left >= screen.left, isTrue);
    expect(menu.right <= screen.right, isTrue);
    expect(menu.top >= screen.top, isTrue);
    expect(menu.bottom <= screen.bottom, isTrue);

    await tester.tapAt(const Offset(12, 12));
    await tester.pumpAndSettle();
    expect(find.text('置顶到「继续学习」'), findsNothing);
  });

  testWidgets('move to parent appears only when the folder page provides it', (
    tester,
  ) async {
    var moved = 0;
    await tester.pumpWidget(
      ChangeNotifierProvider<LibraryService>.value(
        value: library,
        child: MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: MediaLibraryActivityMenuButton(
                targetId: 'clip',
                isCollection: false,
                onMoveToParent: () => moved += 1,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('media-library-activity-menu')));
    await tester.pumpAndSettle();
    expect(find.text('移动到上一级'), findsOneWidget);
    expect(find.text('从本页移除'), findsNothing);

    await tester.tap(find.text('移动到上一级'));
    await tester.pumpAndSettle();
    expect(moved, 1);
    expect(find.text('移动到上一级'), findsNothing);
  });

  test('menu glyph follows card width instead of a 24px floor', () {
    expect(MediaLibraryActivityMenuMetrics.glyphSize(103), closeTo(12.36, 0.05));
    expect(MediaLibraryActivityMenuMetrics.layoutSize(103) < 24, isTrue);
    expect(MediaLibraryActivityMenuMetrics.hitSize(103), closeTo(37.08, 0.05));
    expect(MediaLibraryActivityMenuMetrics.glyphSize(280), 20);
    expect(MediaLibraryActivityMenuMetrics.hitSize(280), 40);
  });

  test('anchor menu stays compact on phone tablet and desktop', () {
    final phone = MediaLibraryAnchorMenuMetrics.of(const Size(390, 844));
    expect(phone.width, lessThan(230));
    expect(phone.width, greaterThan(160));
    expect(phone.rowHeight, 38);

    final tablet = MediaLibraryAnchorMenuMetrics.of(const Size(820, 1180));
    expect(tablet.width, inInclusiveRange(180, 240));
    expect(tablet.rowHeight, lessThan(44));

    final desktop = MediaLibraryAnchorMenuMetrics.of(const Size(1920, 1080));
    expect(desktop.width, lessThan(220));
    expect(desktop.rowHeight, 32);
    expect(desktop.fontSize, 13);
  });
}
