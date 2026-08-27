import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/platform/windows_video_player_media_kit.dart';
import 'package:video_player_app/services/settings_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('hardware video decoding is the persisted default', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final settings = SettingsService()..resetForTest();
    await settings.init();

    expect(settings.useHardwareVideoDecoding, isTrue);
    await settings.saveUseHardwareVideoDecoding(false);
    expect(settings.useHardwareVideoDecoding, isFalse);

    settings.resetForTest();
    await settings.init();
    expect(settings.useHardwareVideoDecoding, isFalse);
  });

  test('native decoder options distinguish hardware and software paths', () {
    expect(
      NativeVideoPlayerMediaKit.decoderOptionFor(
        useHardwareDecoding: true,
        operatingSystem: 'android',
      ),
      'auto-safe',
    );
    for (final operatingSystem in <String>[
      'ios',
      'macos',
      'windows',
      'linux',
    ]) {
      expect(
        NativeVideoPlayerMediaKit.decoderOptionFor(
          useHardwareDecoding: true,
          operatingSystem: operatingSystem,
        ),
        'auto',
      );
      expect(
        NativeVideoPlayerMediaKit.decoderOptionFor(
          useHardwareDecoding: false,
          operatingSystem: operatingSystem,
        ),
        'no',
      );
    }
  });

  test('Android retries software only once before the first frame', () {
    expect(
      NativeVideoPlayerMediaKit.shouldRetryAndroidSoftwareDecoding(
        useHardwareDecoding: true,
        operatingSystem: 'android',
        firstFrameRendered: false,
        fallbackAttempted: false,
      ),
      isTrue,
    );
    expect(
      NativeVideoPlayerMediaKit.shouldRetryAndroidSoftwareDecoding(
        useHardwareDecoding: true,
        operatingSystem: 'android',
        firstFrameRendered: false,
        fallbackAttempted: true,
      ),
      isFalse,
    );
    expect(
      NativeVideoPlayerMediaKit.shouldRetryAndroidSoftwareDecoding(
        useHardwareDecoding: true,
        operatingSystem: 'android',
        firstFrameRendered: true,
        fallbackAttempted: false,
      ),
      isFalse,
    );
    expect(
      NativeVideoPlayerMediaKit.shouldRetryAndroidSoftwareDecoding(
        useHardwareDecoding: true,
        operatingSystem: 'windows',
        firstFrameRendered: false,
        fallbackAttempted: false,
      ),
      isFalse,
    );
  });

  test(
    '4K texture is capped to physical view without changing aspect ratio',
    () {
      expect(
        NativeVideoPlayerMediaKit.adaptiveTextureSize(
          source: const Size(3840, 2160),
          physicalViewport: const Size(1920, 1080),
        ),
        const Size(1920, 1080),
      );
      expect(
        NativeVideoPlayerMediaKit.adaptiveTextureSize(
          source: const Size(3840, 2160),
          physicalViewport: const Size(3120, 2080),
        ),
        const Size(3120, 1754),
      );
      expect(
        NativeVideoPlayerMediaKit.adaptiveTextureSize(
          source: const Size(1280, 720),
          physicalViewport: const Size(3120, 2080),
        ),
        const Size(1280, 720),
      );
    },
  );
}
