import 'package:path/path.dart' as p;

class YtDlpAndroidPostProcessPolicy {
  static const String primaryVideoStreamSpecifier = '0:V:0';

  static const Set<String> mediaContainerExtensions = <String>{
    'm4a',
    'mp3',
    'aac',
    'opus',
    'ogg',
    'oga',
    'wav',
    'flac',
    'wma',
    'mp4',
    'mkv',
    'mka',
    'webm',
    'avi',
    'mov',
    'flv',
    '3gp',
    'ts',
    'm2ts',
    'mpeg',
    'mpg',
    'wmv',
    'm4v',
    'ogv',
  };

  static bool isMediaContainerPath(String filePath) {
    final extension = p.extension(filePath).replaceFirst('.', '').toLowerCase();
    return mediaContainerExtensions.contains(extension);
  }

  static List<String> withoutThumbnailOutputArgs(List<String> args) {
    final filtered = <String>[];
    for (var index = 0; index < args.length; index++) {
      final arg = args[index];
      if (arg == '--write-thumbnail' || arg == '--write-all-thumbnails') {
        continue;
      }
      if (arg == '--convert-thumbnails') {
        if (index + 1 < args.length) index += 1;
        continue;
      }
      filtered.add(arg);
    }
    return filtered;
  }
}
