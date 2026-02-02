import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:io';
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
import '../services/settings_service.dart';
import '../services/video_preview_service.dart';

class VideoControlsOverlay extends StatefulWidget {
  final VideoPlayerController controller;
  final bool isLocked; 
  final VoidCallback onTogglePlay;
  final VoidCallback onBackPressed;
  final VoidCallback? onExitPressed; // New: For Windows direct exit
  final VoidCallback? onToggleSidebar;
  final bool isSubtitleSidebarVisible;
  final VoidCallback? onOpenSettings;
  final VoidCallback? onToggleFloatingSubtitleSettings;
  final VoidCallback onToggleLock; 
  final VoidCallback? onToggleFullScreen; // New: For desktop full screen toggle
  final ValueChanged<Duration>? onSeekTo;
  final ValueChanged<double> onSpeedUpdate;
  final int doubleTapSeekSeconds;
  final bool enableDoubleTapSubtitleSeek;
  final List<SubtitleItem> subtitles;
  final double longPressSpeed;
  final bool showSubtitles;
  final VoidCallback onToggleSubtitles;
  final VoidCallback onMoveSubtitles; // New callback for move subtitles

  // Subtitle Dragging Passthrough
  final List<SubtitleOverlayEntry> subtitleEntries;
  final SubtitleStyle subtitleStyle;
  final Alignment subtitleAlignment;
  final VoidCallback onEnterSubtitleDragMode;
  final VoidCallback? onClearSelection; // New callback
  final bool showPlayControls;
  final bool showBottomBar;
  final FocusNode? focusNode; // New: External focus node
  
  // Playlist Navigation
  final VoidCallback? onPlayPrevious;
  final VoidCallback? onPlayNext;
  final bool hasPrevious;
  final bool hasNext;

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
    this.onToggleFloatingSubtitleSettings,
    required this.onToggleLock,
    this.onToggleFullScreen,
    this.onSeekTo,
    required this.onSpeedUpdate,
    this.doubleTapSeekSeconds = 5,
    this.enableDoubleTapSubtitleSeek = true,
    this.subtitles = const [],
    this.longPressSpeed = 2.0,
    required this.showSubtitles,
    required this.onToggleSubtitles,
    required this.onMoveSubtitles, // New parameter
    required this.subtitleEntries,
    required this.subtitleStyle,
    required this.subtitleAlignment,
    required this.onEnterSubtitleDragMode,
    this.onClearSelection, // New parameter
    this.showPlayControls = true,
    this.showBottomBar = true,
    this.focusNode,
    this.onPlayPrevious,
    this.onPlayNext,
    this.hasPrevious = false,
    this.hasNext = false,
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
  bool _isProgressDragCanceling = false; // New: For slider drag cancellation

  // Long Press Speed
  bool _isLongPressingZone = false;
  String _zoneFeedbackText = "";
  Offset? _tapPosition;

  // Volume & Brightness
  bool _isAdjustingVolume = false;
  bool _isAdjustingBrightness = false;
  // bool _showVolumeSlider = false; // Removed
  double _currentVolume = 0.0;
  double _currentBrightness = 0.0;
  double _preLongPressSpeed = 1.0;
  double _startDragValue = 0.0; // Value at start of drag
  // double _sliderVolume = 1.0; // Removed
  
  double _lastPlayerVolume = 1.0; // To restore volume after unmute

  // Manual Double Tap Detection
  DateTime? _lastTapTime;
  Offset? _lastTapDownPosition;
  Timer? _singleTapTimer;

  // Keyboard Handling
  final FocusNode _focusNode = FocusNode(debugLabel: 'VideoControlsOverlayFocus');
  Timer? _keyboardLongPressTimer;
  bool _isKeyboardLongPressing = false;
  bool _wasPlayingBeforeLongPress = false; // 新增：记录长按前的播放状态
  // Key press tracking
  bool _isSpacePressed = false;
  bool _isRightArrowPressed = false;
  bool _isLeftArrowPressed = false;
  bool _isEscPressed = false;

  Uint8List? _previewImage;

  // Auto-hide controls timer
  Timer? _autoHideTimer;
  static const Duration _autoHideDelay = Duration(seconds: 5);

  void _updateSeekPreview(double value) {
    final settings = Provider.of<SettingsService>(context, listen: false);
    if (!settings.enableSeekPreview) {
      _previewImage = null;
      return;
    }

    final path = widget.controller.dataSource;
    // Basic check to ensure we are dealing with a file path
    String filePath = path;
    if (path.startsWith('file://')) {
      try {
        filePath = Uri.parse(path).toFilePath();
      } catch (e) {
        // Fallback or ignore
      }
    } else if (path.startsWith('http')) {
      // Skip network streams for performance
      return;
    }

    VideoPreviewService().requestPreview(filePath, value.toInt()).then((data) {
      if (mounted && _isDraggingProgress && (data != null)) {
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
   }

   @override
   void dispose() {
     _focusNode.dispose();
     _keyboardLongPressTimer?.cancel();
     _singleTapTimer?.cancel();
     _seekResetTimer?.cancel();
     _seekDebounceTimer?.cancel();
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

  // Handle Key Events
  KeyEventResult handleKeyEvent(FocusNode node, KeyEvent event) {
    // If we don't have focus, we shouldn't handle keys here (let them bubble)
    // BUT for video player, we want to capture keys even if sidebar is clicked.
    // The issue is that clicking the sidebar moves focus to the sidebar or its items.
    
    if (widget.isLocked) return KeyEventResult.ignored;

    final key = event.logicalKey;
    bool isTargetKey = key == LogicalKeyboardKey.space || 
                       key == LogicalKeyboardKey.arrowRight || 
                       key == LogicalKeyboardKey.arrowLeft ||
                       key == LogicalKeyboardKey.escape;

    if (!isTargetKey) return KeyEventResult.ignored;

    // If focus is in a TextField, don't intercept space/arrows
    if (FocusManager.instance.primaryFocus?.context?.widget is EditableText) {
      return KeyEventResult.ignored;
    }

    if (event is KeyRepeatEvent) {
      return KeyEventResult.handled;
    }

    if (event is KeyDownEvent) {
      if (key == LogicalKeyboardKey.space && !_isSpacePressed) {
        _isSpacePressed = true;
        _wasPlayingBeforeLongPress = widget.controller.value.isPlaying;
        _startKeyboardLongPressTimer(() {
           _startZoneLongPress(2.0); 
        });
      } else if (key == LogicalKeyboardKey.arrowRight && !_isRightArrowPressed) {
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
          // Right Arrow Tap -> Fast Forward
          _seekRelative(widget.doubleTapSeekSeconds);
        });
      } else if (key == LogicalKeyboardKey.arrowLeft) {
        _isLeftArrowPressed = false;
        // Left Arrow Tap -> Rewind
        // Left Long press doesn't have a timer start, so it will always be treated as tap here
        _seekRelative(-widget.doubleTapSeekSeconds);
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
      // Use widget.longPressSpeed as requested by user to sync with settings
      // The speedMultiplier param here is just a placeholder if we wanted override
      // But user said: "sync with android settings"
      
      // Store current speed before increasing
      _preLongPressSpeed = widget.controller.value.playbackSpeed;

      // We simulate the feedback text logic
      setState(() {
        _isLongPressingZone = true;
        _zoneFeedbackText = "${widget.longPressSpeed}X 速";
      });
      widget.onSpeedUpdate(widget.longPressSpeed);
      
      // Haptic feedback not needed on PC
  }

  void _endZoneLongPress() {
      if (!_isLongPressingZone) return;
      setState(() {
        _isLongPressingZone = false;
        _zoneFeedbackText = "";
      });
      widget.onSpeedUpdate(_preLongPressSpeed); // Restore speed
  }
  bool _isSpeedUpMode = false; // Track if current zone action is speed up (long press) or seek (double tap)

  // Accumulated Seek Logic
  Timer? _seekResetTimer;
  int _subtitleSeekAccumulator = 0;
  Duration? _initialSeekPosition;
  Timer? _seekDebounceTimer;
  final List<int> _subtitleStartMs = <int>[];

  // -- initState and dispose moved to top of file --
  
  Future<void> _initVolumeBrightness() async {
    try {
      if (Platform.isAndroid || Platform.isIOS) {
        _currentBrightness = await ScreenBrightness().application;
      } else {
        _currentBrightness = 0.5;
      }
      _currentVolume = widget.controller.value.volume;
      // Initialize last volume
      if (_currentVolume > 0) {
        _lastPlayerVolume = _currentVolume;
      }
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

    if (_subtitleStartMs.isNotEmpty && (_subtitleStartMs.first != first || _subtitleStartMs.last != last)) {
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
    final newPos = widget.controller.value.position + Duration(seconds: seconds);
    final total = widget.controller.value.duration;
    final clamped = newPos < Duration.zero ? Duration.zero : (newPos > total ? total : newPos);
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
    if (!widget.controller.value.isInitialized || widget.isLocked) return;
    // 互斥：如果正在长按加速（或显示双击反馈），则不响应滑动
    if (_isLongPressingZone) return;

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
      _isGestureSeeking = true;
      _gestureTargetTime = widget.controller.value.position;
      _isGestureCanceling = false;
      _showControls = true;
    });
    
    // Reset auto-hide timer during gesture
    _startAutoHideTimer();
  }

  void _onHorizontalDragUpdate(DragUpdateDetails details, BuildContext context) {
    if (!_isGestureSeeking || widget.isLocked || _dragStartPosition == null) return;
    if (_isLongPressingZone) return; // Double check

    final double offsetX = details.globalPosition.dx - _dragStartPosition!.dx;
    final int secondsToAdd = (offsetX / 10).round(); 
    
    final Duration newTime = widget.controller.value.position + Duration(seconds: secondsToAdd);
    
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
      
      final diff = _gestureTargetTime.inSeconds - widget.controller.value.position.inSeconds;
      _gestureDiffText = diff > 0 ? "+${diff}s" : "${diff}s";
      
      _isGestureCanceling = isInCancelArea;
    });
  }

  void _onHorizontalDragEnd(DragEndDetails details) {
    if (!_isGestureSeeking) return;

    if (!_isGestureCanceling && !widget.isLocked) {
      _seekTo(_gestureTargetTime);
    }

    setState(() {
      _isGestureSeeking = false;
      _isGestureCanceling = false;
      _showControls = false; // Auto hide controls after seek
      _dragStartPosition = null;
    });
    
    // Cancel auto-hide timer since controls are hidden
    _cancelAutoHideTimer();
  }

  void _handleDoubleTap(Offset localPosition, double width) {
    if (widget.isLocked) return;

    final dx = localPosition.dx;
    final isLeft = dx < width * 0.2; // 20%
    final isRight = dx > width * 0.8; // 20%
    final settings = Provider.of<SettingsService>(context, listen: false);
    final Duration subtitleOffset = settings.subtitleOffset;

    // Center Double Tap: Play/Pause
    if (!isLeft && !isRight) {
      widget.onTogglePlay();
      // Hide controls immediately after double-tap play/pause
      setState(() {
        _showControls = false;
      });
      return;
    }

    // Side Double Tap: Seek
    final int seconds = widget.doubleTapSeekSeconds;
    final currentPos = widget.controller.value.position;
    final duration = widget.controller.value.duration;

    Duration target = Duration.zero;

    // Subtitle Seek Logic with Accumulation
    if (widget.enableDoubleTapSubtitleSeek && widget.subtitles.isNotEmpty) {
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
       if (nextSubIndex > widget.subtitles.length) nextSubIndex = widget.subtitles.length;
       
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
          if (initialPosMs < widget.subtitles[currentSubIndex].startTime.inMilliseconds + 500) {
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
          
          feedback = "上一句${_subtitleSeekAccumulator < -1 ? " x${_subtitleSeekAccumulator.abs()}" : ""}";
       } else {
          // Positive (Right)
          // Pivot is usually "Current" or "Prev". Next is pivot + 1?
          // If inside X: Next is X+1.
          // If gap X...X+1: Next is X+1.
          
          // So if we are at pivotIndex, next start is pivotIndex + 1.
          targetIndex = pivotIndex + _subtitleSeekAccumulator;
          
          feedback = "下一句${_subtitleSeekAccumulator > 1 ? " x$_subtitleSeekAccumulator" : ""}";
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
       
       _zoneFeedbackText = feedback;
       
       // Start Reset Timer (2 seconds to chain commands)
       _seekResetTimer = Timer(const Duration(milliseconds: 2000), () {
          _subtitleSeekAccumulator = 0;
          _initialSeekPosition = null;
       });

    } else {
        // Standard Seek Logic
        if (localPosition.dx < width / 2) {
          target = currentPos - Duration(seconds: seconds);
          _zoneFeedbackText = "-${seconds}s";
        } else {
          target = currentPos + Duration(seconds: seconds);
          _zoneFeedbackText = "+${seconds}s";
        }
    }

    if (target < Duration.zero) target = Duration.zero;
    if (target > duration) target = duration;

    // Debounce/Throttle Seek to prevent UI lag
    _seekDebounceTimer?.cancel();
    _seekDebounceTimer = Timer(const Duration(milliseconds: 30), () {
        _seekTo(target);
    });

    setState(() {
      _isLongPressingZone = true;
      _isSpeedUpMode = false;
      _tapPosition = localPosition;
    });
    
    // Auto-hide feedback logic
    Future.delayed(const Duration(milliseconds: 2000), () {
      if (mounted && !_isGestureSeeking && (_seekResetTimer == null || !_seekResetTimer!.isActive)) {
        setState(() {
          _isLongPressingZone = false;
        });
      }
    });
  }

  void _handleZoneLongPressStart(Offset localPosition, double width) {
    if (widget.isLocked) return;
    
    // Allow long press anywhere on the screen
    // final dx = localPosition.dx;
    // final isLeft = dx < width * 0.2;
    // final isRight = dx > width * 0.8;

    // if (!isLeft && !isRight) return;

    setState(() {
      _isLongPressingZone = true;
      _isSpeedUpMode = true;
      _tapPosition = localPosition;
      _zoneFeedbackText = "${widget.longPressSpeed}x 速";
      _preLongPressSpeed = widget.controller.value.playbackSpeed; // 记录当前速度
      
      // 强制结束任何可能存在的滑动状态
      if (_isGestureSeeking) {
        _isGestureSeeking = false;
        _isGestureCanceling = false;
        _dragStartPosition = null;
      }
      _isAdjustingBrightness = false;
      _isAdjustingVolume = false;
    });
    
    widget.controller.setPlaybackSpeed(widget.longPressSpeed); // 直接设置临时速度
  }

  void _handleZoneLongPressEnd(LongPressEndDetails details) {
    if (!_isLongPressingZone) return;
    
    setState(() {
      _isLongPressingZone = false;
    });
    widget.controller.setPlaybackSpeed(_preLongPressSpeed); // 恢复之前的速度
  }

  // Vertical Drag for Volume/Brightness
  void _onVerticalDragStart(DragStartDetails details, double width) async {
    if (widget.isLocked) return; // Prevent global drag if locked
    if (_isLongPressingZone) return; // 互斥

    final dx = details.localPosition.dx;
    
    if (dx < width * 0.2) {
      // Brightness (Left 20%) - Only on mobile
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
      }
    } else if (dx > width * 0.8) {
        // Volume (Right 20%) - Only on mobile
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
        }
      }
    
    // Reset auto-hide timer during gesture
    if (_isAdjustingBrightness || _isAdjustingVolume) {
      _startAutoHideTimer();
    }
  }

  void _onVerticalDragUpdate(DragUpdateDetails details, double height) {
    if (widget.isLocked) return;
    if (_isLongPressingZone) return; // 互斥
    if (!_isAdjustingBrightness && !_isAdjustingVolume) return;

    // Delta Y is positive when dragging down, negative when dragging up.
    // We want dragging UP to increase value.
    final double delta = -details.primaryDelta! / height; // Sensitivity depends on height
    // Multiplier for sensitivity
    final double change = delta * 1.5; 

    setState(() {
      if (_isAdjustingBrightness && (Platform.isAndroid || Platform.isIOS)) {
        _currentBrightness = (_currentBrightness + change).clamp(0.0, 1.0);
        ScreenBrightness().setApplicationScreenBrightness(_currentBrightness);
      } else if (_isAdjustingVolume && (Platform.isAndroid || Platform.isIOS)) {
        // System Volume Control (Gesture)
        _currentVolume = (_currentVolume + change).clamp(0.0, 1.0);
        VolumeController.instance.setVolume(_currentVolume);
        // Do NOT update widget.controller.setVolume (Software Gain)
        // Do NOT update _sliderVolume
      }
    });
  }

  void _onVerticalDragEnd(DragEndDetails details) {
    setState(() {
      _isAdjustingBrightness = false;
      _isAdjustingVolume = false;
      _showControls = false; // Auto hide controls after adjustment
    });
    
    // Cancel auto-hide timer since controls are hidden
    _cancelAutoHideTimer();
  }

  void _handleSmartTap(double width) {
    final now = DateTime.now();
    bool isDoubleTap = false;

    // Re-request focus on any tap within the player area to restore keyboard shortcuts
    if (mounted) (widget.focusNode ?? _focusNode).requestFocus();

    if (_lastTapTime != null && 
        now.difference(_lastTapTime!) < const Duration(milliseconds: 300)) {
      // Check distance to confirm it's a double tap and not two separate taps far apart
      if (_tapPosition != null && _lastTapDownPosition != null && 
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
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final height = constraints.maxHeight;
        final isSmallScreen = width < 600;
        
        // Define sizes based on screen size
        final double iconSize = isSmallScreen ? 18 : 24;
        final double bigIconSize = isSmallScreen ? 28 : 32;
        final double lockIconSize = isSmallScreen ? 20 : 32;
        final double topBarPadding = isSmallScreen ? 4 : 8;
        final double bottomBarPadding = isSmallScreen ? 8 : 16;
        final double bottomBarVerticalPadding = isSmallScreen ? 8 : 24;
        final settings = Provider.of<SettingsService>(context);
        final bool isLeftHandedMode = settings.isLeftHandedMode;
        final Alignment timeAlignment = isLeftHandedMode ? Alignment.centerRight : Alignment.centerLeft;
        final Alignment toolsAlignment = isLeftHandedMode ? Alignment.centerLeft : Alignment.centerRight;
        final List<Widget> topLeading = [
          if (!kIsWeb && Platform.isWindows) ...[
            IconButton(
              icon: const Icon(Icons.close, color: Colors.white),
              tooltip: "退出播放",
              onPressed: () {
                _startAutoHideTimer();
                (widget.onExitPressed ?? widget.onBackPressed)();
              },
              iconSize: iconSize,
            ),
            const SizedBox(width: 8),
          ],
          IconButton(
            icon: const Icon(Icons.arrow_back, color: Colors.white),
            onPressed: () {
              _startAutoHideTimer();
              widget.onBackPressed();
            },
            iconSize: iconSize,
          ),
        ];
        final List<Widget> topTrailing = [
          if (widget.onOpenSettings != null)
            IconButton(
              icon: const Icon(Icons.settings, color: Colors.white),
              onPressed: () {
                _startAutoHideTimer();
                widget.onOpenSettings!();
              },
              iconSize: iconSize,
            ),
          if (widget.onToggleFloatingSubtitleSettings != null)
            IconButton(
              icon: const Icon(Icons.style, color: Colors.white),
              tooltip: "悬浮字幕设置",
              onPressed: () {
                _startAutoHideTimer();
                widget.onToggleFloatingSubtitleSettings!();
              },
              iconSize: iconSize,
            ),
          IconButton(
            icon: const Icon(Icons.open_with, color: Colors.white),
            tooltip: "移动字幕",
            onPressed: () {
              _startAutoHideTimer();
              widget.onMoveSubtitles();
            },
            iconSize: iconSize,
          ),
          if (widget.onToggleSidebar != null)
            IconButton(
              icon: Icon(
                widget.isSubtitleSidebarVisible ? Icons.menu_open : Icons.menu,
                color: Colors.white,
              ),
              tooltip: widget.isSubtitleSidebarVisible ? "隐藏字幕边栏" : "显示字幕边栏",
              onPressed: () {
                _startAutoHideTimer();
                widget.onToggleSidebar!();
              },
              iconSize: iconSize,
            ),
          if (!kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux))
            IconButton(
              icon: Icon(
                settings.isFullScreen
                    ? Icons.fullscreen_exit
                    : Icons.fullscreen,
                color: Colors.white,
              ),
              tooltip: settings.isFullScreen ? "退出全屏" : "全屏",
              onPressed: () {
                _startAutoHideTimer();
                widget.onToggleFullScreen!();
              },
              iconSize: iconSize,
            ),
        ];

        return Focus(
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
                  TapGestureRecognizer: GestureRecognizerFactoryWithHandlers<TapGestureRecognizer>(
                    () => TapGestureRecognizer(),
                    (TapGestureRecognizer instance) {
                      instance.onTapDown = (details) {
                         final RenderBox box = context.findRenderObject() as RenderBox;
                         final localOffset = box.globalToLocal(details.globalPosition);
                         _tapPosition = localOffset;
                      };
                      instance.onTap = () {
                        _handleSmartTap(width);
                      };
                    },
                  ),
                  // DoubleTapGestureRecognizer removed to eliminate delay
                  LongPressGestureRecognizer: GestureRecognizerFactoryWithHandlers<LongPressGestureRecognizer>(
                    // Android long press standard is 500ms, user requested "slightly longer than click"
                    // 350ms feels responsive without being too quick to trigger accidentally during slow clicks
                    () => LongPressGestureRecognizer(duration: const Duration(milliseconds: 350)),
                    (LongPressGestureRecognizer instance) {
                      instance.onLongPressStart = (details) {
                         final RenderBox box = context.findRenderObject() as RenderBox;
                         final localOffset = box.globalToLocal(details.globalPosition);
                         
                         // Always trigger long press speed up
                         _handleZoneLongPressStart(localOffset, width);
                      };
                      instance.onLongPressMoveUpdate = (details) {
                         if (_isLongPressingZone) return;
                         // Center long press seek removed in favor of Horizontal Drag
                      };
                      instance.onLongPressEnd = (details) {
                         if (_isLongPressingZone) {
                           _handleZoneLongPressEnd(details);
                         }
                      };
                    },
                  ),
                  VerticalDragGestureRecognizer: GestureRecognizerFactoryWithHandlers<VerticalDragGestureRecognizer>(
                    () => VerticalDragGestureRecognizer(),
                    (VerticalDragGestureRecognizer instance) {
                      instance.onStart = (details) => _onVerticalDragStart(details, width);
                      instance.onUpdate = (details) => _onVerticalDragUpdate(details, height);
                      instance.onEnd = (details) => _onVerticalDragEnd(details);
                    },
                  ),
                  HorizontalDragGestureRecognizer: GestureRecognizerFactoryWithHandlers<HorizontalDragGestureRecognizer>(
                    () => HorizontalDragGestureRecognizer(),
                    (HorizontalDragGestureRecognizer instance) {
                      instance.onStart = (details) => _onHorizontalDragStart(details, width);
                      instance.onUpdate = (details) => _onHorizontalDragUpdate(details, context);
                      instance.onEnd = (details) => _onHorizontalDragEnd(details);
                    },
                  ),
                },
                behavior: HitTestBehavior.translucent,
                child: Stack(
                  children: [
                    // Transparent container to catch hits in empty areas
                    Container(color: Colors.transparent),

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
                          onLongPress: widget.onEnterSubtitleDragMode,
                          isGestureOnly: true,
                        ),
                      ),

                    // Visual Feedback Elements (Zone, Seek, Brightness/Volume, Cancel Area)
                    // These are non-interactive visuals driven by state
                    
                    // Zone Feedback (Double Tap / Long Press)
                    if (_isLongPressingZone && _tapPosition != null)
                       Positioned(
                         left: _tapPosition!.dx <= width / 2 ? 40 : null,
                         right: _tapPosition!.dx > width / 2 ? 40 : null,
                         top: height / 2 - 30,
                         child: Container(
                           padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                           decoration: BoxDecoration(
                             color: Colors.black54,
                             borderRadius: BorderRadius.circular(8),
                           ),
                           child: Row(
                             children: [
                               Icon(
                                 _tapPosition!.dx < width / 2 
                                     ? (_isSpeedUpMode ? Icons.fast_forward : Icons.fast_rewind) 
                                     : Icons.fast_forward, 
                                 color: Colors.white
                               ),
                               const SizedBox(width: 8),
                               Text(
                                 _zoneFeedbackText,
                                 style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                               ),
                             ],
                           ),
                         ),
                       ),

                    // Gesture Seek Feedback (Center)
                    if (_isGestureSeeking && !widget.isLocked && !_isLongPressingZone)
                      Center(
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
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
                                const Icon(Icons.undo, color: Colors.white, size: 48),
                                const SizedBox(height: 8),
                                const Text("松手取消跳转", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                              ] else ...[
                                Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      _gestureDiffText.startsWith('+') ? Icons.fast_forward : Icons.fast_rewind,
                                      color: Colors.white70,
                                      size: 32,
                                    ),
                                    const SizedBox(width: 8),
                                    Text(
                                      _gestureDiffText,
                                      style: const TextStyle(color: Colors.blueAccent, fontSize: 24, fontWeight: FontWeight.bold),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  "${_formatDuration(_gestureTargetTime)} / ${_formatDuration(widget.controller.value.duration)}",
                                  style: const TextStyle(color: Colors.white, fontSize: 16),
                                ),
                              ]
                            ],
                          ),
                        ),
                      ),
                    
                    // Brightness/Volume Feedback (Center)
                    if ((_isAdjustingBrightness || _isAdjustingVolume) && !widget.isLocked)
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
                                _isAdjustingBrightness ? Icons.brightness_6 : Icons.volume_up,
                                color: Colors.white,
                                size: 48,
                              ),
                              const SizedBox(height: 12),
                              LinearProgressIndicator(
                                value: _isAdjustingBrightness ? _currentBrightness : _currentVolume,
                                backgroundColor: Colors.white24,
                                valueColor: const AlwaysStoppedAnimation<Color>(Colors.blueAccent),
                                minHeight: 6,
                              ),
                              const SizedBox(height: 8),
                              Text(
                                "${((_isAdjustingBrightness ? _currentBrightness : _currentVolume) * 100).toInt()}%",
                                style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                              ),
                            ],
                          ),
                        ),
                      ),

                    // Seek Cancel Area Highlight
                    if ((_isGestureSeeking || _isDraggingProgress) && !widget.isLocked)
                       Positioned(
                         top: 0, left: 0, right: 0,
                         height: height * 0.25,
                         child: Container(
                           color: (_isGestureCanceling || _isProgressDragCanceling) 
                               ? Colors.red.withValues(alpha: 0.3) 
                               : Colors.white.withValues(alpha: 0.1),
                           alignment: Alignment.center,
                           child: Text(
                             (_isGestureCanceling || _isProgressDragCanceling) ? "松手取消" : "上滑至此区域取消", 
                             style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)
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
            if (_showControls || widget.isLocked)
              Positioned(
                left: isLeftHandedMode ? null : (isSmallScreen ? 12 : 20),
                right: isLeftHandedMode ? (isSmallScreen ? 12 : 20) : null,
                top: height / 2 - (lockIconSize / 2 + (isSmallScreen ? 8 : 12)), 
                child: IconButton(
                  onPressed: () {
                    _startAutoHideTimer();
                    widget.onToggleLock();
                  },
                  icon: Icon(
                    widget.isLocked ? Icons.lock : Icons.lock_open,
                    color: widget.isLocked ? Colors.blueAccent : Colors.white54,
                    size: lockIconSize,
                  ),
                  style: IconButton.styleFrom(
                    backgroundColor: Colors.black45,
                    padding: EdgeInsets.all(isSmallScreen ? 8 : 12),
                  ),
                ),
              ),

            // Top Controls
            if (_showControls && !widget.isLocked) ...[
              Positioned(
                top: 0, left: 0, right: 0,
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onTap: () {
                    // Reset auto-hide timer when any control is tapped
                    _startAutoHideTimer();
                  },
                  child: Container(
                    padding: EdgeInsets.symmetric(horizontal: isSmallScreen ? 8 : 16, vertical: topBarPadding),
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter, end: Alignment.bottomCenter,
                        colors: [Colors.black54, Colors.transparent],
                      ),
                    ),
                    child: Row(
                      children: [
                        if (isLeftHandedMode) ...topTrailing else ...topLeading,
                        const Spacer(),
                        if (isLeftHandedMode) ...topLeading else ...topTrailing,
                      ],
                    ),
                  ),
                ),
              ),

              // Bottom Controls (Progress & Time)
              if (widget.showBottomBar)
              Positioned(
                bottom: 0, left: 0, right: 0,
                child: GestureDetector(
                  onHorizontalDragStart: (_) {}, // Consume horizontal drag to prevent conflict
                  onTap: () {
                    // Reset auto-hide timer when bottom controls are tapped
                    _startAutoHideTimer();
                  },
                  child: Container(
                    padding: EdgeInsets.symmetric(
                      horizontal: bottomBarPadding, 
                      vertical: bottomBarVerticalPadding
                    ),
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.bottomCenter, end: Alignment.topCenter,
                        colors: [Colors.black87, Colors.transparent],
                      ),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        AnimatedBuilder(
                          animation: widget.controller,
                          builder: (context, child) {
                            final position = widget.controller.value.position;
                            final duration = widget.controller.value.duration;
                            final isInitialized = widget.controller.value.isInitialized && duration.inMilliseconds > 0;
                            
                            final currentPosition = _isDraggingProgress 
                                ? Duration(milliseconds: _dragProgressValue.toInt()) 
                                : position;
                            
                            final sliderMax = isInitialized ? duration.inMilliseconds.toDouble() : 1.0;
                            final sliderValue = isInitialized 
                                ? currentPosition.inMilliseconds.toDouble().clamp(0.0, sliderMax)
                                : 0.0;

                            return Column(
                              children: [
                                // Progress Bar (Slider)
                                LayoutBuilder(
                                  builder: (context, sliderConstraints) {
                                    return Stack(
                                      clipBehavior: Clip.none,
                                      alignment: Alignment.bottomLeft,
                                      children: [
                                        // Seek Preview Overlay
                                        if (_isDraggingProgress && _previewImage != null)
                                          Positioned(
                                            left: () {
                                              final double width = sliderConstraints.maxWidth;
                                              final double pct = sliderMax > 0 ? sliderValue / sliderMax : 0;
                                              // Center the 160px preview on the thumb
                                              double left = (width * pct) - 80;
                                              // Clamp to edges
                                              if (left < 0) left = 0;
                                              if (left + 160 > width) left = width - 160;
                                              return left;
                                            }(),
                                            bottom: 40,
                                            child: Column(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                Container(
                                                  width: 160,
                                                  height: 90,
                                                  decoration: BoxDecoration(
                                                    color: Colors.black,
                                                    border: Border.all(color: Colors.white70, width: 1.5),
                                                    borderRadius: BorderRadius.circular(8),
                                                    boxShadow: const [BoxShadow(color: Colors.black45, blurRadius: 4)],
                                                  ),
                                                  child: ClipRRect(
                                                    borderRadius: BorderRadius.circular(6),
                                                    child: Image.memory(
                                                      _previewImage!,
                                                      fit: BoxFit.cover,
                                                      gaplessPlayback: true,
                                                    ),
                                                  ),
                                                ),
                                                const SizedBox(height: 4),
                                                Container(
                                                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                                  decoration: BoxDecoration(
                                                    color: Colors.black54,
                                                    borderRadius: BorderRadius.circular(4),
                                                  ),
                                                  child: Text(
                                                    _formatDuration(Duration(milliseconds: sliderValue.toInt())),
                                                    style: const TextStyle(color: Colors.white, fontSize: 12),
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),

                                        Listener(
                                          behavior: HitTestBehavior.translucent,
                                          onPointerMove: (event) {
                                            if (!_isDraggingProgress || widget.isLocked) return;
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
                                              _previewImage = null;
                                              _isProgressDragCanceling = false;
                                            });
                                          },
                                          child: SizedBox(
                                            height: 40, // Ensure enough height for hit testing
                                            child: SliderTheme(
                                              data: SliderTheme.of(context).copyWith(
                                                activeTrackColor: _isProgressDragCanceling ? Colors.grey : const Color(0xFF0D47A1),
                                                inactiveTrackColor: Colors.white24,
                                                thumbColor: isInitialized ? (_isProgressDragCanceling ? Colors.grey : const Color(0xFF1565C0)) : Colors.grey,
                                                overlayColor: const Color(0x291565C0),
                                                thumbShape: RoundSliderThumbShape(enabledThumbRadius: isSmallScreen ? 4.0 : 6.0),
                                                trackHeight: isSmallScreen ? 2.0 : 4.0,
                                                overlayShape: const RoundSliderOverlayShape(overlayRadius: 10), // Reduced overlay to fit
                                              ),
                                              child: Slider(
                                                min: 0.0,
                                                max: sliderMax,
                                                value: sliderValue,
                                                onChanged: isInitialized ? (newValue) {
                                                  setState(() {
                                                    _isDraggingProgress = true;
                                                    _dragProgressValue = newValue;
                                                  });
                                                  _updateSeekPreview(newValue);
                                                  // Reset auto-hide timer while dragging
                                                  _startAutoHideTimer();
                                                } : null,
                                                onChangeEnd: (newValue) {
                                                  if (!_isProgressDragCanceling) {
                                                    _seekTo(Duration(milliseconds: newValue.toInt()));
                                                  }
                                                  setState(() {
                                                    _isDraggingProgress = false;
                                                    _previewImage = null;
                                                    _isProgressDragCanceling = false;
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
                                // Removed SizedBox(height: 4) to reduce gap
                                // Bottom Controls Row
                                SizedBox(
                                  height: bigIconSize * 1.5, // Adaptive height
                                  child: Stack(
                                    children: [
                                      // Left: Time
                                      Align(
                                        alignment: timeAlignment,
                                        child: Text(
                                          "${_formatDuration(currentPosition)} / ${_formatDuration(duration)}",
                                          style: TextStyle(color: Colors.white, fontSize: isSmallScreen ? 10 : 12),
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
                                            if (widget.onPlayPrevious != null) ...[
                                              IconButton(
                                                iconSize: bigIconSize,
                                                icon: Icon(
                                                  Icons.skip_previous,
                                                  color: widget.hasPrevious ? Colors.white : Colors.white38,
                                                ),
                                                onPressed: widget.hasPrevious ? () {
                                                  _startAutoHideTimer();
                                                  widget.onPlayPrevious!();
                                                } : null,
                                                tooltip: "上一集",
                                              ),
                                              const SizedBox(width: 8),
                                            ],

                                            // Seek Backward Button with Dynamic Number
                                            InkWell(
                                              onTap: () {
                                                if (!widget.controller.value.isInitialized) return;
                                                _startAutoHideTimer();
                                                final newPos = widget.controller.value.position - Duration(seconds: widget.doubleTapSeekSeconds);
                                                _seekTo(newPos < Duration.zero ? Duration.zero : newPos);
                                              },
                                              borderRadius: BorderRadius.circular(20),
                                              child: SizedBox(
                                                width: bigIconSize + 8, 
                                                height: bigIconSize + 8,
                                                child: Stack(
                                                  alignment: Alignment.center,
                                                  children: [
                                                    Icon(Icons.replay, color: widget.controller.value.isInitialized ? Colors.white : Colors.white38, size: bigIconSize * 0.75),
                                                    Text(
                                                      "${widget.doubleTapSeekSeconds}",
                                                      style: TextStyle(
                                                        color: widget.controller.value.isInitialized ? Colors.white : Colors.white38, 
                                                        fontSize: 8, 
                                                        fontWeight: FontWeight.bold
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                            ),
                                            const SizedBox(width: 8),
                                            IconButton(
                                              iconSize: bigIconSize, 
                                              icon: Icon(
                                                widget.controller.value.isPlaying ? Icons.pause_circle_filled : Icons.play_circle_fill,
                                                color: widget.controller.value.isInitialized ? Colors.white : Colors.white38,
                                              ),
                                              onPressed: widget.controller.value.isInitialized ? () {
                                                _startAutoHideTimer();
                                                widget.onTogglePlay();
                                              } : null,
                                            ),
                                            const SizedBox(width: 8),
                                            // Seek Forward Button with Dynamic Number
                                            InkWell(
                                              onTap: () {
                                                if (!widget.controller.value.isInitialized) return;
                                                _startAutoHideTimer();
                                                final newPos = widget.controller.value.position + Duration(seconds: widget.doubleTapSeekSeconds);
                                                final duration = widget.controller.value.duration;
                                                _seekTo(newPos > duration ? duration : newPos);
                                              },
                                              borderRadius: BorderRadius.circular(20),
                                              child: SizedBox(
                                                width: bigIconSize + 8, 
                                                height: bigIconSize + 8,
                                                child: Stack(
                                                  alignment: Alignment.center,
                                                  children: [
                                                    // Transform to flip the replay icon horizontally to make it look like forward
                                                    Transform(
                                                      alignment: Alignment.center,
                                                      transform: Matrix4.rotationY(3.14159),
                                                      child: Icon(Icons.replay, color: widget.controller.value.isInitialized ? Colors.white : Colors.white38, size: bigIconSize * 0.75),
                                                    ),
                                                    Text(
                                                      "${widget.doubleTapSeekSeconds}",
                                                      style: TextStyle(
                                                        color: widget.controller.value.isInitialized ? Colors.white : Colors.white38, 
                                                        fontSize: 8, 
                                                        fontWeight: FontWeight.bold
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                            ),

                                            // Next Episode
                                            if (widget.onPlayNext != null) ...[
                                              const SizedBox(width: 8),
                                              IconButton(
                                                iconSize: bigIconSize,
                                                icon: Icon(
                                                  Icons.skip_next,
                                                  color: widget.hasNext ? Colors.white : Colors.white38,
                                                ),
                                                onPressed: widget.hasNext ? () {
                                                  _startAutoHideTimer();
                                                  widget.onPlayNext!();
                                                } : null,
                                                tooltip: "下一集",
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
                                            PopupMenuButton<double>(
                                              initialValue: widget.controller.value.playbackSpeed,
                                              tooltip: "倍速",
                                              onSelected: (speed) {
                                                _startAutoHideTimer();
                                                widget.onSpeedUpdate(speed);
                                              },
                                              constraints: const BoxConstraints(maxHeight: 400), // Limit height to ensure scrolling behavior is obvious
                                              itemBuilder: (context) => [0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 2.5, 3.0, 4.0, 5.0].map((speed) {
                                                return PopupMenuItem<double>(
                                                  value: speed,
                                                  child: Text("${speed}x"),
                                                );
                                              }).toList(),
                                              child: Padding(
                                                padding: const EdgeInsets.symmetric(horizontal: 8),
                                                child: Text(
                                                  "${widget.controller.value.playbackSpeed}x",
                                                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                                                ),
                                              ),
                                            ),

                                            IconButton(
                                              icon: Icon(
                                                widget.showSubtitles ? Icons.subtitles : Icons.subtitles_off,
                                                color: widget.showSubtitles ? Colors.blueAccent : Colors.white70,
                                              ),
                                              onPressed: () {
                                                _startAutoHideTimer();
                                                widget.onToggleSubtitles();
                                              },
                                              tooltip: "字幕开关",
                                            ),

                                            IconButton(
                                              icon: Icon(
                                                widget.controller.value.volume == 0 ? Icons.volume_off : Icons.volume_up,
                                                color: widget.controller.value.volume == 0 ? Colors.redAccent : Colors.white,
                                              ),
                                              onPressed: () {
                                                _startAutoHideTimer();
                                                setState(() {
                                                  if (widget.controller.value.volume > 0) {
                                                    // Mute
                                                    _lastPlayerVolume = widget.controller.value.volume;
                                                    widget.controller.setVolume(0.0);
                                                  } else {
                                                    // Unmute
                                                    widget.controller.setVolume(_lastPlayerVolume > 0 ? _lastPlayerVolume : 1.0);
                                                  }
                                                });
                                              },
                                              tooltip: widget.controller.value.volume == 0 ? "取消静音" : "静音",
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            );
                          },
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      );
    }
    );
  }
}
