import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/models/danmaku_style.dart';
import 'package:video_player_app/widgets/danmaku_overlay.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('弹幕默认不局限于视频区域，并可即时响应和持久化', () async {
    SharedPreferences.setMockInitialValues({});
    final settings = SettingsService();
    settings.resetForTest();
    await settings.init();

    expect(settings.bilibiliDanmakuOnlyInVideoArea, isFalse);

    var notifications = 0;
    settings.addListener(() => notifications++);
    final persistence = settings.saveBilibiliDanmakuOnlyInVideoArea(true);

    expect(settings.bilibiliDanmakuOnlyInVideoArea, isTrue);
    expect(notifications, 1);
    await persistence;

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('bilibiliDanmakuOnlyInVideoArea'), isTrue);

    settings.resetForTest();
    await settings.init();
    expect(settings.bilibiliDanmakuOnlyInVideoArea, isTrue);
  });

  test('弹幕字号只由播放器纵向高度和字号百分比决定', () {
    final fontSize = resolveDanmakuFontSize(playerHeight: 1080, fontScale: 0.8);
    expect(fontSize, 32);

    // 横向宽度、视频画面比例和侧栏宽度不属于字号计算参数。
    expect(
      resolveDanmakuFontSize(playerHeight: 1080, fontScale: 0.8),
      fontSize,
    );
    expect(
      resolveDanmakuFontSize(playerHeight: 720, fontScale: 0.8),
      closeTo(21.333333, 0.000001),
    );
  });

  test('弹幕显示区域、字号和速度支持扩展后的完整范围', () async {
    SharedPreferences.setMockInitialValues({});
    final settings = SettingsService();
    settings.resetForTest();
    await settings.init();

    await settings.saveBilibiliDanmakuDisplayArea(kDanmakuDisplayAreaMin);
    await settings.saveBilibiliDanmakuFontScale(kDanmakuFontScaleMax);
    await settings.saveBilibiliDanmakuSpeed(kDanmakuSpeedMax);

    expect(settings.bilibiliDanmakuDisplayArea, kDanmakuDisplayAreaMin);
    expect(settings.bilibiliDanmakuFontScale, kDanmakuFontScaleMax);
    expect(settings.bilibiliDanmakuSpeed, kDanmakuSpeedMax);
    expect(
      resolveDanmakuFontSize(
        playerHeight: 1080,
        fontScale: kDanmakuFontScaleMax,
      ),
      160,
    );

    await settings.saveBilibiliDanmakuFontScale(kDanmakuFontScaleMin);
    await settings.saveBilibiliDanmakuSpeed(kDanmakuSpeedMin);
    expect(settings.bilibiliDanmakuFontScale, kDanmakuFontScaleMin);
    expect(settings.bilibiliDanmakuSpeed, kDanmakuSpeedMin);
  });

  test('普通与高级弹幕设置全局持久化并可恢复历史默认外观', () async {
    SharedPreferences.setMockInitialValues({});
    final settings = SettingsService();
    settings.resetForTest();
    await settings.init();

    expect(settings.bilibiliDanmakuFontFamily, isNull);
    expect(settings.bilibiliDanmakuFontWeight, 600);
    expect(settings.bilibiliDanmakuOutlineType, DanmakuOutlineType.standard);

    await settings.saveBilibiliDanmakuOpacity(0.55);
    await settings.saveBilibiliDanmakuFontFamily('MiSans');
    await settings.saveBilibiliDanmakuFontWeight(800);
    await settings.saveBilibiliDanmakuOutlineType(
      DanmakuOutlineType.projection,
    );

    settings.resetForTest();
    await settings.init();
    expect(settings.bilibiliDanmakuOpacity, 0.55);
    expect(settings.bilibiliDanmakuFontFamily, 'MiSans');
    expect(settings.bilibiliDanmakuFontWeight, 800);
    expect(settings.bilibiliDanmakuOutlineType, DanmakuOutlineType.projection);

    await settings.resetBilibiliDanmakuSettings();
    expect(settings.bilibiliDanmakuOpacity, 0.8);
    expect(settings.bilibiliDanmakuFontFamily, isNull);
    expect(settings.bilibiliDanmakuFontWeight, 600);
    expect(settings.bilibiliDanmakuOutlineType, DanmakuOutlineType.standard);
  });
}
