import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'library_service.dart';

/// 播放状态快照 - 用于持久化和恢复
class PlaybackStateSnapshot {
  final String? currentItemId;
  final int positionMs;
  final bool wasPlaying;
  final String? playlistFolderId;
  final int timestamp;

  PlaybackStateSnapshot({
    this.currentItemId,
    required this.positionMs,
    required this.wasPlaying,
    this.playlistFolderId,
    int? timestamp,
  }) : timestamp = timestamp ?? DateTime.now().millisecondsSinceEpoch;

  /// 转换为 JSON
  Map<String, dynamic> toJson() {
    return {
      'currentItemId': currentItemId,
      'positionMs': positionMs,
      'wasPlaying': wasPlaying,
      'playlistFolderId': playlistFolderId,
      'timestamp': timestamp,
    };
  }

  /// 从 JSON 创建
  factory PlaybackStateSnapshot.fromJson(Map<String, dynamic> json) {
    return PlaybackStateSnapshot(
      currentItemId: json['currentItemId'] as String?,
      positionMs: json['positionMs'] as int,
      wasPlaying: json['wasPlaying'] as bool,
      playlistFolderId: json['playlistFolderId'] as String?,
      timestamp: json['timestamp'] as int?,
    );
  }
}

/// 进度追踪器 - 管理播放进度持久化
class ProgressTracker {
  // 依赖服务
  LibraryService? _libraryService;

  // 防抖定时器
  Timer? _debounceTimer;
  static const Duration _debounceDuration = Duration(seconds: 5);

  // SharedPreferences 键
  static const String _playbackStateKey = 'playback_state_snapshot';

  /// 初始化服务依赖
  void initialize({required LibraryService libraryService}) {
    _libraryService = libraryService;
  }

  /// 保存进度（防抖处理，最多每5秒保存一次）
  Future<void> saveProgress(String itemId, Duration position) async {
    // 取消之前的定时器
    _debounceTimer?.cancel();
    
    // 设置新的防抖定时器
    _debounceTimer = Timer(_debounceDuration, () {
      saveProgressImmediately(itemId, position);
    });
  }

  /// 立即保存进度（用于暂停、切换等场景）
  Future<void> saveProgressImmediately(String itemId, Duration position) async {
    // 取消防抖定时器
    _debounceTimer?.cancel();
    
    if (_libraryService == null) {
      debugPrint('ProgressTracker: LibraryService 未初始化');
      return;
    }
    
    try {
      // 更新 VideoItem 的 lastPositionMs
      await _libraryService!.updateVideoProgress(itemId, position.inMilliseconds);
    } catch (e) {
      // 静默处理错误，不影响用户体验
      debugPrint('进度保存失败: $e');
    }
  }

  /// 获取保存的进度
  Duration? getProgress(String itemId) {
    if (_libraryService == null) {
      debugPrint('ProgressTracker: LibraryService 未初始化');
      return null;
    }
    
    // 从 LibraryService 获取视频项
    final video = _libraryService!.getVideo(itemId);
    if (video == null) {
      return null;
    }
    
    // 返回保存的播放位置
    final lastPos = video.lastPositionMs;
    if (lastPos > 0) {
      return Duration(milliseconds: lastPos);
    }
    
    return null;
  }

  /// 保存当前播放状态（用于应用恢复）
  Future<void> savePlaybackState(PlaybackStateSnapshot snapshot) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonString = jsonEncode(snapshot.toJson());
      await prefs.setString(_playbackStateKey, jsonString);
    } catch (e) {
      debugPrint('播放状态保存失败: $e');
    }
  }

  /// 恢复播放状态
  Future<PlaybackStateSnapshot?> restorePlaybackState() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonString = prefs.getString(_playbackStateKey);
      
      if (jsonString != null && jsonString.isNotEmpty) {
        final json = jsonDecode(jsonString) as Map<String, dynamic>;
        return PlaybackStateSnapshot.fromJson(json);
      }
    } catch (e) {
      debugPrint('播放状态恢复失败: $e');
    }
    return null;
  }

  /// 清理资源
  void dispose() {
    _debounceTimer?.cancel();
  }
}
