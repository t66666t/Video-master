import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image_lib;
import 'package:provider/provider.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/screens/music_player_screen.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/music_artwork_backdrop_cache.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/widgets/music_album_cover.dart';
import 'package:video_player_app/widgets/music_lyric_view.dart';
import 'package:video_player_app/widgets/music_text_optical_alignment.dart';
import 'package:video_player_app/widgets/music_playback_controls.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('music player system UI follows the phone orientation', () {
    expect(
      musicPlayerSystemUiModeForSize(const Size(390, 844)),
      SystemUiMode.edgeToEdge,
    );
    expect(
      musicPlayerSystemUiModeForSize(const Size(844, 390)),
      SystemUiMode.immersiveSticky,
    );
  });

  test('controls lyric mask completes before controls finish entering', () {
    expect(musicControlsLyricMaskProgress(0), 0);
    expect(musicControlsLyricMaskProgress(0.10), greaterThan(0.9));
    expect(musicControlsLyricMaskProgress(0.18), 1);
    expect(musicControlsLyricMaskProgress(1), 1);
  });

  test('direct lyric taps use a long eased movement profile', () {
    expect(musicLyricTapScrollDurationMs(0), 580);
    expect(musicLyricTapScrollDurationMs(3), 706);
    expect(musicLyricTapScrollDurationMs(99), 820);
    expect(musicLyricTapScrollCurve.transform(0.1), lessThan(0.1));
    expect(musicLyricTapScrollCurve.transform(0.9), greaterThan(0.9));
  });

  test('music CJK optical correction scales with the rendered font size', () {
    expect(musicCjkOpticalRaiseEm, 0.055);
    expect(musicCjkOpticalRaise(20), closeTo(1.1, 0.0001));
    expect(musicTextContainsCjk('English only'), isFalse);
    expect(musicTextContainsCjk('中文 title'), isTrue);
  });

  testWidgets(
    'portrait player keeps header, lyrics, and controls as overlays',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final settings = SettingsService()..resetForTest();
      final playback = MediaPlaybackService();

      Widget host(Widget child) {
        return MultiProvider(
          providers: [
            ChangeNotifierProvider<SettingsService>.value(value: settings),
            ChangeNotifierProvider<MediaPlaybackService>.value(value: playback),
          ],
          child: MaterialApp(home: child),
        );
      }

      await tester.pumpWidget(host(const MusicPlayerScreen(title: 'Track')));
      await tester.pump();

      final lyricMask = find.byKey(const ValueKey('music-portrait-lyric-mask'));
      final header = find.byKey(const ValueKey('music-portrait-header'));
      final controls = find.byKey(
        const ValueKey('music-portrait-controls-overlay'),
      );

      expect(lyricMask, findsOneWidget);
      expect(header, findsOneWidget);
      expect(controls, findsOneWidget);
      expect(
        find.byKey(const ValueKey('music-portrait-lyric-visibility-mask')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('music-controls-backdrop-filter')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('music-controls-obscuring-scrim')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('music-header-backdrop-filter')),
        findsNothing,
      );
      expect(
        tester.getTopLeft(lyricMask).dy,
        lessThan(tester.getBottomLeft(header).dy),
      );
      expect(
        tester.getTopLeft(controls).dy,
        greaterThan(tester.getTopLeft(header).dy),
      );
      expect(tester.getSize(controls).height, lessThan(844 * 0.31));
      final closeBackground = find.byKey(
        const ValueKey('music-portrait-close-background'),
      );
      expect(tester.getSize(closeBackground).width, lessThanOrEqualTo(38));

      await tester.pumpWidget(host(const SizedBox.shrink()));
    },
  );

  testWidgets('cached low-resolution backdrop still fills the viewport', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final cache = MusicArtworkBackdropCache.instance..clearForTest();
    addTearDown(cache.clearForTest);
    final cover = image_lib.Image(width: 24, height: 24);
    image_lib.fill(cover, color: image_lib.ColorRgb8(80, 120, 180));
    const coverPath = 'music-backdrop-layout-test-cover.png';
    cache.seedForTest(coverPath, image_lib.encodePng(cover));

    final settings = SettingsService()..resetForTest();
    final playback = MediaPlaybackService();
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<SettingsService>.value(value: settings),
          ChangeNotifierProvider<MediaPlaybackService>.value(value: playback),
        ],
        child: MaterialApp(
          home: MusicPlayerScreen(title: 'Track', coverImagePath: coverPath),
        ),
      ),
    );
    await tester.pump();

    final backdrop = find.byKey(
      const ValueKey<String>('music-backdrop-memory-$coverPath'),
    );
    expect(backdrop, findsOneWidget);
    expect(tester.getSize(backdrop), const Size(390, 844));

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('progress uses Apple layout while preserving seek callbacks', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final position = ValueNotifier<Duration>(const Duration(seconds: 25));
    addTearDown(position.dispose);
    final starts = <double>[];
    final changes = <double>[];
    final ends = <double>[];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 340,
              child: MusicPlaybackControls(
                totalDuration: const Duration(minutes: 4),
                positionListenable: position,
                onProgressChangeStart: starts.add,
                onProgressChanged: changes.add,
                onProgressChangeEnd: ends.add,
              ),
            ),
          ),
        ),
      ),
    );

    final slider = find.byKey(const ValueKey('music-progress-slider'));
    final currentTime = find.byKey(const ValueKey('music-current-time'));
    final remainingTime = find.byKey(const ValueKey('music-remaining-time'));

    expect(find.text('00:25'), findsOneWidget);
    expect(find.text('-03:35'), findsOneWidget);
    expect(
      tester.getCenter(slider).dy,
      lessThan(tester.getCenter(currentTime).dy),
    );
    expect(
      tester.getCenter(slider).dy,
      lessThan(tester.getCenter(remainingTime).dy),
    );
    expect(find.byIcon(CupertinoIcons.backward_fill), findsOneWidget);
    expect(find.byIcon(CupertinoIcons.forward_fill), findsOneWidget);

    SliderTheme sliderTheme() => tester.widget<SliderTheme>(
      find.ancestor(of: slider, matching: find.byType(SliderTheme)).first,
    );

    expect(sliderTheme().data.thumbShape, same(SliderComponentShape.noThumb));

    final sliderRect = tester.getRect(slider);
    final gesture = await tester.startGesture(
      Offset(sliderRect.left + sliderRect.width * 0.25, sliderRect.center.dy),
    );
    await gesture.moveBy(Offset(sliderRect.width * 0.25, 0));
    await tester.pump();

    expect(starts, isNotEmpty);
    expect(changes, isNotEmpty);
    expect(sliderTheme().data.thumbShape, isA<RoundSliderThumbShape>());

    await gesture.up();
    await tester.pump();

    expect(ends, hasLength(1));
    expect(sliderTheme().data.thumbShape, same(SliderComponentShape.noThumb));
  });

  testWidgets('lyric press feedback is transient and seek fires once', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final position = ValueNotifier<Duration>(Duration.zero);
    addTearDown(position.dispose);
    final seeks = <Duration>[];
    final subtitles = <SubtitleItem>[
      SubtitleItem(
        index: 0,
        startTime: Duration.zero,
        endTime: const Duration(seconds: 4),
        text: 'First lyric',
      ),
      SubtitleItem(
        index: 1,
        startTime: const Duration(seconds: 5),
        endTime: const Duration(seconds: 9),
        text: 'Second lyric',
      ),
      SubtitleItem(
        index: 2,
        startTime: const Duration(seconds: 10),
        endTime: const Duration(seconds: 14),
        text: 'Third lyric',
      ),
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MusicLyricView(
            subtitles: subtitles,
            positionListenable: position,
            onSeek: seeks.add,
            anchorFraction: 0.215,
            horizontalPaddingFraction: 0.082,
            applyEdgeFade: false,
          ),
        ),
      ),
    );
    await tester.pump();

    final pressFeedback = find.byKey(const ValueKey('music-lyric-press-1'));
    final rowScale = find.byKey(const ValueKey('music-lyric-row-scale-1'));
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('Second lyric')),
    );
    await tester.pump(const Duration(milliseconds: 100));

    expect(tester.widget<AnimatedOpacity>(pressFeedback).opacity, 1.0);
    expect(
      tester.widget<AnimatedOpacity>(pressFeedback).duration,
      const Duration(milliseconds: 90),
    );
    expect(tester.widget<AnimatedScale>(rowScale).scale, 0.982);
    expect(find.byKey(const ValueKey('music-lyric-ripple-1')), findsNothing);
    expect(
      find.descendant(of: rowScale, matching: find.byType(AnimatedSlide)),
      findsNothing,
    );

    await gesture.up();
    await tester.pump();
    expect(seeks, [const Duration(seconds: 5)]);

    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.widget<AnimatedOpacity>(pressFeedback).opacity, 0.0);
    expect(
      tester.widget<AnimatedOpacity>(pressFeedback).duration,
      const Duration(milliseconds: 780),
    );
    expect(
      tester.widget<AnimatedScale>(rowScale).duration,
      const Duration(milliseconds: 680),
    );
    expect(tester.widget<AnimatedScale>(rowScale).scale, 1.0);

    // Let the lyric scroll animation and its delayed guard complete so the
    // widget test also verifies that the interaction leaves no stray timer.
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('direct lyric tap suppresses the enclosing background tap', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    var suppressBackgroundTap = false;
    var backgroundTapCount = 0;
    final seeks = <Duration>[];
    final subtitles = <SubtitleItem>[
      SubtitleItem(
        index: 0,
        startTime: Duration.zero,
        endTime: const Duration(seconds: 4),
        text: 'Tap isolation first',
      ),
      SubtitleItem(
        index: 1,
        startTime: const Duration(seconds: 5),
        endTime: const Duration(seconds: 9),
        text: 'Tap isolation second',
      ),
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTap: () {
            if (suppressBackgroundTap) {
              suppressBackgroundTap = false;
            } else {
              backgroundTapCount++;
            }
          },
          child: MusicLyricView(
            subtitles: subtitles,
            onSeek: seeks.add,
            onDirectLyricTap: () => suppressBackgroundTap = true,
            applyEdgeFade: false,
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.text('Tap isolation second'));
    await tester.pump();

    expect(seeks, [const Duration(seconds: 5)]);
    expect(backgroundTapCount, 0);
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('paused ALAC lyric tap tolerates native packet undershoot', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final position = ValueNotifier<Duration>(Duration.zero);
    addTearDown(position.dispose);
    final subtitles = <SubtitleItem>[
      SubtitleItem(
        index: 0,
        startTime: Duration.zero,
        endTime: const Duration(seconds: 5),
        text: 'ALAC first',
      ),
      SubtitleItem(
        index: 1,
        startTime: const Duration(seconds: 5),
        endTime: const Duration(seconds: 10),
        text: 'ALAC second',
      ),
      SubtitleItem(
        index: 2,
        startTime: const Duration(seconds: 10),
        endTime: const Duration(seconds: 15),
        text: 'ALAC third',
      ),
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MusicLyricView(
            subtitles: subtitles,
            positionListenable: position,
            onSeek: (target) => position.value = target,
            stabilizeAlacDirectSeek: true,
            isPlaying: false,
            applyEdgeFade: false,
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.text('ALAC third'));
    await tester.pump();
    position.value = const Duration(milliseconds: 9907);
    await tester.pump(const Duration(milliseconds: 150));

    expect(
      tester
          .widget<AnimatedOpacity>(
            find.byKey(const ValueKey('music-lyric-row-opacity-2')),
          )
          .opacity,
      1.0,
    );
    expect(
      tester
          .widget<AnimatedOpacity>(
            find.byKey(const ValueKey('music-lyric-row-opacity-1')),
          )
          .opacity,
      0.30,
    );

    await tester.pump(const Duration(seconds: 1));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('non-ALAC lyric highlighting keeps exact boundary behavior', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final position = ValueNotifier<Duration>(Duration.zero);
    addTearDown(position.dispose);
    final subtitles = <SubtitleItem>[
      SubtitleItem(
        index: 0,
        startTime: Duration.zero,
        endTime: const Duration(seconds: 5),
        text: 'AAC first',
      ),
      SubtitleItem(
        index: 1,
        startTime: const Duration(seconds: 5),
        endTime: const Duration(seconds: 10),
        text: 'AAC second',
      ),
      SubtitleItem(
        index: 2,
        startTime: const Duration(seconds: 10),
        endTime: const Duration(seconds: 15),
        text: 'AAC third',
      ),
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MusicLyricView(
            subtitles: subtitles,
            positionListenable: position,
            onSeek: (target) => position.value = target,
            stabilizeAlacDirectSeek: false,
            isPlaying: false,
            applyEdgeFade: false,
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.text('AAC third'));
    await tester.pump();
    position.value = const Duration(milliseconds: 9907);
    await tester.pump(const Duration(milliseconds: 150));

    expect(
      tester
          .widget<AnimatedOpacity>(
            find.byKey(const ValueKey('music-lyric-row-opacity-1')),
          )
          .opacity,
      1.0,
    );
    expect(
      tester
          .widget<AnimatedOpacity>(
            find.byKey(const ValueKey('music-lyric-row-opacity-2')),
          )
          .opacity,
      0.34,
    );

    await tester.pump(const Duration(seconds: 1));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('first lyric stays inactive until its start time', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final position = ValueNotifier<Duration>(Duration.zero);
    addTearDown(position.dispose);
    final subtitles = <SubtitleItem>[
      SubtitleItem(
        index: 0,
        startTime: const Duration(seconds: 5),
        endTime: const Duration(seconds: 9),
        text: 'Delayed first lyric',
      ),
      SubtitleItem(
        index: 1,
        startTime: const Duration(seconds: 10),
        endTime: const Duration(seconds: 14),
        text: 'Following lyric',
      ),
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MusicLyricView(
            subtitles: subtitles,
            positionListenable: position,
            applyEdgeFade: false,
          ),
        ),
      ),
    );
    await tester.pump();

    final firstOpacity = find.byKey(
      const ValueKey('music-lyric-row-opacity-0'),
    );
    expect(tester.widget<AnimatedOpacity>(firstOpacity).opacity, lessThan(1));

    position.value = const Duration(milliseconds: 4999);
    await tester.pump();
    expect(tester.widget<AnimatedOpacity>(firstOpacity).opacity, lessThan(1));

    position.value = const Duration(seconds: 5);
    await tester.pump();
    expect(tester.widget<AnimatedOpacity>(firstOpacity).opacity, 1.0);

    await tester.pump(const Duration(seconds: 1));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'seeking into the prelude locates line zero without highlighting',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final position = ValueNotifier<Duration>(const Duration(seconds: 605));
      addTearDown(position.dispose);
      final subtitles = List<SubtitleItem>.generate(
        100,
        (index) => SubtitleItem(
          index: index,
          startTime: Duration(seconds: 5 + index * 10),
          endTime: Duration(seconds: 14 + index * 10),
          text: 'Prelude seek lyric $index',
        ),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MusicLyricView(
              subtitles: subtitles,
              positionListenable: position,
              applyEdgeFade: false,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Prelude seek lyric 60'), findsOneWidget);
      expect(find.text('Prelude seek lyric 0'), findsNothing);

      position.value = const Duration(seconds: 2);
      await tester.pumpAndSettle();

      expect(find.text('Prelude seek lyric 0'), findsOneWidget);
      final firstOpacity = tester.widget<AnimatedOpacity>(
        find.byKey(const ValueKey('music-lyric-row-opacity-0')),
      );
      expect(firstOpacity.opacity, lessThan(1));

      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('rapid scrub locations are interruptible and latest wins', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final position = ValueNotifier<Duration>(Duration.zero);
    final positionController = MusicLyricPositionController();
    addTearDown(position.dispose);
    addTearDown(positionController.dispose);
    final subtitles = List<SubtitleItem>.generate(
      100,
      (index) => SubtitleItem(
        index: index,
        startTime: Duration(seconds: index * 10),
        endTime: Duration(seconds: index * 10 + 9),
        text: 'Scrub lyric $index',
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MusicLyricView(
            subtitles: subtitles,
            positionListenable: position,
            positionController: positionController,
            applyEdgeFade: false,
          ),
        ),
      ),
    );
    await tester.pump();

    void scrubTo(Duration target) {
      positionController.locate(target);
      position.value = target;
    }

    scrubTo(const Duration(seconds: 600));
    await tester.pump(const Duration(milliseconds: 35));
    scrubTo(const Duration(seconds: 800));
    await tester.pump(const Duration(milliseconds: 35));
    scrubTo(const Duration(seconds: 200));
    await tester.pump(const Duration(milliseconds: 35));
    // An equal target is still a distinct drag-end positioning request.
    scrubTo(const Duration(seconds: 200));
    await tester.pumpAndSettle();

    expect(find.text('Scrub lyric 20'), findsOneWidget);
    final latestOpacity = tester.widget<AnimatedOpacity>(
      find.byKey(const ValueKey('music-lyric-row-opacity-20')),
    );
    expect(latestOpacity.opacity, 1.0);
    expect(find.text('Scrub lyric 80'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Chinese lyric centers its leading without changing English', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final subtitles = <SubtitleItem>[
      SubtitleItem(
        index: 0,
        startTime: Duration.zero,
        endTime: const Duration(seconds: 4),
        text: 'English lyric',
      ),
      SubtitleItem(
        index: 1,
        startTime: const Duration(seconds: 5),
        endTime: const Duration(seconds: 9),
        text: '中文歌词',
      ),
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MusicLyricView(subtitles: subtitles, applyEdgeFade: false),
        ),
      ),
    );
    await tester.pump();

    final english = tester.widget<Text>(find.text('English lyric'));
    final chinese = tester.widget<Text>(find.text('中文歌词'));
    expect(english.style?.leadingDistribution, isNull);
    expect(chinese.style?.leadingDistribution, TextLeadingDistribution.even);
    final englishAlignment = find.ancestor(
      of: find.text('English lyric'),
      matching: find.byType(MusicTextOpticalAlignment),
    );
    expect(
      tester
          .widget<MusicTextOpticalAlignment>(englishAlignment.first)
          .applyCjkRaise,
      isFalse,
    );
    final chineseAlignment = find.ancestor(
      of: find.text('中文歌词'),
      matching: find.byType(MusicTextOpticalAlignment),
    );
    expect(
      tester
          .widget<MusicTextOpticalAlignment>(chineseAlignment.first)
          .applyCjkRaise,
      isTrue,
    );
    final chineseTransform = tester.widget<Transform>(
      find.descendant(
        of: chineseAlignment.first,
        matching: find.byType(Transform),
      ),
    );
    expect(chineseTransform.transform.getTranslation().y, lessThan(0));

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('rapid lyric taps stay responsive and coalesce native seeks', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final seeks = <Duration>[];
    final subtitles = List<SubtitleItem>.generate(
      8,
      (index) => SubtitleItem(
        index: index,
        startTime: Duration(seconds: index * 5),
        endTime: Duration(seconds: index * 5 + 4),
        text: 'Rapid lyric $index',
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MusicLyricView(
            subtitles: subtitles,
            onSeek: seeks.add,
            applyEdgeFade: false,
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.text('Rapid lyric 1'));
    await tester.pump(const Duration(milliseconds: 35));
    final secondTap = await tester.startGesture(
      tester.getCenter(find.text('Rapid lyric 2')),
    );
    // Rebuild between down/up: the scrolling list is actively ignoring its
    // rows here, so only the stable outer hit map can retain this request.
    await tester.pump(const Duration(milliseconds: 1));
    await secondTap.up();
    await tester.pump(const Duration(milliseconds: 35));
    final repeatedTap = await tester.startGesture(
      tester.getCenter(find.text('Rapid lyric 2')),
    );
    await tester.pump(const Duration(milliseconds: 1));
    await repeatedTap.up();

    // Visual interactions happen for every tap, while the backend receives the
    // first request immediately and one latest-wins request for the burst.
    await tester.pump(const Duration(milliseconds: 150));
    expect(seeks, [const Duration(seconds: 5), const Duration(seconds: 10)]);

    await tester.pump(const Duration(seconds: 1));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'Windows tap stays on one scroll tree despite delayed seek feedback',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 601));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final position = ValueNotifier<Duration>(Duration.zero);
      addTearDown(position.dispose);
      final notifications = <ScrollNotification>[];
      final subtitles = List<SubtitleItem>.generate(
        8,
        (index) => SubtitleItem(
          index: index,
          startTime: Duration(seconds: index * 5),
          endTime: Duration(seconds: index * 5 + 4),
          text: 'Windows native lyric $index',
        ),
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: TargetPlatform.windows),
          home: Scaffold(
            body: NotificationListener<ScrollNotification>(
              onNotification: (notification) {
                notifications.add(notification);
                return false;
              },
              child: MusicLyricView(
                subtitles: subtitles,
                positionListenable: position,
                onSeek: (value) {
                  Timer(const Duration(milliseconds: 900), () {
                    position.value = value;
                  });
                },
                applyEdgeFade: false,
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 250));
      expect(
        find.byKey(const ValueKey<String>('music-lyric-windows-single-scroll')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('music-lyric-positioned-list')),
        findsNothing,
      );

      await tester.tap(find.text('Windows native lyric 3'));
      await tester.pump(const Duration(milliseconds: 80));
      final replacementTap = await tester.startGesture(
        tester.getCenter(find.text('Windows native lyric 5')),
      );
      await tester.pump(const Duration(milliseconds: 1));
      await replacementTap.up();
      await tester.pump();
      for (var frame = 0; frame < 50; frame++) {
        await tester.pump(const Duration(milliseconds: 17));
      }
      final settledTop = tester
          .getTopLeft(find.text('Windows native lyric 5'))
          .dy;
      notifications.clear();

      for (var frame = 0; frame < 36; frame++) {
        await tester.pump(const Duration(milliseconds: 17));
      }

      expect(notifications.whereType<ScrollStartNotification>(), isEmpty);
      expect(
        tester.getTopLeft(find.text('Windows native lyric 5')).dy,
        closeTo(settledTop, 0.1),
      );
      expect(settledTop, closeTo(601 * 0.30, 0.1));
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('Android landscape accepts a replacement tap while scrolling', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final seeks = <Duration>[];
    final subtitles = List<SubtitleItem>.generate(
      8,
      (index) => SubtitleItem(
        index: index,
        startTime: Duration(seconds: index * 5),
        endTime: Duration(seconds: index * 5 + 4),
        text: 'Android landscape lyric $index',
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.android),
        home: Scaffold(
          body: MusicLyricView(
            subtitles: subtitles,
            onSeek: seeks.add,
            applyEdgeFade: false,
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 250));

    await tester.tap(find.text('Android landscape lyric 2'));
    await tester.pump(const Duration(milliseconds: 80));
    final replacementStartTop = tester
        .getTopLeft(find.text('Android landscape lyric 4'))
        .dy;
    final replacement = await tester.startGesture(
      tester.getCenter(find.text('Android landscape lyric 4')),
    );
    await tester.pump(const Duration(milliseconds: 1));
    await replacement.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump(const Duration(milliseconds: 160));
    final replacementMidTop = tester
        .getTopLeft(find.text('Android landscape lyric 4'))
        .dy;

    expect(seeks, [const Duration(seconds: 10), const Duration(seconds: 20)]);
    expect(
      (replacementMidTop - replacementStartTop).abs(),
      greaterThan(2),
      reason: 'the replacement tap must start a new positioning animation',
    );
    await tester.pump(const Duration(milliseconds: 900));
    expect(
      tester.getTopLeft(find.text('Android landscape lyric 4')).dy,
      closeTo(600 * 0.30, 1.0),
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('iOS landscape accepts a replacement tap while scrolling', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final seeks = <Duration>[];
    final subtitles = List<SubtitleItem>.generate(
      8,
      (index) => SubtitleItem(
        index: index,
        startTime: Duration(seconds: index * 5),
        endTime: Duration(seconds: index * 5 + 4),
        text: 'iOS landscape lyric $index',
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.iOS),
        home: Scaffold(
          body: MusicLyricView(
            subtitles: subtitles,
            onSeek: seeks.add,
            applyEdgeFade: false,
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 250));

    await tester.tap(find.text('iOS landscape lyric 2'));
    await tester.pump(const Duration(milliseconds: 80));
    final replacementStartTop = tester
        .getTopLeft(find.text('iOS landscape lyric 4'))
        .dy;
    final replacement = await tester.startGesture(
      tester.getCenter(find.text('iOS landscape lyric 4')),
    );
    await tester.pump(const Duration(milliseconds: 1));
    await replacement.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump(const Duration(milliseconds: 160));
    final replacementMidTop = tester
        .getTopLeft(find.text('iOS landscape lyric 4'))
        .dy;

    expect(seeks, [const Duration(seconds: 10), const Duration(seconds: 20)]);
    expect(
      (replacementMidTop - replacementStartTop).abs(),
      greaterThan(2),
      reason: 'the iOS replacement tap must keep its positioning animation',
    );
    await tester.pump(const Duration(milliseconds: 900));
    expect(
      tester.getTopLeft(find.text('iOS landscape lyric 4')).dy,
      closeTo(600 * 0.30, 1.0),
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('replacement lyrics locate the active line before fading in', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final position = ValueNotifier<Duration>(const Duration(seconds: 50));
    addTearDown(position.dispose);

    List<SubtitleItem> timeline(String prefix, int stepSeconds) =>
        List<SubtitleItem>.generate(30, (index) {
          final start = Duration(seconds: index * stepSeconds);
          return SubtitleItem(
            index: index,
            startTime: start,
            endTime: start + Duration(seconds: stepSeconds - 1),
            text: '$prefix $index',
          );
        });

    Widget host(List<SubtitleItem> subtitles) => MaterialApp(
      home: Scaffold(
        body: MusicLyricView(
          subtitles: subtitles,
          positionListenable: position,
          applyEdgeFade: false,
        ),
      ),
    );

    await tester.pumpWidget(host(timeline('Old', 5)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 220));

    final oldActive = find.text('Old 10');
    expect(oldActive, findsOneWidget);
    expect(tester.getTopLeft(oldActive).dy, inInclusiveRange(180, 330));

    position.value = const Duration(seconds: 72);
    await tester.pumpWidget(host(timeline('New', 6)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 220));

    final newActive = find.text('New 12');
    expect(newActive, findsOneWidget);
    expect(tester.getTopLeft(newActive).dy, inInclusiveRange(180, 330));
    expect(find.text('Old 10'), findsNothing);

    await tester.pump(const Duration(seconds: 1));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('song metadata keeps identical geometry across title changes', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(900, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    var title = 'Short title';
    late StateSetter update;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          backgroundColor: Colors.black,
          body: Center(
            child: StatefulBuilder(
              builder: (context, setState) {
                update = setState;
                return MusicAlbumCover(
                  title: title,
                  coverSize: 180,
                  infoWidth: 180,
                  onExitTrigger: () {},
                );
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final shortSize = tester.getSize(find.byType(MusicAlbumCover));

    update(() {
      title = 'A deliberately much longer title that wraps onto a second line';
    });
    await tester.pump();
    final longSize = tester.getSize(find.byType(MusicAlbumCover));

    expect(longSize, shortSize);
  });

  testWidgets('long transcripts only build rows near the viewport', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final position = ValueNotifier<Duration>(Duration.zero);
    addTearDown(position.dispose);
    final subtitles = List<SubtitleItem>.generate(
      5000,
      (index) => SubtitleItem(
        index: index,
        startTime: Duration(seconds: index),
        endTime: Duration(seconds: index + 1),
        text: 'Virtual lyric $index',
      ),
      growable: false,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MusicLyricView(
            subtitles: subtitles,
            positionListenable: position,
            anchorFraction: 0.215,
            horizontalPaddingFraction: 0.082,
            applyEdgeFade: false,
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 250));

    final builtPressLayers = find.byWidgetPredicate((widget) {
      final key = widget.key;
      return widget is AnimatedOpacity &&
          key is ValueKey<String> &&
          key.value.startsWith('music-lyric-press-');
    });

    expect(builtPressLayers, findsWidgets);
    expect(builtPressLayers.evaluate().length, lessThan(80));
    expect(find.text('Virtual lyric 4999'), findsNothing);

    position.value = const Duration(seconds: 4999);
    await tester.pumpAndSettle(
      const Duration(milliseconds: 50),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 3),
    );

    expect(find.text('Virtual lyric 4999'), findsOneWidget);
    expect(builtPressLayers.evaluate().length, lessThan(80));

    await tester.pumpWidget(const SizedBox.shrink());
  });
}
