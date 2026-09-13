import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:video_player_app/features/youtube_download/services/yt_dlp_binary_installer.dart';

class FFmpegUtils {
  static Future<String>? _ffmpegPathFuture;
  static Future<String>? _ffprobePathFuture;

  static Future<String> get ffmpegPath async {
    if (!(Platform.isWindows || Platform.isMacOS)) {
      return 'ffmpeg';
    }
    return _ffmpegPathFuture ??= _resolveDesktopBinaryPath(
      fileName: Platform.isWindows ? 'ffmpeg.exe' : 'ffmpeg',
      pathFallback: 'ffmpeg',
    );
  }

  static Future<String> get ffprobePath async {
    if (!(Platform.isWindows || Platform.isMacOS)) {
      return 'ffprobe';
    }
    return _ffprobePathFuture ??= _resolveDesktopBinaryPath(
      fileName: Platform.isWindows ? 'ffprobe.exe' : 'ffprobe',
      pathFallback: 'ffprobe',
    );
  }

  static Future<String> _resolveDesktopBinaryPath({
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
      final result = await Process.run(binaryPath, const [
        '-version',
      ]).timeout(const Duration(seconds: 8));
      return result.exitCode == 0;
    } catch (_) {
      return false;
    }
  }
}
