import 'dart:convert';

import 'library_activity.dart';

/// Where a newly imported media card is placed in the library tree.
enum ImportCardPlacement {
  /// The folder that was open when the import was started. Home is the root.
  currentFolder,

  /// Always the media library root.
  libraryRoot,

  /// A stable folder per import feature, created at the library root.
  sourceFolder,
}

extension ImportCardPlacementX on ImportCardPlacement {
  String get storageValue {
    switch (this) {
      case ImportCardPlacement.currentFolder:
        return 'currentFolder';
      case ImportCardPlacement.libraryRoot:
        return 'libraryRoot';
      case ImportCardPlacement.sourceFolder:
        return 'sourceFolder';
    }
  }

  String get label {
    switch (this) {
      case ImportCardPlacement.currentFolder:
        return '当前文件夹';
      case ImportCardPlacement.libraryRoot:
        return '媒体库根目录';
      case ImportCardPlacement.sourceFolder:
        return '按功能分开放';
    }
  }

  String get description {
    switch (this) {
      case ImportCardPlacement.currentFolder:
        return '在哪个文件夹里开始导入，卡片就进哪里。媒体库首页则进根目录。';
      case ImportCardPlacement.libraryRoot:
        return '无论从哪里打开，卡片都放在媒体库根目录。';
      case ImportCardPlacement.sourceFolder:
        return '每种导入使用自己的固定文件夹，都建在媒体库根目录下。文件夹名可以改。';
    }
  }

  static ImportCardPlacement fromStorage(Object? raw) {
    switch (raw) {
      case 'libraryRoot':
        return ImportCardPlacement.libraryRoot;
      case 'sourceFolder':
        return ImportCardPlacement.sourceFolder;
      case 'currentFolder':
      default:
        return ImportCardPlacement.currentFolder;
    }
  }
}

/// Import surfaces that can each own a stable library folder.
enum ImportCardFeature {
  localFile,
  folder,
  archive,
  bilibiliDownload,
  bilibiliOnline,
  ytDlp,
  fluentPack,
}

extension ImportCardFeatureX on ImportCardFeature {
  String get storageValue {
    switch (this) {
      case ImportCardFeature.localFile:
        return 'localFile';
      case ImportCardFeature.folder:
        return 'folder';
      case ImportCardFeature.archive:
        return 'archive';
      case ImportCardFeature.bilibiliDownload:
        return 'bilibiliDownload';
      case ImportCardFeature.bilibiliOnline:
        return 'bilibiliOnline';
      case ImportCardFeature.ytDlp:
        return 'ytDlp';
      case ImportCardFeature.fluentPack:
        return 'fluentPack';
    }
  }

  String get label {
    switch (this) {
      case ImportCardFeature.localFile:
        return '本地文件';
      case ImportCardFeature.folder:
        return '文件夹导入';
      case ImportCardFeature.archive:
        return '压缩包';
      case ImportCardFeature.bilibiliDownload:
        return 'B站下载';
      case ImportCardFeature.bilibiliOnline:
        return 'B站在线';
      case ImportCardFeature.ytDlp:
        return 'YT-DLP';
      case ImportCardFeature.fluentPack:
        return '导出包';
    }
  }

  String get defaultFolderName => label;

  static ImportCardFeature? tryParse(Object? raw) {
    for (final feature in ImportCardFeature.values) {
      if (feature.storageValue == raw) return feature;
    }
    return null;
  }

  static ImportCardFeature fromSourceKind(LibraryImportSourceKind kind) {
    switch (kind) {
      case LibraryImportSourceKind.folder:
        return ImportCardFeature.folder;
      case LibraryImportSourceKind.archive:
        return ImportCardFeature.archive;
      case LibraryImportSourceKind.ytDlp:
        return ImportCardFeature.ytDlp;
      case LibraryImportSourceKind.fluentPack:
        return ImportCardFeature.fluentPack;
      case LibraryImportSourceKind.bilibili:
        return ImportCardFeature.bilibiliDownload;
      case LibraryImportSourceKind.localFile:
      case LibraryImportSourceKind.share:
        return ImportCardFeature.localFile;
    }
  }
}

class ImportSourceFolders {
  static const String namesKey = 'importSourceFolderNames';
  static const String idsKey = 'importSourceFolderIds';

  static String sanitizeFolderName(String raw, {required String fallback}) {
    final cleaned = raw
        .replaceAll(RegExp(r'[\r\n\t]'), ' ')
        .replaceAll(RegExp(r'[<>:"/\\|?*]'), '')
        .trim();
    if (cleaned.isEmpty) return fallback;
    const maxLength = 40;
    if (cleaned.length <= maxLength) return cleaned;
    return cleaned.substring(0, maxLength).trim();
  }

  static Map<String, String> decodeNames(String raw) {
    final names = <String, String>{
      for (final feature in ImportCardFeature.values)
        feature.storageValue: feature.defaultFolderName,
    };
    final decoded = _decodeObject(raw);
    for (final feature in ImportCardFeature.values) {
      final value = decoded[feature.storageValue];
      if (value is! String) continue;
      names[feature.storageValue] = sanitizeFolderName(
        value,
        fallback: feature.defaultFolderName,
      );
    }
    return names;
  }

  static Map<String, String> decodeIds(String raw) {
    final ids = <String, String>{};
    final decoded = _decodeObject(raw);
    for (final feature in ImportCardFeature.values) {
      final value = decoded[feature.storageValue];
      if (value is! String) continue;
      final id = value.trim();
      if (id.isEmpty) continue;
      ids[feature.storageValue] = id;
    }
    return ids;
  }

  static String normalizeNamesJson(String raw) => jsonEncode(decodeNames(raw));

  static String normalizeIdsJson(String raw) => jsonEncode(decodeIds(raw));

  static Map<String, dynamic> _decodeObject(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return Map<String, dynamic>.from(decoded);
      }
    } catch (_) {}
    return const <String, dynamic>{};
  }
}
