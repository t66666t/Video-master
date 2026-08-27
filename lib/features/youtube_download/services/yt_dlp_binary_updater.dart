import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:video_player_app/features/youtube_download/services/yt_dlp_binary_installer.dart';
import 'package:video_player_app/features/youtube_download/services/yt_dlp_platform_asset.dart';
import 'package:video_player_app/features/youtube_download/services/yt_dlp_runtime_abi.dart';
import 'package:video_player_app/features/youtube_download/services/yt_dlp_version.dart';

class YtDlpBinaryReleaseInfo {
  final String version;
  final String assetName;
  final String downloadUrl;
  final String releasePageUrl;
  final String? checksumUrl;

  const YtDlpBinaryReleaseInfo({
    required this.version,
    required this.assetName,
    required this.downloadUrl,
    required this.releasePageUrl,
    this.checksumUrl,
  });
}

enum YtDlpBinaryUpdateStatus { updated, alreadyUpToDate }

class YtDlpBinaryUpdateResult {
  final YtDlpBinaryUpdateStatus status;
  final String previousVersion;
  final String currentVersion;
  final YtDlpBinaryReleaseInfo release;

  const YtDlpBinaryUpdateResult({
    required this.status,
    required this.previousVersion,
    required this.currentVersion,
    required this.release,
  });
}

class YtDlpBinaryUpdater {
  static const String _latestReleaseApiUrl =
      'https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest';
  static const String _githubApiAccept = 'application/vnd.github+json';
  static const String _userAgent = 'video_player_app/yt-dlp-updater';
  static const String _checksumAssetName = 'SHA2-256SUMS';

  const YtDlpBinaryUpdater();

  static int compareVersions(String left, String right) {
    return YtDlpVersions.compare(left, right);
  }

  static bool get supportsOnlineUpdate =>
      !kIsWeb &&
      (Platform.isWindows ||
          Platform.isMacOS ||
          Platform.isAndroid ||
          (Platform.isLinux &&
              (currentYtDlpRuntimeArch() == YtDlpRuntimeArch.x64 ||
                  currentYtDlpRuntimeArch() == YtDlpRuntimeArch.arm64)));

  static bool get supportsLatestReleaseCheck =>
      !kIsWeb &&
      (Platform.isWindows ||
          Platform.isMacOS ||
          Platform.isLinux ||
          Platform.isAndroid);

  Future<YtDlpBinaryReleaseInfo> fetchLatestRelease() async {
    if (!supportsLatestReleaseCheck) {
      throw UnsupportedError('当前平台不支持检查 yt-dlp 最新稳定版');
    }

    final dio = Dio(
      BaseOptions(
        headers: const {
          HttpHeaders.acceptHeader: _githubApiAccept,
          HttpHeaders.userAgentHeader: _userAgent,
        },
        responseType: ResponseType.json,
        receiveTimeout: const Duration(seconds: 20),
        connectTimeout: const Duration(seconds: 10),
      ),
    );
    final response = await dio.get<Object>(_latestReleaseApiUrl);
    final payload = response.data;
    if (payload is! Map) {
      throw StateError('无法解析 yt-dlp 最新版本信息');
    }
    final json = Map<String, dynamic>.from(payload.cast<Object, Object?>());
    final version = _normalizeVersion(json['tag_name']?.toString());
    if (version.isEmpty) {
      throw StateError('官方返回的 yt-dlp 版本号为空');
    }

    final assets = (json['assets'] as List<dynamic>? ?? const [])
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item.cast<Object, Object?>()))
        .toList();
    final platformAsset = await YtDlpPlatformAsset.current();
    final assetName =
        platformAsset?.releaseAssetName ?? _tryResolveReleaseAssetName();
    final binaryAsset = assetName == null
        ? null
        : assets.cast<Map<String, dynamic>?>().firstWhere(
            (item) => item?['name']?.toString() == assetName,
            orElse: () => null,
          );
    if (supportsOnlineUpdate && binaryAsset == null) {
      throw StateError('官方发布中未找到当前平台对应的 yt-dlp 资产: $assetName');
    }
    final checksumAsset = assets.cast<Map<String, dynamic>?>().firstWhere(
      (item) => item?['name']?.toString() == _checksumAssetName,
      orElse: () => null,
    );
    return YtDlpBinaryReleaseInfo(
      version: version,
      assetName: assetName ?? '',
      downloadUrl: binaryAsset?['browser_download_url']?.toString() ?? '',
      releasePageUrl: json['html_url']?.toString() ?? '',
      checksumUrl: checksumAsset?['browser_download_url']?.toString(),
    );
  }

  Future<YtDlpBinaryUpdateResult> updateToLatest({
    required String? currentVersion,
    void Function(double progress)? onProgress,
    Future<String?> Function(String binaryPath)? validateBinary,
  }) async {
    if (!supportsOnlineUpdate) {
      throw UnsupportedError('当前平台不支持在线更新 yt-dlp');
    }

    final release = await fetchLatestRelease();
    final previousVersion = _normalizeVersion(currentVersion);
    if (previousVersion.isNotEmpty &&
        compareVersions(previousVersion, release.version) == 0) {
      return YtDlpBinaryUpdateResult(
        status: YtDlpBinaryUpdateStatus.alreadyUpToDate,
        previousVersion: previousVersion,
        currentVersion: release.version,
        release: release,
      );
    }

    final platformAsset = await YtDlpPlatformAsset.current();
    if (platformAsset == null) {
      throw UnsupportedError('当前系统或处理器架构没有可用的官方 yt-dlp 资产');
    }
    final installDir = await YtDlpBinaryInstaller.resolveInstallDirectory();
    await installDir.create(recursive: true);
    final fileName = platformAsset.installedFileName.isEmpty
        ? _resolveInstalledFileName()
        : platformAsset.installedFileName;
    final targetFile = File(p.join(installDir.path, fileName));
    final downloadFile = File('${targetFile.path}.download');
    final backupFile = File('${targetFile.path}.bak');

    await _deleteIfExists(downloadFile);

    final dio = Dio(
      BaseOptions(
        headers: const {HttpHeaders.userAgentHeader: _userAgent},
        receiveTimeout: const Duration(minutes: 2),
        connectTimeout: const Duration(seconds: 15),
      ),
    );
    await dio.download(
      release.downloadUrl,
      downloadFile.path,
      onReceiveProgress: (received, total) {
        if (onProgress == null || total <= 0) {
          return;
        }
        onProgress((received / total).clamp(0.0, 1.0));
      },
    );

    try {
      await _verifyChecksumIfAvailable(dio, release, downloadFile);
      await _replaceTargetBinary(
        targetFile: targetFile,
        downloadFile: downloadFile,
        backupFile: backupFile,
      );
      try {
        await YtDlpBinaryInstaller.ensureExecutable(targetFile);
        final appliedVersion = _normalizeVersion(
          validateBinary == null
              ? await _readBinaryVersion(targetFile)
              : await validateBinary(targetFile.path),
        );
        if (appliedVersion != release.version) {
          throw StateError(
            'yt-dlp 更新校验失败：期望 ${release.version}，'
            '实际 ${appliedVersion.isEmpty ? '无法读取' : appliedVersion}',
          );
        }
        await YtDlpBinaryInstaller.markBinaryAsManaged(
          fileName: fileName,
          versionStamp: 'yt-dlp-${release.version}-${release.assetName}',
          source: YtDlpBinaryInstaller.officialReleaseSource,
        );
      } catch (_) {
        await _restoreBackup(targetFile: targetFile, backupFile: backupFile);
        if (validateBinary != null && await targetFile.exists()) {
          try {
            await validateBinary(targetFile.path);
          } catch (_) {}
        }
        rethrow;
      }
      await _deleteIfExists(backupFile);
      return YtDlpBinaryUpdateResult(
        status: YtDlpBinaryUpdateStatus.updated,
        previousVersion: previousVersion,
        currentVersion: release.version,
        release: release,
      );
    } finally {
      await _deleteIfExists(downloadFile);
    }
  }

  String? _tryResolveReleaseAssetName() {
    if (Platform.isWindows) {
      return 'yt-dlp.exe';
    }
    if (Platform.isMacOS) {
      return 'yt-dlp_macos';
    }
    return null;
  }

  String _resolveInstalledFileName() {
    if (Platform.isWindows) {
      return 'yt-dlp.exe';
    }
    if (Platform.isMacOS) {
      return 'yt-dlp';
    }
    throw UnsupportedError('当前平台不支持在线更新 yt-dlp');
  }

  Future<void> _verifyChecksumIfAvailable(
    Dio dio,
    YtDlpBinaryReleaseInfo release,
    File downloadFile,
  ) async {
    final checksumUrl = release.checksumUrl;
    if (checksumUrl == null || checksumUrl.isEmpty) {
      throw StateError('官方发布缺少 SHA2-256SUMS，已拒绝安装未校验的 yt-dlp');
    }
    final response = await dio.get<String>(
      checksumUrl,
      options: Options(responseType: ResponseType.plain),
    );
    final checksumText = response.data;
    if (checksumText == null || checksumText.trim().isEmpty) {
      throw StateError('官方 yt-dlp 校验文件为空，已取消更新');
    }
    final expectedHash = _extractExpectedHash(
      checksumText: checksumText,
      assetName: release.assetName,
    );
    if (expectedHash == null) {
      throw StateError('SHA2-256SUMS 中未找到 ${release.assetName} 的校验值');
    }
    final actualHash = sha256
        .convert(await downloadFile.readAsBytes())
        .toString();
    if (actualHash.toLowerCase() != expectedHash.toLowerCase()) {
      throw StateError('下载的 yt-dlp 校验失败，请稍后重试');
    }
  }

  String? _extractExpectedHash({
    required String checksumText,
    required String assetName,
  }) {
    final lines = const LineSplitter().convert(checksumText);
    for (final rawLine in lines) {
      final line = rawLine.trim();
      if (line.isEmpty) {
        continue;
      }
      final match = RegExp(r'^([A-Fa-f0-9]{64})\s+[* ]?(.+)$').firstMatch(line);
      if (match == null) {
        continue;
      }
      final name = match.group(2)?.trim();
      if (name == assetName) {
        return match.group(1)?.trim();
      }
    }
    return null;
  }

  Future<void> _replaceTargetBinary({
    required File targetFile,
    required File downloadFile,
    required File backupFile,
  }) async {
    await _deleteIfExists(backupFile);
    final targetExists = await targetFile.exists();
    try {
      if (targetExists) {
        await targetFile.rename(backupFile.path);
      }
      try {
        await downloadFile.rename(targetFile.path);
      } catch (_) {
        await downloadFile.copy(targetFile.path);
        await downloadFile.delete();
      }
    } catch (_) {
      await _restoreBackup(targetFile: targetFile, backupFile: backupFile);
      rethrow;
    }
  }

  Future<String> _readBinaryVersion(File binary) async {
    try {
      final result = await Process.run(binary.path, const [
        '--version',
      ]).timeout(const Duration(seconds: 15));
      if (result.exitCode != 0) {
        return '';
      }
      return _normalizeVersion(result.stdout.toString());
    } catch (_) {
      return '';
    }
  }

  Future<void> _restoreBackup({
    required File targetFile,
    required File backupFile,
  }) async {
    if (await targetFile.exists()) {
      await targetFile.delete();
    }
    if (await backupFile.exists()) {
      await backupFile.rename(targetFile.path);
    }
  }

  Future<void> _deleteIfExists(File file) async {
    if (await file.exists()) {
      await file.delete();
    }
  }

  String _normalizeVersion(String? version) {
    return YtDlpVersions.normalize(version);
  }
}
