import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/subtitle_style.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/utils/desktop_player_shortcuts.dart';
import 'package:video_player_app/widgets/video_controls_overlay.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    SettingsService().resetForTest();
  });

  Future<void> pumpOverlay(
    WidgetTester tester, {
    VoidCallback? onToggleBilibiliPanel,
    bool open = false,
  }) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<SettingsService>.value(
            value: SettingsService(),
          ),
          ChangeNotifierProvider<MediaPlaybackService>.value(
            value: MediaPlaybackService(),
          ),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: VideoControlsOverlay(
              controller: null,
              isLocked: false,
              onTogglePlay: () {},
              onBackPressed: () {},
              onExitPressed: () {},
              onToggleLock: () {},
              onSpeedUpdate: (_) async {},
              showSubtitles: false,
              onToggleSubtitles: () {},
              onMoveSubtitles: () {},
              isLongPressing: false,
              longPressFeedbackText: '',
              onLongPressStart: () => false,
              onLongPressEnd: () {},
              subtitleEntries: const [],
              subtitleStyle: const SubtitleStyle(),
              subtitleAlignment: Alignment.bottomCenter,
              onEnterSubtitleDragMode: () {},
              allowPlayWhenUninitialized: true,
              onToggleBilibiliPanel: onToggleBilibiliPanel,
              bilibiliPanelOpen: open,
            ),
          ),
        ),
      ),
    );
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 40));
  }

  KeyEventResult pressI(WidgetTester tester, FocusNode node) {
    final state = tester.state<VideoControlsOverlayState>(
      find.byType(VideoControlsOverlay),
    );
    final down = state.handleKeyEvent(
      node,
      const KeyDownEvent(
        physicalKey: PhysicalKeyboardKey.keyI,
        logicalKey: LogicalKeyboardKey.keyI,
        timeStamp: Duration.zero,
      ),
    );
    state.handleKeyEvent(
      node,
      const KeyUpEvent(
        physicalKey: PhysicalKeyboardKey.keyI,
        logicalKey: LogicalKeyboardKey.keyI,
        timeStamp: Duration.zero,
      ),
    );
    return down;
  }

  const buttonKey = ValueKey('video-controls-top-bilibili-panel');

  testWidgets('no Bilibili button for other videos', (tester) async {
    await pumpOverlay(tester);
    expect(find.byKey(buttonKey), findsNothing);
    await finish(tester);
  });

  testWidgets('a Bilibili video gets the button and the I key', (tester) async {
    var toggles = 0;
    await pumpOverlay(tester, onToggleBilibiliPanel: () => toggles++);
    expect(find.byKey(buttonKey), findsOneWidget);

    await tester.tap(find.byKey(buttonKey));
    await tester.pump();
    expect(toggles, 1);

    final node = FocusNode();
    addTearDown(node.dispose);
    pressI(tester, node);
    expect(toggles, 2);
    await finish(tester);
  });

  test('I is the panel shortcut', () {
    expect(
      DesktopPlayerShortcuts.matchAction(LogicalKeyboardKey.keyI),
      DesktopPlayerShortcutAction.toggleBilibiliPanel,
    );
    expect(
      DesktopPlayerShortcuts.shortcutLabel(
        DesktopPlayerShortcutAction.toggleBilibiliPanel,
      ),
      'I',
    );
  });

  group('the landscape page only wires the panel', () {
    final source = File(
      'lib/screens/video_player_screen.dart',
    ).readAsStringSync();
    int count(String pattern) => RegExp(pattern).allMatches(source).length;

    test('the button is passed for Bilibili videos only', () {
      expect(
        count(
          r'onToggleBilibiliPanel:\s*_isBilibiliVideo\s*\?\s*'
          r'_toggleBilibiliPanel\s*:\s*null',
        ),
        1,
      );
    });

    test('only the button / shortcut and the collapse button write the '
        'remembered state', () {
      expect(count(r'saveBilibiliPlayerPanelOpen'), 0);
      expect(count(r'_bilibiliPanelMemory\.userToggled\('), 1);
      expect(count(r'_bilibiliPanelMemory\.userCollapsed\('), 1);
      expect(count(r'onCollapse:\s*_collapseBilibiliPanel'), 1);
    });

    test('the panel and closing it hand focus back to the video', () {
      expect(count(r'void _returnFocusToVideo\('), 1);
      expect(count(r'_returnFocusToVideo\(\);'), 2);
    });
  });
}
