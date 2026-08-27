import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show ByteData, rootBundle;
import 'package:path/path.dart' as p;
import 'package:video_player_app/features/youtube_download/services/yt_dlp_binary_location_store.dart';
import 'package:video_player_app/features/youtube_download/services/yt_dlp_platform_asset.dart';
import 'package:video_player_app/features/youtube_download/services/yt_dlp_version.dart';

class YtDlpBinaryInstaller {
  static const String _windowsFfmpegVersion = 'windows-runner-bundled';
  static const String _macosFfmpegVersion = 'macos-bundled-20260511';
  static const String bundledSource = 'bundled';
  static const String officialReleaseSource = 'official-release';

  static const List<_BinaryAssetSpec> _windowsToolAssets = [
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

    if (Platform.isAndroid) {
      await _removeOutdatedAndroidRuntimeOverride();
      return;
    }

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

  static String get bundledYtDlpVersion {
    if (Platform.isAndroid) {
      return YtDlpVersions.androidBundled;
    }
    if (Platform.isMacOS) {
      return YtDlpVersions.macosBundled;
    }
    if (Platform.isLinux) {
      return YtDlpVersions.linuxBundled;
    }
    return YtDlpVersions.windowsBundled;
  }

  static Future<List<_BinaryAssetSpec>> _currentPlatformSpecs() async {
    final platformAsset = await YtDlpPlatformAsset.current();
    if (platformAsset == null || platformAsset.bundledAssetPath == null) {
      return const [];
    }
    final ytDlpSpec = _BinaryAssetSpec(
      assetPath: platformAsset.bundledAssetPath!,
      outputFileName: platformAsset.installedFileName,
      executable: !Platform.isWindows,
      versionStamp:
          'yt-dlp-$bundledYtDlpVersion-${platformAsset.releaseAssetName}',
    );
    if (Platform.isWindows) {
      return [ytDlpSpec, ..._windowsToolAssets];
    }
    if (Platform.isMacOS) {
      final archFolder = await _resolveMacosArchFolder();
      final assetPrefix = 'assets/binaries/macos/$archFolder';
      return [
        ytDlpSpec,
        _BinaryAssetSpec(
          assetPath: '$assetPrefix/ffmpeg',
          outputFileName: 'ffmpeg',
          executable: true,
          versionStamp: 'ffmpeg-$_macosFfmpegVersion-$archFolder',
        ),
      ];
    }
    if (Platform.isLinux) {
      return [ytDlpSpec];
    }
    // yt-dlp 官方发布页目前没有可直接用于 Android App 的独立官方可执行文件。
    return const [];
  }

  static Future<Directory> _resolveInstallDirectory() async {
    final settings = await YtDlpBinaryLocationStore.load();
    return Directory(settings.managedDirectory);
  }

  static Future<YtDlpPlatformAsset?> resolveCurrentPlatformAsset() {
    return YtDlpPlatformAsset.current();
  }

  static Future<String?> resolveManagedYtDlpPath() async {
    final asset = await resolveCurrentPlatformAsset();
    if (asset == null) return null;
    return resolveInstalledBinaryPath(asset.installedFileName);
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

  static Future<Directory> migrateInstallDirectory(String newPath) async {
    final trimmed = newPath.trim();
    if (trimmed.isEmpty || !p.isAbsolute(trimmed)) {
      throw ArgumentError('请输入有效的绝对文件夹路径');
    }
    final currentDirectory = await _resolveInstallDirectory();
    final targetDirectory = Directory(p.normalize(trimmed));
    if (p.equals(currentDirectory.path, targetDirectory.path)) {
      return currentDirectory;
    }
    if (p.isWithin(currentDirectory.path, targetDirectory.path) ||
        p.isWithin(targetDirectory.path, currentDirectory.path)) {
      throw ArgumentError('新旧文件夹不能互相包含');
    }

    await targetDirectory.create(recursive: true);
    final sourceFiles = await currentDirectory.exists()
        ? await currentDirectory
              .list()
              .where((entity) => entity is File)
              .toList()
        : const <FileSystemEntity>[];
    final copiedFiles = <File>[];
    try {
      for (final entity in sourceFiles) {
        final sourceFile = entity as File;
        final targetFile = File(
          p.join(targetDirectory.path, p.basename(sourceFile.path)),
        );
        if (await targetFile.exists()) {
          throw FileSystemException('目标文件夹已存在同名文件，请选择空文件夹', targetFile.path);
        }
        await sourceFile.copy(targetFile.path);
        copiedFiles.add(targetFile);
      }
    } catch (_) {
      for (final copiedFile in copiedFiles.reversed) {
        try {
          if (await copiedFile.exists()) await copiedFile.delete();
        } catch (_) {}
      }
      rethrow;
    }

    final settings = await YtDlpBinaryLocationStore.load();
    await YtDlpBinaryLocationStore.save(
      settings.copyWith(managedDirectory: targetDirectory.path),
    );
    for (final entity in sourceFiles) {
      final sourceFile = entity as File;
      try {
        if (await sourceFile.exists()) await sourceFile.delete();
      } catch (_) {
        // The new copy is already active. Leaving a duplicate is safer than
        // rolling back the persisted location after a successful copy.
      }
    }
    try {
      if (await currentDirectory.exists() &&
          await currentDirectory.list().isEmpty) {
        await currentDirectory.delete();
      }
    } catch (_) {}
    return targetDirectory;
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

  static Future<void> _removeOutdatedAndroidRuntimeOverride() async {
    final installDir = await _resolveInstallDirectory();
    final runtimeFile = File(p.join(installDir.path, 'yt-dlp'));
    final markerFile = File('${runtimeFile.path}.version');
    final sourceFile = File('${runtimeFile.path}.source');
    final source = await _tryReadText(sourceFile);
    final installedVersion = await _tryReadText(markerFile);
    if (source?.trim() != officialReleaseSource ||
        !YtDlpVersions.shouldReplaceInstalledStable(
          installedVersionStamp: installedVersion,
          bundledVersionStamp: YtDlpVersions.androidBundled,
        )) {
      return;
    }
    for (final file in [runtimeFile, markerFile, sourceFile]) {
      try {
        if (await file.exists()) await file.delete();
      } catch (_) {
        // If removal fails, the Python bridge validates the archive and can
        // still fall back to the APK-bundled module.
      }
    }
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
    final source = await _tryReadText(sourceFile);
    final previousVersion = await _tryReadText(markerFile);
    final targetExists = await targetFile.exists();
    final normalizedSource = source?.trim();
    final isCurrentBundledInstall =
        targetExists &&
        normalizedSource == bundledSource &&
        previousVersion == spec.versionStamp;
    final shouldKeepOfficialInstall =
        targetExists &&
        normalizedSource == officialReleaseSource &&
        !_shouldOverwriteManagedBinary(
          source: source,
          previousVersion: previousVersion,
          spec: spec,
        );
    if (isCurrentBundledInstall || shouldKeepOfficialInstall) {
      if (spec.executable) {
        await _ensureExecutable(targetFile);
      }
      return;
    }

    // Only inflate the bundled asset when installation or replacement is
    // actually required. ffmpeg alone is close to 100 MB on Windows.
    final data = await _tryLoadAsset(spec.assetPath);
    if (data == null) {
      return;
    }

    final needsWrite =
        previousVersion != spec.versionStamp ||
        !targetExists ||
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

  static bool _shouldOverwriteManagedBinary({
    required String? source,
    required String? previousVersion,
    required _BinaryAssetSpec spec,
  }) {
    final normalized = source?.trim();
    if (normalized == null || normalized.isEmpty) {
      return true;
    }
    if (normalized == bundledSource) {
      return true;
    }
    if (normalized != officialReleaseSource || !spec.isYtDlp) {
      return false;
    }
    final shouldReplaceOlder = YtDlpVersions.shouldReplaceInstalledStable(
      installedVersionStamp: previousVersion,
      bundledVersionStamp: spec.versionStamp,
    );
    if (shouldReplaceOlder) return true;
    final installed = YtDlpVersions.extractStableVersion(previousVersion);
    final bundled = YtDlpVersions.extractStableVersion(spec.versionStamp);
    return installed != null &&
        bundled != null &&
        YtDlpVersions.compare(installed, bundled) == 0 &&
        previousVersion?.trim() != spec.versionStamp;
  }

  static Future<ByteData?> _tryLoadAsset(String assetPath) async {
    for (final candidate in [assetPath]) {
      try {
        return await rootBundle.load(candidate);
      } catch (_) {
        // Try the next candidate.
      }
    }
    for (final candidate in _packagedFileCandidates(assetPath)) {
      try {
        final file = File(candidate);
        if (!await file.exists()) continue;
        final bytes = await file.readAsBytes();
        return ByteData.sublistView(bytes);
      } catch (_) {
        // Try the next platform-packaged copy.
      }
    }
    return null;
  }

  static List<String> _packagedFileCandidates(String assetPath) {
    final executableDirectory = File(Platform.resolvedExecutable).parent.path;
    final assetSegments = p.split(assetPath);
    final fileName = p.basename(assetPath).startsWith('yt-dlp')
        ? (Platform.isWindows ? 'yt-dlp.exe' : 'yt-dlp')
        : p.basename(assetPath);
    final archFolderIndex = assetSegments.indexWhere(
      (segment) => segment == 'arm64' || segment == 'x64',
    );
    final relativeParts = <String>[
      'yt_dlp',
      if (archFolderIndex >= 0) assetSegments[archFolderIndex],
      fileName,
    ];
    final relativePath = p.joinAll(relativeParts);
    return [
      p.join(executableDirectory, 'resources', relativePath),
      p.normalize(p.join(executableDirectory, '..', 'Resources', relativePath)),
      p.normalize(
        p.join(
          executableDirectory,
          '..',
          'lib',
          'video_player_app',
          'resources',
          relativePath,
        ),
      ),
      p.join(executableDirectory, 'data', 'resources', relativePath),
    ];
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

  const _BinaryAssetSpec({
    required this.assetPath,
    required this.outputFileName,
    required this.executable,
    required this.versionStamp,
  });

  bool get isYtDlp =>
      outputFileName == 'yt-dlp.exe' || outputFileName == 'yt-dlp';
}
