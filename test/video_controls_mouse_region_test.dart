import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_app/models/subtitle_style.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/widgets/video_controls_overlay.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'desktop controls hide outside the whole player and show on re-entry',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final controller = VideoPlayerController.networkUrl(
        Uri.parse('https://example.invalid/video.mp4'),
      );
      addTearDown(controller.dispose);

      final playbackService = MediaPlaybackService();
      addTearDown(playbackService.dispose);
      final controlsVisibility = ValueNotifier<bool>(true);
      addTearDown(controlsVisibility.dispose);

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<SettingsService>.value(
              value: SettingsService(),
            ),
            ChangeNotifierProvider<MediaPlaybackService>.value(
              value: playbackService,
            ),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: Row(
                children: [
                  SizedBox(
                    width: 750,
                    child: VideoControlsOverlay(
                      controller: controller,
                      isLocked: false,
                      onTogglePlay: () {},
                      onBackPressed: () {},
                      onToggleLock: () {},
                      onSpeedUpdate: (_) async {},
                      showSubtitles: false,
                      onToggleSubtitles: () {},
                      onMoveSubtitles: () {},
                      isLongPressing: false,
                      longPressFeedbackText: '',
                      onLongPressStart: () => true,
                      onLongPressEnd: () {},
                      subtitleEntries: const [],
                      subtitleStyle: const SubtitleStyle(),
                      subtitleAlignment: Alignment.bottomCenter,
                      onEnterSubtitleDragMode: () {},
                      playbackControlsVisibility: controlsVisibility,
                    ),
                  ),
                  const Expanded(
                    child: ColoredBox(
                      key: ValueKey('non-player-sidebar'),
                      color: Colors.grey,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );

      final playerMouseRegion = find.byKey(
        const ValueKey('video-controls-player-mouse-region'),
      );
      MouseRegion region() => tester.widget<MouseRegion>(playerMouseRegion);

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);

      // The complete 750px-wide surface is the player. This includes any
      // black space around a contained video.
      await mouse.addPointer(location: const Offset(500, 350));
      await tester.pump();
      expect(region().cursor, MouseCursor.defer);
      expect(controlsVisibility.value, isTrue);

      // Crossing into a sibling sidebar hides immediately, without a click.
      await mouse.moveTo(const Offset(900, 350));
      // The signal changes synchronously with the control state, before a
      // frame is pumped for rendering.
      expect(controlsVisibility.value, isFalse);
      await tester.pump();
      expect(region().cursor, SystemMouseCursors.none);

      // Re-entering is sufficient to show the controls again.
      await mouse.moveTo(const Offset(500, 350));
      expect(controlsVisibility.value, isTrue);
      await tester.pump();
      expect(region().cursor, MouseCursor.defer);

      // A rapid second round trip must not be affected by a stale hide timer.
      await mouse.moveTo(const Offset(900, 350));
      await mouse.moveTo(const Offset(500, 350));
      await tester.pump();
      expect(region().cursor, MouseCursor.defer);
      expect(tester.takeException(), isNull);

      await mouse.removePointer();
      await tester.pumpWidget(const SizedBox.shrink());
      // VideoPreviewService deliberately keeps a short cache-cleanup timer
      // after this overlay is disposed.
      await tester.pump(const Duration(seconds: 20));
    },
  );
}
