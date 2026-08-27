import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_app/models/subtitle_style.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/widgets/video_controls_overlay.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('missing source keeps the play button available for retry', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1000, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final controller = VideoPlayerController.networkUrl(
      Uri.parse('https://example.invalid/missing.mp4'),
    );
    addTearDown(controller.dispose);
    var retryCount = 0;

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
              controller: controller,
              isLocked: false,
              onTogglePlay: () => retryCount++,
              onBackPressed: () {},
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
            ),
          ),
        ),
      ),
    );

    final playButton = find.byKey(const ValueKey('video-controls-play-pause'));
    expect(playButton, findsOneWidget);
    expect(tester.widget<IconButton>(playButton).onPressed, isNotNull);

    await tester.tap(playButton);
    await tester.pump();
    expect(retryCount, 1);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 20));
  });
}
