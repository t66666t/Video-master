import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:video_player_app/models/batch_subtitle_task_view.dart';
import 'package:video_player_app/models/transcription_status.dart';
import 'package:video_player_app/screens/batch_subtitle_screen.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/services/transcription_manager.dart';
import 'package:video_player_app/widgets/task_queue_table.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final tasks = <BatchSubtitleTaskView>[
    const BatchSubtitleTaskView(
      mediaKey: 'internal:1',
      videoPath: 'first.mp4',
      videoId: '1',
      videoName: '这是一个用于测试窄屏省略显示的超长内部视频名称.mp4',
      videoDuration: '01:23:45',
      isExternal: false,
      status: TranscriptionStatus.transcribing,
      progress: 0.68,
      statusMessage: '正在生成字幕，请稍候',
      createdAt: 1,
      isStarted: true,
    ),
    const BatchSubtitleTaskView(
      mediaKey: 'external:2',
      videoPath: 'second.mkv',
      videoName: '外部视频.mkv',
      videoDuration: '08:12',
      isExternal: true,
      status: TranscriptionStatus.completed,
      progress: 1,
      statusMessage: '转录完成',
      createdAt: 2,
      isStarted: true,
    ),
  ];

  testWidgets('start all remains actionable when every task failed', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 800);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final manager = _FailedQueueManager(
      tasks.last.copyWith(status: TranscriptionStatus.error),
    );
    addTearDown(manager.dispose);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<TranscriptionManager>.value(value: manager),
          ChangeNotifierProvider<SettingsService>.value(
            value: SettingsService(),
          ),
          ChangeNotifierProvider<LibraryService>.value(value: LibraryService()),
        ],
        child: const MaterialApp(home: BatchSubtitleScreen()),
      ),
    );
    await tester.tap(find.text('全部开始'));
    expect(manager.startAllCalls, 1);
    expect(tester.takeException(), isNull);
  });

  for (final width in [360.0, 1280.0]) {
    testWidgets('running and queued rows can pause at width $width', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(width, 800);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final paused = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TaskQueueTable(
              tasks: [
                tasks.first,
                tasks.last.copyWith(
                  status: TranscriptionStatus.idle,
                  isStarted: true,
                ),
              ],
              autoDeletedKeys: const {},
              onStart: (_) {},
              onRetry: (_) {},
              onDelete: (_) {},
              onReorder: (_, _) {},
              onPause: paused.add,
            ),
          ),
        ),
      );
      expect(find.byTooltip('暂停'), findsNWidgets(2));
      await tester.tap(find.byTooltip('暂停').first);
      await tester.tap(find.byTooltip('暂停').last);
      expect(paused, [tasks.first.mediaKey, tasks.last.mediaKey]);
      expect(tester.takeException(), isNull);
    });
  }

  for (final size in <Size>[
    const Size(320, 568),
    const Size(360, 800),
    const Size(800, 360),
    const Size(600, 960),
    const Size(768, 1024),
    const Size(1024, 768),
    const Size(1120, 650),
    const Size(1280, 720),
    const Size(1440, 900),
  ]) {
    testWidgets(
      'task queue is tabular without overflow at ${size.width.toInt()}x${size.height.toInt()}',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = size;
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);

        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(useMaterial3: true),
            home: Scaffold(
              body: TaskQueueTable(
                tasks: tasks,
                autoDeletedKeys: const {},
                onStart: (_) {},
                onRetry: (_) {},
                onDelete: (_) {},
                onReorder: (_, _) {},
                onTapCompleted: (_) {},
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.textContaining('超长内部视频名称'), findsOneWidget);
        final completedText = tester.widget<Text>(find.text('外部视频.mkv'));
        final completedContext = tester.element(find.text('外部视频.mkv'));
        expect(completedText.style?.decoration, TextDecoration.underline);
        expect(
          completedText.style?.color,
          Theme.of(completedContext).colorScheme.onSurface,
        );
        if (size.width == 320) {
          expect(find.text('名称（2）'), findsOneWidget);
          expect(find.text('状态'), findsOneWidget);
          expect(find.text('操作'), findsOneWidget);
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final size in <Size>[
    const Size(320, 568),
    const Size(360, 800),
    const Size(800, 360),
    const Size(600, 960),
    const Size(768, 1024),
    const Size(1024, 768),
    const Size(1120, 650),
    const Size(1280, 720),
    const Size(1440, 900),
  ]) {
    testWidgets(
      'batch screen toolbar has no overflow at ${size.width.toInt()}px',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = size;
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);

        final manager = TranscriptionManager();
        addTearDown(manager.dispose);
        await tester.pumpWidget(
          MultiProvider(
            providers: [
              ChangeNotifierProvider<TranscriptionManager>.value(
                value: manager,
              ),
              ChangeNotifierProvider<SettingsService>.value(
                value: SettingsService(),
              ),
              ChangeNotifierProvider<LibraryService>.value(
                value: LibraryService(),
              ),
            ],
            child: MaterialApp(
              theme: ThemeData(
                useMaterial3: true,
                brightness: Brightness.dark,
                fontFamily: 'Test App Font',
              ),
              home: const BatchSubtitleScreen(),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('批量字幕生成'), findsOneWidget);
        final titleContext = tester.element(find.text('批量字幕生成'));
        // 批量字幕页统一强制使用思源黑体，不随应用默认字体变化。
        expect(
          Theme.of(titleContext).textTheme.bodyMedium?.fontFamily,
          'Noto Sans SC',
        );
        expect(find.byType(Switch), findsNothing);
        if (size.width == 320) {
          expect(find.text('添加视频'), findsOneWidget);
          expect(find.text('开始全部'), findsOneWidget);
          expect(find.text('保留已完成任务'), findsOneWidget);
          expect(find.text('更多'), findsOneWidget);
        }
        if (size.shortestSide >= 600 && size.width < 1100) {
          expect(find.text('开始全部任务'), findsOneWidget);
        }
        if (size.width >= 1120) {
          expect(find.text('完成后移除'), findsOneWidget);
          expect(find.text('外部视频软字幕内嵌'), findsOneWidget);
          expect(find.text('字幕输出位置'), findsOneWidget);
          expect(find.text('清理队列'), findsOneWidget);
        }
        expect(tester.takeException(), isNull);
      },
    );
  }
}

class _FailedQueueManager extends TranscriptionManager {
  _FailedQueueManager(this.task);
  final BatchSubtitleTaskView task;
  int startAllCalls = 0;

  @override
  List<BatchSubtitleTaskView> getQueueSnapshot() => [task];

  @override
  void startAllTasks() {
    startAllCalls++;
  }
}
