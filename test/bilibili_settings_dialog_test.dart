import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/screens/bilibili_download_screen.dart';
import 'package:video_player_app/services/bilibili/bilibili_download_service.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/utils/app_toast.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<({BilibiliDownloadService service, SettingsService settings})>
  pumpDownloadScreen(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await tester.binding.setSurfaceSize(const Size(1200, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final settings = SettingsService()..resetForTest();
    await settings.init();
    final service = BilibiliDownloadService();
    addTearDown(service.dispose);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: service),
          ChangeNotifierProvider.value(value: settings),
          ChangeNotifierProvider.value(value: LibraryService()),
        ],
        child: MaterialApp(
          navigatorKey: AppToast.navigatorKey,
          home: const BilibiliDownloadScreen(),
        ),
      ),
    );
    await tester.pump();
    return (service: service, settings: settings);
  }

  testWidgets('cancelling download settings discards the danmaku draft', (
    tester,
  ) async {
    final host = await pumpDownloadScreen(tester);
    expect(host.service.downloadDanmaku, isTrue);

    await tester.tap(find.byTooltip('下载设置'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('下载弹幕'));
    await tester.pump();

    expect(host.service.downloadDanmaku, isTrue);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(host.service.downloadDanmaku, isTrue);
  });

  testWidgets('using the default directory clears the custom-path override', (
    tester,
  ) async {
    final host = await pumpDownloadScreen(tester);
    host.service.customDownloadPath = r'D:\custom-downloads';

    await tester.tap(find.byTooltip('下载设置'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('使用默认'));
    await tester.pump();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();

    expect(host.service.customDownloadPath, isNull);
    final preferences = await SharedPreferences.getInstance();
    expect(preferences.containsKey('bilibili_custom_download_path'), isFalse);
  });
}
