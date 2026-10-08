import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/media_source_ref.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/screens/portrait_video_screen.dart';
import 'package:video_player_app/services/bilibili/bilibili_api_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_player_panel_memory.dart';
import 'package:video_player_app/services/bilibili/bilibili_player_panel_policy.dart';
import 'package:video_player_app/services/bilibili/bilibili_streaming_service.dart';
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
import 'package:video_player_app/widgets/episode_picker_panel.dart';
import 'package:video_player_app/widgets/subtitle_management_sheet.dart';
import 'package:video_player_app/widgets/subtitle_sidebar.dart';

import 'test_dir_cleanup.dart';

void main() {
  group('BilibiliPortraitTabMemory', () {
    test('details at first; only userPicked writes', () async {
      var stored = false;
      final writes = <bool>[];
      final memory = BilibiliPortraitTabMemory(
        readSubtitles: () => stored,
        writeSubtitles: (value) async {
          writes.add(value);
          stored = value;
        },
      );
      expect(memory.remembered, PortraitBilibiliTab.details);
      memory.userPicked(PortraitBilibiliTab.subtitles);
      await Future<void>.delayed(Duration.zero);
      expect(memory.remembered, PortraitBilibiliTab.subtitles);
      expect(writes, [true]);
    });

    test('a hand-off is for its card only, and taken once', () {
      BilibiliPortraitTabMemory.handOff('a', PortraitBilibiliTab.subtitles);
      expect(BilibiliPortraitTabMemory.takeHandOff('b'), isNull);
      expect(
        BilibiliPortraitTabMemory.takeHandOff('a'),
        PortraitBilibiliTab.subtitles,
      );
      expect(BilibiliPortraitTabMemory.takeHandOff('a'), isNull);
    });
  });

  group('portrait player, 「详情 | 字幕」 below the video', () {
    late Directory root;
    late PathProviderPlatform originalPaths;
    late LibraryService library;
    late MediaPlaybackService playback;
    final settings = SettingsService();

    setUp(() async {
      Provider.debugCheckInvalidValueType = null;
      SharedPreferences.setMockInitialValues(<String, Object>{});
      settings.resetForTest();
      await settings.init();
      root = await Directory.systemTemp.createTemp('bilibili_portrait_tabs_');
      originalPaths = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _Paths(root.path);
      library = LibraryService()..resetLibraryForTesting();
      playback = MediaPlaybackService();
      await playback.initialize(
        playlistManager: PlaylistManager(),
        progressTracker: ProgressTracker(),
        bilibiliStreamingService: _NeverReadyStreaming(),
      );
    });

    tearDown(() async {
      BilibiliPortraitTabMemory.takeHandOff(_bilibiliItem().id);
      settings.resetForTest();
      library.resetLibraryForTesting();
      PathProviderPlatform.instance = originalPaths;
      Provider.debugCheckInvalidValueType = _defaultValueTypeCheck;
      await deleteTestTempDir(root);
    });

    Future<void> open(WidgetTester tester, VideoItem item) async {
      tester.view.physicalSize = const Size(412, 915);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MultiProvider(
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
          child: MaterialApp(
            home: PortraitVideoScreen(videoItem: item, autoPlayOnEntry: false),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    }

    Future<void> close(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 30));
    }

    Future<void> settle(WidgetTester tester) async {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    }

    final tabBar = find.byKey(const ValueKey('bilibili-portrait-tab-bar'));
    final details = find.byType(BilibiliPlayerPanel);
    final subtitles = find.byType(SubtitleSidebar);

    PortraitBilibiliTab shownTab(WidgetTester tester) => tester
        .widget<BilibiliPortraitTabs>(find.byType(BilibiliPortraitTabs))
        .tab;

    testWidgets('a Bilibili video shows the details at first, the '
        'subtitle list a tap away; the tap is remembered', (tester) async {
      await open(tester, _bilibiliItem());
      expect(tabBar, findsOneWidget);
      expect(shownTab(tester), PortraitBilibiliTab.details);
      expect(details, findsOneWidget);
      // The subtitle list stays built behind the details, not visible.
      expect(find.byType(SubtitleSidebar, skipOffstage: false), findsOneWidget);
      expect(subtitles, findsNothing);
      expect(
        tester
            .widget<SubtitleSidebar>(
              find.byType(SubtitleSidebar, skipOffstage: false),
            )
            .isVisible,
        isFalse,
      );

      await tester.tap(
        find.byKey(const ValueKey('bilibili-portrait-tab-subtitles')),
      );
      await settle(tester);
      expect(shownTab(tester), PortraitBilibiliTab.subtitles);
      expect(subtitles, findsOneWidget);
      expect(tester.widget<SubtitleSidebar>(subtitles).isVisible, isTrue);
      expect(settings.bilibiliPortraitShowsSubtitles, isTrue);
      await close(tester);

      // The next Bilibili video opens on the remembered tab.
      await open(tester, _bilibiliItem());
      expect(shownTab(tester), PortraitBilibiliTab.subtitles);
      await tester.tap(
        find.byKey(const ValueKey('bilibili-portrait-tab-details')),
      );
      await settle(tester);
      expect(shownTab(tester), PortraitBilibiliTab.details);
      expect(settings.bilibiliPortraitShowsSubtitles, isFalse);
      await close(tester);
    });

    testWidgets('the part list takes the place of the details for a while; '
        'closing it brings the details back, nothing remembered', (
      tester,
    ) async {
      await open(tester, _bilibiliItem());
      tester.widget<BilibiliPlayerPanel>(details).onOpenEpisodes!();
      await settle(tester);
      expect(find.byType(EpisodePickerPanel), findsOneWidget);
      expect(tabBar, findsNothing);

      tester
          .widget<EpisodePickerPanel>(find.byType(EpisodePickerPanel))
          .onClose();
      await settle(tester);
      expect(find.byType(EpisodePickerPanel), findsNothing);
      expect(shownTab(tester), PortraitBilibiliTab.details);
      expect(details, findsOneWidget);
      expect(settings.bilibiliPortraitShowsSubtitles, isFalse);
      await close(tester);
    });

    testWidgets('the subtitle manager takes the place of the subtitle tab; '
        'closing it goes back to that tab', (tester) async {
      settings.bilibiliPortraitShowsSubtitles = true;
      await open(tester, _bilibiliItem());
      expect(shownTab(tester), PortraitBilibiliTab.subtitles);
      tester.widget<SubtitleSidebar>(subtitles).onOpenSubtitleManager!();
      await settle(tester);
      expect(find.byType(SubtitleManagementSheet), findsOneWidget);
      expect(tabBar, findsNothing);

      tester
          .widget<SubtitleManagementSheet>(find.byType(SubtitleManagementSheet))
          .onClose!();
      await settle(tester);
      expect(shownTab(tester), PortraitBilibiliTab.subtitles);
      expect(subtitles, findsOneWidget);
      expect(settings.bilibiliPortraitShowsSubtitles, isTrue);
      await close(tester);
    });

    testWidgets('the tab picked on the loading page is where the page '
        'starts, and where it comes back to; the memory stays', (tester) async {
      BilibiliPortraitTabMemory.handOff(
        _bilibiliItem().id,
        PortraitBilibiliTab.subtitles,
      );
      await open(tester, _bilibiliItem());
      expect(shownTab(tester), PortraitBilibiliTab.subtitles);
      tester.widget<SubtitleSidebar>(subtitles).onOpenEpisodePicker!();
      await settle(tester);
      tester
          .widget<EpisodePickerPanel>(find.byType(EpisodePickerPanel))
          .onClose();
      await settle(tester);
      expect(shownTab(tester), PortraitBilibiliTab.subtitles);
      expect(settings.bilibiliPortraitShowsSubtitles, isFalse);
      await close(tester);
    });

    testWidgets('other videos keep the plain subtitle list', (tester) async {
      settings.bilibiliPortraitShowsSubtitles = false;
      await open(tester, _localItem(root.path));
      expect(tabBar, findsNothing);
      expect(details, findsNothing);
      expect(subtitles, findsOneWidget);
      expect(tester.widget<SubtitleSidebar>(subtitles).isVisible, isTrue);
      await close(tester);
    });
  });
}

final _defaultValueTypeCheck = Provider.debugCheckInvalidValueType;

const _bvid = 'BV1xx411c7mD';

VideoItem _bilibiliItem() => VideoItem(
  id: 'watch-1',
  path: 'bilibili://stream/$_bvid?cid=101',
  title: '测试视频',
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

VideoItem _localItem(String root) => VideoItem(
  id: 'local-1',
  path: '$root/local.mp4',
  title: '本地视频',
  durationMs: 600000,
  lastUpdated: 0,
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
