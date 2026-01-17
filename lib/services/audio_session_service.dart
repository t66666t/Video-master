import 'dart:async';
import 'dart:io';
import 'package:audio_service/audio_service.dart' as audio_service;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart'; // 引入 Material 库以使用 Color
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

/// 媒体信息
class MediaInfo {
  final String title;
  final String? artist;
  final String? album;
  final String? artworkPath;
  final Duration duration;

  MediaInfo({
    required this.title,
    this.artist,
    this.album,
    this.artworkPath,
    required this.duration,
  });
}

/// 媒体操作枚举
enum CustomMediaAction {
  play,
  pause,
  stop,
  next,
  previous,
  seekTo,
}

/// 媒体操作事件
class MediaActionEvent {
  final CustomMediaAction action;
  final Duration? seekPosition;

  MediaActionEvent(this.action, {this.seekPosition});
}

/// 音频会话服务 - 处理后台播放和系统控制
class AudioSessionService {
  static final AudioSessionService _instance = AudioSessionService._internal();
  factory AudioSessionService() => _instance;
  AudioSessionService._internal();

  audio_service.AudioHandler? _audioHandler;
  final StreamController<MediaActionEvent> _actionController = StreamController<MediaActionEvent>.broadcast();

  /// 媒体操作流
  Stream<MediaActionEvent> get mediaActions => _actionController.stream;

  /// 生成 FileProvider URI
  Future<Uri?> _generateFileProviderUri(String? filePath) async {
    if (filePath == null || filePath.isEmpty) return null;
    
    try {
      final file = File(filePath);
      if (!file.existsSync()) return null;
      
      final packageName = 'com.example.video_player_app';
      
      final tempDir = await getTemporaryDirectory();
      final cacheDir = await getTemporaryDirectory();
      final appSupportDir = await getApplicationSupportDirectory();
      final appDocDir = await getApplicationDocumentsDirectory();
      
      String contentPath;
      
      if (filePath.startsWith(tempDir.path)) {
        final relativePath = path.relative(filePath, from: tempDir.path);
        contentPath = 'cache/$relativePath';
      } else if (filePath.startsWith(cacheDir.path)) {
        final relativePath = path.relative(filePath, from: cacheDir.path);
        contentPath = 'cache/$relativePath';
      } else if (filePath.startsWith(appSupportDir.path)) {
        final relativePath = path.relative(filePath, from: appSupportDir.path);
        contentPath = 'files/$relativePath';
      } else if (filePath.startsWith(appDocDir.path)) {
        final relativePath = path.relative(filePath, from: appDocDir.path);
        contentPath = 'files/$relativePath';
      } else {
        final fileName = path.basename(filePath);
        contentPath = 'cache/$fileName';
      }
      
      return Uri.parse('content://$packageName.fileprovider/$contentPath');
    } catch (e) {
      debugPrint('AudioSessionService: 生成 FileProvider URI 失败 $e');
      return null;
    }
  }

  /// 初始化音频会话
  Future<void> init() async {
    try {
      _audioHandler = await audio_service.AudioService.init(
        builder: () => _MediaPlaybackHandler(_actionController),
        config: audio_service.AudioServiceConfig(
          androidNotificationChannelId: 'com.example.video_player_app.channel.audio',
          androidNotificationChannelName: '媒体播放',
          androidNotificationChannelDescription: '控制视频和音频播放',
          androidNotificationOngoing: true,
          androidStopForegroundOnPause: true, // 确保暂停时移除前台服务，但保留通知
          androidNotificationClickStartsActivity: true,
          androidNotificationIcon: 'mipmap/ic_launcher', // 使用应用图标作为通知图标，确保兼容性
          androidShowNotificationBadge: true,
          androidResumeOnClick: true,
          // 确保媒体会话处于活跃状态
          notificationColor: const Color(0xFF2196F3),
        ),
      );
      debugPrint('AudioSessionService: 初始化成功');
    } catch (e) {
      debugPrint('AudioSessionService: 初始化失败 $e');
      rethrow;
    }
  }

  /// 设置播放队列
  Future<void> setQueue(List<MediaInfo> items, int initialIndex) async {
    if (_audioHandler == null) return;

    try {
      final mediaItems = <audio_service.MediaItem>[];
      
      for (var i = 0; i < items.length; i++) {
        final item = items[i];
        final artUri = await _generateFileProviderUri(item.artworkPath);
        
        final mediaItem = audio_service.MediaItem(
          id: item.title,
          title: item.title,
          artist: item.artist ?? '视频播放器',
          album: item.album ?? '本地媒体',
          duration: item.duration,
          artUri: artUri,
          extras: {
            'artworkPath': item.artworkPath ?? '',
          },
        );
        
        mediaItems.add(mediaItem);
      }

      // 使用 addQueueItem 方法逐个添加到队列
      for (var i = 0; i < mediaItems.length; i++) {
        await _audioHandler!.addQueueItem(mediaItems[i]);
      }
      
      // 跳转到初始索引
      if (initialIndex >= 0 && initialIndex < mediaItems.length) {
        await _audioHandler!.skipToQueueItem(initialIndex);
      }
      
      debugPrint('AudioSessionService: 设置播放队列，共 ${items.length} 项，初始索引: $initialIndex');
    } catch (e) {
      debugPrint('AudioSessionService: 设置播放队列失败 $e');
    }
  }

  /// 更新媒体信息
  Future<void> updateMediaInfo(MediaInfo info) async {
    if (_audioHandler == null) return;

    try {
      Uri? artUri = await _generateFileProviderUri(info.artworkPath);
      
      final mediaItem = audio_service.MediaItem(
        id: info.title,
        title: info.title,
        artist: info.artist ?? '视频播放器',
        album: info.album ?? '本地媒体',
        duration: info.duration,
        artUri: artUri,
        extras: {
          'artworkPath': info.artworkPath ?? '',
        },
      );

      await _audioHandler!.updateMediaItem(mediaItem);
      debugPrint('AudioSessionService: 更新媒体信息 ${info.title}, 缩略图: ${info.artworkPath}, URI: $artUri');
    } catch (e) {
      debugPrint('AudioSessionService: 更新媒体信息失败 $e');
    }
  }

  /// 更新播放状态
  Future<void> updatePlaybackState({
    required bool playing,
    required Duration position,
    Duration? duration,
    double? speed,
  }) async {
    if (_audioHandler == null) return;

    try {
      final controls = <audio_service.MediaControl>[
        audio_service.MediaControl.skipToPrevious,
        playing ? audio_service.MediaControl.pause : audio_service.MediaControl.play,
        audio_service.MediaControl.skipToNext,
        audio_service.MediaControl.stop,
      ];
      
      final systemActions = <audio_service.MediaAction>{
        audio_service.MediaAction.seek,
        audio_service.MediaAction.play,
        audio_service.MediaAction.pause,
        audio_service.MediaAction.stop,
        audio_service.MediaAction.skipToNext,
        audio_service.MediaAction.skipToPrevious,
        audio_service.MediaAction.playPause,
      };
      
      final state = audio_service.PlaybackState(
        controls: controls,
        androidCompactActionIndices: const [0, 1, 2],
        systemActions: systemActions,
        processingState: audio_service.AudioProcessingState.ready,
        playing: playing,
        updatePosition: position,
        bufferedPosition: duration ?? position,
        speed: speed ?? 1.0,
        queueIndex: 0,
        repeatMode: audio_service.AudioServiceRepeatMode.none,
        shuffleMode: audio_service.AudioServiceShuffleMode.none,
      );
      
      (_audioHandler!.playbackState as dynamic).add(state);
      
      debugPrint('AudioSessionService: 更新播放状态 playing=$playing, position=${position.inSeconds}s, duration=${duration?.inSeconds}s');
    } catch (e) {
      debugPrint('AudioSessionService: 更新播放状态失败 $e');
    }
  }

  /// 播放
  Future<void> play() async {
    if (_audioHandler == null) return;
    try {
      await _audioHandler!.play();
      debugPrint('AudioSessionService: 播放');
    } catch (e) {
      debugPrint('AudioSessionService: 播放失败 $e');
    }
  }

  /// 暂停
  Future<void> pause() async {
    if (_audioHandler == null) return;
    try {
      await _audioHandler!.pause();
      debugPrint('AudioSessionService: 暂停');
    } catch (e) {
      debugPrint('AudioSessionService: 暂停失败 $e');
    }
  }

  /// 停止
  Future<void> stop() async {
    if (_audioHandler == null) return;
    try {
      await _audioHandler!.stop();
      debugPrint('AudioSessionService: 停止');
    } catch (e) {
      debugPrint('AudioSessionService: 停止失败 $e');
    }
  }

  void dispose() {
    _actionController.close();
  }
}

/// 媒体播放处理器
class _MediaPlaybackHandler extends audio_service.BaseAudioHandler {
  final StreamController<MediaActionEvent> _actionController;

  _MediaPlaybackHandler(this._actionController);

  @override
  Future<void> play() async {
    _actionController.add(MediaActionEvent(CustomMediaAction.play));
  }

  @override
  Future<void> pause() async {
    _actionController.add(MediaActionEvent(CustomMediaAction.pause));
  }

  @override
  Future<void> stop() async {
    _actionController.add(MediaActionEvent(CustomMediaAction.stop));
  }

  @override
  Future<void> skipToNext() async {
    _actionController.add(MediaActionEvent(CustomMediaAction.next));
  }

  @override
  Future<void> skipToPrevious() async {
    _actionController.add(MediaActionEvent(CustomMediaAction.previous));
  }

  @override
  Future<void> seek(Duration position) async {
    _actionController.add(MediaActionEvent(CustomMediaAction.seekTo, seekPosition: position));
  }
}
