/// Root-library destinations shown by the compact entry switcher.
enum MediaLibraryRootEntry {
  continueLearning,
  recent,
  folders,
  bilibili,
}

extension MediaLibraryRootEntryX on MediaLibraryRootEntry {
  String get storageValue {
    switch (this) {
      case MediaLibraryRootEntry.continueLearning:
        return 'continueLearning';
      case MediaLibraryRootEntry.recent:
        return 'recent';
      case MediaLibraryRootEntry.folders:
        return 'folders';
      case MediaLibraryRootEntry.bilibili:
        return 'bilibili';
    }
  }

  String get label {
    switch (this) {
      case MediaLibraryRootEntry.continueLearning:
        return '继续学习';
      case MediaLibraryRootEntry.recent:
        return '最近添加';
      case MediaLibraryRootEntry.folders:
        return '文件夹';
      case MediaLibraryRootEntry.bilibili:
        return '哔哩哔哩';
    }
  }

  static MediaLibraryRootEntry? tryParse(String? raw) {
    switch (raw) {
      case 'continueLearning':
        return MediaLibraryRootEntry.continueLearning;
      case 'recent':
        return MediaLibraryRootEntry.recent;
      case 'folders':
        return MediaLibraryRootEntry.folders;
      case 'bilibili':
        return MediaLibraryRootEntry.bilibili;
      default:
        return null;
    }
  }
}
