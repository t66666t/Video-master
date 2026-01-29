import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:video_player/video_player.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../models/video_item.dart';
import '../models/subtitle_model.dart';
import 'playlist_manager.dart';
import 'progress_tracker.dart';

import '../services/settings_service.dart';

/// 播放状态枚举
enum PlaybackState {
  idle,      // 空闲状态
  loading,   // 加载中
  playing,   // 播放中
  paused,    // 暂停
  error,     // 错误
}

/// 媒体播放服务 - 管理全局播放状态
class MediaPlaybackService extends ChangeNotifier {
  // 单例模式
  static final MediaPlaybackService _instance = MediaPlaybackService._internal();
  factory MediaPlaybackService() => _instance;
  MediaPlaybackService._internal();

  // 依赖服务
  PlaylistManager? _playlistManager;
  ProgressTracker? _progressTracker;

  // 播放状态
  PlaybackState _state = PlaybackState.idle;
  VideoItem? _currentItem;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  Duration _bufferedPosition = Duration.zero;
  bool _isMuted = false;
  double _volume = 1.0;
  VideoPlayerController? _controller;
  
  // 字幕相关
  List<SubtitleItem> _subtitles = [];
  List<SubtitleItem> _secondarySubtitles = [];
  List<String> _subtitlePaths = [];
  SubtitleItem? _currentSubtitle;
  int _lastSubtitleIndex = 0;
  final List<int> _subtitleStartMs = <int>[];
  
  // 进度追踪定时器
  Timer? _progressTimer;
  
  // 进度更新定时器（用于实时UI更新）
  Timer? _positionUpdateTimer;
  
  Timer? _seekPersistTimer;
  int _seekRequestId = 0;
  bool? _lastControllerIsPlaying;
  bool _wakelockApplied = false;

  void _applyWakelock(bool enable) {
    try {
      final Future<void> future = enable ? WakelockPlus.enable() : WakelockPlus.disable();
      future.catchError((_) {});
    } catch (_) {}
  }

  void _syncWakelockWithState() {
    final bool shouldEnable = _state == PlaybackState.playing;
    if (_wakelockApplied == shouldEnable) return;
    _wakelockApplied = shouldEnable;
    _applyWakelock(shouldEnable);
  }

  // Getters
  PlaybackState get state => _state;
  VideoItem? get currentItem => _currentItem;
  Duration get position => _position;
  Duration get duration => _duration;
  Duration get bufferedPosition => _bufferedPosition;
  bool get isPlaying => _state == PlaybackState.playing;
  bool get isMuted => _isMuted;
  double get volume => _volume;
  VideoPlayerController? get controller => _controller;
  List<SubtitleItem> get subtitles => _subtitles;
  List<SubtitleItem> get secondarySubtitles => _secondarySubtitles;
  List<String> get subtitlePaths => _subtitlePaths;
  SubtitleItem? get currentSubtitle => _currentSubtitle;

  /// 初始化服务依赖
  void initialize({
    required PlaylistManager playlistManager,
    required ProgressTracker progressTracker,
  }) {
    _playlistManager = playlistManager;
    _progressTracker = progressTracker;
  }
  
  /// 设置字幕列表
  void setSubtitles(List<SubtitleItem> subtitles) {
    setSubtitleState(paths: const [], primary: subtitles, secondary: const []);
  }

  void setSubtitleState({
    required List<String> paths,
    required List<SubtitleItem> primary,
    required List<SubtitleItem> secondary,
  }) {
    _subtitles = primary;
    _secondarySubtitles = secondary;
    _subtitlePaths = List<String>.from(paths);
    _lastSubtitleIndex = 0;
    _currentSubtitle = null;
    _subtitleStartMs
      ..clear()
      ..addAll(_subtitles.map((e) => e.startTime.inMilliseconds));
    _updateCurrentSubtitle();
    notifyListeners();
  }

  void clearSubtitleState() {
    setSubtitleState(paths: const [], primary: const [], secondary: const []);
  }
  
  /// 设置外部控制器（用于UI创建的控制器移交给服务管理）
  void setController(VideoPlayerController controller) {
    // 如果是同一个控制器，无需处理
    if (_controller == controller) return;
    
    // 先移除旧控制器的监听器，防止状态冲突
    if (_controller != null) {
      try {
        _controller!.removeListener(_onControllerUpdate);
      } catch (e) {
        // 忽略移除失败（可能已dispose）
      }
    }
    
    _controller = controller;
    
    // 立即同步状态
    if (_controller!.value.isInitialized) {
      _duration = _controller!.value.duration;
      _position = _controller!.value.position;
      _bufferedPosition = _readBufferedPosition(_controller!);
      _state = _controller!.value.isPlaying ? PlaybackState.playing : PlaybackState.paused;
    }
    _lastControllerIsPlaying = _controller!.value.isPlaying;
    
    // 添加新监听器
    _controller!.addListener(_onControllerUpdate);
    
    // 启动进度追踪
    if (_state == PlaybackState.playing) {
      _startProgressTracking();
    } else {
      _stopProgressTracking();
    }
    
    _syncWakelockWithState();
    notifyListeners();
  }

  /// 清除当前控制器引用（当UI销毁控制器时调用）
  void clearController() {
    if (_controller != null) {
      try {
        _controller!.removeListener(_onControllerUpdate);
      } catch (e) {
        // 忽略
      }
      _controller = null;
    }
  }

  /// 更新媒体元数据
  Future<void> updateMetadata(VideoItem item) async {
    _currentItem = item;

    if (_playlistManager != null) {
      final idx = _playlistManager!.indexOfItem(item.id);
      if (idx >= 0) {
        _playlistManager!.setCurrentIndex(idx);
      } else {
        _playlistManager!.loadFolderPlaylist(item.parentId, item.id);
      }
    }
    
    // 如果控制器已就绪，确保时长准确
    if (_controller != null && _controller!.value.isInitialized) {
      _duration = _controller!.value.duration;
    }
    
    notifyListeners();
  }

  /// 跳转到上一句字幕
  Future<void> seekToPreviousSubtitle() async {
    if (_subtitles.isEmpty || _controller == null) return;
    
    // 找到当前字幕的索引
    int currentIndex = _lastSubtitleIndex;
    
    // 如果当前位置在当前字幕开始后1秒以上，跳到当前字幕开始
    if (_currentSubtitle != null && 
        _position > _currentSubtitle!.startTime + const Duration(seconds: 1)) {
      await seekTo(_currentSubtitle!.startTime);
      return;
    }
    
    // 否则跳到上一句字幕
    if (currentIndex > 0) {
      await seekTo(_subtitles[currentIndex - 1].startTime);
    }
  }
  
  /// 跳转到下一句字幕
  Future<void> seekToNextSubtitle() async {
    if (_subtitles.isEmpty || _controller == null) return;
    
    int currentIndex = _lastSubtitleIndex;
    
    // 跳到下一句字幕
    if (currentIndex < _subtitles.length - 1) {
      await seekTo(_subtitles[currentIndex + 1].startTime);
    }
  }

  /// 播放媒体
  Future<void> play(VideoItem item, {Duration? startPosition, bool autoPlay = true}) async {
    try {
      // 如果正在播放其他媒体，先保存进度并停止
      if (_currentItem != null && _currentItem!.id != item.id) {
        clearSubtitleState();
        await _saveCurrentProgress();
        _seekPersistTimer?.cancel();
        _seekPersistTimer = null;
        await _disposeController();
      }
      
      _currentItem = item;
      _state = PlaybackState.loading;
      _syncWakelockWithState();
      notifyListeners();

      if (_playlistManager != null) {
        final idx = _playlistManager!.indexOfItem(item.id);
        if (idx >= 0) {
          _playlistManager!.setCurrentIndex(idx);
        } else {
          _playlistManager!.loadFolderPlaylist(item.parentId, item.id);
        }
      }
      
      // 创建新的控制器
      final file = File(item.path);
      if (!await file.exists()) {
        _state = PlaybackState.error;
        notifyListeners();
        debugPrint('MediaPlaybackService: 文件不存在 ${item.path}');
        return;
      }
      
      _controller = VideoPlayerController.file(file);
      
      // 初始化控制器
      await _controller!.initialize();
      
      if (_controller == null) return; // 可能在初始化期间被停止
      
      _duration = _controller!.value.duration;
      _bufferedPosition = _readBufferedPosition(_controller!);
      if (_progressTracker != null && _duration > Duration.zero) {
        await _progressTracker!.saveDurationImmediately(item.id, _duration);
      }
      
      // 设置音量和静音状态
      await _controller!.setVolume(_isMuted ? 0.0 : _volume);
      
      // 添加监听器
      _controller!.addListener(_onControllerUpdate);
      
      // 确定起始位置
      Duration initialPosition = startPosition ?? Duration.zero;
      
      // 如果没有指定起始位置，尝试从进度追踪器获取
      if (startPosition == null && _progressTracker != null) {
        final savedProgress = _progressTracker!.getProgress(item.id);
        if (savedProgress != null) {
          initialPosition = savedProgress;
        }
      }
      
      // 跳转到起始位置
      if (initialPosition > Duration.zero && initialPosition < _duration) {
        await _controller!.seekTo(initialPosition);
        _position = initialPosition;
        _bufferedPosition = _readBufferedPosition(_controller!);
      }
      
      if (autoPlay) {
        // 乐观更新：立即设置状态为播放中
        _state = PlaybackState.playing;
        _syncWakelockWithState();
        notifyListeners();
        
        // 启动进度追踪定时器
        _startProgressTracking();
        
        // 开始播放
        await _controller!.play();
      } else {
        // 保持暂停状态
        _state = PlaybackState.paused;
        _syncWakelockWithState();
        // 暂停时也应该保存一次初始状态
        await _saveCurrentProgress(immediate: true);
      }
      
      // 保存播放状态快照
      await _savePlaybackStateSnapshot();
      
      notifyListeners();
    } catch (e) {
      debugPrint('MediaPlaybackService: 播放失败 $e');
      _state = PlaybackState.error;
      _syncWakelockWithState();
      notifyListeners();
    }
  }

  /// 暂停播放
  Future<void> pause() async {
    if (_state != PlaybackState.playing) return;
    
    try {
      // 乐观更新：立即设置状态为暂停
      _state = PlaybackState.paused;
      _syncWakelockWithState();
      notifyListeners();
      
      // 停止进度追踪定时器
      _stopProgressTracking();
      
      await _controller?.pause();
      
      // 更新最终位置
      if (_controller != null && _controller!.value.isInitialized) {
        _position = _controller!.value.position;
        _bufferedPosition = _readBufferedPosition(_controller!);
      }
      
      // 暂停时立即保存进度
      await _saveCurrentProgress(immediate: true);
      
      // 保存播放状态快照
      await _savePlaybackStateSnapshot();
      
      notifyListeners();
    } catch (e) {
      debugPrint('MediaPlaybackService: 暂停失败 $e');
    }
  }

  /// 继续播放
  Future<void> resume() async {
    if (_state != PlaybackState.paused) return;
    
    try {
      // 乐观更新：立即设置状态为播放中
      _state = PlaybackState.playing;
      _syncWakelockWithState();
      notifyListeners();
      
      // 重新启动进度追踪定时器
      _startProgressTracking();
      
      await _controller?.play();
      
      // 保存播放状态快照
      await _savePlaybackStateSnapshot();
      
      notifyListeners();
    } catch (e) {
      debugPrint('MediaPlaybackService: 继续播放失败 $e');
    }
  }

  /// 从 controller 同步播放状态（用于播放页面状态同步）
  /// 这个方法不进行状态检查，直接更新状态并通知监听器
  void updatePlaybackStateFromController() {
    if (_controller == null || !_controller!.value.isInitialized) return;
    
    // 直接从 controller 读取实际播放状态
    final controllerIsPlaying = _controller!.value.isPlaying;
    
    if (controllerIsPlaying) {
      _state = PlaybackState.playing;
      // 重新启动进度追踪定时器
      _startProgressTracking();
    } else {
      _state = PlaybackState.paused;
      // 停止进度追踪定时器
      _stopProgressTracking();
      
      // 更新最终位置
      _position = _controller!.value.position;
      _bufferedPosition = _readBufferedPosition(_controller!);
      
      // 暂停时立即保存进度
      _saveCurrentProgress(immediate: true);
    }

    _syncWakelockWithState();
    
    // 异步保存播放状态快照（不阻塞UI）
    _savePlaybackStateSnapshot().catchError((e) {
      debugPrint('保存播放状态快照失败: $e');
    });
    
    // 通知监听器，触发 UI 更新
    notifyListeners();
  }

  /// 停止播放
  Future<void> stop() async {
    // 保存当前进度
    await _saveCurrentProgress(immediate: true);
    
    // 保存播放状态快照（停止状态）
    if (_progressTracker != null) {
      await _progressTracker!.savePlaybackState(
        PlaybackStateSnapshot(
          currentItemId: null,
          positionMs: 0,
          wasPlaying: false,
          playlistFolderId: null,
        ),
      );
    }
    
    // 停止进度追踪
    _stopProgressTracking();
    _seekPersistTimer?.cancel();
    _seekPersistTimer = null;
    
    // 释放控制器
    await _disposeController();
    
    _state = PlaybackState.idle;
    _syncWakelockWithState();
    clearSubtitleState();
    _currentItem = null;
    _position = Duration.zero;
    _duration = Duration.zero;
    _bufferedPosition = Duration.zero;
    
    notifyListeners();
  }

  /// 跳转到指定位置
  Future<void> seekTo(Duration position) async {
    if (_controller == null || !_controller!.value.isInitialized) return;
    
    try {
      final controllerDuration = _controller!.value.duration;
      if (controllerDuration > Duration.zero && controllerDuration != _duration) {
        _duration = controllerDuration;
      }

      final clampedPosition = _duration > Duration.zero
          ? Duration(
              milliseconds: position.inMilliseconds.clamp(0, _duration.inMilliseconds).toInt(),
            )
          : (position.inMilliseconds < 0 ? Duration.zero : position);

      _position = clampedPosition;
      notifyListeners();

      final requestId = ++_seekRequestId;
      await _controller!.seekTo(clampedPosition);
      if (requestId != _seekRequestId) return;

      final actualPosition = _controller!.value.position;
      if (actualPosition != _position) {
        _position = actualPosition;
        notifyListeners();
      }
      _bufferedPosition = _readBufferedPosition(_controller!);

      _seekPersistTimer?.cancel();
      _seekPersistTimer = Timer(const Duration(milliseconds: 500), () {
        _saveCurrentProgress(immediate: true).catchError((e) {
          debugPrint('MediaPlaybackService: 保存进度失败 $e');
        });
        _savePlaybackStateSnapshot().catchError((e) {
          debugPrint('MediaPlaybackService: 保存播放状态快照失败 $e');
        });
      });

      notifyListeners();
    } catch (e) {
      debugPrint('MediaPlaybackService: 跳转失败 $e');
    }
  }

  /// 设置音量
  Future<void> setVolume(double volume) async {
    _volume = volume.clamp(0.0, 1.0);
    
    if (_controller != null && !_isMuted) {
      await _controller!.setVolume(_volume);
    }
    
    notifyListeners();
  }

  /// 切换静音状态
  Future<void> toggleMute() async {
    _isMuted = !_isMuted;
    
    if (_controller != null) {
      await _controller!.setVolume(_isMuted ? 0.0 : _volume);
    }
    
    notifyListeners();
  }

  /// 播放下一个媒体
  Future<void> playNext({bool autoPlay = true}) async {
    // 确保播放列表是最新的
    _playlistManager?.reloadPlaylist();
    
    final nextItem = _playlistManager?.getNext();
    if (nextItem != null) {
      // 保存当前进度
      await _saveCurrentProgress(immediate: true);
      
      // 更新播放列表索引
      final nextIndex = _playlistManager!.indexOfItem(nextItem.id);
      if (nextIndex >= 0) {
        _playlistManager!.setCurrentIndex(nextIndex);
      }
      
      await play(nextItem, autoPlay: autoPlay);
    }
  }

  /// 播放上一个媒体
  Future<void> playPrevious({bool autoPlay = true}) async {
    // 确保播放列表是最新的
    _playlistManager?.reloadPlaylist();

    final previousItem = _playlistManager?.getPrevious();
    if (previousItem != null) {
      // 保存当前进度
      await _saveCurrentProgress(immediate: true);
      
      // 更新播放列表索引
      final prevIndex = _playlistManager!.indexOfItem(previousItem.id);
      if (prevIndex >= 0) {
        _playlistManager!.setCurrentIndex(prevIndex);
      }
      
      await play(previousItem, autoPlay: autoPlay);
    }
  }
  
  /// 控制器更新监听器（用于处理播放状态变化）
  void _onControllerUpdate() {
    if (_controller == null || !_controller!.value.isInitialized) return;
    
    // 这个监听器主要用于处理播放状态变化（如播放完成、错误等）
    // 位置更新由 _positionUpdateTimer 定时器处理，避免过度通知
    
    // 检查播放完成
    final position = _controller!.value.position;
    final duration = _controller!.value.duration;
    final controllerIsPlaying = _controller!.value.isPlaying;
    final bufferedPosition = _readBufferedPosition(_controller!);
    if (bufferedPosition != _bufferedPosition) {
      _bufferedPosition = bufferedPosition;
    }
    
    if (position >= duration && duration > Duration.zero && _state == PlaybackState.playing) {
      _onPlaybackCompleted();
    }

    if (_lastControllerIsPlaying != controllerIsPlaying) {
      _lastControllerIsPlaying = controllerIsPlaying;
      updatePlaybackStateFromController();
    }
  }
  
  /// 更新当前字幕（支持连续字幕）
  void _updateCurrentSubtitle() {
    if (_subtitles.isEmpty) {
      if (_currentSubtitle != null) {
        _currentSubtitle = null;
      }
      return;
    }
    
    if (_subtitleStartMs.length != _subtitles.length) {
      _subtitleStartMs
        ..clear()
        ..addAll(_subtitles.map((e) => e.startTime.inMilliseconds));
    }

    final int posMs = _position.inMilliseconds;

    int foundIndex = -1;
    if (_lastSubtitleIndex >= 0 && _lastSubtitleIndex < _subtitles.length) {
      final int lastStart = _subtitleStartMs[_lastSubtitleIndex];
      final int lastEnd = (_lastSubtitleIndex + 1 < _subtitles.length)
          ? _subtitleStartMs[_lastSubtitleIndex + 1]
          : _subtitles[_lastSubtitleIndex].endTime.inMilliseconds;
      if (posMs >= lastStart && posMs < lastEnd) {
        foundIndex = _lastSubtitleIndex;
      } else if (_lastSubtitleIndex + 1 < _subtitles.length) {
        final int nextIndex = _lastSubtitleIndex + 1;
        final int nextStart = _subtitleStartMs[nextIndex];
        final int nextEnd = (nextIndex + 1 < _subtitles.length)
            ? _subtitleStartMs[nextIndex + 1]
            : _subtitles[nextIndex].endTime.inMilliseconds;
        if (posMs >= nextStart && posMs < nextEnd) {
          foundIndex = nextIndex;
        }
      }
    }

    if (foundIndex == -1) {
      int low = 0;
      int high = _subtitleStartMs.length - 1;
      int ans = -1;
      while (low <= high) {
        final int mid = (low + high) >> 1;
        if (_subtitleStartMs[mid] <= posMs) {
          ans = mid;
          low = mid + 1;
        } else {
          high = mid - 1;
        }
      }
      if (ans >= 0 && ans < _subtitles.length) {
        final int endMs = (ans + 1 < _subtitles.length)
            ? _subtitleStartMs[ans + 1]
            : _subtitles[ans].endTime.inMilliseconds;
        if (posMs < endMs) {
          foundIndex = ans;
        }
      }
    }

    SubtitleItem? foundSubtitle;
    if (foundIndex >= 0 && foundIndex < _subtitles.length) {
      foundSubtitle = _subtitles[foundIndex];
      _lastSubtitleIndex = foundIndex;
    } else {
      _lastSubtitleIndex = 0;
    }
    
    if (_currentSubtitle != foundSubtitle) {
      _currentSubtitle = foundSubtitle;
    }
  }
  
  /// 播放完成处理
  void _onPlaybackCompleted() {
    // 保存进度
    _saveCurrentProgress(immediate: true);
    
    // 自动播放下一个
    if (_playlistManager?.hasNext ?? false) {
      final settings = SettingsService();
      playNext(autoPlay: settings.autoPlayNextVideo);
    } else {
      // 没有下一个，停止播放
      stop();
    }
  }
  
  /// 启动进度追踪定时器
  void _startProgressTracking() {
    _stopProgressTracking();
    
    // 每5秒保存一次进度
    _progressTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      _saveCurrentProgress(immediate: true);
      _savePlaybackStateSnapshot();
    });
    
    _positionUpdateTimer = Timer.periodic(const Duration(milliseconds: 300), (_) {
      _updatePosition();
    });
  }
  
  /// 停止进度追踪定时器
  void _stopProgressTracking() {
    _progressTimer?.cancel();
    _progressTimer = null;
    _positionUpdateTimer?.cancel();
    _positionUpdateTimer = null;
  }
  
  /// 更新播放位置（用于实时UI同步）
  void _updatePosition() {
    if (_controller == null || !_controller!.value.isInitialized) return;
    if (_state != PlaybackState.playing) return;
    
    final newPosition = _controller!.value.position;
    final newDuration = _controller!.value.duration;
    final newBufferedPosition = _readBufferedPosition(_controller!);
    final durationChanged = newDuration != _duration;
    
    // 只有当位置或时长发生变化时才通知监听器
    if (newPosition != _position || newDuration != _duration || newBufferedPosition != _bufferedPosition) {
      _position = newPosition;
      _duration = newDuration;
      _bufferedPosition = newBufferedPosition;
      if (_currentItem != null && _progressTracker != null && _duration > Duration.zero) {
        final durationMs = _duration.inMilliseconds;
        if (_currentItem!.durationMs == 0 || _currentItem!.durationMs != durationMs) {
          _progressTracker!.saveDurationImmediately(_currentItem!.id, _duration);
        }
      }

      if (durationChanged &&
          _currentItem != null &&
          _duration > Duration.zero) {
        // _lastPushedMediaDuration was removed
      }
      
      // 更新当前字幕
      _updateCurrentSubtitle();
      
      // 检查是否播放结束
      if (_position >= _duration && _duration > Duration.zero) {
        _onPlaybackCompleted();
      }
      
      notifyListeners();
    }
  }
  
  // _updateNotificationProgress 已移除，改用事件驱动
  
  /// 保存当前播放进度
  Future<void> _saveCurrentProgress({bool immediate = false}) async {
    if (_currentItem == null || _progressTracker == null) return;
    
    if (immediate) {
      await _progressTracker!.saveProgressImmediately(_currentItem!.id, _position);
    } else {
      await _progressTracker!.saveProgress(_currentItem!.id, _position);
    }
  }
  
  /// 释放控制器
  Future<void> _disposeController() async {
    if (_controller != null) {
      _controller!.removeListener(_onControllerUpdate);
      await _controller!.dispose();
      _controller = null;
    }
  }

  @override
  void dispose() {
    _seekPersistTimer?.cancel();
    _seekPersistTimer = null;
    _stopProgressTracking();
    _disposeController();
    _applyWakelock(false);
    _wakelockApplied = false;
    super.dispose();
  }
  
  Duration _readBufferedPosition(VideoPlayerController controller) {
    final ranges = controller.value.buffered;
    if (ranges.isEmpty) return Duration.zero;
    Duration maxEnd = Duration.zero;
    for (final range in ranges) {
      if (range.end > maxEnd) {
        maxEnd = range.end;
      }
    }
    return maxEnd;
  }
  
  /// 保存播放状态快照
  Future<void> _savePlaybackStateSnapshot() async {
    if (_progressTracker == null) return;
    
    try {
      final snapshot = PlaybackStateSnapshot(
        currentItemId: _currentItem?.id,
        positionMs: _position.inMilliseconds,
        wasPlaying: _state == PlaybackState.playing,
        playlistFolderId: _currentItem?.parentId,
      );
      
      await _progressTracker!.savePlaybackState(snapshot);
    } catch (e) {
      debugPrint('MediaPlaybackService: 保存播放状态快照失败 $e');
    }
  }
}
