import 'dart:async';
import 'package:audio_service/audio_service.dart' as audio_service;
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'dart:io';
import 'package:window_manager/window_manager.dart';
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
import 'services/ocr_subtitle_manager.dart';
import 'services/system_media_session_service.dart';
import 'utils/app_toast.dart';
import 'widgets/library_persistence_notification_bridge.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  _configureImageCaches();

  // Create a stable provider graph synchronously. Disk-backed and plugin
  // initialization starts only after the lightweight startup frame is visible.
  final settings = SettingsService();
  final library = LibraryService();
  ThumbnailCacheService().setMissingThumbnailResolver(
    (videoId) => library.ensureThumbnailForVideo(videoId),
  );
  final batch = BatchImportService();

  // Register Services
  final transcriptionManager = TranscriptionManager();
  final embeddedSubtitleService = EmbeddedSubtitleService();
  final bilibiliService = BilibiliDownloadService();
  final ytDlpService = YtDlpDownloadService();
  final videoComposeManager = VideoComposeManager();
  final ocrSubtitleManager = OcrSubtitleManager(library: library);

  // Initialize media playback services
  final playlistManager = PlaylistManager();
  playlistManager.initialize(libraryService: library);

  final progressTracker = ProgressTracker();
  progressTracker.initialize(libraryService: library);

  final mediaPlaybackService = MediaPlaybackService();
  final deferredServicesReady = Completer<void>();

  // 恢复上次的播放状态 - 等待 library 初始化完成后执行
  // 这样既不会阻塞启动，又能保证有数据可恢复
  deferredServicesReady.future.then((_) {
    _restorePlaybackState(
      mediaPlaybackService: mediaPlaybackService,
      progressTracker: progressTracker,
      playlistManager: playlistManager,
      library: library,
    ).catchError((e) {
      debugPrint('恢复播放状态失败: $e');
    });
  });

  // 初始化崩溃日志路径，供 FlutterError.onError 和 runZonedGuarded 使用。
  // 必须在 runZonedGuarded 之前完成，确保错误处理器可用。
  unawaited(_initCrashLogPath());

  // 捕获框架级异常（渲染/布局/Widget 错误）。
  // runZonedGuarded 无法捕获此类异常，需单独处理，否则直接导致崩溃无日志。
  FlutterError.onError = (FlutterErrorDetails details) {
    FlutterError.presentError(details);
    _writeCrashLog(
      '[FlutterError] ${details.exception}\n${details.stack ?? ''}',
    );
  };

  Future<void> initializeStartupServices() => _initializeStartupServices(
    settings: settings,
    mediaPlaybackService: mediaPlaybackService,
    playlistManager: playlistManager,
    progressTracker: progressTracker,
    library: library,
    embeddedSubtitleService: embeddedSubtitleService,
  );

  // Android already owns a native launch surface. Keep that single cover on
  // screen until the core state is ready, so the first Flutter frame is the
  // real home page instead of a second, differently scaled copy of the logo.
  final useNativeAndroidLaunchSurface = Platform.isAndroid;
  if (useNativeAndroidLaunchSurface) {
    await initializeStartupServices();
  }

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
            ChangeNotifierProvider.value(value: ocrSubtitleManager),
            ChangeNotifierProvider.value(value: playlistManager),
            ChangeNotifierProvider.value(value: mediaPlaybackService),
          ],
          child: AppStartupGate(
            initialize: initializeStartupServices,
            initiallyReady: useNativeAndroidLaunchSurface,
            onReadyFirstFrame: () {
              unawaited(
                _initializeDeferredServices(
                  library: library,
                  batch: batch,
                  transcriptionManager: transcriptionManager,
                  ocrSubtitleManager: ocrSubtitleManager,
                  bilibiliService: bilibiliService,
                  ytDlpService: ytDlpService,
                  mediaPlaybackService: mediaPlaybackService,
                  playlistManager: playlistManager,
                ).whenComplete(() {
                  if (!deferredServicesReady.isCompleted) {
                    deferredServicesReady.complete();
                  }
                }),
              );
            },
            child: MyApp(
              bilibiliService: bilibiliService,
              transcriptionManager: transcriptionManager,
            ),
          ),
        ),
      );
    },
    (error, stack) {
      debugPrint('Uncaught error: $error');
      debugPrint(stack.toString());
      _writeCrashLog('[ZoneError] $error\n$stack');
      unawaited(transcriptionManager.shutdown());
    },
  );
}

Future<void> _initializeStartupServices({
  required SettingsService settings,
  required MediaPlaybackService mediaPlaybackService,
  required PlaylistManager playlistManager,
  required ProgressTracker progressTracker,
  required LibraryService library,
  required EmbeddedSubtitleService embeddedSubtitleService,
}) async {
  Future<void> safely(String name, Future<void> Function() operation) async {
    try {
      await operation();
    } catch (e) {
      debugPrint('$name init failed: $e');
    }
  }

  // Window setup is independent of persisted settings, so it can run in
  // parallel. This function starts after the startup frame, which prevents
  // show() from exposing an unpainted Flutter view.
  final desktopWindowFuture = safely(
    'Desktop window',
    _initializeDesktopWindow,
  );

  await safely(
    'SettingsService',
    () => settings.init().timeout(const Duration(seconds: 2)),
  );

  // Preserve the original dependency order: playback reads persisted mute
  // state only after settings have had an opportunity to load.
  await safely(
    'MediaPlaybackService',
    () => mediaPlaybackService.initialize(
      playlistManager: playlistManager,
      progressTracker: progressTracker,
      libraryService: library,
      embeddedSubtitleService: embeddedSubtitleService,
    ),
  );

  await desktopWindowFuture;
}

Future<void> _initializeDesktopWindow() async {
  if (!(Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
    return;
  }

  await windowManager.ensureInitialized();

  const windowOptions = WindowOptions(
    size: Size(1280, 720),
    center: true,
    backgroundColor: Color(0xFF121212),
    skipTaskbar: false,
    titleBarStyle: TitleBarStyle.normal,
  );

  await windowManager.waitUntilReadyToShow(windowOptions, () async {
    await windowManager.show();
    await windowManager.maximize();
    await windowManager.focus();
  });
}

/// Paints a minimal first frame before any plugin or disk-backed startup work.
///
/// The real application is mounted only after its existing startup dependencies
/// are ready, so users cannot interact with partially initialized services.
@visibleForTesting
class AppStartupGate extends StatefulWidget {
  const AppStartupGate({
    super.key,
    required this.initialize,
    required this.onReadyFirstFrame,
    required this.child,
    this.initiallyReady = false,
  });

  final Future<void> Function() initialize;
  final VoidCallback onReadyFirstFrame;
  final Widget child;
  final bool initiallyReady;

  @override
  State<AppStartupGate> createState() => _AppStartupGateState();
}

class _AppStartupGateState extends State<AppStartupGate> {
  late bool _isReady;
  bool _initializationStarted = false;
  bool _readyFirstFrameReported = false;

  @override
  void initState() {
    super.initState();
    _isReady = widget.initiallyReady;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_isReady) {
        _reportReadyFirstFrame();
        return;
      }
      if (_initializationStarted) return;
      _initializationStarted = true;
      unawaited(_initialize());
    });
  }

  Future<void> _initialize() async {
    try {
      await widget.initialize();
    } catch (e, stack) {
      debugPrint('App startup initialization failed: $e');
      debugPrintStack(stackTrace: stack);
    }

    if (!mounted) return;
    setState(() => _isReady = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _reportReadyFirstFrame();
    });
  }

  void _reportReadyFirstFrame() {
    if (_readyFirstFrameReported) return;
    _readyFirstFrameReported = true;
    widget.onReadyFirstFrame();
  }

  @override
  Widget build(BuildContext context) {
    if (_isReady) return widget.child;
    return const _StartupSurface();
  }
}

class _StartupSurface extends StatelessWidget {
  const _StartupSurface();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Fluent Player',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF121212),
        colorScheme: const ColorScheme.dark(primary: Color(0xFF6EA8FF)),
      ),
      home: Scaffold(
        body: Center(
          child: Semantics(
            image: true,
            label: 'Fluent Player',
            child: Image.asset(
              'android/app/src/main/res/mipmap-xxxhdpi/launcher_icon.png',
              key: const ValueKey<String>('startup-cover'),
              width: 112,
              height: 112,
              fit: BoxFit.contain,
              filterQuality: FilterQuality.medium,
              gaplessPlayback: true,
            ),
          ),
        ),
      ),
    );
  }
}

Future<void> _initializeDeferredServices({
  required LibraryService library,
  required BatchImportService batch,
  required TranscriptionManager transcriptionManager,
  required OcrSubtitleManager ocrSubtitleManager,
  required BilibiliDownloadService bilibiliService,
  required YtDlpDownloadService ytDlpService,
  required MediaPlaybackService mediaPlaybackService,
  required PlaylistManager playlistManager,
}) async {
  Future<void> safely(String name, Future<void> Function() operation) async {
    try {
      await operation();
    } catch (e) {
      debugPrint('$name init failed: $e');
    }
  }

  // Native codec discovery and video_player registration can load shared
  // libraries. Do it after the first frame, but before library restoration can
  // create any player controller.
  try {
    NativeVideoPlayerMediaKit.ensureInitialized();
    debugPrint('Cross-platform MediaKit video backend initialized');
  } catch (e) {
    debugPrint('Cross-platform MediaKit initialization failed: $e');
  }

  final libraryFuture = safely('LibraryService', library.init);
  final mediaSessionFuture = safely(
    'SystemMediaSessionService',
    () => SystemMediaSessionService.instance.initialize(
      playbackService: mediaPlaybackService,
      playlistManager: playlistManager,
    ),
  );

  unawaited(safely('BatchImportService', batch.init));
  unawaited(safely('TranscriptionManager', transcriptionManager.initialize));
  unawaited(safely('OcrSubtitleManager', ocrSubtitleManager.initialize));
  unawaited(safely('BilibiliDownloadService', bilibiliService.init));
  unawaited(safely('YtDlpDownloadService', ytDlpService.init));

  // Playback restoration needs the library and Android media session, but
  // neither is allowed to delay the first Flutter frame.
  await Future.wait<void>(<Future<void>>[libraryFuture, mediaSessionFuture]);
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

/// 崩溃日志文件路径，由 [_initCrashLogPath] 初始化。
String? _crashLogPath;

/// 初始化崩溃日志路径。
///
/// 在 [main] 早期调用，确保后续错误处理器可用。路径获取失败时静默处理，
/// 仅丢失日志能力，不影响应用启动。
Future<void> _initCrashLogPath() async {
  try {
    final dir = await getApplicationSupportDirectory();
    _crashLogPath = p.join(dir.path, 'crash_log.txt');
  } catch (e) {
    debugPrint('初始化崩溃日志路径失败: $e');
  }
}

/// 将崩溃信息写入日志文件（追加模式）。
///
/// 日志文件限制为 1MB，超出时清空重写，避免无限增长。
/// 写入失败时静默处理，防止日志机制本身导致二次崩溃。
void _writeCrashLog(String message) {
  if (_crashLogPath == null) return;
  try {
    final file = File(_crashLogPath!);
    final timestamp = DateTime.now().toIso8601String();
    final entry = '[$timestamp] $message\n';
    // 限制日志文件大小为 1MB，超出时清空重来
    if (file.existsSync() && file.lengthSync() > 1024 * 1024) {
      file.writeAsStringSync('');
    }
    file.writeAsStringSync(entry, mode: FileMode.append, flush: true);
  } catch (e) {
    // 写入失败静默处理
    debugPrint('崩溃日志写入失败: $e');
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
    _notificationClickedSubscription = audio_service
        .AudioService
        .notificationClicked
        .listen(_handleNotificationClicked);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    MediaPlaybackService().handleAppLifecycleState(state);
    if (_isForegroundState(state) &&
        MediaPlaybackService().currentItem != null) {
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
            builder: (context, child) {
              return LibraryPersistenceNotificationBridge(
                child: child ?? const SizedBox.shrink(),
              );
            },
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
