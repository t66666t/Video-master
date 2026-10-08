import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/bilibili_models.dart';
import 'package:video_player_app/models/media_source_ref.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/screens/bilibili/bilibili_watch_loading_page.dart';
import 'package:video_player_app/screens/bilibili/bilibili_watch_page_layout.dart';
import 'package:video_player_app/screens/portrait_video_screen.dart';
import 'package:video_player_app/screens/video_player_screen.dart';
import 'package:video_player_app/services/bilibili/bilibili_api_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_open_timeline.dart';
import 'package:video_player_app/services/bilibili/bilibili_player_panel_memory.dart';
import 'package:video_player_app/services/bilibili/bilibili_player_panel_policy.dart';
import 'package:video_player_app/services/bilibili/bilibili_streaming_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_watch_cards.dart';
import 'package:video_player_app/services/bilibili/bilibili_watch_launch.dart';
import 'package:video_player_app/services/embedded_subtitle_service.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/ocr_subtitle_manager.dart';
import 'package:video_player_app/services/playlist_manager.dart';
import 'package:video_player_app/services/progress_tracker.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/services/transcription_manager.dart';
import 'package:video_player_app/widgets/bilibili_player_panel.dart';
import 'package:video_player_app/widgets/bilibili_portrait_tabs.dart';

import 'test_dir_cleanup.dart';

void main() {
  group('layout of the playback page, worked out ahead', () {
    const wide = Size(1280, 720);
    const narrow = Size(900, 600);

    BilibiliWatchLandscapeLayout landscape(
      Size window, {
      bool leftHanded = false,
      bool panel = true,
      bool subtitles = true,
      bool mobile = false,
      EdgeInsets padding = EdgeInsets.zero,
    }) {
      return BilibiliWatchPageShape(
        landscape: true,
        leftHanded: leftHanded,
        bilibiliPanelRemembered: panel,
        subtitleSidebarRemembered: subtitles,
        isMobilePlatform: mobile,
      ).landscapeLayout(window: window, padding: padding);
    }

    test('wide window: the Bilibili panel docks on the right', () {
      final layout = landscape(wide);
      expect(layout.slot, BilibiliWatchSidebarSlot.bilibili);
      // 1280 * 0.32 = 409.6 leaves 870.4 >= 640 for the video.
      expect(layout.surface, const Rect.fromLTWH(0, 0, 870.4, 720));
      expect(layout.sidebar, const Rect.fromLTWH(870.4, 0, 409.6, 720));
    });

    test('left-handed mode puts the panel on the left', () {
      final layout = landscape(wide, leftHanded: true);
      expect(layout.surface, const Rect.fromLTWH(409.6, 0, 870.4, 720));
      expect(layout.sidebar, const Rect.fromLTWH(0, 0, 409.6, 720));
    });

    test('narrow window: no docked panel, the subtitle list keeps its '
        'place with its handle', () {
      final layout = landscape(narrow);
      expect(layout.slot, BilibiliWatchSidebarSlot.subtitles);
      expect(layout.sidebar.width, closeTo(262.4 + 12, 1e-9));
      expect(layout.surface.width, closeTo(900 - 274.4, 1e-9));

      final bare = landscape(narrow, subtitles: false);
      expect(bare.slot, BilibiliWatchSidebarSlot.none);
      expect(bare.surface, const Rect.fromLTWH(0, 0, 900, 600));
      expect(bare.sidebar.width, 0);
    });

    test('panel closed, or a phone: no Bilibili panel', () {
      expect(
        landscape(wide, panel: false).slot,
        BilibiliWatchSidebarSlot.subtitles,
      );
      expect(
        landscape(const Size(844, 390), mobile: true).slot,
        BilibiliWatchSidebarSlot.subtitles,
      );
      expect(
        landscape(const Size(1366, 1024), mobile: true).slot,
        BilibiliWatchSidebarSlot.bilibili,
      );
    });

    test('only the top inset is kept free in landscape', () {
      final layout = landscape(
        wide,
        padding: const EdgeInsets.fromLTRB(30, 24, 30, 10),
      );
      expect(layout.surface, const Rect.fromLTWH(0, 24, 870.4, 696));
    });

    test(
      'portrait: at most 500 wide and centered, 16:9 under the top inset',
      () {
        expect(
          bilibiliWatchPortraitVideoArea(
            window: const Size(390, 844),
            padding: const EdgeInsets.only(top: 47, bottom: 34),
            aspectRatio: 16 / 9,
          ),
          const Rect.fromLTWH(0, 47, 390, 390 * 9 / 16),
        );
        expect(
          bilibiliWatchPortraitVideoArea(
            window: const Size(800, 1280),
            padding: EdgeInsets.zero,
            aspectRatio: 16 / 9,
          ),
          const Rect.fromLTWH(150, 0, 500, 500 * 9 / 16),
        );
      },
    );

    test('the video is fitted into the area as the landscape page fits it', () {
      const area = Rect.fromLTWH(0, 0, 870.4, 720);
      final video = containedVideoRect(area, 16 / 9);
      expect(video.width, closeTo(870.4, 1e-9));
      expect(video.height, closeTo(870.4 * 9 / 16, 1e-9));
      expect(video.center, area.center);
      final tall = containedVideoRect(area, 9 / 16);
      expect(tall.height, 720);
      expect(tall.width, closeTo(405, 1e-9));
    });

    test('the numbers are the playback pages\' own', () {
      final landscapeSource = File(
        'lib/screens/video_player_screen.dart',
      ).readAsStringSync();
      final portraitSource = File(
        'lib/screens/portrait_video_screen.dart',
      ).readAsStringSync();
      for (final line in <String>[
        'static const double _subtitleSidebarResizerLayoutWidth = '
            '${kPlayerSubtitleSidebarResizerWidth.toStringAsFixed(1)};',
        'static const double _subtitleSidebarMinWidth = '
            '${kPlayerSubtitleSidebarMinWidth.toStringAsFixed(1)};',
        'static const double _subtitleSidebarMinRemainingPlayerWidth = '
            '${kPlayerSubtitleSidebarMinRemainingWidth.toStringAsFixed(1)};',
        'LandscapeSidebarTarget get _defaultTarget => landscapeDefaultSidebar(',
        'return LandscapeSidebarLayout.functionalWidthFor(screenSize);',
        'if (isLeftHandedMode) ...sidebarWidgets,',
        'if (!isLeftHandedMode) ...sidebarWidgets,',
        'height = width / safeAspectRatio;',
        'width = height * safeAspectRatio;',
      ]) {
        expect(landscapeSource, contains(line));
      }
      expect(
        portraitSource,
        contains(
          'constraints: const BoxConstraints(maxWidth: '
          '${kPortraitPlayerMaxWidth.toInt()}),',
        ),
      );
    });
  });

  group('the loading page shows the cover where the playback page shows '
      'the video', () {
    late Directory root;
    late PathProviderPlatform originalPaths;
    late LibraryService library;
    late MediaPlaybackService playback;
    late _NeverReadyStreaming streaming;
    final settings = SettingsService();

    setUp(() async {
      Provider.debugCheckInvalidValueType = null;
      SharedPreferences.setMockInitialValues(<String, Object>{});
      settings.resetForTest();
      await settings.init();
      root = await Directory.systemTemp.createTemp('bilibili_watch_layout_');
      originalPaths = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _Paths(root.path);
      library = LibraryService()..resetLibraryForTesting();
      // The playback pages stay on their loading cover: the video never
      // gets ready.
      streaming = _NeverReadyStreaming();
      playback = MediaPlaybackService();
      await playback.initialize(
        playlistManager: PlaylistManager(),
        progressTracker: ProgressTracker(),
        bilibiliStreamingService: streaming,
      );
    });

    tearDown(() async {
      BilibiliPortraitTabMemory.takeHandOff(_item().id);
      settings
        ..isLeftHandedMode = false
        ..bilibiliPlayerPanelOpen = true
        ..isLandscapeSubtitleSidebarVisible = true
        ..userSubtitleSidebarWidth = 262.4
        ..resetForTest();
      library.resetLibraryForTesting();
      PathProviderPlatform.instance = originalPaths;
      Provider.debugCheckInvalidValueType = _defaultValueTypeCheck;
      await deleteTestTempDir(root);
    });

    void window(WidgetTester tester, Size size, {EdgeInsets? padding}) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      if (padding != null) {
        tester.view.padding = FakeViewPadding(
          left: padding.left,
          top: padding.top,
          right: padding.right,
          bottom: padding.bottom,
        );
      }
      addTearDown(tester.view.reset);
    }

    Widget host(Widget page) {
      // The playback service goes in as a plain value: the page starts
      // playback while it is built, which must not rebuild the tree here.
      return MultiProvider(
        providers: [
          ChangeNotifierProvider<SettingsService>.value(value: settings),
          ChangeNotifierProvider<LibraryService>.value(value: library),
          ChangeNotifierProvider<TranscriptionManager>.value(
            value: TranscriptionManager(),
          ),
          ChangeNotifierProvider<EmbeddedSubtitleService>.value(
            value: EmbeddedSubtitleService(),
          ),
          ChangeNotifierProvider<OcrSubtitleManager>.value(
            value: OcrSubtitleManager(library: library),
          ),
          ChangeNotifierProvider<PlaylistManager>.value(
            value: PlaylistManager(),
          ),
          Provider<MediaPlaybackService>.value(value: playback),
        ],
        child: MaterialApp(home: page),
      );
    }

    Future<void> close(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 30));
    }

    /// Rects of what both pages show while the video gets ready.
    Future<_Shown> showLoadingPage(
      WidgetTester tester,
      BilibiliWatchPageShape shape,
    ) async {
      final load = Completer<BilibiliWatchPlan>();
      await tester.pumpWidget(
        host(
          BilibiliWatchLoadingPage(
            bvid: _bvid,
            preview: const BilibiliWatchPreview(title: _title),
            load: (_) => load.future,
            open: (_, _, _, _) async {},
            timeline: () => BilibiliOpenTimeline(_bvid),
            shape: shape,
          ),
        ),
      );
      await tester.pump();
      final area = find.byKey(
        const ValueKey('bilibili-watch-loading-video-area'),
      );
      final shown = _Shown(
        area: tester.getRect(area),
        back: tester.getRect(
          find.byKey(const ValueKey('bilibili-watch-loading-back')),
        ),
        title: shape.landscape ? tester.getRect(find.text(_title).first) : null,
      );
      await close(tester);
      return shown;
    }

    Future<_Shown> showLandscapePlayer(WidgetTester tester) async {
      await tester.pumpWidget(
        host(VideoPlayerScreen(videoItem: _item(), autoPlayOnEntry: false)),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      final surface = find.byKey(const ValueKey('landscape-player-surface'));
      final shown = _Shown(
        area: tester.getRect(surface),
        back: tester.getRect(
          find.descendant(of: surface, matching: find.byTooltip('退出播放 (Esc)')),
        ),
        title: tester.getRect(
          find.descendant(of: surface, matching: find.text(_title)),
        ),
      );
      await close(tester);
      return shown;
    }

    Future<Rect> showPortraitPlayer(WidgetTester tester) async {
      await tester.pumpWidget(
        host(PortraitVideoScreen(videoItem: _item(), autoPlayOnEntry: false)),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      final area = tester.getRect(
        find
            .descendant(
              of: find.byType(PortraitVideoScreen),
              matching: find.byType(AspectRatio),
            )
            .first,
      );
      await close(tester);
      return area;
    }

    Future<void> expectSameLandscape(WidgetTester tester) async {
      final player = await showLandscapePlayer(tester);
      final shape = BilibiliWatchPageShape.current();
      expect(shape.landscape, isTrue);
      final loading = await showLoadingPage(tester, shape);
      expect(loading.area, player.area);
      expect(loading.back.center, player.back.center);
      expect(loading.title!.topLeft, player.title!.topLeft);
      final media = MediaQueryData.fromView(tester.view);
      expect(
        shape
            .landscapeLayout(window: media.size, padding: media.padding)
            .surface,
        player.area,
      );
    }

    testWidgets('wide window, the Bilibili panel docked', (tester) async {
      window(tester, const Size(1280, 720));
      settings.bilibiliPlayerPanelOpen = true;
      await expectSameLandscape(tester);
      final layout = BilibiliWatchPageShape.current().landscapeLayout(
        window: const Size(1280, 720),
        padding: EdgeInsets.zero,
      );
      expect(layout.slot, BilibiliWatchSidebarSlot.bilibili);
    });

    testWidgets('narrow window, the panel not docked', (tester) async {
      window(tester, const Size(900, 600));
      settings.bilibiliPlayerPanelOpen = true;
      await expectSameLandscape(tester);
      settings.isLandscapeSubtitleSidebarVisible = false;
      await expectSameLandscape(tester);
    });

    for (final subtitles in <bool>[false, true]) {
      testWidgets('dragging the window narrow tucks the docked panel away '
          'for now, wide brings it back; nothing is remembered '
          '(subtitle list ${subtitles ? 'left open' : 'closed'})', (
        tester,
      ) async {
        window(tester, const Size(1280, 720));
        settings
          ..bilibiliPlayerPanelOpen = true
          ..isLandscapeSubtitleSidebarVisible = subtitles;
        await tester.pumpWidget(
          host(VideoPlayerScreen(videoItem: _item(), autoPlayOnEntry: false)),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
        final surface = find.byKey(const ValueKey('landscape-player-surface'));
        expect(find.byType(BilibiliPlayerPanel), findsOneWidget);
        final wideVideo = tester.getRect(surface).width;

        // 900 - panel < 640: the panel gives way to the video.
        tester.view.physicalSize = const Size(900, 720);
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
        expect(find.byType(BilibiliPlayerPanel), findsNothing);
        if (!subtitles) {
          expect(tester.getRect(surface).width, 900);
        }
        expect(settings.bilibiliPlayerPanelOpen, isTrue);

        // Wide again: back as remembered.
        tester.view.physicalSize = const Size(1280, 720);
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
        expect(find.byType(BilibiliPlayerPanel), findsOneWidget);
        expect(tester.getRect(surface).width, wideVideo);
        expect(settings.bilibiliPlayerPanelOpen, isTrue);
        expect(settings.isLandscapeSubtitleSidebarVisible, subtitles);
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getBool('bilibiliPlayerPanelOpen'), isNull);
        await close(tester);
      });
    }

    testWidgets('left-handed mode', (tester) async {
      window(tester, const Size(1280, 720));
      settings
        ..isLeftHandedMode = true
        ..bilibiliPlayerPanelOpen = true;
      await expectSameLandscape(tester);
      window(tester, const Size(900, 600));
      await expectSameLandscape(tester);
    });

    testWidgets('panel left closed, with a top inset', (tester) async {
      window(
        tester,
        const Size(1280, 720),
        padding: const EdgeInsets.only(top: 24),
      );
      settings.bilibiliPlayerPanelOpen = false;
      await expectSameLandscape(tester);
    });

    testWidgets('the side panel\'s place shows on the matching side', (
      tester,
    ) async {
      window(tester, const Size(1280, 720));
      const shape = BilibiliWatchPageShape(
        landscape: true,
        bilibiliPanelRemembered: true,
        leftHanded: true,
      );
      final load = Completer<BilibiliWatchPlan>();
      await tester.pumpWidget(
        host(
          BilibiliWatchLoadingPage(
            bvid: _bvid,
            preview: const BilibiliWatchPreview(title: _title),
            load: (_) => load.future,
            open: (_, _, _, _) async {},
            timeline: () => BilibiliOpenTimeline(_bvid),
            shape: shape,
          ),
        ),
      );
      await tester.pump();
      expect(
        tester.getRect(
          find.byKey(const ValueKey('bilibili-watch-loading-sidebar-bilibili')),
        ),
        const Rect.fromLTWH(0, 0, 409.6, 720),
      );
      await close(tester);
    });

    testWidgets('the loading page shows the player\'s own Bilibili panel; '
        'collapsing it there is remembered as in the player', (tester) async {
      window(tester, const Size(1280, 720));
      settings.bilibiliPlayerPanelOpen = true;
      final load = Completer<BilibiliWatchPlan>();
      await tester.pumpWidget(
        host(
          BilibiliWatchLoadingPage(
            bvid: _bvid,
            preview: const BilibiliWatchPreview(title: _title),
            load: (_) => load.future,
            open: (_, _, _, _) async {},
            timeline: () => BilibiliOpenTimeline(_bvid),
          ),
        ),
      );
      await tester.pump();
      final sidebar = find.byKey(
        const ValueKey('bilibili-watch-loading-sidebar-bilibili'),
      );
      expect(
        find.descendant(
          of: sidebar,
          matching: find.byType(BilibiliPlayerPanel),
        ),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('bilibili-panel-collapse')));
      await tester.pump();
      expect(sidebar, findsNothing);
      expect(settings.bilibiliPlayerPanelOpen, isFalse);
      expect(
        find.byKey(const ValueKey('bilibili-watch-loading-sidebar-subtitles')),
        findsOneWidget,
      );
      await close(tester);
    });

    /// Rects of the portrait lower area: the switch and the whole area.
    Future<(Rect, Rect)> portraitLowerArea(WidgetTester tester) async {
      final tabs = find.byType(BilibiliPortraitTabs);
      return (
        tester.getRect(
          find.descendant(
            of: tabs,
            matching: find.byKey(const ValueKey('bilibili-portrait-tab-bar')),
          ),
        ),
        tester.getRect(tabs),
      );
    }

    for (final size in const <Size>[Size(412, 915), Size(800, 1280)]) {
      testWidgets('portrait ${size.width.toInt()} wide: the 详情 | 字幕 area '
          'starts and ends where the player\'s does', (tester) async {
        window(
          tester,
          size,
          padding: const EdgeInsets.only(top: 30, bottom: 20),
        );
        await tester.pumpWidget(
          host(PortraitVideoScreen(videoItem: _item(), autoPlayOnEntry: false)),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        final player = await portraitLowerArea(tester);
        expect(
          tester
              .widget<BilibiliPortraitTabs>(find.byType(BilibiliPortraitTabs))
              .tab,
          PortraitBilibiliTab.details,
        );
        await close(tester);

        final load = Completer<BilibiliWatchPlan>();
        await tester.pumpWidget(
          host(
            BilibiliWatchLoadingPage(
              bvid: _bvid,
              preview: const BilibiliWatchPreview(title: _title),
              load: (_) => load.future,
              open: (_, _, _, _) async {},
              timeline: () => BilibiliOpenTimeline(_bvid),
              shape: const BilibiliWatchPageShape(landscape: false),
            ),
          ),
        );
        await tester.pump();
        final loading = await portraitLowerArea(tester);
        expect(loading.$1, player.$1);
        expect(loading.$2, player.$2);
        // The details tab: the panel the player shows, its outline while
        // the detail loads.
        expect(find.byType(BilibiliPlayerPanel), findsOneWidget);
        expect(
          find.byKey(const ValueKey('bilibili-watch-loading-controls')),
          findsOneWidget,
        );
        await close(tester);
      });
    }

    testWidgets('the tab picked on the loading page carries over to the '
        'player, which does not snap back; nothing is remembered', (
      tester,
    ) async {
      window(tester, const Size(412, 915));
      expect(settings.bilibiliPortraitShowsSubtitles, isFalse);
      final load = Completer<BilibiliWatchPlan>();
      await tester.pumpWidget(
        host(
          BilibiliWatchLoadingPage(
            bvid: _bvid,
            preview: const BilibiliWatchPreview(title: _title),
            load: (_) => load.future,
            open: (navigator, page, plan, _) async {
              navigator.replace(
                oldRoute: page,
                newRoute: MaterialPageRoute<void>(
                  builder: (_) => PortraitVideoScreen(
                    videoItem: plan.item,
                    autoPlayOnEntry: false,
                  ),
                ),
              );
            },
            timeline: () => BilibiliOpenTimeline(_bvid),
            shape: const BilibiliWatchPageShape(landscape: false),
          ),
        ),
      );
      await tester.pump();
      PortraitBilibiliTab shown() => tester
          .widget<BilibiliPortraitTabs>(find.byType(BilibiliPortraitTabs))
          .tab;
      expect(shown(), PortraitBilibiliTab.details);

      await tester.tap(
        find.byKey(const ValueKey('bilibili-portrait-tab-subtitles')),
      );
      await tester.pump();
      expect(shown(), PortraitBilibiliTab.subtitles);
      expect(settings.bilibiliPortraitShowsSubtitles, isFalse);

      load.complete(_plan());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(BilibiliWatchLoadingPage), findsNothing);
      expect(find.byType(PortraitVideoScreen), findsOneWidget);
      expect(shown(), PortraitBilibiliTab.subtitles);
      expect(settings.bilibiliPortraitShowsSubtitles, isFalse);
      await close(tester);
    });

    testWidgets('a tab picked on the loading page that is not opened '
        'changes nothing', (tester) async {
      window(tester, const Size(412, 915));
      final load = Completer<BilibiliWatchPlan>();
      await tester.pumpWidget(
        host(
          BilibiliWatchLoadingPage(
            bvid: _bvid,
            preview: const BilibiliWatchPreview(title: _title),
            load: (_) => load.future,
            open: (_, _, _, _) async {},
            timeline: () => BilibiliOpenTimeline(_bvid),
            shape: const BilibiliWatchPageShape(landscape: false),
          ),
        ),
      );
      await tester.pump();
      await tester.tap(
        find.byKey(const ValueKey('bilibili-portrait-tab-subtitles')),
      );
      await tester.pump();
      await close(tester);
      expect(settings.bilibiliPortraitShowsSubtitles, isFalse);
      expect(BilibiliPortraitTabMemory.takeHandOff(_item().id), isNull);
    });

    for (final size in const <Size>[Size(412, 915), Size(800, 1280)]) {
      testWidgets('portrait ${size.width.toInt()} wide', (tester) async {
        window(
          tester,
          size,
          padding: const EdgeInsets.only(top: 30, bottom: 20),
        );
        final player = await showPortraitPlayer(tester);
        final loading = await showLoadingPage(
          tester,
          const BilibiliWatchPageShape(landscape: false),
        );
        expect(loading.area, player);
        expect(
          bilibiliWatchPortraitVideoArea(
            window: size,
            padding: const EdgeInsets.only(top: 30, bottom: 20),
            aspectRatio: 16 / 9,
          ),
          player,
        );
      });
    }
  });
}

final _defaultValueTypeCheck = Provider.debugCheckInvalidValueType;

class _Shown {
  const _Shown({required this.area, required this.back, this.title});

  final Rect area;
  final Rect back;
  final Rect? title;
}

const _bvid = 'BV1xx411c7mD';
const _title = '测试视频';

VideoItem _item() => VideoItem(
  id: 'watch-1',
  path: 'bilibili://stream/$_bvid?cid=101',
  title: _title,
  durationMs: 600000,
  lastUpdated: 0,
  isTransient: true,
  isBilibiliExported: true,
  sourceRef: const MediaSourceRef(
    value: _bvid,
    kind: MediaSourceKind.bilibiliStream,
    bvid: _bvid,
    cid: 101,
    page: 1,
  ),
);

BilibiliWatchPlan _plan() => BilibiliWatchPlan(
  item: _item(),
  imported: false,
  videoInfo: BilibiliVideoInfo(
    title: _title,
    desc: '',
    pic: '',
    bvid: _bvid,
    aid: '123',
    ownerName: 'UP',
    ownerMid: '1',
    pubDate: 0,
    pages: <BilibiliPage>[
      BilibiliPage(
        cid: 101,
        page: 1,
        part: '第 1 部分',
        duration: 600,
        bvid: _bvid,
        aid: '123',
      ),
    ],
  ),
);

class _NeverReadyStreaming extends BilibiliStreamingService {
  _NeverReadyStreaming() : super(BilibiliApiService());

  @override
  Future<BilibiliPreparedPlayback> prepare(
    VideoItem item, {
    int? qualityId,
    bool allowWarmReuse = true,
  }) => Completer<BilibiliPreparedPlayback>().future;
}

class _Paths extends PathProviderPlatform {
  _Paths(this.root);

  final String root;

  @override
  Future<String?> getApplicationDocumentsPath() async => root;

  @override
  Future<String?> getApplicationSupportPath() async => root;

  @override
  Future<String?> getApplicationCachePath() async => root;

  @override
  Future<String?> getTemporaryPath() async => root;
}
