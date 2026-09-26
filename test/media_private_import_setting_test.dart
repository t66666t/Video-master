import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/services/clipboard_parse_repeat.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/widgets/media_library_settings_sheet.dart';

void useTallSettingsSurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(800, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    SettingsService().resetForTest();
  });

  test('打开时回到上次页面默认开启，关闭后可记住指定入口', () async {
    final settings = SettingsService();
    await settings.init();

    expect(settings.mediaLibraryRestoreLastPage, isTrue);
    expect(settings.mediaLibraryStartupEntry, 'folders');

    await settings.updateSetting('mediaLibraryRestoreLastPage', false);
    await settings.updateSetting(
      'mediaLibraryStartupEntry',
      'continueLearning',
    );
    await settings.updateSetting('mediaLibraryStartupEntry', 'not-a-page');

    expect(settings.mediaLibraryStartupEntry, 'folders');

    await settings.updateSetting('mediaLibraryStartupEntry', 'recent');
    settings.resetForTest();
    await settings.init();
    expect(settings.mediaLibraryRestoreLastPage, isFalse);
    expect(settings.mediaLibraryStartupEntry, 'recent');
  });

  test('导入媒体到应用私有目录默认关闭', () async {
    final settings = SettingsService();
    await settings.init();

    expect(settings.copyImportedMediaToPrivateStorage, isFalse);
  });

  test('私有目录导入设置可持久化并在重新初始化后恢复', () async {
    final settings = SettingsService();
    await settings.init();

    await settings.updateSetting('copyImportedMediaToPrivateStorage', true);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('copyImportedMediaToPrivateStorage'), isTrue);

    settings.resetForTest();
    await settings.init();
    expect(settings.copyImportedMediaToPrivateStorage, isTrue);
  });

  test('更新调用会立即改变运行时值并通知监听器', () async {
    final settings = SettingsService();
    await settings.init();
    var notificationCount = 0;
    settings.addListener(() => notificationCount++);

    final persistence = settings.updateSetting(
      'copyImportedMediaToPrivateStorage',
      true,
    );

    expect(settings.copyImportedMediaToPrivateStorage, isTrue);
    expect(notificationCount, 1);
    await persistence;
  });

  testWidgets('媒体库设置弹窗可即时切换私有目录导入', (tester) async {
    useTallSettingsSurface(tester);
    final settings = SettingsService();
    await settings.init();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () =>
                  showMediaLibrarySettingsBottomSheet(context, settings),
              child: const Text('打开设置'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开设置'));
    await tester.pumpAndSettle();
    expect(find.text('打开时回到上次离开的页面'), findsOneWidget);
    expect(find.text('文件夹'), findsNothing);
    expect(find.text('导入时复制媒体到应用私有目录'), findsOneWidget);
    expect(find.text('搜索结果作为播放队列'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('mediaLibraryRestoreLastPage')));
    await tester.pump();
    expect(settings.mediaLibraryRestoreLastPage, isFalse);
    expect(find.text('继续学习'), findsOneWidget);
    expect(find.text('最近添加'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey('mediaLibraryStartupEntry-continueLearning')),
    );
    await tester.pump();
    expect(settings.mediaLibraryStartupEntry, 'continueLearning');

    await tester.tap(
      find.byKey(const ValueKey('copyImportedMediaToPrivateStorage')),
    );
    await tester.pump();
    expect(settings.copyImportedMediaToPrivateStorage, isTrue);
    expect(settings.useSearchResultsAsPlaybackQueue, isFalse);
  });

  test('搜索结果作为播放队列默认关闭', () async {
    final settings = SettingsService();
    await settings.init();

    expect(settings.useSearchResultsAsPlaybackQueue, isFalse);
  });

  test('搜索结果作为播放队列可持久化并在重新初始化后恢复', () async {
    final settings = SettingsService();
    await settings.init();

    await settings.updateSetting('useSearchResultsAsPlaybackQueue', true);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('useSearchResultsAsPlaybackQueue'), isTrue);

    settings.resetForTest();
    await settings.init();
    expect(settings.useSearchResultsAsPlaybackQueue, isTrue);
  });

  testWidgets('媒体库设置弹窗可即时切换搜索结果播放队列', (tester) async {
    useTallSettingsSurface(tester);
    final settings = SettingsService();
    await settings.init();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () =>
                  showMediaLibrarySettingsBottomSheet(context, settings),
              child: const Text('打开设置'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开设置'));
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey('useSearchResultsAsPlaybackQueue')),
    );
    await tester.pump();
    expect(settings.useSearchResultsAsPlaybackQueue, isTrue);
  });

  test('后台播放哔哩哔哩时只加载音频默认关闭', () async {
    final settings = SettingsService();
    await settings.init();

    expect(settings.bilibiliBackgroundAudioOnly, isFalse);
  });

  test('哔哩哔哩后台只加载音频可持久化并在重新初始化后恢复', () async {
    final settings = SettingsService();
    await settings.init();

    await settings.updateSetting('bilibiliBackgroundAudioOnly', true);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('bilibiliBackgroundAudioOnly'), isTrue);

    settings.resetForTest();
    await settings.init();
    expect(settings.bilibiliBackgroundAudioOnly, isTrue);
  });

  testWidgets('媒体库设置弹窗可即时切换哔哩哔哩后台只加载音频', (tester) async {
    useTallSettingsSurface(tester);
    final settings = SettingsService();
    await settings.init();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () =>
                  showMediaLibrarySettingsBottomSheet(context, settings),
              child: const Text('打开设置'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开设置'));
    await tester.pumpAndSettle();
    expect(find.text('后台播放哔哩哔哩时只加载音频'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('bilibiliBackgroundAudioOnly')));
    await tester.pump();
    expect(settings.bilibiliBackgroundAudioOnly, isTrue);
  });

  test('相同剪贴板只识别一次默认打开', () async {
    final settings = SettingsService();
    await settings.init();

    expect(settings.skipRepeatedClipboardText, isTrue);
    expect(settings.clipboardLastHandledText, isNull);
  });

  test('相同剪贴板开关可持久化，已识别文字不进入设置导出', () async {
    final settings = SettingsService();
    await settings.init();

    await settings.updateSetting('skipRepeatedClipboardText', false);
    await settings.rememberClipboardHandledText(
      ' https://www.bilibili.com/video/BV1xx411c7mD ',
    );

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('skipRepeatedClipboardText'), isFalse);
    expect(
      prefs.getString(SettingsService.clipboardLastHandledTextKey),
      'https://www.bilibili.com/video/BV1xx411c7mD',
    );

    final home =
        settings.exportSettingsSnapshot()['home'] as Map<String, dynamic>;
    expect(home['skipRepeatedClipboardText'], isFalse);
    expect(home.containsKey('clipboardLastHandledText'), isFalse);

    settings.resetForTest();
    await settings.init();
    expect(settings.skipRepeatedClipboardText, isFalse);
    expect(
      settings.clipboardLastHandledText,
      'https://www.bilibili.com/video/BV1xx411c7mD',
    );
  });

  test('只记住最近一段文字，关闭开关后允许再识别一次', () {
    const first = 'https://www.bilibili.com/video/BV1xx411c7mD';
    const second = 'https://b23.tv/abc';

    expect(
      shouldSkipClipboardParse(
        content: '  $first\n',
        skipRepeated: true,
        persistedText: first,
        sessionText: null,
        sessionSkipRepeated: null,
      ),
      isTrue,
    );
    expect(
      shouldSkipClipboardParse(
        content: second,
        skipRepeated: true,
        persistedText: first,
        sessionText: null,
        sessionSkipRepeated: null,
      ),
      isFalse,
    );
    expect(
      shouldSkipClipboardParse(
        content: first,
        skipRepeated: false,
        persistedText: first,
        sessionText: null,
        sessionSkipRepeated: null,
      ),
      isFalse,
    );
    expect(
      shouldSkipClipboardParse(
        content: first,
        skipRepeated: false,
        persistedText: first,
        sessionText: first,
        sessionSkipRepeated: false,
      ),
      isTrue,
    );
    expect(
      shouldSkipClipboardParse(
        content: first,
        skipRepeated: false,
        persistedText: first,
        sessionText: first,
        sessionSkipRepeated: true,
      ),
      isFalse,
    );
  });

  testWidgets('媒体库设置弹窗可关闭相同剪贴板只识别一次', (tester) async {
    useTallSettingsSurface(tester);
    final settings = SettingsService();
    await settings.init();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () =>
                  showMediaLibrarySettingsBottomSheet(context, settings),
              child: const Text('打开设置'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开设置'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('skipRepeatedClipboardText')),
      200,
    );
    expect(find.text('相同剪贴板内容只识别一次'), findsOneWidget);
    expect(settings.skipRepeatedClipboardText, isTrue);

    await tester.tap(find.byKey(const ValueKey('skipRepeatedClipboardText')));
    await tester.pump();
    expect(settings.skipRepeatedClipboardText, isFalse);
  });
}
