import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show ByteData, rootBundle;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class YtDlpBinaryInstaller {
  static const String _ytDlpVersion = '2026.06.09';
  static const String _windowsFfmpegVersion = 'windows-runner-bundled';
  static const String _macosFfmpegVersion = 'macos-bundled-20260511';
  static const String bundledSource = 'bundled';
  static const String officialReleaseSource = 'official-release';

  static const List<_BinaryAssetSpec> _windowsAssets = [
    _BinaryAssetSpec(
      assetPath: 'assets/binaries/windows/yt-dlp.exe',
      outputFileName: 'yt-dlp.exe',
      executable: false,
      versionStamp: 'yt-dlp-$_ytDlpVersion',
    ),
    _BinaryAssetSpec(
      assetPath: 'assets/binaries/windows/ffmpeg.exe',
      outputFileName: 'ffmpeg.exe',
      executable: false,
      versionStamp: 'ffmpeg-$_windowsFfmpegVersion',
    ),
    _BinaryAssetSpec(
      assetPath: 'assets/binaries/windows/ffprobe.exe',
      outputFileName: 'ffprobe.exe',
      executable: false,
      versionStamp: 'ffprobe-$_windowsFfmpegVersion',
    ),
  ];

  static Future<void> ensureInstalled() async {
    if (kIsWeb) return;

    final specs = await _currentPlatformSpecs();
    if (specs.isEmpty) {
      return;
    }

    final installDir = await _resolveInstallDirectory();
    await installDir.create(recursive: true);

    for (final spec in specs) {
      await _installAsset(spec: spec, installDir: installDir);
    }
  }

  static String get bundledYtDlpVersion => _ytDlpVersion;

  static Future<List<_BinaryAssetSpec>> _currentPlatformSpecs() async {
    if (Platform.isWindows) {
      return _windowsAssets;
    }
    if (Platform.isMacOS) {
      final archFolder = await _resolveMacosArchFolder();
      final assetPrefix = 'assets/binaries/macos/$archFolder';
      return [
        _BinaryAssetSpec(
          assetPath: '$assetPrefix/yt-dlp',
          outputFileName: 'yt-dlp',
          executable: true,
          versionStamp: 'yt-dlp-$_ytDlpVersion-$archFolder',
          fallbackAssetPaths: const ['assets/binaries/macos/yt-dlp'],
        ),
        _BinaryAssetSpec(
          assetPath: '$assetPrefix/ffmpeg',
          outputFileName: 'ffmpeg',
          executable: true,
          versionStamp: 'ffmpeg-$_macosFfmpegVersion-$archFolder',
        ),
      ];
    }
    // yt-dlp 官方发布页目前没有可直接用于 Android App 的独立官方可执行文件。
    return const [];
  }

  static Future<Directory> _resolveInstallDirectory() async {
    final supportDir = await getApplicationSupportDirectory();
    return Directory(p.join(supportDir.path, 'yt_dlp'));
  }

  static Future<String?> resolveInstalledBinaryPath(String fileName) async {
    final installDir = await _resolveInstallDirectory();
    final targetFile = File(p.join(installDir.path, fileName));
    if (await targetFile.exists()) {
      return targetFile.path;
    }
    return null;
  }

  static Future<Directory> resolveInstallDirectory() async {
    return _resolveInstallDirectory();
  }

  static Future<void> markBinaryAsManaged({
    required String fileName,
    required String versionStamp,
    required String source,
  }) async {
    final installDir = await _resolveInstallDirectory();
    await installDir.create(recursive: true);
    final basePath = p.join(installDir.path, fileName);
    await File('$basePath.version').writeAsString(versionStamp, flush: true);
    await File('$basePath.source').writeAsString(source, flush: true);
  }

  static Future<void> ensureExecutable(File file) async {
    await _ensureExecutable(file);
  }

  static Future<void> _installAsset({
    required _BinaryAssetSpec spec,
    required Directory installDir,
  }) async {
    final targetFile = File(p.join(installDir.path, spec.outputFileName));
    final markerFile = File(
      '${p.join(installDir.path, spec.outputFileName)}.version',
    );
    final sourceFile = File(
      '${p.join(installDir.path, spec.outputFileName)}.source',
    );
    final data = await _tryLoadAsset(spec.assetPath, spec.fallbackAssetPaths);
    if (data == null) {
      return;
    }

    final source = await _tryReadText(sourceFile);
    if (await targetFile.exists() && !_shouldOverwriteManagedBinary(source)) {
      if (spec.executable) {
        await _ensureExecutable(targetFile);
      }
      return;
    }

    final previousVersion = await _tryReadText(markerFile);
    final needsWrite =
        previousVersion != spec.versionStamp ||
        !await targetFile.exists() ||
        await targetFile.length() != data.lengthInBytes;
    if (needsWrite) {
      await targetFile.writeAsBytes(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        flush: true,
      );
      await markerFile.writeAsString(spec.versionStamp, flush: true);
      await sourceFile.writeAsString(bundledSource, flush: true);
    }

    if (spec.executable) {
      await _ensureExecutable(targetFile);
    }
  }

  static bool _shouldOverwriteManagedBinary(String? source) {
    final normalized = source?.trim();
    if (normalized == null || normalized.isEmpty) {
      return true;
    }
    return normalized == bundledSource;
  }

  static Future<ByteData?> _tryLoadAsset(
    String assetPath, [
    List<String> fallbacks = const [],
  ]) async {
    for (final candidate in [assetPath, ...fallbacks]) {
      try {
        return await rootBundle.load(candidate);
      } catch (_) {
        // Try the next candidate.
      }
    }
    return null;
  }

  static Future<String?> _tryReadText(File file) async {
    try {
      if (!await file.exists()) {
        return null;
      }
      return await file.readAsString();
    } catch (_) {
      return null;
    }
  }

  static Future<String> _resolveMacosArchFolder() async {
    final uname = File('/usr/bin/uname');
    if (await uname.exists()) {
      try {
        final result = await Process.run(uname.path, const ['-m']);
        final value = result.stdout.toString().trim().toLowerCase();
        if (value.contains('arm64') || value.contains('aarch64')) {
          return 'arm64';
        }
      } catch (_) {
        // Fall back to x64 below.
      }
    }
    return 'x64';
  }

  static Future<void> _ensureExecutable(File file) async {
    if (!(Platform.isMacOS || Platform.isLinux)) {
      return;
    }

    final chmodExecutable = File('/bin/chmod');
    if (!await chmodExecutable.exists()) {
      return;
    }

    try {
      await Process.run(chmodExecutable.path, ['755', file.path]);
    } catch (_) {
      // Best-effort only. Native-side detection will still surface failures.
    }
  }
}

class _BinaryAssetSpec {
  final String assetPath;
  final String outputFileName;
  final bool executable;
  final String versionStamp;
  final List<String> fallbackAssetPaths;

  const _BinaryAssetSpec({
    required this.assetPath,
    required this.outputFileName,
    required this.executable,
    required this.versionStamp,
    this.fallbackAssetPaths = const [],
  });
}
