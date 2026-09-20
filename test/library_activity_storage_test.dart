import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/library_activity.dart';
import 'package:video_player_app/models/video_collection.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/settings_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final library = LibraryService();
  late Directory root;
  late PathProviderPlatform originalPathProvider;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    SettingsService().resetForTest();
    originalPathProvider = PathProviderPlatform.instance;
    root = await Directory.systemTemp.createTemp('library_activity_s01_');
    PathProviderPlatform.instance = _FakePathProvider(root.path);
    SettingsService().largeDataRootPath = root.path;
    library.resetLibraryForTesting();
  });

  tearDown(() async {
    library.resetLibraryForTesting();
    PathProviderPlatform.instance = originalPathProvider;
    SettingsService().resetForTest();
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  test(
    'old libraries keep unknown addedAt and do not copy lastUpdated',
    () async {
      await _writeLibrary(root, videos: [_item('old', lastUpdated: 999)]);

      await library.init();

      expect(library.getVideo('old')!.lastUpdated, 999);
      expect(library.mediaActivity('old'), isNull);
      expect(library.activityProjection.recentAddedMediaIds().unknownAddedIds, [
        'old',
      ]);
      expect(
        library.activityProjection.recentAddedMediaIds().datedIds,
        isEmpty,
      );
    },
  );

  test('activity round-trips without writing fields onto VideoItem', () async {
    await _writeLibrary(root, videos: [_item('a'), _item('b')]);
    await library.init();

    final batchId = library.beginImportBatch(
      title: '本地文件',
      sourceKind: LibraryImportSourceKind.localFile,
    );
    library.noteImportedMedia('a', addedAtMs: 100, batchId: batchId);
    library.noteImportedMedia('b', addedAtMs: 200, batchId: batchId);
    await library.completeImportBatch(batchId!);
    await library.pinLibraryItem('a');
    await library.hideLibraryMedia('b');

    library.resetLibraryForTesting();
    SettingsService().largeDataRootPath = root.path;
    await library.init();

    expect(library.mediaActivity('a')!.addedAtMs, 100);
    expect(library.mediaActivity('b')!.addedAtMs, 200);
    expect(library.mediaActivity('b')!.hidden, isTrue);
    expect(library.pinnedItemIds, ['a']);
    expect(library.importBatches.single.createdMediaIds, ['a', 'b']);

    final saved =
        jsonDecode(await _libraryFile(root).readAsString())
            as Map<String, dynamic>;
    expect(saved['activity']['version'], 1);
    final videoJson = (saved['videos'] as List).first as Map<String, dynamic>;
    expect(videoJson.containsKey('addedAtMs'), isFalse);
    expect(videoJson.containsKey('hidden'), isFalse);
  });

  test('reloading a migrated snapshot does not invent times', () async {
    await _writeLibrary(
      root,
      videos: [_item('legacy', lastUpdated: 50)],
      schemaVersion: 1,
    );

    await library.init();
    expect(library.mediaActivity('legacy'), isNull);

    library.resetLibraryForTesting();
    SettingsService().largeDataRootPath = root.path;
    await library.init();

    expect(library.mediaActivity('legacy'), isNull);
    expect(library.getVideo('legacy')!.lastUpdated, 50);
    final saved =
        jsonDecode(await _libraryFile(root).readAsString())
            as Map<String, dynamic>;
    expect(saved['schemaVersion'], 2);
    expect(saved['activity']['media'], isEmpty);
  });

  test('rename and progress updates leave addedAt unchanged', () async {
    await _writeLibrary(root, videos: [_item('clip', lastUpdated: 1)]);
    await library.init();
    await library.registerImportedMedia('clip', addedAtMs: 40);

    await library.renameItem('clip', 'new title');
    await library.updateVideoProgress('clip', 1234);

    expect(library.getVideo('clip')!.title, 'new title');
    expect(library.getVideo('clip')!.lastPositionMs, 1234);
    expect(library.mediaActivity('clip')!.addedAtMs, 40);
  });

  test('soft delete keeps pins; permanent delete drops references', () async {
    await _writeLibrary(
      root,
      collections: [_folder('folder')],
      videos: [_item('clip', parentId: 'folder')],
    );
    await library.init();
    await library.registerImportedMedia('clip', addedAtMs: 8);
    await library.pinLibraryItem('folder');
    await library.pinLibraryItem('clip');

    await library.moveToRecycleBin(['folder']);
    expect(library.pinnedItemIds, ['clip', 'folder']);
    expect(library.activityProjection.visiblePinnedIds(), isEmpty);
    expect(library.activityProjection.isVisibleMedia('clip'), isFalse);
    expect(library.mediaActivity('clip')!.addedAtMs, 8);

    await library.restoreFromRecycleBin(['folder']);
    expect(library.pinnedItemIds, ['clip', 'folder']);
    expect(library.activityProjection.visiblePinnedIds(), ['clip', 'folder']);

    await library.moveToRecycleBin(['clip']);
    await library.deleteFromRecycleBin(['clip']);
    expect(library.mediaActivity('clip'), isNull);
    expect(library.pinnedItemIds, ['folder']);
  });

  test('recycled ancestors are excluded from activity projections', () async {
    await _writeLibrary(
      root,
      collections: [
        _folder('parent'),
        _folder('child', parentId: 'parent'),
      ],
      videos: [_item('clip', parentId: 'child', lastUpdated: 3)],
    );
    await library.init();
    await library.registerImportedMedia('clip', addedAtMs: 11);
    await library.pinLibraryItem('clip');
    await library.moveToRecycleBin(['parent']);

    expect(library.getVideo('clip')!.isRecycled, isFalse);
    expect(library.activityProjection.hasRecycledAncestor('child'), isTrue);
    expect(library.activityProjection.isVisibleMedia('clip'), isFalse);
    expect(library.activityProjection.recentAddedMediaIds().datedIds, isEmpty);
  });

  test(
    'corrupt activity rows are skipped without dropping valid ones',
    () async {
      await _writeLibrary(
        root,
        videos: [_item('good'), _item('other')],
        activity: <String, Object?>{
          'version': 1,
          'media': <Object?>[
            'not-a-map',
            <String, Object?>{'addedAtMs': 1},
            <String, Object?>{'id': 'good', 'addedAtMs': 42},
          ],
          'batches': <Object?>[
            <String, Object?>{'title': 'missing-id'},
            <String, Object?>{
              'id': 'batch-1',
              'startedAtMs': 1,
              'title': 'ok',
              'sourceKind': 'folder',
              'createdMediaIds': <Object?>['good', 3, ''],
            },
          ],
          'pinnedIds': <Object?>['good', '', 'good', 9],
        },
      );

      await library.init();

      expect(library.mediaActivity('good')!.addedAtMs, 42);
      expect(library.mediaActivity('other'), isNull);
      expect(library.importBatches.single.createdMediaIds, ['good']);
      expect(library.pinnedItemIds, ['good']);
    },
  );

  test('unknown future activity versions are kept on later saves', () async {
    await _writeLibrary(
      root,
      videos: [_item('clip')],
      activity: <String, Object?>{
        'version': 9,
        'secret': 'keep-me',
        'media': <Object?>[
          <String, Object?>{'id': 'clip', 'addedAtMs': 77},
        ],
      },
    );
    await library.init();

    expect(library.mediaActivity('clip'), isNull);
    await library.pinLibraryItem('clip');
    await library.renameItem('clip', 'renamed');

    final saved =
        jsonDecode(await _libraryFile(root).readAsString())
            as Map<String, dynamic>;
    expect(saved['activity']['version'], 9);
    expect(saved['activity']['secret'], 'keep-me');
    expect(library.getVideo('clip')!.title, 'renamed');
  });

  test('aborted batches are not persisted', () async {
    await _writeLibrary(root, videos: [_item('clip')]);
    await library.init();

    final batchId = library.beginImportBatch(
      title: '取消',
      sourceKind: LibraryImportSourceKind.share,
    );
    library.noteImportedMedia('clip', addedAtMs: 5, batchId: batchId);
    library.abortImportBatch(batchId!);

    expect(await library.completeImportBatch(batchId), isFalse);
    await library.saveLibraryForTesting();
    final saved =
        jsonDecode(await _libraryFile(root).readAsString())
            as Map<String, dynamic>;
    expect(saved['activity']['batches'], isEmpty);
    expect(library.mediaActivity('clip')!.addedAtMs, 5);
  });

  test(
    'failed save retries keep in-memory activity and recover on disk',
    () async {
      await _writeLibrary(root, videos: [_item('clip')]);
      await library.init();
      library.saveRetryDelaysForTesting = const <Duration>[Duration(days: 1)];

      var attempts = 0;
      library.writeLibrarySnapshotOverrideForTesting = () async {
        attempts++;
        throw const FileSystemException('activity write failure');
      };
      await library.registerImportedMedia('clip', addedAtMs: 12);
      await library.pinLibraryItem('clip');

      expect(library.hasPersistenceFailure, isTrue);
      expect(library.mediaActivity('clip')!.addedAtMs, 12);
      expect(library.pinnedItemIds, ['clip']);

      library.writeLibrarySnapshotOverrideForTesting = null;
      await library.retryLibraryPersistence();

      expect(library.hasPersistenceFailure, isFalse);
      final saved =
          jsonDecode(await _libraryFile(root).readAsString())
              as Map<String, dynamic>;
      expect(saved['activity']['pinnedIds'], ['clip']);
      expect(attempts, 2);
    },
  );

  test('completed activity survives progress reset writes', () async {
    await _writeLibrary(root, videos: [_item('clip')]);
    await library.init();
    await library.recordPlaybackCompleted('clip', completedAtMs: 20);
    await library.updateVideoProgress('clip', 0);

    expect(library.mediaActivity('clip')!.completed, isTrue);
    expect(library.mediaActivity('clip')!.lastPlayedAtMs, 20);
    expect(library.getVideo('clip')!.lastPositionMs, 0);
  });
}

VideoItem _item(String id, {String? parentId, int lastUpdated = 1}) {
  return VideoItem(
    id: id,
    path: '/tmp/$id.mp4',
    title: id,
    durationMs: 1000,
    lastUpdated: lastUpdated,
    parentId: parentId,
  );
}

VideoCollection _folder(String id, {String? parentId}) {
  return VideoCollection(
    id: id,
    name: id,
    createTime: 1,
    parentId: parentId,
    childrenIds: <String>[],
  );
}

File _libraryFile(Directory root) => File(p.join(root.path, 'library.json'));

Future<void> _writeLibrary(
  Directory root, {
  List<VideoItem> videos = const <VideoItem>[],
  List<VideoCollection> collections = const <VideoCollection>[],
  int schemaVersion = 2,
  Map<String, Object?>? activity,
}) async {
  final collectionById = <String, VideoCollection>{
    for (final collection in collections) collection.id: collection,
  };
  for (final video in videos) {
    final parentId = video.parentId;
    if (parentId != null && collectionById.containsKey(parentId)) {
      collectionById[parentId]!.childrenIds.add(video.id);
    }
  }
  for (final collection in collections) {
    final parentId = collection.parentId;
    if (parentId != null && collectionById.containsKey(parentId)) {
      collectionById[parentId]!.childrenIds.add(collection.id);
    }
  }

  final rootIds = <String>[
    ...collections.where((c) => c.parentId == null).map((c) => c.id),
    ...videos.where((v) => v.parentId == null).map((v) => v.id),
  ];

  await _libraryFile(root).writeAsString(
    jsonEncode(<String, Object?>{
      'collections': collections.map((c) => c.toJson()).toList(),
      'videos': videos.map((v) => v.toJson()).toList(),
      'rootChildrenIds': rootIds,
      'schemaVersion': schemaVersion,
      if (activity != null) 'activity': activity,
    }),
  );
}

class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.rootPath);

  final String rootPath;

  @override
  Future<String?> getApplicationDocumentsPath() async => rootPath;

  @override
  Future<String?> getTemporaryPath() async => rootPath;
}
