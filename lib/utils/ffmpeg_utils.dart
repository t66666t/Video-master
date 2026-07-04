import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:video_player_app/features/youtube_download/services/yt_dlp_binary_installer.dart';

class FFmpegUtils {
  static Future<String>? _ffmpegPathFuture;
  static Future<String>? _ffprobePathFuture;

  static Future<String> get ffmpegPath async {
    if (!Platform.isWindows) {
      return 'ffmpeg'; // Not used on other platforms usually (they use FFmpegKit)
    }
    return _ffmpegPathFuture ??= _resolveWindowsBinaryPath(
      fileName: 'ffmpeg.exe',
      pathFallback: 'ffmpeg',
    );
  }

  static Future<String> get ffprobePath async {
    if (!Platform.isWindows) {
      return 'ffprobe';
    }
    return _ffprobePathFuture ??= _resolveWindowsBinaryPath(
      fileName: 'ffprobe.exe',
      pathFallback: 'ffprobe',
    );
  }

  static Future<String> _resolveWindowsBinaryPath({
    required String fileName,
    required String pathFallback,
  }) async {
    final exePath = Platform.resolvedExecutable;
    final exeDir = File(exePath).parent.path;
    final bundledPath = p.join(exeDir, fileName);
    if (await File(bundledPath).exists() &&
        await _isBinaryOperational(bundledPath)) {
      return bundledPath;
    }

    try {
      await YtDlpBinaryInstaller.ensureInstalled();
      final installedPath =
          await YtDlpBinaryInstaller.resolveInstalledBinaryPath(fileName);
      if (installedPath != null &&
          await File(installedPath).exists() &&
          await _isBinaryOperational(installedPath)) {
        return installedPath;
      }
    } catch (_) {
      // Fall back to PATH if lazy installation is unavailable.
    }

    if (await _isBinaryOperational(pathFallback)) {
      return pathFallback;
    }

    return pathFallback;
  }

  static Future<bool> _isBinaryOperational(String binaryPath) async {
    try {
      final result = await Process.run(
        binaryPath,
        const ['-version'],
      ).timeout(const Duration(seconds: 8));
      return result.exitCode == 0;
    } catch (_) {
      return false;
    }
  }
}
