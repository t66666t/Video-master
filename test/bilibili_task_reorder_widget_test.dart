import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/bilibili_download_task.dart';
import 'package:video_player_app/models/bilibili_models.dart';
import 'package:video_player_app/screens/bilibili_download_screen.dart';
import 'package:video_player_app/services/bilibili/bilibili_download_service.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/settings_service.dart';

BilibiliDownloadTask _task(
  String bvid,
  int episodeCount, {
  bool expanded = true,
}) {
  final pages = List.generate(
    episodeCount,
    (index) => BilibiliPage(
      cid: index + 1,
      page: index + 1,
      part: '$bvid-P${index + 1}',
      duration: 60,
      bvid: bvid,
      aid: bvid,
    ),
  );
  final videoInfo = BilibiliVideoInfo(
    title: bvid,
    desc: '',
    pic: '',
    bvid: bvid,
    aid: bvid,
    ownerName: 'up',
    ownerMid: '1',
    pubDate: 0,
    pages: pages,
  );
  return BilibiliDownloadTask(
    taskId: 'task-$bvid',
    singleVideoInfo: videoInfo,
    videos: [
      BilibiliVideoItem(
        videoInfo: videoInfo,
        episodes: [
          for (final page in pages)
            BilibiliDownloadEpisode(page: page, bvid: bvid),
        ],
      ),
    ],
    isExpanded: expanded,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('长按拖动会平滑收起顶层单位、稳定排序并恢复原展开状态', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await tester.binding.setSurfaceSize(const Size(1200, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final settings = SettingsService()..resetForTest();
    await settings.init();
    final service = BilibiliDownloadService();
    final first = _task('BV-FIRST', 3);
    final second = _task('BV-SECOND', 1);
    final third = _task('BV-THIRD', 1, expanded: false);
    service.replaceTasksForTesting([first, second, third]);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: service),
          ChangeNotifierProvider.value(value: settings),
          ChangeNotifierProvider.value(value: LibraryService()),
        ],
        child: const MaterialApp(home: BilibiliDownloadScreen()),
      ),
    );
    await tester.pump();

    final firstHeader = find.byKey(const ValueKey('bb-task-task-BV-FIRST'));
    final secondHeader = find.byKey(const ValueKey('bb-task-task-BV-SECOND'));
    expect(firstHeader, findsOneWidget);
    expect(secondHeader, findsOneWidget);
    final secondTopBeforeDrag = tester.getTopLeft(secondHeader).dy;

    final gesture = await tester.startGesture(tester.getCenter(firstHeader));
    await tester.pump(const Duration(milliseconds: 430));
    await tester.pump(const Duration(milliseconds: 100));
    final secondTopDuringCollapse = tester.getTopLeft(secondHeader).dy;
    expect(secondTopDuringCollapse, lessThan(secondTopBeforeDrag));

    await tester.pump(const Duration(milliseconds: 120));
    expect(
      find.byKey(const ValueKey('bb-episode-task-BV-FIRST-BV-FIRST_1_1')),
      findsNothing,
    );

    final thirdHeader = find.byKey(const ValueKey('bb-task-task-BV-THIRD'));
    final thirdRect = tester.getRect(thirdHeader);
    await gesture.moveTo(Offset(thirdRect.center.dx, thirdRect.bottom - 4));
    await tester.pump(const Duration(milliseconds: 80));
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 210));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(service.taskIds, [second.taskId, third.taskId, first.taskId]);
    expect(first.isExpanded, isTrue);
    expect(second.isExpanded, isTrue);
    expect(third.isExpanded, isFalse);
    final restoredEpisode = find.byKey(
      const ValueKey('bb-episode-task-BV-FIRST-BV-FIRST_1_1'),
    );
    await tester.dragUntilVisible(
      restoredEpisode,
      find.byType(Scrollable).last,
      const Offset(0, -250),
    );
    expect(restoredEpisode, findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    service.dispose();
    settings.dispose();
  });
}
