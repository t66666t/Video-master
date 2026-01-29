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
  String? _currentFolderId;
  bool _isFolderPlaylist = false;

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
    _isFolderPlaylist = false;
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
    _isFolderPlaylist = true;
    _currentFolderId = folderId;
  }

  /// 重新加载播放列表（用于同步文件夹内容变化）
  void reloadPlaylist() {
    if (!_isFolderPlaylist || _libraryService == null) return;

    final currentItemId = currentItem?.id;
    final folderItems = _libraryService!.getVideosInFolder(_currentFolderId);
    
    _playlist = List.from(folderItems);
    
    if (currentItemId != null) {
      final newIndex = _playlist.indexWhere((item) => item.id == currentItemId);
      if (newIndex >= 0) {
        _currentIndex = newIndex;
      } else {
        // 如果当前项不在新列表中（可能被移走），保持索引在有效范围内
        if (_currentIndex >= _playlist.length) {
          _currentIndex = _playlist.isEmpty ? -1 : _playlist.length - 1;
        }
      }
    } else {
      _currentIndex = _playlist.isEmpty ? -1 : 0;
    }
    
    notifyListeners();
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
