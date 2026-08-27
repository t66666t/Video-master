import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/features/youtube_download/platform/yt_dlp_native_bridge.dart';
import 'package:video_player_app/features/youtube_download/services/yt_dlp_binary_installer.dart';
import 'package:video_player_app/features/youtube_download/services/yt_dlp_binary_location_store.dart';
import 'package:video_player_app/features/youtube_download/services/yt_dlp_binary_updater.dart';
import 'package:video_player_app/features/youtube_download/services/yt_dlp_platform_asset.dart';
import 'package:video_player_app/features/youtube_download/services/yt_dlp_runtime_abi.dart';
import 'package:video_player_app/features/youtube_download/services/yt_dlp_version.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('native task removal handlers never unlink produced media', () {
    final windowsSource = File(
      p.join(Directory.current.path, 'windows', 'runner', 'flutter_window.cpp'),
    ).readAsStringSync();
    final windowsRemove = windowsSource.substring(
      windowsSource.indexOf('bool FlutterWindow::RemoveYtDlpTask'),
      windowsSource.indexOf(
        'std::unique_ptr<flutter::EncodableValue>',
        windowsSource.indexOf('bool FlutterWindow::RemoveYtDlpTask'),
      ),
    );
    expect(windowsRemove, isNot(contains('filesystem::remove')));

    final macSource = File(
      p.join(Directory.current.path, 'macos', 'Runner', 'AppDelegate.swift'),
    ).readAsStringSync();
    final macRemove = macSource.substring(
      macSource.indexOf('private func removeYoutubeTask'),
      macSource.indexOf(
        'private func getYoutubeTaskStatus',
        macSource.indexOf('private func removeYoutubeTask'),
      ),
    );
    expect(macRemove, isNot(contains('removeItem')));
  });

  group('Windows yt-dlp runtime', () {
    test(
      'managed directory is next to the application executable',
      () async {
        final directory = await YtDlpBinaryInstaller.resolveInstallDirectory();
        final expected = p.join(
          File(Platform.resolvedExecutable).parent.path,
          'yt_dlp',
        );

        expect(p.equals(directory.path, expected), isTrue);
      },
      skip: !Platform.isWindows,
    );

    test(
      'bundled version metadata matches the Windows executable',
      () async {
        final binary = File(
          p.join(
            Directory.current.path,
            'assets',
            'binaries',
            'windows',
            'yt-dlp.exe',
          ),
        );
        expect(await binary.exists(), isTrue);

        final result = await Process.run(binary.path, const ['--version']);
        expect(result.exitCode, 0);
        expect(
          result.stdout.toString().trim(),
          YtDlpBinaryInstaller.bundledYtDlpVersion,
        );
      },
      skip: !Platform.isWindows,
    );

    test('native bridge sends the managed binary paths', () async {
      const channel = MethodChannel('com.example.video_player_app/yt_dlp');
      MethodCall? capturedCall;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            capturedCall = call;
            return true;
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });

      final configured = await YtDlpNativeBridge().configureBinaryPaths(
        ytDlpPath: r'D:\Fluent Player\yt_dlp\yt-dlp.exe',
        ffmpegPath: r'D:\Fluent Player\yt_dlp\ffmpeg.exe',
      );

      expect(configured, isTrue);
      expect(
        capturedCall,
        isMethodCall(
          YtDlpNativeBridge.configureBinaryPathsMethod,
          arguments: {
            'ytDlpPath': r'D:\Fluent Player\yt_dlp\yt-dlp.exe',
            'ffmpegPath': r'D:\Fluent Player\yt_dlp\ffmpeg.exe',
          },
        ),
      );
    });

    test('Android runtime reload sends the verified archive path', () async {
      const channel = MethodChannel('com.example.video_player_app/yt_dlp');
      MethodCall? capturedCall;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            capturedCall = call;
            return '2026.08.19';
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });

      final version = await YtDlpNativeBridge().reloadAndroidRuntime(
        '/data/user/0/example/files/yt_dlp/yt-dlp',
      );

      expect(version, '2026.08.19');
      expect(
        capturedCall,
        isMethodCall(
          YtDlpNativeBridge.reloadAndroidRuntimeMethod,
          arguments: {
            'archivePath': '/data/user/0/example/files/yt_dlp/yt-dlp',
          },
        ),
      );
    });
  });

  group('official release asset mapping', () {
    test('Windows maps x64, ARM64 and x86 independently', () {
      expect(
        YtDlpPlatformAsset.forTarget(
          operatingSystem: YtDlpDesktopOs.windows,
          architecture: YtDlpRuntimeArch.x64,
        )?.releaseAssetName,
        'yt-dlp.exe',
      );
      expect(
        YtDlpPlatformAsset.forTarget(
          operatingSystem: YtDlpDesktopOs.windows,
          architecture: YtDlpRuntimeArch.arm64,
        )?.releaseAssetName,
        'yt-dlp_arm64.exe',
      );
      expect(
        YtDlpPlatformAsset.forTarget(
          operatingSystem: YtDlpDesktopOs.windows,
          architecture: YtDlpRuntimeArch.x86,
        )?.releaseAssetName,
        'yt-dlp_x86.exe',
      );
    });

    test('macOS uses the official universal executable', () {
      for (final arch in [YtDlpRuntimeArch.x64, YtDlpRuntimeArch.arm64]) {
        expect(
          YtDlpPlatformAsset.forTarget(
            operatingSystem: YtDlpDesktopOs.macos,
            architecture: arch,
          )?.releaseAssetName,
          'yt-dlp_macos',
        );
      }
    });

    test('Linux maps libc and architecture', () {
      expect(
        YtDlpPlatformAsset.forTarget(
          operatingSystem: YtDlpDesktopOs.linux,
          architecture: YtDlpRuntimeArch.x64,
        )?.releaseAssetName,
        'yt-dlp_linux',
      );
      expect(
        YtDlpPlatformAsset.forTarget(
          operatingSystem: YtDlpDesktopOs.linux,
          architecture: YtDlpRuntimeArch.arm64,
          linuxLibc: YtDlpLinuxLibc.musl,
        )?.releaseAssetName,
        'yt-dlp_musllinux_aarch64',
      );
    });
  });

  group('desktop binary location settings', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('managed source is selected by default', () async {
      final settings = await YtDlpBinaryLocationStore.load();
      expect(settings.source, YtDlpBinarySource.managed);
      expect(settings.managedDirectory, isNotEmpty);
      expect(settings.customBinaryPath, isEmpty);
    });

    test(
      'custom file and managed directory are persisted independently',
      () async {
        const settings = YtDlpBinaryLocationSettings(
          source: YtDlpBinarySource.custom,
          managedDirectory: r'D:\Managed yt-dlp',
          customBinaryPath: r'D:\Tools\yt-dlp.exe',
        );
        await YtDlpBinaryLocationStore.save(settings);

        final restored = await YtDlpBinaryLocationStore.load();
        expect(restored.source, YtDlpBinarySource.custom);
        expect(
          restored.managedDirectory,
          p.normalize(settings.managedDirectory),
        );
        expect(
          restored.customBinaryPath,
          p.normalize(settings.customBinaryPath),
        );
      },
    );
  });

  group('yt-dlp version comparison', () {
    test('newer stable release compares greater', () {
      expect(
        YtDlpBinaryUpdater.compareVersions('2026.07.04', '2026.03.17'),
        greaterThan(0),
      );
    });

    test('newer nightly is not treated as older than stable', () {
      expect(
        YtDlpBinaryUpdater.compareVersions('2026.07.04', '2026.08.19.123456'),
        lessThan(0),
      );
    });

    test('zero-padded and normalized stable versions compare equal', () {
      expect(YtDlpBinaryUpdater.compareVersions('2026.08.19', '2026.8.19'), 0);
    });

    test('new bundle replaces an older managed official release only', () {
      expect(
        YtDlpVersions.shouldReplaceInstalledStable(
          installedVersionStamp: '2026.03.17',
          bundledVersionStamp: 'yt-dlp-2026.08.19',
        ),
        isTrue,
      );
      expect(
        YtDlpVersions.shouldReplaceInstalledStable(
          installedVersionStamp: '2026.09.01',
          bundledVersionStamp: 'yt-dlp-2026.08.19',
        ),
        isFalse,
      );
    });

    test('Android status label keeps the release date visible', () {
      expect(
        YtDlpVersions.latestStableLabel(
          YtDlpVersions.androidBundled,
          supportsOnlineUpdate: false,
        ),
        '2026.08.19（当前平台不支持在线更新）',
      );
    });

    test('Android build pins the same embedded yt-dlp release', () async {
      final gradleFile = File(
        p.join(Directory.current.path, 'android', 'app', 'build.gradle.kts'),
      );
      final normalizedPipVersion = YtDlpVersions.androidBundled
          .split('.')
          .map(int.parse)
          .join('.');

      expect(await gradleFile.exists(), isTrue);
      expect(
        await gradleFile.readAsString(),
        contains('install("yt-dlp==$normalizedPipVersion")'),
      );
    });
  });
}
