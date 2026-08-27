import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_app/models/media_chapter.dart';
import 'package:video_player_app/models/subtitle_style.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/widgets/player_control_metrics.dart';
import 'package:video_player_app/widgets/video_controls_overlay.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('bottom controls stay dense and scale with the player viewport', (
    tester,
  ) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = VideoPlayerController.networkUrl(
      Uri.parse('https://example.invalid/video.mp4'),
    );
    addTearDown(controller.dispose);
    final playbackService = MediaPlaybackService();
    addTearDown(playbackService.dispose);

    Future<double> pumpAt(
      Size size, {
      bool isLocked = false,
      bool compactTopRightButtons = false,
      bool showResetScreenButton = false,
      bool hasChapters = false,
    }) async {
      await tester.binding.setSurfaceSize(size);
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
              body: VideoControlsOverlay(
                controller: controller,
                isLocked: isLocked,
                isPreviewMode: false,
                onTogglePlay: () {},
                onBackPressed: () {},
                onToggleLock: () {},
                onOpenSettings: () {},
                onOpenSubtitleManager: () {},
                compactTopRightButtons: compactTopRightButtons,
                showDanmakuControls: true,
                danmakuEnabled: true,
                onToggleDanmaku: () {},
                onOpenDanmakuSettings: () {},
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
                showResetScreenButton: showResetScreenButton,
                onResetScreenTransform: showResetScreenButton ? () {} : null,
                chapters: hasChapters
                    ? const <MediaChapter>[
                        MediaChapter(title: '第一章', startMs: 0, endMs: 10000),
                      ]
                    : const <MediaChapter>[],
                onOpenChapters: hasChapters ? () {} : null,
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      final progressRect = tester.getRect(
        find.byKey(const ValueKey('video-controls-progress-area')),
      );
      final rowRect = tester.getRect(
        find.byKey(const ValueKey('video-controls-bottom-row')),
      );
      final metrics = PlayerControlMetrics.fromSize(size);

      expect(progressRect.bottom, closeTo(rowRect.top, 0.01));
      expect(
        progressRect.height,
        closeTo(
          metrics.progressAreaHeight(hasChapterButton: hasChapters),
          0.01,
        ),
      );
      expect(
        size.height - rowRect.bottom,
        closeTo(metrics.bottomPadding, 0.01),
      );
      final settingsRect = tester.getRect(
        find.byKey(const ValueKey('video-controls-top-settings')),
      );
      final subtitleLibraryRect = tester.getRect(
        find.byKey(const ValueKey('video-controls-top-subtitle-library')),
      );
      expect(settingsRect.right, closeTo(subtitleLibraryRect.left, 0.01));
      expect(
        settingsRect.width,
        greaterThanOrEqualTo(compactTopRightButtons ? 30 : 32),
      );
      expect(
        settingsRect.width,
        lessThanOrEqualTo(compactTopRightButtons ? 32 : 36),
      );
      if (isLocked) {
        expect(
          find.byKey(const ValueKey('player-side-danmaku-toggle')),
          findsNothing,
        );
        expect(
          find.byKey(const ValueKey('player-side-danmaku-settings')),
          findsNothing,
        );
        expect(
          find.byKey(const ValueKey('player-side-reset-screen')),
          findsNothing,
        );
      } else {
        final sideControlSize = tester.getSize(
          find.byKey(const ValueKey('player-side-danmaku-toggle')),
        );
        expect(sideControlSize, Size.square(metrics.sideControlButtonExtent));
        if (showResetScreenButton) {
          final resetRect = tester.getRect(
            find.byKey(const ValueKey('player-side-reset-screen')),
          );
          final lockButton = find.byKey(const ValueKey('player-side-lock'));
          if (lockButton.evaluate().isNotEmpty) {
            final lockRect = tester.getRect(lockButton);
            expect(resetRect.bottom, lessThan(lockRect.top));
          } else {
            // Windows/macOS do not expose the lock control. The reset action
            // still occupies the same side-control rail rather than the old
            // full-width row above the progress controls.
            expect(
              resetRect.left,
              closeTo(metrics.sideControlHorizontalInset, 0.01),
            );
          }
        }
      }
      return tester
          .getSize(find.byKey(const ValueKey('video-controls-play-pause')))
          .width;
    }

    final phoneButtonSize = await pumpAt(const Size(800, 360));
    final tabletButtonSize = await pumpAt(const Size(1280, 800));

    expect(phoneButtonSize, greaterThanOrEqualTo(40));
    expect(phoneButtonSize, lessThan(tabletButtonSize));
    await pumpAt(const Size(800, 360), compactTopRightButtons: true);
    await pumpAt(const Size(800, 360), showResetScreenButton: true);
    final resetTopWithoutChapters = tester
        .getRect(find.byKey(const ValueKey('player-side-reset-screen')))
        .top;
    await pumpAt(
      const Size(800, 360),
      showResetScreenButton: true,
      hasChapters: true,
    );
    final resetTopWithChapters = tester
        .getRect(find.byKey(const ValueKey('player-side-reset-screen')))
        .top;
    expect(resetTopWithChapters, resetTopWithoutChapters);
    await pumpAt(
      const Size(800, 360),
      isLocked: true,
      showResetScreenButton: true,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    // VideoPreviewService schedules a short idle cleanup when the overlay is
    // disposed; advance the fake clock so the test leaves no pending timer.
    await tester.pump(const Duration(seconds: 20));
  });
}
