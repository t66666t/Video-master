import 'dart:async';
import 'package:audio_service/audio_service.dart' as audio_service;
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'dart:io';
import 'package:window_manager/window_manager.dart';
import 'package:media_kit/media_kit.dart';
import 'package:video_player_app/features/youtube_download/services/yt_dlp_download_service.dart';
import 'package:video_player_app/platform/windows_video_player_media_kit.dart';
import 'screens/home_screen.dart';
import 'services/library_service.dart';
import 'services/settings_service.dart';
import 'services/transcription_manager.dart';
import 'services/batch_import_service.dart';
import 'services/embedded_subtitle_service.dart';
import 'services/bilibili/bilibili_download_service.dart';
import 'services/media_playback_service.dart';
import 'services/playlist_manager.dart';
import 'services/playback_navigation_service.dart';
import 'services/progress_tracker.dart';
import 'services/thumbnail_cache_service.dart';
import 'services/video_compose_manager.dart';
import 'services/system_media_session_service.dart';
import 'utils/app_toast.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  _configureImageCaches();

  // Initialize media_kit for Windows platform only
  // This replaces video_player_win with media_kit for better codec support
  // and smoother playback speed changes
  if (Platform.isWindows) {
    try {
      // Force Windows player instances to start with subtitle output disabled.
      debugPrint('MediaKit initialized successfully');

      WindowsVideoPlayerMediaKit.ensureInitialized();
      debugPrint('WindowsVideoPlayerMediaKit initialized successfully');
    } catch (e) {
      debugPrint('MediaKit initialization failed: $e');
      // Continue without MediaKit - will fall back to default video player
    }
  }

  // Initialize Services
  final settings = SettingsService();
  try {
    // 允许 SettingsService 初始化失败，避免阻塞启动
    await settings.init().timeout(const Duration(seconds: 2));
  } catch (e) {
    debugPrint('SettingsService init failed or timed out: $e');
  }

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
  ThumbnailCacheService().setMissingThumbnailResolver(
    (videoId) => library.ensureThumbnailForVideo(videoId),
  );
  // Start library initialization but don't await it to prevent blocking app startup
  // We capture the future to use it for playback restoration later
  final libraryInitFuture = library.init().catchError((e) {
    debugPrint('LibraryService init failed: $e');
  });

  final batch = BatchImportService();
  // Don't await batch import service initialization
  batch.init().catchError((e) {
    debugPrint('BatchImportService init failed: $e');
  });

  // Register Services
  final transcriptionManager = TranscriptionManager();
  try {
    await transcriptionManager.initialize().timeout(const Duration(seconds: 3));
  } catch (e) {
    debugPrint('TranscriptionManager init failed or timed out: $e');
  }
  final embeddedSubtitleService = EmbeddedSubtitleService();
  final bilibiliService = BilibiliDownloadService();
  final ytDlpService = YtDlpDownloadService();
  final videoComposeManager = VideoComposeManager();
  // Don't await bilibili service initialization
  bilibiliService.init().catchError((e) {
    debugPrint('BilibiliDownloadService init failed: $e');
  });
  ytDlpService.init().catchError((e) {
    debugPrint('YtDlpDownloadService init failed: $e');
  });

  // Initialize media playback services
  final playlistManager = PlaylistManager();
  playlistManager.initialize(libraryService: library);

  final progressTracker = ProgressTracker();
  progressTracker.initialize(libraryService: library);

  final mediaPlaybackService = MediaPlaybackService();
  await mediaPlaybackService.initialize(
    playlistManager: playlistManager,
    progressTracker: progressTracker,
    libraryService: library,
    embeddedSubtitleService: embeddedSubtitleService,
  );
  await SystemMediaSessionService.instance.initialize(
    playbackService: mediaPlaybackService,
    playlistManager: playlistManager,
  );

  // 恢复上次的播放状态 - 等待 library 初始化完成后执行
  // 这样既不会阻塞启动，又能保证有数据可恢复
  libraryInitFuture.then((_) {
    _restorePlaybackState(
      mediaPlaybackService: mediaPlaybackService,
      progressTracker: progressTracker,
      playlistManager: playlistManager,
      library: library,
    ).catchError((e) {
      debugPrint('恢复播放状态失败: $e');
    });
  });

  runZonedGuarded(
    () {
      runApp(
        MultiProvider(
          providers: [
            ChangeNotifierProvider.value(value: settings),
            ChangeNotifierProvider.value(value: library),
            ChangeNotifierProvider.value(value: transcriptionManager),
            ChangeNotifierProvider.value(value: batch),
            ChangeNotifierProvider.value(value: embeddedSubtitleService),
            ChangeNotifierProvider.value(value: bilibiliService),
            ChangeNotifierProvider.value(value: ytDlpService),
            ChangeNotifierProvider.value(value: videoComposeManager),
            ChangeNotifierProvider.value(value: playlistManager),
            ChangeNotifierProvider.value(value: mediaPlaybackService),
          ],
          child: MyApp(
            bilibiliService: bilibiliService,
            transcriptionManager: transcriptionManager,
          ),
        ),
      );
    },
    (error, stack) {
      debugPrint('Uncaught error: $error');
      debugPrint(stack.toString());
      unawaited(transcriptionManager.shutdown());
    },
  );
}

void _configureImageCaches() {
  final imageCache = PaintingBinding.instance.imageCache;
  final isDesktop = Platform.isWindows || Platform.isLinux || Platform.isMacOS;
  // Keep memory usage conservative to avoid OOM on Windows.
  // 768MB was far too aggressive for a media player that already uses
  // significant memory for video decoding.
  final targetImageEntryCount = isDesktop ? 600 : 350;
  final targetImageMemoryBytes = isDesktop
      ? 256 * 1024 * 1024
      : 128 * 1024 * 1024;
  if (imageCache.maximumSize < targetImageEntryCount) {
    imageCache.maximumSize = targetImageEntryCount;
  }
  if (imageCache.maximumSizeBytes < targetImageMemoryBytes) {
    imageCache.maximumSizeBytes = targetImageMemoryBytes;
  }

  final thumbnailCache = ThumbnailCacheService();
  final targetThumbnailEntryCount = isDesktop ? 800 : 400;
  if (thumbnailCache.maxCacheSize < targetThumbnailEntryCount) {
    thumbnailCache.setMaxCacheSize(targetThumbnailEntryCount);
  }
}

class RestartWidget extends StatefulWidget {
  final Widget child;

  const RestartWidget({super.key, required this.child});

  static void restartApp(BuildContext context) {
    context.findAncestorStateOfType<_RestartWidgetState>()?.restartApp();
  }

  @override
  State<RestartWidget> createState() => _RestartWidgetState();
}

class _RestartWidgetState extends State<RestartWidget> {
  Key key = UniqueKey();

  void restartApp() {
    setState(() {
      key = UniqueKey();
    });
  }

  @override
  Widget build(BuildContext context) {
    return KeyedSubtree(key: key, child: widget.child);
  }
}

class RefreshAppIntent extends Intent {
  const RefreshAppIntent();
}

class MyApp extends StatefulWidget {
  final BilibiliDownloadService bilibiliService;
  final TranscriptionManager transcriptionManager;

  const MyApp({
    super.key,
    required this.bilibiliService,
    required this.transcriptionManager,
  });

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> with WidgetsBindingObserver {
  bool _sessionThumbnailCacheCleared = false;
  StreamSubscription<bool>? _notificationClickedSubscription;
  bool _pendingNotificationPlaybackNavigation = false;

  bool _isForegroundState(AppLifecycleState? state) {
    return state == null ||
        state == AppLifecycleState.resumed ||
        state == AppLifecycleState.inactive;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    MediaPlaybackService().addListener(_handlePlaybackServiceChanged);
    MediaPlaybackService().handleAppLifecycleState(
      WidgetsBinding.instance.lifecycleState,
    );
    _notificationClickedSubscription = audio_service.AudioService
        .notificationClicked
        .listen(_handleNotificationClicked);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    MediaPlaybackService().handleAppLifecycleState(state);
    if (_isForegroundState(state) && MediaPlaybackService().currentItem != null) {
      unawaited(
        SystemMediaSessionService.instance.refreshNow(
          ensureNotificationVisible: true,
        ),
      );
    }
    if (state == AppLifecycleState.detached) {
      unawaited(widget.bilibiliService.shutdown());
      unawaited(widget.transcriptionManager.shutdown());
      unawaited(_cleanupSessionThumbnailCaches());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    MediaPlaybackService().removeListener(_handlePlaybackServiceChanged);
    unawaited(_notificationClickedSubscription?.cancel());
    _notificationClickedSubscription = null;
    unawaited(widget.bilibiliService.shutdown());
    unawaited(widget.transcriptionManager.shutdown());
    unawaited(_cleanupSessionThumbnailCaches());
    super.dispose();
  }

  void _handleNotificationClicked(bool clicked) {
    if (!clicked) {
      return;
    }
    _pendingNotificationPlaybackNavigation = true;
    unawaited(_openPlaybackFromNotificationIfReady());
  }

  void _handlePlaybackServiceChanged() {
    if (!_pendingNotificationPlaybackNavigation) {
      return;
    }
    unawaited(_openPlaybackFromNotificationIfReady());
  }

  Future<void> _openPlaybackFromNotificationIfReady() async {
    if (!_pendingNotificationPlaybackNavigation) {
      return;
    }

    final currentItem = MediaPlaybackService().currentItem;
    if (currentItem == null) {
      return;
    }

    _pendingNotificationPlaybackNavigation = false;
    await PlaybackNavigationService.instance.openPortraitFromNotification(
      currentItem,
    );
  }

  Future<void> _cleanupSessionThumbnailCaches() async {
    if (_sessionThumbnailCacheCleared) {
      return;
    }
    _sessionThumbnailCacheCleared = true;
    final thumbnailCache = ThumbnailCacheService();
    thumbnailCache.clearMemoryCache();
    final imageCache = PaintingBinding.instance.imageCache;
    imageCache.clear();
    imageCache.clearLiveImages();
  }

  @override
  Widget build(BuildContext context) {
    final isIOS = !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;
    final platformTextFontFamily = isIOS ? 'CupertinoSystemText' : 'MiSans';
    final platformDisplayFontFamily = isIOS
        ? 'CupertinoSystemDisplay'
        : platformTextFontFamily;
    final bodyFontWeight = isIOS ? FontWeight.w400 : FontWeight.w300;
    final titleFontWeight = isIOS ? FontWeight.w600 : FontWeight.w300;
    final labelFontWeight = isIOS ? FontWeight.w500 : FontWeight.w300;
    final baseTextTheme = ThemeData.dark(useMaterial3: true).textTheme;

    return RestartWidget(
      child: Shortcuts(
        shortcuts: <LogicalKeySet, Intent>{
          LogicalKeySet(LogicalKeyboardKey.f11): const ToggleFullScreenIntent(),
          LogicalKeySet(LogicalKeyboardKey.escape):
              const ExitFullScreenIntent(),
          LogicalKeySet(LogicalKeyboardKey.space): const VideoPlayPauseIntent(),
          LogicalKeySet(LogicalKeyboardKey.control, LogicalKeyboardKey.keyR):
              const RefreshAppIntent(),
        },
        child: Actions(
          actions: <Type, Action<Intent>>{
            ToggleFullScreenIntent: CallbackAction<ToggleFullScreenIntent>(
              onInvoke: (intent) => Provider.of<SettingsService>(
                context,
                listen: false,
              ).toggleFullScreen(),
            ),
            ExitFullScreenIntent: CallbackAction<ExitFullScreenIntent>(
              onInvoke: (intent) {
                final settings = Provider.of<SettingsService>(
                  context,
                  listen: false,
                );
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
            RefreshAppIntent: CallbackAction<RefreshAppIntent>(
              onInvoke: (intent) {
                RestartWidget.restartApp(context);
                AppToast.show("正在刷新应用...", type: AppToastType.info);
                return null;
              },
            ),
          },
          child: MaterialApp(
            title: 'Fluent_Player',
            debugShowCheckedModeBanner: false,
            navigatorKey: AppToast.navigatorKey,
            navigatorObservers: [
              AppToast.observer,
              AppToast.routeObserver,
              PlaybackNavigationService.instance.observer,
            ],
            theme: ThemeData(
              brightness: Brightness.dark,
              primarySwatch: Colors.blue,
              scaffoldBackgroundColor: const Color(0xFF121212),
              typography: Typography.material2021(
                platform: isIOS ? TargetPlatform.iOS : defaultTargetPlatform,
              ),
              fontFamily: platformTextFontFamily,
              textTheme: baseTextTheme
                  .apply(
                    bodyColor: Colors.white,
                    displayColor: Colors.white,
                    fontFamily: platformTextFontFamily,
                  )
                  .copyWith(
                    displayLarge: baseTextTheme.displayLarge?.copyWith(
                      fontFamily: platformDisplayFontFamily,
                    ),
                    displayMedium: baseTextTheme.displayMedium?.copyWith(
                      fontFamily: platformDisplayFontFamily,
                    ),
                    displaySmall: baseTextTheme.displaySmall?.copyWith(
                      fontFamily: platformDisplayFontFamily,
                    ),
                    headlineLarge: baseTextTheme.headlineLarge?.copyWith(
                      fontFamily: platformDisplayFontFamily,
                    ),
                    headlineMedium: baseTextTheme.headlineMedium?.copyWith(
                      fontFamily: platformDisplayFontFamily,
                    ),
                    headlineSmall: baseTextTheme.headlineSmall?.copyWith(
                      fontFamily: platformDisplayFontFamily,
                    ),
                    bodyLarge: TextStyle(fontWeight: bodyFontWeight),
                    bodyMedium: TextStyle(fontWeight: bodyFontWeight),
                    bodySmall: TextStyle(fontWeight: bodyFontWeight),
                    titleLarge: TextStyle(
                      fontWeight: titleFontWeight,
                      fontFamily: platformDisplayFontFamily,
                    ),
                    titleMedium: TextStyle(
                      fontWeight: titleFontWeight,
                      fontFamily: platformDisplayFontFamily,
                    ),
                    titleSmall: TextStyle(
                      fontWeight: titleFontWeight,
                      fontFamily: platformDisplayFontFamily,
                    ),
                    labelLarge: TextStyle(fontWeight: labelFontWeight),
                    labelMedium: TextStyle(fontWeight: labelFontWeight),
                    labelSmall: TextStyle(fontWeight: labelFontWeight),
                  ),
              cupertinoOverrideTheme: isIOS
                  ? const CupertinoThemeData(brightness: Brightness.dark)
                  : null,
              colorScheme: const ColorScheme.dark(
                primary: Colors.blue,
                surface: Color(0xFF121212),
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
    var positionMs = snapshot.positionMs;
    if (videoItem.lastPositionMs > 0 &&
        videoItem.lastUpdated > snapshot.timestamp) {
      positionMs = videoItem.lastPositionMs;
    }
    final position = Duration(milliseconds: positionMs);

    // 播放媒体，但立即暂停（不自动播放）
    // 强制 autoPlay: false，确保启动时不自动播放，无论上次退出时状态如何
    await mediaPlaybackService.play(
      videoItem,
      startPosition: position,
      autoPlay: false,
    );
    await SystemMediaSessionService.instance.refreshNow(
      ensureNotificationVisible: true,
    );

    debugPrint('成功恢复播放状态: ${videoItem.title} at ${position.inSeconds}s');
  } catch (e) {
    debugPrint('恢复播放状态失败: $e');
    // 静默处理错误，不影响应用启动
  }
}
