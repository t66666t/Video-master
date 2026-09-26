import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/import_card_placement.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/widgets/media_library_settings_sheet.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    SettingsService().resetForTest();
  });

  test('导入卡片位置默认跟随当前文件夹，文件夹名会补齐默认值', () async {
    final settings = SettingsService();
    await settings.init();

    expect(settings.importCardPlacementMode, ImportCardPlacement.currentFolder);
    expect(
      settings.importSourceFolderName(ImportCardFeature.bilibiliOnline),
      'B站在线',
    );
    expect(settings.importSourceFolderName(ImportCardFeature.ytDlp), 'YT-DLP');

    await settings.updateSetting('importCardPlacement', 'sourceFolder');
    await settings.updateSetting(
      ImportSourceFolders.namesKey,
      '{"ytDlp":"  油管下载/ ","missing":"忽略"}',
    );

    settings.resetForTest();
    await settings.init();
    expect(settings.importCardPlacementMode, ImportCardPlacement.sourceFolder);
    expect(settings.importSourceFolderName(ImportCardFeature.ytDlp), '油管下载');
    expect(
      settings.importSourceFolderName(ImportCardFeature.bilibiliDownload),
      'B站下载',
    );
  });

  testWidgets('媒体库设置可以选择导入卡片位置', (tester) async {
    final settings = SettingsService();
    await settings.init();

    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

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

    expect(find.text('导入卡片放在哪'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('importSourceFolder-ytDlp')),
      findsNothing,
    );

    await tester.tap(
      find.byKey(const ValueKey('importCardPlacement-sourceFolder')),
    );
    await tester.pumpAndSettle();

    expect(settings.importCardPlacementMode, ImportCardPlacement.sourceFolder);
    expect(
      find.byKey(const ValueKey('importSourceFolder-ytDlp')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('importSourceFolder-bilibiliOnline')),
      findsOneWidget,
    );
  });
}
