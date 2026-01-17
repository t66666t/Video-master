import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:video_player/video_player.dart';
import 'package:fast_gbk/fast_gbk.dart';
import '../models/video_item.dart';
import '../models/subtitle_model.dart';
import '../utils/subtitle_parser.dart';
import 'playlist_manager.dart';
import 'progress_tracker.dart';
import 'audio_session_service.dart';

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
  AudioSessionService? _audioSessionService;

  // 播放状态
  PlaybackState _state = PlaybackState.idle;
  VideoItem? _currentItem;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _isMuted = false;
  double _volume = 1.0;
  VideoPlayerController? _controller;
  
  // 字幕相关
  List<SubtitleItem> _subtitles = [];
  SubtitleItem? _currentSubtitle;
  int _lastSubtitleIndex = 0;
  
  // 进度追踪定时器
  Timer? _progressTimer;
  
  // 进度更新定时器（用于实时UI更新）
  Timer? _positionUpdateTimer;
  
  // 通知栏进度更新定时器
  Timer? _notificationUpdateTimer;

  // Getters
  PlaybackState get state => _state;
  VideoItem? get currentItem => _currentItem;
  Duration get position => _position;
  Duration get duration => _duration;
  bool get isPlaying => _state == PlaybackState.playing;
  bool get isMuted => _isMuted;
  double get volume => _volume;
  VideoPlayerController? get controller => _controller;
  List<SubtitleItem> get subtitles => _subtitles;
  SubtitleItem? get currentSubtitle => _currentSubtitle;

  /// 初始化服务依赖
  void initialize({
    required PlaylistManager playlistManager,
    required ProgressTracker progressTracker,
    AudioSessionService? audioSessionService,
  }) {
    _playlistManager = playlistManager;
    _progressTracker = progressTracker;
    _audioSessionService = audioSessionService;
    
    // 监听音频服务的媒体操作
    _audioSessionService?.mediaActions.listen(_handleMediaAction);
  }
  
  /// 设置字幕列表
  void setSubtitles(List<SubtitleItem> subtitles) {
    _subtitles = subtitles;
    _lastSubtitleIndex = 0;
    _currentSubtitle = null;
    _updateCurrentSubtitle();
    notifyListeners();
  }
  
  /// 设置外部控制器（用于UI创建的控制器移交给服务管理）
  void setController(VideoPlayerController controller) {
    // 如果是同一个控制器，无需处理
    if (_controller == controller) return;
    
    // 如果之前有控制器且不是传入的这个，先释放旧的（如果服务持有所有权）
    // 这里假设调用 setController 时，UI 已经负责了旧控制器的清理，或者服务接管了所有权
    // 为安全起见，我们只更新引用，不 dispose，避免意外释放 UI 还在用的控制器
    // 实际逻辑中，UI 切换视频时会 dispose 旧的
    
    _controller = controller;
    
    // 立即同步状态
    if (_controller!.value.isInitialized) {
      _duration = _controller!.value.duration;
      _position = _controller!.value.position;
      _state = _controller!.value.isPlaying ? PlaybackState.playing : PlaybackState.paused;
    }
    
    // 重新绑定监听器
    try {
      _controller!.removeListener(_onControllerUpdate);
    } catch (e) {
      // 忽略移除失败
    }
    _controller!.addListener(_onControllerUpdate);
    
    // 启动进度追踪
    if (_state == PlaybackState.playing) {
      _startProgressTracking();
    } else {
      _stopProgressTracking();
    }
    
    notifyListeners();
  }

  /// 更新媒体元数据（用于同步通知栏信息）
  Future<void> updateMetadata(VideoItem item) async {
    _currentItem = item;
    
    // 如果控制器已就绪，确保时长准确
    if (_controller != null && _controller!.value.isInitialized) {
      _duration = _controller!.value.duration;
    }
    
    await _updateAudioService();
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
        await _saveCurrentProgress();
        await _disposeController();
      }
      
      _currentItem = item;
      _state = PlaybackState.loading;
      notifyListeners();
      
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
      }
      
      if (autoPlay) {
        // 开始播放
        await _controller!.play();
        _state = PlaybackState.playing;
        
        // 启动进度追踪定时器
        _startProgressTracking();
      } else {
        // 保持暂停状态
        _state = PlaybackState.paused;
        // 暂停时也应该保存一次初始状态
        await _saveCurrentProgress(immediate: true);
      }
      
      // 更新音频服务的媒体信息和播放状态
      await _updateAudioService();
      
      // 保存播放状态快照
      await _savePlaybackStateSnapshot();
      
      notifyListeners();
    } catch (e) {
      debugPrint('MediaPlaybackService: 播放失败 $e');
      _state = PlaybackState.error;
      notifyListeners();
    }
  }

  /// 暂停播放
  Future<void> pause() async {
    if (_state != PlaybackState.playing) return;
    
    try {
      await _controller?.pause();
      _state = PlaybackState.paused;
      
      // 停止进度追踪定时器
      _stopProgressTracking();
      
      // 更新最终位置
      if (_controller != null && _controller!.value.isInitialized) {
        _position = _controller!.value.position;
      }
      
      // 暂停时立即保存进度
      await _saveCurrentProgress(immediate: true);
      
      // 保存播放状态快照
      await _savePlaybackStateSnapshot();
      
      // 更新音频服务状态
      await _updateAudioService();
      
      notifyListeners();
    } catch (e) {
      debugPrint('MediaPlaybackService: 暂停失败 $e');
    }
  }

  /// 继续播放
  Future<void> resume() async {
    if (_state != PlaybackState.paused) return;
    
    try {
      await _controller?.play();
      _state = PlaybackState.playing;
      
      // 重新启动进度追踪定时器
      _startProgressTracking();
      
      // 更新音频服务状态
      await _updateAudioService();
      
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
      
      // 暂停时立即保存进度
      _saveCurrentProgress(immediate: true);
    }
    
    // 异步保存播放状态快照（不阻塞UI）
    _savePlaybackStateSnapshot().catchError((e) {
      debugPrint('保存播放状态快照失败: $e');
    });
    
    // 异步更新音频服务（不阻塞UI）
    _updateAudioService().catchError((e) {
      debugPrint('更新音频服务失败: $e');
    });
    
    // 通知监听器，触发 UI 更新
    notifyListeners();
  }

  /// 停止播放
  Future<void> stop() async {
    // 保存当前进度
    await _saveCurrentProgress(immediate: true);
    
    // 保存播放状态快照（停止状态）
    await _savePlaybackStateSnapshot();
    
    // 停止进度追踪
    _stopProgressTracking();
    
    // 停止音频服务
    await _audioSessionService?.stop();
    
    // 释放控制器
    await _disposeController();
    
    _state = PlaybackState.idle;
    _currentItem = null;
    _position = Duration.zero;
    _duration = Duration.zero;
    
    notifyListeners();
  }

  /// 跳转到指定位置
  Future<void> seekTo(Duration position) async {
    if (_controller == null || !_controller!.value.isInitialized) return;
    
    try {
      await _controller!.seekTo(position);
      _position = position;
      
      // 跳转后立即保存进度
      await _saveCurrentProgress(immediate: true);
      
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
    
    if (position >= duration && duration > Duration.zero && _state == PlaybackState.playing) {
      _onPlaybackCompleted();
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
    
    final position = _position;
    
    // 重置索引如果越界
    if (_lastSubtitleIndex >= _subtitles.length || 
        (_lastSubtitleIndex > 0 && position < _subtitles[_lastSubtitleIndex].startTime)) {
      _lastSubtitleIndex = 0;
    }
    
    SubtitleItem? foundSubtitle;
    
    // 从上次索引开始查找
    for (int i = _lastSubtitleIndex; i < _subtitles.length; i++) {
      final item = _subtitles[i];
      
      // 如果位置在字幕开始之前，停止查找
      if (position < item.startTime) break;
      
      // 计算有效结束时间（连续字幕：延伸到下一句开始）
      Duration effectiveEndTime = item.endTime;
      if (i + 1 < _subtitles.length) {
        effectiveEndTime = _subtitles[i + 1].startTime;
      }
      
      // 如果位置在有效时间范围内
      if (position < effectiveEndTime) {
        foundSubtitle = item;
        _lastSubtitleIndex = i;
        break;
      }
      
      _lastSubtitleIndex = i + 1;
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
      _saveCurrentProgress();
    });
    
    // 每100毫秒更新一次UI位置（确保实时同步）
    _positionUpdateTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      _updatePosition();
    });
    
    // 每1秒更新一次通知栏进度（避免过于频繁）
    _notificationUpdateTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _updateNotificationProgress();
    });
  }
  
  /// 停止进度追踪定时器
  void _stopProgressTracking() {
    _progressTimer?.cancel();
    _progressTimer = null;
    _positionUpdateTimer?.cancel();
    _positionUpdateTimer = null;
    _notificationUpdateTimer?.cancel();
    _notificationUpdateTimer = null;
  }
  
  /// 更新播放位置（用于实时UI同步）
  void _updatePosition() {
    if (_controller == null || !_controller!.value.isInitialized) return;
    if (_state != PlaybackState.playing) return;
    
    final newPosition = _controller!.value.position;
    final newDuration = _controller!.value.duration;
    
    // 只有当位置或时长发生变化时才通知监听器
    if (newPosition != _position || newDuration != _duration) {
      _position = newPosition;
      _duration = newDuration;
      
      // 更新当前字幕
      _updateCurrentSubtitle();
      
      // 检查是否播放结束
      if (_position >= _duration && _duration > Duration.zero) {
        _onPlaybackCompleted();
      }
      
      notifyListeners();
    }
  }
  
  /// 更新通知栏进度（每秒更新一次）
  void _updateNotificationProgress() {
    if (_audioSessionService == null || _currentItem == null) return;
    if (_state != PlaybackState.playing) return;
    
    try {
      _audioSessionService!.updatePlaybackState(
        playing: true,
        position: _position,
        duration: _duration,
      );
    } catch (e) {
      debugPrint('MediaPlaybackService: 更新通知栏进度失败 $e');
    }
  }
  
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
    _stopProgressTracking();
    _disposeController();
    super.dispose();
  }
  
  /// 更新音频服务的媒体信息和播放状态
  Future<void> _updateAudioService() async {
    if (_audioSessionService == null || _currentItem == null) return;
    
    try {
      // 设置播放队列（如果还没有设置）
      if (_playlistManager != null && _playlistManager!.playlist.isNotEmpty) {
        final currentIndex = _playlistManager!.currentIndex;
        final mediaInfoList = _playlistManager!.playlist.map((item) => MediaInfo(
          title: item.title,
          duration: Duration(milliseconds: item.durationMs),
          artworkPath: item.thumbnailPath,
        )).toList();
        
        await _audioSessionService!.setQueue(mediaInfoList, currentIndex);
      }
      
      // 更新媒体信息
      await _audioSessionService!.updateMediaInfo(
        MediaInfo(
          title: _currentItem!.title,
          duration: _duration,
          artworkPath: _currentItem!.thumbnailPath,
        ),
      );
      
      // 更新播放状态（包含时长信息）
      await _audioSessionService!.updatePlaybackState(
        playing: _state == PlaybackState.playing,
        position: _position,
        duration: _duration,
      );
      
      // 根据播放状态调用 play 或 pause
      if (_state == PlaybackState.playing) {
        await _audioSessionService!.play();
      } else if (_state == PlaybackState.paused) {
        await _audioSessionService!.pause();
      }
    } catch (e) {
      debugPrint('MediaPlaybackService: 更新音频服务失败 $e');
    }
  }
  
  /// 处理来自音频服务的媒体操作
  void _handleMediaAction(MediaActionEvent event) {
    switch (event.action) {
      case CustomMediaAction.play:
        resume();
        break;
      case CustomMediaAction.pause:
        pause();
        break;
      case CustomMediaAction.stop:
        stop();
        break;
      case CustomMediaAction.next:
        playNext();
        break;
      case CustomMediaAction.previous:
        playPrevious();
        break;
      case CustomMediaAction.seekTo:
        if (event.seekPosition != null) {
          seekTo(event.seekPosition!);
        }
        break;
    }
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
