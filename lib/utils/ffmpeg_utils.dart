import 'dart:io';
import 'package:path/path.dart' as p;

class FFmpegUtils {
  static Future<String> get ffmpegPath async {
    if (Platform.isWindows) {
      final exePath = Platform.resolvedExecutable;
      final dir = File(exePath).parent.path;
      final bundledPath = p.join(dir, 'ffmpeg.exe');
      if (await File(bundledPath).exists()) {
        return bundledPath;
      }
      return 'ffmpeg'; // Fallback to PATH
    }
    return 'ffmpeg'; // Not used on other platforms usually (they use FFmpegKit)
  }

  static Future<String> get ffprobePath async {
    if (Platform.isWindows) {
      final exePath = Platform.resolvedExecutable;
      final dir = File(exePath).parent.path;
      final bundledPath = p.join(dir, 'ffprobe.exe');
      if (await File(bundledPath).exists()) {
        return bundledPath;
      }
      return 'ffprobe'; // Fallback to PATH
    }
    return 'ffprobe';
  }
}
