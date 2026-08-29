import 'dart:async';
import 'dart:io';
import 'dart:developer' as developer;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';
import '../models/video_item.dart';
import '../models/media_source_ref.dart';
import '../models/subtitle_model.dart';
import '../models/subtitle_style.dart';
import '../models/managed_subtitle_asset.dart';
import '../models/ocr_subtitle_models.dart';
import '../services/library_service.dart';
import '../services/task_subtitle_storage_service.dart';
import '../services/settings_service.dart';
import '../services/media_playback_service.dart';
import '../services/playback_navigation_service.dart';
import '../services/playback_exit_guard.dart';
import '../services/playback_orientation_transition.dart';
import '../services/subtitle_timeline_resolver.dart';
import '../services/video_compose/video_compose_preview_controller.dart';
import '../services/playlist_manager.dart';
import '../widgets/subtitle_sidebar.dart';
import '../widgets/subtitle_settings_sheet.dart';
import '../widgets/video_controls_overlay.dart';
import '../widgets/playback_speed_dialog.dart';
import '../widgets/danmaku_overlay.dart';
import '../widgets/danmaku_settings_dialog.dart';
import '../widgets/subtitle_overlay.dart';
import '../widgets/subtitle_display_layer.dart';
import '../models/subtitle_display_state.dart';
import '../widgets/settings_panel.dart';
import '../widgets/ai_transcription_panel.dart';
import '../services/transcription_manager.dart';
import '../services/ocr_subtitle_manager.dart';
import '../widgets/subtitle_management_sheet.dart';
import 'video_player_screen.dart'; // Landscape screen
import 'music_player_screen.dart'; // Experimental Apple Music page
import 'package:path/path.dart' as p;
import '../services/embedded_subtitle_service.dart';
import '../utils/app_toast.dart';
import '../utils/subtitle_drag_snap.dart';
import '../utils/subtitle_file_picker.dart';

import '../widgets/episode_picker_panel.dart';
import '../widgets/video_compose_panel.dart';
import '../widgets/ocr_subtitle_panel.dart';
import '../widgets/subtitle_editor_panel.dart';

enum PortraitPanel {
  subtitles,
  settings,
  subtitleStyle,
  ai,
  subtitleManager,
  subtitleEditor,
  episodePicker,
  videoCompose,
  ocrSubtitle,
}

class PortraitVideoScreen extends StatefulWidget {
  final VideoItem videoItem;

  const PortraitVideoScreen({super.key, required this.videoItem});

  @override
  State<PortraitVideoScreen> createState() => _PortraitVideoScreenState();
}

class _PortraitVideoScreenState extends State<PortraitVideoScreen>
    with WidgetsBindingObserver, RouteAware {
  final GlobalKey<SelectableRegionState> _selectionKey =
      GlobalKey<SelectableRegionState>();
  final GlobalKey<SubtitleSidebarState> _subtitleSidebarKey =
      GlobalKey<SubtitleSidebarState>();
  final FocusNode _selectionFocusNode = FocusNode();
  final FocusNode _videoFocusNode =
      FocusNode(); // Dedicated focus node for video controls
  final FocusNode _playbackPageFocusNode = FocusNode(
    debugLabel: 'PortraitPlaybackPageShortcutFocus',
  );
  final GlobalKey<VideoControlsOverlayState> _controlsKey =
      GlobalKey<VideoControlsOverlayState>();
  final GlobalKey _videoTextureKey = GlobalKey(
    debugLabel: 'PortraitPlaybackVideoTexture',
  );
  late VideoPlayerController _controller;
  bool _initialized = false;
  bool _isControllerAssigned = false;
  bool _isSourceMissing = false;
  int _danmakuRevision = 0;
  bool _isControllerOwner = true; // 跟踪是否拥有 controller（是否应该在 dispose 时释放）
  bool get _supportsOcrSubtitle =>
      Platform.isAndroid ||
      Platform.isIOS ||
      Platform.isWindows ||
      Platform.isMacOS;
  List<SubtitleItem> _subtitles = [];
  List<SubtitleItem> _secondarySubtitles = [];
  List<String> _currentSubtitlePaths = [];
  int _subtitleRevision = -1;

  // Shared State Logic
  bool _isLocked = false;
  bool _isLongPressing = false;
  String _longPressFeedbackText = "";
  double _preLongPressSpeed = 1.0;
  MediaPlaybackService? _longPressPlaybackService;
  String _currentSubtitleText = "";
  String? _currentSecondaryText;
  int _currentSubtitleIndex = -1;
  int _currentSecondarySubtitleIndex = -1;
  List<int> _currentSubtitleIndices = [];
  List<int> _currentSecondarySubtitleIndices = [];
  List<SubtitleOverlayEntry> _currentSubtitleEntries = [];
  final VideoComposePreviewController _videoComposePreviewController =
      VideoComposePreviewController();
  bool _videoComposePreviewActive = false;
  final Map<int, Uint8List?> _currentSubtitleImages = <int, Uint8List?>{};
  int _subtitleImageRequestId = 0;
  SubtitleTimelineResolver _subtitleTimeline = SubtitleTimelineResolver(
    const <SubtitleItem>[],
  );
  SubtitleTimelineResolver _secondarySubtitleTimeline =
      SubtitleTimelineResolver(const <SubtitleItem>[]);
  Timer? _subtitleSeekTimer;
  bool _isSubtitleDragMode = false;
  bool _isSubtitleSnappedX = false;
  bool _isSubtitleSnappedY = false;
  bool _isSubtitleNearCenterX = false;
  bool _isSubtitleNearCenterY = false;
  bool _isStylePanelDragMode = false;
  PortraitPanel _activePanel = PortraitPanel.subtitles;
  bool get _suppressSubtitleOverlayForOcr =>
      _activePanel == PortraitPanel.ocrSubtitle;
  bool _isSubtitleEditorExpanded = false;

  // Bottom Control Bar State
  bool _isDraggingProgress = false;
  double _dragProgressValue = 0.0;
  bool _isProgressDragCanceling = false;
  final bool _showVolumeSlider = false;
  final LayerLink _volumeButtonLayerLink = LayerLink();

  bool _routeObserverSubscribed = false;
  bool _isPushingLandscape = false;
  bool _isOrientationTransitioning = false;
  bool _pendingSubtitleSidebarViewportRestore = false;
  bool _subtitleSidebarRestoreCallbackScheduled = false;
  bool _forceExit = false;
  final PlaybackExitGuard _exitGuard = PlaybackExitGuard();
  bool _iosBackSwipeActive = false;
  double _iosBackSwipeDistance = 0.0;
  static const double _iosBackSwipeEdgeWidth = 20.0;
  static const double _iosBackSwipeTriggerDistance = 60.0;
  TranscriptionManager? _transcriptionManager;
  OcrSubtitleManager? _ocrSubtitleManager;

  // Audio state
  bool _isAudio = false;
  late VideoItem _currentItem;
  SettingsService? _settingsService;
  bool? _lastShowSubtitles;
  Duration? _lastSubtitleOffset;
  bool? _lastSplitSubtitleByLine;
  bool? _lastVideoContinuousSubtitle;
  bool? _lastAudioContinuousSubtitle;
  bool? _lastSkipPortraitPlayer;
  bool? _lastIsPlayingForServiceSync;
  String? _autoEmbeddedAttemptedForItemId;
  bool _isLoadingEmbeddedSubtitle = false;
  bool _embeddedSubtitleDetected = false;

  Timer? _manualSubtitleWriteTimer;
  Timer? _customAspectDraftSaveTimer;
  int _postInitWorkToken = 0;

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
    FocusManager.instance.addEarlyKeyEventHandler(_handlePlaybackEarlyKeyEvent);
    // Orientation is handled in didChangeDependencies to support tablet adaptive layout
    _initPlayer();
    _scheduleVideoFocusRestore();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        final playbackService = Provider.of<MediaPlaybackService>(
          context,
          listen: false,
        );
        playbackService.addListener(_onPlaybackServiceChange);
        _onPlaybackServiceChange();
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
      _lastSkipPortraitPlayer = settings.skipPortraitPlayer;
      settings.addListener(_onSettingsChanged);
      _onSettingsChanged();
    });
  }

  void _scheduleVideoFocusRestore() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || ModalRoute.of(context)?.isCurrent != true) return;
      final BuildContext? focusContext =
          FocusManager.instance.primaryFocus?.context;
      final bool isEditingText =
          focusContext?.widget is EditableText ||
          focusContext?.findAncestorWidgetOfExactType<EditableText>() != null;
      if (!isEditingText && _videoFocusNode.canRequestFocus) {
        _videoFocusNode.requestFocus();
      }
    });
  }

  void _onSettingsChanged() {
    final settings = _settingsService;
    if (settings == null) return;

    // 「跳过竖屏播放页」需独立于字幕缓存比对，在字幕无关的设置变更中也
    // 能即时响应（off→on 边沿触发一次）。
    _handleSkipPortraitPlayerChanged(settings.skipPortraitPlayer);

    final bool changed =
        _lastShowSubtitles != settings.showSubtitles ||
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

  /// 「跳过竖屏播放页」在竖屏页内被打开时，立即切入横屏播放页。
  ///
  /// 仅在 off→on 边沿触发一次，且要求当前路由位于栈顶、没有正在进行的
  /// 横屏跳转，避免横屏页覆盖本页时误触发或重复导航。
  void _handleSkipPortraitPlayerChanged(bool enabled) {
    final bool? previous = _lastSkipPortraitPlayer;
    _lastSkipPortraitPlayer = enabled;
    if (previous != false || !enabled) return;
    if (!mounted || _isPushingLandscape) return;
    if (ModalRoute.of(context)?.isCurrent != true) return;
    _goToLandscape();
  }

  void _applyItemSubtitlePreference(VideoItem item, {bool force = false}) {
    final settings =
        _settingsService ??
        Provider.of<SettingsService>(context, listen: false);
    if (force || item.showFloatingSubtitles != settings.showSubtitles) {
      item.showFloatingSubtitles = settings.showSubtitles;
    }
  }

  void _setFloatingSubtitles(bool value) {
    final settings =
        _settingsService ??
        Provider.of<SettingsService>(context, listen: false);
    settings.saveShowSubtitles(value);
    final currentItem = _currentItem;
    currentItem.showFloatingSubtitles = value;
  }

  void _scheduleDeferredPostInitWork(VideoItem item) {
    final int token = ++_postInitWorkToken;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || token != _postInitWorkToken) return;
      unawaited(_runDeferredPostInitWork(item, token));
    });
  }

  Future<void> _runDeferredPostInitWork(VideoItem item, int token) async {
    if (!mounted || token != _postInitWorkToken) return;
    _checkAndLoadAiSubtitle(item);

    if (item.subtitlePath != null) {
      final List<String> paths = [item.subtitlePath!];
      if (item.secondarySubtitlePath != null) {
        paths.add(item.secondarySubtitlePath!);
      }
      await _loadSubtitles(paths);
    } else {
      final loadedAssociated = await _tryLoadAssociatedSubtitleAsPrimary(item);
      if (!loadedAssociated && mounted && token == _postInitWorkToken) {
        _maybeAutoLoadEmbeddedSubtitle();
      }
    }

    if (!mounted || token != _postInitWorkToken) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && token == _postInitWorkToken) {
        _updateSubtitle();
      }
    });
  }

  void _bindControllerListener() {
    try {
      _controller.removeListener(_videoListener);
    } catch (_) {}
    _controller.addListener(_videoListener);
  }

  void _showMissingSource(VideoItem item) {
    if (_isSourceMissing && _isControllerAssigned) {
      return;
    }

    VideoPlayerController? previousController;
    final bool disposePrevious = _isControllerAssigned && _isControllerOwner;
    if (_isControllerAssigned) {
      previousController = _controller;
      try {
        previousController.removeListener(_videoListener);
      } catch (_) {}
    }

    _controller = VideoPlayerController.file(
      File(item.path),
      videoPlayerOptions: MediaPlaybackService.buildVideoPlayerOptions(
        settings: _settingsService ?? SettingsService(),
      ),
    );
    _isControllerAssigned = true;
    _isControllerOwner = true;
    _bindControllerListener();

    if (disposePrevious && previousController != null) {
      unawaited(previousController.dispose());
    }

    if (!mounted) return;
    setState(() {
      _currentItem = item;
      _isAudio = item.type == MediaType.audio;
      _isSourceMissing = true;
      _initialized = false;
      _lastIsPlayingForServiceSync = false;
    });
  }

  void _onPlaybackServiceChange() {
    if (!mounted) return;
    final service = Provider.of<MediaPlaybackService>(context, listen: false);

    // 检查当前路由是否在最顶层（即竖屏页是否可见）
    // 如果不在最顶层（被横屏页覆盖），则不处理控制器变更，只更新字幕等状态
    final bool isOnTop = ModalRoute.of(context)?.isCurrent ?? false;

    if (service.currentItem?.id == _currentItem.id && service.isSourceMissing) {
      _showMissingSource(service.currentItem!);
      _syncSubtitlesFromService(service);
      return;
    }
    if (service.currentItem?.id == _currentItem.id &&
        service.state == PlaybackState.loading &&
        _isSourceMissing) {
      setState(() => _isSourceMissing = false);
    }

    if (service.currentItem != null &&
        service.currentItem!.id != _currentItem.id) {
      // 视频发生变化
      if (isOnTop) {
        // 竖屏页在最顶层，正常处理视频切换
        setState(() {
          _currentItem = service.currentItem!;
          _isAudio = service.currentItem!.type == MediaType.audio;
          _isSourceMissing = false;
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
        _postInitWorkToken++;
        _initPlayer();
      } else {
        // 竖屏页在后台（被横屏页覆盖），只更新当前项信息，不处理控制器
        // 这样当返回竖屏页时，会重新同步状态
        setState(() {
          _currentItem = service.currentItem!;
          _isAudio = service.currentItem!.type == MediaType.audio;
          _isSourceMissing = false;
          _initialized = false;
          _isControllerAssigned = false;
        });
        // 不调用 _initPlayer，让页面重新可见时再处理
      }
    } else if (service.currentItem?.id == _currentItem.id &&
        service.state != PlaybackState.loading &&
        service.controller != null &&
        (!_initialized ||
            !_isControllerAssigned ||
            !identical(_controller, service.controller))) {
      if (_isControllerAssigned &&
          !identical(_controller, service.controller)) {
        final previousController = _controller;
        final shouldDisposePrevious = _isControllerOwner;
        try {
          previousController.removeListener(_videoListener);
        } catch (_) {}
        setState(() {
          _isControllerAssigned = false;
          _isControllerOwner = false;
          _initialized = false;
        });
        if (shouldDisposePrevious) {
          unawaited(previousController.dispose());
        }
      }
      // ID 没变，但之前因为 Loading 等待了，现在 Service 准备好了 -> 重试初始化
      _postInitWorkToken++;
      _initPlayer();
    } else if (service.currentItem?.id == _currentItem.id) {
      _syncSubtitlesFromService(service);
    }
  }

  /// Sync subtitle state from [MediaPlaybackService] to local state if the
  /// service's subtitle data differs from the local copy. Called from
  /// [_onPlaybackServiceChange] for live updates and from [_goToLandscape]'s
  /// continuation to catch any subtitle changes that occurred while the
  /// portrait page was in the background (covered by the landscape page).
  void _syncSubtitlesFromService(MediaPlaybackService service) {
    if (!mounted) return;
    if (service.currentItem?.id != _currentItem.id) return;

    if (_subtitleRevision == service.subtitleRevision) return;

    setState(() {
      _subtitleRevision = service.subtitleRevision;
      _subtitles = List<SubtitleItem>.from(service.subtitles);
      _secondarySubtitles = List<SubtitleItem>.from(service.secondarySubtitles);
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

  Matrix4 _buildVideoDisplayTransformMatrix() {
    return Matrix4.identity()..multiply(
      Matrix4.diagonal3Values(
        _currentItem.isVideoMirroredH ? -1.0 : 1.0,
        _currentItem.isVideoMirroredV ? -1.0 : 1.0,
        1.0,
      ),
    );
  }

  Future<void> _updateVideoDisplayTransform({
    bool? isMirroredH,
    bool? isMirroredV,
  }) async {
    final bool nextMirroredH = isMirroredH ?? _currentItem.isVideoMirroredH;
    final bool nextMirroredV = isMirroredV ?? _currentItem.isVideoMirroredV;

    setState(() {
      _currentItem.isVideoMirroredH = nextMirroredH;
      _currentItem.isVideoMirroredV = nextMirroredV;
    });

    final library = Provider.of<LibraryService>(context, listen: false);
    await library.updateVideoDisplayTransform(
      _currentItem.id,
      isMirroredH: nextMirroredH,
      isMirroredV: nextMirroredV,
    );
  }

  String? _resolveFirstAssociatedSubtitlePath(VideoItem item) {
    final associated = item.downloadAssociatedSubtitles;
    if (associated.isEmpty) return null;
    for (final path in associated.values) {
      if (path.isEmpty) continue;
      final normalized = p.normalize(path);
      if (File(normalized).existsSync()) {
        return normalized;
      }
    }
    return null;
  }

  Future<void> _persistPrimarySubtitlePathIfNeeded(
    String subtitlePath, {
    String? secondarySubtitlePath,
  }) async {
    final normalizedPrimary = p.normalize(subtitlePath);
    final currentPrimary = _currentItem.subtitlePath == null
        ? null
        : p.normalize(_currentItem.subtitlePath!);
    if (currentPrimary == normalizedPrimary) return;
    try {
      final settingsService = Provider.of<SettingsService>(
        context,
        listen: false,
      );
      final libraryService = Provider.of<LibraryService>(
        context,
        listen: false,
      );
      await libraryService.updateVideoSubtitles(
        _currentItem.id,
        normalizedPrimary,
        settingsService.autoCacheSubtitles,
        secondarySubtitlePath: secondarySubtitlePath,
        isSecondaryCached: settingsService.autoCacheSubtitles,
      );
      if (mounted) {
        final updated = libraryService.getVideo(_currentItem.id);
        if (updated != null) {
          setState(() {
            _currentItem = updated;
          });
        }
      }
    } catch (_) {}
  }

  Future<bool> _tryLoadAssociatedSubtitleAsPrimary(VideoItem item) async {
    if (item.blockAutoAssociatedSubtitleSelection) {
      return false;
    }
    final associatedPath = _resolveFirstAssociatedSubtitlePath(item);
    if (associatedPath == null) {
      return false;
    }

    await _persistPrimarySubtitlePathIfNeeded(
      associatedPath,
      secondarySubtitlePath: item.secondarySubtitlePath,
    );
    if (!mounted) {
      return true;
    }

    final refreshedItem = _currentItem;
    final primaryPath = refreshedItem.subtitlePath ?? associatedPath;
    final paths = <String>[primaryPath];
    final secondaryPath = refreshedItem.secondarySubtitlePath;
    if (secondaryPath != null &&
        secondaryPath.isNotEmpty &&
        secondaryPath != primaryPath) {
      paths.add(secondaryPath);
    }
    await _loadSubtitles(paths);
    return true;
  }

  void _maybeAutoLoadEmbeddedSubtitle() {
    final currentId = _currentItem.id;
    if (_currentItem.blockAutoAssociatedSubtitleSelection) return;
    if (_currentItem.prefersManagedAssociatedSubtitles) return;
    if (_currentItem.hasAttemptedAutoEmbeddedSubtitleLoad) return;
    if (_autoEmbeddedAttemptedForItemId == currentId) return;
    if (_currentItem.subtitlePath != null) return;
    if (_currentSubtitlePaths.isNotEmpty) return;
    if (_subtitles.isNotEmpty || _secondarySubtitles.isNotEmpty) return;
    try {
      final service = Provider.of<MediaPlaybackService>(context, listen: false);
      if (service.subtitlePaths.isNotEmpty ||
          service.subtitles.isNotEmpty ||
          service.secondarySubtitles.isNotEmpty) {
        return;
      }
    } catch (_) {}

    _currentItem.hasAttemptedAutoEmbeddedSubtitleLoad = true;
    _persistAutoEmbeddedAttemptedFlag(currentId);
    _autoEmbeddedAttemptedForItemId = currentId;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _checkAndLoadEmbeddedSubtitle(
        showToastWhenNone: false,
        showLoadingIndicator: false,
      );
    });
  }

  Future<void> _persistAutoEmbeddedAttemptedFlag(String videoId) async {
    try {
      final library = Provider.of<LibraryService>(context, listen: false);
      await library.markAutoEmbeddedSubtitleLoadAttempted(videoId);
      if (!mounted) return;
      final refreshed = library.getVideo(videoId);
      if (refreshed != null) {
        setState(() {
          _currentItem = refreshed;
        });
      }
    } catch (_) {}
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
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      MediaPlaybackService().setPlaybackPageVisible(
        this,
        ModalRoute.of(context)?.isCurrent == true,
      );
    });

    // Listen to TranscriptionManager for auto-mounting subtitles
    final manager = Provider.of<TranscriptionManager>(context, listen: false);
    if (_transcriptionManager != manager) {
      _transcriptionManager?.removeListener(_onTranscriptionUpdate);
      _transcriptionManager = manager;
      _transcriptionManager?.addListener(_onTranscriptionUpdate);
    }

    final ocrManager = Provider.of<OcrSubtitleManager>(context, listen: false);
    if (_ocrSubtitleManager != ocrManager) {
      _ocrSubtitleManager?.removeListener(_onOcrSubtitleUpdate);
      _ocrSubtitleManager = ocrManager;
      _ocrSubtitleManager?.addListener(_onOcrSubtitleUpdate);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _onOcrSubtitleUpdate();
      });
    }
  }

  void _onOcrSubtitleUpdate() {
    if (!mounted || _ocrSubtitleManager == null) return;
    final job = _ocrSubtitleManager!.job;
    if (job?.status != OcrSubtitleJobStatus.completed) return;
    final paths = _ocrSubtitleManager!.consumeCompletedPaths(job!.videoId);
    if (paths == null || paths.isEmpty) return;
    if (_currentItem.id == job.videoId) {
      unawaited(_applyCompletedOcrSubtitles(paths));
    } else {
      AppToast.show('OCR 字幕已生成并保存到字幕管理', type: AppToastType.success);
    }
  }

  void _onTranscriptionUpdate() {
    if (!mounted || _transcriptionManager == null) return;

    final path = _transcriptionManager!.getGeneratedSrtPathForVideo(
      _currentItem.path,
      videoId: _currentItem.id,
    );
    if (path != null &&
        _transcriptionManager!.consumeResultNotificationForVideo(
          _currentItem.path,
          videoId: _currentItem.id,
        )) {
      // Avoid repeated loading if already loaded as primary
      if (_currentSubtitlePaths.isNotEmpty &&
          _currentSubtitlePaths[0] == path) {
        return;
      }

      // 保留当前已加载的副字幕
      List<String> pathsToLoad = [path];
      if (_currentSubtitlePaths.length > 1) {
        pathsToLoad.add(_currentSubtitlePaths[1]);
      }

      // Auto load
      _loadSubtitles(pathsToLoad);

      // 不需要在这里保存到 library，TranscriptionManager 已经保存了

      // Show notification
      AppToast.show("AI 字幕转录完成并已自动加载", type: AppToastType.success);
    }
  }

  void _checkAndLoadAiSubtitle(VideoItem currentItem) {
    try {
      final manager = Provider.of<TranscriptionManager>(context, listen: false);

      final srtPath = manager.getGeneratedSrtPathForVideo(
        currentItem.path,
        videoId: currentItem.id,
      );
      if (srtPath != null) {
        if (File(srtPath).existsSync()) {
          debugPrint("检测到AI字幕已完成，自动加载: $srtPath");

          List<String> pathsToLoad = [srtPath];
          if (currentItem.secondarySubtitlePath != null) {
            pathsToLoad.add(currentItem.secondarySubtitlePath!);
          }

          _loadSubtitles(pathsToLoad);

          if (mounted &&
              manager.consumeResultNotificationForVideo(
                currentItem.path,
                videoId: currentItem.id,
              )) {
            AppToast.show("AI 字幕已自动加载", type: AppToastType.success);
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

  bool get _usesAndroidPhoneOrientationBridge {
    if (kIsWeb || !Platform.isAndroid || !mounted) return false;
    final display = View.of(context).display;
    final pixelRatio = display.devicePixelRatio;
    return pixelRatio > 0 && display.size.shortestSide / pixelRatio < 600;
  }

  Future<bool> _waitForPlaybackViewport(PlaybackViewportOrientation target) {
    final view = View.of(context);
    return PlaybackOrientationTransition.waitForViewport(
      readSize: () => view.physicalSize,
      waitForFrame: () => WidgetsBinding.instance.endOfFrame,
      target: target,
      readStabilitySignature: () =>
          PlaybackOrientationTransition.metricsSignature(view),
    );
  }

  Future<void> _showOrientationBridge() async {
    if (!_usesAndroidPhoneOrientationBridge || !mounted) return;
    setState(() {
      _isOrientationTransitioning = true;
    });
    await WidgetsBinding.instance.endOfFrame;
  }

  Future<void> _hideOrientationBridge() async {
    if (!mounted || !_isOrientationTransitioning) return;
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    setState(() {
      _isOrientationTransitioning = false;
    });
  }

  void _scheduleUpdateOrientations() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _updateOrientations();
    });
  }

  bool _isPortraitSidebarViewportReady() {
    final mediaQuery = MediaQuery.maybeOf(context);
    if (mediaQuery == null) return false;
    final Size size = mediaQuery.size;
    // Tablets intentionally keep the portrait-player layout available in
    // either physical orientation. Phones must wait for the actual portrait
    // metrics; locating against the transient landscape viewport can leave
    // ScrollablePositionedList with no painted children after the pop.
    return size.shortestSide >= 600 || size.height >= size.width;
  }

  void _requestSubtitleSidebarViewportRestore() {
    _pendingSubtitleSidebarViewportRestore = true;
    _tryRestoreSubtitleSidebarForCurrentViewport();
  }

  void _tryRestoreSubtitleSidebarForCurrentViewport() {
    if (!mounted ||
        !_pendingSubtitleSidebarViewportRestore ||
        _subtitleSidebarRestoreCallbackScheduled) {
      return;
    }
    _subtitleSidebarRestoreCallbackScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _subtitleSidebarRestoreCallbackScheduled = false;
      if (!mounted || !_pendingSubtitleSidebarViewportRestore) return;
      if (ModalRoute.of(context)?.isCurrent != true ||
          !_isPortraitSidebarViewportReady()) {
        return;
      }
      if (_activePanel != PortraitPanel.subtitles) {
        _pendingSubtitleSidebarViewportRestore = false;
        return;
      }

      final sidebar = _subtitleSidebarKey.currentState;
      if (sidebar == null) return;
      _pendingSubtitleSidebarViewportRestore = false;
      // Route restoration is a viewport repair, not playback auto-follow. It
      // must run while paused and when automatic following is disabled.
      sidebar.locateToCurrentSubtitle(ignorePointer: true);
    });
  }

  @override
  void didPush() {
    MediaPlaybackService().setPlaybackPageVisible(this, true);
    _scheduleUpdateOrientations();
  }

  @override
  void didPopNext() {
    MediaPlaybackService().setPlaybackPageVisible(this, true);
    _scheduleUpdateOrientations();
    _scheduleVideoFocusRestore();
    // RouteAware also reports dialogs and unrelated child pages. Only a
    // landscape-player pop owns this viewport repair; otherwise returning
    // from settings could unexpectedly move a manually scrolled transcript.
    if (_isPushingLandscape) {
      _requestSubtitleSidebarViewportRestore();
    }
  }

  @override
  void didPushNext() {
    if (_isPushingLandscape) return;
    MediaPlaybackService().setPlaybackPageVisible(this, false);
    SystemChrome.setPreferredOrientations([]);
  }

  @override
  void didPop() {
    MediaPlaybackService().setPlaybackPageVisible(this, false);
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
      final service = Provider.of<EmbeddedSubtitleService>(
        context,
        listen: false,
      );
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

        final settings = Provider.of<SettingsService>(context, listen: false);
        final subDir = await const TaskSubtitleStorageService().taskDirectory(
          _currentItem.id,
          create: true,
        );

        // Extract
        final extractedPath = await service.extractSubtitle(
          path,
          track.index,
          subDir.path,
          codecName: track.codecName,
          videoId: _currentItem.id,
        );

        if (extractedPath != null) {
          await library.registerManagedSubtitleAsset(
            _currentItem.id,
            path: extractedPath,
            kind: ManagedSubtitleAssetKind.embedded,
            displayName: track.title,
          );
        }

        if (extractedPath != null && mounted) {
          // Check again
          if (_subtitles.isNotEmpty) return;

          List<String> pathsToLoad = [extractedPath];
          if (_currentSubtitlePaths.length > 1) {
            pathsToLoad.add(_currentSubtitlePaths[1]);
          }
          await _loadSubtitles(pathsToLoad);
          if (mounted) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              _subtitleSidebarKey.currentState?.jumpToFirstSubtitleTop();
            });
          }

          if (_currentItem.subtitlePath == null) {
            try {
              final String? currentSecondary = _currentSubtitlePaths.length > 1
                  ? _currentSubtitlePaths[1]
                  : _currentItem.secondarySubtitlePath;
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
      final libItem = Provider.of<LibraryService>(
        context,
        listen: false,
      ).getVideo(currentItem.id);
      if (libItem != null && libItem.lastUpdated >= currentItem.lastUpdated) {
        currentItem = libItem;
      }
    } catch (e) {
      debugPrint("Error refreshing item: $e");
    }
    _currentItem = currentItem;
    _applyItemSubtitlePreference(currentItem, force: true);
    final settingsService =
        _settingsService ??
        Provider.of<SettingsService>(context, listen: false);

    // Check if this is audio
    _isAudio = currentItem.type == MediaType.audio;

    // 检查 MediaPlaybackService 状态
    try {
      final playbackService = Provider.of<MediaPlaybackService>(
        context,
        listen: false,
      );

      if (playbackService.currentItem?.id == currentItem.id &&
          playbackService.isSourceMissing) {
        _showMissingSource(currentItem);
        _syncSubtitlesFromService(playbackService);
        return;
      }

      // 如果 Service 正在加载此视频，等待它完成
      if (playbackService.currentItem?.id == currentItem.id &&
          playbackService.state == PlaybackState.loading) {
        debugPrint(
          "PortraitVideoScreen: Waiting for service to load ${currentItem.title}",
        );
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

        await _applyInitialPortraitDefaultAspectRatioIfNeeded();

        setState(() {
          _isSourceMissing = false;
          _initialized = true;
        });

        _bindControllerListener();
        _scheduleDeferredPostInitWork(currentItem);

        // MediaPlaybackService owns the authoritative position and state for
        // this controller. Do not read the native position here: an online
        // backend can briefly expose its byte-zero probe during hand-off.
        if (playbackService.isPlaying) {
          if (!_controller.value.isPlaying) playbackService.resume();
        } else {
          if (_controller.value.isPlaying) playbackService.pause();
        }
        return;
      }
    } catch (e) {
      debugPrint("无法获取 MediaPlaybackService: $e");
      // 继续使用原有逻辑创建新的 controller
    }

    try {
      final playbackService = Provider.of<MediaPlaybackService>(
        context,
        listen: false,
      );
      if (playbackService.currentItem?.id != currentItem.id ||
          playbackService.controller == null) {
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
    _controller = VideoPlayerController.file(
      file,
      videoPlayerOptions: MediaPlaybackService.buildVideoPlayerOptions(
        settings: SettingsService(),
      ),
    );
    _isControllerAssigned = true;
    final libraryService = Provider.of<LibraryService>(context, listen: false);
    final playbackService = Provider.of<MediaPlaybackService>(
      context,
      listen: false,
    );

    if (!await file.exists()) {
      developer.log('Video file not found: ${currentItem.path}');
      _showMissingSource(currentItem);
      return;
    }

    try {
      // Add timeout to prevent hanging if file is problematic
      await _controller.initialize().timeout(const Duration(seconds: 10));

      if (!mounted) return;

      await _applyInitialPortraitDefaultAspectRatioIfNeeded();

      // Update duration if missing
      final duration = _controller.value.duration.inMilliseconds;

      if (currentItem.durationMs == 0 || currentItem.durationMs != duration) {
        libraryService.updateVideoDuration(currentItem.id, duration);
      }

      // Seek to last position
      if (currentItem.lastPositionMs > 0) {
        await _controller.seekTo(
          Duration(milliseconds: currentItem.lastPositionMs),
        );
      }

      // Apply global settings
      await _controller.setPlaybackSpeed(
        settingsService.effectiveGlobalPlaybackSpeed,
      );

      setState(() {
        _isSourceMissing = false;
        _initialized = true;
      });
      _bindControllerListener();
      _scheduleDeferredPostInitWork(currentItem);

      try {
        final bool shouldResumeAfterAttach = playbackService.isPlaying;
        await playbackService.setController(_controller);
        await playbackService.updateMetadata(currentItem);
        if (shouldResumeAfterAttach) {
          await playbackService.resume();
        }
      } catch (e) {
        debugPrint("Failed to register controller with service: $e");
      }
    } catch (e) {
      developer.log('Error initializing player', error: e);
      if (await File(currentItem.path).exists()) {
        if (!mounted) return;
        AppToast.show("无法加载视频", type: AppToastType.error);
      } else {
        _showMissingSource(currentItem);
      }
    }
  }

  void _videoListener() {
    final isPlayingNow = _controller.value.isPlaying;
    if (_lastIsPlayingForServiceSync != isPlayingNow) {
      _lastIsPlayingForServiceSync = isPlayingNow;
      try {
        final playbackService = Provider.of<MediaPlaybackService>(
          context,
          listen: false,
        );
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
    if (_videoComposePreviewActive) {
      _videoComposePreviewController.update(_controller.value.position);
    }

    if (!settings.showSubtitles) {
      if (_currentSubtitleText.isNotEmpty ||
          _currentSecondaryText != null ||
          _currentSubtitleIndex != -1 ||
          _currentSecondarySubtitleIndex != -1 ||
          _currentSubtitleEntries.isNotEmpty) {
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
    final continuousSubtitleEnabled = _isAudio
        ? settings.audioContinuousSubtitle
        : settings.videoContinuousSubtitle;

    if (_subtitleTimeline.length != _subtitles.length ||
        _secondarySubtitleTimeline.length != _secondarySubtitles.length) {
      _rebuildSubtitleIndex();
    }

    final List<int> primaryIndices = _subtitles.isEmpty
        ? <int>[]
        : _subtitleTimeline.activeIndicesAtMs(
            posMs,
            extendToNextStart: continuousSubtitleEnabled,
          );
    final List<int> secondaryIndices = _secondarySubtitles.isEmpty
        ? <int>[]
        : _secondarySubtitleTimeline.activeIndicesAtMs(
            posMs,
            extendToNextStart: continuousSubtitleEnabled,
          );

    final List<SubtitleItem> secondaryOverlapItems = secondaryIndices
        .map((i) => _secondarySubtitles[i])
        .toList();
    final List<SubtitleOverlayEntry> entries = <SubtitleOverlayEntry>[];

    if (primaryIndices.isNotEmpty) {
      for (final int index in primaryIndices) {
        final SubtitleItem item = _subtitles[index];
        final Uint8List? image = _currentSubtitleImages[index];
        final bool hasImage = item.imageLoader != null;
        String text = hasImage ? "" : item.text;
        String? secondaryText;

        if (!hasImage &&
            _secondarySubtitles.isEmpty &&
            settings.splitSubtitleByLine) {
          if (text.contains('\n')) {
            final lines = text.split('\n');
            text = lines[0];
            secondaryText = lines.sublist(1).join('\n');
          }
        } else if (!hasImage && secondaryOverlapItems.isNotEmpty) {
          SubtitleItem? best;
          int bestDelta = 1 << 30;
          for (final sec in secondaryOverlapItems) {
            final int delta =
                (sec.startTime.inMilliseconds - item.startTime.inMilliseconds)
                    .abs();
            if (delta < bestDelta) {
              bestDelta = delta;
              best = sec;
            }
          }
          secondaryText = best?.text;
        }

        entries.add(
          SubtitleOverlayEntry(
            index: index,
            text: text,
            secondaryText: hasImage ? null : secondaryText,
            image: image,
          ),
        );
      }
    } else if (secondaryIndices.isNotEmpty) {
      for (final int index in secondaryIndices) {
        final SubtitleItem item = _secondarySubtitles[index];
        entries.add(
          SubtitleOverlayEntry(
            index: null,
            text: "",
            secondaryText: item.text,
            image: null,
          ),
        );
      }
    }

    final int anchorPrimaryIndex = primaryIndices.isNotEmpty
        ? primaryIndices.first
        : -1;
    final int anchorSecondaryIndex = secondaryIndices.isNotEmpty
        ? secondaryIndices.first
        : -1;
    final SubtitleOverlayEntry? anchorEntry = entries.isNotEmpty
        ? entries.first
        : null;
    final bool indicesChanged =
        !_areIntListsEqual(primaryIndices, _currentSubtitleIndices) ||
        !_areIntListsEqual(secondaryIndices, _currentSecondarySubtitleIndices);
    final bool entriesChanged = !_areSubtitleEntryListsEqual(
      entries,
      _currentSubtitleEntries,
    );
    final bool anchorChanged =
        anchorPrimaryIndex != _currentSubtitleIndex ||
        anchorSecondaryIndex != _currentSecondarySubtitleIndex;

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

  void _seekPlaybackPosition(
    Duration target, {
    bool syncSubtitleSidebar = false,
  }) {
    if (!_initialized || !_controller.value.isInitialized) return;
    final duration = _controller.value.duration;
    Duration clamped = target;
    if (clamped < Duration.zero) clamped = Duration.zero;
    if (duration > Duration.zero && clamped > duration) clamped = duration;

    _subtitleSeekTimer?.cancel();
    _subtitleSeekTimer = null;
    if (syncSubtitleSidebar && _activePanel == PortraitPanel.subtitles) {
      _subtitleSidebarKey.currentState?.locateToTime(clamped);
    }
    try {
      final playbackService = Provider.of<MediaPlaybackService>(
        context,
        listen: false,
      );
      if (playbackService.controller == _controller) {
        playbackService.seekTo(clamped);
      } else {
        _controller.seekTo(clamped);
      }
    } catch (_) {
      _controller.seekTo(clamped);
    }
  }

  void _seekToSubtitleFast(Duration target) {
    _seekPlaybackPosition(target);
  }

  void _togglePlay() {
    if (_isSourceMissing) {
      final playbackService = Provider.of<MediaPlaybackService>(
        context,
        listen: false,
      );
      unawaited(playbackService.resume());
      return;
    }
    try {
      final playbackService = Provider.of<MediaPlaybackService>(
        context,
        listen: false,
      );
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

  bool _startLongPressSpeed() {
    if (_isSourceMissing) return false;
    final settings =
        _settingsService ??
        Provider.of<SettingsService>(context, listen: false);
    MediaPlaybackService? playbackService;
    try {
      final candidate = Provider.of<MediaPlaybackService>(
        context,
        listen: false,
      );
      if (candidate.controller == _controller) playbackService = candidate;
    } catch (_) {}
    _longPressPlaybackService = playbackService;
    _preLongPressSpeed =
        playbackService?.confirmedPlaybackSpeed ??
        _controller.value.playbackSpeed;
    _isLongPressing = true;
    _longPressFeedbackText = "${settings.longPressSpeed}x";
    unawaited(
      playbackService?.beginTemporaryPlaybackSpeed(settings.longPressSpeed) ??
          _controller.setPlaybackSpeed(settings.longPressSpeed),
    );
    return true;
  }

  void _endLongPressSpeed() {
    if (!_isLongPressing) return;
    _isLongPressing = false;
    _controlsKey.currentState?.cancelLongPressFeedback();
    final playbackService = _longPressPlaybackService;
    _longPressPlaybackService = null;
    unawaited(
      playbackService?.endTemporaryPlaybackSpeed() ??
          _controller.setPlaybackSpeed(_preLongPressSpeed),
    );
  }

  Future<void> _syncPlaybackSpeedToCurrentController(double speed) async {
    if (_isSourceMissing) return;
    try {
      final playbackService = Provider.of<MediaPlaybackService>(
        context,
        listen: false,
      );
      if (playbackService.controller == _controller) {
        await playbackService.setPlaybackSpeed(speed);
        return;
      }
    } catch (_) {}
    await _controller.setPlaybackSpeed(speed);
  }

  Future<void> _handlePlaybackSpeedSelected(double speed) async {
    await _syncPlaybackSpeedToCurrentController(speed);
  }

  Future<void> _handlePlaybackSpeedLockChanged(
    double speed,
    bool locked,
  ) async {
    final settings =
        _settingsService ??
        Provider.of<SettingsService>(context, listen: false);
    await settings.setPlaybackSpeedLock(speed, locked);
    await _syncPlaybackSpeedToCurrentController(speed);
  }

  void _enterSubtitleDragMode() {
    setState(() {
      _isSubtitleDragMode = true;
      _isStylePanelDragMode = false;
      _isSubtitleSnappedX = false;
      _isSubtitleSnappedY = false;
      _isSubtitleNearCenterX = false;
      _isSubtitleNearCenterY = false;
    });
  }

  void _exitSubtitleDragMode() {
    setState(() {
      _isSubtitleDragMode = false;
      _isStylePanelDragMode = false;
      _isSubtitleSnappedX = false;
      _isSubtitleSnappedY = false;
      _isSubtitleNearCenterX = false;
      _isSubtitleNearCenterY = false;
    });
  }

  void _enableStylePanelDragMode() {
    setState(() {
      _isStylePanelDragMode = true;
      _isSubtitleDragMode = true;
      _isSubtitleSnappedX = false;
      _isSubtitleSnappedY = false;
      _isSubtitleNearCenterX = false;
      _isSubtitleNearCenterY = false;
    });
  }

  void _disableStylePanelDragMode() {
    setState(() {
      _isStylePanelDragMode = false;
      _isSubtitleDragMode = false;
      _isSubtitleSnappedX = false;
      _isSubtitleSnappedY = false;
      _isSubtitleNearCenterX = false;
      _isSubtitleNearCenterY = false;
    });
  }

  void _updateSubtitlePosition(
    DragUpdateDetails details,
    BoxConstraints constraints,
  ) {
    final settings = Provider.of<SettingsService>(context, listen: false);
    final currentAlignment = _isAudio
        ? settings.audioSubtitleAlignment
        : settings.subtitleAlignment;
    final snapResult = resolveSubtitleDragSnap(
      currentAlignment: currentAlignment,
      dragDelta: details.delta,
      dragBounds: Size(constraints.maxWidth, constraints.maxHeight),
      wasSnappedX: _isSubtitleSnappedX,
      wasSnappedY: _isSubtitleSnappedY,
    );

    if (_isAudio) {
      settings.saveAudioSubtitleAlignment(snapResult.alignment);
    } else {
      settings.saveSubtitleAlignment(snapResult.alignment);
    }
    setState(() {
      _isSubtitleSnappedX = snapResult.snappedX;
      _isSubtitleSnappedY = snapResult.snappedY;
      _isSubtitleNearCenterX = snapResult.guideX;
      _isSubtitleNearCenterY = snapResult.guideY;
    });
  }

  Widget _buildPageSubtitleOverlay({
    required Alignment alignment,
    required SubtitleStyle style,
    bool isDragging = false,
    bool isGestureOnly = false,
    bool enablePanUpdate = false,
    ValueListenable<SubtitleDisplayState>? displayNotifier,
  }) {
    return Positioned.fill(
      child: LayoutBuilder(
        builder: (context, constraints) {
          Widget overlay = SizedBox.expand(
            child: displayNotifier == null
                ? SubtitleOverlayGroup(
                    entries: _currentSubtitleEntries,
                    alignment: alignment,
                    style: style,
                    isDragging: isDragging,
                    isGestureOnly: isGestureOnly,
                  )
                : SubtitleDisplayLayer(
                    notifier: displayNotifier,
                    alignment: alignment,
                    style: style,
                    isDragging: isDragging,
                    isGestureOnly: isGestureOnly,
                  ),
          );

          if (enablePanUpdate) {
            final overlayConstraints = BoxConstraints.tightFor(
              width: constraints.maxWidth,
              height: constraints.maxHeight,
            );
            overlay = GestureDetector(
              behavior: HitTestBehavior.translucent,
              onPanUpdate: (details) =>
                  _updateSubtitlePosition(details, overlayConstraints),
              child: overlay,
            );
          }

          return ClipRect(child: overlay);
        },
      ),
    );
  }

  Widget _buildPortraitDanmakuOverlay(SettingsService settings) {
    final path = _currentItem.danmakuPath;
    if (_isAudio ||
        !_currentItem.isBilibiliExported ||
        path == null ||
        path.isEmpty ||
        !settings.showBilibiliDanmaku ||
        !File(path).existsSync()) {
      return const SizedBox.shrink();
    }
    final position = Provider.of<MediaPlaybackService>(
      context,
      listen: false,
    ).positionNotifier;
    return Positioned.fill(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final viewportSize = constraints.biggest;
          final aspectRatio = _nativeVideoAspectRatio();
          final videoSize = applyBoxFit(
            BoxFit.contain,
            Size(aspectRatio, 1),
            viewportSize,
          ).destination;
          final overlay = DanmakuOverlay(
            key: ValueKey('$path:$_danmakuRevision'),
            path: path,
            position: position,
            displayArea: settings.bilibiliDanmakuDisplayArea,
            opacity: settings.bilibiliDanmakuOpacity,
            fontScale: settings.bilibiliDanmakuFontScale,
            speed: settings.bilibiliDanmakuSpeed,
            fontFamily: settings.bilibiliDanmakuFontFamily,
            fontWeight: settings.bilibiliDanmakuFontWeight,
            outlineType: settings.bilibiliDanmakuOutlineType,
            playerHeight: viewportSize.height,
          );
          return ClipRect(
            child: settings.bilibiliDanmakuOnlyInVideoArea
                ? Center(
                    child: SizedBox(
                      width: videoSize.width,
                      height: videoSize.height,
                      child: overlay,
                    ),
                  )
                : overlay,
          );
        },
      ),
    );
  }

  Future<void> _pickSubtitle() async {
    try {
      final settings = Provider.of<SettingsService>(context, listen: false);
      final library = Provider.of<LibraryService>(context, listen: false);

      final pickedSubtitle = await pickSubtitleFile(
        allowedExtensions: ['srt', 'lrc', 'vtt'],
      );

      if (!mounted) return;

      if (pickedSubtitle != null) {
        final path = pickedSubtitle.path;
        final shouldCacheSubtitle =
            settings.autoCacheSubtitles || pickedSubtitle.requiresPersistence;

        // Auto Cache Logic
        final String? currentSecondary = _currentSubtitlePaths.length > 1
            ? _currentSubtitlePaths[1]
            : _currentItem.secondarySubtitlePath;
        await library.updateVideoSubtitles(
          _currentItem.id,
          path,
          shouldCacheSubtitle,
          secondarySubtitlePath: currentSecondary,
          isSecondaryCached: settings.autoCacheSubtitles,
        );

        final storedItem = library.getVideo(_currentItem.id);
        final pathsToLoad = <String>[storedItem?.subtitlePath ?? path];
        final storedSecondary = storedItem?.secondarySubtitlePath;
        if (storedSecondary != null && storedSecondary.isNotEmpty) {
          pathsToLoad.add(storedSecondary);
        }
        await _loadSubtitles(pathsToLoad);

        if (mounted) {
          AppToast.show(
            "已加载字幕: ${pickedSubtitle.displayName}",
            type: AppToastType.success,
          );
        }
      }
    } catch (e) {
      developer.log('Error picking subtitle', error: e);
    }
  }

  bool _subtitleStyleFromCompose = false;
  bool _subtitleManagerFromCompose = false;

  void _openSubtitleStyleSettings({bool fromCompose = false}) {
    developer.log('Opening subtitle style settings');
    setState(() {
      _subtitleStyleFromCompose = fromCompose;
      _activePanel = PortraitPanel.subtitleStyle;
    });
    if (_initialized) {
      _enableStylePanelDragMode();
    }
  }

  void _openSubtitleManager({bool fromCompose = false}) {
    setState(() {
      _subtitleManagerFromCompose = fromCompose;
      _activePanel = PortraitPanel.subtitleManager;
    });
  }

  String _subtitlePathKey(String path) {
    final normalized = p.normalize(path);
    if (Platform.isWindows) {
      return normalized.toLowerCase();
    }
    return normalized;
  }

  Future<void> _prepareEmbeddedSubtitlesForCompose() async {
    if (_currentItem.path.isEmpty) return;
    try {
      final embeddedService = Provider.of<EmbeddedSubtitleService>(
        context,
        listen: false,
      );
      final library = Provider.of<LibraryService>(context, listen: false);
      final tracks = await embeddedService.getEmbeddedSubtitles(
        _currentItem.path,
      );
      if (tracks.isEmpty) return;
      final subDir = await const TaskSubtitleStorageService().taskDirectory(
        _currentItem.id,
        create: true,
      );
      for (final track in tracks) {
        final extractedPath = await embeddedService.extractSubtitle(
          _currentItem.path,
          track.index,
          subDir.path,
          codecName: track.codecName,
          videoId: _currentItem.id,
        );
        if (extractedPath == null || extractedPath.isEmpty) {
          continue;
        }
        await library.registerManagedSubtitleAsset(
          _currentItem.id,
          path: extractedPath,
          kind: ManagedSubtitleAssetKind.embedded,
          displayName: track.title,
        );
      }
    } catch (e) {
      debugPrint('Prepare embedded subtitles for compose failed: $e');
    }
  }

  void _openVideoCompose() async {
    await _prepareEmbeddedSubtitlesForCompose();
    if (!mounted) return;
    setState(() => _activePanel = PortraitPanel.videoCompose);
  }

  void _openOcrSubtitle() {
    if (!_supportsOcrSubtitle || _isAudio) return;
    setState(() => _activePanel = PortraitPanel.ocrSubtitle);
  }

  Future<void> _applyCompletedOcrSubtitles(List<String> paths) async {
    final available = <String>[];
    for (final path in paths) {
      if (await File(path).exists()) available.add(path);
    }
    if (available.isEmpty) return;
    final itemId = _currentItem.id;
    final primary = available.first;
    final secondary = available.length > 1
        ? available[1]
        : (_currentSubtitlePaths.length > 1
              ? _currentSubtitlePaths[1]
              : _currentItem.secondarySubtitlePath);
    await _loadSubtitles([primary, ?secondary]);
    if (!mounted || _currentItem.id != itemId) return;
    final settings = Provider.of<SettingsService>(context, listen: false);
    final library = Provider.of<LibraryService>(context, listen: false);
    await library.updateVideoSubtitles(
      itemId,
      primary,
      settings.autoCacheSubtitles,
      secondarySubtitlePath: secondary,
      isSecondaryCached: settings.autoCacheSubtitles,
    );
    if (mounted) {
      AppToast.show(
        '已生成 ${available.length} 条 OCR 字幕轨，并自动加载前两条',
        type: AppToastType.success,
      );
    }
  }

  void _applyVideoComposePreview(VideoComposePreviewConfig config) {
    if (!mounted) return;
    if (!_videoComposePreviewActive) {
      setState(() => _videoComposePreviewActive = true);
    }
    unawaited(
      _videoComposePreviewController.configure(config).then((_) {
        if (_initialized && _isControllerAssigned) {
          _videoComposePreviewController.update(_controller.value.position);
        }
      }),
    );
  }

  void _clearVideoComposePreview() {
    _videoComposePreviewController.clear();
    if (mounted && _videoComposePreviewActive) {
      setState(() => _videoComposePreviewActive = false);
    } else {
      _videoComposePreviewActive = false;
    }
  }

  void _closeSubtitleStyleSettings() {
    _disableStylePanelDragMode();
    setState(() {
      _activePanel = _subtitleStyleFromCompose
          ? PortraitPanel.videoCompose
          : PortraitPanel.subtitles;
      _subtitleStyleFromCompose = false;
    });
  }

  void _closeSubtitleManager() {
    setState(() {
      _activePanel = _subtitleManagerFromCompose
          ? PortraitPanel.videoCompose
          : PortraitPanel.subtitles;
      _subtitleManagerFromCompose = false;
    });
  }

  Map<String, String> _buildSubtitleEditorGroups() {
    final Map<String, String> groups = <String, String>{};
    groups.addAll(_currentItem.downloadAssociatedSubtitles);
    groups.addAll(_currentItem.localSubtitleGroups);
    if (_currentItem.subtitlePath != null &&
        _currentItem.subtitlePath!.isNotEmpty) {
      groups.putIfAbsent('主字幕', () => _currentItem.subtitlePath!);
    }
    if (_currentSubtitlePaths.isNotEmpty &&
        _currentSubtitlePaths.first.isNotEmpty) {
      groups.putIfAbsent('当前主字幕', () => _currentSubtitlePaths.first);
    }
    if (_currentItem.secondarySubtitlePath != null &&
        _currentItem.secondarySubtitlePath!.isNotEmpty) {
      groups.putIfAbsent('副字幕', () => _currentItem.secondarySubtitlePath!);
    }
    return groups;
  }

  String? _resolveActiveSubtitleEditorPath() {
    if (_currentSubtitlePaths.isNotEmpty &&
        _currentSubtitlePaths.first.isNotEmpty) {
      return _currentSubtitlePaths.first;
    }
    if (_currentItem.subtitlePath != null &&
        _currentItem.subtitlePath!.isNotEmpty) {
      return _currentItem.subtitlePath;
    }
    return null;
  }

  String _normalizeGroupName(String name) {
    final String normalized = name.trim();
    return normalized.isEmpty ? '手动字幕' : normalized;
  }

  Future<String> _createManualSubtitleGroup(String desiredName) async {
    final String groupName = _normalizeGroupName(desiredName);
    final library = Provider.of<LibraryService>(context, listen: false);
    final String filePath = await const TaskSubtitleStorageService()
        .allocatePath(
          _currentItem.id,
          'manual.${DateTime.now().millisecondsSinceEpoch}.srt',
        );
    await _writeSubtitlesToSrt(filePath, _subtitles);
    await library.registerManagedSubtitleAsset(
      _currentItem.id,
      path: filePath,
      kind: ManagedSubtitleAssetKind.manual,
      displayName: groupName,
    );

    final Map<String, String> local = Map<String, String>.from(
      _currentItem.localSubtitles ?? <String, String>{},
    );
    String unique = groupName;
    int serial = 2;
    while (local.containsKey(unique)) {
      unique = '$groupName $serial';
      serial++;
    }
    local[unique] = filePath;
    _currentItem.localSubtitles = local;
    await library.updateVideoLocalSubtitles(_currentItem.id, local);
    await _applyPrimarySubtitlePath(filePath);
    return filePath;
  }

  Future<void> _renameSubtitleGroup(String oldName, String newName) async {
    final String normalized = _normalizeGroupName(newName);
    final library = Provider.of<LibraryService>(context, listen: false);
    final associated = Map<String, String>.from(
      _currentItem.additionalSubtitles ?? const <String, String>{},
    );
    final downloadAssociated = _currentItem.downloadAssociatedSubtitles;
    final local = Map<String, String>.from(
      _currentItem.localSubtitles ?? <String, String>{},
    );
    if (downloadAssociated.containsKey(oldName)) {
      final path = associated.remove(oldName)!;
      if (associated.containsKey(normalized) || local.containsKey(normalized)) {
        return;
      }
      associated[normalized] = path;
      _currentItem.additionalSubtitles = associated;
      await library.updateVideoAdditionalSubtitles(_currentItem.id, associated);
    } else if (!local.containsKey(oldName)) {
      final String? currentPath = _resolveActiveSubtitleEditorPath();
      if (currentPath == null || currentPath.isEmpty) return;
      if (associated.containsKey(normalized) || local.containsKey(normalized)) {
        return;
      }
      local[normalized] = currentPath;
    } else {
      final String path = local.remove(oldName)!;
      if (associated.containsKey(normalized) || local.containsKey(normalized)) {
        return;
      }
      local[normalized] = path;
    }
    _currentItem.localSubtitles = local;
    await library.updateVideoLocalSubtitles(_currentItem.id, local);
    if (mounted) setState(() {});
  }

  Future<void> _writeSubtitlesToSrt(
    String path,
    List<SubtitleItem> subtitles,
  ) async {
    final StringBuffer buffer = StringBuffer();
    for (int i = 0; i < subtitles.length; i++) {
      final SubtitleItem item = subtitles[i];
      final int index = i + 1;
      buffer.writeln(index.toString());
      buffer.writeln(
        '${_formatSrtTime(item.startTime)} --> ${_formatSrtTime(item.endTime)}',
      );
      buffer.writeln(item.text);
      buffer.writeln();
    }
    await File(path).writeAsString(buffer.toString(), flush: true);
  }

  String _formatSrtTime(Duration duration) {
    String two(int value) => value.toString().padLeft(2, '0');
    final int hours = duration.inHours;
    final int minutes = duration.inMinutes.remainder(60);
    final int seconds = duration.inSeconds.remainder(60);
    final int milliseconds = duration.inMilliseconds.remainder(1000);
    return '${two(hours)}:${two(minutes)}:${two(seconds)},${milliseconds.toString().padLeft(3, '0')}';
  }

  Future<void> _applyPrimarySubtitlePath(String path) async {
    if (path.isEmpty) return;
    final settings = Provider.of<SettingsService>(context, listen: false);
    final library = Provider.of<LibraryService>(context, listen: false);
    String? secondaryPath;
    if (_currentSubtitlePaths.length > 1) {
      secondaryPath = _currentSubtitlePaths[1];
    } else {
      secondaryPath = _currentItem.secondarySubtitlePath;
    }
    final List<String> paths = <String>[path];
    if (secondaryPath != null &&
        secondaryPath.isNotEmpty &&
        secondaryPath != path) {
      paths.add(secondaryPath);
    }
    await _loadSubtitles(paths);
    await library.updateVideoSubtitles(
      _currentItem.id,
      path,
      settings.autoCacheSubtitles,
      secondarySubtitlePath: secondaryPath,
      isSecondaryCached: settings.autoCacheSubtitles,
    );
  }

  Future<void> _onSubtitleEditorSubtitlesChanged(
    List<SubtitleItem> subtitles,
  ) async {
    if (!mounted) return;
    setState(() {
      _subtitles = List<SubtitleItem>.from(subtitles);
    });
    _rebuildSubtitleIndex();
    final playbackService = Provider.of<MediaPlaybackService>(
      context,
      listen: false,
    );
    playbackService.setSubtitleState(
      paths: _currentSubtitlePaths,
      primary: _subtitles,
      secondary: _secondarySubtitles,
    );
    _updateSubtitle();
    final String? primaryPath = _resolveActiveSubtitleEditorPath();
    if (primaryPath == null || primaryPath.isEmpty) return;
    final library = Provider.of<LibraryService>(context, listen: false);
    final videoId = _currentItem.id;
    final writablePath = await _ensureWritableSubtitleEditorPath(
      primaryPath,
      subtitles,
    );
    if (writablePath == null) return;
    _manualSubtitleWriteTimer?.cancel();
    _manualSubtitleWriteTimer = Timer(const Duration(milliseconds: 150), () {
      unawaited(
        _writeSubtitlesToSrt(writablePath, subtitles).then((_) {
          library.notifySubtitleFilesChanged(videoId: videoId);
        }),
      );
    });
  }

  Future<String?> _ensureWritableSubtitleEditorPath(
    String sourcePath,
    List<SubtitleItem> subtitles,
  ) async {
    final storage = const TaskSubtitleStorageService();
    final library = Provider.of<LibraryService>(context, listen: false);
    final isOwned = await storage.isTaskOwnedPath(sourcePath, _currentItem.id);
    if (isOwned && p.extension(sourcePath).toLowerCase() == '.srt') {
      return sourcePath;
    }

    final sourceAssetId = library
        .managedSubtitleAssetForPath(_currentItem.id, sourcePath)
        ?.assetId;
    final outputPath = await storage.allocatePath(
      _currentItem.id,
      'edited.${DateTime.now().millisecondsSinceEpoch}.srt',
    );
    await _writeSubtitlesToSrt(outputPath, subtitles);
    final baseLabel = '${p.basenameWithoutExtension(sourcePath)}（编辑副本）';
    await library.registerManagedSubtitleAsset(
      _currentItem.id,
      path: outputPath,
      kind: ManagedSubtitleAssetKind.manual,
      displayName: baseLabel,
      sourceAssetId: sourceAssetId,
    );
    final local = Map<String, String>.from(
      _currentItem.localSubtitles ?? const <String, String>{},
    );
    var label = baseLabel;
    var serial = 2;
    while (local.containsKey(label)) {
      label = '$baseLabel $serial';
      serial++;
    }
    local[label] = outputPath;
    _currentItem.localSubtitles = local;
    await library.updateVideoLocalSubtitles(_currentItem.id, local);
    await _applyPrimarySubtitlePath(outputPath);
    return outputPath;
  }

  Future<void> _loadSubtitles(
    List<String> paths, {
    bool autoEnableSubtitles = true,
  }) async {
    final playbackService = Provider.of<MediaPlaybackService>(
      context,
      listen: false,
    );
    final bool committed = await playbackService
        .loadSubtitlePathsForCurrentItem(itemId: _currentItem.id, paths: paths);
    if (!committed || !mounted) return;

    final primary = List<SubtitleItem>.from(playbackService.subtitles);
    final secondary = List<SubtitleItem>.from(
      playbackService.secondarySubtitles,
    );

    setState(() {
      _subtitleRevision = playbackService.subtitleRevision;
      _subtitles = primary;
      _secondarySubtitles = secondary;
      _currentSubtitlePaths = List<String>.from(playbackService.subtitlePaths);
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

    if (autoEnableSubtitles && (primary.isNotEmpty || secondary.isNotEmpty)) {
      // Keep the per-item snapshot aligned with the persisted global toggle
      // without overriding the user's current floating subtitle preference.
      _applyItemSubtitlePreference(_currentItem, force: true);
    }
    _updateSubtitle();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _updateSubtitle();
    });
  }

  void _rebuildSubtitleIndex() {
    _subtitleTimeline = SubtitleTimelineResolver(_subtitles);
    _secondarySubtitleTimeline = SubtitleTimelineResolver(_secondarySubtitles);
  }

  bool _areIntListsEqual(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  bool _areSubtitleEntryListsEqual(
    List<SubtitleOverlayEntry> a,
    List<SubtitleOverlayEntry> b,
  ) {
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
    final keysToRemove = _currentSubtitleImages.keys
        .where((k) => !keepIndices.contains(k))
        .toList();
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
    if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      if (_isLongPressing) _endLongPressSpeed();
      _saveProgress();
    } else if (state == AppLifecycleState.resumed) {
      _scheduleVideoFocusRestore();
    }
  }

  @override
  void didChangeMetrics() {
    super.didChangeMetrics();
    if (_pendingSubtitleSidebarViewportRestore) {
      _tryRestoreSubtitleSidebarForCurrentViewport();
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
      final playbackService = Provider.of<MediaPlaybackService>(
        context,
        listen: false,
      );
      final suppressRouteCleanup =
          PlaybackNavigationService.instance.suppressAutoPauseOnRouteCleanup;
      if (!suppressRouteCleanup &&
          settings.autoPauseOnExit &&
          _controller.value.isPlaying) {
        if (playbackService.controller == _controller) {
          await playbackService.pause();
        } else {
          await _controller.pause();
        }
      }

      // Force sync state
      if (!_isControllerOwner && playbackService.controller != _controller) {
        playbackService.updatePlaybackStateFromController();
      }
      await _saveProgress();
    } catch (e) {
      debugPrint("Exit sync error: $e");
    }
  }

  Future<void> _handleBackRequest() async {
    final navigator = Navigator.of(context);
    if (_forceExit) {
      if (!_exitGuard.tryStart()) return;
      await _handleExit();
      if (!mounted) return;
      _updateOrientations();
      navigator.pop();
      return;
    }

    if (_isSubtitleDragMode && !_isStylePanelDragMode) {
      _exitSubtitleDragMode();
      return;
    }

    if (_activePanel == PortraitPanel.subtitleEditor &&
        _isSubtitleEditorExpanded) {
      if (!mounted) return;
      setState(() {
        _isSubtitleEditorExpanded = false;
      });
      return;
    }

    if (_activePanel != PortraitPanel.subtitles) {
      if (!mounted) return;
      if (_activePanel == PortraitPanel.videoCompose) {
        _clearVideoComposePreview();
      }
      setState(() {
        if (_activePanel == PortraitPanel.subtitleStyle) {
          _isStylePanelDragMode = false;
          _isSubtitleDragMode = false;
          _isSubtitleSnappedX = false;
          _isSubtitleSnappedY = false;
          _isSubtitleNearCenterX = false;
          _isSubtitleNearCenterY = false;
        }
        if (_activePanel == PortraitPanel.subtitleStyle &&
            _subtitleStyleFromCompose) {
          _activePanel = PortraitPanel.videoCompose;
        } else if (_activePanel == PortraitPanel.subtitleManager &&
            _subtitleManagerFromCompose) {
          _activePanel = PortraitPanel.videoCompose;
        } else {
          _activePanel = PortraitPanel.subtitles;
        }
        _subtitleStyleFromCompose = false;
        _subtitleManagerFromCompose = false;
        _isSubtitleEditorExpanded = false;
      });
      return;
    }

    if (!_exitGuard.tryStart()) return;
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
    if (_isLongPressing) {
      _isLongPressing = false;
      final playbackService = _longPressPlaybackService;
      _longPressPlaybackService = null;
      if (playbackService != null) {
        unawaited(playbackService.endTemporaryPlaybackSpeed());
      }
    }
    FocusManager.instance.removeEarlyKeyEventHandler(
      _handlePlaybackEarlyKeyEvent,
    );
    // Try to sync one last time (fire and forget)
    _handleExit();
    MediaPlaybackService().setPlaybackPageVisible(this, false);

    if (_routeObserverSubscribed) {
      AppToast.routeObserver.unsubscribe(this);
    }

    try {
      Provider.of<MediaPlaybackService>(
        context,
        listen: false,
      ).removeListener(_onPlaybackServiceChange);
    } catch (_) {}
    _settingsService?.removeListener(_onSettingsChanged);

    _transcriptionManager?.removeListener(_onTranscriptionUpdate);
    _ocrSubtitleManager?.removeListener(_onOcrSubtitleUpdate);
    _selectionFocusNode.dispose();
    _videoComposePreviewController.dispose();
    _videoFocusNode.dispose();
    _playbackPageFocusNode.dispose();
    _subtitleSeekTimer?.cancel();
    _customAspectDraftSaveTimer?.cancel();
    _manualSubtitleWriteTimer?.cancel();

    WidgetsBinding.instance.removeObserver(this);
    if (_isControllerAssigned) {
      _controller.removeListener(_videoListener);
      // 只有当我们拥有 controller 时才 dispose
      if (_isControllerOwner) {
        try {
          final playbackService = Provider.of<MediaPlaybackService>(
            context,
            listen: false,
          );
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

  KeyEventResult _handlePlaybackEarlyKeyEvent(KeyEvent event) {
    if (!mounted || ModalRoute.of(context)?.isCurrent != true) {
      return KeyEventResult.ignored;
    }
    final BuildContext? focusContext =
        FocusManager.instance.primaryFocus?.context;
    final bool isEditingText =
        focusContext?.widget is EditableText ||
        focusContext?.findAncestorWidgetOfExactType<EditableText>() != null;
    if (isEditingText) return KeyEventResult.ignored;
    return _controlsKey.currentState?.handleKeyEvent(
          _playbackPageFocusNode,
          event,
        ) ??
        KeyEventResult.ignored;
  }

  Future<void> _saveProgress() async {
    final playbackService = Provider.of<MediaPlaybackService>(
      context,
      listen: false,
    );
    if (playbackService.currentItem?.id == _currentItem.id) {
      await playbackService.persistCurrentProgress(
        expectedItemId: _currentItem.id,
      );
      return;
    }
    if (_isControllerAssigned && _controller.value.isInitialized) {
      await Provider.of<LibraryService>(
        context,
        listen: false,
      ).updateVideoProgress(
        _currentItem.id,
        _controller.value.position.inMilliseconds,
      );
    }
  }

  void _goToLandscape() async {
    if (_isPushingLandscape) {
      return;
    }
    _isPushingLandscape = true;

    // A controller and its subtitles must cross the layout boundary as one
    // coherent snapshot. On a cold start the service's initial subtitle parse
    // can still be in flight here, which previously let landscape observe the
    // primary track before the secondary track had been committed.
    final playbackService = Provider.of<MediaPlaybackService>(
      context,
      listen: false,
    );
    VideoItem handoffItem = _currentItem;
    try {
      final latest = Provider.of<LibraryService>(
        context,
        listen: false,
      ).getVideo(_currentItem.id);
      if (latest != null) handoffItem = latest;
    } catch (_) {}
    final servicePaths = playbackService.subtitlePaths;
    final List<String> handoffPaths = <String>[];
    final primaryPath = servicePaths.isNotEmpty
        ? servicePaths.first
        : handoffItem.subtitlePath;
    if (primaryPath != null && primaryPath.isNotEmpty) {
      handoffPaths.add(primaryPath);
    }
    final secondaryPath = servicePaths.length > 1
        ? servicePaths[1]
        : handoffItem.secondarySubtitlePath;
    if (secondaryPath != null &&
        secondaryPath.isNotEmpty &&
        secondaryPath != primaryPath) {
      handoffPaths.add(secondaryPath);
    }
    try {
      await playbackService.ensureSubtitlePathsForCurrentItem(
        itemId: handoffItem.id,
        paths: handoffPaths,
      );
    } catch (e) {
      debugPrint('Subtitle hand-off refresh failed: $e');
    }
    if (!mounted) {
      _isPushingLandscape = false;
      return;
    }
    _currentItem = playbackService.currentItem ?? handoffItem;
    _syncSubtitlesFromService(playbackService);

    // Push landscape page with current controller
    unawaited(_saveProgress()); // Save before switch just in case
    final navigator = Navigator.of(context);

    final bool useOrientationBridge = _usesAndroidPhoneOrientationBridge;
    if (useOrientationBridge) {
      await _showOrientationBridge();
      if (!mounted) {
        _isPushingLandscape = false;
        return;
      }
      try {
        await Future.wait<void>(<Future<void>>[
          SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky),
          SystemChrome.setPreferredOrientations(<DeviceOrientation>[
            DeviceOrientation.landscapeLeft,
            DeviceOrientation.landscapeRight,
          ]),
        ]);
      } catch (error) {
        debugPrint(
          'Playback orientation transition: landscape request failed: $error',
        );
        await _hideOrientationBridge();
        _isPushingLandscape = false;
        return;
      }
      final reachedLandscape = await _waitForPlaybackViewport(
        PlaybackViewportOrientation.landscape,
      );
      if (!mounted) {
        _isPushingLandscape = false;
        return;
      }
      if (!reachedLandscape &&
          !PlaybackOrientationTransition.matches(
            View.of(context).physicalSize,
            PlaybackViewportOrientation.landscape,
          )) {
        debugPrint(
          'Playback orientation transition: landscape viewport timed out.',
        );
        await SystemChrome.setPreferredOrientations(<DeviceOrientation>[
          DeviceOrientation.portraitUp,
          DeviceOrientation.portraitDown,
        ]);
        await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
        await _hideOrientationBridge();
        _isPushingLandscape = false;
        return;
      }
    } else if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
      await SystemChrome.setPreferredOrientations(<DeviceOrientation>[
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    }

    // Missing-source placeholders stay local. A real controller is handed to
    // landscape and keeps the existing ownership semantics.
    final VideoPlayerController? controllerForHandoff = _isSourceMissing
        ? null
        : _controller;
    if (controllerForHandoff != null) {
      _isControllerOwner = false;
    }

    try {
      await navigator.push(
        PageRouteBuilder(
          settings: PlaybackNavigationService.landscapeRouteSettings(
            _currentItem,
          ),
          pageBuilder: (context, animation, secondaryAnimation) =>
              VideoPlayerScreen(
                videoFile: null, // Legacy param, ignored
                existingController: controllerForHandoff,
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
    } catch (error, stackTrace) {
      if (controllerForHandoff != null) {
        _isControllerOwner = true;
      }
      debugPrint('Opening landscape playback failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      if (useOrientationBridge && mounted) {
        await SystemChrome.setPreferredOrientations(<DeviceOrientation>[
          DeviceOrientation.portraitUp,
          DeviceOrientation.portraitDown,
        ]);
        await _hideOrientationBridge();
      }
      return;
    } finally {
      _isPushingLandscape = false;
    }

    if (!mounted) return;

    // 从横屏返回后，需要重新同步控制器状态
    // 因为横屏页可能已经切换了视频，导致控制器被替换
    if (_isControllerAssigned) {
      try {
        _controller.removeListener(_videoListener);
      } catch (_) {}
      if (_isControllerOwner) {
        unawaited(_controller.dispose());
      }
    }
    _isControllerAssigned = false;
    _initialized = false;
    _isSourceMissing = false;

    // Restore orientation logic based on device type
    _updateOrientations();

    // 重新初始化播放器以同步 Service 的状态
    final bool needsReinit =
        playbackService.currentItem?.id != _currentItem.id ||
        playbackService.controller == null;
    if (needsReinit) {
      _postInitWorkToken++;
      _initPlayer();
    } else {
      _currentItem = playbackService.currentItem!;
      _controller = playbackService.controller!;
      _isControllerAssigned = true;
      _isControllerOwner = false;
      _isAudio = _currentItem.type == MediaType.audio;
      _initialized = _controller.value.isInitialized;
      _bindControllerListener();
      _scheduleDeferredPostInitWork(_currentItem);
      if (mounted) {
        setState(() {});
      }
    }

    // 同步字幕状态
    try {
      final library = Provider.of<LibraryService>(context, listen: false);
      final updated = library.getVideo(_currentItem.id);
      if (updated != null) {
        _currentItem = updated;
      }
    } catch (_) {}

    final bool hasServiceSubtitleState =
        playbackService.subtitles.isNotEmpty ||
        playbackService.secondarySubtitles.isNotEmpty;
    if (hasServiceSubtitleState) {
      setState(() {
        _subtitles = List<SubtitleItem>.from(playbackService.subtitles);
        _secondarySubtitles = List<SubtitleItem>.from(
          playbackService.secondarySubtitles,
        );
        _currentSubtitlePaths = List<String>.from(
          playbackService.subtitlePaths,
        );
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
    } else if (playbackService.subtitlePaths.isNotEmpty) {
      await _loadSubtitles(playbackService.subtitlePaths);
    } else if (_currentItem.subtitlePath != null) {
      final List<String> paths = [_currentItem.subtitlePath!];
      if (_currentItem.secondarySubtitlePath != null) {
        paths.add(_currentItem.secondarySubtitlePath!);
      }
      await _loadSubtitles(paths);
    } else if (!_currentItem.blockAutoAssociatedSubtitleSelection &&
        _resolveFirstAssociatedSubtitlePath(_currentItem) != null) {
      await _tryLoadAssociatedSubtitleAsPrimary(_currentItem);
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

    // The route may become current before the phone has finished rotating.
    // Restore once the final portrait metrics are laid out; unlike playback
    // auto-follow, this repair is also required while paused.
    _requestSubtitleSidebarViewportRestore();

    if (useOrientationBridge) {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      await _waitForPlaybackViewport(PlaybackViewportOrientation.portrait);
      await _hideOrientationBridge();
    }
  }

  Widget _buildOrientationBridge() {
    Widget content;
    if (_isSourceMissing) {
      content = const Center(
        child: Text(
          '没有源媒体',
          style: TextStyle(color: Colors.white70, fontSize: 18),
        ),
      );
    } else if (_initialized && _isAudio) {
      content = const Center(
        child: Icon(Icons.music_note, size: 80, color: Colors.white24),
      );
    } else if (_initialized && _isControllerAssigned) {
      content = Center(
        child: AspectRatio(
          aspectRatio: _nativeVideoAspectRatio(),
          child: Transform(
            alignment: Alignment.center,
            transform: _buildVideoDisplayTransformMatrix(),
            child: VideoPlayer(_controller, key: _videoTextureKey),
          ),
        ),
      );
    } else if (!_isAudio &&
        _currentItem.thumbnailPath != null &&
        File(_currentItem.thumbnailPath!).existsSync()) {
      content = Image.file(
        File(_currentItem.thumbnailPath!),
        fit: BoxFit.cover,
      );
    } else {
      content = const SizedBox.expand();
    }

    return ColoredBox(
      color: Colors.black,
      child: IgnorePointer(child: content),
    );
  }

  double _nativeVideoAspectRatio() {
    try {
      final playbackService = Provider.of<MediaPlaybackService>(
        context,
        listen: false,
      );
      final streamRatio = playbackService.streamDisplayAspectRatio;
      if (playbackService.currentItem?.id == _currentItem.id &&
          playbackService.isCurrentItemBilibiliStream &&
          streamRatio != null &&
          streamRatio.isFinite &&
          streamRatio > 0) {
        return streamRatio;
      }
    } catch (_) {}
    if (_isControllerAssigned &&
        _controller.value.isInitialized &&
        _controller.value.aspectRatio > 0) {
      return _controller.value.aspectRatio;
    }
    return 16 / 9;
  }

  double _portraitDisplayAspectRatio() {
    if (_isAudio) {
      final settings =
          _settingsService ??
          Provider.of<SettingsService>(context, listen: false);
      final globalRatio = settings.audioPortraitDisplayAspectRatio;
      if (globalRatio != null && globalRatio.isFinite && globalRatio > 0) {
        return globalRatio;
      }
      return 1.0;
    }
    final manual = _currentItem.portraitDisplayAspectRatio;
    if (manual != null && manual.isFinite && manual > 0) {
      return manual;
    }
    return _nativeVideoAspectRatio();
  }

  String _portraitAspectRatioLabel(double? ratio) {
    if (ratio == null) return '原始';
    if ((ratio - 1.0).abs() < 0.01) return '1:1';
    if ((ratio - (16 / 9)).abs() < 0.01) return '16:9';
    if ((ratio - (4 / 3)).abs() < 0.01) return '4:3';
    if ((ratio - (3 / 2)).abs() < 0.01) return '3:2';
    return '${ratio.toStringAsFixed(2)}:1';
  }

  bool _isPresetAspectRatio(double ratio, {bool includeSquare = false}) {
    return (includeSquare && (ratio - 1.0).abs() < 0.01) ||
        (ratio - (16 / 9)).abs() < 0.01 ||
        (ratio - (4 / 3)).abs() < 0.01 ||
        (ratio - (3 / 2)).abs() < 0.01;
  }

  Future<void> _applyInitialPortraitDefaultAspectRatioIfNeeded() async {
    if (_isAudio ||
        !_isControllerAssigned ||
        !_controller.value.isInitialized ||
        _currentItem.hasPortraitAspectPreferenceInitialized) {
      return;
    }

    const double portraitThreshold = 1.0 - 0.0001;
    final double nativeRatio = _nativeVideoAspectRatio();
    if (nativeRatio <= 0) return;

    final double? manual = _currentItem.portraitDisplayAspectRatio;
    if (manual != null && manual.isFinite && manual > 0) {
      setState(() {
        _currentItem.hasPortraitAspectPreferenceInitialized = true;
      });
      try {
        final library = Provider.of<LibraryService>(context, listen: false);
        await library.updateVideoPortraitDisplayAspectRatio(
          _currentItem.id,
          manual,
          customWidth: _currentItem.portraitCustomAspectWidth,
          customHeight: _currentItem.portraitCustomAspectHeight,
          markInitialized: true,
        );
      } catch (_) {}
      return;
    }

    if (nativeRatio < portraitThreshold) {
      await _persistPortraitAspectRatio(4 / 3);
    }
  }

  Future<void> _persistPortraitAspectRatio(
    double? ratio, {
    double? customWidth,
    double? customHeight,
  }) async {
    final normalized =
        (ratio != null && ratio.isFinite && ratio > 0 && ratio <= 10)
        ? ratio
        : null;
    final normalizedWidth =
        (customWidth != null && customWidth.isFinite && customWidth > 0)
        ? customWidth
        : null;
    final normalizedHeight =
        (customHeight != null && customHeight.isFinite && customHeight > 0)
        ? customHeight
        : null;

    // 音频：保存到全局设置（所有音频共享同一比例）
    if (_isAudio) {
      final settings =
          _settingsService ??
          Provider.of<SettingsService>(context, listen: false);
      await settings.saveAudioPortraitDisplayAspectRatio(
        normalized,
        customWidth: normalizedWidth,
        customHeight: normalizedHeight,
      );
      if (!mounted) return;
      setState(() {});
      return;
    }

    // 视频：保存到当前视频项
    setState(() {
      _currentItem.portraitDisplayAspectRatio = normalized;
      _currentItem.portraitCustomAspectWidth = normalizedWidth;
      _currentItem.portraitCustomAspectHeight = normalizedHeight;
      _currentItem.hasPortraitAspectPreferenceInitialized = true;
    });

    try {
      final library = Provider.of<LibraryService>(context, listen: false);
      await library.updateVideoPortraitDisplayAspectRatio(
        _currentItem.id,
        normalized,
        customWidth: normalizedWidth,
        customHeight: normalizedHeight,
      );
      if (!mounted) return;
      final updated = library.getVideo(_currentItem.id);
      if (updated != null) {
        setState(() {
          _currentItem = updated;
        });
      }
    } catch (_) {}
  }

  /// 实验性功能：五连击标题进入 Apple Music 风格播放页面
  void _navigateToMusicPlayer() {
    final service = Provider.of<MediaPlaybackService>(context, listen: false);
    final settings = Provider.of<SettingsService>(context, listen: false);
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => MusicPlayerScreen(
          coverImagePath: _currentItem.thumbnailPath,
          title: _currentItem.title,
          onSeek: (pos) => service.seekTo(pos),
          onPlayPause: () {
            if (service.isPlaying) {
              service.pause();
            } else {
              service.resume();
            }
          },
          onPrevious: () =>
              service.playPrevious(autoPlay: settings.autoPlayNextVideo),
          onNext: () => service.playNext(autoPlay: settings.autoPlayNextVideo),
        ),
        fullscreenDialog: true,
      ),
    );
  }

  Future<void> _showPortraitAspectRatioSheet() async {
    final settings = Provider.of<SettingsService>(context, listen: false);
    final String initWidthText = settings.portraitCustomAspectDraftWidthText;
    final String initHeightText = settings.portraitCustomAspectDraftHeightText;

    final TextEditingController widthController = TextEditingController(
      text: initWidthText,
    );
    final TextEditingController heightController = TextEditingController(
      text: initHeightText,
    );

    String lastSavedWidthText = initWidthText;
    String lastSavedHeightText = initHeightText;
    Timer? customAspectLiveApplyTimer;
    double? lastLiveAppliedRatio;

    Future<void> persistCustomAspectDraft({bool immediate = false}) async {
      final widthText = widthController.text;
      final heightText = heightController.text;
      if (widthText == lastSavedWidthText &&
          heightText == lastSavedHeightText) {
        return;
      }

      Future<void> doSave() async {
        await settings.savePortraitCustomAspectDraftTexts(
          widthText: widthText,
          heightText: heightText,
        );
        lastSavedWidthText = widthText;
        lastSavedHeightText = heightText;
      }

      _customAspectDraftSaveTimer?.cancel();
      if (immediate) {
        await doSave();
      } else {
        _customAspectDraftSaveTimer = Timer(
          const Duration(milliseconds: 180),
          () {
            doSave();
          },
        );
      }
    }

    final Color panelColor = const Color(0xFF1E1E1E);

    final Color chipColor = const Color(0xFF2B2B2B);

    try {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        backgroundColor: panelColor,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
        ),
        builder: (sheetContext) {
          double? selected = _isAudio
              ? (settings.audioPortraitDisplayAspectRatio ?? 1.0)
              : _currentItem.portraitDisplayAspectRatio;
          String? errorText;

          Future<void> apply(
            double? ratio, {
            double? customWidth,
            double? customHeight,
          }) async {
            await _persistPortraitAspectRatio(
              ratio,
              customWidth: customWidth,
              customHeight: customHeight,
            );
          }

          return StatefulBuilder(
            builder: (context, setSheetState) {
              bool shouldLiveSyncCustomInput() {
                final applied = _isAudio
                    ? settings.audioPortraitDisplayAspectRatio
                    : _currentItem.portraitDisplayAspectRatio;
                return applied != null &&
                    applied.isFinite &&
                    applied > 0 &&
                    !_isPresetAspectRatio(applied, includeSquare: _isAudio);
              }

              void scheduleLiveCustomApply() {
                if (!shouldLiveSyncCustomInput()) return;
                final double? width = double.tryParse(
                  widthController.text.trim(),
                );
                final double? height = double.tryParse(
                  heightController.text.trim(),
                );
                if (width == null ||
                    height == null ||
                    !width.isFinite ||
                    !height.isFinite ||
                    width <= 0 ||
                    height <= 0) {
                  return;
                }
                final double ratio = width / height;
                if (!ratio.isFinite || ratio <= 0 || ratio > 10) return;
                if (lastLiveAppliedRatio != null &&
                    (lastLiveAppliedRatio! - ratio).abs() < 0.0001) {
                  return;
                }

                customAspectLiveApplyTimer?.cancel();
                customAspectLiveApplyTimer = Timer(
                  const Duration(milliseconds: 120),
                  () async {
                    await apply(
                      ratio,
                      customWidth: width,
                      customHeight: height,
                    );
                    if (!mounted) return;
                    setSheetState(() {
                      selected = ratio;
                      errorText = null;
                    });
                    lastLiveAppliedRatio = ratio;
                  },
                );
              }

              Widget option(String title, double? ratio) {
                final bool isSelected =
                    (selected == null && ratio == null) ||
                    (selected != null &&
                        ratio != null &&
                        (selected! - ratio).abs() < 0.01);
                return AnimatedContainer(
                  duration: const Duration(milliseconds: 140),
                  curve: Curves.easeOut,
                  margin: const EdgeInsets.only(right: 8, bottom: 8),
                  child: Material(
                    color: isSelected
                        ? const Color(0xFF1565C0).withValues(alpha: 0.28)
                        : chipColor,
                    borderRadius: BorderRadius.circular(12),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: () async {
                        setSheetState(() {
                          selected = ratio;
                          errorText = null;
                        });
                        await apply(
                          ratio,
                          customWidth: null,
                          customHeight: null,
                        );
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              isSelected
                                  ? Icons.radio_button_checked
                                  : Icons.radio_button_unchecked,
                              size: 16,
                              color: isSelected
                                  ? const Color(0xFF64B5F6)
                                  : Colors.white60,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              title,
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              }

              return Padding(
                padding: EdgeInsets.fromLTRB(
                  16,
                  14,
                  16,
                  16 + MediaQuery.of(context).viewInsets.bottom,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(
                          Icons.aspect_ratio,
                          color: Colors.white70,
                          size: 20,
                        ),
                        const SizedBox(width: 8),
                        const Text(
                          '竖屏页显示比例',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const Spacer(),
                        Text(
                          '当前：${_portraitAspectRatioLabel(_isAudio ? (settings.audioPortraitDisplayAspectRatio ?? 1.0) : _currentItem.portraitDisplayAspectRatio)}',
                          style: const TextStyle(
                            color: Colors.white60,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      children: [
                        if (_isAudio)
                          option('1:1', 1.0)
                        else
                          option('原始比例', null),
                        option('16:9', 16 / 9),
                        option('4:3', 4 / 3),
                        option('3:2', 3 / 2),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Material(
                      color: chipColor,
                      borderRadius: BorderRadius.circular(12),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            InkWell(
                              borderRadius: BorderRadius.circular(16),
                              onTap: () async {
                                final double? width = double.tryParse(
                                  widthController.text.trim(),
                                );
                                final double? height = double.tryParse(
                                  heightController.text.trim(),
                                );
                                if (width == null ||
                                    height == null ||
                                    !width.isFinite ||
                                    !height.isFinite ||
                                    width <= 0 ||
                                    height <= 0) {
                                  setSheetState(() {
                                    errorText = '请输入有效的宽高数值';
                                  });
                                  return;
                                }

                                final double ratio = width / height;
                                if (!ratio.isFinite ||
                                    ratio <= 0 ||
                                    ratio > 10) {
                                  setSheetState(() {
                                    errorText = '宽高比最大支持 10:1';
                                  });
                                  return;
                                }

                                setSheetState(() {
                                  selected = ratio;
                                  errorText = null;
                                });
                                await apply(
                                  ratio,
                                  customWidth: width,
                                  customHeight: height,
                                );
                                lastLiveAppliedRatio = ratio;
                              },
                              child: Padding(
                                padding: const EdgeInsets.only(right: 10),
                                child: Icon(
                                  selected != null &&
                                          !_isPresetAspectRatio(
                                            selected!,
                                            includeSquare: _isAudio,
                                          )
                                      ? Icons.radio_button_checked
                                      : Icons.radio_button_unchecked,
                                  size: 18,
                                  color:
                                      selected != null &&
                                          !_isPresetAspectRatio(
                                            selected!,
                                            includeSquare: _isAudio,
                                          )
                                      ? const Color(0xFF64B5F6)
                                      : Colors.white60,
                                ),
                              ),
                            ),
                            const Padding(
                              padding: EdgeInsets.only(right: 8),
                              child: Text(
                                '自定义',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            Expanded(
                              child: TextField(
                                controller: widthController,
                                keyboardType:
                                    const TextInputType.numberWithOptions(
                                      decimal: true,
                                    ),
                                onChanged: (_) {
                                  setSheetState(() {
                                    errorText = null;
                                  });
                                  persistCustomAspectDraft();
                                  scheduleLiveCustomApply();
                                },
                                style: const TextStyle(color: Colors.white),
                                decoration: InputDecoration(
                                  filled: true,
                                  fillColor: const Color(0xFF232323),
                                  hintText: '宽',
                                  hintStyle: const TextStyle(
                                    color: Colors.white38,
                                  ),
                                  contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 8,
                                  ),
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(8),
                                    borderSide: BorderSide.none,
                                  ),
                                ),
                              ),
                            ),
                            const Padding(
                              padding: EdgeInsets.symmetric(horizontal: 6),
                              child: Text(
                                ':',
                                style: TextStyle(color: Colors.white70),
                              ),
                            ),
                            Expanded(
                              child: TextField(
                                controller: heightController,
                                keyboardType:
                                    const TextInputType.numberWithOptions(
                                      decimal: true,
                                    ),
                                onChanged: (_) {
                                  setSheetState(() {
                                    errorText = null;
                                  });
                                  persistCustomAspectDraft();
                                  scheduleLiveCustomApply();
                                },
                                style: const TextStyle(color: Colors.white),

                                decoration: InputDecoration(
                                  filled: true,
                                  fillColor: const Color(0xFF232323),
                                  hintText: '高',
                                  hintStyle: const TextStyle(
                                    color: Colors.white38,
                                  ),
                                  contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 8,
                                  ),
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(8),
                                    borderSide: BorderSide.none,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    if (errorText != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        errorText!,
                        style: const TextStyle(color: Colors.redAccent),
                      ),
                    ],
                    const SizedBox(height: 8),
                  ],
                ),
              );
            },
          );
        },
      );
    } finally {
      await persistCustomAspectDraft(immediate: true);
      _customAspectDraftSaveTimer?.cancel();
      customAspectLiveApplyTimer?.cancel();
      widthController.dispose();
      heightController.dispose();
    }
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
    // Progress is already driven by the controller's ValueListenableBuilder
    // below. Listening to the whole service rebuilt the portrait player for
    // every coarse media-position notification.
    final playbackService = Provider.of<MediaPlaybackService>(
      context,
      listen: false,
    );
    if (!_isControllerAssigned) {
      return _buildLoadingBottomControlBar(settings, playbackService);
    }

    return ValueListenableBuilder(
      valueListenable: _controller,
      builder: (context, value, child) {
        // Use metadata if controller not ready
        final duration = value.isInitialized
            ? value.duration
            : Duration(milliseconds: _currentItem.durationMs);
        final position = value.isInitialized
            ? value.position
            : Duration(milliseconds: _currentItem.lastPositionMs);

        // Ensure valid slider values
        final double maxDuration = duration.inMilliseconds.toDouble();
        final double currentPos = position.inMilliseconds.toDouble();
        final double sliderMax = maxDuration > 0 ? maxDuration : 1.0;
        final double sliderValue = currentPos.clamp(0.0, sliderMax);
        var bufferedValue = sliderValue;
        for (final range in value.buffered) {
          final end = range.end.inMilliseconds.toDouble();
          if (end > bufferedValue) bufferedValue = end;
        }
        bufferedValue = bufferedValue.clamp(sliderValue, sliderMax);

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
                      activeTrackColor: _isProgressDragCanceling
                          ? Colors.grey
                          : const Color(0xFF0D47A1),
                      inactiveTrackColor: Colors.white24,
                      secondaryActiveTrackColor: Colors.white54,
                      thumbColor: _isProgressDragCanceling
                          ? Colors.grey
                          : const Color(0xFF1565C0),
                      overlayColor: const Color(0x291565C0),
                      thumbShape: const RoundSliderThumbShape(
                        enabledThumbRadius: 6.0,
                      ),
                      trackHeight: 2.0,
                      overlayShape: const RoundSliderOverlayShape(
                        overlayRadius: 10,
                      ),
                    ),
                    child: Slider(
                      min: 0.0,
                      max: sliderMax,
                      value: _isDraggingProgress
                          ? _dragProgressValue
                          : sliderValue,
                      secondaryTrackValue: _isDraggingProgress
                          ? (_dragProgressValue > bufferedValue
                                ? _dragProgressValue
                                : bufferedValue)
                          : bufferedValue,
                      onChanged: value.isInitialized
                          ? (newValue) {
                              setState(() {
                                _isDraggingProgress = true;
                                _dragProgressValue = newValue;
                              });
                            }
                          : null,
                      onChangeEnd: value.isInitialized
                          ? (newValue) {
                              if (!_isProgressDragCanceling) {
                                final pos = Duration(
                                  milliseconds: newValue.toInt(),
                                );
                                _seekPlaybackPosition(pos);
                              }
                              setState(() {
                                _isDraggingProgress = false;
                                _isProgressDragCanceling = false;
                              });
                            }
                          : null,
                    ),
                  ),
                ),
              ),

              // Tools

              // Speed
              Builder(
                builder: (speedButtonContext) => Tooltip(
                  message: '倍速',
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(8),
                      onTap: value.isInitialized
                          ? () => unawaited(
                              showPlaybackSpeedDialog(
                                context: context,
                                anchorContext: speedButtonContext,
                                initialSpeed: value.playbackSpeed,
                                settings: settings,
                                onSpeedSelected: _handlePlaybackSpeedSelected,
                              ),
                            )
                          : null,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 5,
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              "${value.playbackSpeed}x",
                              maxLines: 1,
                              overflow: TextOverflow.fade,
                              style: TextStyle(
                                color: value.isInitialized
                                    ? Colors.white
                                    : Colors.white38,
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            if (settings.isLockedPlaybackSpeed(
                              value.playbackSpeed,
                            )) ...[
                              const SizedBox(width: 4),
                              const Icon(
                                Icons.lock,
                                size: 12,
                                color: Colors.blueAccent,
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),

              // Subtitle Toggle
              IconButton(
                icon: Icon(
                  settings.showSubtitles
                      ? Icons.subtitles
                      : Icons.subtitles_off,
                  color: settings.showSubtitles
                      ? Colors.blueAccent
                      : Colors.white70,
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
                  playbackService.isMuted ? Icons.volume_off : Icons.volume_up,
                  color: playbackService.isMuted
                      ? Colors.redAccent
                      : Colors.white,
                  size: 18,
                ),
                onPressed: () {
                  unawaited(playbackService.toggleMute());
                },
                tooltip: playbackService.isMuted ? "取消静音" : "静音",
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
    final playbackService = Provider.of<MediaPlaybackService>(
      context,
      listen: false,
    );
    if (!_isControllerAssigned) {
      return _buildLoadingExternalControls(
        settings,
        playlistManager,
        playbackService,
      );
    }

    // Reduced sizes by ~50-60% to meet user request (80% reduction requested but that would be too small, so aiming for "much smaller")
    const double iconSize = 50.0;
    const double seekIconSize = 28.0;

    return ValueListenableBuilder(
      valueListenable: _controller,
      builder: (context, value, child) {
        return Container(
          color: const Color(0xFF1E1E1E), // Match SubtitleSidebar background
          padding: const EdgeInsets.symmetric(
            vertical: 0.1,
          ), // Minimal padding to fit tightly
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Previous Episode
              IconButton(
                icon: Icon(
                  Icons.skip_previous,
                  color: playlistManager.hasPrevious
                      ? Colors.white
                      : Colors.white38,
                ),
                onPressed: playlistManager.hasPrevious
                    ? () => playbackService.playPrevious(
                        autoPlay: settings.autoPlayNextVideo,
                      )
                    : null,
                iconSize: 32,
                tooltip: "上一集",
              ),
              const SizedBox(width: 16),

              // Seek Backward
              InkWell(
                onTap: value.isInitialized && !_isSourceMissing
                    ? () {
                        final newPos =
                            value.position -
                            Duration(seconds: settings.doubleTapSeekSeconds);
                        final pos = newPos < Duration.zero
                            ? Duration.zero
                            : newPos;
                        if (playbackService.controller == _controller) {
                          playbackService.seekTo(pos);
                        } else {
                          _controller.seekTo(pos);
                        }
                      }
                    : null,
                borderRadius: BorderRadius.circular(30),
                child: SizedBox(
                  width: seekIconSize + 16,
                  height: seekIconSize + 16,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      Icon(
                        Icons.replay,
                        color: value.isInitialized && !_isSourceMissing
                            ? Colors.white
                            : Colors.white38,
                        size: seekIconSize,
                      ),
                      Text(
                        "${settings.doubleTapSeekSeconds}",
                        style: TextStyle(
                          color: value.isInitialized && !_isSourceMissing
                              ? Colors.white
                              : Colors.white38,
                          fontSize: 8,
                          fontWeight: FontWeight.bold,
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
                  value.isPlaying
                      ? Icons.pause_circle_filled
                      : Icons.play_circle_fill,
                  color: value.isInitialized || _isSourceMissing
                      ? Colors.white
                      : Colors.white38,
                ),
                onPressed: value.isInitialized || _isSourceMissing
                    ? _togglePlay
                    : null,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
              ),

              const SizedBox(width: 30),

              // Seek Forward
              InkWell(
                onTap: value.isInitialized && !_isSourceMissing
                    ? () {
                        final newPos =
                            value.position +
                            Duration(seconds: settings.doubleTapSeekSeconds);
                        final duration = value.duration;
                        final pos = newPos > duration ? duration : newPos;
                        if (playbackService.controller == _controller) {
                          playbackService.seekTo(pos);
                        } else {
                          _controller.seekTo(pos);
                        }
                      }
                    : null,
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
                        child: Icon(
                          Icons.replay,
                          color: value.isInitialized && !_isSourceMissing
                              ? Colors.white
                              : Colors.white38,
                          size: seekIconSize,
                        ),
                      ),
                      Text(
                        "${settings.doubleTapSeekSeconds}",
                        style: TextStyle(
                          color: value.isInitialized && !_isSourceMissing
                              ? Colors.white
                              : Colors.white38,
                          fontSize: 8,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(width: 16),
              // Next Episode
              IconButton(
                icon: Icon(
                  Icons.skip_next,
                  color: playlistManager.hasNext
                      ? Colors.white
                      : Colors.white38,
                ),
                onPressed: playlistManager.hasNext
                    ? () => playbackService.playNext(
                        autoPlay: settings.autoPlayNextVideo,
                      )
                    : null,
                iconSize: 32,
                tooltip: "下一集",
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildLoadingExternalControls(
    SettingsService settings,
    PlaylistManager playlistManager,
    MediaPlaybackService playbackService,
  ) {
    const double seekIconSize = 28.0;
    Widget seekButton({required bool forward}) {
      return SizedBox(
        width: seekIconSize + 16,
        height: seekIconSize + 16,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Transform(
              alignment: Alignment.center,
              transform: forward
                  ? Matrix4.rotationY(3.14159)
                  : Matrix4.identity(),
              child: const Icon(
                Icons.replay,
                color: Colors.white38,
                size: seekIconSize,
              ),
            ),
            Text(
              '${settings.doubleTapSeekSeconds}',
              style: const TextStyle(
                color: Colors.white38,
                fontSize: 8,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      );
    }

    return Container(
      key: const ValueKey('portrait-loading-external-controls'),
      height: 50,
      color: const Color(0xFF1E1E1E),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          IconButton(
            icon: Icon(
              Icons.skip_previous,
              color: playlistManager.hasPrevious
                  ? Colors.white
                  : Colors.white38,
            ),
            onPressed: playlistManager.hasPrevious
                ? () => playbackService.playPrevious(
                    autoPlay: settings.autoPlayNextVideo,
                  )
                : null,
            iconSize: 32,
            tooltip: '上一集',
          ),
          const SizedBox(width: 16),
          seekButton(forward: false),
          const SizedBox(width: 30),
          const Icon(
            Icons.play_circle_fill,
            key: ValueKey('portrait-loading-play-button'),
            color: Colors.white38,
            size: 50,
          ),
          const SizedBox(width: 30),
          seekButton(forward: true),
          const SizedBox(width: 16),
          IconButton(
            icon: Icon(
              Icons.skip_next,
              color: playlistManager.hasNext ? Colors.white : Colors.white38,
            ),
            onPressed: playlistManager.hasNext
                ? () => playbackService.playNext(
                    autoPlay: settings.autoPlayNextVideo,
                  )
                : null,
            iconSize: 32,
            tooltip: '下一集',
          ),
        ],
      ),
    );
  }

  Widget _buildLoadingBottomControlBar(
    SettingsService settings,
    MediaPlaybackService playbackService,
  ) {
    final duration = playbackService.duration > Duration.zero
        ? playbackService.duration
        : Duration(milliseconds: _currentItem.durationMs);
    final position = playbackService.position;
    final maxDuration = duration.inMilliseconds.toDouble();
    final sliderMax = maxDuration > 0 ? maxDuration : 1.0;
    final sliderValue = position.inMilliseconds.toDouble().clamp(
      0.0,
      sliderMax,
    );
    final bufferedValue = playbackService.bufferedPosition.inMilliseconds
        .toDouble()
        .clamp(sliderValue, sliderMax);

    return Container(
      key: const ValueKey('portrait-loading-bottom-control-bar'),
      color: const Color(0xFF1E1E1E),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      height: 36,
      child: Row(
        children: [
          Text(
            '${_formatDuration(position)} / ${_formatDuration(duration)}',
            style: const TextStyle(color: Colors.white70, fontSize: 10),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                disabledActiveTrackColor: const Color(0xFF0D47A1),
                disabledInactiveTrackColor: Colors.white24,
                disabledSecondaryActiveTrackColor: Colors.white38,
                disabledThumbColor: const Color(0xFF1565C0),
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                trackHeight: 2,
              ),
              child: Slider(
                key: const ValueKey('portrait-loading-progress'),
                min: 0,
                max: sliderMax,
                value: sliderValue,
                secondaryTrackValue: bufferedValue,
                onChanged: null,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
            child: Text(
              '${settings.effectiveGlobalPlaybackSpeed}x',
              style: const TextStyle(
                color: Colors.white38,
                fontSize: 10,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          IconButton(
            icon: Icon(
              settings.showSubtitles ? Icons.subtitles : Icons.subtitles_off,
              color: settings.showSubtitles
                  ? Colors.blueAccent
                  : Colors.white70,
              size: 18,
            ),
            onPressed: () => _setFloatingSubtitles(!settings.showSubtitles),
            tooltip: '字幕开关',
            padding: const EdgeInsets.all(4),
            constraints: const BoxConstraints(),
          ),
          IconButton(
            icon: Icon(
              playbackService.isMuted ? Icons.volume_off : Icons.volume_up,
              color: playbackService.isMuted ? Colors.redAccent : Colors.white,
              size: 18,
            ),
            onPressed: () => unawaited(playbackService.toggleMute()),
            tooltip: playbackService.isMuted ? '取消静音' : '静音',
            padding: const EdgeInsets.all(4),
            constraints: const BoxConstraints(),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<SettingsService>(
      builder: (context, settings, child) {
        if (_isOrientationTransitioning) {
          return PopScope(canPop: false, child: _buildOrientationBridge());
        }
        // Use WillPopScope to handle back button and reset orientation early
        // This helps reduce the "jank" when returning to a landscape screen
        return PopScope(
          canPop: false,
          onPopInvokedWithResult: (didPop, result) {
            if (didPop) return;
            _handleBackRequest();
          },
          child: Focus(
            focusNode: _playbackPageFocusNode,
            onKeyEvent: (node, event) =>
                _controlsKey.currentState?.handleKeyEvent(node, event) ??
                KeyEventResult.ignored,
            child: Scaffold(
              backgroundColor: Colors.black,
              body: SelectableRegion(
                key: _selectionKey,
                selectionControls: materialTextSelectionControls,
                focusNode: _selectionFocusNode,
                child: GestureDetector(
                  onTap: () {
                    // 点击空白区域取消文字选择，仅清除选择焦点，
                    // 不调用 unfocus() 避免清除视频控制焦点的键盘快捷键
                    _selectionKey.currentState?.clearSelection();
                    _selectionFocusNode.unfocus();
                    _scheduleVideoFocusRestore();
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
                                    if (!(_activePanel ==
                                            PortraitPanel.subtitleEditor &&
                                        _isSubtitleEditorExpanded))
                                      // 1. Video Area (Top)
                                      Container(
                                        color: Colors.black,
                                        child: AspectRatio(
                                          aspectRatio:
                                              _portraitDisplayAspectRatio(),
                                          child: LayoutBuilder(
                                            builder: (context, constraints) {
                                              return Stack(
                                                fit: StackFit.expand,
                                                children: [
                                                  if (_isSourceMissing)
                                                    const ColoredBox(
                                                      color: Colors.black,
                                                      child: Center(
                                                        child: Text(
                                                          "没有原媒体",
                                                          style: TextStyle(
                                                            color:
                                                                Colors.white70,
                                                            fontSize: 18,
                                                            fontWeight:
                                                                FontWeight.w500,
                                                          ),
                                                        ),
                                                      ),
                                                    )
                                                  else if (_initialized)
                                                    if (_isAudio)
                                                      Container(
                                                        color: Colors.black,
                                                        child: const Center(
                                                          child: Icon(
                                                            Icons.music_note,
                                                            size: 80,
                                                            color:
                                                                Colors.white24,
                                                          ),
                                                        ),
                                                      )
                                                    else
                                                      Center(
                                                        child: AspectRatio(
                                                          aspectRatio:
                                                              _nativeVideoAspectRatio(),
                                                          child: Transform(
                                                            alignment: Alignment
                                                                .center,
                                                            transform:
                                                                _buildVideoDisplayTransformMatrix(),
                                                            child: VideoPlayer(
                                                              _controller,
                                                              key:
                                                                  _videoTextureKey,
                                                            ),
                                                          ),
                                                        ),
                                                      )
                                                  else ...[
                                                    if (!_isAudio &&
                                                        _currentItem
                                                                .thumbnailPath !=
                                                            null &&
                                                        File(
                                                          _currentItem
                                                              .thumbnailPath!,
                                                        ).existsSync())
                                                      Image.file(
                                                        File(
                                                          _currentItem
                                                              .thumbnailPath!,
                                                        ),
                                                        fit: BoxFit.cover,
                                                      )
                                                    else
                                                      Container(
                                                        color: Colors.black,
                                                      ),
                                                    Center(
                                                      child:
                                                          CircularProgressIndicator(
                                                            color: Colors.white
                                                                .withValues(
                                                                  alpha: 0.5,
                                                                ),
                                                          ),
                                                    ),
                                                  ],
                                                  if (_isDraggingProgress &&
                                                      !_isLocked)
                                                    Positioned.fill(
                                                      child: Container(
                                                        color: Colors.black
                                                            .withValues(
                                                              alpha:
                                                                  _isProgressDragCanceling
                                                                  ? 0.28
                                                                  : 0.16,
                                                            ),
                                                        alignment:
                                                            Alignment.center,
                                                        child: Text(
                                                          _isProgressDragCanceling
                                                              ? "松手取消"
                                                              : "上滑至此区域取消",
                                                          style:
                                                              const TextStyle(
                                                                color: Colors
                                                                    .white,
                                                                fontSize: 16,
                                                                fontWeight:
                                                                    FontWeight
                                                                        .bold,
                                                              ),
                                                        ),
                                                      ),
                                                    ),
                                                  if (_initialized)
                                                    _buildPortraitDanmakuOverlay(
                                                      settings,
                                                    ),
                                                  // Controls Overlay
                                                  if (_isControllerAssigned &&
                                                      !_isSubtitleDragMode)
                                                    VideoControlsOverlay(
                                                      key: _controlsKey,
                                                      enableSeekThumbnailPreview:
                                                          _currentItem
                                                                  .sourceRef
                                                                  ?.kind !=
                                                              MediaSourceKind
                                                                  .bilibiliStream ||
                                                          (_currentItem
                                                                  .bilibiliVideoShot
                                                                  ?.hasLocalSprites ??
                                                              false),
                                                      bilibiliVideoShot:
                                                          _currentItem
                                                                  .bilibiliVideoShot
                                                                  ?.hasLocalSprites ==
                                                              true
                                                          ? _currentItem
                                                                .bilibiliVideoShot
                                                          : null,
                                                      controller: _controller,
                                                      isLocked: _isLocked,
                                                      onTogglePlay: _togglePlay,
                                                      onBackPressed:
                                                          _handleBackRequest,
                                                      onSeekTo: (position) {
                                                        _seekPlaybackPosition(
                                                          position,
                                                        );
                                                      },
                                                      onExitPressed: () async {
                                                        _forceExit = true;
                                                        await _handleBackRequest();
                                                      },
                                                      onToggleSidebar: null,
                                                      onToggleFullScreen: () =>
                                                          settings
                                                              .toggleFullScreen(),
                                                      onOpenSettings: null,
                                                      onOpenSubtitleEditor:
                                                          null,
                                                      onOpenVideoCompose: null,

                                                      onToggleLock: () =>
                                                          setState(
                                                            () => _isLocked =
                                                                !_isLocked,
                                                          ),
                                                      showDanmakuControls:
                                                          _currentItem
                                                              .isBilibiliExported,
                                                      danmakuEnabled: settings
                                                          .showBilibiliDanmaku,
                                                      onToggleDanmaku: () => unawaited(
                                                        settings.saveShowBilibiliDanmaku(
                                                          !settings
                                                              .showBilibiliDanmaku,
                                                        ),
                                                      ),
                                                      onOpenDanmakuSettings:
                                                          () => unawaited(
                                                            showDanmakuSettingsDialog(
                                                              context,
                                                              videoItem:
                                                                  _currentItem,
                                                              onDanmakuUpdated: () {
                                                                if (mounted) {
                                                                  setState(
                                                                    () =>
                                                                        _danmakuRevision++,
                                                                  );
                                                                }
                                                              },
                                                            ),
                                                          ),
                                                      onSpeedUpdate:
                                                          _handlePlaybackSpeedSelected,
                                                      doubleTapSeekSeconds: settings
                                                          .doubleTapSeekSeconds,
                                                      enableDoubleTapSubtitleSeek:
                                                          settings
                                                              .enableDoubleTapSubtitleSeek,
                                                      subtitles: _subtitles,
                                                      longPressSpeed: settings
                                                          .longPressSpeed,
                                                      showSubtitles: settings
                                                          .showSubtitles,
                                                      suppressSubtitleOverlay:
                                                          _suppressSubtitleOverlayForOcr,
                                                      allowPlayWhenUninitialized:
                                                          _isSourceMissing,
                                                      onToggleSubtitles: () =>
                                                          _setFloatingSubtitles(
                                                            !settings
                                                                .showSubtitles,
                                                          ),
                                                      onMoveSubtitles:
                                                          _enterSubtitleDragMode,
                                                      subtitleEntries:
                                                          _currentSubtitleEntries,
                                                      subtitleStyle: _isAudio
                                                          ? settings
                                                                .audioSubtitleStylePortrait
                                                          : settings
                                                                .subtitleStylePortrait,
                                                      subtitleAlignment:
                                                          _isAudio
                                                          ? settings
                                                                .audioSubtitleAlignment
                                                          : settings
                                                                .subtitleAlignment,
                                                      onEnterSubtitleDragMode:
                                                          _enterSubtitleDragMode,
                                                      onClearSelection: () =>
                                                          _selectionKey
                                                              .currentState
                                                              ?.clearSelection(),
                                                      showPlayControls: false,
                                                      showBottomBar: false,
                                                      focusNode:
                                                          _videoFocusNode,
                                                      isLongPressing:
                                                          _isLongPressing,
                                                      longPressFeedbackText:
                                                          _longPressFeedbackText,
                                                      onLongPressStart:
                                                          _startLongPressSpeed,
                                                      onLongPressEnd:
                                                          _endLongPressSpeed,
                                                      mediaTitle:
                                                          _currentItem.title,
                                                      onExperimentalTrigger:
                                                          _navigateToMusicPlayer,
                                                      onOpenAspectRatio:
                                                          _showPortraitAspectRatioSheet,
                                                      aspectRatioLabel:
                                                          _portraitAspectRatioLabel(
                                                            _isAudio
                                                                ? (_settingsService
                                                                          ?.audioPortraitDisplayAspectRatio ??
                                                                      1.0)
                                                                : _currentItem
                                                                      .portraitDisplayAspectRatio,
                                                          ),
                                                      compactTopRightButtons:
                                                          true,
                                                    ),

                                                  // Fullscreen Button (Custom for Portrait)
                                                  if (!_isLocked &&
                                                      !_isSubtitleDragMode)
                                                    Positioned(
                                                      bottom: 10,
                                                      right: 10,
                                                      child: IconButton(
                                                        icon: Icon(
                                                          Icons.fullscreen,
                                                          color:
                                                              (_initialized ||
                                                                  _isSourceMissing)
                                                              ? Colors.white
                                                              : Colors.white38,
                                                          size: 30,
                                                        ),
                                                        onPressed:
                                                            (_initialized ||
                                                                _isSourceMissing)
                                                            ? _goToLandscape
                                                            : null,
                                                        style:
                                                            IconButton.styleFrom(
                                                              backgroundColor:
                                                                  Colors
                                                                      .black45,
                                                            ),
                                                      ),
                                                    ),
                                                  // Keep ordinary subtitles above every playback
                                                  // control so low-positioned text is never hidden
                                                  // behind the progress bar or buttons.
                                                  if (_initialized &&
                                                      ((settings.showSubtitles &&
                                                              !_suppressSubtitleOverlayForOcr) ||
                                                          _videoComposePreviewActive))
                                                    _isAudio
                                                        ? _buildPageSubtitleOverlay(
                                                            alignment: settings
                                                                .audioSubtitleAlignment,
                                                            style: settings
                                                                .audioSubtitleStylePortrait,
                                                            isDragging:
                                                                _isSubtitleDragMode,
                                                            displayNotifier:
                                                                _videoComposePreviewActive
                                                                ? _videoComposePreviewController
                                                                      .displayNotifier
                                                                : null,
                                                          )
                                                        : Positioned.fill(
                                                            child: Center(
                                                              child: AspectRatio(
                                                                aspectRatio:
                                                                    _nativeVideoAspectRatio(),
                                                                child:
                                                                    _videoComposePreviewActive
                                                                    ? SubtitleDisplayLayer(
                                                                        notifier:
                                                                            _videoComposePreviewController.displayNotifier,
                                                                        alignment:
                                                                            settings.subtitleAlignment,
                                                                        style: settings
                                                                            .subtitleStylePortrait,
                                                                        isDragging:
                                                                            _isSubtitleDragMode,
                                                                      )
                                                                    : SubtitleOverlayGroup(
                                                                        entries:
                                                                            _currentSubtitleEntries,
                                                                        alignment:
                                                                            settings.subtitleAlignment,
                                                                        style: settings
                                                                            .subtitleStylePortrait,
                                                                        isDragging:
                                                                            _isSubtitleDragMode,
                                                                        isVisualOnly:
                                                                            false,
                                                                      ),
                                                              ),
                                                            ),
                                                          ),
                                                  // Drag Mode Layer
                                                  if (_initialized &&
                                                      _isSubtitleDragMode) ...[
                                                    _isAudio
                                                        ? _buildPageSubtitleOverlay(
                                                            alignment: settings
                                                                .audioSubtitleAlignment,
                                                            style: settings
                                                                .audioSubtitleStylePortrait,
                                                            isDragging: true,
                                                            isGestureOnly: true,
                                                            enablePanUpdate:
                                                                true,
                                                          )
                                                        : Center(
                                                            child: AspectRatio(
                                                              aspectRatio:
                                                                  _nativeVideoAspectRatio(),
                                                              child: LayoutBuilder(
                                                                builder:
                                                                    (
                                                                      context,
                                                                      videoConstraints,
                                                                    ) {
                                                                      return Stack(
                                                                        fit: StackFit
                                                                            .expand,
                                                                        children: [
                                                                          Align(
                                                                            alignment:
                                                                                settings.subtitleAlignment,
                                                                            child: GestureDetector(
                                                                              onPanUpdate:
                                                                                  (
                                                                                    details,
                                                                                  ) => _updateSubtitlePosition(
                                                                                    details,
                                                                                    videoConstraints,
                                                                                  ),
                                                                              child: SubtitleOverlayGroup(
                                                                                entries: _currentSubtitleEntries,
                                                                                alignment: settings.subtitleAlignment,
                                                                                style: settings.subtitleStylePortrait,
                                                                                isDragging: true,
                                                                                isGestureOnly: true,
                                                                              ),
                                                                            ),
                                                                          ),
                                                                        ],
                                                                      );
                                                                    },
                                                              ),
                                                            ),
                                                          ),
                                                    if (_isSubtitleNearCenterX)
                                                      Center(
                                                        child: Container(
                                                          width:
                                                              _isSubtitleSnappedX
                                                              ? 2
                                                              : 1,
                                                          height:
                                                              double.infinity,
                                                          color: Colors.white
                                                              .withValues(
                                                                alpha:
                                                                    _isSubtitleSnappedX
                                                                    ? 0.52
                                                                    : 0.22,
                                                              ),
                                                        ),
                                                      ),
                                                    if (_isSubtitleNearCenterY)
                                                      Center(
                                                        child: Container(
                                                          width:
                                                              double.infinity,
                                                          height:
                                                              _isSubtitleSnappedY
                                                              ? 2
                                                              : 1,
                                                          color: Colors.white
                                                              .withValues(
                                                                alpha:
                                                                    _isSubtitleSnappedY
                                                                    ? 0.52
                                                                    : 0.22,
                                                              ),
                                                        ),
                                                      ),
                                                    Positioned(
                                                      top: 20,
                                                      left: 0,
                                                      right: 0,
                                                      child: Center(
                                                        child: Container(
                                                          padding:
                                                              const EdgeInsets.symmetric(
                                                                horizontal: 16,
                                                                vertical: 8,
                                                              ),
                                                          decoration: BoxDecoration(
                                                            color:
                                                                Colors.black54,
                                                            borderRadius:
                                                                BorderRadius.circular(
                                                                  20,
                                                                ),
                                                          ),
                                                          child: Text(
                                                            _isStylePanelDragMode
                                                                ? "拖拽调整位置"
                                                                : "拖拽调整位置 (点击退出)",
                                                            style: TextStyle(
                                                              color:
                                                                  Colors.white,
                                                            ),
                                                          ),
                                                        ),
                                                      ),
                                                    ),
                                                    if (!_isStylePanelDragMode)
                                                      Positioned.fill(
                                                        child: GestureDetector(
                                                          onTap:
                                                              _exitSubtitleDragMode,
                                                          behavior:
                                                              HitTestBehavior
                                                                  .translucent,
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
                                    if (!(_activePanel ==
                                            PortraitPanel.subtitleEditor &&
                                        _isSubtitleEditorExpanded))
                                      // 2. External Play Controls (Middle) + Bottom Bar
                                      Stack(
                                        clipBehavior: Clip.none,
                                        children: [
                                          Column(
                                            children: [
                                              _buildExternalControls(),
                                              _buildBottomControlBar(),
                                            ],
                                          ),
                                        ],
                                      ),
                                    // 3. Subtitle Sidebar (Bottom)
                                    Expanded(
                                      child: AnimatedSwitcher(
                                        duration: const Duration(
                                          milliseconds: 300,
                                        ),
                                        layoutBuilder:
                                            (
                                              Widget? currentChild,
                                              List<Widget> previousChildren,
                                            ) {
                                              return Stack(
                                                alignment: Alignment.topCenter,
                                                fit: StackFit.expand,
                                                children: <Widget>[
                                                  ...previousChildren,
                                                  ...?(currentChild == null
                                                      ? null
                                                      : <Widget>[currentChild]),
                                                ],
                                              );
                                            },
                                        transitionBuilder:
                                            (
                                              Widget child,
                                              Animation<double> animation,
                                            ) {
                                              return SlideTransition(
                                                position:
                                                    Tween<Offset>(
                                                      begin: const Offset(
                                                        0.0,
                                                        1.0,
                                                      ),
                                                      end: Offset.zero,
                                                    ).animate(
                                                      CurvedAnimation(
                                                        parent: animation,
                                                        curve:
                                                            Curves.easeOutCubic,
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
                                          borderRadius: BorderRadius.circular(
                                            16,
                                          ),
                                          boxShadow: [
                                            BoxShadow(
                                              color: Colors.black45,
                                              blurRadius: 4,
                                              offset: Offset(0, 2),
                                            ),
                                          ],
                                        ),
                                        padding: const EdgeInsets.symmetric(
                                          vertical: 8,
                                        ),
                                        child: RotatedBox(
                                          quarterTurns: -1,
                                          child: SliderTheme(
                                            data: SliderTheme.of(context).copyWith(
                                              activeTrackColor: Colors.white,
                                              inactiveTrackColor:
                                                  Colors.white24,
                                              thumbColor: Colors.white,
                                              thumbShape:
                                                  const RoundSliderThumbShape(
                                                    enabledThumbRadius: 6.0,
                                                  ),
                                              trackHeight: 2.0,
                                              overlayShape:
                                                  const RoundSliderOverlayShape(
                                                    overlayRadius: 12,
                                                  ),
                                            ),
                                            child: Slider(
                                              value: _controller.value.volume,
                                              onChanged: (v) {
                                                final playbackService =
                                                    Provider.of<
                                                      MediaPlaybackService
                                                    >(context, listen: false);
                                                unawaited(
                                                  playbackService.setVolume(v),
                                                );
                                              },
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
                                      onHorizontalDragStart:
                                          _onIosBackSwipeStart,
                                      onHorizontalDragUpdate:
                                          _onIosBackSwipeUpdate,
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
          ),
        );
      },
    );
  }

  Widget _buildBottomPanel(SettingsService settings) {
    switch (_activePanel) {
      case PortraitPanel.ai:
        return AiTranscriptionPanel(
          videoPath: _currentItem.path,
          videoId: _currentItem.id,
          onBack: () => setState(() => _activePanel = PortraitPanel.subtitles),
          onCompleted: (path) async {
            final settingsService = Provider.of<SettingsService>(
              context,
              listen: false,
            );
            final libraryService = Provider.of<LibraryService>(
              context,
              listen: false,
            );

            // Auto load generated subtitle
            if (await File(path).exists()) {
              List<String> pathsToLoad = [path];
              if (_currentSubtitlePaths.length > 1) {
                pathsToLoad.add(_currentSubtitlePaths[1]);
              }
              await _loadSubtitles(pathsToLoad);
              // Also update library
              final String? currentSecondary = _currentSubtitlePaths.length > 1
                  ? _currentSubtitlePaths[1]
                  : _currentItem.secondarySubtitlePath;
              libraryService.updateVideoSubtitles(
                _currentItem.id,
                path,
                settingsService.autoCacheSubtitles,
                secondarySubtitlePath: currentSecondary,
                isSecondaryCached: settingsService.autoCacheSubtitles,
              );
              if (mounted) {
                AppToast.show("AI 字幕已生成并自动加载", type: AppToastType.success);
              }
            }
          },
        );
      case PortraitPanel.subtitleManager:
        final List<String> selectedPathsForSheet =
            _currentSubtitlePaths.isNotEmpty
            ? List<String>.from(_currentSubtitlePaths)
            : <String>[
                if (_currentItem.subtitlePath != null &&
                    _currentItem.subtitlePath!.isNotEmpty)
                  _currentItem.subtitlePath!,
                if (_currentItem.secondarySubtitlePath != null &&
                    _currentItem.secondarySubtitlePath!.isNotEmpty)
                  _currentItem.secondarySubtitlePath!,
              ];
        final associatedSubtitlesForSheet =
            _currentItem.downloadAssociatedSubtitles;
        final localSubtitlesForSheet = _currentItem.localSubtitleGroups;
        return SubtitleManagementSheet(
          key: ValueKey(_currentItem.path),
          videoPath: _currentItem.path,
          videoId: _currentItem.id,
          showEmbeddedSubtitles: true,
          associatedSubtitles: associatedSubtitlesForSheet,
          localSubtitles: localSubtitlesForSheet,
          initialSelectedPaths: selectedPathsForSheet,
          onSubtitleChanged: () {
            // Reload if needed or handled by logic
          },
          onSubtitleSelected: (paths) async {
            final settingsService = Provider.of<SettingsService>(
              context,
              listen: false,
            );
            final libraryService = Provider.of<LibraryService>(
              context,
              listen: false,
            );

            await _loadSubtitles(paths);
            if (mounted) {
              String? path0;
              String? path1;

              if (paths.isNotEmpty) path0 = paths[0];
              if (paths.length > 1) path1 = paths[1];

              await libraryService.updateVideoSubtitles(
                _currentItem.id,
                path0,
                settingsService.autoCacheSubtitles,
                secondarySubtitlePath: path1,
                isSecondaryCached: settingsService.autoCacheSubtitles,
              );
              final updated = libraryService.getVideo(_currentItem.id);
              if (updated != null && mounted) {
                setState(() {
                  _currentItem = updated;
                });
              }
              // Keep open, no pop needed here as it is an inline panel replacement
            }
          },
          onSubtitlePreview: (path) async {
            final settingsService = Provider.of<SettingsService>(
              context,
              listen: false,
            );
            final libraryService = Provider.of<LibraryService>(
              context,
              listen: false,
            );

            List<String> pathsToLoad = [path];
            if (_currentSubtitlePaths.length > 1) {
              pathsToLoad.add(_currentSubtitlePaths[1]);
            }
            await _loadSubtitles(pathsToLoad);
            // Do not close panel
            if (mounted) {
              final String? currentSecondary = _currentSubtitlePaths.length > 1
                  ? _currentSubtitlePaths[1]
                  : _currentItem.secondarySubtitlePath;
              libraryService.updateVideoSubtitles(
                _currentItem.id,
                path,
                settingsService.autoCacheSubtitles,
                secondarySubtitlePath: currentSecondary,
                isSecondaryCached: settingsService.autoCacheSubtitles,
              );
            }
          },
          onClose: _closeSubtitleManager,
          onOpenAi: () => setState(() => _activePanel = PortraitPanel.ai),
        );
      case PortraitPanel.episodePicker:
        return LayoutBuilder(
          builder: (context, constraints) {
            return EpisodePickerPanel(
              key: const ValueKey("EpisodePickerPanel_Portrait"),
              panelWidth: constraints.maxWidth,
              panelHeight: constraints.maxHeight,
              onClose: () =>
                  setState(() => _activePanel = PortraitPanel.subtitles),
              isPortrait: true,
            );
          },
        );
      case PortraitPanel.videoCompose:
        return VideoComposePanel(
          key: ValueKey('video_compose_${_currentItem.id}'),
          videoItem: _currentItem,
          currentSelectedPaths: List<String>.from(_currentSubtitlePaths),
          availableSubtitleMap: _buildAvailableSubtitleMap(),
          onBack: () {
            _clearVideoComposePreview();
            setState(() => _activePanel = PortraitPanel.subtitles);
          },
          onOpenSubtitleStyle: () =>
              _openSubtitleStyleSettings(fromCompose: true),
          onOpenSubtitleManager: () => _openSubtitleManager(fromCompose: true),
          onPreviewChanged: _applyVideoComposePreview,
        );
      case PortraitPanel.ocrSubtitle:
        if (_isAudio) return const SizedBox.shrink();
        if (!_isControllerAssigned || !_initialized) {
          return const Center(
            child: Text(
              '播放器加载完成后可使用 OCR 字幕',
              style: TextStyle(color: Colors.white54),
            ),
          );
        }
        return OcrSubtitlePanel(
          key: ValueKey('ocr_subtitle_${_currentItem.id}'),
          videoItem: _currentItem,
          duration: _controller.value.duration,
          currentPosition: () => _controller.value.position,
          pauseForRegionSelection: () async {
            final wasPlaying = _controller.value.isPlaying;
            await _controller.pause();
            return wasPlaying;
          },
          restorePlayback: (wasPlaying) async {
            if (wasPlaying && mounted) await _controller.play();
          },
          onBack: () => setState(() => _activePanel = PortraitPanel.subtitles),
          onCompleted: _applyCompletedOcrSubtitles,
        );
      case PortraitPanel.subtitleEditor:
        final Map<String, String> groups = _buildSubtitleEditorGroups();
        String? activePath = _resolveActiveSubtitleEditorPath();
        if (activePath == null && groups.isNotEmpty) {
          activePath = groups.values.first;
        }
        return SubtitleEditorPanel(
          groups: groups,
          activeGroupPath: activePath,
          subtitles: _subtitles,
          currentSubtitleIndex: _currentSubtitleIndex,
          currentPlaybackPosition:
              _isControllerAssigned && _controller.value.isInitialized
              ? _controller.value.position
              : Duration.zero,
          onSelectGroupPath: _applyPrimarySubtitlePath,
          onCreateGroup: (name) async {
            await _createManualSubtitleGroup(name);
            if (mounted) setState(() {});
          },
          onRenameGroup: (oldName, newName) async {
            await _renameSubtitleGroup(oldName, newName);
          },
          onSubtitlesChanged: _onSubtitleEditorSubtitlesChanged,
          onSeekTo: _seekToSubtitleFast,
          onBack: () => setState(() {
            _activePanel = PortraitPanel.subtitles;
            _isSubtitleEditorExpanded = false;
          }),
          isExpanded: _isSubtitleEditorExpanded,
          onToggleExpanded: () => setState(() {
            _isSubtitleEditorExpanded = !_isSubtitleEditorExpanded;
          }),
        );
      case PortraitPanel.settings:
        final displayedPlaybackSpeed =
            _isControllerAssigned && _controller.value.isInitialized
            ? _controller.value.playbackSpeed
            : settings.effectiveGlobalPlaybackSpeed;
        final bool showMobilePlaybackControls =
            !kIsWeb && (Platform.isAndroid || Platform.isIOS);
        return SettingsPanel(
          key: const ValueKey("SettingsPanel"),
          playbackSpeed: displayedPlaybackSpeed,
          isAudioMode: _isAudio,
          syncAudioSubtitleStyleWithVideo:
              settings.syncAudioSubtitleStyleWithVideo,
          onSyncAudioSubtitleStyleWithVideoChanged: _isAudio
              ? (value) => settings.setAudioSubtitleStyleSyncWithVideo(value)
              : null,
          showSkipPortraitPlayerSetting:
              !kIsWeb && (Platform.isAndroid || Platform.isIOS),
          skipPortraitPlayer: settings.skipPortraitPlayer,
          onSkipPortraitPlayerChanged: (value) =>
              settings.saveSkipPortraitPlayer(value),
          isPlaybackSpeedLocked: settings.isPlaybackSpeedLocked,
          lockedPlaybackSpeed: settings.isPlaybackSpeedLocked
              ? settings.playbackSpeed
              : null,
          showSubtitles: settings.showSubtitles,
          isMirroredH: _currentItem.isVideoMirroredH,
          isMirroredV: _currentItem.isVideoMirroredV,
          doubleTapSeekSeconds: settings.doubleTapSeekSeconds,
          enableDoubleTapSubtitleSeek: settings.enableDoubleTapSubtitleSeek,
          onDoubleTapSubtitleSeekChanged: (val) =>
              settings.saveEnableDoubleTapSubtitleSeek(val),
          subtitleDelay: settings.subtitleDelay,
          longPressSpeed: settings.longPressSpeed,
          showLongPressSpeedIndicator: settings.showLongPressSpeedIndicator,
          autoCacheSubtitles: settings.autoCacheSubtitles,
          onSpeedChanged: (val) => unawaited(_handlePlaybackSpeedSelected(val)),
          onSpeedLockChanged: _handlePlaybackSpeedLockChanged,
          onSubtitleToggle: (val) => _setFloatingSubtitles(val),
          onMirrorHChanged: (val) =>
              unawaited(_updateVideoDisplayTransform(isMirroredH: val)),
          onMirrorVChanged: (val) =>
              unawaited(_updateVideoDisplayTransform(isMirroredV: val)),
          onSeekSecondsChanged: (val) => settings.saveDoubleTapSeekSeconds(val),
          onSubtitleDelayChanged: (val) => settings.setSubtitleDelay(val),
          onSubtitleDelayChangeEnd: (val) => settings.saveSubtitleDelay(val),
          onLongPressSpeedChanged: (val) => settings.saveLongPressSpeed(val),
          onShowLongPressSpeedIndicatorChanged: (val) =>
              settings.saveShowLongPressSpeedIndicator(val),
          onAutoCacheSubtitlesChanged: (val) =>
              settings.saveAutoCacheSubtitles(val),
          splitSubtitleByLine: settings.splitSubtitleByLine,
          onSplitSubtitleByLineChanged: (val) =>
              settings.saveSplitSubtitleByLine(val),
          continuousSubtitle: _isAudio
              ? settings.audioContinuousSubtitle
              : settings.videoContinuousSubtitle,
          onContinuousSubtitleChanged: (value) {
            if (_isAudio) {
              settings.saveAudioContinuousSubtitle(value);
            } else {
              settings.saveVideoContinuousSubtitle(value);
            }
          },
          autoPauseOnExit: settings.autoPauseOnExit,
          onAutoPauseOnExitChanged: (val) => settings.saveAutoPauseOnExit(val),
          avoidPlaybackControlsWithSubtitles:
              settings.avoidPlaybackControlsWithSubtitles,
          onAvoidPlaybackControlsWithSubtitlesChanged: (val) =>
              settings.saveAvoidPlaybackControlsWithSubtitles(val),
          pausePlaybackWhenAppBackgrounded:
              settings.pausePlaybackWhenAppBackgrounded,
          onPausePlaybackWhenAppBackgroundedChanged: (val) =>
              settings.savePausePlaybackWhenAppBackgrounded(val),
          allowConcurrentPlayback: settings.allowConcurrentPlayback,
          onAllowConcurrentPlaybackChanged: (val) =>
              settings.saveAllowConcurrentPlayback(val),
          showVideoDecoderSetting:
              !kIsWeb &&
              (Platform.isAndroid ||
                  Platform.isIOS ||
                  Platform.isMacOS ||
                  Platform.isWindows ||
                  Platform.isLinux),
          useHardwareVideoDecoding: settings.useHardwareVideoDecoding,
          onVideoDecoderChanged: (useHardware) async {
            await settings.saveUseHardwareVideoDecoding(useHardware);
            await MediaPlaybackService().reloadCurrentVideoDecoder();
          },
          enableHeadsetMediaControls: settings.enableHeadsetMediaControls,
          onEnableHeadsetMediaControlsChanged: (val) =>
              settings.saveEnableHeadsetMediaControls(val),
          showMobilePlaybackControls: showMobilePlaybackControls,
          autoPlayNextVideo: settings.autoPlayNextVideo,
          onAutoPlayNextVideoChanged: (val) =>
              settings.saveAutoPlayNextVideo(val),
          autoPlayOnCompletion: settings.autoPlayOnCompletion,
          onAutoPlayOnCompletionChanged: (val) =>
              settings.saveAutoPlayOnCompletion(val),
          autoPlayOnCompletionFromStart: settings.autoPlayOnCompletionFromStart,
          onAutoPlayOnCompletionFromStartChanged: (val) =>
              settings.saveAutoPlayOnCompletionFromStart(val),
          enableSeekPreview: settings.enableSeekPreview,
          onEnableSeekPreviewChanged: (val) =>
              settings.saveEnableSeekPreview(val),
          enableHapticFeedback: settings.enableHapticFeedback,
          onEnableHapticFeedbackChanged: (val) =>
              settings.saveEnableHapticFeedback(val),
          isLeftHandedMode: settings.isLeftHandedMode,
          onLeftHandedModeChanged: (val) => settings.saveLeftHandedMode(val),
          onClose: () => setState(() => _activePanel = PortraitPanel.subtitles),
          onLoadSubtitle: _pickSubtitle,
          onOpenSubtitleSettings: _openSubtitleStyleSettings,
        );
      case PortraitPanel.subtitleStyle:
        return SubtitleSettingsSheet(
          key: const ValueKey("SubtitleSettingsSheet"),
          style: _isAudio
              ? settings.audioSubtitleStylePortrait
              : settings.subtitleStylePortrait,
          isLandscape: false,
          isAudio: _isAudio,
          syncAudioSubtitleStyleWithVideo:
              settings.syncAudioSubtitleStyleWithVideo,
          onSyncAudioSubtitleStyleWithVideoChanged: _isAudio
              ? (value) => settings.setAudioSubtitleStyleSyncWithVideo(value)
              : null,
          hideGhostModeToggle: true,
          // 文字样式改变时同步到横竖屏
          onTextStyleChanged: (newTextStyle) {
            if (_isAudio) {
              if (settings.syncAudioSubtitleStyleWithVideo) {
                settings.saveSubtitleTextStyle(newTextStyle);
              } else {
                settings.saveAudioSubtitleTextStyle(newTextStyle);
              }
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
              if (settings.syncAudioSubtitleStyleWithVideo) {
                settings.saveSubtitleTextStyle(newStyle.textStyle);
                settings.saveAudioSubtitleLayoutPortrait(newStyle.layoutStyle);
              } else {
                settings.saveAudioSubtitleStylePortrait(newStyle);
              }
            } else {
              settings.saveSubtitleStylePortrait(newStyle);
            }
          },
          onClose: _closeSubtitleStyleSettings,
          onBack: _closeSubtitleStyleSettings,
        );
      case PortraitPanel.subtitles:
        return SubtitleSidebar(
          key: _subtitleSidebarKey,
          subtitles: _subtitles,
          secondarySubtitles: _secondarySubtitles,
          controller: _isControllerAssigned ? _controller : null,
          positionListenable: MediaPlaybackService().positionNotifier,
          onItemTap: _seekToSubtitleFast,
          onClose: () {}, // Maybe close app? or hide sidebar?
          onOpenSettings: () {
            developer.log('Opening settings panel');
            setState(() => _activePanel = PortraitPanel.settings);
          },
          onLoadSubtitle: _pickSubtitle,
          onOpenSubtitleStyle: _openSubtitleStyleSettings,
          onOpenSubtitleManager: _openSubtitleManager,
          onClearSelection: () => _selectionKey.currentState?.clearSelection(),
          onScanEmbeddedSubtitles: _checkAndLoadEmbeddedSubtitle,
          onOpenEpisodePicker: () =>
              setState(() => _activePanel = PortraitPanel.episodePicker),
          onOpenVideoCompose: _openVideoCompose,
          onOpenOcrSubtitle: _supportsOcrSubtitle ? _openOcrSubtitle : null,
          onOpenSubtitleEditor: () => setState(() {
            _activePanel = PortraitPanel.subtitleEditor;
            _isSubtitleEditorExpanded = false;
          }),
          isCompact: true,
          isPortrait: true,
          focusNode: _videoFocusNode,
          isVisible: _activePanel == PortraitPanel.subtitles,
          showEmbeddedLoadingMessage:
              _embeddedSubtitleDetected &&
              _isLoadingEmbeddedSubtitle &&
              _subtitles.isEmpty &&
              _secondarySubtitles.isEmpty,
        );
    }
  }

  Map<String, String> _buildAvailableSubtitleMap() {
    final Map<String, String> map = <String, String>{};
    final additional = <String, String>{
      ..._currentItem.downloadAssociatedSubtitles,
      ..._currentItem.localSubtitleGroups,
    };
    final Map<String, String> nameByPath = <String, String>{};
    if (additional.isNotEmpty) {
      additional.forEach((name, path) {
        if (path.isEmpty) return;
        nameByPath[_subtitlePathKey(path)] = name;
      });
    }
    String embeddedFallbackName(String path, String fallback) {
      final normalized = p.basename(path);
      final match = RegExp(r'\.stream_(\d+)').firstMatch(normalized);
      if (match != null) {
        final index = match.group(1);
        if (index != null && index.isNotEmpty) {
          return '内嵌字幕 $index';
        }
      }
      // 回退到文件名，避免显示"主字幕（主字幕）"这类冗余文本
      final base = p.basenameWithoutExtension(path).trim();
      return base.isNotEmpty ? base : fallback;
    }

    String nameForPath(String path, {String fallback = '未命名字幕'}) {
      final name = nameByPath[_subtitlePathKey(path)];
      if (name != null && name.trim().isNotEmpty) {
        return name;
      }
      return embeddedFallbackName(path, fallback);
    }

    final String? primary = _currentItem.subtitlePath;
    if (primary != null && primary.isNotEmpty) {
      map[primary] = '主字幕（${nameForPath(primary, fallback: '主字幕')}）';
    }
    final String? secondary = _currentItem.secondarySubtitlePath;
    if (secondary != null && secondary.isNotEmpty) {
      map[secondary] = '副字幕（${nameForPath(secondary, fallback: '副字幕')}）';
    }
    if (_currentSubtitlePaths.isNotEmpty) {
      for (int i = 0; i < _currentSubtitlePaths.length; i++) {
        final String path = _currentSubtitlePaths[i];
        if (path.isEmpty) continue;
        final String role = i == 0 ? '当前主字幕' : '当前副字幕';
        map[path] = '$role（${nameForPath(path, fallback: role)}）';
      }
    }
    if (additional.isNotEmpty) {
      additional.forEach((name, path) {
        if (path.isEmpty) return;
        map[path] = name;
      });
    }
    return map;
  }
}
