import 'package:provider/provider.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/widgets/subtitle_debug_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/subtitle_debug_preset.dart';
import 'package:video_player_app/models/subtitle_style.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/services/subtitle_debug_session.dart';
import 'package:video_player_app/widgets/subtitle_settings_sheet.dart';
import 'package:video_player_app/widgets/subtitle_preset_chrome.dart';
import 'package:video_player_app/widgets/subtitle_overlay.dart';
import 'package:video_player_app/widgets/music_lyric_view.dart';

void main() {
  final session = SubtitleDebugSession.instance;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    session.resetForTest();
    await session.initialize();
    session.toggle();
    session.select(subtitleDebugPresets.first);
  });
  tearDown(session.resetForTest);
  testWidgets(
    'catalog fills sidebar height and tuning fits short, narrow and large-text windows',
    (tester) async {
      addTearDown(tester.view.reset);
      for (final spec in [
        (const Size(1280, 900), 320.0, 1.0),
        (const Size(800, 360), 280.0, 1.0),
        (const Size(360, 640), 360.0, 1.0),
        (const Size(240, 320), 240.0, 1.6),
      ]) {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = spec.$1;
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData.dark(),
            home: MediaQuery(
              data: MediaQueryData(
                size: spec.$1,
                textScaler: TextScaler.linear(spec.$3),
              ),
              child: Scaffold(
                body: Align(
                  alignment: Alignment.centerRight,
                  child: SizedBox(
                    width: spec.$2,
                    child: SubtitleSettingsSheet(
                      style: const SubtitleStyle(),
                      onClose: () {},
                      hideGhostModeToggle: true,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final scroll = find.byKey(
          const ValueKey('subtitle-preset-full-height-scroll'),
        );
        expect(
          tester.getSize(scroll).height,
          greaterThan(spec.$1.height - 220),
        );
        expect(tester.getRect(scroll).bottom, closeTo(spec.$1.height, 1));
        await tester.tap(find.text('微调当前预设'));
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing);
        final rect = tester.getRect(
          find.byKey(const ValueKey('subtitle-preset-inline-settings')),
        );
        expect(rect.left, greaterThanOrEqualTo(spec.$1.width - spec.$2));
        expect(rect.left, greaterThanOrEqualTo(0));
        expect(rect.top, greaterThanOrEqualTo(0));
        expect(rect.right, lessThanOrEqualTo(spec.$1.width));
        expect(rect.bottom, lessThanOrEqualTo(spec.$1.height));
        expect(tester.takeException(), isNull, reason: '$spec');
        await tester.tap(find.text('完成'));
        await tester.pumpAndSettle();
        await tester.pumpWidget(const SizedBox());
      }
    },
  );
  testWidgets('tuning scales both tracks and reset only changes this preset', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: Scaffold(
          body: SubtitleSettingsSheet(
            style: const SubtitleStyle(),
            onClose: () {},
            hideGhostModeToggle: true,
          ),
        ),
      ),
    );
    await tester.tap(find.text('微调当前预设'));
    await tester.pumpAndSettle();
    final ratio = session.preset!.ratio;
    final slider = tester.widget<Slider>(find.byType(Slider).first);
    slider.onChanged!(1.5);
    await tester.pump();
    expect(session.preset!.textScale, 1.5);
    expect(
      session.preset!.styleFor(secondary: true).fontSize /
          session.preset!.styleFor().fontSize,
      closeTo(ratio, .0001),
    );
    expect(session.resolved(subtitleDebugPresets[1].id).textScale, 1);
    await tester.tap(find.text('重置本预设'));
    await tester.pump();
    expect(session.preset!.textScale, 1);
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
  });
  testWidgets(
    'preset captions do not capture long press drag and useOriginal restores gestures',
    (tester) async {
      int drags = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: SubtitleOverlayGroup(
            entries: const [
              SubtitleOverlayEntry(text: '字幕', secondaryText: 'subtitle'),
            ],
            style: const SubtitleStyle(),
            alignment: Alignment.bottomCenter,
            onLongPress: () => drags++,
          ),
        ),
      );
      await tester.longPress(
        find.byType(SubtitlePresetContent),
        warnIfMissed: false,
      );
      expect(drags, 0);
      session.useOriginal();
      await tester.pump();
      await tester.longPress(find.byType(SubtitleOverlay));
      expect(drags, 1);
    },
  );
  testWidgets(
    'browse position survives tuning and reopening; locate reveals current preset',
    (tester) async {
      Widget app() => const MaterialApp(
        home: Scaffold(body: SizedBox(width: 320, child: SubtitleDebugPanel())),
      );
      await tester.pumpWidget(app());
      final scroll = find.byKey(
        const ValueKey('subtitle-preset-full-height-scroll'),
      );
      final state = tester.state<ScrollableState>(
        find.descendant(of: scroll, matching: find.byType(Scrollable)).first,
      );
      final target = (state.position.maxScrollExtent * 0.72).clamp(
        0.0,
        state.position.maxScrollExtent,
      );
      state.position.jumpTo(target);
      await tester.pump();
      final savedOffset = state.position.pixels;
      await tester.tap(find.text('微调当前预设'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      await tester.tap(find.text('主字幕颜色'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byType(TextFormField), findsOneWidget);
      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();
      expect(state.position.pixels, savedOffset);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      final restored = tester.state<ScrollableState>(
        find.descendant(of: scroll, matching: find.byType(Scrollable)).first,
      );
      expect(restored.position.pixels, savedOffset);
      session.select(subtitleDebugPresets[40]);
      await tester.pump();
      await tester.tap(find.byTooltip('定位当前样式'));
      await tester.pumpAndSettle();
      expect(
        find
            .byKey(ValueKey('preset-card-${subtitleDebugPresets[40].id}'))
            .hitTestable(),
        findsOneWidget,
      );
    },
  );
  testWidgets(
    'preset and original ghost switches share the persisted setting',
    (tester) async {
      final settings = SettingsService();
      settings.resetForTest();
      await tester.runAsync(() => settings.init());
      await tester.pumpWidget(
        ChangeNotifierProvider<SettingsService>.value(
          value: settings,
          child: MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 320,
                child: SubtitleSettingsSheet(
                  style: const SubtitleStyle(),
                  onClose: () {},
                ),
              ),
            ),
          ),
        ),
      );
      final toggle = find.byKey(SubtitleGhostModeToggle.toggleKey);
      final previous = settings.isGhostModeEnabled;
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(settings.isGhostModeEnabled, !previous);
      session.useOriginal();
      await tester.pumpAndSettle();
      expect(settings.isGhostModeEnabled, !previous);
      await tester.tap(toggle.first);
      await tester.pumpAndSettle();
      session.openCatalog();
      await tester.pumpAndSettle();
      expect(settings.isGhostModeEnabled, previous);
      expect(find.byType(Switch), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'ghost presets follow shared alignment while playback and export keep preset layout',
    (tester) async {
      Future<Rect> render(
        bool ghost,
        Alignment alignment, {
        bool export = false,
      }) async {
        await tester.pumpWidget(
          MaterialApp(
            home: SizedBox.expand(
              child: SubtitleOverlayGroup(
                entries: const [
                  SubtitleOverlayEntry(text: '字幕', secondaryText: 'Subtitle'),
                ],
                style: const SubtitleStyle(),
                alignment: alignment,
                isGhostMode: ghost,
                enableDebugPreview: !export,
                presetOverride: export ? session.preset : null,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        return tester.getRect(find.byType(SubtitlePresetContent));
      }

      final normal = await render(false, Alignment.topCenter);
      final ghostTop = await render(true, Alignment.topCenter);
      final ghostBottom = await render(true, Alignment.bottomCenter);
      expect(ghostTop.top, closeTo(0, 1));
      expect(ghostBottom.top, greaterThan(ghostTop.top + 100));
      expect(normal.top, greaterThan(ghostTop.top + 100));
      final exported = await render(false, Alignment.topCenter, export: true);
      expect(exported, normal);
    },
  );
  testWidgets('audio lyric rows keep music fonts while a video preset is on', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MusicLyricView(
            subtitles: [
              SubtitleItem(
                index: 0,
                startTime: Duration.zero,
                endTime: const Duration(seconds: 3),
                text: '字幕\nSubtitle',
              ),
            ],
            splitSubtitleByLine: true,
          ),
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 5));
  });
  testWidgets(
    'narrow phone sidebar keeps chrome labels visible without a switch row',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(240, 400);
      addTearDown(tester.view.reset);
      final settings = SettingsService();
      settings.resetForTest();
      await tester.runAsync(() => settings.init());
      await tester.pumpWidget(
        ChangeNotifierProvider<SettingsService>.value(
          value: settings,
          child: const MediaQuery(
            data: MediaQueryData(size: Size(240, 400)),
            child: MaterialApp(
              home: Scaffold(
                body: SizedBox(
                  width: 240,
                  child: SubtitleSettingsSheet(
                    style: SubtitleStyle(),
                    onClose: _noopClose,
                    onBack: _noopClose,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('字幕排版'), findsOneWidget);
      expect(find.byTooltip('关闭'), findsNothing);
      expect(find.text('使用原样式'), findsOneWidget);
      expect(find.text('微调当前预设'), findsOneWidget);
      expect(find.text('幽灵'), findsOneWidget);
      expect(find.byType(Switch), findsNothing);
      final ghost = tester.getSize(
        find.byKey(SubtitleGhostModeToggle.toggleKey),
      );
      expect(ghost.height, lessThan(32));
      final locate = tester.getSize(find.byTooltip('定位当前样式'));
      expect(locate.width, lessThanOrEqualTo(28));
      final category = tester.getSize(find.byTooltip('选择分类'));
      expect(category, locate);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'category button opens chips, filters the grid, and stays open',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(240, 400);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SizedBox(width: 240, child: SubtitleDebugPanel()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('清幕标准'), findsWidgets);
      expect(
        find.byKey(const ValueKey('subtitle-preset-category-panel')),
        findsNothing,
      );
      await tester.tap(find.byTooltip('选择分类'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('subtitle-preset-category-panel')),
        findsOneWidget,
      );
      expect(find.text('电影宋体'), findsOneWidget);
      expect(find.text('竖屏方屏'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('subtitle-preset-category-电影宋体')),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('subtitle-preset-category-panel')),
        findsOneWidget,
      );
      expect(
        find.byKey(ValueKey('preset-card-${subtitleDebugPresets[6].id}')),
        findsOneWidget,
      );
      expect(
        find.byKey(ValueKey('preset-card-${subtitleDebugPresets.first.id}')),
        findsNothing,
      );
      await tester.tap(find.byKey(const ValueKey('subtitle-preset-category-全部')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('subtitle-preset-category-panel')),
        findsOneWidget,
      );
      expect(
        find.byKey(ValueKey('preset-card-${subtitleDebugPresets.first.id}')),
        findsOneWidget,
      );
      await tester.tap(find.byTooltip('收起分类'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('subtitle-preset-category-panel')),
        findsNothing,
      );
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SizedBox(width: 480, child: SubtitleDebugPanel()),
          ),
        ),
      );
      tester.view.physicalSize = const Size(480, 720);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('选择分类'));
      await tester.pumpAndSettle();
      expect(find.text('通用黑体'), findsOneWidget);
      expect(find.text('纪录访谈'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}

void _noopClose() {}
