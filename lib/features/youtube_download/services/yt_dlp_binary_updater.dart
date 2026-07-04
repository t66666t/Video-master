import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:video_player_app/features/youtube_download/services/yt_dlp_binary_installer.dart';

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

  static bool get supportsOnlineUpdate =>
      !kIsWeb && (Platform.isWindows || Platform.isMacOS);

  Future<YtDlpBinaryReleaseInfo> fetchLatestRelease() async {
    if (!supportsOnlineUpdate) {
      throw UnsupportedError('当前平台不支持在线更新 yt-dlp');
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
    final assetName = _resolveReleaseAssetName();
    final binaryAsset = assets.cast<Map<String, dynamic>?>().firstWhere(
      (item) => item?['name']?.toString() == assetName,
      orElse: () => null,
    );
    if (binaryAsset == null) {
      throw StateError('官方发布中未找到当前平台对应的 yt-dlp 资产: $assetName');
    }
    final checksumAsset = assets.cast<Map<String, dynamic>?>().firstWhere(
      (item) => item?['name']?.toString() == _checksumAssetName,
      orElse: () => null,
    );
    return YtDlpBinaryReleaseInfo(
      version: version,
      assetName: assetName,
      downloadUrl: binaryAsset['browser_download_url']?.toString() ?? '',
      releasePageUrl: json['html_url']?.toString() ?? '',
      checksumUrl: checksumAsset?['browser_download_url']?.toString(),
    );
  }

  Future<YtDlpBinaryUpdateResult> updateToLatest({
    required String? currentVersion,
    String? currentBinaryPath,
    void Function(double progress)? onProgress,
  }) async {
    if (!supportsOnlineUpdate) {
      throw UnsupportedError('当前平台不支持在线更新 yt-dlp');
    }

    final release = await fetchLatestRelease();
    final previousVersion = _normalizeVersion(currentVersion);
    if (previousVersion.isNotEmpty && previousVersion == release.version) {
      return YtDlpBinaryUpdateResult(
        status: YtDlpBinaryUpdateStatus.alreadyUpToDate,
        previousVersion: previousVersion,
        currentVersion: release.version,
        release: release,
      );
    }

    final installDir = await YtDlpBinaryInstaller.resolveInstallDirectory();
    await installDir.create(recursive: true);
    final fileName = _resolveInstalledFileName();
    final targetFile = _resolveTargetFile(
      currentBinaryPath: currentBinaryPath,
      expectedFileName: fileName,
      fallbackDirectory: installDir,
    );
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
      await YtDlpBinaryInstaller.ensureExecutable(targetFile);
      if (_isManagedInstallTarget(targetFile, installDir)) {
        await YtDlpBinaryInstaller.markBinaryAsManaged(
          fileName: fileName,
          versionStamp: release.version,
          source: YtDlpBinaryInstaller.officialReleaseSource,
        );
      }
      // 同步更新 exe 目录中的副本（如存在），防止 C++ 回退查找
      // 到旧的捆绑版本。
      await _syncExeDirCopy(
        updatedFile: targetFile,
        fileName: fileName,
      );
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

  String _resolveReleaseAssetName() {
    if (Platform.isWindows) {
      return 'yt-dlp.exe';
    }
    if (Platform.isMacOS) {
      return 'yt-dlp_macos';
    }
    throw UnsupportedError('当前平台不支持在线更新 yt-dlp');
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

  File _resolveTargetFile({
    required String? currentBinaryPath,
    required String expectedFileName,
    required Directory fallbackDirectory,
  }) {
    final normalizedPath = currentBinaryPath?.trim();
    if (normalizedPath != null && normalizedPath.isNotEmpty) {
      final candidate = File(normalizedPath);
      final basename = p.basename(candidate.path).toLowerCase();
      if (basename == expectedFileName.toLowerCase()) {
        return candidate;
      }
    }
    return File(p.join(fallbackDirectory.path, expectedFileName));
  }

  bool _isManagedInstallTarget(File targetFile, Directory installDir) {
    return p.equals(
      p.normalize(p.dirname(targetFile.path)),
      p.normalize(installDir.path),
    );
  }

  Future<void> _verifyChecksumIfAvailable(
    Dio dio,
    YtDlpBinaryReleaseInfo release,
    File downloadFile,
  ) async {
    final checksumUrl = release.checksumUrl;
    if (checksumUrl == null || checksumUrl.isEmpty) {
      return;
    }
    final response = await dio.get<String>(
      checksumUrl,
      options: Options(responseType: ResponseType.plain),
    );
    final checksumText = response.data;
    if (checksumText == null || checksumText.trim().isEmpty) {
      return;
    }
    final expectedHash = _extractExpectedHash(
      checksumText: checksumText,
      assetName: release.assetName,
    );
    if (expectedHash == null) {
      return;
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
      await downloadFile.rename(targetFile.path);
    } catch (error) {
      if (await downloadFile.exists() && !await targetFile.exists()) {
        try {
          await downloadFile.copy(targetFile.path);
          await downloadFile.delete();
        } catch (_) {
          // Ignore and let rollback below handle it.
        }
      }
      if (!await targetFile.exists() && await backupFile.exists()) {
        await backupFile.rename(targetFile.path);
      }
      rethrow;
    }
  }

  /// 将更新后的二进制文件同步到 exe 目录中的副本。
  /// Windows 构建时 CMake 会将捆绑的 yt-dlp.exe 复制到 exe 目录，
  /// C++ FindExecutable 回退查找时可能命中该旧副本。
  Future<void> _syncExeDirCopy({
    required File updatedFile,
    required String fileName,
  }) async {
    if (!Platform.isWindows) return;
    try {
      final exePath = Platform.resolvedExecutable;
      final exeDir = File(exePath).parent;
      final exeDirCopy = File(p.join(exeDir.path, fileName));
      // 仅当 exe 目录副本存在且与已更新文件不同时才覆盖
      if (!await exeDirCopy.exists()) return;
      if (p.equals(
        p.normalize(exeDirCopy.path),
        p.normalize(updatedFile.path),
      )) {
        return;
      }
      await updatedFile.copy(exeDirCopy.path);
    } catch (_) {
      // 尽力而为，exe 目录可能只读或文件被锁定
    }
  }

  Future<void> _deleteIfExists(File file) async {
    if (await file.exists()) {
      await file.delete();
    }
  }

  String _normalizeVersion(String? version) {
    return version?.trim().replaceFirst(
          RegExp(r'^v', caseSensitive: false),
          '',
        ) ??
        '';
  }
}
