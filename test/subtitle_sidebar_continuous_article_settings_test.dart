import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/widgets/subtitle_sidebar.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'paragraph mode is backward-compatible and included in layout export',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'subtitleArticleSentencesPerParagraph': 9,
      });
      final settings = SettingsService();
      settings.resetForTest();
      await settings.init();

      expect(settings.subtitleArticleParagraphModeEnabled, isTrue);
      expect(settings.subtitleArticleSentencesPerParagraph, 9);
      final layout =
          settings.exportSettingsSnapshot()['layout'] as Map<String, dynamic>;
      expect(layout['subtitleArticleParagraphModeEnabled'], isTrue);
      expect(layout['subtitleArticleSentencesPerParagraph'], 9);
    },
  );

  testWidgets('continuous mode persists and disables paragraph size editor', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'subtitleViewMode': 1,
      'subtitleArticleParagraphModeEnabled': false,
      'subtitleArticleSentencesPerParagraph': 7,
    });
    final settings = SettingsService();
    settings.resetForTest();
    await settings.init();
    final controller = VideoPlayerController.networkUrl(
      Uri.parse('https://example.invalid/continuous.mp4'),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 320,
            height: 420,
            child: SubtitleSidebar(
              subtitles: List<SubtitleItem>.generate(
                8,
                (index) => SubtitleItem(
                  index: index + 1,
                  startTime: Duration(seconds: index),
                  endTime: Duration(seconds: index + 1),
                  text: 'sentence $index',
                ),
              ),
              controller: controller,
              isCompact: true,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(
      find.byKey(const ValueKey('subtitle-continuous-article-view')),
      findsOneWidget,
    );
    await tester.tap(find.byIcon(Icons.format_size));
    await tester.pump();
    final switchFinder = find.byKey(
      const ValueKey('subtitle-paragraph-mode-switch'),
    );
    expect(tester.widget<Switch>(switchFinder).value, isFalse);
    expect(
      find.ancestor(
        of: find.byKey(
          const ValueKey('subtitle-sentences-per-paragraph-input'),
        ),
        matching: find.byType(IgnorePointer),
      ),
      findsWidgets,
    );

    await tester.tap(switchFinder);
    await tester.pump();
    expect(settings.subtitleArticleParagraphModeEnabled, isTrue);
    expect(settings.subtitleArticleSentencesPerParagraph, 7);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('subtitleArticleParagraphModeEnabled'), isTrue);

    await tester.pumpWidget(const SizedBox.shrink());
    await controller.dispose();
  });

  testWidgets(
    'turning paragraph mode off responds before a long layout finishes',
    (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'subtitleViewMode': 1,
        'subtitleArticleParagraphModeEnabled': true,
      });
      final settings = SettingsService();
      settings.resetForTest();
      await settings.init();
      final controller = VideoPlayerController.networkUrl(
        Uri.parse('https://example.invalid/long-continuous.mp4'),
      );
      final subtitles = List<SubtitleItem>.generate(
        4000,
        (index) => SubtitleItem(
          index: index + 1,
          startTime: Duration(seconds: index),
          endTime: Duration(seconds: index + 1),
          text: 'A reasonably long subtitle sentence number $index.',
        ),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 320,
              height: 420,
              child: SubtitleSidebar(
                subtitles: subtitles,
                controller: controller,
                isCompact: true,
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byIcon(Icons.format_size));
      await tester.pump();
      await tester.tap(
        find.byKey(const ValueKey('subtitle-paragraph-mode-control')),
      );
      await tester.pump();

      expect(settings.subtitleArticleParagraphModeEnabled, isFalse);
      expect(
        find.byKey(const ValueKey('subtitle-continuous-article-preparing')),
        findsOneWidget,
      );

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await controller.dispose();
    },
  );
}
