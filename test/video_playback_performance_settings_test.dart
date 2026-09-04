import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/platform/windows_video_player_media_kit.dart';
import 'package:video_player_app/platform/local_playback_backend_policy.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart'
    show DataSourceType;

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

  test('Android defers UI video output only while truly backgrounded', () {
    for (final state in <AppLifecycleState>[
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
      AppLifecycleState.detached,
    ]) {
      expect(
        NativeVideoPlayerMediaKit.shouldDeferVideoOutputInitialization(
          operatingSystem: 'android',
          lifecycleState: state,
        ),
        isTrue,
      );
    }
    for (final state in <AppLifecycleState?>[
      null,
      AppLifecycleState.resumed,
      AppLifecycleState.inactive,
    ]) {
      expect(
        NativeVideoPlayerMediaKit.shouldDeferVideoOutputInitialization(
          operatingSystem: 'android',
          lifecycleState: state,
        ),
        isFalse,
      );
    }
    expect(
      NativeVideoPlayerMediaKit.shouldDeferVideoOutputInitialization(
        operatingSystem: 'windows',
        lifecycleState: AppLifecycleState.paused,
      ),
      isFalse,
    );
  });

  test('pure audio never creates a video output or first-frame observer', () {
    for (final resource in <String>[
      r'D:\Music\Diamonds.m4a',
      r'D:\Music\Lossless.ALAC',
      'https://example.test/audio/track.flac?token=1',
    ]) {
      expect(
        NativeVideoPlayerMediaKit.shouldCreateVideoOutput(
          resource: resource,
          operatingSystem: 'android',
          lifecycleState: AppLifecycleState.resumed,
        ),
        isFalse,
      );
    }
    expect(
      NativeVideoPlayerMediaKit.shouldCreateVideoOutput(
        resource: r'D:\Video\movie.mp4',
        operatingSystem: 'android',
        lifecycleState: AppLifecycleState.resumed,
      ),
      isTrue,
    );
    expect(
      NativeVideoPlayerMediaKit.shouldCreateVideoOutput(
        resource: r'D:\Video\movie.mp4',
        operatingSystem: 'android',
        lifecycleState: AppLifecycleState.paused,
      ),
      isTrue,
    );
    expect(
      NativeVideoPlayerMediaKit.shouldCreateVideoOutput(
        resource: 'https://example.test/video/movie.mp4',
        operatingSystem: 'android',
        lifecycleState: AppLifecycleState.paused,
      ),
      isFalse,
    );
  });

  test('Android local files retain the stable platform player backend', () {
    LocalPlaybackBackendPolicy.clearForTesting();
    expect(
      NativeVideoPlayerMediaKit.shouldUsePlatformPlayer(
        sourceType: DataSourceType.file,
        operatingSystem: 'android',
        resource: '/storage/emulated/0/Movies/movie.mp4',
      ),
      isTrue,
    );
    expect(
      NativeVideoPlayerMediaKit.shouldUsePlatformPlayer(
        sourceType: DataSourceType.network,
        operatingSystem: 'android',
        resource: 'https://example.test/movie.mp4',
      ),
      isFalse,
    );
    expect(
      NativeVideoPlayerMediaKit.shouldUsePlatformPlayer(
        sourceType: DataSourceType.file,
        operatingSystem: 'windows',
        resource: r'D:\Movies\movie.mp4',
      ),
      isFalse,
    );

    final adapterSource = File(
      'lib/platform/windows_video_player_media_kit.dart',
    ).readAsStringSync();
    expect(
      adapterSource,
      contains('if (_delegatedTextureIds.containsKey(textureId)) return true;'),
      reason: 'a delegated local controller must remain directly mountable',
    );
  });

  test('Android routes only wide-codec local audio through media_kit', () {
    LocalPlaybackBackendPolicy.clearForTesting();
    const alacInM4a = '/storage/emulated/0/Music/lossless.m4a';
    const ordinaryAac = '/storage/emulated/0/Music/ordinary.m4a';

    LocalPlaybackBackendPolicy.preferWideCodecBackend(alacInM4a);

    expect(
      NativeVideoPlayerMediaKit.shouldUsePlatformPlayer(
        sourceType: DataSourceType.file,
        operatingSystem: 'android',
        resource: alacInM4a,
      ),
      isFalse,
    );
    expect(
      NativeVideoPlayerMediaKit.shouldUsePlatformPlayer(
        sourceType: DataSourceType.file,
        operatingSystem: 'android',
        resource: ordinaryAac,
      ),
      isTrue,
    );
    expect(
      NativeVideoPlayerMediaKit.shouldUsePlatformPlayer(
        sourceType: DataSourceType.file,
        operatingSystem: 'android',
        resource: '/storage/emulated/0/Music/album.ape',
      ),
      isFalse,
    );

    const deviceSpecificFailure =
        '/storage/emulated/0/Music/device-specific.aac';
    LocalPlaybackBackendPolicy.preferWideCodecBackend(deviceSpecificFailure);
    LocalPlaybackBackendPolicy.preferPlatformBackend(deviceSpecificFailure);
    expect(
      NativeVideoPlayerMediaKit.shouldUsePlatformPlayer(
        sourceType: DataSourceType.file,
        operatingSystem: 'android',
        resource: deviceSpecificFailure,
      ),
      isFalse,
      reason: 'a runtime decoder failure must not be cleared by codec probing',
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

  test(
    'native completion ignores album-art and pause pulses away from end',
    () {
      const duration = Duration(minutes: 4);

      expect(
        NativeVideoPlayerMediaKit.shouldForwardPlaybackCompletion(
          completed: true,
          position: const Duration(seconds: 42),
          duration: duration,
        ),
        isFalse,
      );
      expect(
        NativeVideoPlayerMediaKit.shouldForwardPlaybackCompletion(
          completed: true,
          position: Duration.zero,
          duration: duration,
        ),
        isFalse,
      );
      expect(
        NativeVideoPlayerMediaKit.shouldForwardPlaybackCompletion(
          completed: true,
          position: const Duration(minutes: 3, seconds: 59, milliseconds: 400),
          duration: duration,
        ),
        isTrue,
      );
      expect(
        NativeVideoPlayerMediaKit.shouldForwardPlaybackCompletion(
          completed: false,
          position: duration,
          duration: duration,
        ),
        isFalse,
      );
    },
  );

  test('known audio containers disable attached-picture video output', () {
    expect(
      NativeVideoPlayerMediaKit.isKnownAudioOnlyResource(
        r'D:\Music\Album\track.M4A',
      ),
      isTrue,
    );
    expect(
      NativeVideoPlayerMediaKit.isKnownAudioOnlyResource(
        'https://example.test/audio/song.flac?token=1',
      ),
      isTrue,
    );
    expect(
      NativeVideoPlayerMediaKit.isKnownAudioOnlyResource(
        'https://example.test/video/movie.mp4?token=1',
      ),
      isFalse,
    );
  });

  test('split-stream playback selects a concrete primary video track', () {
    const primary = VideoTrack(
      '1',
      '1080p',
      'und',
      codec: 'h264',
      w: 1920,
      h: 1080,
    );
    const artwork = VideoTrack('2', 'cover', 'und', image: true);

    expect(
      NativeVideoPlayerMediaKit.firstUsableVideoTrack(
        const Tracks(video: [VideoTrack('auto', null, null), primary, artwork]),
      ),
      same(primary),
    );
    expect(
      NativeVideoPlayerMediaKit.firstUsableVideoTrack(const Tracks()),
      isNull,
    );
  });

  test('recoverable decoder logs do not invalidate an active controller', () {
    expect(
      NativeVideoPlayerMediaKit.shouldForwardPlayerError(
        controllerInitialized: false,
        duration: Duration.zero,
        hasUsableMediaTrack: false,
      ),
      isTrue,
    );
    expect(
      NativeVideoPlayerMediaKit.shouldForwardPlayerError(
        controllerInitialized: true,
        duration: const Duration(minutes: 4),
        hasUsableMediaTrack: true,
      ),
      isFalse,
    );
    expect(
      NativeVideoPlayerMediaKit.shouldForwardPlayerError(
        controllerInitialized: true,
        duration: Duration.zero,
        hasUsableMediaTrack: false,
      ),
      isTrue,
    );
  });
}
