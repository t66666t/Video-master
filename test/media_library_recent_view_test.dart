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
import 'package:video_player_app/widgets/media_library_grid_card.dart';
import 'package:video_player_app/widgets/media_library_recent_intent.dart';
import 'package:video_player_app/widgets/media_library_recent_view.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late LibraryService library;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    SettingsService().resetForTest();
    library = LibraryService();
    library.resetLibraryForTesting();
    MediaLibraryRecentIntent.pendingBatchId.value = null;
  });

  tearDown(() {
    library.resetLibraryForTesting();
    SettingsService().resetForTest();
    MediaLibraryRecentIntent.pendingBatchId.value = null;
  });

  testWidgets('100-item batch stays collapsed until opened', (tester) async {
    final ids = List<String>.generate(100, (index) => 'm$index');
    for (final id in ids) {
      library.seedVideoForTesting(
        VideoItem(
          id: id,
          path: '/tmp/$id.mp4',
          title: id,
          durationMs: 1,
          lastUpdated: 1,
          hasProbedChapters: true,
        ),
      );
    }
    final batchId = library.beginImportBatch(
      title: 'Pack',
      sourceKind: LibraryImportSourceKind.folder,
      startedAtMs: 50,
    )!;
    for (final id in ids) {
      library.noteImportedMedia(id, addedAtMs: 50, batchId: batchId);
    }
    await library.completeImportBatch(batchId, persist: false);
    library.notifyListeners();

    await tester.pumpWidget(_harness(library));
    await tester.pump();

    expect(find.text('Pack·当前100项'), findsOneWidget);
    expect(find.byType(MediaLibraryGridCard), findsNothing);
    expect(find.text('m0'), findsNothing);

    await tester.tap(find.text('Pack·当前100项'));
    await tester.pump();

    expect(find.byType(MediaLibraryGridCard), findsWidgets);
    expect(find.text('m0'), findsOneWidget);
    expect(find.text('m99'), findsNothing);
  });

  testWidgets('newest small batch opens itself', (tester) async {
    final ids = <String>['m0', 'm1', 'm2'];
    for (final id in ids) {
      library.seedVideoForTesting(
        VideoItem(
          id: id,
          path: '/tmp/$id.mp4',
          title: id,
          durationMs: 1,
          lastUpdated: 1,
          hasProbedChapters: true,
        ),
      );
    }
    final batchId = library.beginImportBatch(
      title: 'Pack',
      sourceKind: LibraryImportSourceKind.folder,
      startedAtMs: 50,
    )!;
    for (final id in ids) {
      library.noteImportedMedia(id, addedAtMs: 50, batchId: batchId);
    }
    await library.completeImportBatch(batchId, persist: false);
    library.notifyListeners();

    await tester.pumpWidget(_harness(library));
    await tester.pump();

    expect(find.text('Pack·当前3项'), findsOneWidget);
    expect(find.text('m0'), findsOneWidget);
    expect(find.text('m2'), findsOneWidget);
  });

  testWidgets('consecutive singles share one grid row', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    for (var index = 0; index < 6; index++) {
      final id = 's$index';
      library.seedVideoForTesting(
        VideoItem(
          id: id,
          path: '/tmp/$id.mp4',
          title: id,
          durationMs: 1,
          lastUpdated: 1,
          hasProbedChapters: true,
        ),
      );
      library.noteImportedMedia(id, addedAtMs: 100 - index);
    }
    library.notifyListeners();

    await tester.pumpWidget(_harness(library));
    await tester.pump();

    expect(find.text('s0'), findsOneWidget);
    expect(find.text('s5'), findsOneWidget);
    expect(find.byType(SliverGrid), findsOneWidget);
  });

  testWidgets('nested folder child can be opened and located', (tester) async {
    library.seedCollectionForTesting(
      VideoCollection(
        id: 'root',
        name: '压缩包',
        createTime: 1,
        childrenIds: ['mid'],
      ),
    );
    library.seedCollectionForTesting(
      VideoCollection(
        id: 'mid',
        name: '中间层',
        createTime: 1,
        parentId: 'root',
        childrenIds: ['deep'],
      ),
    );
    library.seedCollectionForTesting(
      VideoCollection(
        id: 'deep',
        name: '最内层',
        createTime: 1,
        parentId: 'mid',
        childrenIds: ['clip'],
      ),
    );
    library.seedVideoForTesting(
      VideoItem(
        id: 'clip',
        path: '/tmp/clip.mp4',
        title: 'clip',
        durationMs: 1,
        lastUpdated: 1,
        parentId: 'deep',
        hasProbedChapters: true,
      ),
    );
    final batchId = library.beginImportBatch(
      title: '压缩包',
      sourceKind: LibraryImportSourceKind.archive,
      startedAtMs: 50,
    )!;
    library.noteImportedCollection('root', batchId: batchId);
    library.noteImportedCollection('mid', batchId: batchId);
    library.noteImportedCollection('deep', batchId: batchId);
    library.noteImportedMedia('clip', addedAtMs: 50, batchId: batchId);
    await library.completeImportBatch(batchId, persist: false);
    library.notifyListeners();

    String? opened;
    String? located;
    await tester.pumpWidget(
      _harness(library, onOpenFolder: (id) => opened = id, onLocateFolder: (id) => located = id),
    );
    await tester.pump();

    expect(find.text('压缩包·当前1项'), findsOneWidget);
    expect(find.text('中间层'), findsOneWidget);
    expect(find.byKey(const ValueKey('show-in-parent-folder-button')), findsOneWidget);

    await tester.tap(find.text('中间层'));
    await tester.pump();
    expect(opened, 'mid');

    await tester.tap(find.byKey(const ValueKey('show-in-parent-folder-button')));
    await tester.pump();
    expect(located, 'mid');
  });

  test('查看 intent records the batch without switching by itself', () {
    MediaLibraryRecentIntent.viewBatch('batch-9');
    expect(MediaLibraryRecentIntent.pendingBatchId.value, 'batch-9');
  });
}

Widget _harness(
  LibraryService library, {
  ValueChanged<String>? onOpenFolder,
  ValueChanged<String>? onLocateFolder,
}) {
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<LibraryService>.value(value: library),
      ChangeNotifierProvider<SettingsService>.value(
        value: SettingsService()..mediaLibraryViewMode = 0,
      ),
      ChangeNotifierProvider<MediaPlaybackService>.value(
        value: MediaPlaybackService(),
      ),
    ],
    child: MaterialApp(
      home: Scaffold(
        body: MediaLibraryRecentView(
          scrollController: ScrollController(),
          cardBottomPadding: 0,
          onOpenMedia: (_) {},
          onLocateMedia: (_) {},
          onOpenFolder: (collection) => onOpenFolder?.call(collection.id),
          onLocateFolder: (collection) => onLocateFolder?.call(collection.id),
        ),
      ),
    ),
  );
}
