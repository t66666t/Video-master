import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/library_activity.dart';
import 'package:video_player_app/models/media_library_root_entry.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/widgets/media_library_continue_view.dart';
import 'package:video_player_app/widgets/media_library_entry_switcher.dart';
import 'package:video_player_app/widgets/media_library_folder_breadcrumb.dart';
import 'package:video_player_app/widgets/media_library_grid_card.dart';
import 'package:video_player_app/widgets/media_library_list_tile.dart';
import 'package:video_player_app/widgets/playback_card_layout.dart';

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

  Future<void> setSize(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  testWidgets('phone 360, landscape, tablet and desktop chrome still layout', (
    tester,
  ) async {
    for (final size in const [
      Size(360, 640),
      Size(800, 360),
      Size(800, 1280),
      Size(1280, 800),
    ]) {
      await setSize(tester, size);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            appBar: AppBar(
              title: MediaLibraryEntrySwitcher(
                selected: MediaLibraryRootEntry.recent,
                availableEntries: MediaLibraryRootEntry.values.toSet(),
                onSelected: (_) {},
                compact: size.width < 600,
              ),
            ),
            body: Stack(
              children: [
                MediaLibraryFolderBreadcrumb(
                  compact: size.width < 600,
                  crumbs: const [
                    MediaLibraryBreadcrumbCrumb(folderId: null, label: '媒体库'),
                    MediaLibraryBreadcrumbCrumb(folderId: 'a', label: '一年级'),
                    MediaLibraryBreadcrumbCrumb(folderId: 'b', label: '数学'),
                    MediaLibraryBreadcrumbCrumb(folderId: 'c', label: '第一单元'),
                  ],
                  onSelected: (_) {},
                ),
                const Positioned(
                  key: MediaLibraryOverlayKeys.miniPlaybackCard,
                  left: 12,
                  right: 12,
                  bottom: 12,
                  height: 72,
                  child: ColoredBox(color: Color(0xFF222222)),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('最近添加'), findsOneWidget);
      expect(find.text('继续学习'), findsOneWidget);
      expect(find.text('文件夹'), findsOneWidget);
      expect(find.text('媒体库'), findsOneWidget);
      expect(
        find.byKey(MediaLibraryOverlayKeys.miniPlaybackCard),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('list and grid cards keep titles at 360 and 1280', (
    tester,
  ) async {
    final item = VideoItem(
      id: 'clip',
      path: '/tmp/clip.mp4',
      title: 'Overflowing title that must not be eaten by badges',
      durationMs: 1,
      lastUpdated: 1,
    );

    Future<void> pumpCards(Size size, {required bool list}) async {
      await setSize(tester, size);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: size.width,
              height: 72,
              child: list
                  ? ChangeNotifierProvider<MediaPlaybackService>.value(
                      value: MediaPlaybackService(),
                      child: MediaLibraryListTile.video(
                        item: item,
                        index: 0,
                        showIndex: false,
                        showThumbnail: true,
                        isSelected: false,
                        isSelectionMode: false,
                        titleScale: 0.065,
                        onTap: () {},
                      ),
                    )
                  : MediaLibraryGridCard(
                      radius: 8,
                      isSelected: false,
                      onTap: () {},
                      child: Text(item.title),
                    ),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    await pumpCards(const Size(360, 640), list: true);
    expect(find.textContaining('Overflowing title'), findsOneWidget);
    await pumpCards(const Size(1280, 800), list: false);
    expect(find.textContaining('Overflowing title'), findsOneWidget);
  });

  testWidgets('continue view still lists progress without probing disk', (
    tester,
  ) async {
    await setSize(tester, const Size(360, 640));
    SettingsService().mediaLibraryViewMode = 1;
    library.seedVideoForTesting(
      VideoItem(
        id: 'clip',
        path: r'Z:\missing\does-not-exist.mp4',
        title: 'clip',
        durationMs: 120000,
        lastUpdated: 1,
        lastPositionMs: 15000,
      ),
    );
    library.seedMediaActivityForTesting(
      MediaActivityRecord(
        mediaId: 'clip',
        lastPlayedAtMs: 3,
        accumulatedWatchMs: 40000,
      ),
    );

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<LibraryService>.value(value: library),
          ChangeNotifierProvider<SettingsService>.value(
            value: SettingsService(),
          ),
          ChangeNotifierProvider<MediaPlaybackService>.value(
            value: MediaPlaybackService(),
          ),
        ],
        child: MaterialApp(
          home: MediaLibraryContinueView(
            scrollController: scroll,
            cardBottomPadding: 0,
            onOpenMedia: (_) {},
            onOpenFolder: (_) {},
            onLocateMedia: (_) {},
            onLocateFolder: (_) {},
            onGoRecent: () {},
            onGoFolders: () {},
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('clip'), findsOneWidget);
    expect(find.text('文件无法访问'), findsNothing);
  });
}
