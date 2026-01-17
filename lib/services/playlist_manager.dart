import 'package:flutter/foundation.dart';
import '../models/video_item.dart';
import 'library_service.dart';

/// 播放列表管理器
class PlaylistManager extends ChangeNotifier {
  // 依赖服务
  LibraryService? _libraryService;

  // 当前播放列表
  List<VideoItem> _playlist = [];
  int _currentIndex = -1;

  // Getters
  List<VideoItem> get playlist => List.unmodifiable(_playlist);
  int get currentIndex => _currentIndex;
  VideoItem? get currentItem => 
      _currentIndex >= 0 && _currentIndex < _playlist.length 
          ? _playlist[_currentIndex] 
          : null;

  /// 初始化服务依赖
  void initialize({required LibraryService libraryService}) {
    _libraryService = libraryService;
  }

  /// 设置播放列表
  void setPlaylist(List<VideoItem> items, {int startIndex = 0}) {
    _playlist = List.from(items);
    _currentIndex = items.isEmpty ? -1 : startIndex.clamp(0, items.length - 1);
    notifyListeners();
  }

  /// 从文件夹加载播放列表
  void loadFolderPlaylist(String? folderId, String currentItemId) {
    if (_libraryService == null) {
      debugPrint('PlaylistManager: LibraryService not initialized');
      return;
    }
    
    // 获取同文件夹的所有媒体（不包括回收站中的）
    final folderItems = _libraryService!.getVideosInFolder(folderId);
    
    // 找到当前项的索引
    final currentIdx = folderItems.indexWhere((item) => item.id == currentItemId);
    
    setPlaylist(folderItems, startIndex: currentIdx >= 0 ? currentIdx : 0);
  }

  /// 获取下一个媒体
  VideoItem? getNext() {
    if (!hasNext) return null;
    return _playlist[_currentIndex + 1];
  }

  /// 获取上一个媒体
  VideoItem? getPrevious() {
    if (!hasPrevious) return null;
    return _playlist[_currentIndex - 1];
  }

  /// 是否有下一个媒体
  bool get hasNext => _currentIndex >= 0 && _currentIndex < _playlist.length - 1;

  /// 是否有上一个媒体
  bool get hasPrevious => _currentIndex > 0;

  /// 设置当前索引
  void setCurrentIndex(int index) {
    if (index >= 0 && index < _playlist.length) {
      _currentIndex = index;
      notifyListeners();
    }
  }

  /// 获取媒体项的索引
  int indexOfItem(String itemId) {
    return _playlist.indexWhere((item) => item.id == itemId);
  }
}
