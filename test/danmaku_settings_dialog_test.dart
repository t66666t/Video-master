import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/danmaku_style.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/widgets/danmaku_settings_dialog.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('高级弹幕设置只在按钮点击后打开并可即时更新', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final settings = SettingsService();
    settings.resetForTest();
    await settings.init();
    await tester.binding.setSurfaceSize(const Size(390, 650));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      ChangeNotifierProvider<SettingsService>.value(
        value: settings,
        child: MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDanmakuSettingsDialog(context),
              child: const Text('设置'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
    expect(find.text('弹幕高级设置'), findsNothing);
    expect(find.text('适中 · 1.0×'), findsOneWidget);

    await tester.tap(find.text('高级设置'));
    await tester.pumpAndSettle();
    expect(find.text('弹幕高级设置'), findsOneWidget);
    expect(find.text('当前默认字体'), findsOneWidget);
    expect(find.text('标准描边'), findsOneWidget);

    await tester.ensureVisible(find.text('45°投影'));
    await tester.tap(find.text('45°投影'));
    await tester.pump();
    expect(settings.bilibiliDanmakuOutlineType, DanmakuOutlineType.projection);
    expect(tester.takeException(), isNull);
  });
}
