import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/utils/stable_system_ui_insets.dart';

MediaQueryData _metrics({
  double paddingTop = 0,
  double paddingBottom = 0,
  double? viewPaddingTop,
  double? viewPaddingBottom,
}) {
  return MediaQueryData(
    size: const Size(400, 800),
    padding: EdgeInsets.only(top: paddingTop, bottom: paddingBottom),
    viewPadding: EdgeInsets.only(
      top: viewPaddingTop ?? paddingTop,
      bottom: viewPaddingBottom ?? paddingBottom,
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('竖屏稳定状态直接采用实时安全区', () {
    final controller = StableSystemUiInsetController();
    final insets = controller.observe(
      _metrics(paddingTop: 40, paddingBottom: 48),
    );

    expect(insets.top, 40);
    expect(insets.bottom, 48);
    controller.dispose();
  });

  test('沉浸式横屏期间与系统栏回场动画中途都保持预留值', () {
    final controller = StableSystemUiInsetController();
    controller.observe(_metrics(paddingTop: 40, paddingBottom: 48));

    // 进入沉浸式：系统栏隐藏，实时安全区归零。
    expect(controller.observe(_metrics()).bottom, 48);
    expect(controller.observe(_metrics()).top, 40);

    // 回场动画中途的平台上报值同样是瞬态，不能驱动布局。
    expect(
      controller.observe(_metrics(paddingTop: 12, paddingBottom: 16)).bottom,
      48,
    );
    expect(
      controller.observe(_metrics(paddingTop: 28, paddingBottom: 40)).top,
      40,
    );

    // 动画结束，与预留一致。
    final settled = controller.observe(
      _metrics(paddingTop: 40, paddingBottom: 48),
    );
    expect(settled.top, 40);
    expect(settled.bottom, 48);
    controller.dispose();
  });

  test('安全区变大时立即采用，不需要等待', () {
    final controller = StableSystemUiInsetController();
    controller.observe(_metrics(paddingTop: 40, paddingBottom: 48));

    final grown = controller.observe(
      _metrics(paddingTop: 40, paddingBottom: 72),
    );
    expect(grown.bottom, 72);
    controller.dispose();
  });

  test('键盘弹出时按 viewPadding 保留系统栏占位', () {
    final controller = StableSystemUiInsetController();
    controller.observe(_metrics(paddingTop: 40, paddingBottom: 48));

    // 键盘弹出：padding.bottom 被清零，但 viewPadding.bottom 仍是触控条高度。
    final withKeyboard = controller.observe(
      _metrics(
        paddingTop: 40,
        paddingBottom: 0,
        viewPaddingBottom: 48,
      ),
    );
    expect(withKeyboard.bottom, 48);
    controller.dispose();
  });

  testWidgets('安全区变小需要等实时值稳定后才收窄', (tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    int notifications = 0;
    final controller = StableSystemUiInsetController(
      onChanged: () => notifications++,
    );
    controller.observe(_metrics(paddingTop: 40, paddingBottom: 72));

    // 例如从三键导航切到手势导航：安全区变小，先保持原值。
    expect(controller.observe(_metrics(paddingTop: 40, paddingBottom: 48)).bottom, 72);
    await tester.pump(const Duration(milliseconds: 300));
    expect(controller.reservedBottom, 72);

    // 稳定超过等待时长后才收窄，并通知页面重建。
    await tester.pump(StableSystemUiInsetController.shrinkSettleDelay);
    expect(controller.reservedBottom, 48);
    expect(notifications, 1);
    controller.dispose();
  });

  testWidgets('实时值在稳定期内回升则取消收窄', (tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    int notifications = 0;
    final controller = StableSystemUiInsetController(
      onChanged: () => notifications++,
    );
    controller.observe(_metrics(paddingTop: 40, paddingBottom: 72));

    controller.observe(_metrics(paddingTop: 40, paddingBottom: 24));
    await tester.pump(const Duration(milliseconds: 200));
    // 系统栏动画回到与预留一致的值：取消待执行的收窄。
    controller.observe(_metrics(paddingTop: 40, paddingBottom: 72));
    await tester.pump(StableSystemUiInsetController.shrinkSettleDelay * 2);

    expect(controller.reservedBottom, 72);
    expect(notifications, 0);
    controller.dispose();
  });
}
