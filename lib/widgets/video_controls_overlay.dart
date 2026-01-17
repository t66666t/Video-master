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

class VideoControlsOverlay extends StatefulWidget {
  final VideoPlayerController controller;
  final bool isLocked; 
  final VoidCallback onTogglePlay;
  final VoidCallback onBackPressed;
  final VoidCallback? onExitPressed; // New: For Windows direct exit
  final VoidCallback? onToggleSidebar;
  final VoidCallback? onOpenSettings;
  final VoidCallback onToggleLock; 
  final VoidCallback? onToggleFullScreen; // New: For desktop full screen toggle
  final ValueChanged<double> onSpeedUpdate;
  final int doubleTapSeekSeconds;
  final bool enableDoubleTapSubtitleSeek;
  final List<SubtitleItem> subtitles;
  final double longPressSpeed;
  final bool showSubtitles;
  final VoidCallback onToggleSubtitles;
  final VoidCallback onMoveSubtitles; // New callback for move subtitles

  // Subtitle Dragging Passthrough
  final String subtitleText;
  final String? secondarySubtitleText; // New: Secondary text
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
    this.onOpenSettings,
    required this.onToggleLock,
    this.onToggleFullScreen,
    required this.onSpeedUpdate,
    this.doubleTapSeekSeconds = 5,
    this.enableDoubleTapSubtitleSeek = true,
    this.subtitles = const [],
    this.longPressSpeed = 2.0,
    required this.showSubtitles,
    required this.onToggleSubtitles,
    required this.onMoveSubtitles, // New parameter
    required this.subtitleText,
    this.secondarySubtitleText,
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

  @override
   void initState() {
     super.initState();
     _initVolumeBrightness();
     // Auto request focus to enable keyboard listening
     WidgetsBinding.instance.addPostFrameCallback((_) {
       if (mounted) {
         (widget.focusNode ?? _focusNode).requestFocus();
       }
     });
   }

   @override
   void dispose() {
     _focusNode.dispose();
     _keyboardLongPressTimer?.cancel();
     _singleTapTimer?.cancel();
     _seekResetTimer?.cancel();
     _seekDebounceTimer?.cancel();
     super.dispose();
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
        widget.controller.play();
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

  // -- initState and dispose moved to top of file --
  
  Future<void> _initVolumeBrightness() async {
    try {
      if (Platform.isAndroid || Platform.isIOS) {
        _currentBrightness = await ScreenBrightness().current;
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

  // Helper for keyboard seek
  void _seekRelative(int seconds) {
    if (!widget.controller.value.isInitialized) return;
    final newPos = widget.controller.value.position + Duration(seconds: seconds);
    final total = widget.controller.value.duration;
    final clamped = newPos < Duration.zero ? Duration.zero : (newPos > total ? total : newPos);
    widget.controller.seekTo(clamped);
    
    // Show feedback (optional, reusing gesture UI or similar)
    // For now just seek
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
      widget.controller.seekTo(_gestureTargetTime);
    }

    setState(() {
      _isGestureSeeking = false;
      _isGestureCanceling = false;
      _showControls = false; // Auto hide controls after seek
      _dragStartPosition = null;
    });
  }

  void _handleDoubleTap(Offset localPosition, double width) {
    if (widget.isLocked) return;

    final dx = localPosition.dx;
    final isLeft = dx < width * 0.2; // 20%
    final isRight = dx > width * 0.8; // 20%

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
       // Reset or Init Accumulator
       if (_seekResetTimer?.isActive ?? false) {
          _seekResetTimer?.cancel();
       } else {
          // New seek sequence started
          _subtitleSeekAccumulator = 0;
          _initialSeekPosition = currentPos;
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
       int baseIndex = -1;
       
       // Find subtitle at or just before _initialSeekPosition
       for (int i = 0; i < widget.subtitles.length; i++) {
          final sub = widget.subtitles[i];
          if (sub.startTime <= _initialSeekPosition! && sub.endTime >= _initialSeekPosition!) {
             // Inside a subtitle
             // If we are deep inside (>500ms), this counts as "Current".
             // If we are at start (<500ms), this counts as "Previous" relative to index i+1?
             // Actually, let's simplify:
             // If inside sub i:
             //   Left -> Start of i (Accumulator -1)
             //   Left again -> Start of i-1 (Accumulator -2)
             
             // Wait, the accumulator logic needs to map to indices.
             // Let "0" be the current playback moment.
             baseIndex = i;
             
             // Special case: If we are just starting this subtitle (< 500ms), 
             // "Left" should imply going to previous one immediately?
             // The user said: "If I double tap twice... it keeps resetting to current... I want it to go back to previous"
             
             // If we are at start of i, treat "Current" as i-1 effectively for the first jump?
             if (_initialSeekPosition! < sub.startTime + const Duration(milliseconds: 500)) {
                // We are at start of i.
                // A "Left" (-1) should go to i-1.
                // So effective base is i. But the jump logic below will handle it.
             }
             break;
          }
          if (sub.startTime > _initialSeekPosition!) {
             // We are in a gap before sub i.
             // So "Current" context is effectively gap between i-1 and i.
             // Left (-1) -> Start of i-1.
             // Right (+1) -> Start of i.
             baseIndex = i; // Let's say next is i.
             // Adjust base logic below.
             break;
          }
       }
       
       if (baseIndex == -1) {
          // After last subtitle?
          baseIndex = widget.subtitles.length;
       }
       
       // Logic to resolve Accumulator to Target Index
       int targetIndex = -1;
       String feedback = "";
       
       // Re-evaluate base index more robustly
       // We want to find "Current/Next" boundary
       int nextSubIndex = widget.subtitles.indexWhere((s) => s.startTime > _initialSeekPosition!);
       if (nextSubIndex == -1) nextSubIndex = widget.subtitles.length;
       
       // Current Subtitle Index (if inside one)
       int currentSubIndex = widget.subtitles.indexWhere((s) => s.startTime <= _initialSeekPosition! && s.endTime >= _initialSeekPosition!);
       
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
          if (_initialSeekPosition! < widget.subtitles[currentSubIndex].startTime + const Duration(milliseconds: 500)) {
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
          
          feedback = "下一句${_subtitleSeekAccumulator > 1 ? " x${_subtitleSeekAccumulator}" : ""}";
       }
       
       // Clamping
       if (targetIndex < 0) {
          target = Duration.zero;
          feedback = "开头";
       } else if (targetIndex >= widget.subtitles.length) {
          target = duration;
          feedback = "结尾";
       } else {
          target = widget.subtitles[targetIndex].startTime;
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
    _seekDebounceTimer = Timer(const Duration(milliseconds: 100), () {
        widget.controller.seekTo(target);
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
          _startDragValue = await ScreenBrightness().current;
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
        ScreenBrightness().setScreenBrightness(_currentBrightness);
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
                      Align(
                        alignment: widget.subtitleAlignment,
                        child: SubtitleOverlay(
                          text: widget.subtitleText,
                          secondaryText: widget.secondarySubtitleText,
                          style: widget.subtitleStyle,
                          onLongPress: widget.onEnterSubtitleDragMode,
                          isGestureOnly: true, // Invisible but handles gestures
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
                                ? Colors.red.withOpacity(0.8)
                                : Colors.black.withOpacity(0.7),
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
                            color: Colors.black.withOpacity(0.7),
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
                    if (_isGestureSeeking && !_isGestureCanceling && !widget.isLocked)
                       Positioned(
                         top: 0, left: 0, right: 0,
                         height: height * 0.2,
                         child: Container(
                           color: Colors.white.withOpacity(0.1),
                           alignment: Alignment.center,
                           child: const Text("上滑至此区域取消", style: TextStyle(color: Colors.white70)),
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
                left: isSmallScreen ? 12 : 20,
                top: height / 2 - (lockIconSize / 2 + (isSmallScreen ? 8 : 12)), 
                child: IconButton(
                  onPressed: widget.onToggleLock,
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
                      if (!kIsWeb && Platform.isWindows) ...[
                        IconButton(
                          icon: const Icon(Icons.close, color: Colors.white),
                          tooltip: "退出播放",
                          onPressed: widget.onExitPressed ?? widget.onBackPressed,
                          iconSize: iconSize,
                        ),
                        const SizedBox(width: 8),
                      ],
                      IconButton(
                        icon: const Icon(Icons.arrow_back, color: Colors.white),
                        onPressed: widget.onBackPressed,
                        iconSize: iconSize,
                      ),
                      const Spacer(),
                      // Clean Screen Button
                      IconButton(
                        icon: const Icon(Icons.visibility_off, color: Colors.white),
                        tooltip: "隐藏控制栏",
                        onPressed: () => setState(() => _showControls = false),
                        iconSize: iconSize,
                      ),
                      if (widget.onOpenSettings != null)
                        IconButton(
                          icon: const Icon(Icons.settings, color: Colors.white),
                          onPressed: widget.onOpenSettings,
                          iconSize: iconSize,
                        ),
                      // Move Subtitle Button
                      IconButton(
                        icon: const Icon(Icons.open_with, color: Colors.white),
                        tooltip: "移动字幕",
                        onPressed: widget.onMoveSubtitles,
                        iconSize: iconSize,
                      ),
                      if (widget.onToggleSidebar != null)
                        IconButton(
                          icon: const Icon(Icons.subtitles, color: Colors.white),
                          onPressed: widget.onToggleSidebar,
                          iconSize: iconSize,
                        ),
                      if (!kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux))
                        IconButton(
                          icon: Icon(
                            Provider.of<SettingsService>(context).isFullScreen 
                                ? Icons.fullscreen_exit 
                                : Icons.fullscreen, 
                            color: Colors.white
                          ),
                          tooltip: Provider.of<SettingsService>(context).isFullScreen ? "退出全屏" : "全屏",
                          onPressed: widget.onToggleFullScreen,
                          iconSize: iconSize,
                        ),
                    ],
                  ),
                ),
              ),

              // Bottom Controls (Progress & Time)
              if (widget.showBottomBar)
              Positioned(
                bottom: 0, left: 0, right: 0,
                child: GestureDetector(
                  onHorizontalDragStart: (_) {}, // Consume horizontal drag to prevent conflict
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
                                SizedBox(
                                  height: 40, // Ensure enough height for hit testing
                                  child: SliderTheme(
                                    data: SliderTheme.of(context).copyWith(
                                      activeTrackColor: const Color(0xFF0D47A1),
                                      inactiveTrackColor: Colors.white24,
                                      thumbColor: isInitialized ? const Color(0xFF1565C0) : Colors.grey,
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
                                      } : null,
                                      onChangeEnd: (newValue) {
                                        widget.controller.seekTo(Duration(milliseconds: newValue.toInt()));
                                        setState(() {
                                          _isDraggingProgress = false;
                                        });
                                      },
                                    ),
                                  ),
                                ),
                                // Removed SizedBox(height: 4) to reduce gap
                                // Bottom Controls Row
                                SizedBox(
                                  height: bigIconSize * 1.5, // Adaptive height
                                  child: Stack(
                                    children: [
                                      // Left: Time
                                      Align(
                                        alignment: Alignment.centerLeft,
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
                                                onPressed: widget.hasPrevious ? widget.onPlayPrevious : null,
                                                tooltip: "上一集",
                                              ),
                                              const SizedBox(width: 8),
                                            ],

                                            // Seek Backward Button with Dynamic Number
                                            InkWell(
                                              onTap: () {
                                                if (!widget.controller.value.isInitialized) return;
                                                final newPos = widget.controller.value.position - Duration(seconds: widget.doubleTapSeekSeconds);
                                                widget.controller.seekTo(newPos < Duration.zero ? Duration.zero : newPos);
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
                                              onPressed: widget.controller.value.isInitialized ? widget.onTogglePlay : null,
                                            ),
                                            const SizedBox(width: 8),
                                            // Seek Forward Button with Dynamic Number
                                            InkWell(
                                              onTap: () {
                                                if (!widget.controller.value.isInitialized) return;
                                                final newPos = widget.controller.value.position + Duration(seconds: widget.doubleTapSeekSeconds);
                                                final duration = widget.controller.value.duration;
                                                widget.controller.seekTo(newPos > duration ? duration : newPos);
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
                                                onPressed: widget.hasNext ? widget.onPlayNext : null,
                                                tooltip: "下一集",
                                              ),
                                            ],
                                          ],
                                        ),
                                      ),
                                      
                                      // Right: Tools (Speed, Subtitles, Volume)
                                      Align(
                                        alignment: Alignment.centerRight,
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            PopupMenuButton<double>(
                                              initialValue: widget.controller.value.playbackSpeed,
                                              tooltip: "倍速",
                                              onSelected: widget.onSpeedUpdate,
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
                                              onPressed: widget.onToggleSubtitles,
                                              tooltip: "字幕开关",
                                            ),

                                            IconButton(
                                              icon: Icon(
                                                widget.controller.value.volume == 0 ? Icons.volume_off : Icons.volume_up,
                                                color: widget.controller.value.volume == 0 ? Colors.redAccent : Colors.white,
                                              ),
                                              onPressed: () {
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
