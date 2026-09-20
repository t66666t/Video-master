/// Root-library destinations shown by the compact entry switcher.
enum MediaLibraryRootEntry {
  continueLearning,
  recent,
  folders,
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
      default:
        return null;
    }
  }
}
