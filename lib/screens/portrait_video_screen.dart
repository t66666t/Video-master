import 'dart:async';
import 'dart:io';
import 'dart:developer' as developer;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';
import '../models/video_item.dart';
import '../models/subtitle_model.dart';
import '../services/library_service.dart';
import '../services/settings_service.dart';
import '../services/media_playback_service.dart';
import '../services/playlist_manager.dart';
import '../widgets/subtitle_sidebar.dart';
import '../widgets/subtitle_settings_sheet.dart';
import '../widgets/video_controls_overlay.dart';
import '../widgets/subtitle_overlay.dart';
import '../utils/subtitle_converter.dart';
import '../utils/subtitle_parser.dart';
import '../widgets/settings_panel.dart';
import '../widgets/ai_transcription_panel.dart';
import '../services/transcription_manager.dart';
import '../widgets/subtitle_management_sheet.dart';
import 'video_player_screen.dart'; // Landscape screen
import 'package:path/path.dart' as p;
import '../services/embedded_subtitle_service.dart';
import '../utils/app_toast.dart';

enum PortraitPanel { subtitles, settings, subtitleStyle, ai, subtitleManager }

class PortraitVideoScreen extends StatefulWidget {
  final VideoItem videoItem;

  const PortraitVideoScreen({super.key, required this.videoItem});

  @override
  State<PortraitVideoScreen> createState() => _PortraitVideoScreenState();
}
class _PortraitVideoScreenState extends State<PortraitVideoScreen> with WidgetsBindingObserver, RouteAware {
  final GlobalKey<SelectableRegionState> _selectionKey = GlobalKey<SelectableRegionState>();
  final GlobalKey<SubtitleSidebarState> _subtitleSidebarKey = GlobalKey<SubtitleSidebarState>();
  final FocusNode _selectionFocusNode = FocusNode();
  final FocusNode _videoFocusNode = FocusNode(); // Dedicated focus node for video controls
  late VideoPlayerController _controller;
  bool _initialized = false;
  bool _isControllerAssigned = false;
  bool _isControllerOwner = true; // 跟踪是否拥有 controller（是否应该在 dispose 时释放）
  List<SubtitleItem> _subtitles = [];
  List<SubtitleItem> _secondarySubtitles = [];
  List<String> _currentSubtitlePaths = [];
  
  // Shared State Logic
  bool _isLocked = false;
  String _currentSubtitleText = "";
  String? _currentSecondaryText;
  int _currentSubtitleIndex = -1;
  int _currentSecondarySubtitleIndex = -1;
  List<int> _currentSubtitleIndices = [];
  List<int> _currentSecondarySubtitleIndices = [];
  List<SubtitleOverlayEntry> _currentSubtitleEntries = [];
  final Map<int, Uint8List?> _currentSubtitleImages = <int, Uint8List?>{};
  int _subtitleImageRequestId = 0;
  final List<int> _subtitleStartMs = <int>[];
  final List<int> _secondarySubtitleStartMs = <int>[];
  Timer? _subtitleSeekTimer;
  bool _isSubtitleDragMode = false;
  bool _isSubtitleSnapped = false;
  PortraitPanel _activePanel = PortraitPanel.subtitles;
  
  // Bottom Control Bar State
  bool _isDraggingProgress = false;
  double _dragProgressValue = 0.0;
  bool _isProgressDragCanceling = false;
  final bool _showVolumeSlider = false;
  final LayerLink _volumeButtonLayerLink = LayerLink();

  bool _routeObserverSubscribed = false;
  bool _isPushingLandscape = false;
  bool _forceExit = false;
  bool _iosBackSwipeActive = false;
  double _iosBackSwipeDistance = 0.0;
  static const double _iosBackSwipeEdgeWidth = 20.0;
  static const double _iosBackSwipeTriggerDistance = 60.0;
  TranscriptionManager? _transcriptionManager;
  
  // Audio state
  bool _isAudio = false;
  late VideoItem _currentItem;
  SettingsService? _settingsService;
  bool? _lastShowSubtitles;
  Duration? _lastSubtitleOffset;
  bool? _lastSplitSubtitleByLine;
  bool? _lastVideoContinuousSubtitle;
  bool? _lastAudioContinuousSubtitle;
  bool? _lastIsPlayingForServiceSync;
  String? _autoEmbeddedAttemptedForItemId;
  bool _isLoadingEmbeddedSubtitle = false;
  bool _embeddedSubtitleDetected = false;

  bool _isImageSubtitleCodec(String codecName) {
    final codec = codecName.toLowerCase();
    return codec == 'hdmv_pgs_subtitle' ||
        codec == 'dvd_subtitle' ||
        codec == 'pgs' ||
        codec == 'pgs_subtitle' ||
        codec == 'vobsub' ||
        codec == 'xsub';
  }

  @override
  void initState() {
    super.initState();
    _currentItem = widget.videoItem;
    WidgetsBinding.instance.addObserver(this);
    // Orientation is handled in didChangeDependencies to support tablet adaptive layout
    _initPlayer();
    
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        Provider.of<MediaPlaybackService>(context, listen: false).addListener(_onPlaybackServiceChange);
      }
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final settings = Provider.of<SettingsService>(context, listen: false);
      _settingsService = settings;
      _lastShowSubtitles = settings.showSubtitles;
      _lastSubtitleOffset = settings.subtitleOffset;
      _lastSplitSubtitleByLine = settings.splitSubtitleByLine;
      _lastVideoContinuousSubtitle = settings.videoContinuousSubtitle;
      _lastAudioContinuousSubtitle = settings.audioContinuousSubtitle;
      settings.addListener(_onSettingsChanged);
      _onSettingsChanged();
    });
  }

  void _onSettingsChanged() {
    final settings = _settingsService;
    if (settings == null) return;

    final bool changed = _lastShowSubtitles != settings.showSubtitles ||
        _lastSubtitleOffset != settings.subtitleOffset ||
        _lastSplitSubtitleByLine != settings.splitSubtitleByLine ||
        _lastVideoContinuousSubtitle != settings.videoContinuousSubtitle ||
        _lastAudioContinuousSubtitle != settings.audioContinuousSubtitle;

    if (!changed) return;

    _lastShowSubtitles = settings.showSubtitles;
    _lastSubtitleOffset = settings.subtitleOffset;
    _lastSplitSubtitleByLine = settings.splitSubtitleByLine;
    _lastVideoContinuousSubtitle = settings.videoContinuousSubtitle;
    _lastAudioContinuousSubtitle = settings.audioContinuousSubtitle;

    if (_initialized) {
      _updateSubtitle();
    }
  }

  void _applyItemSubtitlePreference(VideoItem item, {bool force = false}) {
    final settings = _settingsService ?? Provider.of<SettingsService>(context, listen: false);
    final bool target = item.showFloatingSubtitles;
    if (force || settings.showSubtitles != target) {
      settings.updateSetting('showSubtitles', target);
    }
  }

  void _setFloatingSubtitles(bool value) {
    final settings = _settingsService ?? Provider.of<SettingsService>(context, listen: false);
    settings.updateSetting('showSubtitles', value);
    final currentItem = _currentItem;
    currentItem.showFloatingSubtitles = value;
    try {
      Provider.of<LibraryService>(context, listen: false)
          .updateVideoSubtitleVisibility(currentItem.id, value);
    } catch (_) {}
  }
  
  void _onPlaybackServiceChange() {
    if (!mounted) return;
    final service = Provider.of<MediaPlaybackService>(context, listen: false);
    
    // 检查当前路由是否在最顶层（即竖屏页是否可见）
    // 如果不在最顶层（被横屏页覆盖），则不处理控制器变更，只更新字幕等状态
    final bool isOnTop = ModalRoute.of(context)?.isCurrent ?? false;
    
    if (service.currentItem != null && service.currentItem!.id != _currentItem.id) {
      // 视频发生变化
      if (isOnTop) {
        // 竖屏页在最顶层，正常处理视频切换
        setState(() {
          _currentItem = service.currentItem!;
          _initialized = false;
          _isControllerAssigned = false;
          _subtitles = [];
          _secondarySubtitles = [];
          _currentSubtitlePaths = [];
          _currentSubtitleText = "";
          _currentSecondaryText = null;
          _currentSubtitleIndex = -1;
          _currentSecondarySubtitleIndex = -1;
          _currentSubtitleIndices = [];
          _currentSecondarySubtitleIndices = [];
          _currentSubtitleEntries = [];
          _currentSubtitleImages.clear();
          _autoEmbeddedAttemptedForItemId = null;
          _embeddedSubtitleDetected = false;
        });
        _applyItemSubtitlePreference(service.currentItem!, force: true);
        _initPlayer();
      } else {
        // 竖屏页在后台（被横屏页覆盖），只更新当前项信息，不处理控制器
        // 这样当返回竖屏页时，会重新同步状态
        setState(() {
          _currentItem = service.currentItem!;
          _initialized = false;
          _isControllerAssigned = false;
        });
        // 不调用 _initPlayer，让页面重新可见时再处理
      }
    } else if (!_initialized && service.currentItem?.id == _currentItem.id && 
               service.state != PlaybackState.loading && service.controller != null) {
      // ID 没变，但之前因为 Loading 等待了，现在 Service 准备好了 -> 重试初始化
      _initPlayer();
    } else if (service.currentItem?.id == _currentItem.id) {
      // 同步字幕状态（无论是否在顶层都同步，确保字幕设置一致）
      final bool pathsChanged = !_stringListEquals(service.subtitlePaths, _currentSubtitlePaths);
      final bool primaryChanged = service.subtitles.length != _subtitles.length;
      final bool secondaryChanged = service.secondarySubtitles.length != _secondarySubtitles.length;
      if (pathsChanged || primaryChanged || secondaryChanged) {
        setState(() {
          _subtitles = service.subtitles;
          _secondarySubtitles = service.secondarySubtitles;
          _currentSubtitlePaths = List<String>.from(service.subtitlePaths);
          _currentSubtitleText = "";
          _currentSecondaryText = null;
          _currentSubtitleIndex = -1;
          _currentSecondarySubtitleIndex = -1;
          _currentSubtitleIndices = [];
          _currentSecondarySubtitleIndices = [];
          _currentSubtitleEntries = [];
          _currentSubtitleImages.clear();
        });
        _rebuildSubtitleIndex();
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _updateSubtitle();
        });
      }
    }
  }

  bool _stringListEquals(List<String> a, List<String> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  void _maybeAutoLoadEmbeddedSubtitle() {
    final currentId = _currentItem.id;
    if (_autoEmbeddedAttemptedForItemId == currentId) return;
    if (_currentItem.subtitlePath != null) return;
    if (_currentSubtitlePaths.isNotEmpty) return;
    if (_subtitles.isNotEmpty || _secondarySubtitles.isNotEmpty) return;
    try {
      final service = Provider.of<MediaPlaybackService>(context, listen: false);
      if (service.subtitlePaths.isNotEmpty || service.subtitles.isNotEmpty || service.secondarySubtitles.isNotEmpty) {
        return;
      }
    } catch (_) {}

    _autoEmbeddedAttemptedForItemId = currentId;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _checkAndLoadEmbeddedSubtitle(showToastWhenNone: false, showLoadingIndicator: false);
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_routeObserverSubscribed) {
      final route = ModalRoute.of(context);
      if (route is PageRoute) {
        AppToast.routeObserver.subscribe(this, route);
        _routeObserverSubscribed = true;
      }
    }
    
    // Listen to TranscriptionManager for auto-mounting subtitles
    final manager = Provider.of<TranscriptionManager>(context, listen: false);
    if (_transcriptionManager != manager) {
      _transcriptionManager?.removeListener(_onTranscriptionUpdate);
      _transcriptionManager = manager;
      _transcriptionManager?.addListener(_onTranscriptionUpdate);
    }
  }
  
  void _onTranscriptionUpdate() {
    if (!mounted || _transcriptionManager == null) return;
    
    if (_transcriptionManager!.status == TranscriptionStatus.completed &&
        _transcriptionManager!.currentVideoPath == _currentItem.path &&
        _transcriptionManager!.lastGeneratedSrtPath != null) {
        
        if (_transcriptionManager!.isResultConsumed) {
          return;
        }

        final path = _transcriptionManager!.lastGeneratedSrtPath!;
        // Avoid repeated loading if already loaded as primary
        if (_currentSubtitlePaths.isNotEmpty && _currentSubtitlePaths[0] == path) return;
        
        _transcriptionManager!.markResultConsumed();

        // Auto load
        _loadSubtitles([path]);
        
        // Update library
        final settings = Provider.of<SettingsService>(context, listen: false);
        Provider.of<LibraryService>(context, listen: false)
              .updateVideoSubtitles(_currentItem.id, path, settings.autoCacheSubtitles);
        
        // Show notification
        AppToast.show("AI 字幕转录完成并已自动加载", type: AppToastType.success);
    }
  }

  void _checkAndLoadAiSubtitle(VideoItem currentItem) {
    try {
      final manager = Provider.of<TranscriptionManager>(context, listen: false);
      
      if (manager.status == TranscriptionStatus.completed &&
          manager.currentVideoPath == currentItem.path &&
          manager.lastGeneratedSrtPath != null) {
        
        final srtPath = manager.lastGeneratedSrtPath!;
        final shouldToast = !manager.isResultConsumed;
        
        if (File(srtPath).existsSync()) {
          debugPrint("检测到AI字幕已完成，自动加载: $srtPath");
          
          List<String> pathsToLoad = [srtPath];
          if (currentItem.secondarySubtitlePath != null) {
            pathsToLoad.add(currentItem.secondarySubtitlePath!);
          }
          
          _loadSubtitles(pathsToLoad);
          
          if (mounted && shouldToast) {
            AppToast.show("AI 字幕已自动加载", type: AppToastType.success);
            manager.markResultConsumed();
          }
        }
      }
    } catch (e) {
      debugPrint("检查AI字幕失败: $e");
    }
  }

  void _updateOrientations() {
    // Detect tablet/large screen
    final size = MediaQuery.of(context).size;
    final isTablet = size.shortestSide >= 600;

    if (isTablet) {
      // On tablet, allow landscape so transition is smooth
      // The UI will be constrained to center by build method
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
        DeviceOrientation.portraitDown,
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    } else {
      // On phone, force portrait
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
        DeviceOrientation.portraitDown,
      ]);
    }
  }

  void _scheduleUpdateOrientations() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _updateOrientations();
    });
  }

  @override
  void didPush() {
    _scheduleUpdateOrientations();
  }

  @override
  void didPopNext() {
    _scheduleUpdateOrientations();
  }

  @override
  void didPushNext() {
    if (_isPushingLandscape) return;
    SystemChrome.setPreferredOrientations([]);
  }

  Future<void> _checkAndLoadEmbeddedSubtitle({
    bool showToastWhenNone = true,
    bool showLoadingIndicator = true,
  }) async {
    // If we already have subtitles loaded (e.g. from file), don't override
    if (_subtitles.isNotEmpty) return;
    if (_isLoadingEmbeddedSubtitle) return;
    
    // Determine video path
    String path = _currentItem.path;
    
    // Check embedded
    bool loadingShown = false;
    try {
      final library = Provider.of<LibraryService>(context, listen: false);
      _isLoadingEmbeddedSubtitle = true;
      if (showLoadingIndicator && mounted) {
        loadingShown = true;
        AppToast.showLoading("正在检测内嵌字幕...");
      }
      final service = Provider.of<EmbeddedSubtitleService>(context, listen: false);
      final tracks = await service.getEmbeddedSubtitles(path);
      
      if (tracks.isNotEmpty && mounted && _subtitles.isEmpty) {
        setState(() {
          _embeddedSubtitleDetected = true;
        });
        final EmbeddedSubtitleTrack track = tracks.firstWhere(
          (t) => !_isImageSubtitleCodec(t.codecName),
          orElse: () => tracks.first,
        );
        if (_isImageSubtitleCodec(track.codecName)) {
          setState(() {
            _embeddedSubtitleDetected = false;
          });
          if (loadingShown) AppToast.dismiss();
          AppToast.show("当前播放器不支持图像字幕，请转换为文本字幕", type: AppToastType.info);
          return;
        }
        
        // Prepare cache dir
        final settings = Provider.of<SettingsService>(context, listen: false);
        final dataRoot = await settings.resolveLargeDataRootDir();
        final subDir = Directory(p.join(dataRoot.path, 'subtitles'));
        if (!await subDir.exists()) {
          await subDir.create(recursive: true);
        }
        
        // Extract
        final extractedPath = await service.extractSubtitle(path, track.index, subDir.path);
        
        if (extractedPath != null && mounted) {
          // Check again
          if (_subtitles.isNotEmpty) return;
          
          await _loadSubtitles([extractedPath]);
          if (mounted) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              _subtitleSidebarKey.currentState?.jumpToFirstSubtitleTop();
            });
          }

          if (_currentItem.subtitlePath == null) {
            try {
              final String? currentSecondary =
                  _currentSubtitlePaths.length > 1 ? _currentSubtitlePaths[1] : _currentItem.secondarySubtitlePath;
              await library.updateVideoSubtitles(
                _currentItem.id,
                extractedPath,
                settings.autoCacheSubtitles,
                secondarySubtitlePath: currentSecondary,
                isSecondaryCached: settings.autoCacheSubtitles,
              );
              final updated = library.getVideo(_currentItem.id);
              if (updated != null && mounted) {
                setState(() {
                  _currentItem = updated;
                });
              }
            } catch (_) {}
          }
          
          if (!mounted) return;
          if (loadingShown) AppToast.dismiss();
          final isImage = _isImageSubtitleCodec(track.codecName);
          AppToast.show(
            isImage ? "已加载内嵌图像字幕: ${track.title}" : "已加载内嵌字幕: ${track.title}",
            type: AppToastType.success,
          );
          if (isImage) {
            AppToast.show("图像字幕无法转为文本，将以位图渲染", type: AppToastType.info);
          }
        }
      } else {
        if (mounted) {
          if (_embeddedSubtitleDetected) {
            setState(() {
              _embeddedSubtitleDetected = false;
            });
          }
          if (loadingShown) AppToast.dismiss();
          if (showToastWhenNone) {
            AppToast.show("未找到内嵌字幕");
          }
        }
      }
    } catch (e) {
      debugPrint("Auto load embedded subtitle failed: $e");
      if (loadingShown) AppToast.dismiss();
      if (mounted) {
        if (_embeddedSubtitleDetected) {
          setState(() {
            _embeddedSubtitleDetected = false;
          });
        }
        AppToast.show("内嵌字幕检测失败", type: AppToastType.error);
      }
    } finally {
      _isLoadingEmbeddedSubtitle = false;
    }
  }

  Future<void> _initPlayer() async {
    // Refresh video item
    VideoItem currentItem = _currentItem;
    try {
      final libItem = Provider.of<LibraryService>(context, listen: false).getVideo(currentItem.id);
      if (libItem != null) currentItem = libItem;
    } catch (e) {
      debugPrint("Error refreshing item: $e");
    }
    _applyItemSubtitlePreference(currentItem, force: true);
    
    // Check if this is audio
    _isAudio = currentItem.type == MediaType.audio;

    // 检查 MediaPlaybackService 状态
    try {
      final playbackService = Provider.of<MediaPlaybackService>(context, listen: false);
      
      // 如果 Service 正在加载此视频，等待它完成
      if (playbackService.currentItem?.id == currentItem.id && 
          playbackService.state == PlaybackState.loading) {
        debugPrint("PortraitVideoScreen: Waiting for service to load ${currentItem.title}");
        if (mounted) {
          setState(() {
            _initialized = false;
          });
        }
        return;
      }

      // 如果 Service 已经有这个视频的 controller，直接复用
      if (playbackService.currentItem?.id == currentItem.id && 
          playbackService.controller != null) {
        
        // 如果之前持有本地 controller，先释放，防止声音重叠
        if (_isControllerAssigned && _isControllerOwner) {
          try {
            _controller.removeListener(_videoListener);
            _controller.dispose();
          } catch (e) {
            debugPrint("Error disposing old controller: $e");
          }
        }

        // 使用现有的 controller
        _controller = playbackService.controller!;
        _isControllerAssigned = true;
        _isControllerOwner = false; // 不拥有这个 controller，不应该 dispose
        
        if (!mounted) return;
        
        setState(() {
          _initialized = true;
        });
        
        _controller.addListener(_videoListener);
        
        // 首先检查是否有刚完成的AI字幕（即使 isResultConsumed 为 true）
        _checkAndLoadAiSubtitle(currentItem);
        
        // Auto-load subtitle if exists
        if (currentItem.subtitlePath != null) {
          final List<String> paths = [currentItem.subtitlePath!];
          if (currentItem.secondarySubtitlePath != null) {
            paths.add(currentItem.secondarySubtitlePath!);
          }
          await _loadSubtitles(paths);
        } else {
          _maybeAutoLoadEmbeddedSubtitle();
        }
        
        // 不需要再次调用 play()，因为 MediaPlaybackService 已经在管理播放状态
        // 但为了保险起见，同步一次状态
        playbackService.updatePlaybackStateFromController();
        if (playbackService.isPlaying) {
          if (!_controller.value.isPlaying) playbackService.resume();
        } else {
          if (_controller.value.isPlaying) playbackService.pause();
        }
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _updateSubtitle();
        });
        return;
      }
    } catch (e) {
      debugPrint("无法获取 MediaPlaybackService: $e");
      // 继续使用原有逻辑创建新的 controller
    }

    try {
      final playbackService = Provider.of<MediaPlaybackService>(context, listen: false);
      if (playbackService.currentItem?.id != currentItem.id || playbackService.controller == null) {
        if (mounted) {
          setState(() {
            _initialized = false;
          });
        }
        playbackService.play(currentItem);
        return;
      }
    } catch (_) {}

    final file = File(currentItem.path);
    // Initialize controller immediately to prevent LateInitializationError in UI
    _controller = VideoPlayerController.file(file);
    _isControllerAssigned = true;
    final libraryService = Provider.of<LibraryService>(context, listen: false);
    final settingsService = Provider.of<SettingsService>(context, listen: false);
    final playbackService = Provider.of<MediaPlaybackService>(context, listen: false);

    if (!await file.exists()) {
      developer.log('Video file not found: ${currentItem.path}');
      if (mounted) {
        AppToast.show("视频文件不存在: ${currentItem.path}", type: AppToastType.error);
      }
      return;
    }

    try {
      // Add timeout to prevent hanging if file is problematic
      await _controller.initialize().timeout(const Duration(seconds: 10));
      
      if (!mounted) return;

      // Update duration if missing
      final duration = _controller.value.duration.inMilliseconds;
      if (currentItem.durationMs == 0 || currentItem.durationMs != duration) {
        libraryService.updateVideoDuration(currentItem.id, duration);
      }
      
      // Seek to last position
      if (currentItem.lastPositionMs > 0) {
        await _controller.seekTo(Duration(milliseconds: currentItem.lastPositionMs));
      }
      
      // Apply global settings
      await _controller.setPlaybackSpeed(settingsService.playbackSpeed);

      // 首先检查是否有刚完成的AI字幕（即使 isResultConsumed 为 true）
      _checkAndLoadAiSubtitle(currentItem);

      // Auto-load subtitle if exists
      if (currentItem.subtitlePath != null) {
        final List<String> paths = [currentItem.subtitlePath!];
        if (currentItem.secondarySubtitlePath != null) {
          paths.add(currentItem.secondarySubtitlePath!);
        }
        await _loadSubtitles(paths);
      } else {
        _maybeAutoLoadEmbeddedSubtitle();
      }

      setState(() {
        _initialized = true;
      });
      _controller.addListener(_videoListener);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _updateSubtitle();
      });

      try {
        playbackService.setController(_controller);
        await playbackService.updateMetadata(currentItem);
        await playbackService.resume();
      } catch (e) {
        debugPrint("Failed to register controller with service: $e");
      }

      // Auto Load Embedded if enabled
      Future.delayed(const Duration(seconds: 1), () {
        if (mounted) {
           final settings = Provider.of<SettingsService>(context, listen: false);
           if (settings.autoLoadEmbeddedSubtitles) {
              _checkAndLoadEmbeddedSubtitle();
           }
        }
      });
    } catch (e) {
      developer.log('Error initializing player', error: e);
      if (mounted) {
        AppToast.show("无法加载视频", type: AppToastType.error);
      }
    }
  }
  
  void _videoListener() {
    final isPlayingNow = _controller.value.isPlaying;
    if (_lastIsPlayingForServiceSync != isPlayingNow) {
      _lastIsPlayingForServiceSync = isPlayingNow;
      try {
        final playbackService = Provider.of<MediaPlaybackService>(context, listen: false);
        if (playbackService.controller == _controller) {
          playbackService.updatePlaybackStateFromController();
        }
      } catch (_) {}
    }
    _updateSubtitle();
  }

  void _updateSubtitle() {
    if (!_initialized) return;
    final settings = Provider.of<SettingsService>(context, listen: false);
    
    if (!settings.showSubtitles) {
      if (_currentSubtitleText.isNotEmpty || _currentSecondaryText != null || _currentSubtitleIndex != -1 || _currentSecondarySubtitleIndex != -1 || _currentSubtitleEntries.isNotEmpty) {
        setState(() {
          _currentSubtitleText = "";
          _currentSecondaryText = null;
          _currentSubtitleIndex = -1;
          _currentSecondarySubtitleIndex = -1;
          _currentSubtitleIndices = [];
          _currentSecondarySubtitleIndices = [];
          _currentSubtitleEntries = [];
          _currentSubtitleImages.clear();
        });
      }
      return;
    }

    final position = _controller.value.position;
    final adjustedPosition = position - settings.subtitleOffset;
    final int posMs = adjustedPosition.inMilliseconds;
    final continuousSubtitleEnabled = _isAudio ? settings.audioContinuousSubtitle : settings.videoContinuousSubtitle;
    
    if (_subtitleStartMs.length != _subtitles.length || _secondarySubtitleStartMs.length != _secondarySubtitles.length) {
      _rebuildSubtitleIndex();
    }

    final List<int> primaryIndices = _subtitles.isEmpty
        ? <int>[]
        : _findSubtitleIndicesMs(
            posMs: posMs,
            subtitles: _subtitles,
            startMs: _subtitleStartMs,
            continuousSubtitleEnabled: continuousSubtitleEnabled,
          );
    final List<int> secondaryIndices = _secondarySubtitles.isEmpty
        ? <int>[]
        : _findSubtitleIndicesMs(
            posMs: posMs,
            subtitles: _secondarySubtitles,
            startMs: _secondarySubtitleStartMs,
            continuousSubtitleEnabled: continuousSubtitleEnabled,
          );

    final List<SubtitleItem> secondaryOverlapItems = secondaryIndices.map((i) => _secondarySubtitles[i]).toList();
    final List<SubtitleOverlayEntry> entries = <SubtitleOverlayEntry>[];

    if (primaryIndices.isNotEmpty) {
      for (final int index in primaryIndices) {
        final SubtitleItem item = _subtitles[index];
        final Uint8List? image = _currentSubtitleImages[index];
        final bool hasImage = item.imageLoader != null;
        String text = hasImage ? "" : item.text;
        String? secondaryText;

        if (!hasImage && _secondarySubtitles.isEmpty && settings.splitSubtitleByLine) {
          if (text.contains('\n')) {
            final lines = text.split('\n');
            text = lines[0];
            secondaryText = lines.sublist(1).join('\n');
          }
        } else if (!hasImage && secondaryOverlapItems.isNotEmpty) {
          SubtitleItem? best;
          int bestDelta = 1 << 30;
          for (final sec in secondaryOverlapItems) {
            final int delta = (sec.startTime.inMilliseconds - item.startTime.inMilliseconds).abs();
            if (delta < bestDelta) {
              bestDelta = delta;
              best = sec;
            }
          }
          secondaryText = best?.text;
        }

        entries.add(SubtitleOverlayEntry(
          index: index,
          text: text,
          secondaryText: hasImage ? null : secondaryText,
          image: image,
        ));
      }
    } else if (secondaryIndices.isNotEmpty) {
      for (final int index in secondaryIndices) {
        final SubtitleItem item = _secondarySubtitles[index];
        entries.add(SubtitleOverlayEntry(
          index: null,
          text: "",
          secondaryText: item.text,
          image: null,
        ));
      }
    }

    final int anchorPrimaryIndex = primaryIndices.isNotEmpty ? primaryIndices.first : -1;
    final int anchorSecondaryIndex = secondaryIndices.isNotEmpty ? secondaryIndices.first : -1;
    final SubtitleOverlayEntry? anchorEntry = entries.isNotEmpty ? entries.first : null;
    final bool indicesChanged = !_areIntListsEqual(primaryIndices, _currentSubtitleIndices) ||
        !_areIntListsEqual(secondaryIndices, _currentSecondarySubtitleIndices);
    final bool entriesChanged = !_areSubtitleEntryListsEqual(entries, _currentSubtitleEntries);
    final bool anchorChanged = anchorPrimaryIndex != _currentSubtitleIndex || anchorSecondaryIndex != _currentSecondarySubtitleIndex;

    if (!indicesChanged && !entriesChanged && !anchorChanged) return;

    setState(() {
      _currentSubtitleIndices = primaryIndices;
      _currentSecondarySubtitleIndices = secondaryIndices;
      _currentSubtitleEntries = entries;
      _currentSubtitleIndex = anchorPrimaryIndex;
      _currentSecondarySubtitleIndex = anchorSecondaryIndex;
      _currentSubtitleText = anchorEntry?.text ?? "";
      _currentSecondaryText = anchorEntry?.secondaryText;
    });

    if (primaryIndices.isNotEmpty) {
      _loadSubtitleImages(primaryIndices);
    }
  }

  void _seekToSubtitleFast(Duration target) {
    if (!_initialized || !_controller.value.isInitialized) return;
    final duration = _controller.value.duration;
    Duration clamped = target;
    if (clamped < Duration.zero) clamped = Duration.zero;
    if (duration > Duration.zero && clamped > duration) clamped = duration;

    _subtitleSeekTimer?.cancel();
    _subtitleSeekTimer = null;
    try {
      final playbackService = Provider.of<MediaPlaybackService>(context, listen: false);
      if (playbackService.controller == _controller) {
        playbackService.seekTo(clamped);
      } else {
        _controller.seekTo(clamped);
      }
    } catch (_) {
      _controller.seekTo(clamped);
    }
  }

  void _togglePlay() {
    try {
      final playbackService = Provider.of<MediaPlaybackService>(context, listen: false);
      if (playbackService.controller == _controller) {
        playbackService.updatePlaybackStateFromController();
        if (_controller.value.isPlaying) {
          playbackService.pause();
        } else {
          playbackService.resume();
        }
        return;
      }
    } catch (_) {}

    if (_controller.value.isPlaying) {
      _controller.pause();
    } else {
      _controller.play();
    }
  }

  void _enterSubtitleDragMode() {
    setState(() {
      _isSubtitleDragMode = true;
      final settings = Provider.of<SettingsService>(context, listen: false);
      _isSubtitleSnapped = settings.subtitleAlignment.x == 0.0;
    });
  }

  void _exitSubtitleDragMode() {
    setState(() {
      _isSubtitleDragMode = false;
      _isSubtitleSnapped = false;
    });
  }

  void _updateSubtitlePosition(DragUpdateDetails details, BoxConstraints constraints) {
    final settings = Provider.of<SettingsService>(context, listen: false);
    final dx = (details.delta.dx / (constraints.maxWidth / 2));
    final dy = (details.delta.dy / (constraints.maxHeight / 2));
    
    double newX = (settings.subtitleAlignment.x + dx).clamp(-1.0, 1.0);
    final newY = (settings.subtitleAlignment.y + dy).clamp(-1.0, 1.0);

    bool snapped = false;
    if (newX.abs() < 0.05) { 
      newX = 0.0;
      snapped = true;
    }

    settings.saveSubtitleAlignment(Alignment(newX, newY));
    setState(() {
      _isSubtitleSnapped = snapped;
    });
  }

  Future<void> _pickSubtitle() async {
    try {
      final settings = Provider.of<SettingsService>(context, listen: false);
      final library = Provider.of<LibraryService>(context, listen: false);

      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['srt', 'lrc', 'vtt'],
        withData: true, 
      );

      if (!mounted) return;

      if (result != null) {
        final file = result.files.single;
        String path = file.path!;
        
        // Auto Cache Logic
        final String? currentSecondary = _currentSubtitlePaths.length > 1 ? _currentSubtitlePaths[1] : _currentItem.secondarySubtitlePath;
        await library.updateVideoSubtitles(
          _currentItem.id,
          path,
          settings.autoCacheSubtitles,
          secondarySubtitlePath: currentSecondary,
          isSecondaryCached: settings.autoCacheSubtitles,
        );
        
        final List<String> pathsToLoad = [path];
        if (currentSecondary != null && currentSecondary.isNotEmpty) {
          pathsToLoad.add(currentSecondary);
        }
        await _loadSubtitles(pathsToLoad);
        
        if (mounted) {
          AppToast.show("已加载字幕: ${file.name}", type: AppToastType.success);
        }
      }
    } catch (e) {
      developer.log('Error picking subtitle', error: e);
    }
  }

  void _openSubtitleStyleSettings() {
    developer.log('Opening subtitle style settings');
    setState(() {
      _activePanel = PortraitPanel.subtitleStyle;
    });
  }

  Future<void> _loadSubtitles(List<String> paths) async {
    final playbackService = Provider.of<MediaPlaybackService>(context, listen: false);

    if (paths.isEmpty) {
      // 清空字幕时也同步到 MediaPlaybackService
      playbackService.clearSubtitleState();
      _subtitleStartMs.clear();
      _secondarySubtitleStartMs.clear();
      return;
    }
    
    // Helper to parse file
    Future<List<SubtitleItem>> parseFile(String path) async {
      try {
        final file = File(path);
        if (!await file.exists()) return [];

        final length = await file.length();
        if (length > 100 * 1024 * 1024) {
           debugPrint("Subtitle file too large ($length bytes), skipping: $path");
           return [];
        }

        final ext = path.toLowerCase();
        if (ext.endsWith('.sup') || ext.endsWith('.idx')) {
           if (mounted) {
             AppToast.show("当前播放器不支持图像字幕，请转换为文本字幕", type: AppToastType.info);
           }
           return [];
        } else if (ext.endsWith('.sub')) {
          if (await SubtitleConverter.isMicroDvdSub(path)) {
            final converted = await SubtitleConverter.convert(inputPath: path, targetExtension: '.srt');
            if (converted != null) return await parseFile(converted);
            return [];
          }
          if (mounted) {
            AppToast.show("当前播放器不支持图像字幕，请转换为文本字幕", type: AppToastType.info);
          }
          return [];
        }

        final bytes = await file.readAsBytes();
        final content = SubtitleParser.decodeBytes(bytes);
        
        if (content.isNotEmpty) {
          final parsed = SubtitleParser.parse(content);
          parsed.sort((a, b) => a.startTime.compareTo(b.startTime));
          return parsed;
        }
      } catch (e) {
        debugPrint("Error loading subtitle: $e");
      }
      return [];
    }

    final primary = await parseFile(paths[0]);
    List<SubtitleItem> secondary = [];
    if (paths.length > 1) {
      secondary = await parseFile(paths[1]);
    }

    if (!mounted) return;

    setState(() {
      _subtitles = primary;
      _secondarySubtitles = secondary;
      _currentSubtitlePaths = List.from(paths);
      _currentSubtitleText = "";
      _currentSecondaryText = null;
      _currentSubtitleIndex = -1;
      _currentSecondarySubtitleIndex = -1;
      _currentSubtitleIndices = [];
      _currentSecondarySubtitleIndices = [];
      _currentSubtitleEntries = [];
      _currentSubtitleImages.clear();
    });
    _rebuildSubtitleIndex();
    
    playbackService.setSubtitleState(paths: paths, primary: primary, secondary: secondary);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _updateSubtitle();
    });
  }

  void _rebuildSubtitleIndex() {
    _subtitleStartMs
      ..clear()
      ..addAll(_subtitles.map((e) => e.startTime.inMilliseconds));
    _secondarySubtitleStartMs
      ..clear()
      ..addAll(_secondarySubtitles.map((e) => e.startTime.inMilliseconds));
  }

  int _getEffectiveEndMs({
    required List<SubtitleItem> subtitles,
    required List<int> startMs,
    required int index,
    required bool continuousSubtitleEnabled,
  }) {
    final SubtitleItem item = subtitles[index];
    final int actualEndMs = item.endTime.inMilliseconds;
    if (!continuousSubtitleEnabled) return actualEndMs;
    int nextStartMs = actualEndMs;
    if (index + 1 < subtitles.length) {
      nextStartMs = startMs[index + 1];
    }
    return nextStartMs < actualEndMs ? actualEndMs : nextStartMs;
  }

  int _binarySearchLastStartLE(List<int> startMs, int posMs) {
    int low = 0;
    int high = startMs.length - 1;
    int ans = -1;
    while (low <= high) {
      final int mid = (low + high) >> 1;
      if (startMs[mid] <= posMs) {
        ans = mid;
        low = mid + 1;
      } else {
        high = mid - 1;
      }
    }
    return ans;
  }


  List<int> _findSubtitleIndicesMs({
    required int posMs,
    required List<SubtitleItem> subtitles,
    required List<int> startMs,
    required bool continuousSubtitleEnabled,
  }) {
    if (subtitles.isEmpty) return <int>[];
    final int candidate = _binarySearchLastStartLE(startMs, posMs);
    if (candidate < 0 || candidate >= subtitles.length) return <int>[];

    final List<int> indices = <int>[];
    for (int i = candidate; i >= 0; i--) {
      if (startMs[i] > posMs) continue;
      final int endMs = _getEffectiveEndMs(
        subtitles: subtitles,
        startMs: startMs,
        index: i,
        continuousSubtitleEnabled: continuousSubtitleEnabled,
      );
      if (posMs < endMs) {
        indices.add(i);
      } else {
        break;
      }
    }
    if (indices.length <= 1) return indices;
    indices.sort();
    return indices;
  }

  bool _areIntListsEqual(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  bool _areSubtitleEntryListsEqual(List<SubtitleOverlayEntry> a, List<SubtitleOverlayEntry> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      final SubtitleOverlayEntry left = a[i];
      final SubtitleOverlayEntry right = b[i];
      if (left.index != right.index) return false;
      if (left.text != right.text) return false;
      if (left.secondaryText != right.secondaryText) return false;
      if (left.image != right.image) return false;
    }
    return true;
  }

  void _pruneSubtitleImages(Set<int> keepIndices) {
    if (_currentSubtitleImages.isEmpty) return;
    final keysToRemove = _currentSubtitleImages.keys.where((k) => !keepIndices.contains(k)).toList();
    for (final key in keysToRemove) {
      _currentSubtitleImages.remove(key);
    }
  }

  void _loadSubtitleImages(List<int> indices) {
    final Set<int> indexSet = indices.toSet();
    _pruneSubtitleImages(indexSet);
    if (indexSet.isEmpty) return;

    final int requestId = ++_subtitleImageRequestId;
    for (final int index in indexSet) {
      final SubtitleItem item = _subtitles[index];
      final imageLoader = item.imageLoader;
      if (imageLoader == null) continue;
      if (_currentSubtitleImages.containsKey(index)) continue;

      imageLoader().then((image) {
        if (!mounted) return;
        if (requestId != _subtitleImageRequestId) return;
        if (!indexSet.contains(index)) return;

        setState(() {
          _currentSubtitleImages[index] = image;
          _currentSubtitleEntries = _currentSubtitleEntries
              .map(
                (entry) => entry.index == index
                    ? SubtitleOverlayEntry(
                        index: entry.index,
                        text: entry.text,
                        secondaryText: entry.secondaryText,
                        image: image,
                      )
                    : entry,
              )
              .toList();
        });
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.detached) {
      _saveProgress();
    }
  }

  @override
  void deactivate() {
    _saveProgress();
    super.deactivate();
  }

  Future<void> _handleExit() async {
     try {
       final settings = Provider.of<SettingsService>(context, listen: false);
       final playbackService = Provider.of<MediaPlaybackService>(context, listen: false);
       await _saveProgress();
       
       if (settings.autoPauseOnExit && _controller.value.isPlaying) {
          if (playbackService.controller == _controller) {
            await playbackService.pause();
          } else {
            await _controller.pause();
          }
       }
       
       // Force sync state
       if (!_isControllerOwner) {
          playbackService.updatePlaybackStateFromController();
       }
     } catch (e) {
       debugPrint("Exit sync error: $e");
     }
  }

  Future<void> _handleBackRequest() async {
    final navigator = Navigator.of(context);
    if (_forceExit) {
      _updateOrientations();
      if (mounted) navigator.pop();
      return;
    }

    if (_isSubtitleDragMode) {
      _exitSubtitleDragMode();
      return;
    }

    if (_activePanel != PortraitPanel.subtitles) {
      if (!mounted) return;
      setState(() {
        _activePanel = PortraitPanel.subtitles;
      });
      return;
    }

    await _handleExit();
    if (!mounted) return;
    _updateOrientations();
    navigator.pop();
  }

  void _onIosBackSwipeStart(DragStartDetails details) {
    if (!Platform.isIOS) return;
    _iosBackSwipeActive = true;
    _iosBackSwipeDistance = 0.0;
  }

  void _onIosBackSwipeUpdate(DragUpdateDetails details) {
    if (!_iosBackSwipeActive) return;
    _iosBackSwipeDistance += details.delta.dx;
    if (_iosBackSwipeDistance >= _iosBackSwipeTriggerDistance) {
      _iosBackSwipeActive = false;
      _iosBackSwipeDistance = 0.0;
      _handleBackRequest();
    }
  }

  void _onIosBackSwipeEnd(DragEndDetails details) {
    _iosBackSwipeActive = false;
    _iosBackSwipeDistance = 0.0;
  }

  @override
  void dispose() {
    // Try to sync one last time (fire and forget)
    _handleExit();

    if (_routeObserverSubscribed) {
      AppToast.routeObserver.unsubscribe(this);
    }

    try {
      Provider.of<MediaPlaybackService>(context, listen: false).removeListener(_onPlaybackServiceChange);
    } catch (_) {}
    _settingsService?.removeListener(_onSettingsChanged);

    _transcriptionManager?.removeListener(_onTranscriptionUpdate);
    _selectionFocusNode.dispose();
    _subtitleSeekTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    if (_isControllerAssigned) {
      _controller.removeListener(_videoListener);
      // 只有当我们拥有 controller 时才 dispose
      if (_isControllerOwner) {
        try {
          final playbackService = Provider.of<MediaPlaybackService>(context, listen: false);
          if (playbackService.controller == _controller) {
            playbackService.clearController();
          }
        } catch (e) {
          debugPrint("Error clearing controller from service: $e");
        }
        _controller.dispose();
      }
    }
    super.dispose();
  }

  Future<void> _saveProgress() async {
    if (_isControllerAssigned && _controller.value.isInitialized) {
      final position = _controller.value.position.inMilliseconds;
      await Provider.of<LibraryService>(context, listen: false)
          .updateVideoProgress(_currentItem.id, position);
    }
  }
  
  void _goToLandscape() async {
    // Push landscape page with current controller
    // Use opaque: false to make transition smoother if needed
    _saveProgress(); // Save before switch just in case
    
    // 标记控制器已传递给横屏页，竖屏页不再拥有它
    _isControllerOwner = false;
    
    _isPushingLandscape = true;
    try {
      final navigator = Navigator.of(context);
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
      await navigator.push(
        PageRouteBuilder(
          pageBuilder: (context, animation, secondaryAnimation) => VideoPlayerScreen(
            videoFile: null, // Legacy param, ignored
            existingController: _controller, // Pass控制器
            videoItem: _currentItem, // Pass item for context
            skipAutoPauseOnExit: true,
          ),
          opaque: true,
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            return child;
          },
          transitionDuration: Duration.zero,
          reverseTransitionDuration: Duration.zero,
        ),
      );
    } finally {
      _isPushingLandscape = false;
    }
    
    if (!mounted) return;
    
    // 从横屏返回后，需要重新同步控制器状态
    // 因为横屏页可能已经切换了视频，导致控制器被替换
    _isControllerAssigned = false;
    _initialized = false;
    
    // Restore orientation logic based on device type
    _updateOrientations();
    
    // 重新初始化播放器以同步 Service 的状态
    _initPlayer();
    
    // 同步字幕状态
    try {
      final library = Provider.of<LibraryService>(context, listen: false);
      final updated = library.getVideo(_currentItem.id);
      if (updated != null) {
        _currentItem = updated;
      }
    } catch (_) {}

    final playbackService = Provider.of<MediaPlaybackService>(context, listen: false);
    if (playbackService.subtitlePaths.isNotEmpty) {
      await _loadSubtitles(playbackService.subtitlePaths);
    } else if (_currentItem.subtitlePath != null) {
      final List<String> paths = [_currentItem.subtitlePath!];
      if (_currentItem.secondarySubtitlePath != null) {
        paths.add(_currentItem.secondarySubtitlePath!);
      }
      await _loadSubtitles(paths);
    } else {
      setState(() {
        _subtitles = [];
        _secondarySubtitles = [];
        _currentSubtitlePaths = [];
        _currentSubtitleText = "";
        _currentSecondaryText = null;
        _currentSubtitleIndex = -1;
        _currentSecondarySubtitleIndex = -1;
        _currentSubtitleIndices = [];
        _currentSecondarySubtitleIndices = [];
        _currentSubtitleEntries = [];
        _currentSubtitleImages.clear();
      });
      playbackService.clearSubtitleState();
    }

    setState(() {});

    // 自动跟随字幕开启时，从横屏返回后自动定位
    // 等待转场动画完成，避免在动画过程中滚动
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final settings = Provider.of<SettingsService>(context, listen: false);
      if (settings.autoScrollSubtitles) {
        Future.delayed(const Duration(milliseconds: 400), () {
          if (mounted) {
            _subtitleSidebarKey.currentState?.triggerLocateForAutoFollow();
          }
        });
      }
    });
  }

  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, "0");
    String twoDigitMinutes = twoDigits(duration.inMinutes.remainder(60));
    String twoDigitSeconds = twoDigits(duration.inSeconds.remainder(60));
    return "${twoDigits(duration.inHours)}:$twoDigitMinutes:$twoDigitSeconds";
  }

  bool _isInCancelArea(Offset globalPosition) {
    if (!mounted) return false;
    final RenderBox? box = context.findRenderObject() as RenderBox?;
    if (box == null) return false;
    final localOffset = box.globalToLocal(globalPosition);
    return localOffset.dy < box.size.height * 0.25;
  }

  Widget _buildBottomControlBar() {
    final settings = Provider.of<SettingsService>(context);
    
    return ValueListenableBuilder(
      valueListenable: _controller,
      builder: (context, value, child) {
        // Use metadata if controller not ready
        final duration = value.isInitialized ? value.duration : Duration(milliseconds: _currentItem.durationMs);
        final position = value.isInitialized ? value.position : Duration(milliseconds: _currentItem.lastPositionMs);
        
        // Ensure valid slider values
        final double maxDuration = duration.inMilliseconds.toDouble();
        final double currentPos = position.inMilliseconds.toDouble();
        final double sliderMax = maxDuration > 0 ? maxDuration : 1.0;
        final double sliderValue = currentPos.clamp(0.0, sliderMax);

        return Container(
          color: const Color(0xFF1E1E1E),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
          height: 36, // Extremely short height
          child: Row(
            children: [
              // Time - show drag position when dragging, otherwise show current position
              Text(
                _isDraggingProgress
                    ? "${_formatDuration(Duration(milliseconds: _dragProgressValue.toInt()))} / ${_formatDuration(duration)}"
                    : "${_formatDuration(position)} / ${_formatDuration(duration)}",
                style: const TextStyle(color: Colors.white, fontSize: 10),
              ),
              
              const SizedBox(width: 8),
              
              // Progress Slider
              Expanded(
                child: Listener(
                  behavior: HitTestBehavior.translucent,
                  onPointerMove: (event) {
                    if (!_isDraggingProgress || _isLocked) return;
                    final isInCancelArea = _isInCancelArea(event.position);
                    if (isInCancelArea != _isProgressDragCanceling) {
                      setState(() {
                        _isProgressDragCanceling = isInCancelArea;
                      });
                    }
                  },
                  onPointerCancel: (event) {
                    if (!_isDraggingProgress) return;
                    setState(() {
                      _isDraggingProgress = false;
                      _isProgressDragCanceling = false;
                    });
                  },
                  child: SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      activeTrackColor: _isProgressDragCanceling ? Colors.grey : const Color(0xFF0D47A1),
                      inactiveTrackColor: Colors.white24,
                      thumbColor: _isProgressDragCanceling ? Colors.grey : const Color(0xFF1565C0),
                      overlayColor: const Color(0x291565C0),
                      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6.0),
                      trackHeight: 2.0,
                      overlayShape: const RoundSliderOverlayShape(overlayRadius: 10),
                    ),
                    child: Slider(
                      min: 0.0,
                      max: sliderMax,
                      value: _isDraggingProgress 
                          ? _dragProgressValue 
                          : sliderValue,
                      onChanged: (newValue) {
                        setState(() {
                          _isDraggingProgress = true;
                          _dragProgressValue = newValue;
                        });
                      },
                      onChangeEnd: (newValue) {
                        if (!_isProgressDragCanceling) {
                          final pos = Duration(milliseconds: newValue.toInt());
                          try {
                            final playbackService = Provider.of<MediaPlaybackService>(context, listen: false);
                            if (playbackService.controller == _controller) {
                              playbackService.seekTo(pos);
                            } else {
                              _controller.seekTo(pos);
                            }
                          } catch (_) {
                            _controller.seekTo(pos);
                          }
                        }
                        setState(() {
                          _isDraggingProgress = false;
                          _isProgressDragCanceling = false;
                        });
                      },
                    ),
                  ),
                ),
              ),
              
              // Tools
              
              // Speed
              PopupMenuButton<double>(
                initialValue: value.playbackSpeed,
                tooltip: "倍速",
                onSelected: (speed) {
                  _controller.setPlaybackSpeed(speed);
                  settings.updateSetting('playbackSpeed', speed);
                  try {
                    final playbackService = Provider.of<MediaPlaybackService>(context, listen: false);
                    if (playbackService.controller == _controller) {
                      playbackService.updatePlaybackStateFromController();
                    }
                  } catch (_) {}
                },
                constraints: const BoxConstraints(maxHeight: 400), // Limit height to ensure scrolling behavior is obvious
                itemBuilder: (context) => [0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 2.5, 3.0, 4.0, 5.0].map((speed) {
                  return PopupMenuItem<double>(
                    value: speed,
                    child: Text("${speed}x"),
                  );
                }).toList(),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Text(
                    "${value.playbackSpeed}x",
                    style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
                  ),
                ),
              ),
              
              // Subtitle Toggle
              IconButton(
                icon: Icon(
                  settings.showSubtitles ? Icons.subtitles : Icons.subtitles_off,
                  color: settings.showSubtitles ? Colors.blueAccent : Colors.white70,
                  size: 18,
                ),
                onPressed: () => _setFloatingSubtitles(!settings.showSubtitles),
                tooltip: "字幕开关",
                padding: const EdgeInsets.all(4),
                constraints: const BoxConstraints(),
              ),
              
              // Volume Toggle (Mute/Unmute)
              IconButton(
                icon: Icon(
                  _controller.value.volume == 0 ? Icons.volume_off : Icons.volume_up,
                  color: _controller.value.volume == 0 ? Colors.redAccent : Colors.white,
                  size: 18
                ),
                onPressed: () {
                  setState(() {
                    if (_controller.value.volume > 0) {
                      _controller.setVolume(0.0);
                    } else {
                      _controller.setVolume(1.0);
                    }
                  });
                },
                tooltip: _controller.value.volume == 0 ? "取消静音" : "静音",
                padding: const EdgeInsets.all(4),
                constraints: const BoxConstraints(),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildExternalControls() {
    final settings = Provider.of<SettingsService>(context);
    final playlistManager = Provider.of<PlaylistManager>(context);
    final playbackService = Provider.of<MediaPlaybackService>(context, listen: false);
    
    // Reduced sizes by ~50-60% to meet user request (80% reduction requested but that would be too small, so aiming for "much smaller")
    const double iconSize = 50.0; 
    const double seekIconSize = 28.0; 

    return ValueListenableBuilder(
      valueListenable: _controller,
      builder: (context, value, child) {
        return Container(
          color: const Color(0xFF1E1E1E), // Match SubtitleSidebar background
          padding: const EdgeInsets.symmetric(vertical:0.1), // Minimal padding to fit tightly
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Previous Episode
              IconButton(
                icon: Icon(Icons.skip_previous, color: playlistManager.hasPrevious ? Colors.white : Colors.white38),
                onPressed: playlistManager.hasPrevious ? () => playbackService.playPrevious(autoPlay: settings.autoPlayNextVideo) : null,
                iconSize: 32,
                tooltip: "上一集",
              ),
              const SizedBox(width: 16),

              // Seek Backward
              InkWell(
                onTap: () {
                   final newPos = value.position - Duration(seconds: settings.doubleTapSeekSeconds);
                   final pos = newPos < Duration.zero ? Duration.zero : newPos;
                   if (playbackService.controller == _controller) {
                     playbackService.seekTo(pos);
                   } else {
                     _controller.seekTo(pos);
                   }
                },
                borderRadius: BorderRadius.circular(30),
                child: SizedBox(
                  width: seekIconSize + 16,
                  height: seekIconSize + 16,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      Icon(Icons.replay, color: Colors.white, size: seekIconSize),
                      Text(
                        "${settings.doubleTapSeekSeconds}",
                        style: const TextStyle(
                          color: Colors.white, 
                          fontSize: 8, 
                          fontWeight: FontWeight.bold
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 30),
              
              // Play/Pause
              IconButton(
                iconSize: iconSize,
                icon: Icon(
                  value.isPlaying ? Icons.pause_circle_filled : Icons.play_circle_fill,
                  color: Colors.white,
                ),
                onPressed: _togglePlay,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
              ),
              
              const SizedBox(width: 30),
              
              // Seek Forward
              InkWell(
                onTap: () {
                   final newPos = value.position + Duration(seconds: settings.doubleTapSeekSeconds);
                   final duration = value.duration;
                   final pos = newPos > duration ? duration : newPos;
                   if (playbackService.controller == _controller) {
                     playbackService.seekTo(pos);
                   } else {
                     _controller.seekTo(pos);
                   }
                },
                borderRadius: BorderRadius.circular(30),
                child: SizedBox(
                  width: seekIconSize + 16,
                  height: seekIconSize + 16,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      Transform(
                        alignment: Alignment.center,
                        transform: Matrix4.rotationY(3.14159),
                        child: Icon(Icons.replay, color: Colors.white, size: seekIconSize),
                      ),
                      Text(
                        "${settings.doubleTapSeekSeconds}",
                        style: const TextStyle(
                          color: Colors.white, 
                          fontSize: 8, 
                          fontWeight: FontWeight.bold
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(width: 16),
              // Next Episode
              IconButton(
                icon: Icon(Icons.skip_next, color: playlistManager.hasNext ? Colors.white : Colors.white38),
                onPressed: playlistManager.hasNext ? () => playbackService.playNext(autoPlay: settings.autoPlayNextVideo) : null,
                iconSize: 32,
                tooltip: "下一集",
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<SettingsService>(
      builder: (context, settings, child) {
        // Use WillPopScope to handle back button and reset orientation early
        // This helps reduce the "jank" when returning to a landscape screen
        return PopScope(
          canPop: false,
          onPopInvokedWithResult: (didPop, result) {
            if (didPop) return;
            _handleBackRequest();
          },
          child: Scaffold(
            backgroundColor: Colors.black,
            body: SelectableRegion(
              key: _selectionKey,
              selectionControls: materialTextSelectionControls,
              focusNode: _selectionFocusNode,
              child: GestureDetector(
                onTap: () {
                  // 点击空白区域取消文字选择
                  _selectionKey.currentState?.clearSelection();
                  FocusManager.instance.primaryFocus?.unfocus();
                },
                behavior: HitTestBehavior.translucent,
                child: OrientationBuilder(
              builder: (context, orientation) {
                // If device is in landscape (e.g. tablet), limit width to simulate portrait mode
                return Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 500),
                    child: SafeArea(
                      top: true,
                      bottom: false,
                      child: Stack(
                        children: [
                      Column(
                        children: [
                          // 1. Video Area (Top)
                          Container(
                            color: Colors.black,
                            child: AspectRatio(
                        aspectRatio: _isAudio ? 16 / 9 : (_initialized && _controller.value.aspectRatio > 0) ? _controller.value.aspectRatio : 16 / 9,
                        child: LayoutBuilder(
                          builder: (context, constraints) {
                            return Stack(
                              fit: StackFit.expand,
                              children: [
                                if (_initialized)
                                  if (_isAudio)
                                    Container(
                                      color: Colors.black,
                                      child: const Center(
                                        child: Icon(
                                          Icons.music_note,
                                          size: 80,
                                          color: Colors.white24,
                                        ),
                                      ),
                                    )
                                  else
                                    VideoPlayer(_controller)
                                else ...[
                                  if (_currentItem.thumbnailPath != null && File(_currentItem.thumbnailPath!).existsSync())
                                    Image.file(
                                      File(_currentItem.thumbnailPath!),
                                      fit: BoxFit.cover,
                                    )
                                  else
                                    Container(color: Colors.black),
                                  Center(
                                    child: CircularProgressIndicator(
                                      color: Colors.white.withValues(alpha: 0.5),
                                    ),
                                  ),
                                ],
                                if (_isDraggingProgress && !_isLocked)
                                  Positioned.fill(
                                    child: Container(
                                      color: Colors.black.withValues(alpha: _isProgressDragCanceling ? 0.28 : 0.16),
                                      alignment: Alignment.center,
                                      child: Text(
                                        _isProgressDragCanceling ? "松手取消" : "上滑至此区域取消",
                                        style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                                      ),
                                    ),
                                  ),
                                // Visible Subtitles
                                if (_initialized && settings.showSubtitles)
                                  Positioned.fill(
                                    child: SubtitleOverlayGroup(
                                      entries: _currentSubtitleEntries,
                                      alignment: settings.subtitleAlignment,
                                      style: _isAudio ? settings.audioSubtitleStylePortrait : settings.subtitleStylePortrait,
                                      isDragging: _isSubtitleDragMode,
                                      isVisualOnly: false,
                                    ),
                                  ),
                                // Controls Overlay
                                if (_isControllerAssigned && !_isSubtitleDragMode)
                                  VideoControlsOverlay(
                                    controller: _controller,
                                    isLocked: _isLocked,
                                    onTogglePlay: _togglePlay,
                                    onBackPressed: () {
                                      // Reset orientation immediately for smooth transition
                                      SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
                                      Navigator.of(context).maybePop();
                                    },
                                    onSeekTo: (position) {
                                      try {
                                        final playbackService = Provider.of<MediaPlaybackService>(context, listen: false);
                                        if (playbackService.controller == _controller) {
                                          playbackService.seekTo(position);
                                        } else {
                                          _controller.seekTo(position);
                                        }
                                      } catch (_) {
                                        _controller.seekTo(position);
                                      }
                                    },
                                    onExitPressed: () async {
                                      _forceExit = true;
                                      await _handleExit();
                                      SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
                                      if (context.mounted) Navigator.of(context).pop();
                                    },
                                    onToggleSidebar: null,
                                     onToggleFullScreen: () => settings.toggleFullScreen(),
                                     onOpenSettings: null,
                                    onToggleLock: () => setState(() => _isLocked = !_isLocked),
                                    onSpeedUpdate: (speed) {
                                      _controller.setPlaybackSpeed(speed);
                                      settings.updateSetting('playbackSpeed', speed);
                                    },
                                    doubleTapSeekSeconds: settings.doubleTapSeekSeconds,
                                    enableDoubleTapSubtitleSeek: settings.enableDoubleTapSubtitleSeek,
                                    subtitles: _subtitles,
                                    longPressSpeed: settings.longPressSpeed,
                                    showSubtitles: settings.showSubtitles,
                                    onToggleSubtitles: () => _setFloatingSubtitles(!settings.showSubtitles),
                                    onMoveSubtitles: _enterSubtitleDragMode,
                                    subtitleEntries: _currentSubtitleEntries,
                                    subtitleStyle: settings.subtitleStyle,
                                    subtitleAlignment: settings.subtitleAlignment,
                                    onEnterSubtitleDragMode: _enterSubtitleDragMode,
                                    onClearSelection: () => _selectionKey.currentState?.clearSelection(),
                                    showPlayControls: false,
                                    showBottomBar: false,
                                    focusNode: _videoFocusNode, isLongPressing: false, longPressFeedbackText: '', onLongPressStart: () {  }, onLongPressEnd: () {  },
                                  ),
                                // Fullscreen Button (Custom for Portrait)
                                if (!_isLocked && !_isSubtitleDragMode)
                                  Positioned(
                                    bottom: 10,
                                    right: 10,
                                    child: IconButton(
                                      icon: Icon(Icons.fullscreen, color: _initialized ? Colors.white : Colors.white38, size: 30),
                                      onPressed: _initialized ? _goToLandscape : null,
                                      style: IconButton.styleFrom(backgroundColor: Colors.black45),
                                    ),
                                  ),
                                // Drag Mode Layer
                                if (_initialized && _isSubtitleDragMode) ...[
                                  Stack(
                                    fit: StackFit.expand,
                                    children: [
                                      Align(
                                        alignment: settings.subtitleAlignment,
                                        child: GestureDetector(
                                          onPanUpdate: (details) => _updateSubtitlePosition(details, constraints),
                                          child: SubtitleOverlayGroup(
                                            entries: _currentSubtitleEntries,
                                            alignment: settings.subtitleAlignment,
                                            style: _isAudio ? settings.audioSubtitleStylePortrait : settings.subtitleStylePortrait,
                                            isDragging: true,
                                            isGestureOnly: true,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                  if (_isSubtitleSnapped)
                                    Center(
                                      child: Container(
                                        width: 2,
                                        height: double.infinity,
                                        color: Colors.white.withValues(alpha: 0.5),
                                      ),
                                    ),
                                  Positioned(
                                    top: 20,
                                    left: 0,
                                    right: 0,
                                    child: Center(
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                                        decoration: BoxDecoration(
                                          color: Colors.black54,
                                          borderRadius: BorderRadius.circular(20),
                                        ),
                                        child: const Text(
                                          "拖拽调整位置 (点击退出)",
                                          style: TextStyle(color: Colors.white),
                                        ),
                                      ),
                                    ),
                                  ),
                                  Positioned.fill(
                                    child: GestureDetector(
                                      onTap: _exitSubtitleDragMode,
                                      behavior: HitTestBehavior.translucent,
                                      child: Container(),
                                    ),
                                  ),
                                ],
                              ],
                            );
                          },
                        ),
                      ),
                    ),
                    // 2. External Play Controls (Middle) + Bottom Bar
                    Stack(
                      clipBehavior: Clip.none,
                      children: [
                        Column(
                          children: [
                            if (_isControllerAssigned) ...[
                              _buildExternalControls(),
                              _buildBottomControlBar(),
                            ] else
                              const SizedBox(height: 86), // Approximate height placeholder
                          ],
                        ),
                      ],
                    ),
                    // 3. Subtitle Sidebar (Bottom)
                    Expanded(
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 300),
                        layoutBuilder: (Widget? currentChild, List<Widget> previousChildren) {
                          return Stack(
                            alignment: Alignment.topCenter,
                            fit: StackFit.expand,
                            children: <Widget>[
                              ...previousChildren,
                              ...? (currentChild == null ? null : <Widget>[currentChild]),
                            ],
                          );
                        },
                        transitionBuilder: (Widget child, Animation<double> animation) {
                          return SlideTransition(
                            position: Tween<Offset>(
                              begin: const Offset(0.0, 1.0),
                              end: Offset.zero,
                            ).animate(
                              CurvedAnimation(
                                parent: animation,
                                curve: Curves.easeOutCubic,
                              ),
                            ),
                            child: child,
                          );
                        },
                        child: _buildBottomPanel(settings),
                      ),
                    ),
                  ],
                ),
                // Volume Slider Overlay (Global)
                if (_showVolumeSlider && _isControllerAssigned)
                      CompositedTransformFollower(
                        link: _volumeButtonLayerLink,
                        targetAnchor: Alignment.bottomCenter,
                        followerAnchor: Alignment.topCenter,
                        offset: const Offset(0, 5),
                        child: Material(
                          color: Colors.transparent,
                          child: Container(
                            height: 120,
                            width: 32,
                            decoration: BoxDecoration(
                              color: const Color(0xFF1E1E1E),
                              borderRadius: BorderRadius.circular(16),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black45,
                                  blurRadius: 4,
                                  offset: Offset(0, 2),
                                ),
                              ],
                            ),
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            child: RotatedBox(
                              quarterTurns: -1,
                              child: SliderTheme(
                                data: SliderTheme.of(context).copyWith(
                                  activeTrackColor: Colors.white,
                                  inactiveTrackColor: Colors.white24,
                                  thumbColor: Colors.white,
                                  thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6.0),
                                  trackHeight: 2.0,
                                  overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
                                ),
                                child: Slider(
                                  value: _controller.value.volume,
                                  onChanged: (v) => _controller.setVolume(v),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    if (Platform.isIOS)
                      Positioned(
                        left: 0,
                        top: 0,
                        bottom: 0,
                        width: _iosBackSwipeEdgeWidth,
                        child: GestureDetector(
                          behavior: HitTestBehavior.translucent,
                          onHorizontalDragStart: _onIosBackSwipeStart,
                          onHorizontalDragUpdate: _onIosBackSwipeUpdate,
                          onHorizontalDragEnd: _onIosBackSwipeEnd,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    ),
  ),
),
);
},
);
}

  Widget _buildBottomPanel(SettingsService settings) {
    if (!_isControllerAssigned) {
      return const Center(child: CircularProgressIndicator(color: Colors.white24));
    }
    switch (_activePanel) {
      case PortraitPanel.ai:
        return AiTranscriptionPanel(
          videoPath: _currentItem.path,
          onBack: () => setState(() => _activePanel = PortraitPanel.subtitles),
          onCompleted: (path) async {
            final settingsService = Provider.of<SettingsService>(context, listen: false);
            final libraryService = Provider.of<LibraryService>(context, listen: false);

            // Auto load generated subtitle
            if (await File(path).exists()) {
               await _loadSubtitles([path]);
               // Also update library
               libraryService.updateVideoSubtitles(_currentItem.id, path, settingsService.autoCacheSubtitles);
            }
            // Go back to subtitle view
            if (mounted) {
              setState(() => _activePanel = PortraitPanel.subtitles);
            }
          },
        );
      case PortraitPanel.subtitleManager:
        return SubtitleManagementSheet(
          key: ValueKey(_currentItem.path),
          videoPath: _currentItem.path,
          showEmbeddedSubtitles: !(_currentItem.isBilibiliExported),
          additionalSubtitles: _currentItem.additionalSubtitles,
          initialSelectedPaths: _currentSubtitlePaths,
          onSubtitleChanged: () {
            // Reload if needed or handled by logic
          },
          onSubtitleSelected: (paths) async {
             final settingsService = Provider.of<SettingsService>(context, listen: false);
             final libraryService = Provider.of<LibraryService>(context, listen: false);

             await _loadSubtitles(paths);
             if (mounted) {
               String? path0;
               String? path1;
               
               if (paths.isNotEmpty) path0 = paths[0];
               if (paths.length > 1) path1 = paths[1];
               
               libraryService.updateVideoSubtitles(
                     _currentItem.id, 
                     path0, 
                     settingsService.autoCacheSubtitles,
                     secondarySubtitlePath: path1,
                     isSecondaryCached: settingsService.autoCacheSubtitles
                  );
               // Keep open, no pop needed here as it is an inline panel replacement
             }
          },
          onSubtitlePreview: (path) async {
             final settingsService = Provider.of<SettingsService>(context, listen: false);
             final libraryService = Provider.of<LibraryService>(context, listen: false);

             await _loadSubtitles([path]);
             // Do not close panel
             if (mounted) {
               libraryService.updateVideoSubtitles(_currentItem.id, path, settingsService.autoCacheSubtitles);
             }
          },
          onClose: () => setState(() => _activePanel = PortraitPanel.subtitles),
          onOpenAi: () => setState(() => _activePanel = PortraitPanel.ai),
        );
      case PortraitPanel.settings:
        return SettingsPanel(
          key: const ValueKey("SettingsPanel"),
          playbackSpeed: settings.playbackSpeed,
          showSubtitles: settings.showSubtitles,
          isMirroredH: settings.isMirroredH,
          isMirroredV: settings.isMirroredV,
          doubleTapSeekSeconds: settings.doubleTapSeekSeconds,
          enableDoubleTapSubtitleSeek: settings.enableDoubleTapSubtitleSeek,
          onDoubleTapSubtitleSeekChanged: (val) => settings.updateSetting('enableDoubleTapSubtitleSeek', val),
          subtitleDelay: settings.subtitleDelay,
          longPressSpeed: settings.longPressSpeed,
          autoCacheSubtitles: settings.autoCacheSubtitles,
          onSpeedChanged: (val) => settings.updateSetting('playbackSpeed', val),
          onSubtitleToggle: (val) => _setFloatingSubtitles(val),
          onMirrorHChanged: (val) => settings.updateSetting('isMirroredH', val),
          onMirrorVChanged: (val) => settings.updateSetting('isMirroredV', val),
          onSeekSecondsChanged: (val) => settings.updateSetting('doubleTapSeekSeconds', val),
          onSubtitleDelayChanged: (val) => settings.setSubtitleDelay(val), 
          onSubtitleDelayChangeEnd: (val) => settings.saveSubtitleDelay(val),
          onLongPressSpeedChanged: (val) => settings.updateSetting('longPressSpeed', val),
          onAutoCacheSubtitlesChanged: (val) => settings.updateSetting('autoCacheSubtitles', val),
          splitSubtitleByLine: settings.splitSubtitleByLine,
          onSplitSubtitleByLineChanged: (val) => settings.updateSetting('splitSubtitleByLine', val),
          continuousSubtitle: _isAudio ? settings.audioContinuousSubtitle : settings.videoContinuousSubtitle,
          onContinuousSubtitleChanged: (value) {
            if (_isAudio) {
              settings.updateSetting('audioContinuousSubtitle', value);
            } else {
              settings.updateSetting('videoContinuousSubtitle', value);
            }
          },
          autoPauseOnExit: settings.autoPauseOnExit,
          onAutoPauseOnExitChanged: (val) => settings.updateSetting('autoPauseOnExit', val),
          autoPlayNextVideo: settings.autoPlayNextVideo,
          onAutoPlayNextVideoChanged: (val) => settings.updateSetting('autoPlayNextVideo', val),
          enableSeekPreview: settings.enableSeekPreview,
          onEnableSeekPreviewChanged: (val) => settings.updateSetting('enableSeekPreview', val),
          isLeftHandedMode: settings.isLeftHandedMode,
          onLeftHandedModeChanged: (val) => settings.updateSetting('isLeftHandedMode', val),
          onClose: () => setState(() => _activePanel = PortraitPanel.subtitles),
          onLoadSubtitle: _pickSubtitle,
          onOpenSubtitleSettings: _openSubtitleStyleSettings,
        );
      case PortraitPanel.subtitleStyle:
        return SubtitleSettingsSheet(
          key: const ValueKey("SubtitleSettingsSheet"),
          style: _isAudio ? settings.audioSubtitleStylePortrait : settings.subtitleStylePortrait,
          isLandscape: false,
          isAudio: _isAudio,
          // 文字样式改变时同步到横竖屏
          onTextStyleChanged: (newTextStyle) {
            if (_isAudio) {
              settings.saveAudioSubtitleTextStyle(newTextStyle);
            } else {
              settings.saveSubtitleTextStyle(newTextStyle);
            }
          },
          // 布局样式改变时同步到横竖屏
          onLayoutStyleChanged: (newLayoutStyle) {
            if (_isAudio) {
              settings.saveAudioSubtitleLayoutPortrait(newLayoutStyle);
            } else {
              settings.saveSubtitleLayoutPortrait(newLayoutStyle);
            }
          },
          // 向后兼容的回调
          onStyleChanged: (newStyle) {
            if (_isAudio) {
              settings.saveAudioSubtitleStylePortrait(newStyle);
            } else {
              settings.saveSubtitleStylePortrait(newStyle);
            }
          },
          onClose: () => setState(() => _activePanel = PortraitPanel.subtitles),
          onBack: () => setState(() => _activePanel = PortraitPanel.subtitles), // Or settings if navigated from there
        );
      case PortraitPanel.subtitles:
        return SubtitleSidebar(
          key: _subtitleSidebarKey,
          subtitles: _subtitles,
          secondarySubtitles: _secondarySubtitles,
          controller: _controller, 
          onItemTap: _seekToSubtitleFast,
          onClose: () {}, // Maybe close app? or hide sidebar?
          onOpenSettings: () {
            developer.log('Opening settings panel');
            setState(() => _activePanel = PortraitPanel.settings);
          },
          onLoadSubtitle: _pickSubtitle,
          onOpenSubtitleStyle: _openSubtitleStyleSettings,
          onOpenSubtitleManager: () => setState(() => _activePanel = PortraitPanel.subtitleManager),
          onClearSelection: () => _selectionKey.currentState?.clearSelection(),
          onScanEmbeddedSubtitles: _checkAndLoadEmbeddedSubtitle,
          isCompact: true,
          isPortrait: true,
          focusNode: _videoFocusNode,
          isVisible: _activePanel == PortraitPanel.subtitles,
          showEmbeddedLoadingMessage: _embeddedSubtitleDetected &&
              _isLoadingEmbeddedSubtitle &&
              _subtitles.isEmpty &&
              _secondarySubtitles.isEmpty,
        );
    }
  }
}
