import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/widgets/sleep_timer_dialog.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('sleep timer dialog adapts without vertical scrolling', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(() => debugDefaultTargetPlatformOverride = null);

    final settings = SettingsService();
    await settings.init();
    final playback = MediaPlaybackService();

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<SettingsService>.value(value: settings),
          ChangeNotifierProvider<MediaPlaybackService>.value(value: playback),
        ],
        child: MaterialApp(
          theme: ThemeData.dark(),
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: FilledButton(
                  onPressed: () => showSleepTimerDialog(context),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    for (final size in const [Size(320, 568), Size(568, 320)]) {
      tester.view.physicalSize = size;
      await tester.pump();
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('定时关闭'), findsOneWidget);
      expect(find.text('退出页面后自动暂停'), findsOneWidget);
      expect(find.text('离开软件后暂停播放'), findsOneWidget);
      expect(find.byType(ListView), findsNothing);
      expect(find.byType(SingleChildScrollView), findsNothing);
      expect(tester.takeException(), isNull, reason: 'mobile viewport: $size');
      await tester.tap(find.byTooltip('关闭'));
      await tester.pumpAndSettle();
    }

    debugDefaultTargetPlatformOverride = null;
    for (final size in const [
      Size(800, 600),
      Size(768, 1024),
      Size(1366, 768),
    ]) {
      tester.view.physicalSize = size;
      await tester.pump();
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('倒计时'), findsOneWidget);
      expect(find.text('播放完成后'), findsOneWidget);
      expect(find.text('播放行为'), findsOneWidget);
      expect(find.byType(ListView), findsNothing);
      expect(find.byType(SingleChildScrollView), findsNothing);
      expect(tester.takeException(), isNull, reason: 'large viewport: $size');
      await tester.tap(find.byTooltip('关闭'));
      await tester.pumpAndSettle();
    }
  });
}
