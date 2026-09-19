import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/models/danmaku_model.dart';
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

  test('弹幕速度使用宽范围对数滑块并可无损往返', () {
    expect(kDanmakuSpeedMin, 0.05);
    expect(kDanmakuSpeedMax, 16);
    expect(danmakuSpeedToSlider(kDanmakuSpeedMin), 0);
    expect(danmakuSpeedToSlider(kDanmakuSpeedMax), 1);

    for (final speed in <double>[0.05, 0.1, 0.2, 0.5, 1, 2, 4, 8, 16]) {
      expect(
        danmakuSpeedFromSlider(danmakuSpeedToSlider(speed)),
        closeTo(speed, 0.000001),
      );
    }

    // 常用的慢速不再被挤在线性滑块最左侧的一小段。
    expect(danmakuSpeedToSlider(0.1), greaterThan(0.1));
    expect(danmakuSpeedToSlider(0.5), greaterThan(0.35));
    expect(danmakuSpeedToSlider(1), inInclusiveRange(0.5, 0.55));
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
    expect(settings.bilibiliDanmakuUseLockedSpeedAsBaseline, isFalse);
  });

  test('锁定倍速基准只在开关打开且确实锁定时缩放弹幕媒体速度', () {
    expect(
      resolveDanmakuSpeedWithLockedPlaybackBaseline(
        sliderSpeed: 1.2,
        useLockedPlaybackAsBaseline: false,
        isPlaybackSpeedLocked: true,
        lockedPlaybackSpeed: 2,
      ),
      1.2,
    );
    expect(
      resolveDanmakuSpeedWithLockedPlaybackBaseline(
        sliderSpeed: 1.2,
        useLockedPlaybackAsBaseline: true,
        isPlaybackSpeedLocked: false,
        lockedPlaybackSpeed: 2,
      ),
      1.2,
    );
    expect(
      resolveDanmakuSpeedWithLockedPlaybackBaseline(
        sliderSpeed: 1.2,
        useLockedPlaybackAsBaseline: true,
        isPlaybackSpeedLocked: true,
        lockedPlaybackSpeed: 2,
      ),
      closeTo(0.6, 0.000001),
    );
    expect(
      resolveDanmakuSpeedWithLockedPlaybackBaseline(
        sliderSpeed: 1,
        useLockedPlaybackAsBaseline: true,
        isPlaybackSpeedLocked: true,
        lockedPlaybackSpeed: 1.5,
      ),
      closeTo(1 / 1.5, 0.000001),
    );
    expect(
      resolveDanmakuSpeedWithLockedPlaybackBaseline(
        sliderSpeed: 1,
        useLockedPlaybackAsBaseline: true,
        isPlaybackSpeedLocked: true,
        lockedPlaybackSpeed: 0,
      ),
      1,
    );
    expect(
      resolveDanmakuSpeedWithLockedPlaybackBaseline(
        sliderSpeed: double.nan,
        useLockedPlaybackAsBaseline: true,
        isPlaybackSpeedLocked: true,
        lockedPlaybackSpeed: 2,
      ),
      1,
    );
  });

  test('以锁定倍速为基准时，2 倍速锁定后弹幕穿越时长回到 1 倍速观感', () {
    const item = DanmakuItem(
      index: 0,
      startTime: Duration.zero,
      duration: Duration(seconds: 8),
      text: '弹幕',
      type: DanmakuType.top,
      colorValue: 0xFFFFFFFF,
      sourceY: 40,
    );
    final atOneX = resolveDanmakuDurationUs(
      item,
      speed: 1,
      viewportWidth: 1920,
      referenceWidth: 1920,
    );
    final lockedTwoX = resolveDanmakuDurationUs(
      item,
      speed: resolveDanmakuSpeedWithLockedPlaybackBaseline(
        sliderSpeed: 1,
        useLockedPlaybackAsBaseline: true,
        isPlaybackSpeedLocked: true,
        lockedPlaybackSpeed: 2,
      ),
      viewportWidth: 1920,
      referenceWidth: 1920,
    );
    // Position clock at 2x consumes media time twice as fast, so doubling the
    // media-time duration restores the original wall-clock travel.
    expect(lockedTwoX, atOneX * 2);
  });

  test('锁定倍速基准勾选即时生效并永久保存，未锁定的残留倍速不会误补偿', () async {
    SharedPreferences.setMockInitialValues({});
    final settings = SettingsService();
    settings.resetForTest();
    await settings.init();

    expect(settings.bilibiliDanmakuUseLockedSpeedAsBaseline, isFalse);
    await settings.setPlaybackSpeedLock(2.0, false);
    expect(settings.effectiveBilibiliDanmakuSpeed, 1.0);

    var notifications = 0;
    settings.addListener(() => notifications++);
    final persistence = settings.saveBilibiliDanmakuUseLockedSpeedAsBaseline(
      true,
    );

    expect(settings.bilibiliDanmakuUseLockedSpeedAsBaseline, isTrue);
    expect(notifications, 1);
    // Unlocked leftover 2x must not change the overlay speed.
    expect(settings.effectiveBilibiliDanmakuSpeed, 1.0);
    await persistence;

    await settings.setPlaybackSpeedLock(2.0, true);
    expect(settings.effectiveBilibiliDanmakuSpeed, closeTo(0.5, 0.000001));

    await settings.saveBilibiliDanmakuUseLockedSpeedAsBaseline(true);
    expect(notifications, 2);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('bilibiliDanmakuUseLockedSpeedAsBaseline'), isTrue);

    settings.resetForTest();
    await settings.init();
    expect(settings.bilibiliDanmakuUseLockedSpeedAsBaseline, isTrue);
    expect(settings.isPlaybackSpeedLocked, isTrue);
    expect(settings.effectiveBilibiliDanmakuSpeed, closeTo(0.5, 0.000001));
  });
}
