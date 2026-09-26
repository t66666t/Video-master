import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/library_activity.dart';
import 'package:video_player_app/models/video_collection.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/widgets/media_library_continue_view.dart';
import 'package:video_player_app/widgets/media_library_item_interaction_wrapper.dart';
import 'package:video_player_app/widgets/media_library_list_tile.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late LibraryService library;
  late ScrollController scroll;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    SettingsService().resetForTest();
    library = LibraryService();
    library.resetLibraryForTesting();
    library.writeLibrarySnapshotOverrideForTesting = () async {};
    scroll = ScrollController();
  });

  tearDown(() {
    scroll.dispose();
    library.resetLibraryForTesting();
    SettingsService().resetForTest();
  });

  testWidgets('empty continue view offers recent and folder shortcuts', (
    tester,
  ) async {
    await tester.pumpWidget(await _harness(library, scroll));
    await tester.pump();
    expect(find.text('全部记录'), findsOneWidget);
    expect(find.textContaining('播放过的媒体会出现在这里'), findsOneWidget);
    expect(find.text('前往最近添加'), findsOneWidget);
    expect(find.text('前往文件夹'), findsOneWidget);
  });

  testWidgets('small folder groups show every card without expanding', (
    tester,
  ) async {
    library.seedCollectionForTesting(
      VideoCollection(id: 'course', name: 'Course', createTime: 1),
    );
    library.seedVideoForTesting(_clip('ep1', parentId: 'course'));
    library.seedVideoForTesting(_clip('ep2', parentId: 'course'));
    library.seedMediaActivityForTesting(
      MediaActivityRecord(
        mediaId: 'ep1',
        lastPlayedAtMs: 10,
        accumulatedWatchMs: 40000,
      ),
    );
    library.seedMediaActivityForTesting(
      MediaActivityRecord(
        mediaId: 'ep2',
        lastPlayedAtMs: 20,
        accumulatedWatchMs: 40000,
      ),
    );
    library.notifyListeners();

    await tester.pumpWidget(await _harness(library, scroll, seriousOnly: true));
    await tester.pump();

    expect(find.text('Course·当前2项'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(MediaLibraryListTile),
        matching: find.text('ep1'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byType(MediaLibraryListTile),
        matching: find.text('ep2'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('large folder keeps a playable featured card while collapsed', (
    tester,
  ) async {
    String? opened;
    String? openedFolder;
    library.seedCollectionForTesting(
      VideoCollection(id: 'course', name: 'Course', createTime: 1),
    );
    for (var i = 1; i <= 4; i++) {
      library.seedVideoForTesting(_clip('ep$i', parentId: 'course'));
      library.seedMediaActivityForTesting(
        MediaActivityRecord(
          mediaId: 'ep$i',
          lastPlayedAtMs: i * 10,
          accumulatedWatchMs: 40000,
        ),
      );
    }
    library.notifyListeners();

    await tester.pumpWidget(
      await _harness(
        library,
        scroll,
        onOpen: (id) => opened = id,
        onOpenFolder: (id) => openedFolder = id,
        seriousOnly: true,
      ),
    );
    await tester.pump();

    expect(find.text('Course·当前4项'), findsOneWidget);
    expect(find.text('其余3'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(MediaLibraryListTile),
        matching: find.text('ep4'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byType(MediaLibraryListTile),
        matching: find.text('ep1'),
      ),
      findsNothing,
    );

    await tester.tap(
      find.descendant(
        of: find.byType(MediaLibraryListTile),
        matching: find.text('ep4'),
      ),
    );
    await tester.pump();
    expect(opened, 'ep4');

    await tester.tap(find.text('Course·当前4项'));
    await tester.pump();
    expect(
      find.descendant(
        of: find.byType(MediaLibraryListTile),
        matching: find.text('ep1'),
      ),
      findsOneWidget,
    );

    await tester.tap(find.byTooltip('打开此目录'));
    await tester.pump();
    expect(openedFolder, 'course');
  });

  testWidgets('older history days stay collapsed until opened', (tester) async {
    final playedAt = DateTime.now()
        .subtract(const Duration(days: 3))
        .millisecondsSinceEpoch;
    for (var i = 0; i < 4; i++) {
      library.seedVideoForTesting(_clip('old$i'));
      library.seedMediaActivityForTesting(
        MediaActivityRecord(
          mediaId: 'old$i',
          lastPlayedAtMs: playedAt - i,
          accumulatedWatchMs: 1200,
          continueEnrolled: false,
        ),
      );
    }
    library.notifyListeners();

    await tester.pumpWidget(await _harness(library, scroll));
    await tester.pump();

    expect(find.textContaining('·4项'), findsOneWidget);
    expect(find.text('old0'), findsNothing);

    await tester.tap(find.textContaining('·4项'));
    await tester.pump();
    expect(find.text('old0'), findsOneWidget);
  });

  testWidgets('opening a continue row uses the host playback callback', (
    tester,
  ) async {
    String? opened;
    library.seedVideoForTesting(_clip('solo'));
    library.seedMediaActivityForTesting(
      MediaActivityRecord(
        mediaId: 'solo',
        lastPlayedAtMs: 5,
        accumulatedWatchMs: 40000,
      ),
    );
    library.notifyListeners();

    await tester.pumpWidget(
      await _harness(
        library,
        scroll,
        onOpen: (id) => opened = id,
        seriousOnly: true,
      ),
    );
    await tester.pump();
    await tester.tap(find.text('solo'));
    await tester.pump();
    expect(opened, 'solo');
  });

  testWidgets('history lists short plays until the serious filter is on', (
    tester,
  ) async {
    library.seedVideoForTesting(_clip('peek'));
    library.seedMediaActivityForTesting(
      MediaActivityRecord(
        mediaId: 'peek',
        lastPlayedAtMs: DateTime.now().millisecondsSinceEpoch,
        accumulatedWatchMs: 1200,
        continueEnrolled: false,
      ),
    );
    library.notifyListeners();

    await tester.pumpWidget(await _harness(library, scroll));
    await tester.pump();
    expect(find.text('peek'), findsOneWidget);
    expect(find.textContaining('今天'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('continueFilterMenu')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('continueFilterSeriousOnly')));
    await tester.pump();
    expect(find.text('peek'), findsNothing);
    expect(find.textContaining('没有符合当前门槛的未完成'), findsOneWidget);
  });

  testWidgets('continue policy sheet opens from the tune button', (
    tester,
  ) async {
    await tester.pumpWidget(await _harness(library, scroll));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('continueFilterMenu')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('continueFilterPolicy')));
    await tester.pumpAndSettle();
    expect(find.text('继续观看门槛'), findsOneWidget);
    expect(find.text('取更容易的'), findsOneWidget);
    expect(find.byKey(const ValueKey('continuePolicyExamples')), findsOneWidget);
  });

  testWidgets('continue policy duration can be typed instead of snapped', (
    tester,
  ) async {
    await tester.pumpWidget(await _harness(library, scroll));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('continueFilterMenu')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('continueFilterPolicy')));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(CupertinoButton, '30秒'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(CupertinoTextField), '25');
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(CupertinoButton, '25秒'), findsOneWidget);
  });

  test('continue learning opens media through prepareLibraryPlayback', () {
    final home = File('lib/screens/home_screen.dart').readAsStringSync();
    expect(home.contains('MediaLibraryContinueView'), isTrue);
    expect(home.contains('_preparePlaybackQueue'), isTrue);
    expect(home.contains('prepareLibraryPlayback'), isTrue);
  });

  testWidgets('two or more pins expose reorder handles', (tester) async {
    library.seedVideoForTesting(_clip('first'));
    library.seedVideoForTesting(_clip('second'));
    library.seedPinnedIdsForTesting(['second', 'first']);
    library.notifyListeners();

    await tester.pumpWidget(await _harness(library, scroll));
    await tester.pump();

    expect(find.byKey(const ValueKey('continue-pin-second')), findsOneWidget);
    expect(find.byKey(const ValueKey('continue-pin-first')), findsOneWidget);
    expect(find.byType(MediaLibraryPinnedReorderWrapper), findsNWidgets(2));
  });

  testWidgets('a single pin is not wrapped for reorder', (tester) async {
    library.seedVideoForTesting(_clip('only'));
    library.seedPinnedIdsForTesting(['only']);
    library.notifyListeners();

    await tester.pumpWidget(await _harness(library, scroll));
    await tester.pump();

    expect(find.byKey(const ValueKey('continue-pin-only')), findsNothing);
    expect(find.text('only'), findsOneWidget);
  });

  testWidgets('pinned folders keep a locate button at root and nested', (
    tester,
  ) async {
    String? located;
    String? openedFolder;
    library.seedCollectionForTesting(
      VideoCollection(id: 'root-folder', name: 'RootFolder', createTime: 1),
    );
    library.seedCollectionForTesting(
      VideoCollection(
        id: 'nested-folder',
        name: 'NestedFolder',
        createTime: 2,
        parentId: 'root-folder',
      ),
    );
    library.seedPinnedIdsForTesting(['root-folder', 'nested-folder']);
    library.notifyListeners();

    await tester.pumpWidget(
      await _harness(
        library,
        scroll,
        onOpenFolder: (id) => openedFolder = id,
        onLocateFolder: (id) => located = id,
      ),
    );
    await tester.pump();

    expect(find.text('RootFolder'), findsOneWidget);
    expect(find.text('NestedFolder'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('show-in-parent-folder-button')),
      findsNWidgets(2),
    );

    final nestedCard = find.ancestor(
      of: find.text('NestedFolder'),
      matching: find.byKey(const ValueKey('media-list-card')),
    );
    await tester.tap(
      find.descendant(
        of: nestedCard,
        matching: find.byKey(const ValueKey('show-in-parent-folder-button')),
      ),
    );
    await tester.pump();
    expect(located, 'nested-folder');
    expect(openedFolder, isNull);

    final rootCard = find.ancestor(
      of: find.text('RootFolder'),
      matching: find.byKey(const ValueKey('media-list-card')),
    );
    await tester.tap(
      find.descendant(
        of: rootCard,
        matching: find.byKey(const ValueKey('show-in-parent-folder-button')),
      ),
    );
    await tester.pump();
    expect(located, 'root-folder');
    expect(openedFolder, isNull);
  });

  testWidgets('pinned folder grid cards keep a locate button', (tester) async {
    String? located;
    library.seedCollectionForTesting(
      VideoCollection(id: 'root-folder', name: 'RootFolder', createTime: 1),
    );
    library.seedPinnedIdsForTesting(['root-folder']);
    library.notifyListeners();

    await tester.pumpWidget(
      await _harness(
        library,
        scroll,
        viewMode: 0,
        onLocateFolder: (id) => located = id,
      ),
    );
    await tester.pump();

    expect(
      find.byKey(const ValueKey('show-in-parent-folder-button')),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(const ValueKey('show-in-parent-folder-button')),
    );
    await tester.pump();
    expect(located, 'root-folder');
  });

  testWidgets('continue-learning rows are not pin-reorder targets', (
    tester,
  ) async {
    library.seedVideoForTesting(_clip('first'));
    library.seedVideoForTesting(_clip('second'));
    library.seedVideoForTesting(_clip('loose'));
    library.seedMediaActivityForTesting(
      MediaActivityRecord(
        mediaId: 'loose',
        lastPlayedAtMs: 9,
        accumulatedWatchMs: 40000,
      ),
    );
    library.seedPinnedIdsForTesting(['second', 'first']);
    library.notifyListeners();

    await tester.pumpWidget(await _harness(library, scroll, seriousOnly: true));
    await tester.pump();

    expect(find.byKey(const ValueKey('continue-pin-loose')), findsNothing);
    expect(find.text('loose'), findsOneWidget);
  });
}

VideoItem _clip(String id, {String? parentId}) {
  return VideoItem(
    id: id,
    path: '/tmp/$id.mp4',
    title: id,
    durationMs: 120000,
    lastUpdated: 1,
    parentId: parentId,
    lastPositionMs: 15000,
    hasProbedChapters: true,
  );
}

Future<Widget> _harness(
  LibraryService library,
  ScrollController scroll, {
  ValueChanged<String>? onOpen,
  ValueChanged<String>? onOpenFolder,
  ValueChanged<String>? onLocateFolder,
  bool seriousOnly = false,
  int viewMode = 1,
}) async {
  final settings = SettingsService();
  await settings.init();
  settings.mediaLibraryViewMode = viewMode;
  settings.mediaLibraryContinueSeriousOnly = seriousOnly;
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<LibraryService>.value(value: library),
      ChangeNotifierProvider<SettingsService>.value(value: settings),
      ChangeNotifierProvider<MediaPlaybackService>.value(
        value: MediaPlaybackService(),
      ),
    ],
    child: MaterialApp(
      home: Scaffold(
        body: MediaLibraryContinueView(
          scrollController: scroll,
          cardBottomPadding: 0,
          onOpenMedia: (item) => onOpen?.call(item.id),
          onOpenFolder: (folder) => onOpenFolder?.call(folder.id),
          onLocateMedia: (_) {},
          onLocateFolder: (folder) => onLocateFolder?.call(folder.id),
          onGoRecent: () {},
          onGoFolders: () {},
        ),
      ),
    ),
  );
}
