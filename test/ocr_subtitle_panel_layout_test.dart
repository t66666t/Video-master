import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:video_player_app/models/ocr_subtitle_models.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/bilibili/bilibili_api_service.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/media_materialization_service.dart';
import 'package:video_player_app/services/ocr_subtitle_manager.dart';
import 'package:video_player_app/widgets/ocr_subtitle_panel.dart';

class _LayoutTestOcrManager extends OcrSubtitleManager {
  _LayoutTestOcrManager() : super(library: LibraryService());

  @override
  Future<void> initialize() async {}

  @override
  Future<bool> isModelInstalled(OcrSubtitleLanguage language) async => true;

  @override
  Future<Duration> estimateDuration({
    required Duration mediaDuration,
    required Duration start,
    required Duration end,
    int trackCount = 1,
  }) async => const Duration(minutes: 1);

  @override
  int get totalBundledOnnxModelCount => 4;
}

void main() {
  testWidgets('OCR start action stays visible on a small landscape phone', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(568, 320));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final manager = _LayoutTestOcrManager();
    final materialization = MediaMaterializationService(BilibiliApiService());
    addTearDown(manager.dispose);
    addTearDown(materialization.dispose);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<OcrSubtitleManager>.value(value: manager),
          ChangeNotifierProvider<MediaMaterializationService>.value(
            value: materialization,
          ),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.centerRight,
              child: SizedBox(
                width: 261,
                child: OcrSubtitlePanel(
                  videoItem: VideoItem(
                    id: 'layout-test',
                    path: 'layout-test.mp4',
                    title: 'Layout test',
                    durationMs: 600000,
                    lastUpdated: 0,
                  ),
                  duration: const Duration(minutes: 10),
                  currentPosition: () => Duration.zero,
                  pauseForRegionSelection: () async => false,
                  restorePlayback: (_) async {},
                  onBack: () {},
                  onCompleted: (_) async {},
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final footer = find.byKey(const ValueKey('ocr-pinned-task-action'));
    final start = find.byKey(const ValueKey('ocr-pinned-start'));
    final progress = find.byKey(const ValueKey('ocr-pinned-progress'));

    expect(footer, findsOneWidget);
    expect(start, findsOneWidget);
    expect(progress, findsOneWidget);
    expect(tester.getRect(start).bottom, lessThanOrEqualTo(320));
    expect(tester.getRect(footer).height, lessThan(120));
    expect(tester.takeException(), isNull);
  });
}
