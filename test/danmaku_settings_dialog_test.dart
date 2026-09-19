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

  testWidgets('锁定倍速基准勾选项即时切换且不撑出小屏弹幕设置页', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final settings = SettingsService();
    settings.resetForTest();
    await settings.init();
    await tester.binding.setSurfaceSize(const Size(360, 560));
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
    expect(find.text('以锁定倍速为弹幕速度基准'), findsOneWidget);
    expect(settings.bilibiliDanmakuUseLockedSpeedAsBaseline, isFalse);

    await tester.tap(find.text('以锁定倍速为弹幕速度基准'));
    await tester.pump();
    expect(settings.bilibiliDanmakuUseLockedSpeedAsBaseline, isTrue);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('以锁定倍速为弹幕速度基准'));
    await tester.pump();
    expect(settings.bilibiliDanmakuUseLockedSpeedAsBaseline, isFalse);
    expect(tester.takeException(), isNull);
    expect(
      find.byKey(const ValueKey('danmaku-locked-speed-baseline-checkbox')),
      findsOneWidget,
    );
  });

  testWidgets('手机横屏弹幕设置一屏展示全部控件且无需滚动', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final settings = SettingsService();
    settings.resetForTest();
    await settings.init();
    // Logical landscape phone size; setSurfaceSize does not always update MediaQuery.
    tester.view.physicalSize = const Size(800, 360);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

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

    const screen = Size(800, 360);
    final labels = <String>[
      '弹幕仅在视频区域内展示',
      '显示区域',
      '不透明度',
      '弹幕字号',
      '弹幕速度',
      '以锁定倍速为弹幕速度基准',
      '更新弹幕',
      '立即更新',
    ];
    for (final label in labels) {
      expect(find.text(label), findsOneWidget);
      final rect = tester.getRect(find.text(label));
      expect(
        rect.top >= -0.5 && rect.bottom <= screen.height + 0.5,
        isTrue,
        reason: '$label should stay fully on the landscape viewport',
      );
    }

    final scrollable = tester.state<ScrollableState>(
      find.descendant(
        of: find.byKey(const ValueKey('danmaku-settings-scroll')),
        matching: find.byType(Scrollable),
      ),
    );
    expect(scrollable.position.maxScrollExtent, 0);
    expect(tester.takeException(), isNull);
  });
}
