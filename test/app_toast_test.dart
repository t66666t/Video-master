import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/utils/app_toast.dart';

void main() {
  Future<void> pumpToastHost(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: AppToast.navigatorKey,
        home: const Scaffold(body: SizedBox.expand()),
      ),
    );
    await tester.pump();
  }

  testWidgets('loading toast has a hard auto-dismiss timeout', (tester) async {
    addTearDown(() => AppToast.dismiss(immediate: true));
    await pumpToastHost(tester);

    AppToast.showLoading('正在处理媒体文件...');
    await tester.pump();
    expect(find.text('正在处理媒体文件...'), findsOneWidget);

    await tester.pump(const Duration(seconds: 8));
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('正在处理媒体文件...'), findsNothing);
  });

  testWidgets('loading handle only dismisses its own presentation', (
    tester,
  ) async {
    addTearDown(() => AppToast.dismiss(immediate: true));
    await pumpToastHost(tester);

    final loading = AppToast.showLoading('旧加载提示');
    await tester.pump();
    AppToast.show('新的完成提示', duration: const Duration(seconds: 10));
    await tester.pump();

    await loading.dismiss(immediate: true);
    await tester.pump();

    expect(find.text('旧加载提示'), findsNothing);
    expect(find.text('新的完成提示'), findsOneWidget);

    await AppToast.dismiss(immediate: true);
    await tester.pump();
  });

  testWidgets('loading handle immediately removes the current toast', (
    tester,
  ) async {
    addTearDown(() => AppToast.dismiss(immediate: true));
    await pumpToastHost(tester);

    final loading = AppToast.showLoading('处理中');
    await tester.pump();
    expect(find.text('处理中'), findsOneWidget);

    await loading.dismiss(immediate: true);
    await tester.pump();

    expect(find.text('处理中'), findsNothing);
  });

  testWidgets('any upward swipe fades out and removes the toast', (
    tester,
  ) async {
    addTearDown(() => AppToast.dismiss(immediate: true));
    await pumpToastHost(tester);

    AppToast.show('翻译完成', duration: const Duration(seconds: 10));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 220));
    expect(find.text('翻译完成'), findsOneWidget);

    // This is shorter than the old 36 px dismissal threshold. Once Flutter
    // recognizes it as an upward drag, no app-level distance threshold applies.
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('翻译完成')),
    );
    await gesture.moveBy(const Offset(0, -24));
    await gesture.up();

    // It remains mounted while the reverse animation is fading it out.
    expect(find.text('翻译完成'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 160));

    expect(find.text('翻译完成'), findsNothing);
  });
}
