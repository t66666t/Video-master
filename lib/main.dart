import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'dart:io';
import 'package:window_manager/window_manager.dart';
import 'package:media_kit/media_kit.dart';
import 'package:video_player_media_kit/video_player_media_kit.dart';
import 'screens/home_screen.dart';
import 'services/library_service.dart';
import 'services/settings_service.dart';
import 'services/transcription_manager.dart';
import 'services/batch_import_service.dart';
import 'services/embedded_subtitle_service.dart';
import 'services/bilibili/bilibili_download_service.dart';
import 'services/media_playback_service.dart';
import 'services/playlist_manager.dart';
import 'services/progress_tracker.dart';
import 'services/audio_session_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize media_kit for Windows platform only
  // This replaces video_player_win with media_kit for better codec support
  // and smoother playback speed changes
  if (Platform.isWindows) {
    try {
      // Create or modify mpv.conf file to disable subtitles
      final appData = Platform.environment['APPDATA'];
      if (appData != null) {
        final mpvDir = Directory('$appData\\mpv');
        if (!mpvDir.existsSync()) {
          mpvDir.createSync(recursive: true);
        }
        final mpvConf = File('$appData\\mpv\\mpv.conf');
        final lines = <String>[];
        if (mpvConf.existsSync()) {
          lines.addAll(mpvConf.readAsLinesSync());
        }
        // Add or update subtitle settings
        final subAutoIndex = lines.indexWhere((line) => line.startsWith('sub-auto='));
        if (subAutoIndex >= 0) {
          lines[subAutoIndex] = 'sub-auto=no';
        } else {
          lines.add('sub-auto=no');
        }
        final subVisibilityIndex = lines.indexWhere((line) => line.startsWith('sub-visibility='));
        if (subVisibilityIndex >= 0) {
          lines[subVisibilityIndex] = 'sub-visibility=no';
        } else {
          lines.add('sub-visibility=no');
        }
        final sidIndex = lines.indexWhere((line) => line.startsWith('sid='));
        if (sidIndex >= 0) {
          lines[sidIndex] = 'sid=no';
        } else {
          lines.add('sid=no');
        }
        final secondarySidIndex = lines.indexWhere((line) => line.startsWith('secondary-sid='));
        if (secondarySidIndex >= 0) {
          lines[secondarySidIndex] = 'secondary-sid=no';
        } else {
          lines.add('secondary-sid=no');
        }
        final noSubIndex = lines.indexWhere((line) => line.startsWith('no-sub'));
        if (noSubIndex >= 0) {
          lines[noSubIndex] = 'no-sub';
        } else {
          lines.add('no-sub');
        }
        mpvConf.writeAsStringSync(lines.join('\n'));
      }
      
      // Initialize media_kit with error handling
      MediaKit.ensureInitialized();
      debugPrint('MediaKit initialized successfully');
      
      VideoPlayerMediaKit.ensureInitialized(
        android: false,  // Keep using ExoPlayer on Android
        iOS: false,      // Keep using AVPlayer on iOS
        macOS: false,    // Keep using AVPlayer on macOS
        windows: true,   // Use media_kit on Windows
        linux: true,     // Use media_kit on Linux (if needed)
      );
      debugPrint('VideoPlayerMediaKit initialized successfully');
    } catch (e) {
      debugPrint('MediaKit initialization failed: $e');
      // Continue without MediaKit - will fall back to default video player
    }
  }

  // Initialize Services
  final settings = SettingsService();
  await settings.init();

  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    await windowManager.ensureInitialized();
    
    WindowOptions windowOptions = const WindowOptions(
      size: Size(1280, 720),
      center: true,
      backgroundColor: Colors.transparent,
      skipTaskbar: false,
      titleBarStyle: TitleBarStyle.normal,
    );
    
    await windowManager.waitUntilReadyToShow(windowOptions, () async {
      await windowManager.show();
      await windowManager.maximize();
      await windowManager.focus();
    });
  }
  
  final library = LibraryService();
  await library.init();
  
  final batch = BatchImportService();
  await batch.init();
  
  // Register Services
  final transcriptionManager = TranscriptionManager();
  final embeddedSubtitleService = EmbeddedSubtitleService();
  final bilibiliService = BilibiliDownloadService();
  await bilibiliService.init();

  // Initialize media playback services
  final playlistManager = PlaylistManager();
  playlistManager.initialize(libraryService: library);
  
  final progressTracker = ProgressTracker();
  progressTracker.initialize(libraryService: library);
  
  // Initialize audio session service (for background playback) - Only on Android
  AudioSessionService? audioSessionService;
  if (Platform.isAndroid) {
    audioSessionService = AudioSessionService();
    try {
      await audioSessionService.init();
    } catch (e) {
      debugPrint('AudioSessionService 初始化失败，后台播放功能将不可用: $e');
    }
  }
  
  final mediaPlaybackService = MediaPlaybackService();
  mediaPlaybackService.initialize(
    playlistManager: playlistManager,
    progressTracker: progressTracker,
    audioSessionService: audioSessionService,
  );

  // 恢复上次的播放状态 - 改为非阻塞方式,避免卡住应用启动
  // 使用unawaited让它在后台执行
  _restorePlaybackState(
    mediaPlaybackService: mediaPlaybackService,
    progressTracker: progressTracker,
    playlistManager: playlistManager,
    library: library,
  ).catchError((e) {
    debugPrint('恢复播放状态失败: $e');
  });

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: settings),
        ChangeNotifierProvider.value(value: library),
        ChangeNotifierProvider.value(value: transcriptionManager),
        ChangeNotifierProvider.value(value: batch),
        ChangeNotifierProvider.value(value: embeddedSubtitleService),
        ChangeNotifierProvider.value(value: bilibiliService),
        ChangeNotifierProvider.value(value: playlistManager),
        ChangeNotifierProvider.value(value: mediaPlaybackService),
      ],
      child: const MyApp(),
    ),
  );
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return Shortcuts(
      shortcuts: <LogicalKeySet, Intent>{
        LogicalKeySet(LogicalKeyboardKey.f11): const ToggleFullScreenIntent(),
        LogicalKeySet(LogicalKeyboardKey.escape): const ExitFullScreenIntent(),
        LogicalKeySet(LogicalKeyboardKey.space): const VideoPlayPauseIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          ToggleFullScreenIntent: CallbackAction<ToggleFullScreenIntent>(
            onInvoke: (intent) => Provider.of<SettingsService>(context, listen: false).toggleFullScreen(),
          ),
          ExitFullScreenIntent: CallbackAction<ExitFullScreenIntent>(
            onInvoke: (intent) {
              final settings = Provider.of<SettingsService>(context, listen: false);
              if (settings.isFullScreen) {
                settings.toggleFullScreen();
              }
              return null;
            },
          ),
          VideoPlayPauseIntent: CallbackAction<VideoPlayPauseIntent>(
            onInvoke: (intent) {
              // This is a fallback. Real logic is in VideoControlsOverlay.
              // We only need this if focus is completely lost.
              return null;
            },
          ),
        },
        child: MaterialApp(
          title: 'Custom Video Player',
          debugShowCheckedModeBanner: false,
          theme: ThemeData(
            brightness: Brightness.dark,
            primarySwatch: Colors.blue,
            scaffoldBackgroundColor: const Color(0xFF121212),
            fontFamily: 'MiSans',
            textTheme: const TextTheme().apply(bodyColor: Colors.white, displayColor: Colors.white, fontFamily: 'MiSans').copyWith(
                bodyLarge: const TextStyle(fontWeight: FontWeight.w300),
                bodyMedium: const TextStyle(fontWeight: FontWeight.w300),
                bodySmall: const TextStyle(fontWeight: FontWeight.w300),
                titleLarge: const TextStyle(fontWeight: FontWeight.w300),
                titleMedium: const TextStyle(fontWeight: FontWeight.w300),
                titleSmall: const TextStyle(fontWeight: FontWeight.w300),
                labelLarge: const TextStyle(fontWeight: FontWeight.w300),
                labelMedium: const TextStyle(fontWeight: FontWeight.w300),
                labelSmall: const TextStyle(fontWeight: FontWeight.w300),
              ),
            colorScheme: const ColorScheme.dark(
              primary: Colors.blue,
              surface: Color(0xFF121212),
              background: Color(0xFF121212),
            ),
            useMaterial3: true,
            appBarTheme: const AppBarTheme(
              backgroundColor: Color(0xFF1E1E1E),
              elevation: 0,
            ),
          ),
          home: const HomeScreen(),
        ),
      ),
    );
  }
}

class ExitFullScreenIntent extends Intent {
  const ExitFullScreenIntent();
}

class ToggleFullScreenIntent extends Intent {
  const ToggleFullScreenIntent();
}

class VideoPlayPauseIntent extends Intent {
  const VideoPlayPauseIntent();
}

/// 恢复上次的播放状态
Future<void> _restorePlaybackState({
  required MediaPlaybackService mediaPlaybackService,
  required ProgressTracker progressTracker,
  required PlaylistManager playlistManager,
  required LibraryService library,
}) async {
  try {
    // 从 ProgressTracker 恢复播放状态快照
    final snapshot = await progressTracker.restorePlaybackState();
    
    if (snapshot == null || snapshot.currentItemId == null) {
      debugPrint('没有需要恢复的播放状态');
      return;
    }
    
    // 获取上次播放的媒体项
    final videoItem = library.getVideo(snapshot.currentItemId!);
    if (videoItem == null) {
      debugPrint('上次播放的媒体项不存在: ${snapshot.currentItemId}');
      return;
    }
    
    // 恢复播放列表
    if (snapshot.playlistFolderId != null) {
      playlistManager.loadFolderPlaylist(
        snapshot.playlistFolderId,
        snapshot.currentItemId!,
      );
    } else {
      // 如果没有文件夹ID，使用媒体项的父文件夹
      playlistManager.loadFolderPlaylist(
        videoItem.parentId,
        snapshot.currentItemId!,
      );
    }
    
    // 恢复播放位置
    final position = Duration(milliseconds: snapshot.positionMs);
    
    // 播放媒体，但立即暂停（不自动播放）
    await mediaPlaybackService.play(videoItem, startPosition: position);
    
    // 如果上次不是播放状态，暂停播放
    if (!snapshot.wasPlaying) {
      await mediaPlaybackService.pause();
    }
    
    debugPrint('成功恢复播放状态: ${videoItem.title} at ${position.inSeconds}s');
  } catch (e) {
    debugPrint('恢复播放状态失败: $e');
    // 静默处理错误，不影响应用启动
  }
}
