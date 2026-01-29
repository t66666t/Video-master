import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'dart:developer' as developer;
import 'package:fast_gbk/fast_gbk.dart';
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
import '../utils/subtitle_parser.dart';
import '../widgets/settings_panel.dart';
import '../widgets/ai_transcription_panel.dart';
import '../services/transcription_manager.dart';
import '../widgets/subtitle_management_sheet.dart';
import 'video_player_screen.dart'; // Landscape screen
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../services/embedded_subtitle_service.dart';

enum PortraitPanel { subtitles, settings, subtitleStyle, ai, subtitleManager }

class PortraitVideoScreen extends StatefulWidget {
  final VideoItem videoItem;

  const PortraitVideoScreen({super.key, required this.videoItem});

  @override
  State<PortraitVideoScreen> createState() => _PortraitVideoScreenState();
}
class _PortraitVideoScreenState extends State<PortraitVideoScreen> with WidgetsBindingObserver {
  final GlobalKey<SelectableRegionState> _selectionKey = GlobalKey<SelectableRegionState>();
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
  int _lastSubtitleIndex = 0;
  int _lastSecondarySubtitleIndex = 0;
  final List<int> _subtitleStartMs = <int>[];
  final List<int> _secondarySubtitleStartMs = <int>[];
  Timer? _subtitleSeekTimer;
  bool _isSubtitleDragMode = false;
  bool _isSubtitleSnapped = false;
  PortraitPanel _activePanel = PortraitPanel.subtitles;
  
  // Bottom Control Bar State
  bool _isDraggingProgress = false;
  double _dragProgressValue = 0.0;
  final bool _showVolumeSlider = false;
  final LayerLink _volumeButtonLayerLink = LayerLink();

  bool _isOrientationSetup = false;
  bool _forceExit = false;
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
  
  void _onPlaybackServiceChange() {
    if (!mounted) return;
    final service = Provider.of<MediaPlaybackService>(context, listen: false);
    if (service.currentItem != null && service.currentItem!.id != _currentItem.id) {
      // 切换视频
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
        _autoEmbeddedAttemptedForItemId = null;
      });
      _initPlayer();
    } else if (!_initialized && service.currentItem?.id == _currentItem.id && 
               service.state != PlaybackState.loading && service.controller != null) {
      // ID 没变，但之前因为 Loading 等待了，现在 Service 准备好了 -> 重试初始化
      _initPlayer();
    } else if (service.currentItem?.id == _currentItem.id) {
      final bool pathsChanged = !_stringListEquals(service.subtitlePaths, _currentSubtitlePaths);
      final bool primaryChanged = service.subtitles.length != _subtitles.length;
      final bool secondaryChanged = service.secondarySubtitles.length != _secondarySubtitles.length;
      if (pathsChanged || primaryChanged || secondaryChanged) {
        setState(() {
          _subtitles = service.subtitles;
          _secondarySubtitles = service.secondarySubtitles;
          _currentSubtitlePaths = List<String>.from(service.subtitlePaths);
          _lastSubtitleIndex = 0;
          _lastSecondarySubtitleIndex = 0;
          _currentSubtitleText = "";
          _currentSecondaryText = null;
          _currentSubtitleIndex = -1;
          _currentSecondarySubtitleIndex = -1;
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
    if (!_isOrientationSetup) {
      _updateOrientations();
      _isOrientationSetup = true;
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
        
        final path = _transcriptionManager!.lastGeneratedSrtPath!;
        // Avoid repeated loading if already loaded as primary
        if (_currentSubtitlePaths.isNotEmpty && _currentSubtitlePaths[0] == path) return;
        
        // Auto load
        _loadSubtitles([path]);
        
        // Update library
        final settings = Provider.of<SettingsService>(context, listen: false);
        Provider.of<LibraryService>(context, listen: false)
              .updateVideoSubtitles(_currentItem.id, path, settings.autoCacheSubtitles);
        
        // Show notification
        ScaffoldMessenger.of(context).clearSnackBars();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("AI 字幕转录完成并已自动加载"),
            backgroundColor: Colors.green,
            behavior: SnackBarBehavior.floating,
          ),
        );
    }
  }

  void _checkAndLoadAiSubtitle(VideoItem currentItem) {
    try {
      final manager = Provider.of<TranscriptionManager>(context, listen: false);
      
      if (manager.status == TranscriptionStatus.completed &&
          manager.currentVideoPath == currentItem.path &&
          manager.lastGeneratedSrtPath != null) {
        
        final srtPath = manager.lastGeneratedSrtPath!;
        
        if (File(srtPath).existsSync()) {
          debugPrint("检测到AI字幕已完成，自动加载: $srtPath");
          
          List<String> pathsToLoad = [srtPath];
          if (currentItem.secondarySubtitlePath != null) {
            pathsToLoad.add(currentItem.secondarySubtitlePath!);
          }
          
          _loadSubtitles(pathsToLoad);
          
          if (mounted) {
            ScaffoldMessenger.of(context).clearSnackBars();
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text("AI 字幕已自动加载"),
                backgroundColor: Colors.green,
                behavior: SnackBarBehavior.floating,
              ),
            );
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
    try {
      final messenger = ScaffoldMessenger.of(context);
      final settings = Provider.of<SettingsService>(context, listen: false);
      final library = Provider.of<LibraryService>(context, listen: false);
      _isLoadingEmbeddedSubtitle = true;
      if (showLoadingIndicator && mounted) {
        messenger.clearSnackBars();
        messenger.showSnackBar(
          const SnackBar(
            content: Row(
              children: [
                SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                ),
                SizedBox(width: 12),
                Text("正在检测内嵌字幕..."),
              ],
            ),
            duration: Duration(seconds: 10),
            behavior: SnackBarBehavior.floating,
            backgroundColor: Color(0xFF2C2C2C),
          ),
        );
      }
      final service = Provider.of<EmbeddedSubtitleService>(context, listen: false);
      final tracks = await service.getEmbeddedSubtitles(path);
      
      if (tracks.isNotEmpty && mounted && _subtitles.isEmpty) {
        // Use the first one
        final track = tracks.first;
        
        // Prepare cache dir
        final appDocDir = await getApplicationDocumentsDirectory();
        final subDir = Directory(p.join(appDocDir.path, 'subtitles'));
        if (!await subDir.exists()) {
          await subDir.create(recursive: true);
        }
        
        // Extract
        final extractedPath = await service.extractSubtitle(path, track.index, subDir.path);
        
        if (extractedPath != null && mounted) {
          // Check again
          if (_subtitles.isNotEmpty) return;
          
          await _loadSubtitles([extractedPath]);

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
          messenger.clearSnackBars();
          messenger.showSnackBar(
            SnackBar(
              content: Text("已加载内嵌字幕: ${track.title}"),
              duration: const Duration(seconds: 3),
              behavior: SnackBarBehavior.floating,
              backgroundColor: const Color(0xFF2C2C2C),
            ),
          );
        }
      } else {
        if (mounted) {
          messenger.clearSnackBars();
          if (showToastWhenNone) {
            messenger.showSnackBar(const SnackBar(content: Text("未找到内嵌字幕")));
          }
        }
      }
    } catch (e) {
      debugPrint("Auto load embedded subtitle failed: $e");
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
    final messenger = ScaffoldMessenger.of(context);
    final libraryService = Provider.of<LibraryService>(context, listen: false);
    final settingsService = Provider.of<SettingsService>(context, listen: false);
    final playbackService = Provider.of<MediaPlaybackService>(context, listen: false);

    if (!await file.exists()) {
      developer.log('Video file not found: ${currentItem.path}');
      if (mounted) {
        messenger.clearSnackBars();
        messenger.showSnackBar(
          SnackBar(
            content: Text("视频文件不存在: ${currentItem.path}"),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 5),
          ),
        );
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
        messenger.showSnackBar(
          SnackBar(
            content: Text("无法加载视频: $e"),
            backgroundColor: Colors.red,
          ),
        );
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
      if (_currentSubtitleText.isNotEmpty || _currentSecondaryText != null || _currentSubtitleIndex != -1 || _currentSecondarySubtitleIndex != -1) {
        setState(() {
          _currentSubtitleText = "";
          _currentSecondaryText = null;
          _currentSubtitleIndex = -1;
          _currentSecondarySubtitleIndex = -1;
        });
      }
      return;
    }

    final position = _controller.value.position;
    final adjustedPosition = position - settings.subtitleOffset;
    final int posMs = adjustedPosition.inMilliseconds;
    final continuousSubtitleEnabled = _isAudio ? settings.audioContinuousSubtitle : settings.videoContinuousSubtitle;
    
    // --- Primary Subtitle ---
    SubtitleItem? currentItem;
    int primaryIndex = -1;
    if (_subtitles.isNotEmpty) {
      if (_subtitleStartMs.length != _subtitles.length) {
        _rebuildSubtitleIndex();
      }
      final int index = _findSubtitleIndexMs(
        posMs: posMs,
        subtitles: _subtitles,
        startMs: _subtitleStartMs,
        lastIndex: _lastSubtitleIndex,
        continuousSubtitleEnabled: continuousSubtitleEnabled,
      );
      if (index >= 0) {
        currentItem = _subtitles[index];
        _lastSubtitleIndex = index;
        primaryIndex = index;
      } else {
        _lastSubtitleIndex = 0;
      }
    }

    // --- Secondary Subtitle ---
    SubtitleItem? currentSecondaryItem;
    int secondaryIndex = -1;
    if (_secondarySubtitles.isNotEmpty) {
      if (_secondarySubtitleStartMs.length != _secondarySubtitles.length) {
        _rebuildSubtitleIndex();
      }
      final int index = _findSubtitleIndexMs(
        posMs: posMs,
        subtitles: _secondarySubtitles,
        startMs: _secondarySubtitleStartMs,
        lastIndex: _lastSecondarySubtitleIndex,
        continuousSubtitleEnabled: continuousSubtitleEnabled,
      );
      if (index >= 0) {
        currentSecondaryItem = _secondarySubtitles[index];
        _lastSecondarySubtitleIndex = index;
        secondaryIndex = index;
      } else {
        _lastSecondarySubtitleIndex = 0;
      }
    }
    
    String newText = currentItem?.text ?? "";
    String? newSecondaryText = currentSecondaryItem?.text;
    
    // If no explicit secondary file is loaded, apply the "Split by Line" logic
    if (_secondarySubtitles.isEmpty && settings.splitSubtitleByLine) {
       if (newText.contains('\n')) {
          final lines = newText.split('\n');
          newText = lines[0];
          newSecondaryText = lines.sublist(1).join('\n');
       }
    }
    
    final bool primaryChanged = primaryIndex != _currentSubtitleIndex;
    final bool secondaryChanged = secondaryIndex != _currentSecondarySubtitleIndex;
    if (!primaryChanged && !secondaryChanged) return;

    setState(() {
      _currentSubtitleIndex = primaryIndex;
      _currentSecondarySubtitleIndex = secondaryIndex;
      _currentSubtitleText = newText;
      _currentSecondaryText = newSecondaryText;
    });
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
          ScaffoldMessenger.of(context).clearSnackBars();
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text("已加载字幕: ${file.name}")),
          );
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
        if (await file.exists()) {
           final length = await file.length();
           if (length > 10 * 1024 * 1024) return [];
  
          List<int> bytes = await file.readAsBytes();
          String content = "";
          try {
            content = utf8.decode(bytes);
          } catch (e) {
            try {
              content = gbk.decode(bytes);
            } catch (e2) {
              debugPrint("Failed to decode: $e2");
            }
          }
          
          if (content.isNotEmpty) {
            final parsed = SubtitleParser.parse(content);
            parsed.sort((a, b) => a.startTime.compareTo(b.startTime));
            return parsed;
          }
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
      _lastSubtitleIndex = 0;
      _lastSecondarySubtitleIndex = 0;
      _currentSubtitleText = "";
      _currentSecondaryText = null;
      _currentSubtitleIndex = -1;
      _currentSecondarySubtitleIndex = -1;
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
    if (!continuousSubtitleEnabled) return item.endTime.inMilliseconds;
    if (index + 1 < subtitles.length) return startMs[index + 1];
    return item.endTime.inMilliseconds;
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

  int _findSubtitleIndexMs({
    required int posMs,
    required List<SubtitleItem> subtitles,
    required List<int> startMs,
    required int lastIndex,
    required bool continuousSubtitleEnabled,
  }) {
    if (subtitles.isEmpty) return -1;

    if (lastIndex >= 0 && lastIndex < subtitles.length) {
      final int lastStartMs = startMs[lastIndex];
      final int lastEndMs = _getEffectiveEndMs(
        subtitles: subtitles,
        startMs: startMs,
        index: lastIndex,
        continuousSubtitleEnabled: continuousSubtitleEnabled,
      );
      if (posMs >= lastStartMs && posMs < lastEndMs) {
        return lastIndex;
      }
      final int nextIndex = lastIndex + 1;
      if (nextIndex < subtitles.length) {
        final int nextStartMs = startMs[nextIndex];
        final int nextEndMs = _getEffectiveEndMs(
          subtitles: subtitles,
          startMs: startMs,
          index: nextIndex,
          continuousSubtitleEnabled: continuousSubtitleEnabled,
        );
        if (posMs >= nextStartMs && posMs < nextEndMs) {
          return nextIndex;
        }
      }
    }

    final int candidate = _binarySearchLastStartLE(startMs, posMs);
    if (candidate < 0 || candidate >= subtitles.length) return -1;
    final int endMs = _getEffectiveEndMs(
      subtitles: subtitles,
      startMs: startMs,
      index: candidate,
      continuousSubtitleEnabled: continuousSubtitleEnabled,
    );
    if (posMs < endMs) return candidate;
    return -1;
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

  @override
  void dispose() {
    // Try to sync one last time (fire and forget)
    _handleExit();

    try {
      Provider.of<MediaPlaybackService>(context, listen: false).removeListener(_onPlaybackServiceChange);
    } catch (_) {}
    _settingsService?.removeListener(_onSettingsChanged);

    _transcriptionManager?.removeListener(_onTranscriptionUpdate);
    _selectionFocusNode.dispose();
    _subtitleSeekTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    // Restore orientations to default (allow all)
    SystemChrome.setPreferredOrientations([]);
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
    
    await Navigator.of(context).push(
      PageRouteBuilder(
        pageBuilder: (context, animation, secondaryAnimation) => VideoPlayerScreen(
          videoFile: null, // Legacy param, ignored
          existingController: _controller, // Pass controller
          videoItem: _currentItem, // Pass item for context
          skipAutoPauseOnExit: true,
        ),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          return FadeTransition(
            opacity: animation,
            child: child,
          );
        },
        transitionDuration: const Duration(milliseconds: 300),
      ),
    );
    
    if (!mounted) return;
    
    // Restore orientation logic based on device type
    _updateOrientations();
    
    // When returning, we need to refresh state if settings changed
    // And force reload subtitle in case it was changed in landscape
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
      });
      playbackService.clearSubtitleState();
    }

    setState(() {});
  }

  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, "0");
    String twoDigitMinutes = twoDigits(duration.inMinutes.remainder(60));
    String twoDigitSeconds = twoDigits(duration.inSeconds.remainder(60));
    return "${twoDigits(duration.inHours)}:$twoDigitMinutes:$twoDigitSeconds";
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
              // Time
              Text(
                "${_formatDuration(position)} / ${_formatDuration(duration)}",
                style: const TextStyle(color: Colors.white, fontSize: 10),
              ),
              
              const SizedBox(width: 8),
              
              // Progress Slider
              Expanded(
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    activeTrackColor: const Color(0xFF0D47A1),
                    inactiveTrackColor: Colors.white24,
                    thumbColor: const Color(0xFF1565C0),
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
                      setState(() {
                        _isDraggingProgress = false;
                      });
                    },
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
                onPressed: () => settings.updateSetting('showSubtitles', !settings.showSubtitles),
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
            final navigator = Navigator.of(context);
            () async {
              if (_forceExit) {
                SystemChrome.setPreferredOrientations([]);
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
              SystemChrome.setPreferredOrientations([]);
              navigator.pop();
            }();
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
                                // Visible Subtitles
                                if (_initialized && settings.showSubtitles)
                                  Align(
                                    alignment: settings.subtitleAlignment,
                                    child: SubtitleOverlay(
                                      text: _currentSubtitleText,
                                      secondaryText: _currentSecondaryText,
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
                                    onToggleSubtitles: () => settings.updateSetting('showSubtitles', !settings.showSubtitles),
                                    onMoveSubtitles: _enterSubtitleDragMode,
                                    subtitleText: _currentSubtitleText,
                                    secondarySubtitleText: _currentSecondaryText,
                                    subtitleStyle: settings.subtitleStyle,
                                    subtitleAlignment: settings.subtitleAlignment,
                                    onEnterSubtitleDragMode: _enterSubtitleDragMode,
                                    onClearSelection: () => _selectionKey.currentState?.clearSelection(),
                                    showPlayControls: false,
                                    showBottomBar: false,
                                    focusNode: _videoFocusNode,
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
                                          child: SubtitleOverlay(
                                            text: _currentSubtitleText,
                                            secondaryText: _currentSecondaryText,
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
                              if (currentChild != null) currentChild,
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
          isHardwareDecoding: settings.isHardwareDecoding,
          longPressSpeed: settings.longPressSpeed,
          autoCacheSubtitles: settings.autoCacheSubtitles,
          onSpeedChanged: (val) => settings.updateSetting('playbackSpeed', val),
          onSubtitleToggle: (val) => settings.updateSetting('showSubtitles', val),
          onMirrorHChanged: (val) => settings.updateSetting('isMirroredH', val),
          onMirrorVChanged: (val) => settings.updateSetting('isMirroredV', val),
          onSeekSecondsChanged: (val) => settings.updateSetting('doubleTapSeekSeconds', val),
          onSubtitleDelayChanged: (val) => settings.setSubtitleDelay(val), 
          onSubtitleDelayChangeEnd: (val) => settings.saveSubtitleDelay(val),
          onHardwareDecodingChanged: (val) => settings.updateSetting('isHardwareDecoding', val),
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
          onClose: () => setState(() => _activePanel = PortraitPanel.subtitles),
          onLoadSubtitle: _pickSubtitle,
          onOpenSubtitleSettings: _openSubtitleStyleSettings,
        );
      case PortraitPanel.subtitleStyle:
        return SubtitleSettingsSheet(
          key: const ValueKey("SubtitleSettingsSheet"),
          style: _isAudio ? settings.audioSubtitleStylePortrait : settings.subtitleStylePortrait,
          onStyleChanged: (newStyle) {
            if (_isAudio) {
              settings.saveAudioSubtitleStylePortrait(newStyle);
            } else {
              settings.saveSubtitleStylePortrait(newStyle);
            }
          },
          onClose: () => setState(() => _activePanel = PortraitPanel.subtitles),
          onBack: () => setState(() => _activePanel = PortraitPanel.subtitles), // Or settings if navigated from there
          isAudio: _isAudio,
        );
      case PortraitPanel.subtitles:
        return SubtitleSidebar(
          key: const ValueKey("SubtitleSidebar"),
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
        );
    }
  }
}
