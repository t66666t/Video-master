import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/widgets/media_library_settings_sheet.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    SettingsService().resetForTest();
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
    expect(find.text('导入时复制媒体到应用私有目录'), findsOneWidget);

    await tester.tap(find.byType(Switch));
    await tester.pump();
    expect(settings.copyImportedMediaToPrivateStorage, isTrue);
  });
}
