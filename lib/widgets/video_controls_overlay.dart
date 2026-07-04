import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:video_player/video_player.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart'; // Added for LogicalKeyboardKey
import 'package:provider/provider.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'package:volume_controller/volume_controller.dart';
import '../models/subtitle_style.dart';
import '../models/subtitle_model.dart';
import '../widgets/subtitle_overlay.dart';
import '../services/media_playback_service.dart';
import '../services/settings_service.dart';
import '../services/video_preview_service.dart';
import '../utils/desktop_player_shortcuts.dart';

class VideoControlsOverlay extends StatefulWidget {
  final VideoPlayerController controller;
  final bool isLocked;
  final VoidCallback onTogglePlay;
  final VoidCallback onBackPressed;
  final VoidCallback? onExitPressed; // New: For Windows direct exit
  final VoidCallback? onToggleSidebar;
  final bool isSubtitleSidebarVisible;
  final VoidCallback? onOpenSettings;
  final VoidCallback? onOpenSubtitleManager;
  final VoidCallback? onOpenSubtitleEditor;
  final VoidCallback? onToggleFloatingSubtitleSettings;
  final VoidCallback? onOpenVideoCompose; // New parameter
  final VoidCallback onToggleLock;
  final VoidCallback? onToggleFullScreen; // New: For desktop full screen toggle
  final ValueChanged<Duration>? onSeekTo;
  final ValueChanged<double> onSpeedUpdate;
  final ValueChanged<double>? onSpeedLockToggle;
  final int doubleTapSeekSeconds;
  final bool enableDoubleTapSubtitleSeek;
  final List<SubtitleItem> subtitles;
  final double longPressSpeed;
  final bool showSubtitles;
  final VoidCallback onToggleSubtitles;
  final VoidCallback onMoveSubtitles; // New callback for move subtitles
  final bool isLongPressing;
  final String longPressFeedbackText;
  final VoidCallback onLongPressStart;
  final VoidCallback onLongPressEnd;

  // Subtitle Dragging Passthrough
  final List<SubtitleOverlayEntry> subtitleEntries;
  final SubtitleStyle subtitleStyle;
  final Alignment subtitleAlignment;
  final VoidCallback onEnterSubtitleDragMode;
  final VoidCallback? onClearSelection; // New callback
  final VoidCallback?
  onToggleEpisodePicker; // Callback to toggle episode picker
  final bool showPlayControls;
  final bool showBottomBar;
  final FocusNode? focusNode; // New: External focus node

  // Playlist Navigation
  final VoidCallback? onPlayPrevious;
  final VoidCallback? onPlayNext;
  final bool hasPrevious;
  final bool hasNext;
  final String mediaTitle;
  final bool isPreviewMode; // New parameter for simple preview mode
  final bool showSubtitleEditorButton;
  final VoidCallback? onOpenAspectRatio;
  final String? aspectRatioLabel;
  final bool compactTopRightButtons;
  final bool showResetScreenButton;
  final VoidCallback? onResetScreenTransform;
  final bool suppressPrimaryGestures;

  const VideoControlsOverlay({
    super.key,
    required this.controller,
    required this.isLocked,
    required this.onTogglePlay,
    required this.onBackPressed,
    this.onExitPressed,
    this.onToggleSidebar,
    this.isSubtitleSidebarVisible = false,
    this.onOpenSettings,
    this.onOpenSubtitleManager,
    this.onOpenSubtitleEditor,
    this.onToggleFloatingSubtitleSettings,
    this.onOpenVideoCompose,
    required this.onToggleLock,
    this.onToggleFullScreen,
    this.onSeekTo,
    required this.onSpeedUpdate,
    this.onSpeedLockToggle,
    this.doubleTapSeekSeconds = 5,
    this.enableDoubleTapSubtitleSeek = true,
    this.subtitles = const [],
    this.longPressSpeed = 2.0,
    required this.showSubtitles,
    required this.onToggleSubtitles,
    required this.onMoveSubtitles,
    required this.isLongPressing,
    required this.longPressFeedbackText,
    required this.onLongPressStart,
    required this.onLongPressEnd,
    required this.subtitleEntries,
    required this.subtitleStyle,
    required this.subtitleAlignment,
    required this.onEnterSubtitleDragMode,
    this.onClearSelection,
    this.onToggleEpisodePicker,
    this.showPlayControls = true,
    this.showBottomBar = true,
    this.focusNode,
    this.onPlayPrevious,
    this.onPlayNext,
    this.hasPrevious = false,
    this.hasNext = false,
    this.mediaTitle = '',
    this.isPreviewMode = false,
    this.showSubtitleEditorButton = true,
    this.onOpenAspectRatio,
    this.aspectRatioLabel,
    this.compactTopRightButtons = false,
    this.showResetScreenButton = false,
    this.onResetScreenTransform,
    this.suppressPrimaryGestures = false,
  });

  @override
  State<VideoControlsOverlay> createState() => _VideoControlsOverlayState();
}

class _VideoControlsOverlayState extends State<VideoControlsOverlay> {
  bool _isDraggingProgress = false;
  double _dragProgressValue = 0.0;
  bool _showControls = true;

  // Gesture Seek
  bool _isGestureSeeking = false;
  Duration _gestureTargetTime = Duration.zero;
  String _gestureDiffText = "";
  bool _isGestureCanceling = false;
  bool _showControlsBeforeGestureSeek = false;
  bool _isProgressDragCanceling = false; // New: For slider drag cancellation

  // Long Press Speed
  // bool _isLongPressingZone = false; // Moved to parent
  // String _zoneFeedbackText = ""; // Moved to parent

  // Double Tap Feedback (Local)
  bool _showDoubleTapFeedback = false;
  bool _isDoubleTapFeedbackFadingOut = false;
  String _doubleTapFeedbackText = "";
  Timer? _doubleTapFeedbackHideTimer;
  Timer? _doubleTapFeedbackDismissTimer;
  int _doubleTapFeedbackPulse = 0;
  static const Duration _doubleTapFeedbackVisibleDuration = Duration(
    milliseconds: 430,
  );
  static const Duration _doubleTapFeedbackFadeOutDuration = Duration(
    milliseconds: 180,
  );
  static const Duration _doubleTapChainResetDuration = Duration(
    milliseconds: 900,
  );

  Offset? _tapPosition;

  // Volume & Brightness
  bool _isAdjustingVolume = false;
  bool _isAdjustingBrightness = false;
  // bool _showVolumeSlider = false; // Removed
  double _currentVolume = 0.0;
  double _currentBrightness = 0.0;
  // double _preLongPressSpeed = 1.0; // Moved to parent
  double _startDragValue = 0.0; // Value at start of drag
  // double _sliderVolume = 1.0; // Removed

  // Manual Double Tap Detection
  DateTime? _lastTapTime;
  Offset? _lastTapDownPosition;
  Timer? _singleTapTimer;

  // Keyboard Handling
  final FocusNode _focusNode = FocusNode(
    debugLabel: 'VideoControlsOverlayFocus',
  );
  Timer? _keyboardLongPressTimer;
  bool _isKeyboardLongPressing = false;
  bool _wasPlayingBeforeLongPress = false; // 新增：记录长按前的播放状态
  // Key press tracking
  bool _isSpacePressed = false;
  bool _isRightArrowPressed = false;
  bool _isLeftArrowPressed = false;
  bool _isEscPressed = false;

  Uint8List? _previewImage;
  int _previewRequestSerial = 0;
  Timer? _seekPreviewRefineTimer;
  Timer? _seekPreviewThrottleTimer;
  DateTime? _lastSeekPreviewRequestAt;
  int? _lastSeekPreviewRequestTimeMs;
  double? _pendingSeekPreviewValue;
  static const Duration _seekPreviewRefineDelay = Duration(milliseconds: 140);
  static const Duration _seekPreviewMinInterval = Duration(milliseconds: 65);
  static const int _seekPreviewMinStepMs = 24;

  // Auto-hide controls timer
  Timer? _autoHideTimer;
  static const Duration _autoHideDelay = Duration(seconds: 3);

  String? _resolvePreviewFilePath() {
    final path = widget.controller.dataSource;
    String filePath = path;
    if (path.startsWith('file://')) {
      try {
        filePath = Uri.parse(path).toFilePath();
      } catch (e) {
        // Fallback or ignore
      }
    } else if (path.startsWith('http')) {
      // Skip network streams for performance
      return null;
    }
    return filePath;
  }

  bool _isLockedSpeed(SettingsService settings, double speed) {
    return settings.isLockedPlaybackSpeed(speed);
  }

  PopupMenuEntry<double> _buildPlaybackSpeedMenuItem(
    BuildContext context,
    SettingsService settings,
    double speed,
  ) {
    final bool isLockedSpeed = _isLockedSpeed(settings, speed);

    return PopupMenuItem<double>(
      value: speed,
      padding: EdgeInsets.zero,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onLongPress: widget.onSpeedLockToggle == null
            ? null
            : () {
                Navigator.of(context).pop();
                widget.onSpeedLockToggle!(speed);
              },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: [
              Expanded(child: Text("${speed}x")),
              if (isLockedSpeed)
                const Icon(Icons.lock, size: 16, color: Colors.blueAccent),
            ],
          ),
        ),
      ),
    );
  }

  void _warmSeekPreviewMetadata() {
    final settings = Provider.of<SettingsService>(context, listen: false);
    if (!settings.enableSeekPreview) {
      return;
    }
    final filePath = _resolvePreviewFilePath();
    if (filePath == null) {
      return;
    }
    VideoPreviewService().warmup(filePath);
  }

  void _schedulePreciseSeekPreview(double value) {
    _seekPreviewRefineTimer?.cancel();
    final int targetTimeMs = value.toInt();
    _seekPreviewRefineTimer = Timer(_seekPreviewRefineDelay, () {
      if (!mounted || !_isDraggingProgress) {
        return;
      }
      if ((_dragProgressValue - value).abs() > 1.0) {
        return;
      }
      _updateSeekPreview(value, precise: true, expectedTimeMs: targetTimeMs);
    });
  }

  void _cancelSeekPreviewRefine() {
    _seekPreviewRefineTimer?.cancel();
    _seekPreviewRefineTimer = null;
  }

  void _cancelSeekPreviewThrottle() {
    _seekPreviewThrottleTimer?.cancel();
    _seekPreviewThrottleTimer = null;
    _pendingSeekPreviewValue = null;
  }

  void _resetSeekPreviewRequestState() {
    _cancelSeekPreviewThrottle();
    _lastSeekPreviewRequestAt = null;
    _lastSeekPreviewRequestTimeMs = null;
  }

  void _scheduleLiveSeekPreview(double value, {bool immediate = false}) {
    if (!_isDraggingProgress) {
      return;
    }
    final now = DateTime.now();
    final targetTimeMs = value.toInt();
    final lastRequestedTimeMs = _lastSeekPreviewRequestTimeMs;
    final lastRequestedAt = _lastSeekPreviewRequestAt;
    final bool changedEnough =
        lastRequestedTimeMs == null ||
        (targetTimeMs - lastRequestedTimeMs).abs() >= _seekPreviewMinStepMs;
    final bool intervalPassed =
        lastRequestedAt == null ||
        now.difference(lastRequestedAt) >= _seekPreviewMinInterval;

    if (immediate ||
        (intervalPassed && (changedEnough || _previewImage == null))) {
      _cancelSeekPreviewThrottle();
      _updateSeekPreview(value);
      return;
    }

    _pendingSeekPreviewValue = value;
    if (_seekPreviewThrottleTimer?.isActive ?? false) {
      return;
    }

    final remaining = lastRequestedAt == null
        ? Duration.zero
        : _seekPreviewMinInterval - now.difference(lastRequestedAt);
    _seekPreviewThrottleTimer = Timer(
      remaining.isNegative ? Duration.zero : remaining,
      () {
        _seekPreviewThrottleTimer = null;
        final pendingValue = _pendingSeekPreviewValue;
        if (!mounted || !_isDraggingProgress || pendingValue == null) {
          return;
        }
        final pendingTimeMs = pendingValue.toInt();
        final bool shouldRequest =
            _lastSeekPreviewRequestTimeMs == null ||
            pendingTimeMs != _lastSeekPreviewRequestTimeMs! ||
            _previewImage == null;
        if (shouldRequest) {
          _pendingSeekPreviewValue = null;
          _updateSeekPreview(pendingValue);
        }
      },
    );
  }

  void _updateSeekPreview(
    double value, {
    bool precise = false,
    int? expectedTimeMs,
  }) {
    final settings = Provider.of<SettingsService>(context, listen: false);
    if (!settings.enableSeekPreview) {
      _previewImage = null;
      return;
    }

    final filePath = _resolvePreviewFilePath();
    if (filePath == null) {
      return;
    }

    final int requestSerial = ++_previewRequestSerial;
    final requestTimeMs = value.toInt();
    if (!precise) {
      _lastSeekPreviewRequestAt = DateTime.now();
      _lastSeekPreviewRequestTimeMs = requestTimeMs;
      _pendingSeekPreviewValue = null;
    }
    final future = precise
        ? VideoPreviewService().requestPrecisePreview(filePath, requestTimeMs)
        : VideoPreviewService().requestPreview(filePath, requestTimeMs);
    future.then((data) {
      if (mounted &&
          _isDraggingProgress &&
          (expectedTimeMs == null ||
              (_dragProgressValue.toInt() - expectedTimeMs).abs() <= 1) &&
          requestSerial == _previewRequestSerial &&
          (data != null)) {
        setState(() {
          _previewImage = data;
        });
      }
    });
  }

  @override
  void initState() {
    super.initState();
    if (Platform.isAndroid) {
      VolumeController.instance.showSystemUI = false;
    }
    _warmSeekPreviewMetadata();
    _initVolumeBrightness();
    _rebuildSubtitleIndex();
    // Auto request focus to enable keyboard listening
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        (widget.focusNode ?? _focusNode).requestFocus();
      }
    });
    // Start auto-hide timer since controls are initially visible
    _startAutoHideTimer();
  }

  @override
  void didUpdateWidget(VideoControlsOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.subtitles != widget.subtitles) {
      _rebuildSubtitleIndex();
    }
    if (oldWidget.controller.dataSource != widget.controller.dataSource) {
      VideoPreviewService().markInteractionEnded();
      _cancelSeekPreviewRefine();
      _resetSeekPreviewRequestState();
      _previewRequestSerial++;
      _previewImage = null;
      _warmSeekPreviewMetadata();
    }
  }

  @override
  void dispose() {
    VideoPreviewService().markInteractionEnded();
    _focusNode.dispose();
    _keyboardLongPressTimer?.cancel();
    _singleTapTimer?.cancel();
    _seekResetTimer?.cancel();
    _seekDebounceTimer?.cancel();
    _cancelSeekPreviewRefine();
    _resetSeekPreviewRequestState();
    _doubleTapFeedbackHideTimer?.cancel();
    _doubleTapFeedbackDismissTimer?.cancel();
    _autoHideTimer?.cancel();
    super.dispose();
  }

  // Start or reset the auto-hide timer
  void _startAutoHideTimer() {
    _autoHideTimer?.cancel();
    _autoHideTimer = Timer(_autoHideDelay, () {
      if (mounted && _showControls && !widget.isLocked) {
        setState(() {
          _showControls = false;
        });
      }
    });
  }

  // Cancel the auto-hide timer
  void _cancelAutoHideTimer() {
    _autoHideTimer?.cancel();
    _autoHideTimer = null;
  }

  // Desktop: Show controls when mouse moves over the player area
  void _onMouseHover(PointerHoverEvent event) {
    if (!_showControls && !widget.isLocked) {
      setState(() {
        _showControls = true;
      });
      _startAutoHideTimer();
    } else if (_showControls) {
      // Reset the auto-hide timer on continued mouse movement
      _startAutoHideTimer();
    }
  }

  bool get _supportsDesktopPlayerShortcuts {
    return !kIsWeb &&
        !widget.isPreviewMode &&
        (Platform.isWindows || Platform.isMacOS || Platform.isLinux);
  }

  bool _isTextInputFocused() {
    final BuildContext? focusContext =
        FocusManager.instance.primaryFocus?.context;
    if (focusContext == null) return false;
    return focusContext.widget is EditableText ||
        focusContext.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  String _tooltipWithShortcut(
    String label,
    DesktopPlayerShortcutAction action,
  ) {
    if (!_supportsDesktopPlayerShortcuts) return label;
    return DesktopPlayerShortcuts.buildTooltip(label, action);
  }

  void _dispatchDesktopShortcut(DesktopPlayerShortcutAction action) {
    switch (action) {
      case DesktopPlayerShortcutAction.back:
        _startAutoHideTimer();
        widget.onBackPressed();
        return;
      case DesktopPlayerShortcutAction.playPause:
        if (!widget.controller.value.isInitialized) return;
        _startAutoHideTimer();
        widget.onTogglePlay();
        return;
      case DesktopPlayerShortcutAction.seekBackward:
        if (!widget.controller.value.isInitialized) return;
        _startAutoHideTimer();
        final Duration target =
            widget.controller.value.position -
            Duration(seconds: widget.doubleTapSeekSeconds);
        _seekTo(target < Duration.zero ? Duration.zero : target);
        return;
      case DesktopPlayerShortcutAction.seekForward:
        if (!widget.controller.value.isInitialized) return;
        _startAutoHideTimer();
        final Duration target =
            widget.controller.value.position +
            Duration(seconds: widget.doubleTapSeekSeconds);
        final Duration duration = widget.controller.value.duration;
        _seekTo(target > duration ? duration : target);
        return;
      case DesktopPlayerShortcutAction.openSettings:
        if (widget.onOpenSettings == null) return;
        _startAutoHideTimer();
        widget.onOpenSettings!();
        return;
      case DesktopPlayerShortcutAction.openSubtitleLibrary:
        if (widget.onOpenSubtitleManager == null) return;
        _startAutoHideTimer();
        widget.onOpenSubtitleManager!();
        return;
      case DesktopPlayerShortcutAction.openSubtitleEditor:
        if (widget.onOpenSubtitleEditor == null ||
            !widget.showSubtitleEditorButton) {
          return;
        }
        _startAutoHideTimer();
        widget.onOpenSubtitleEditor!();
        return;
      case DesktopPlayerShortcutAction.openVideoCompose:
        if (widget.onOpenVideoCompose == null) return;
        _startAutoHideTimer();
        widget.onOpenVideoCompose!();
        return;
      case DesktopPlayerShortcutAction.openSubtitleStyle:
        if (widget.onToggleFloatingSubtitleSettings == null) return;
        _startAutoHideTimer();
        widget.onToggleFloatingSubtitleSettings!();
        return;
      case DesktopPlayerShortcutAction.moveSubtitles:
        _startAutoHideTimer();
        widget.onMoveSubtitles();
        return;
      case DesktopPlayerShortcutAction.toggleSubtitleSidebar:
        if (widget.onToggleSidebar == null) return;
        _startAutoHideTimer();
        widget.onToggleSidebar!();
        return;
      case DesktopPlayerShortcutAction.toggleFullScreen:
        if (widget.onToggleFullScreen == null) return;
        _startAutoHideTimer();
        widget.onToggleFullScreen!();
        return;
      case DesktopPlayerShortcutAction.openAspectRatio:
        if (widget.onOpenAspectRatio == null ||
            widget.aspectRatioLabel == null) {
          return;
        }
        _startAutoHideTimer();
        widget.onOpenAspectRatio!();
        return;
      case DesktopPlayerShortcutAction.toggleEpisodePicker:
        if (widget.onToggleEpisodePicker == null) return;
        _startAutoHideTimer();
        widget.onToggleEpisodePicker!();
        return;
      case DesktopPlayerShortcutAction.previousEpisode:
        if (widget.onPlayPrevious == null || !widget.hasPrevious) return;
        _startAutoHideTimer();
        widget.onPlayPrevious!();
        return;
      case DesktopPlayerShortcutAction.nextEpisode:
        if (widget.onPlayNext == null || !widget.hasNext) return;
        _startAutoHideTimer();
        widget.onPlayNext!();
        return;
      case DesktopPlayerShortcutAction.toggleSubtitles:
        _startAutoHideTimer();
        widget.onToggleSubtitles();
        return;
      case DesktopPlayerShortcutAction.toggleMute:
        final playbackService = Provider.of<MediaPlaybackService>(
          context,
          listen: false,
        );
        _startAutoHideTimer();
        unawaited(playbackService.toggleMute());
        return;
    }
  }

  // Handle Key Events
  KeyEventResult handleKeyEvent(FocusNode node, KeyEvent event) {
    // If we don't have focus, we shouldn't handle keys here (let them bubble)
    // BUT for video player, we want to capture keys even if sidebar is clicked.
    // The issue is that clicking the sidebar moves focus to the sidebar or its items.

    if (widget.isLocked) return KeyEventResult.ignored;

    final key = event.logicalKey;
    final bool isLongPressKey =
        key == LogicalKeyboardKey.space ||
        key == LogicalKeyboardKey.arrowRight ||
        key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.escape;
    final bool hasBlockingModifier =
        HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isAltPressed ||
        HardwareKeyboard.instance.isMetaPressed;
    final DesktopPlayerShortcutAction? shortcutAction =
        hasBlockingModifier || !_supportsDesktopPlayerShortcuts
        ? null
        : DesktopPlayerShortcuts.matchAction(key);

    if (!isLongPressKey && shortcutAction == null) {
      return KeyEventResult.ignored;
    }

    // If focus is in a TextField, don't intercept player shortcuts.
    if (_isTextInputFocused() || hasBlockingModifier) {
      return KeyEventResult.ignored;
    }

    if (event is KeyRepeatEvent) {
      return KeyEventResult.handled;
    }

    if (event is KeyDownEvent) {
      if (!isLongPressKey && shortcutAction != null) {
        _dispatchDesktopShortcut(shortcutAction);
      } else if (key == LogicalKeyboardKey.space && !_isSpacePressed) {
        _isSpacePressed = true;
        _wasPlayingBeforeLongPress = widget.controller.value.isPlaying;
        _startKeyboardLongPressTimer(() {
          _startZoneLongPress(2.0);
        });
      } else if (key == LogicalKeyboardKey.arrowRight &&
          !_isRightArrowPressed) {
        _isRightArrowPressed = true;
        _startKeyboardLongPressTimer(() {
          // Right Arrow Long Press -> Speed Up
          _startZoneLongPress(2.0);
        });
      } else if (key == LogicalKeyboardKey.arrowLeft && !_isLeftArrowPressed) {
        _isLeftArrowPressed = true;
        // Left Arrow Long Press -> Continuous Seek Back?
        // User didn't specify special action for Left Long Press, assuming standard or ignore.
        // For now, we only handle Tap for seek.
      } else if (key == LogicalKeyboardKey.escape && !_isEscPressed) {
        _isEscPressed = true;
        _startKeyboardLongPressTimer(() {
          // ESC Long Press -> Exit Fullscreen if in fullscreen
          final settings = Provider.of<SettingsService>(context, listen: false);
          if (settings.isFullScreen) {
            widget.onToggleFullScreen?.call();
          }
        });
      }
      return KeyEventResult.handled;
    } else if (event is KeyUpEvent) {
      if (key == LogicalKeyboardKey.space) {
        _isSpacePressed = false;
        _handleKeyRelease(() {
          // Space Tap -> Toggle Play
          widget.onTogglePlay();
        });
      } else if (key == LogicalKeyboardKey.escape) {
        _isEscPressed = false;
        _handleKeyRelease(() {
          // ESC Tap -> Back
          widget.onBackPressed();
        });
      } else if (key == LogicalKeyboardKey.arrowRight) {
        _isRightArrowPressed = false;
        _handleKeyRelease(() {
          if (Platform.isWindows && !widget.isPreviewMode) {
            final playbackService = Provider.of<MediaPlaybackService>(
              context,
              listen: false,
            );
            final settings = Provider.of<SettingsService>(
              context,
              listen: false,
            );
            playbackService.handleExternalDoubleTapSeek(
              isLeft: false,
              doubleTapSeekSeconds: settings.doubleTapSeekSeconds,
              enableDoubleTapSubtitleSeek: settings.enableDoubleTapSubtitleSeek,
              subtitleOffset: settings.subtitleOffset,
            );
          } else {
            _seekRelative(widget.doubleTapSeekSeconds);
          }
        });
      } else if (key == LogicalKeyboardKey.arrowLeft) {
        _isLeftArrowPressed = false;
        // Left Arrow Tap -> Rewind
        // Left Long press doesn't have a timer start, so it will always be treated as tap here
        _handleKeyRelease(() {
          if (Platform.isWindows && !widget.isPreviewMode) {
            final playbackService = Provider.of<MediaPlaybackService>(
              context,
              listen: false,
            );
            final settings = Provider.of<SettingsService>(
              context,
              listen: false,
            );
            playbackService.handleExternalDoubleTapSeek(
              isLeft: true,
              doubleTapSeekSeconds: settings.doubleTapSeekSeconds,
              enableDoubleTapSubtitleSeek: settings.enableDoubleTapSubtitleSeek,
              subtitleOffset: settings.subtitleOffset,
            );
          } else {
            _seekRelative(-widget.doubleTapSeekSeconds);
          }
        });
      }
      return KeyEventResult.handled;
    }

    // Handle repeat events for target keys to prevent bubbling
    return KeyEventResult.handled;
  }

  void _startKeyboardLongPressTimer(VoidCallback onLongPress) {
    _keyboardLongPressTimer?.cancel();
    _isKeyboardLongPressing = false;
    // 200ms threshold for long press
    _keyboardLongPressTimer = Timer(const Duration(milliseconds: 200), () {
      if (mounted) {
        setState(() {
          _isKeyboardLongPressing = true;
        });
        onLongPress();
      }
    });
  }

  void _handleKeyRelease(VoidCallback onTap) {
    _keyboardLongPressTimer?.cancel();

    if (_isKeyboardLongPressing) {
      // Was long pressing, now stop
      _endZoneLongPress();
      // 如果长按前是播放状态，确保长按结束后继续播放，不触发 tap 的切换逻辑
      if (_wasPlayingBeforeLongPress && !widget.controller.value.isPlaying) {
        widget.onTogglePlay();
      }
      setState(() {
        _isKeyboardLongPressing = false;
      });
    } else {
      // Was a tap
      onTap();
    }
  }

  // Helper to reuse Zone Long Press Logic
  void _startZoneLongPress(double speedMultiplier) {
    widget.onLongPressStart();
  }

  void _endZoneLongPress() {
    widget.onLongPressEnd();
  }

  // Accumulated Seek Logic
  Timer? _seekResetTimer;
  int _subtitleSeekAccumulator = 0;
  Duration? _initialSeekPosition;
  Timer? _seekDebounceTimer;
  final List<int> _subtitleStartMs = <int>[];

  // -- initState and dispose moved to top of file --

  bool get _shouldBlockPrimaryGestures {
    return widget.suppressPrimaryGestures;
  }

  Future<void> _initVolumeBrightness() async {
    try {
      if (Platform.isAndroid || Platform.isIOS) {
        _currentBrightness = await ScreenBrightness().application;
      } else {
        _currentBrightness = 1.0;
      }
      _currentVolume = widget.controller.value.volume;
    } catch (e) {
      debugPrint("Error initializing controls: $e");
    }
  }

  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, "0");
    String twoDigitMinutes = twoDigits(duration.inMinutes.remainder(60));
    String twoDigitSeconds = twoDigits(duration.inSeconds.remainder(60));
    if (duration.inHours > 0) {
      return "${twoDigits(duration.inHours)}:$twoDigitMinutes:$twoDigitSeconds";
    }
    return "$twoDigitMinutes:$twoDigitSeconds";
  }

  void _rebuildSubtitleIndex() {
    _subtitleStartMs
      ..clear()
      ..addAll(widget.subtitles.map((e) => e.startTime.inMilliseconds));
  }

  void _ensureSubtitleIndexUpToDate() {
    if (widget.subtitles.isEmpty) {
      if (_subtitleStartMs.isNotEmpty) _subtitleStartMs.clear();
      return;
    }

    final int first = widget.subtitles.first.startTime.inMilliseconds;
    final int last = widget.subtitles.last.startTime.inMilliseconds;

    if (_subtitleStartMs.length != widget.subtitles.length) {
      _rebuildSubtitleIndex();
      return;
    }

    if (_subtitleStartMs.isNotEmpty &&
        (_subtitleStartMs.first != first || _subtitleStartMs.last != last)) {
      _rebuildSubtitleIndex();
    }
  }

  int _binarySearchLastStartLE(int posMs) {
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
    return ans;
  }

  int _binarySearchFirstStartGT(int posMs) {
    int low = 0;
    int high = _subtitleStartMs.length - 1;
    int ans = _subtitleStartMs.length;
    while (low <= high) {
      final int mid = (low + high) >> 1;
      if (_subtitleStartMs[mid] > posMs) {
        ans = mid;
        high = mid - 1;
      } else {
        low = mid + 1;
      }
    }
    return ans;
  }

  void _cancelDoubleTapFeedbackTimers() {
    _doubleTapFeedbackHideTimer?.cancel();
    _doubleTapFeedbackDismissTimer?.cancel();
  }

  void _triggerDoubleTapFeedback(Offset localPosition) {
    _cancelDoubleTapFeedbackTimers();
    setState(() {
      _showDoubleTapFeedback = true;
      _isDoubleTapFeedbackFadingOut = false;
      _tapPosition = localPosition;
      _doubleTapFeedbackPulse++;
    });

    _doubleTapFeedbackHideTimer = Timer(_doubleTapFeedbackVisibleDuration, () {
      if (!mounted || _isGestureSeeking || widget.isLongPressing) return;
      setState(() {
        _isDoubleTapFeedbackFadingOut = true;
      });
      _doubleTapFeedbackDismissTimer = Timer(
        _doubleTapFeedbackFadeOutDuration,
        () {
          if (!mounted) return;
          setState(() {
            _showDoubleTapFeedback = false;
          });
        },
      );
    });
  }

  double _relativePlayerUnit(
    double width,
    double height, {
    required double fraction,
    required double min,
    required double max,
  }) {
    final double base = math.min(width, height);
    return (base * fraction).clamp(min, max).toDouble();
  }

  int _findCurrentSubtitleIndexByPositionMs(int posMs) {
    if (widget.subtitles.isEmpty) return -1;
    _ensureSubtitleIndexUpToDate();
    final int candidate = _binarySearchLastStartLE(posMs);
    if (candidate < 0 || candidate >= widget.subtitles.length) return -1;
    final int endMs = widget.subtitles[candidate].endTime.inMilliseconds;
    if (posMs <= endMs) return candidate;
    return -1;
  }

  void _seekTo(Duration position) {
    final handler = widget.onSeekTo;
    if (handler != null) {
      handler(position);
      return;
    }
    widget.controller.seekTo(position);
  }

  // Helper for keyboard seek
  void _seekRelative(int seconds) {
    if (!widget.controller.value.isInitialized) return;
    final newPos =
        widget.controller.value.position + Duration(seconds: seconds);
    final total = widget.controller.value.duration;
    final clamped = newPos < Duration.zero
        ? Duration.zero
        : (newPos > total ? total : newPos);
    _seekTo(clamped);

    // Show feedback (optional, reusing gesture UI or similar)
    // For now just seek
  }

  // Helper for determining cancel area
  bool _isInCancelArea(Offset globalPosition) {
    if (!mounted) return false;
    final RenderBox? box = context.findRenderObject() as RenderBox?;
    if (box == null) return false;
    final localOffset = box.globalToLocal(globalPosition);
    // Use absolute top area of the player (25%) for cancel zone
    return localOffset.dy < box.size.height * 0.25;
  }

  // Horizontal Drag for Seeking (Direct Slide)
  Offset? _dragStartPosition;

  void _onHorizontalDragStart(DragStartDetails details, double width) {
    if (_shouldBlockPrimaryGestures) return;
    if (!widget.controller.value.isInitialized || widget.isLocked) return;
    // 互斥：如果正在长按加速（或显示双击反馈），则不响应滑动
    if (widget.isLongPressing) return;

    // Ignore if starting from edges (to avoid conflict with system gestures or volume/brightness)
    // But Volume/Brightness is VerticalDrag, so they shouldn't conflict if direction is clear.
    // However, user might want volume/brightness if they start near edge.
    // VerticalDragGestureRecognizer and HorizontalDragGestureRecognizer compete.
    // We'll let the arena decide.

    // Ignore bottom area (progress bar)
    final screenHeight = MediaQuery.of(context).size.height;
    if (details.globalPosition.dy > screenHeight * 0.85) return;

    _dragStartPosition = details.globalPosition;

    setState(() {
      _showControlsBeforeGestureSeek = _showControls;
      _isGestureSeeking = true;
      _gestureTargetTime = widget.controller.value.position;
      _isGestureCanceling = false;
    });

    // Keep the pre-gesture controls visibility stable during gesture seek.
    _cancelAutoHideTimer();
  }

  void _onHorizontalDragUpdate(
    DragUpdateDetails details,
    BuildContext context,
  ) {
    if (_shouldBlockPrimaryGestures) return;
    if (!_isGestureSeeking || widget.isLocked || _dragStartPosition == null) {
      return;
    }
    if (widget.isLongPressing) return; // Double check

    final double offsetX = details.globalPosition.dx - _dragStartPosition!.dx;
    final int secondsToAdd = (offsetX / 10).round();

    final Duration newTime =
        widget.controller.value.position + Duration(seconds: secondsToAdd);

    final RenderBox box = context.findRenderObject() as RenderBox;
    final localOffset = box.globalToLocal(details.globalPosition);
    // Use absolute top area of the player (25%) for cancel zone
    final bool isInCancelArea = localOffset.dy < box.size.height * 0.25;

    setState(() {
      final totalDuration = widget.controller.value.duration;
      final clamped = newTime < Duration.zero
          ? Duration.zero
          : (newTime > totalDuration ? totalDuration : newTime);
      _gestureTargetTime = clamped;

      final diff =
          _gestureTargetTime.inSeconds -
          widget.controller.value.position.inSeconds;
      _gestureDiffText = diff > 0 ? "+${diff}s" : "${diff}s";

      _isGestureCanceling = isInCancelArea;
    });
  }

  void _onHorizontalDragEnd(DragEndDetails details) {
    if (_shouldBlockPrimaryGestures) return;
    if (!_isGestureSeeking) return;

    if (!_isGestureCanceling && !widget.isLocked) {
      _seekTo(_gestureTargetTime);
    }

    setState(() {
      _isGestureSeeking = false;
      _isGestureCanceling = false;
      _showControls = _showControlsBeforeGestureSeek;
      _showControlsBeforeGestureSeek = false;
      _dragStartPosition = null;
    });

    if (_showControls) {
      _startAutoHideTimer();
    } else {
      _cancelAutoHideTimer();
    }
  }

  void _handleDoubleTap(Offset localPosition, double width) {
    if (_shouldBlockPrimaryGestures) return;
    if (widget.isLocked) return;

    final dx = localPosition.dx;
    final isLeft = dx < width * 0.2; // 20%
    final isRight = dx > width * 0.8; // 20%
    final settings = Provider.of<SettingsService>(context, listen: false);
    final Duration subtitleOffset = settings.subtitleOffset;

    // Center Double Tap: Play/Pause
    if (!isLeft && !isRight) {
      _cancelDoubleTapFeedbackTimers();
      widget.onTogglePlay();
      // Hide controls immediately after double-tap play/pause
      setState(() {
        _showControls = false;
        _showDoubleTapFeedback = false;
        _isDoubleTapFeedbackFadingOut = false;
      });
      return;
    }

    // Side Double Tap: Seek
    final int seconds = widget.doubleTapSeekSeconds;
    final currentPos = widget.controller.value.position;
    final duration = widget.controller.value.duration;

    Duration target = Duration.zero;

    // Subtitle Seek Logic with Accumulation
    if (!widget.isPreviewMode &&
        widget.enableDoubleTapSubtitleSeek &&
        widget.subtitles.isNotEmpty) {
      _ensureSubtitleIndexUpToDate();
      // Reset or Init Accumulator
      if (_seekResetTimer?.isActive ?? false) {
        _seekResetTimer?.cancel();
      } else {
        // New seek sequence started
        _subtitleSeekAccumulator = 0;
        _initialSeekPosition = currentPos - subtitleOffset;
      }

      // Determine direction
      final bool isSeekLeft = localPosition.dx < width / 2;

      if (isSeekLeft) {
        _subtitleSeekAccumulator--;
      } else {
        _subtitleSeekAccumulator++;
      }

      // Calculate Target based on Initial Position + Accumulator
      // Find the starting index corresponding to _initialSeekPosition
      // Logic to resolve Accumulator to Target Index
      int targetIndex = -1;
      String feedback = "";

      // Re-evaluate base index more robustly
      // We want to find "Current/Next" boundary
      final int initialPosMs = _initialSeekPosition!.inMilliseconds;
      int nextSubIndex = _binarySearchFirstStartGT(initialPosMs);
      if (nextSubIndex < 0) nextSubIndex = 0;
      if (nextSubIndex > widget.subtitles.length) {
        nextSubIndex = widget.subtitles.length;
      }

      int currentSubIndex = _findCurrentSubtitleIndexByPositionMs(initialPosMs);

      // Determine "Pivot" index from which we add accumulator
      // Case A: Inside Subtitle X (currentSubIndex = X)
      //   Tap Left (-1):
      //      If > 500ms in: Go to Start of X.
      //      If < 500ms in: Go to Start of X-1.
      //   Tap Right (+1): Go to Start of X+1.

      // Case B: In Gap between X and X+1
      //   Tap Left (-1): Go to Start of X.
      //   Tap Right (+1): Go to Start of X+1.

      int pivotIndex;
      bool isAtStartOfSub = false;

      if (currentSubIndex != -1) {
        pivotIndex = currentSubIndex;
        if (initialPosMs <
            widget.subtitles[currentSubIndex].startTime.inMilliseconds + 500) {
          isAtStartOfSub = true;
        }
      } else {
        // Gap: prev is nextSubIndex - 1
        pivotIndex = nextSubIndex - 1; // Could be -1
      }

      // Calculate Jump
      // If _subtitleSeekAccumulator is negative (Left)
      if (_subtitleSeekAccumulator < 0) {
        // Count jumps backwards
        int jumps = _subtitleSeekAccumulator.abs();

        if (currentSubIndex != -1 && !isAtStartOfSub) {
          // First jump goes to start of current
          jumps--;
          targetIndex = currentSubIndex;
        } else {
          // First jump goes to start of pivot (which is prev sub)
          targetIndex = pivotIndex;
        }

        // Apply remaining jumps
        targetIndex -= jumps;

        feedback =
            "上一句${_subtitleSeekAccumulator < -1 ? " x${_subtitleSeekAccumulator.abs()}" : ""}";
      } else {
        // Positive (Right)
        // Pivot is usually "Current" or "Prev". Next is pivot + 1?
        // If inside X: Next is X+1.
        // If gap X...X+1: Next is X+1.

        // So if we are at pivotIndex, next start is pivotIndex + 1.
        targetIndex = pivotIndex + _subtitleSeekAccumulator;

        feedback =
            "下一句${_subtitleSeekAccumulator > 1 ? " x$_subtitleSeekAccumulator" : ""}";
      }

      // Clamping
      if (targetIndex < 0) {
        target = Duration.zero;
        feedback = "开头";
      } else if (targetIndex >= widget.subtitles.length) {
        target = duration;
        feedback = "结尾";
      } else {
        target = widget.subtitles[targetIndex].startTime + subtitleOffset;
      }

      _doubleTapFeedbackText = feedback;

      // Start Reset Timer (2 seconds to chain commands)
      _seekResetTimer = Timer(_doubleTapChainResetDuration, () {
        _subtitleSeekAccumulator = 0;
        _initialSeekPosition = null;
      });
    } else {
      // Standard Seek Logic
      if (localPosition.dx < width / 2) {
        target = currentPos - Duration(seconds: seconds);
        _doubleTapFeedbackText = "-${seconds}s";
      } else {
        target = currentPos + Duration(seconds: seconds);
        _doubleTapFeedbackText = "+${seconds}s";
      }
    }

    if (target < Duration.zero) target = Duration.zero;
    if (target > duration) target = duration;

    // Debounce/Throttle Seek to prevent UI lag
    _seekDebounceTimer?.cancel();
    _seekDebounceTimer = Timer(const Duration(milliseconds: 30), () {
      _seekTo(target);
    });

    _triggerDoubleTapFeedback(localPosition);
  }

  void _handleZoneLongPressStart(Offset localPosition, double width) {
    if (_shouldBlockPrimaryGestures) return;
    if (widget.isLocked) return;

    // Allow long press anywhere on the screen
    // final dx = localPosition.dx;
    // final isLeft = dx < width * 0.2;
    // final isRight = dx > width * 0.8;

    // if (!isLeft && !isRight) return;

    setState(() {
      _tapPosition = localPosition;
      _showDoubleTapFeedback = false;
      _isDoubleTapFeedbackFadingOut = false;
      _cancelDoubleTapFeedbackTimers();

      // 强制结束任何可能存在的滑动状态
      if (_isGestureSeeking) {
        _isGestureSeeking = false;
        _isGestureCanceling = false;
        _showControlsBeforeGestureSeek = false;
        _dragStartPosition = null;
      }
      _isAdjustingBrightness = false;
      _isAdjustingVolume = false;
    });

    widget.onLongPressStart();
  }

  void _handleZoneLongPressEnd(LongPressEndDetails details) {
    widget.onLongPressEnd();
  }

  Widget _buildDoubleTapFeedbackOverlay(double width, double height) {
    final bool isLeftSide = (_tapPosition?.dx ?? 0) < width / 2;
    final double shortSide = math.min(width, height);
    final double edgeInset = (width * 0.028).clamp(8.0, 20.0).toDouble();
    final double textSize = _relativePlayerUnit(
      width,
      height,
      fraction: 0.022,
      min: 10,
      max: 14,
    );
    final double circleSize = math
        .max(shortSide * 0.18, textSize * 4.8)
        .clamp(72.0, 112.0)
        .toDouble();
    final double horizontalPadding = (circleSize * 0.18)
        .clamp(10.0, 18.0)
        .toDouble();

    return Positioned(
      top: (height - circleSize) / 2,
      left: isLeftSide ? edgeInset : null,
      right: isLeftSide ? null : edgeInset,
      child: IgnorePointer(
        child: AnimatedOpacity(
          duration: _doubleTapFeedbackFadeOutDuration,
          curve: Curves.easeOutCubic,
          opacity: _isDoubleTapFeedbackFadingOut ? 0.0 : 1.0,
          child: AnimatedScale(
            duration: _doubleTapFeedbackFadeOutDuration,
            curve: Curves.easeOutCubic,
            scale: _isDoubleTapFeedbackFadingOut ? 0.94 : 1.0,
            child: TweenAnimationBuilder<double>(
              key: ValueKey(
                '${isLeftSide ? 'left' : 'right'}-$_doubleTapFeedbackPulse',
              ),
              tween: Tween<double>(begin: 0.92, end: 1.0),
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              builder: (context, progress, child) {
                final double slideDistance =
                    circleSize * 0.08 * (1.0 - progress);
                return Transform.translate(
                  offset: Offset(
                    isLeftSide ? -slideDistance : slideDistance,
                    0,
                  ),
                  child: Transform.scale(scale: progress, child: child),
                );
              },
              child: Container(
                width: circleSize,
                height: circleSize,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.grey.shade700.withValues(alpha: 0.9),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.18),
                      blurRadius: 16,
                      spreadRadius: 0.5,
                    ),
                  ],
                ),
                child: Center(
                  child: Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: horizontalPadding,
                    ),
                    child: Text(
                      _doubleTapFeedbackText,
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: textSize,
                        fontWeight: FontWeight.w700,
                        height: 1.12,
                        letterSpacing: 0.1,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  // Vertical Drag for Volume/Brightness
  void _onVerticalDragStart(DragStartDetails details, double width) async {
    if (_shouldBlockPrimaryGestures) return;
    if (widget.isLocked) return; // Prevent global drag if locked
    if (widget.isLongPressing) return; // 互斥

    final dx = details.localPosition.dx;
    final bool isWindows = !kIsWeb && Platform.isWindows;

    if (dx < width * 0.2) {
      if (Platform.isAndroid || Platform.isIOS) {
        try {
          _startDragValue = await ScreenBrightness().application;
        } catch (_) {
          _startDragValue = 0.5;
        }
        setState(() {
          _isAdjustingBrightness = true;
          _currentBrightness = _startDragValue;
        });
      } else if (isWindows) {
        _startDragValue = _currentBrightness;
        setState(() {
          _isAdjustingBrightness = true;
          _currentBrightness = _startDragValue;
        });
      }
    } else if (dx > width * 0.8) {
      if (Platform.isAndroid || Platform.isIOS) {
        try {
          _startDragValue = await VolumeController.instance.getVolume();
        } catch (_) {
          _startDragValue = 0.5;
        }
        setState(() {
          _isAdjustingVolume = true;
          _currentVolume = _startDragValue;
        });
      } else if (isWindows) {
        _startDragValue = widget.controller.value.volume;
        setState(() {
          _isAdjustingVolume = true;
          _currentVolume = _startDragValue;
        });
      }
    }

    // Reset auto-hide timer during gesture
    if (_isAdjustingBrightness || _isAdjustingVolume) {
      _startAutoHideTimer();
    }
  }

  void _onVerticalDragUpdate(DragUpdateDetails details, double height) {
    if (_shouldBlockPrimaryGestures) return;
    if (widget.isLocked) return;
    if (widget.isLongPressing) return; // 互斥
    if (!_isAdjustingBrightness && !_isAdjustingVolume) return;

    // Delta Y is positive when dragging down, negative when dragging up.
    // We want dragging UP to increase value.
    final double delta =
        -details.primaryDelta! / height; // Sensitivity depends on height
    // Multiplier for sensitivity
    final double change = delta * 1.5;
    final bool isWindows = !kIsWeb && Platform.isWindows;

    setState(() {
      if (_isAdjustingBrightness && (Platform.isAndroid || Platform.isIOS)) {
        _currentBrightness = (_currentBrightness + change).clamp(0.0, 1.0);
        ScreenBrightness().setApplicationScreenBrightness(_currentBrightness);
      } else if (_isAdjustingBrightness && isWindows) {
        _currentBrightness = (_currentBrightness + change).clamp(0.0, 1.0);
      } else if (_isAdjustingVolume && (Platform.isAndroid || Platform.isIOS)) {
        // System Volume Control (Gesture)
        _currentVolume = (_currentVolume + change).clamp(0.0, 1.0);
        VolumeController.instance.setVolume(_currentVolume);
        // Do NOT update widget.controller.setVolume (Software Gain)
        // Do NOT update _sliderVolume
      } else if (_isAdjustingVolume && isWindows) {
        _currentVolume = (_currentVolume + change).clamp(0.0, 1.0);
        final playbackService = Provider.of<MediaPlaybackService>(
          context,
          listen: false,
        );
        unawaited(playbackService.setVolume(_currentVolume));
      }
    });
  }

  void _onVerticalDragEnd(DragEndDetails details) {
    if (_shouldBlockPrimaryGestures) return;
    setState(() {
      _isAdjustingBrightness = false;
      _isAdjustingVolume = false;
      _showControls = false; // Auto hide controls after adjustment
    });

    // Cancel auto-hide timer since controls are hidden
    _cancelAutoHideTimer();
  }

  void _handleSmartTap(double width) {
    if (_shouldBlockPrimaryGestures) return;
    final now = DateTime.now();
    bool isDoubleTap = false;

    // Re-request focus on any tap within the player area to restore keyboard shortcuts
    if (mounted) (widget.focusNode ?? _focusNode).requestFocus();

    if (_lastTapTime != null &&
        now.difference(_lastTapTime!) < const Duration(milliseconds: 300)) {
      // Check distance to confirm it's a double tap and not two separate taps far apart
      if (_tapPosition != null &&
          _lastTapDownPosition != null &&
          (_tapPosition! - _lastTapDownPosition!).distance < 100.0) {
        isDoubleTap = true;
      }
    }

    if (isDoubleTap) {
      _singleTapTimer?.cancel(); // Cancel any pending single tap action
      if (_tapPosition != null) {
        _handleDoubleTap(_tapPosition!, width);
      }
      _lastTapTime = null;
      _lastTapDownPosition = null;
    } else {
      // Single Tap Candidate
      // Re-request focus on tap to ensure keyboard shortcuts work
      if (mounted) _focusNode.requestFocus();

      _lastTapTime = now;
      _lastTapDownPosition = _tapPosition;

      // Always delay single tap action to wait for potential double tap (Full Screen Sensitivity)
      _singleTapTimer?.cancel();
      _singleTapTimer = Timer(const Duration(milliseconds: 190), () {
        if (mounted) {
          // Clear selection when tapping anywhere in the control overlay
          widget.onClearSelection?.call();

          setState(() {
            _showControls = !_showControls;
            // _showVolumeSlider = false; // Removed
          });

          // Start auto-hide timer if controls are now shown
          if (_showControls) {
            _startAutoHideTimer();
          } else {
            _cancelAutoHideTimer();
          }
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    // Use listen: false to avoid rebuilding the entire overlay on every
    // position update (every 300ms during playback). Only the mute icon
    // needs reactive updates, handled by Selector below.
    final playbackService = Provider.of<MediaPlaybackService>(context, listen: false);
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final height = constraints.maxHeight;
        final isSmallScreen = width < 600;

        // Define sizes based on screen size
        final double iconSize = isSmallScreen ? 18 : 24;
        final double bigIconSize = isSmallScreen ? 28 : 32;
        final double lockIconSize = isSmallScreen ? 20 : 32;
        final double topActionIconSize = widget.compactTopRightButtons
            ? (isSmallScreen ? 14 : 16)
            : iconSize;
        final EdgeInsets topActionPadding = widget.compactTopRightButtons
            ? EdgeInsets.zero
            : const EdgeInsets.all(8);
        final BoxConstraints topActionConstraints =
            widget.compactTopRightButtons
            ? const BoxConstraints(minWidth: 24, minHeight: 24)
            : const BoxConstraints(minWidth: 40, minHeight: 40);
        final EdgeInsets aspectChipPadding = widget.compactTopRightButtons
            ? const EdgeInsets.symmetric(horizontal: 7, vertical: 4)
            : const EdgeInsets.symmetric(horizontal: 10, vertical: 6);
        final double aspectChipIconSize = widget.compactTopRightButtons
            ? 14
            : 16;
        final double aspectChipTextSize = widget.compactTopRightButtons
            ? 11
            : 12;
        final double aspectChipSpacing = widget.compactTopRightButtons ? 4 : 6;
        final double aspectChipRadius = widget.compactTopRightButtons ? 16 : 20;
        final double resetButtonIconSize = isSmallScreen ? 14 : 16;
        final double resetButtonFontSize = isSmallScreen ? 11 : 12;
        final EdgeInsets resetButtonPadding = EdgeInsets.symmetric(
          horizontal: isSmallScreen ? 10 : 12,
          vertical: isSmallScreen ? 4 : 6,
        );
        final double resetButtonRowHeight = isSmallScreen ? 36 : 40;

        final double topBarPadding = isSmallScreen ? 4 : 8;
        final double bottomBarPadding = isSmallScreen ? 8 : 16;
        final double bottomBarVerticalPadding = isSmallScreen ? 8 : 24;
        final settings = Provider.of<SettingsService>(context);
        final bool isLeftHandedMode = settings.isLeftHandedMode;
        final Alignment timeAlignment = isLeftHandedMode
            ? Alignment.centerRight
            : Alignment.centerLeft;
        final Alignment toolsAlignment = isLeftHandedMode
            ? Alignment.centerLeft
            : Alignment.centerRight;
        final bool isWindows = !kIsWeb && Platform.isWindows;
        final bool showLockButton =
            !widget.isPreviewMode &&
            (kIsWeb || !(Platform.isWindows || Platform.isMacOS));
        final bool hideControlsForGestureSeek =
            _isGestureSeeking && !_showControlsBeforeGestureSeek;
        final double brightnessOverlayAlpha = (1.0 - _currentBrightness)
            .clamp(0.0, 1.0)
            .toDouble();
        final String mediaTitle = widget.mediaTitle.trim();
        final bool isDesktop = !kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux);
        final List<Widget> topLeading = [
          if (isDesktop)
            IconButton(
              icon: const Icon(Icons.close, color: Colors.white),
              tooltip: _tooltipWithShortcut(
                "退出播放",
                DesktopPlayerShortcutAction.back,
              ),
              onPressed: () {
                _startAutoHideTimer();
                (widget.onExitPressed ?? widget.onBackPressed)();
              },
              iconSize: iconSize,
            )
          else
            IconButton(
              icon: const Icon(Icons.arrow_back, color: Colors.white),
              tooltip: _tooltipWithShortcut(
                "返回",
                DesktopPlayerShortcutAction.back,
              ),
              onPressed: () {
                _startAutoHideTimer();
                widget.onBackPressed();
              },
              iconSize: iconSize,
            ),
        ];
        final List<Widget> topTrailing = [
          if (!widget.isPreviewMode) ...[
            if (widget.onOpenSettings != null)
              IconButton(
                icon: const Icon(Icons.settings, color: Colors.white),
                tooltip: _tooltipWithShortcut(
                  "设置",
                  DesktopPlayerShortcutAction.openSettings,
                ),
                onPressed: () {
                  _startAutoHideTimer();
                  widget.onOpenSettings!();
                },
                iconSize: topActionIconSize,
                padding: topActionPadding,
                constraints: topActionConstraints,
              ),
            if (widget.onOpenSubtitleManager != null)
              IconButton(
                icon: const Icon(Icons.subtitles, color: Colors.white),
                tooltip: _tooltipWithShortcut(
                  "字幕库",
                  DesktopPlayerShortcutAction.openSubtitleLibrary,
                ),
                onPressed: () {
                  _startAutoHideTimer();
                  widget.onOpenSubtitleManager!();
                },
                iconSize: topActionIconSize,
                padding: topActionPadding,
                constraints: topActionConstraints,
              ),
            if (widget.showSubtitleEditorButton &&
                widget.onOpenSubtitleEditor != null)
              IconButton(
                icon: const Icon(Icons.edit_note, color: Colors.white),
                tooltip: _tooltipWithShortcut(
                  "字幕编辑",
                  DesktopPlayerShortcutAction.openSubtitleEditor,
                ),
                onPressed: () {
                  _startAutoHideTimer();
                  widget.onOpenSubtitleEditor!();
                },
                iconSize: topActionIconSize,
                padding: topActionPadding,
                constraints: topActionConstraints,
              ),
            if (widget.onOpenVideoCompose != null)
              IconButton(
                icon: const Icon(
                  Icons.movie_creation_outlined,
                  color: Colors.white,
                ),
                tooltip: _tooltipWithShortcut(
                  "合成视频",
                  DesktopPlayerShortcutAction.openVideoCompose,
                ),
                onPressed: () {
                  _startAutoHideTimer();
                  widget.onOpenVideoCompose!();
                },
                iconSize: topActionIconSize,
                padding: topActionPadding,
                constraints: topActionConstraints,
              ),
            if (widget.onToggleFloatingSubtitleSettings != null)
              IconButton(
                icon: const Icon(Icons.style, color: Colors.white),
                tooltip: _tooltipWithShortcut(
                  "悬浮字幕设置",
                  DesktopPlayerShortcutAction.openSubtitleStyle,
                ),
                onPressed: () {
                  _startAutoHideTimer();
                  widget.onToggleFloatingSubtitleSettings!();
                },
                iconSize: topActionIconSize,
                padding: topActionPadding,
                constraints: topActionConstraints,
              ),
            IconButton(
              icon: const Icon(Icons.open_with, color: Colors.white),
              tooltip: _tooltipWithShortcut(
                "移动字幕",
                DesktopPlayerShortcutAction.moveSubtitles,
              ),
              onPressed: () {
                _startAutoHideTimer();
                widget.onMoveSubtitles();
              },
              iconSize: topActionIconSize,
              padding: topActionPadding,
              constraints: topActionConstraints,
            ),
          ],
          if (!widget.isPreviewMode &&
              !kIsWeb &&
              (Platform.isWindows || Platform.isMacOS || Platform.isLinux))
            IconButton(
              icon: Icon(
                settings.isFullScreen
                    ? Icons.fullscreen_exit
                    : Icons.fullscreen,
                color: Colors.white,
              ),
              tooltip: _tooltipWithShortcut(
                settings.isFullScreen ? "退出全屏" : "全屏",
                DesktopPlayerShortcutAction.toggleFullScreen,
              ),
              onPressed: () {
                _startAutoHideTimer();
                widget.onToggleFullScreen!();
              },
              iconSize: topActionIconSize,
              padding: topActionPadding,
              constraints: topActionConstraints,
            ),
          if (widget.onToggleSidebar != null)
            IconButton(
              icon: Icon(
                widget.isSubtitleSidebarVisible ? Icons.menu_open : Icons.menu,
                color: Colors.white,
              ),
              tooltip: _tooltipWithShortcut(
                widget.isSubtitleSidebarVisible ? "隐藏字幕边栏" : "显示字幕边栏",
                DesktopPlayerShortcutAction.toggleSubtitleSidebar,
              ),
              onPressed: () {
                _startAutoHideTimer();
                widget.onToggleSidebar!();
              },
              iconSize: topActionIconSize,
              padding: topActionPadding,
              constraints: topActionConstraints,
            ),
          if (!widget.isPreviewMode &&
              widget.onOpenAspectRatio != null &&
              widget.aspectRatioLabel != null)
            Material(
              color: Colors.black45,
              borderRadius: BorderRadius.circular(aspectChipRadius),
              child: Tooltip(
                message: _tooltipWithShortcut(
                  "画面比例",
                  DesktopPlayerShortcutAction.openAspectRatio,
                ),
                child: InkWell(
                  borderRadius: BorderRadius.circular(aspectChipRadius),
                  onTap: () {
                    _startAutoHideTimer();
                    widget.onOpenAspectRatio!();
                  },
                  child: Padding(
                    padding: aspectChipPadding,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.aspect_ratio,
                          size: aspectChipIconSize,
                          color: Colors.white,
                        ),
                        SizedBox(width: aspectChipSpacing),
                        Text(
                          widget.aspectRatioLabel!,
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: aspectChipTextSize,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ];

        Widget focusChild = Focus(
          focusNode: widget.focusNode ?? _focusNode,
          autofocus: true,
          descendantsAreFocusable: false, // 禁用子控件焦点，确保键盘事件由 Focus 统一处理
          onKeyEvent: handleKeyEvent,
          child: Stack(
            children: [
              // 1. Background Gesture Layer (Lowest Z-Order)
              // This layer handles Double Tap (Seek), Single Tap (Toggle Controls), Long Press (Speed), Vertical Drag (Volume/Brightness).
              // It is BEHIND the control buttons, so buttons will intercept touches first.
              Positioned.fill(
                child: RawGestureDetector(
                  gestures: <Type, GestureRecognizerFactory>{
                    TapGestureRecognizer:
                        GestureRecognizerFactoryWithHandlers<
                          TapGestureRecognizer
                        >(() => TapGestureRecognizer(), (
                          TapGestureRecognizer instance,
                        ) {
                          instance.onTapDown = (details) {
                            final RenderBox box =
                                context.findRenderObject() as RenderBox;
                            final localOffset = box.globalToLocal(
                              details.globalPosition,
                            );
                            _tapPosition = localOffset;
                          };
                          instance.onTap = () {
                            _handleSmartTap(width);
                          };
                        }),
                    // DoubleTapGestureRecognizer removed to eliminate delay
                    LongPressGestureRecognizer:
                        GestureRecognizerFactoryWithHandlers<
                          LongPressGestureRecognizer
                        >(
                          // Android long press standard is 500ms, user requested "slightly longer than click"
                          // 350ms feels responsive without being too quick to trigger accidentally during slow clicks
                          () => LongPressGestureRecognizer(
                            duration: const Duration(milliseconds: 350),
                          ),
                          (LongPressGestureRecognizer instance) {
                            instance.onLongPressStart = (details) {
                              final RenderBox box =
                                  context.findRenderObject() as RenderBox;
                              final localOffset = box.globalToLocal(
                                details.globalPosition,
                              );

                              // Always trigger long press speed up
                              _handleZoneLongPressStart(localOffset, width);
                            };
                            instance.onLongPressMoveUpdate = (details) {
                              if (widget.isLongPressing) return;
                              // Center long press seek removed in favor of Horizontal Drag
                            };
                            instance.onLongPressEnd = (details) {
                              if (widget.isLongPressing) {
                                _handleZoneLongPressEnd(details);
                              }
                            };
                            instance.onLongPressCancel = () {
                              if (widget.isLongPressing) {
                                // If gesture is canceled (e.g. system interruption), we must clean up
                                // But if we use GlobalKey, we hope it persists.
                                // If it still cancels, we reset. Better safe than stuck.
                                // Note: LongPressEndDetails is required by _handleZoneLongPressEnd but it only uses it for nothing important (just triggers callback).
                                // So we can pass a dummy or change the signature.
                                widget.onLongPressEnd();
                              }
                            };
                          },
                        ),
                    VerticalDragGestureRecognizer:
                        GestureRecognizerFactoryWithHandlers<
                          VerticalDragGestureRecognizer
                        >(() => VerticalDragGestureRecognizer(), (
                          VerticalDragGestureRecognizer instance,
                        ) {
                          instance.onStart = (details) =>
                              _onVerticalDragStart(details, width);
                          instance.onUpdate = (details) =>
                              _onVerticalDragUpdate(details, height);
                          instance.onEnd = (details) =>
                              _onVerticalDragEnd(details);
                        }),
                    HorizontalDragGestureRecognizer:
                        GestureRecognizerFactoryWithHandlers<
                          HorizontalDragGestureRecognizer
                        >(() => HorizontalDragGestureRecognizer(), (
                          HorizontalDragGestureRecognizer instance,
                        ) {
                          instance.onStart = (details) =>
                              _onHorizontalDragStart(details, width);
                          instance.onUpdate = (details) =>
                              _onHorizontalDragUpdate(details, context);
                          instance.onEnd = (details) =>
                              _onHorizontalDragEnd(details);
                        }),
                  },
                  behavior: HitTestBehavior.translucent,
                  child: Stack(
                    children: [
                      // Transparent container to catch hits in empty areas
                      Container(color: Colors.transparent),
                      if (isWindows)
                        Positioned.fill(
                          child: IgnorePointer(
                            child: Container(
                              color: Colors.black.withValues(
                                alpha: brightnessOverlayAlpha,
                              ),
                            ),
                          ),
                        ),

                      // Subtitles (Gesture Layer for Long Press Drag)
                      // Kept here so it participates in the background gesture arena.
                      // Tapping subtitle -> Hits here -> Parent RawGestureDetector handles Tap -> Toggles controls.
                      // Long Press subtitle -> Child SubtitleOverlay handles Long Press -> Drag mode.
                      if (widget.showSubtitles)
                        Positioned.fill(
                          child: SubtitleOverlayGroup(
                            entries: widget.subtitleEntries,
                            alignment: widget.subtitleAlignment,
                            style: widget.subtitleStyle,
                            onLongPress: widget.suppressPrimaryGestures
                                ? null
                                : widget.onEnterSubtitleDragMode,
                            isGestureOnly: true,
                          ),
                        ),

                      // Visual Feedback Elements (Zone, Seek, Brightness/Volume, Cancel Area)
                      // These are non-interactive visuals driven by state

                      // Zone Feedback (Long Press)
                      if (widget.isLongPressing && _tapPosition != null)
                        Positioned(
                          left: _tapPosition!.dx <= width / 2 ? 40 : null,
                          right: _tapPosition!.dx > width / 2 ? 40 : null,
                          top: height / 2 - 30,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 8,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.black54,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  widget.isLongPressing
                                      ? Icons.fast_forward
                                      : (_tapPosition!.dx < width / 2
                                            ? Icons.fast_rewind
                                            : Icons.fast_forward),
                                  color: Colors.white,
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  widget.isLongPressing
                                      ? widget.longPressFeedbackText
                                      : _doubleTapFeedbackText,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),

                      if (_showDoubleTapFeedback && _tapPosition != null)
                        _buildDoubleTapFeedbackOverlay(width, height),

                      // Gesture Seek Feedback (Center)
                      if (_isGestureSeeking &&
                          !widget.isLocked &&
                          !widget.isLongPressing)
                        Center(
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 24,
                              vertical: 16,
                            ),
                            decoration: BoxDecoration(
                              color: _isGestureCanceling
                                  ? Colors.red.withValues(alpha: 0.8)
                                  : Colors.black.withValues(alpha: 0.7),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (_isGestureCanceling) ...[
                                  const Icon(
                                    Icons.undo,
                                    color: Colors.white,
                                    size: 48,
                                  ),
                                  const SizedBox(height: 8),
                                  const Text(
                                    "松手取消跳转",
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ] else ...[
                                  Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        _gestureDiffText.startsWith('+')
                                            ? Icons.fast_forward
                                            : Icons.fast_rewind,
                                        color: Colors.white70,
                                        size: 32,
                                      ),
                                      const SizedBox(width: 8),
                                      Text(
                                        _gestureDiffText,
                                        style: const TextStyle(
                                          color: Colors.blueAccent,
                                          fontSize: 24,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    "${_formatDuration(_gestureTargetTime)} / ${_formatDuration(widget.controller.value.duration)}",
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 16,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),

                      // Brightness/Volume Feedback (Center)
                      if ((_isAdjustingBrightness || _isAdjustingVolume) &&
                          !widget.isLocked)
                        Center(
                          child: Container(
                            width: 150,
                            padding: const EdgeInsets.symmetric(vertical: 20),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.7),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  _isAdjustingBrightness
                                      ? Icons.brightness_6
                                      : Icons.volume_up,
                                  color: Colors.white,
                                  size: 48,
                                ),
                                const SizedBox(height: 12),
                                LinearProgressIndicator(
                                  value: _isAdjustingBrightness
                                      ? _currentBrightness
                                      : _currentVolume,
                                  backgroundColor: Colors.white24,
                                  valueColor:
                                      const AlwaysStoppedAnimation<Color>(
                                        Colors.blueAccent,
                                      ),
                                  minHeight: 6,
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  "${((_isAdjustingBrightness ? _currentBrightness : _currentVolume) * 100).toInt()}%",
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),

                      // Seek Cancel Area Highlight
                      if ((_isGestureSeeking || _isDraggingProgress) &&
                          !widget.isLocked)
                        Positioned(
                          top: 0,
                          left: 0,
                          right: 0,
                          height: height * 0.25,
                          child: Container(
                            color:
                                (_isGestureCanceling ||
                                    _isProgressDragCanceling)
                                ? Colors.red.withValues(alpha: 0.3)
                                : Colors.white.withValues(alpha: 0.1),
                            alignment: Alignment.center,
                            child: Text(
                              (_isGestureCanceling || _isProgressDragCanceling)
                                  ? "松手取消"
                                  : "上滑至此区域取消",
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),

              // 2. Interactive Controls Layer (Highest Z-Order)
              // These buttons are SIBLINGS to the RawGestureDetector, so they intercept touches directly.
              // They do NOT have a DoubleTapGestureRecognizer in their parent chain, so Single Taps fire immediately.

              // Volume Slider Overlay (Removed)
              // if (_showVolumeSlider && !widget.isLocked) ...

              // Lock Button
              if (showLockButton &&
                  (widget.isLocked ||
                      (_showControls && !hideControlsForGestureSeek)))
                Positioned(
                  left: isLeftHandedMode ? null : (isSmallScreen ? 12 : 20),
                  right: isLeftHandedMode ? (isSmallScreen ? 12 : 20) : null,
                  top:
                      height / 2 -
                      (lockIconSize / 2 + (isSmallScreen ? 8 : 12)),
                  child: IconButton(
                    onPressed: () {
                      _startAutoHideTimer();
                      widget.onToggleLock();
                    },
                    icon: Icon(
                      widget.isLocked ? Icons.lock : Icons.lock_open,
                      color: widget.isLocked
                          ? Colors.blueAccent
                          : Colors.white54,
                      size: lockIconSize,
                    ),
                    style: IconButton.styleFrom(
                      backgroundColor: Colors.black45,
                      padding: EdgeInsets.all(isSmallScreen ? 8 : 12),
                    ),
                  ),
                ),

              // 顶部及底部控制区（淡入淡出动画）
              Positioned.fill(
                child: AnimatedOpacity(
                  opacity: (_showControls && !widget.isLocked && !hideControlsForGestureSeek) ? 1.0 : 0.0,
                  duration: const Duration(milliseconds: 250),
                  curve: Curves.easeInOut,
                  child: IgnorePointer(
                    ignoring: !(_showControls && !widget.isLocked && !hideControlsForGestureSeek),
                    child: Stack(
                      children: [
                // Top Controls
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                  child: GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onTap: () {
                      // Reset auto-hide timer when any control is tapped
                      _startAutoHideTimer();
                    },
                    child: Container(
                      padding: EdgeInsets.symmetric(
                        horizontal: isSmallScreen ? 8 : 16,
                        vertical: topBarPadding,
                      ),
                      decoration: const BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [Colors.black54, Colors.transparent],
                        ),
                      ),
                      child: Row(
                        children: [
                          if (isLeftHandedMode)
                            ...topTrailing
                          else
                            ...topLeading,
                          if (mediaTitle.isNotEmpty) ...[
                            const SizedBox(width: 8),
                            Expanded(
                              child: _buildTopBarTitle(
                                mediaTitle: mediaTitle,
                                fontSize: isSmallScreen ? 14 : 16,
                                alignRight: isLeftHandedMode,
                              ),
                            ),
                            const SizedBox(width: 8),
                          ] else
                            const Spacer(),
                          if (isLeftHandedMode)
                            ...topLeading
                          else
                            ...topTrailing,
                        ],
                      ),
                    ),
                  ),
                ),

                // Bottom Controls (Progress & Time)
                if (widget.showBottomBar)
                  Positioned(
                    bottom: 0,
                    left: 0,
                    right: 0,
                    child: GestureDetector(
                      onHorizontalDragStart:
                          (_) {}, // Consume horizontal drag to prevent conflict
                      onTap: () {
                        // Reset auto-hide timer when bottom controls are tapped
                        _startAutoHideTimer();
                      },
                      child: Container(
                        padding: EdgeInsets.symmetric(
                          horizontal: bottomBarPadding,
                          vertical: bottomBarVerticalPadding,
                        ),
                        decoration: const BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.bottomCenter,
                            end: Alignment.topCenter,
                            colors: [Colors.black87, Colors.transparent],
                          ),
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            AnimatedBuilder(
                              animation: widget.controller,
                              builder: (context, child) {
                                final position =
                                    widget.controller.value.position;
                                final duration =
                                    widget.controller.value.duration;
                                final isInitialized =
                                    widget.controller.value.isInitialized &&
                                    duration.inMilliseconds > 0;

                                final currentPosition = _isDraggingProgress
                                    ? Duration(
                                        milliseconds: _dragProgressValue
                                            .toInt(),
                                      )
                                    : position;

                                final sliderMax = isInitialized
                                    ? duration.inMilliseconds.toDouble()
                                    : 1.0;
                                final sliderValue = isInitialized
                                    ? currentPosition.inMilliseconds
                                          .toDouble()
                                          .clamp(0.0, sliderMax)
                                    : 0.0;

                                return Column(
                                  children: [
                                    // 进度条区域（RepaintBoundary 隔离重绘，避免每帧重绘底部控制栏）
                                    RepaintBoundary(
                                    child: LayoutBuilder(
                                      builder: (context, sliderConstraints) {
                                        return Stack(
                                          clipBehavior: Clip.none,
                                          alignment: Alignment.bottomLeft,
                                          children: [
                                            // Seek Preview Overlay
                                            if (_isDraggingProgress &&
                                                _previewImage != null)
                                              Positioned(
                                                left: () {
                                                  final double width =
                                                      sliderConstraints
                                                          .maxWidth;
                                                  final double pct =
                                                      sliderMax > 0
                                                      ? sliderValue / sliderMax
                                                      : 0;
                                                  // Center the 160px preview on the thumb
                                                  double left =
                                                      (width * pct) - 80;
                                                  // Clamp to edges
                                                  if (left < 0) left = 0;
                                                  if (left + 160 > width) {
                                                    left = width - 160;
                                                  }
                                                  return left;
                                                }(),
                                                bottom: 40,
                                                child: Column(
                                                  mainAxisSize:
                                                      MainAxisSize.min,
                                                  children: [
                                                    Container(
                                                      width: 160,
                                                      height: 90,
                                                      decoration: BoxDecoration(
                                                        color: Colors.black,
                                                        border: Border.all(
                                                          color: Colors.white70,
                                                          width: 1.5,
                                                        ),
                                                        borderRadius:
                                                            BorderRadius.circular(
                                                              8,
                                                            ),
                                                        boxShadow: const [
                                                          BoxShadow(
                                                            color:
                                                                Colors.black45,
                                                            blurRadius: 4,
                                                          ),
                                                        ],
                                                      ),
                                                      child: ClipRRect(
                                                        borderRadius:
                                                            BorderRadius.circular(
                                                              6,
                                                            ),
                                                        child: Image.memory(
                                                          _previewImage!,
                                                          fit: BoxFit.cover,
                                                          gaplessPlayback: true,
                                                        ),
                                                      ),
                                                    ),
                                                    const SizedBox(height: 4),
                                                    Container(
                                                      padding:
                                                          const EdgeInsets.symmetric(
                                                            horizontal: 6,
                                                            vertical: 2,
                                                          ),
                                                      decoration: BoxDecoration(
                                                        color: Colors.black54,
                                                        borderRadius:
                                                            BorderRadius.circular(
                                                              4,
                                                            ),
                                                      ),
                                                      child: Text(
                                                        _formatDuration(
                                                          Duration(
                                                            milliseconds:
                                                                sliderValue
                                                                    .toInt(),
                                                          ),
                                                        ),
                                                        style: const TextStyle(
                                                          color: Colors.white,
                                                          fontSize: 12,
                                                        ),
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ),

                                            Listener(
                                              behavior:
                                                  HitTestBehavior.translucent,
                                              onPointerMove: (event) {
                                                if (!_isDraggingProgress ||
                                                    widget.isLocked) {
                                                  return;
                                                }
                                                final isInCancelArea =
                                                    _isInCancelArea(
                                                      event.position,
                                                    );
                                                if (isInCancelArea !=
                                                    _isProgressDragCanceling) {
                                                  setState(() {
                                                    _isProgressDragCanceling =
                                                        isInCancelArea;
                                                  });
                                                }
                                              },
                                              onPointerCancel: (event) {
                                                if (!_isDraggingProgress) {
                                                  return;
                                                }
                                                VideoPreviewService()
                                                    .markInteractionEnded();
                                                _cancelSeekPreviewRefine();
                                                _resetSeekPreviewRequestState();
                                                setState(() {
                                                  _isDraggingProgress = false;
                                                  _previewImage = null;
                                                  _isProgressDragCanceling =
                                                      false;
                                                });
                                              },
                                              child: SizedBox(
                                                height:
                                                    40, // Ensure enough height for hit testing
                                                child: SliderTheme(
                                                  data: SliderTheme.of(context).copyWith(
                                                    activeTrackColor:
                                                        _isProgressDragCanceling
                                                        ? Colors.grey
                                                        : const Color(
                                                            0xFF0D47A1,
                                                          ),
                                                    inactiveTrackColor:
                                                        Colors.white24,
                                                    thumbColor: isInitialized
                                                        ? (_isProgressDragCanceling
                                                              ? Colors.grey
                                                              : const Color(
                                                                  0xFF1565C0,
                                                                ))
                                                        : Colors.grey,
                                                    overlayColor: const Color(
                                                      0x291565C0,
                                                    ),
                                                    thumbShape:
                                                        RoundSliderThumbShape(
                                                          enabledThumbRadius:
                                                              isSmallScreen
                                                              ? 4.0
                                                              : 6.0,
                                                        ),
                                                    trackHeight: isSmallScreen
                                                        ? 2.0
                                                        : 4.0,
                                                    overlayShape:
                                                        const RoundSliderOverlayShape(
                                                          overlayRadius: 10,
                                                        ), // Reduced overlay to fit
                                                  ),
                                                  child: Slider(
                                                    min: 0.0,
                                                    max: sliderMax,
                                                    value: sliderValue,
                                                    onChangeStart: isInitialized
                                                        ? (newValue) {
                                                            setState(() {
                                                              _isDraggingProgress =
                                                                  true;
                                                              _dragProgressValue =
                                                                  newValue;
                                                            });
                                                            _scheduleLiveSeekPreview(
                                                              newValue,
                                                              immediate: true,
                                                            );
                                                            _schedulePreciseSeekPreview(
                                                              newValue,
                                                            );
                                                            _startAutoHideTimer();
                                                          }
                                                        : null,
                                                    onChanged: isInitialized
                                                        ? (newValue) {
                                                            setState(() {
                                                              _isDraggingProgress =
                                                                  true;
                                                              _dragProgressValue =
                                                                  newValue;
                                                            });
                                                            _scheduleLiveSeekPreview(
                                                              newValue,
                                                            );
                                                            _schedulePreciseSeekPreview(
                                                              newValue,
                                                            );
                                                            // Reset auto-hide timer while dragging
                                                            _startAutoHideTimer();
                                                          }
                                                        : null,
                                                    onChangeEnd: (newValue) {
                                                      VideoPreviewService()
                                                          .markInteractionEnded();
                                                      _cancelSeekPreviewRefine();
                                                      _resetSeekPreviewRequestState();
                                                      if (!_isProgressDragCanceling) {
                                                        _seekTo(
                                                          Duration(
                                                            milliseconds:
                                                                newValue
                                                                    .toInt(),
                                                          ),
                                                        );
                                                      }
                                                      setState(() {
                                                        _previewRequestSerial++;
                                                        _isDraggingProgress =
                                                            false;
                                                        _previewImage = null;
                                                        _isProgressDragCanceling =
                                                            false;
                                                      });
                                                      // Reset auto-hide timer after seeking
                                                      _startAutoHideTimer();
                                                    },
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ],
                                        );
                                      },
                                    ),
                                    ), // 进度条 RepaintBoundary 结束
                                    // 底部控制栏（RepaintBoundary 隔离重绘）
                                    RepaintBoundary(
                                      child: SizedBox(
                                      height:
                                          bigIconSize * 1.5, // Adaptive height
                                      child: Stack(
                                        children: [
                                          // Left: Time and Episode Picker
                                          Align(
                                            alignment: timeAlignment,
                                            child: Row(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                Text(
                                                  "${_formatDuration(currentPosition)} / ${_formatDuration(duration)}",
                                                  style: TextStyle(
                                                    color: Colors.white,
                                                    fontSize: isSmallScreen
                                                        ? 10
                                                        : 12,
                                                  ),
                                                ),
                                                if (widget
                                                        .onToggleEpisodePicker !=
                                                    null) ...[
                                                  const SizedBox(width: 8),
                                                  Tooltip(
                                                    message: _tooltipWithShortcut(
                                                      "选集",
                                                      DesktopPlayerShortcutAction
                                                          .toggleEpisodePicker,
                                                    ),
                                                    child: TextButton.icon(
                                                      onPressed: () {
                                                        _startAutoHideTimer();
                                                        widget
                                                            .onToggleEpisodePicker
                                                            ?.call();
                                                      },
                                                      style: TextButton.styleFrom(
                                                        foregroundColor:
                                                            Colors.white,
                                                        padding:
                                                            const EdgeInsets.symmetric(
                                                              horizontal: 8,
                                                              vertical: 2,
                                                            ),
                                                        minimumSize: const Size(
                                                          0,
                                                          32,
                                                        ),
                                                        tapTargetSize:
                                                            MaterialTapTargetSize
                                                                .shrinkWrap,
                                                      ),
                                                      icon: const Icon(
                                                        Icons.playlist_play,
                                                        size: 18,
                                                      ),
                                                      label: const Text(
                                                        "选集",
                                                        style: TextStyle(
                                                          fontWeight:
                                                              FontWeight.bold,
                                                        ),
                                                      ),
                                                    ),
                                                  ),
                                                ],
                                              ],
                                            ),
                                          ),

                                          // Center: Play Controls (Play/Pause, Seek)
                                          if (widget.showPlayControls)
                                            Align(
                                              alignment: Alignment.center,
                                              child: Row(
                                                mainAxisSize: MainAxisSize.min,
                                                children: [
                                                  // Previous Episode
                                                  if (widget.onPlayPrevious !=
                                                      null) ...[
                                                    IconButton(
                                                      iconSize: bigIconSize,
                                                      icon: Icon(
                                                        Icons.skip_previous,
                                                        color:
                                                            widget.hasPrevious
                                                            ? Colors.white
                                                            : Colors.white38,
                                                      ),
                                                      onPressed:
                                                          widget.hasPrevious
                                                          ? () {
                                                              _startAutoHideTimer();
                                                              widget
                                                                  .onPlayPrevious!();
                                                            }
                                                          : null,
                                                      tooltip: _tooltipWithShortcut(
                                                        "上一集",
                                                        DesktopPlayerShortcutAction
                                                            .previousEpisode,
                                                      ),
                                                    ),
                                                    const SizedBox(width: 8),
                                                  ],

                                                  // Seek Backward Button with Dynamic Number
                                                  Tooltip(
                                                    message: _tooltipWithShortcut(
                                                      "快退 ${widget.doubleTapSeekSeconds} 秒",
                                                      DesktopPlayerShortcutAction
                                                          .seekBackward,
                                                    ),
                                                    child: InkWell(
                                                      onTap: () {
                                                        if (!widget
                                                            .controller
                                                            .value
                                                            .isInitialized) {
                                                          return;
                                                        }
                                                        _startAutoHideTimer();
                                                        final newPos =
                                                            widget
                                                                .controller
                                                                .value
                                                                .position -
                                                            Duration(
                                                              seconds: widget
                                                                  .doubleTapSeekSeconds,
                                                            );
                                                        _seekTo(
                                                          newPos < Duration.zero
                                                              ? Duration.zero
                                                              : newPos,
                                                        );
                                                      },
                                                      borderRadius:
                                                          BorderRadius.circular(
                                                            20,
                                                          ),
                                                      child: SizedBox(
                                                        width: bigIconSize + 8,
                                                        height: bigIconSize + 8,
                                                        child: Stack(
                                                          alignment:
                                                              Alignment.center,
                                                          children: [
                                                            Icon(
                                                              Icons.replay,
                                                              color:
                                                                  widget
                                                                      .controller
                                                                      .value
                                                                      .isInitialized
                                                                  ? Colors.white
                                                                  : Colors
                                                                        .white38,
                                                              size:
                                                                  bigIconSize *
                                                                  0.75,
                                                            ),
                                                            Text(
                                                              "${widget.doubleTapSeekSeconds}",
                                                              style: TextStyle(
                                                                color:
                                                                    widget
                                                                        .controller
                                                                        .value
                                                                        .isInitialized
                                                                    ? Colors
                                                                          .white
                                                                    : Colors
                                                                          .white38,
                                                                fontSize: 8,
                                                                fontWeight:
                                                                    FontWeight
                                                                        .bold,
                                                              ),
                                                            ),
                                                          ],
                                                        ),
                                                      ),
                                                    ),
                                                  ),
                                                  const SizedBox(width: 8),
                                                  IconButton(
                                                    iconSize: bigIconSize,
                                                    icon: Icon(
                                                      widget
                                                              .controller
                                                              .value
                                                              .isPlaying
                                                          ? Icons
                                                                .pause_circle_filled
                                                          : Icons
                                                                .play_circle_fill,
                                                      color:
                                                          widget
                                                              .controller
                                                              .value
                                                              .isInitialized
                                                          ? Colors.white
                                                          : Colors.white38,
                                                    ),
                                                    onPressed:
                                                        widget
                                                            .controller
                                                            .value
                                                            .isInitialized
                                                        ? () {
                                                            _startAutoHideTimer();
                                                            widget
                                                                .onTogglePlay();
                                                          }
                                                        : null,
                                                    tooltip: _tooltipWithShortcut(
                                                      widget
                                                              .controller
                                                              .value
                                                              .isPlaying
                                                          ? "暂停"
                                                          : "播放",
                                                      DesktopPlayerShortcutAction
                                                          .playPause,
                                                    ),
                                                  ),
                                                  const SizedBox(width: 8),
                                                  // Seek Forward Button with Dynamic Number
                                                  Tooltip(
                                                    message: _tooltipWithShortcut(
                                                      "快进 ${widget.doubleTapSeekSeconds} 秒",
                                                      DesktopPlayerShortcutAction
                                                          .seekForward,
                                                    ),
                                                    child: InkWell(
                                                      onTap: () {
                                                        if (!widget
                                                            .controller
                                                            .value
                                                            .isInitialized) {
                                                          return;
                                                        }
                                                        _startAutoHideTimer();
                                                        final newPos =
                                                            widget
                                                                .controller
                                                                .value
                                                                .position +
                                                            Duration(
                                                              seconds: widget
                                                                  .doubleTapSeekSeconds,
                                                            );
                                                        final duration = widget
                                                            .controller
                                                            .value
                                                            .duration;
                                                        _seekTo(
                                                          newPos > duration
                                                              ? duration
                                                              : newPos,
                                                        );
                                                      },
                                                      borderRadius:
                                                          BorderRadius.circular(
                                                            20,
                                                          ),
                                                      child: SizedBox(
                                                        width: bigIconSize + 8,
                                                        height: bigIconSize + 8,
                                                        child: Stack(
                                                          alignment:
                                                              Alignment.center,
                                                          children: [
                                                            // Transform to flip the replay icon horizontally to make it look like forward
                                                            Transform(
                                                              alignment:
                                                                  Alignment
                                                                      .center,
                                                              transform:
                                                                  Matrix4.rotationY(
                                                                    3.14159,
                                                                  ),
                                                              child: Icon(
                                                                Icons.replay,
                                                                color:
                                                                    widget
                                                                        .controller
                                                                        .value
                                                                        .isInitialized
                                                                    ? Colors
                                                                          .white
                                                                    : Colors
                                                                          .white38,
                                                                size:
                                                                    bigIconSize *
                                                                    .75,
                                                              ),
                                                            ),
                                                            Text(
                                                              "${widget.doubleTapSeekSeconds}",
                                                              style: TextStyle(
                                                                color:
                                                                    widget
                                                                        .controller
                                                                        .value
                                                                        .isInitialized
                                                                    ? Colors
                                                                          .white
                                                                    : Colors
                                                                          .white38,
                                                                fontSize: 8,
                                                                fontWeight:
                                                                    FontWeight
                                                                        .bold,
                                                              ),
                                                            ),
                                                          ],
                                                        ),
                                                      ),
                                                    ),
                                                  ),

                                                  // Next Episode
                                                  if (widget.onPlayNext !=
                                                      null) ...[
                                                    const SizedBox(width: 8),
                                                    IconButton(
                                                      iconSize: bigIconSize,
                                                      icon: Icon(
                                                        Icons.skip_next,
                                                        color: widget.hasNext
                                                            ? Colors.white
                                                            : Colors.white38,
                                                      ),
                                                      onPressed: widget.hasNext
                                                          ? () {
                                                              _startAutoHideTimer();
                                                              widget
                                                                  .onPlayNext!();
                                                            }
                                                          : null,
                                                      tooltip: _tooltipWithShortcut(
                                                        "下一集",
                                                        DesktopPlayerShortcutAction
                                                            .nextEpisode,
                                                      ),
                                                    ),
                                                  ],
                                                ],
                                              ),
                                            ),

                                          // Right: Tools (Speed, Subtitles, Volume)
                                          Align(
                                            alignment: toolsAlignment,
                                            child: Row(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                if (!widget.isPreviewMode) ...[
                                                  PopupMenuButton<double>(
                                                    initialValue: widget
                                                        .controller
                                                        .value
                                                        .playbackSpeed,
                                                    tooltip: "倍速",
                                                    onSelected: (speed) {
                                                      _startAutoHideTimer();
                                                      widget.onSpeedUpdate(
                                                        speed,
                                                      );
                                                    },
                                                    constraints:
                                                        const BoxConstraints(
                                                          maxHeight: 400,
                                                        ), // Limit height to ensure scrolling behavior is obvious
                                                    itemBuilder: (context) =>
                                                        [
                                                          0.25,
                                                          0.5,
                                                          0.75,
                                                          1.0,
                                                          1.25,
                                                          1.5,
                                                          2.0,
                                                          2.5,
                                                          3.0,
                                                          4.0,
                                                          5.0,
                                                        ].map((speed) {
                                                          return _buildPlaybackSpeedMenuItem(
                                                            context,
                                                            settings,
                                                            speed,
                                                          );
                                                        }).toList(),
                                                    child: Padding(
                                                      padding:
                                                          const EdgeInsets.symmetric(
                                                            horizontal: 8,
                                                          ),
                                                      child: Row(
                                                        mainAxisSize:
                                                            MainAxisSize.min,
                                                        children: [
                                                          Text(
                                                            "${widget.controller.value.playbackSpeed}x",
                                                            style:
                                                                const TextStyle(
                                                                  color: Colors
                                                                      .white,
                                                                  fontWeight:
                                                                      FontWeight
                                                                          .bold,
                                                                ),
                                                          ),
                                                          if (settings
                                                              .isLockedPlaybackSpeed(
                                                                widget
                                                                    .controller
                                                                    .value
                                                                    .playbackSpeed,
                                                              )) ...[
                                                            const SizedBox(
                                                              width: 4,
                                                            ),
                                                            const Icon(
                                                              Icons.lock,
                                                              size: 14,
                                                              color: Colors
                                                                  .blueAccent,
                                                            ),
                                                          ],
                                                        ],
                                                      ),
                                                    ),
                                                  ),

                                                  IconButton(
                                                    icon: Icon(
                                                      widget.showSubtitles
                                                          ? Icons.subtitles
                                                          : Icons.subtitles_off,
                                                      color:
                                                          widget.showSubtitles
                                                          ? Colors.blueAccent
                                                          : Colors.white70,
                                                    ),
                                                    onPressed: () {
                                                      _startAutoHideTimer();
                                                      widget
                                                          .onToggleSubtitles();
                                                    },
                                                    tooltip: _tooltipWithShortcut(
                                                      widget.showSubtitles
                                                          ? "隐藏字幕"
                                                          : "显示字幕",
                                                      DesktopPlayerShortcutAction
                                                          .toggleSubtitles,
                                                    ),
                                                  ),

                                                  Selector<MediaPlaybackService, bool>(
                                                    selector: (_, s) => s.isMuted,
                                                    builder: (context, isMuted, _) {
                                                      return IconButton(
                                                        icon: Icon(
                                                          isMuted
                                                              ? Icons.volume_off
                                                              : Icons.volume_up,
                                                          color: isMuted
                                                              ? Colors.redAccent
                                                              : Colors.white,
                                                        ),
                                                        onPressed: () {
                                                          _startAutoHideTimer();
                                                          unawaited(
                                                            playbackService
                                                                .toggleMute(),
                                                          );
                                                        },
                                                        tooltip: _tooltipWithShortcut(
                                                          isMuted
                                                              ? "取消静音"
                                                              : "静音",
                                                          DesktopPlayerShortcutAction
                                                              .toggleMute,
                                                        ),
                                                      );
                                                    },
                                                  ),
                                                ],
                                              ],
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    ), // 底部控制栏 RepaintBoundary 结束
                                  ],
                                );
                              },
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                if (_showControls &&
                    !widget.isLocked &&
                    !hideControlsForGestureSeek &&
                    widget.showBottomBar &&
                    widget.showResetScreenButton &&
                    widget.onResetScreenTransform != null)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: bottomBarVerticalPadding + (bigIconSize * 1.5) + 48,
                    child: SizedBox(
                      height: resetButtonRowHeight,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          Positioned.fill(
                            child: GestureDetector(
                              behavior: HitTestBehavior.translucent,
                              onTap: () {
                                widget.onClearSelection?.call();
                                setState(() {
                                  _showControls = false;
                                });
                                _cancelAutoHideTimer();
                              },
                            ),
                          ),
                          TextButton.icon(
                            onPressed: () {
                              widget.onResetScreenTransform?.call();
                              _startAutoHideTimer();
                            },
                            style: TextButton.styleFrom(
                              foregroundColor: Colors.white,
                              backgroundColor: Colors.black54,
                              padding: resetButtonPadding,
                              minimumSize: Size.zero,
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(18),
                                side: const BorderSide(color: Colors.white24),
                              ),
                            ),
                            icon: Icon(
                              Icons.center_focus_strong,
                              size: resetButtonIconSize,
                            ),
                            label: Text(
                              "还原屏幕",
                              style: TextStyle(
                                fontSize: resetButtonFontSize,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        );

        // Desktop: Wrap with MouseRegion to show controls on mouse movement
        // and hide cursor when controls are hidden for full immersion
        if (isDesktop) {
          return MouseRegion(
            onHover: _onMouseHover,
            cursor: _showControls
                ? MouseCursor.defer
                : SystemMouseCursors.none,
            child: focusChild,
          );
        }
        return focusChild;
      },
    );
  }

  Widget _buildTopBarTitle({
    required String mediaTitle,
    required double fontSize,
    required bool alignRight,
  }) {
    final Alignment alignment = alignRight
        ? Alignment.centerRight
        : Alignment.centerLeft;
    final TextAlign textAlign = alignRight ? TextAlign.right : TextAlign.left;
    return ClipRect(
      child: Align(
        alignment: alignment,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          reverse: alignRight,
          physics: const BouncingScrollPhysics(),
          child: Text(
            mediaTitle,
            textAlign: textAlign,
            maxLines: 1,
            overflow: TextOverflow.visible,
            style: TextStyle(
              color: Colors.white,
              fontSize: fontSize,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }
}
