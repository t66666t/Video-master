import 'package:ffmpeg_kit_flutter_min_gpl/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_min_gpl/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_min_gpl/return_code.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'dart:io';
import 'dart:typed_data';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';
import 'package:cross_file/cross_file.dart'; 
import 'package:file_picker/file_picker.dart';
import 'package:fast_gbk/fast_gbk.dart';
import 'package:permission_handler/permission_handler.dart';
import 'dart:convert';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import '../services/embedded_subtitle_service.dart';
import '../services/media_playback_service.dart';
import '../services/playlist_manager.dart';
import '../utils/subtitle_parser.dart';
import '../utils/pgs_parser.dart';
import '../utils/subtitle_converter.dart';
import '../models/subtitle_model.dart';
import '../models/subtitle_style.dart';
import '../models/video_item.dart';
import '../services/settings_service.dart';
import '../services/library_service.dart';
import '../widgets/subtitle_overlay.dart';
import '../widgets/video_controls_overlay.dart';
import '../widgets/settings_panel.dart'; 
import '../widgets/subtitle_settings_sheet.dart';
import '../widgets/subtitle_sidebar.dart';
import '../widgets/subtitle_position_sidebar.dart';
import '../widgets/subtitle_management_sheet.dart';
import '../widgets/ai_transcription_panel.dart';
import '../services/transcription_manager.dart';

enum SidebarType { none, subtitles, settings, subtitleStyle, subtitlePosition, subtitleManager, aiTranscription }

class VideoPlayerScreen extends StatefulWidget {
  final XFile? videoFile; // Optional now
  final VideoPlayerController? existingController; // New
  final VideoItem? videoItem; // New

  const VideoPlayerScreen({
    super.key, 
    this.videoFile,
    this.existingController,
    this.videoItem,
  });

  @override
  State<VideoPlayerScreen> createState() => _VideoPlayerScreenState();
}

class _VideoPlayerScreenState extends State<VideoPlayerScreen> {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  final GlobalKey<SelectableRegionState> _selectionKey = GlobalKey<SelectableRegionState>();
  final FocusNode _selectionFocusNode = FocusNode();
  final FocusNode _videoFocusNode = FocusNode(); // New: Dedicated focus node for video controls
  late VideoPlayerController _controller;
  bool _initialized = false;
  bool _isPlaying = false;
  bool _isControllerOwner = true; // Track ownership
  
  // Local UI State
  bool _isLocked = false;
  
  // Sidebar
  SidebarType _activeSidebar = SidebarType.none;
  SidebarType _previousSidebarType = SidebarType.none;
  bool get _isSidebarOpen => _activeSidebar != SidebarType.none;
  bool _isResizingSidebar = false;
  bool _forceExit = false;
  
  double _getSidebarWidth(BuildContext context, SettingsService settings) {
    if (_activeSidebar == SidebarType.subtitles) {
      return settings.userSubtitleSidebarWidth;
    }
    if (_activeSidebar == SidebarType.subtitlePosition && _isGhostDragMode) {
      // Add resizer width (12.0) to match total visual width of subtitle sidebar
      return settings.userSubtitleSidebarWidth + 12.0;
    }
    final screenWidth = MediaQuery.of(context).size.width;
    final isSmallScreen = screenWidth < 600;
    return isSmallScreen ? (screenWidth * 0.75).clamp(240.0, 300.0) : 320.0;
  }
  
  // Subtitles
  List<SubtitleItem> _subtitles = [];
  List<SubtitleItem> _secondarySubtitles = []; // New: Secondary subtitle list
  List<String> _currentSubtitlePaths = []; // Track loaded paths
  String _currentSubtitleText = "";
  String? _currentSecondaryText; // New: Secondary text state
  Uint8List? _currentSubtitleImage;
  SubtitleItem? _currentSubtitleItem; // Track current item to avoid reloading images
  int _lastSubtitleIndex = 0;
  int _lastSecondarySubtitleIndex = 0; // New: Secondary index tracking
  
  // Subtitle Positioning Mode
  bool _isSubtitleDragMode = false;
  bool _isGhostDragMode = false;
  bool _isSubtitleSnapped = false;
  
  // Repair state
  bool _isRepairing = false;
  double _repairProgress = 0.0;
  
  // Audio state
  bool _isAudio = false;
  
  // Embedded subtitle loading state
  bool _isLoadingEmbeddedSubtitle = false;
  bool _hasCheckedEmbeddedSubtitles = false;
  
  TranscriptionManager? _transcriptionManager;
  VideoItem? _currentItem;

  @override
  void initState() {
    super.initState();
    _currentItem = widget.videoItem;
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    
    if (Platform.isWindows) {
      _activeSidebar = SidebarType.subtitles;
    } else if (Platform.isAndroid) {
      // 请求通知权限
      Permission.notification.request();
    }

    _initVideo();
    
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        Provider.of<MediaPlaybackService>(context, listen: false).addListener(_onPlaybackServiceChange);
      }
    });
  }
  
  void _onPlaybackServiceChange() {
    if (!mounted) return;
    final service = Provider.of<MediaPlaybackService>(context, listen: false);
    
    // Debug Log
    debugPrint("VideoPlayerScreen: _onPlaybackServiceChange. Service Item: ${service.currentItem?.title}, State: ${service.state}");
    
    // 如果服务中的 currentItem 发生变化，且不是当前播放的项
    if (service.currentItem != null && 
        (_currentItem == null || service.currentItem!.id != _currentItem!.id)) {
      
      debugPrint("VideoPlayerScreen: Detected video change. New: ${service.currentItem!.title}");
      
      setState(() {
        _currentItem = service.currentItem;
        _initialized = false;
        _isPlaying = false; // Reset play state until init
        _subtitles = [];
        _currentSubtitleText = "";
        // Do not reset _isControllerOwner here. Let _initVideo handle it.
        // Otherwise we might accidentally dispose the service controller if we exit before init completes.
      });
      
      // Stop old controller if we owned it
      if (_isControllerOwner && _initialized) { // Check _initialized to avoid double dispose if we just reset it
         // Actually _initVideo handles disposal if it creates new one? 
         // But _initVideo logic is complex.
         // Let's just call _initVideo, it should handle re-assignment.
         // Wait, _initVideo checks "existingController". That's from widget.
         // We need to make sure _initVideo prefers _currentItem from service if available.
      }
      
      // Clean up old controller listener before re-init?
      // _initVideo attaches listener.
      // If we reuse controller, we don't want double listeners.
      _controller.removeListener(_videoListener);
      
      _initVideo();
    } else if (!_initialized && service.currentItem?.id == _currentItem?.id && 
               service.state != PlaybackState.loading && service.controller != null) {
       debugPrint("VideoPlayerScreen: Service ready for current video. Re-initializing.");
       // ID 没变，但之前因为 Loading 等待了，现在 Service 准备好了 -> 重试初始化
       _initVideo();
    }
  }
  
  Future<void> _handleExit() async {
     try {
       final settings = Provider.of<SettingsService>(context, listen: false);
       final playbackService = Provider.of<MediaPlaybackService>(context, listen: false);
       
       if (settings.autoPauseOnExit && _controller.value.isPlaying) {
          await _controller.pause();
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
    
    _transcriptionManager?.removeListener(_onTranscriptionUpdate);
    // Restore orientations to default (allow all)
    SystemChrome.setPreferredOrientations([]);
    
    _selectionFocusNode.dispose();
    
    _controller.removeListener(_videoListener);
    if (_isControllerOwner) {
      _controller.dispose();
    }
    
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    
    // Listen to TranscriptionManager
    final manager = Provider.of<TranscriptionManager>(context, listen: false);
    if (_transcriptionManager != manager) {
      _transcriptionManager?.removeListener(_onTranscriptionUpdate);
      _transcriptionManager = manager;
      _transcriptionManager?.addListener(_onTranscriptionUpdate);
      
      // Check immediately in case it completed while we were away
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _onTranscriptionUpdate();
      });
    }
  }
  
  void _onTranscriptionUpdate() {
    if (!mounted || _transcriptionManager == null) return;
    
    final currentPath = widget.videoFile?.path ?? widget.videoItem?.path;
    if (currentPath == null) return;

    if (_transcriptionManager!.status == TranscriptionStatus.completed &&
        _transcriptionManager!.currentVideoPath == currentPath &&
        _transcriptionManager!.lastGeneratedSrtPath != null) {
        
        // 如果已经消费过这个结果，就不再提示
        if (_transcriptionManager!.isResultConsumed) {
           return;
        }

        final path = _transcriptionManager!.lastGeneratedSrtPath!;
        
        // 即使已加载，也要更新状态为已消费
        _transcriptionManager!.markResultConsumed();
        
        // 如果当前字幕已经是这个，就不重复加载
        if (_currentSubtitlePaths.isNotEmpty && _currentSubtitlePaths[0] == path) return;
        
        // 保留当前已加载的副字幕（如果有）
        List<String> pathsToLoad = [path];
        if (_currentSubtitlePaths.length > 1) {
          pathsToLoad.add(_currentSubtitlePaths[1]);
        }
        
        _loadSubtitles(pathsToLoad);
        
        // 不需要在这里保存，TranscriptionManager 已经保存了
        
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

  void _checkAndLoadAiSubtitle(VideoItem? currentItem) {
    if (currentItem == null) return;
    
    final currentPath = currentItem.path;
    if (currentPath.isEmpty) return;
    
    try {
      final manager = Provider.of<TranscriptionManager>(context, listen: false);
      
      if (manager.status == TranscriptionStatus.completed &&
          manager.currentVideoPath == currentPath &&
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

  // --- Auto Load Embedded Subtitles ---
  Future<void> _checkAndLoadEmbeddedSubtitle({bool showLoadingIndicator = true}) async {
    // If we already have subtitles loaded (e.g. from file), don't override
    if (_subtitles.isNotEmpty) return;
    
    // Prevent multiple concurrent checks
    if (_isLoadingEmbeddedSubtitle) return;
    
    // Determine video path
    String? path;
    if (_currentItem != null) {
      path = _currentItem!.path;
    } else if (widget.videoFile != null) {
      path = widget.videoFile!.path;
    }
    
    if (path == null) return;
    
    // Check embedded
    try {
      _isLoadingEmbeddedSubtitle = true;
      
      // Show loading indicator if requested
      if (showLoadingIndicator && mounted) {
        ScaffoldMessenger.of(context).clearSnackBars();
        ScaffoldMessenger.of(context).showSnackBar(
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
            backgroundColor: const Color(0xFF2C2C2C),
          ),
        );
      }
      
      final service = Provider.of<EmbeddedSubtitleService>(context, listen: false);
      // Note: getEmbeddedSubtitles is fast (probe only)
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
          // Check again if user loaded something while we were extracting
          if (_subtitles.isNotEmpty) return;
          
          await _loadSubtitleFromFile(extractedPath);
          
          ScaffoldMessenger.of(context).clearSnackBars();
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Row(
                children: [
                  const Icon(Icons.check_circle, color: Colors.green, size: 20),
                  const SizedBox(width: 8),
                  Expanded(child: Text("已加载内嵌字幕: ${track.title}")),
                ],
              ),
              duration: const Duration(seconds: 3),
              behavior: SnackBarBehavior.floating,
              backgroundColor: const Color(0xFF2C2C2C),
            ),
          );
        } else if (mounted && extractedPath == null) {
          // Extraction failed
          ScaffoldMessenger.of(context).clearSnackBars();
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Row(
                children: [
                  Icon(Icons.error_outline, color: Colors.orange, size: 20),
                  SizedBox(width: 8),
                  Text("内嵌字幕提取失败"),
                ],
              ),
              duration: const Duration(seconds: 2),
              behavior: SnackBarBehavior.floating,
              backgroundColor: const Color(0xFF2C2C2C),
            ),
          );
        }
      } else if (mounted && tracks.isEmpty) {
        // No embedded subtitles found
        ScaffoldMessenger.of(context).clearSnackBars();
      }
    } catch (e) {
      debugPrint("Auto load embedded subtitle failed: $e");
      if (mounted) {
        ScaffoldMessenger.of(context).clearSnackBars();
      }
    } finally {
      _isLoadingEmbeddedSubtitle = false;
      _hasCheckedEmbeddedSubtitles = true;
    }
  }

  void _initVideo() {
    // Refresh video item from library to ensure we have latest subtitle settings
    VideoItem? currentItem = _currentItem;
    if (currentItem != null) {
      try {
        final libItem = Provider.of<LibraryService>(context, listen: false).getVideo(currentItem.id);
        if (libItem != null) currentItem = libItem;
      } catch (e) {
        debugPrint("Error refreshing video item: $e");
      }
    }
    
    // Check if this is audio
    _isAudio = currentItem?.type == MediaType.audio;

    if (widget.existingController != null && _currentItem?.id == widget.videoItem?.id) {
      _controller = widget.existingController!;
      _isControllerOwner = false;
      _initialized = true;
      
      // 从 MediaPlaybackService 获取正确的播放状态，而不是直接从 controller
      // 这样可以确保状态同步（例如用户在快捷播放卡片暂停后进入播放页面）
      try {
        final playbackService = Provider.of<MediaPlaybackService>(context, listen: false);
        _isPlaying = playbackService.isPlaying;
        
        // 强制同步 controller 状态与 MediaPlaybackService 一致
        if (_isPlaying) {
          if (!_controller.value.isPlaying) _controller.play();
        } else {
          if (_controller.value.isPlaying) _controller.pause();
        }
        
        // 从 MediaPlaybackService 获取已加载的字幕
        final existingSubtitles = playbackService.subtitles;
        if (existingSubtitles.isNotEmpty) {
          setState(() {
            _subtitles = existingSubtitles;
            _lastSubtitleIndex = 0;
            _currentSubtitleText = "";
          });
        }
      } catch (e) {
        // 如果无法获取 MediaPlaybackService，回退到使用 controller 的状态
        debugPrint("无法获取 MediaPlaybackService 状态: $e");
        _isPlaying = _controller.value.isPlaying;
      }
      
      _controller.addListener(_videoListener);
      
      // 首先检查是否有刚完成的AI字幕（即使 isResultConsumed 为 true）
      _checkAndLoadAiSubtitle(currentItem);
      
      // Load subtitles if item has path
      if (currentItem?.subtitlePath != null) {
        final List<String> paths = [currentItem!.subtitlePath!];
        if (currentItem.secondarySubtitlePath != null) {
          paths.add(currentItem.secondarySubtitlePath!);
        }
        _loadSubtitles(paths);
      } else {
        // Try auto-load embedded subtitles after UI is rendered to avoid resource contention during init
        // Only if setting is enabled
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            final settings = Provider.of<SettingsService>(context, listen: false);
            if (settings.autoLoadEmbeddedSubtitles) {
              _checkAndLoadEmbeddedSubtitle();
            }
          }
        });
      }
    } else {
      // 尝试从 MediaPlaybackService 获取 controller (适用于视频切换或未传递 controller 的情况)
      bool usedService = false;
      if (currentItem != null) {
        try {
          final playbackService = Provider.of<MediaPlaybackService>(context, listen: false);
          
          // 如果 Service 正在加载此视频，等待它完成
          if (playbackService.currentItem?.id == currentItem.id && 
              playbackService.state == PlaybackState.loading) {
            debugPrint("VideoPlayerScreen: Waiting for service to load ${currentItem.title}");
            setState(() {
              _initialized = false;
              // Clear old controller if we owned it? No, keep it until new one ready or just show loading.
            });
            return;
          }

          if (playbackService.currentItem?.id == currentItem.id && playbackService.controller != null) {
             // 如果之前持有本地 controller，先释放
             if (_initialized && _isControllerOwner) {
                try {
                  _controller.removeListener(_videoListener);
                  _controller.dispose();
                } catch (e) {
                  debugPrint("Error disposing old controller: $e");
                }
             }

             _controller = playbackService.controller!;
             _isControllerOwner = false;
             
             if (mounted) {
               setState(() {
                 _initialized = true;
                 _isPlaying = playbackService.isPlaying; // 同时更新播放状态
               });
             }
             
             usedService = true;
             
             // Sync state logic
             if (_isPlaying) {
                if (!_controller.value.isPlaying) _controller.play();
             } else {
                if (_controller.value.isPlaying) _controller.pause();
             }
             
             final existingSubtitles = playbackService.subtitles;
             if (existingSubtitles.isNotEmpty) {
                setState(() {
                  _subtitles = existingSubtitles;
                  _lastSubtitleIndex = 0;
                  _currentSubtitleText = "";
                });
             }
             
             _controller.addListener(_videoListener);
             _checkAndLoadAiSubtitle(currentItem);
             
             if (currentItem.subtitlePath != null) {
                final List<String> paths = [currentItem.subtitlePath!];
                if (currentItem.secondarySubtitlePath != null) {
                   paths.add(currentItem.secondarySubtitlePath!);
                }
                _loadSubtitles(paths);
             }
          }
        } catch (e) {
          debugPrint("Check MediaPlaybackService failed: $e");
        }
      }

      if (!usedService && (widget.videoFile != null || currentItem != null)) {
        _isControllerOwner = true;
        String path = widget.videoFile?.path ?? currentItem!.path;
        
        debugPrint("=== Video Player Debug Info ===");
        debugPrint("Platform: ${Platform.operatingSystem}");
        debugPrint("Video path: $path");
        debugPrint("File exists: ${File(path).existsSync()}");
        debugPrint("File size: ${File(path).lengthSync()}");
        debugPrint("Is Windows: ${Platform.isWindows}");
        debugPrint("Is Audio: $_isAudio");
        debugPrint("===============================");
        
        if (kIsWeb) {
          _controller = VideoPlayerController.networkUrl(
            Uri.parse(path),
            videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
          );
        } else {
          _controller = VideoPlayerController.file(
            File(path),
            videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
          );
        }
        _controller.initialize().then((_) {
          if (!mounted) return;
          setState(() {
            _initialized = true;
            _controller.play();
            _isPlaying = true;
          });
          
          // 注册控制器到 MediaPlaybackService，确保通知栏控制生效
          try {
            final playbackService = Provider.of<MediaPlaybackService>(context, listen: false);
            playbackService.setController(_controller);
            
            VideoItem itemToSync = currentItem ?? VideoItem(
              id: path, 
              path: path,
              title: p.basename(path),
              durationMs: _controller.value.duration.inMilliseconds,
              lastUpdated: DateTime.now().millisecondsSinceEpoch,
              type: _isAudio ? MediaType.audio : MediaType.video,
            );
            playbackService.updateMetadata(itemToSync);
          } catch (e) {
            debugPrint("Failed to register controller with service: $e");
          }

          debugPrint("Video initialized successfully!");
          debugPrint("Duration: ${_controller.value.duration}");
          debugPrint("Size: ${_controller.value.size}");
  
          // 首先检查是否有刚完成的AI字幕（即使 isResultConsumed 为 true）
          _checkAndLoadAiSubtitle(currentItem);
  
          // Load subtitles if item has path
          if (currentItem?.subtitlePath != null) {
            final List<String> paths = [currentItem!.subtitlePath!];
            if (currentItem.secondarySubtitlePath != null) {
              paths.add(currentItem.secondarySubtitlePath!);
            }
            _loadSubtitles(paths);
          } else {
            // Try auto-load embedded subtitles after UI is rendered to avoid resource contention during init
            // Only if setting is enabled
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) {
                final settings = Provider.of<SettingsService>(context, listen: false);
                if (settings.autoLoadEmbeddedSubtitles) {
                   _checkAndLoadEmbeddedSubtitle();
                }
              }
            });
          }
        }).catchError((error) {
          debugPrint("Error initializing video: $error");
          debugPrint("Error stack trace: ${StackTrace.current}");
        });
        _controller.addListener(_videoListener);
      }
    }
  }
  
  void _videoListener() {
    if (!mounted) return;
    
    // Check for errors
    if (_controller.value.hasError && !_isRepairing) {
       final errorMsg = _controller.value.errorDescription ?? "";
       // Specific check for HevcConfig or ExoPlaybackException: Source error
       if (errorMsg.contains("HevcConfig") || errorMsg.contains("Source error") || errorMsg.contains("VideoError")) {
          // Remove listener to prevent loop
          _controller.removeListener(_videoListener);
          _showRepairDialog();
          return;
       }
    }

    final isPlaying = _controller.value.isPlaying;
    if (isPlaying != _isPlaying) {
      setState(() {
        _isPlaying = isPlaying;
      });
      
      // 始终同步播放状态到 MediaPlaybackService
      // 确保通知栏和快捷控制卡片显示正确的播放/暂停状态
      try {
        final playbackService = Provider.of<MediaPlaybackService>(context, listen: false);
        // 使用新的同步方法，避免状态检查导致的同步失败
        playbackService.updatePlaybackStateFromController();
      } catch (e) {
        debugPrint("同步播放状态失败: $e");
      }
    }
    _updateSubtitle();
  }
  
  void _showRepairDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text("播放失败"),
        content: const Text("检测到视频格式兼容性问题（HEVC配置错误）。\n是否尝试自动修复（转码为H.264）？\n注意：修复过程可能需要几分钟。"),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              Navigator.pop(context); // Exit player
            },
            child: const Text("退出播放"),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              _repairVideo();
            },
            child: const Text("尝试修复"),
          ),
        ],
      ),
    );
  }

  Future<void> _repairVideo() async {
    setState(() {
      _isRepairing = true;
      _repairProgress = 0.0;
    });
    
    String? path;
    if (_currentItem != null) {
      path = _currentItem!.path;
    } else if (widget.videoFile != null) {
      path = widget.videoFile!.path;
    }
    
    if (path == null) return;
    final String videoPath = path;
    
    final file = File(videoPath);
    final dir = file.parent;
    final filename = p.basenameWithoutExtension(videoPath);
    final ext = p.extension(videoPath);
    final outputPath = p.join(dir.path, "${filename}_repaired$ext");
    
    // Transcode to H.264 (AVC) which is widely supported
    // -preset ultrafast for speed
    // -crf 23 for decent quality
    // -c:a copy to keep audio untouched
    final command = "-y -i \"$videoPath\" -c:v libx264 -preset ultrafast -crf 23 -c:a copy \"$outputPath\"";
    
    debugPrint("Starting repair: $command");
    
    // Estimate duration for progress calculation (if available)
    int durationMs = 0;
    if (_controller.value.isInitialized) {
      durationMs = _controller.value.duration.inMilliseconds;
    } else if (_currentItem != null && _currentItem!.durationMs > 0) {
      durationMs = _currentItem!.durationMs;
    }

    // Fallback: Use FFprobe if duration is unknown
    if (durationMs == 0) {
       debugPrint("Duration unknown, probing...");
       try {
         final session = await FFprobeKit.getMediaInformation(videoPath);
         final info = session.getMediaInformation();
         if (info != null) {
            final durationStr = info.getDuration();
            if (durationStr != null) {
               final double d = double.tryParse(durationStr) ?? 0.0;
               durationMs = (d * 1000).toInt();
            }
         }
       } catch (e) {
         debugPrint("Probe failed: $e");
       }
    }

    await FFmpegKit.executeAsync(
      command, 
      (session) async {
        final returnCode = await session.getReturnCode();
        
        if (ReturnCode.isSuccess(returnCode)) {
          debugPrint("Repair success!");
          
          try {
            final originalBackup = p.join(dir.path, "${filename}_backup$ext");
            if (await File(originalBackup).exists()) {
               await File(originalBackup).delete();
            }
            await file.rename(originalBackup);
            await File(outputPath).rename(videoPath);
            
            // Delete backup if successful rename
            await File(originalBackup).delete();
            
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("修复成功，正在重新加载...")));
              setState(() => _isRepairing = false);
              // Re-init video
              _controller.dispose();
              _initVideo();
            }
          } catch (e) {
            debugPrint("File op failed: $e");
            if (mounted) {
               setState(() => _isRepairing = false);
               ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("文件替换失败: $e")));
            }
          }
        } else {
          debugPrint("Repair failed");
          final logs = await session.getAllLogsAsString();
          final logContent = logs ?? "无日志信息";
          debugPrint("FFmpeg logs: $logContent");
          
          if (mounted) {
            setState(() => _isRepairing = false);
            showDialog(
              context: context,
              builder: (ctx) => AlertDialog(
                title: const Text("修复失败"),
                content: Text("转码过程中出错。\n\n日志片段:\n${logContent.length > 500 ? logContent.substring(logContent.length - 500) : logContent}"),
                actions: [
                  TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("关闭")),
                ],
              ),
            );
          }
        }
      },
      (log) {},
      (statistics) {
        final time = statistics.getTime(); // time in ms
        if (mounted) {
          setState(() {
             if (durationMs > 0) {
               _repairProgress = (time / durationMs).clamp(0.0, 1.0);
             } else {
               // If duration is still unknown, we can't show percentage, 
               // but we can use _repairProgress to store a dummy value or just update UI elsewhere.
               // Let's use negative value to indicate "unknown percentage" or handle in UI.
               // For now, let's just update the timestamp so UI can show something if we change it.
               // But wait, _repairProgress is double. 
               // Let's just keep it 0.0 if duration is 0, but maybe update a separate string?
               // Or we can hack it: if duration is 0, _repairProgress = time / 60000.0 (just to show movement?) - No, that's confusing.
               
               // Better: Store the raw time string? 
               // Let's modify the UI to show raw time if progress is 0.0 and we have time.
               // But I only have _repairProgress state.
               
               // Let's just ensure durationMs is found. 
               // If FFprobe fails, durationMs is 0.
               // Then _repairProgress stays 0.0.
             }
          });
        }
      }
    );
  }

  void _updateSubtitle() {
    if (!_initialized) return;
    final settings = Provider.of<SettingsService>(context, listen: false);
    
    if (!settings.showSubtitles) {
      if (_currentSubtitleText.isNotEmpty) {
        setState(() => _currentSubtitleText = "");
      }
      return;
    }

    final position = _controller.value.position;
    final adjustedPosition = position - settings.subtitleOffset;
    final continuousSubtitleEnabled = _isAudio ? settings.audioContinuousSubtitle : settings.videoContinuousSubtitle;
    
    // --- Primary Subtitle ---
    SubtitleItem? currentItem;
    if (_subtitles.isNotEmpty) {
      if (_lastSubtitleIndex >= _subtitles.length || 
          (_lastSubtitleIndex > 0 && adjustedPosition < _subtitles[_lastSubtitleIndex].startTime)) {
        _lastSubtitleIndex = 0;
      }

      for (int i = _lastSubtitleIndex; i < _subtitles.length; i++) {
        final item = _subtitles[i];
        if (adjustedPosition < item.startTime) break;
        Duration effectiveEndTime = item.endTime;
        if (continuousSubtitleEnabled && i + 1 < _subtitles.length) {
          effectiveEndTime = _subtitles[i + 1].startTime;
        }
        if (adjustedPosition < effectiveEndTime) {
          currentItem = item;
          _lastSubtitleIndex = i;
          break;
        }
        _lastSubtitleIndex = i + 1;
      }
    }
    
    // --- Secondary Subtitle ---
    SubtitleItem? currentSecondaryItem;
    if (_secondarySubtitles.isNotEmpty) {
       if (_lastSecondarySubtitleIndex >= _secondarySubtitles.length ||
           (_lastSecondarySubtitleIndex > 0 && adjustedPosition < _secondarySubtitles[_lastSecondarySubtitleIndex].startTime)) {
          _lastSecondarySubtitleIndex = 0;
       }
       
       for (int i = _lastSecondarySubtitleIndex; i < _secondarySubtitles.length; i++) {
          final item = _secondarySubtitles[i];
          if (adjustedPosition < item.startTime) break;
          Duration effectiveEndTime = item.endTime;
          if (continuousSubtitleEnabled && i + 1 < _secondarySubtitles.length) {
            effectiveEndTime = _secondarySubtitles[i + 1].startTime;
          }
          if (adjustedPosition < effectiveEndTime) {
             currentSecondaryItem = item;
             _lastSecondarySubtitleIndex = i;
             break;
          }
          _lastSecondarySubtitleIndex = i + 1;
       }
    }
    
    // --- Logic for Text vs Split ---
    String newText = currentItem?.text ?? "";
    String? newSecondaryText = currentSecondaryItem?.text; // Explicit secondary
    
    // If no explicit secondary file is loaded, apply the "Split by Line" logic
    if (_secondarySubtitles.isEmpty && settings.splitSubtitleByLine) {
       if (newText.contains('\n')) {
          final lines = newText.split('\n');
          newText = lines[0];
          newSecondaryText = lines.sublist(1).join('\n');
       }
    }
    
    // Check if item changed (Primary)
    if (currentItem != _currentSubtitleItem) {
      // If it's a new item
      _currentSubtitleItem = currentItem;
      
      if (currentItem != null && currentItem.imageLoader != null) {
        // Load Image
        currentItem.imageLoader!().then((image) {
          if (mounted && _currentSubtitleItem == currentItem) {
             setState(() {
               _currentSubtitleImage = image;
               _currentSubtitleText = ""; // Clear text if image exists (usually)
               _currentSecondaryText = null; // Clear secondary
             });
          }
        });
      } else {
        // Text based or empty
        if (_currentSubtitleImage != null) {
           // Clear image if not needed
           setState(() {
             _currentSubtitleImage = null;
           });
        }
      }
    }
    
    if (_currentSubtitleText != newText || _currentSecondaryText != newSecondaryText) {
      setState(() {
        _currentSubtitleText = newText;
        _currentSecondaryText = newSecondaryText;
      });
    }
  }

  void _togglePlay() async {
    if (_controller.value.isPlaying) {
      await _controller.pause();
      // 同步到 MediaPlaybackService，确保快捷播放卡片状态正确
      if (!_isControllerOwner) {
        try {
          final playbackService = Provider.of<MediaPlaybackService>(context, listen: false);
          // 直接从 controller 读取状态并同步
          playbackService.updatePlaybackStateFromController();
        } catch (e) {
          debugPrint("同步暂停状态失败: $e");
        }
      }
    } else {
      await _controller.play();
      // 同步到 MediaPlaybackService，确保快捷播放卡片状态正确
      if (!_isControllerOwner) {
        try {
          final playbackService = Provider.of<MediaPlaybackService>(context, listen: false);
          // 直接从 controller 读取状态并同步
          playbackService.updatePlaybackStateFromController();
        } catch (e) {
          debugPrint("同步播放状态失败: $e");
        }
      }
    }
  }

  Future<void> _pickSubtitle() async {
    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['srt', 'lrc', 'vtt', 'ass', 'ssa', 'sup', 'sub', 'idx', 'scc'],
        withData: true, 
      );

      if (result != null) {
        final file = result.files.single;
        String path = file.path!;
        
        // Auto Cache Logic
        final settings = Provider.of<SettingsService>(context, listen: false);
        if (_currentItem != null) {
          // Preserve secondary subtitle if it exists
          String? currentSecondary;
          if (_currentSubtitlePaths.length > 1) {
            currentSecondary = _currentSubtitlePaths[1];
          }

          await Provider.of<LibraryService>(context, listen: false)
              .updateVideoSubtitles(
                _currentItem!.id, 
                path, 
                settings.autoCacheSubtitles,
                secondarySubtitlePath: currentSecondary,
                isSecondaryCached: settings.autoCacheSubtitles
              );
        }
        
        // Load with preservation of secondary
        List<String> pathsToLoad = [path];
        if (_currentSubtitlePaths.length > 1) {
           pathsToLoad.add(_currentSubtitlePaths[1]);
        }
        await _loadSubtitles(pathsToLoad);
        
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text("已加载字幕: ${file.name}")),
          );
        }
      }
    } catch (e) {
      print("Error picking subtitle: $e");
    }
  }

  void _showSubtitleManager() {
    setState(() {
      _previousSidebarType = SidebarType.subtitles;
      _activeSidebar = SidebarType.subtitleManager;
    });
  }
  
  Future<void> _loadSubtitles(List<String> paths) async {
    if (paths.isEmpty) {
      setState(() {
        _subtitles = [];
        _secondarySubtitles = [];
        _currentSubtitlePaths = [];
        _currentSubtitleText = "";
        _currentSecondaryText = null;
      });
      
      // 同步到 MediaPlaybackService
      if (mounted) {
        final playbackService = Provider.of<MediaPlaybackService>(context, listen: false);
        playbackService.setSubtitles([]);
      }
      
      return;
    }
    
    // Load Primary
    final primaryList = await _parseSubtitleFile(paths[0]);
    
    List<SubtitleItem> secondaryList = [];
    if (paths.length > 1) {
       secondaryList = await _parseSubtitleFile(paths[1]);
    }
    
    if (primaryList.isNotEmpty || secondaryList.isNotEmpty) {
       setState(() {
          _subtitles = primaryList;
          _secondarySubtitles = secondaryList;
          _currentSubtitlePaths = List.from(paths);
          _lastSubtitleIndex = 0;
          _lastSecondarySubtitleIndex = 0;
          _currentSubtitleText = "";
          _currentSecondaryText = null;
          _currentSubtitleImage = null;
       });
       
       // 同步主字幕到 MediaPlaybackService
       if (mounted) {
         final playbackService = Provider.of<MediaPlaybackService>(context, listen: false);
         playbackService.setSubtitles(primaryList);
       }
       
       Provider.of<SettingsService>(context, listen: false).updateSetting('showSubtitles', true);
    }
  }

  Future<List<SubtitleItem>> _parseSubtitleFile(String path) async {
    try {
      final file = File(path);
      if (!await file.exists()) return [];

      final length = await file.length();
      if (length > 10 * 1024 * 1024) {
         debugPrint("Subtitle file too large ($length bytes), skipping: $path");
         return [];
      }

      final ext = path.toLowerCase();
      List<SubtitleItem> parsed = [];

      if (ext.endsWith('.sup')) {
         parsed = await PgsParser.parse(path);
      } else if (ext.endsWith('.idx')) {
         final converted = await SubtitleConverter.convert(inputPath: path, targetExtension: '.sup');
         if (converted != null) parsed = await PgsParser.parse(converted);
      } else if (ext.endsWith('.scc')) {
         final converted = await SubtitleConverter.convert(inputPath: path, targetExtension: '.srt');
         if (converted != null) return _parseSubtitleFile(converted);
      } else if (ext.endsWith('.sub')) {
         if (await SubtitleConverter.isMicroDvdSub(path)) {
            final converted = await SubtitleConverter.convert(inputPath: path, targetExtension: '.srt');
            if (converted != null) return _parseSubtitleFile(converted);
         } else {
            final converted = await SubtitleConverter.convert(inputPath: path, targetExtension: '.sup');
            if (converted != null) parsed = await PgsParser.parse(converted);
         }
      } else {
        List<int> bytes = await file.readAsBytes();
        String content = "";
        try {
          content = utf8.decode(bytes);
        } catch (e) {
          try {
            content = gbk.decode(bytes);
          } catch (e2) {
            print("Failed to decode: $e2");
          }
        }
        
        if (content.isNotEmpty) {
          parsed = SubtitleParser.parse(content);
        }
      }
      
      if (parsed.isNotEmpty) {
        parsed.sort((a, b) => a.startTime.compareTo(b.startTime));
      }
      return parsed;
    } catch (e) {
      print("Load sub error: $e");
      return [];
    }
  }

  Future<void> _loadSubtitleFromFile(String path) async {
     await _loadSubtitles([path]);
  }

  // --- Drag Logic ---
  void _enterSubtitleDragMode() {
    setState(() {
      _isSubtitleDragMode = true;
      _isGhostDragMode = false;
      _activeSidebar = SidebarType.subtitlePosition;
      final settings = Provider.of<SettingsService>(context, listen: false);
      _isSubtitleSnapped = settings.subtitleAlignment.x == 0.0;
    });
  }

  void _enterGhostDragMode() {
    setState(() {
      _isGhostDragMode = true;
      _isSubtitleDragMode = false;
      _activeSidebar = SidebarType.subtitlePosition;
      final settings = Provider.of<SettingsService>(context, listen: false);
      _isSubtitleSnapped = settings.ghostModeAlignment.x == 0.0;
    });
  }

  void _exitSubtitleDragMode() {
    setState(() {
      if (_isGhostDragMode) {
        _activeSidebar = SidebarType.subtitles;
      } else {
        _activeSidebar = SidebarType.none;
      }
      _isSubtitleDragMode = false;
      _isGhostDragMode = false;
      _isSubtitleSnapped = false;
    });
  }

  void _updateSubtitlePosition(DragUpdateDetails details, BoxConstraints constraints, {bool isGhost = false}) {
    final settings = Provider.of<SettingsService>(context, listen: false);
    final dx = (details.delta.dx / (constraints.maxWidth / 2));
    final dy = (details.delta.dy / (constraints.maxHeight / 2));
    
    final currentAlign = isGhost ? settings.ghostModeAlignment : settings.subtitleAlignment;

    double newX = (currentAlign.x + dx).clamp(-1.0, 1.0);
    final newY = (currentAlign.y + dy).clamp(-1.0, 1.0);

    bool snapped = false;
    if (newX.abs() < 0.05) { 
      newX = 0.0;
      snapped = true;
    }

    if (isGhost) {
      settings.saveGhostModeAlignment(Alignment(newX, newY));
    } else {
      settings.saveSubtitleAlignment(Alignment(newX, newY));
    }
    
    setState(() {
      _isSubtitleSnapped = snapped;
    });
  }

  @override
  Widget build(BuildContext context) {
    // Consume SettingsService
    return Consumer<SettingsService>(
      builder: (context, settings, child) {
        return WillPopScope(
          onWillPop: () async {
            if (_forceExit) {
              SystemChrome.setPreferredOrientations([]);
              return true;
            }
            // Block pop if repairing
            if (_isRepairing) return false;
            
            // 1. If in subtitle drag mode, exit it
            if (_isSubtitleDragMode) {
              _exitSubtitleDragMode();
              return false;
            }
            
            // 2. If in ghost drag mode, exit it
            if (_isGhostDragMode) {
              _exitSubtitleDragMode();
              return false;
            }

            // 3. If a sidebar is open, close it
            if (_isSidebarOpen) {
              setState(() {
                _activeSidebar = SidebarType.none;
              });
              return false;
            }

            // 4. Otherwise, allow pop (and reset orientation early)
            await _handleExit();
            SystemChrome.setPreferredOrientations([]);
            return true;
          },
          child: Scaffold(
            key: _scaffoldKey,
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
                child: SafeArea(
            child: Row(
              children: [
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, screenConstraints) {
                      // Ghost Mode Logic
                      final isLandscape = MediaQuery.of(context).orientation == Orientation.landscape;
                      final isGhostActive = settings.isGhostModeEnabled && isLandscape && 
                          ((_activeSidebar == SidebarType.subtitles) || _isGhostDragMode);

                      return Stack(
                        alignment: Alignment.center,
                        children: [
                          // 1. Video Layer
                          Center(
                            child: _isRepairing 
                              ? Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    const CircularProgressIndicator(),
                                    const SizedBox(height: 16),
                                    const Text("正在修复视频...", style: TextStyle(color: Colors.white)),
                                    const SizedBox(height: 8),
                                    Text(
                                      "进度: ${(_repairProgress * 100).toStringAsFixed(1)}%",
                                      style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)
                                    ),
                                    const SizedBox(height: 8),
                                    const Text("转码为 H.264 (兼容模式)", style: TextStyle(color: Colors.white70, fontSize: 12)),
                                  ],
                                )
                              : _initialized
                                ? RepaintBoundary(
                                    child: AspectRatio(
                                      aspectRatio: _isAudio ? 16 / 9 : (_controller.value.aspectRatio > 0 ? _controller.value.aspectRatio : 16 / 9),
                                      child: Stack(
                                        fit: StackFit.expand,
                                        children: [
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
                                            Transform(
                                              alignment: Alignment.center,
                                              transform: Matrix4.identity()
                                                ..rotateY(settings.isMirroredH ? math.pi : 0)
                                                ..rotateX(settings.isMirroredV ? math.pi : 0),
                                              child: VideoPlayer(_controller, key: ValueKey(_currentItem?.id)),
                                            ),
                                          if (settings.showSubtitles && !isGhostActive)
                                            Align(
                                              alignment: settings.subtitleAlignment,
                                              child: SubtitleOverlay(
                                                text: _currentSubtitleText,
                                                secondaryText: _currentSecondaryText,
                                                image: _currentSubtitleImage,
                                                style: _isAudio ? settings.audioSubtitleStyleLandscape : settings.subtitleStyleLandscape,
                                                isDragging: _isSubtitleDragMode,
                                                isVisualOnly: false,
                                              ),
                                            ),
                                        ],
                                      ),
                                    ),
                                  )
                                : Focus(
                                    autofocus: true,
                                    onKeyEvent: (node, event) {
                                      if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.escape) {
                                        Navigator.of(context).maybePop();
                                        return KeyEventResult.handled;
                                      }
                                      return KeyEventResult.ignored;
                                    },
                                    child: Stack(
                                      fit: StackFit.expand,
                                      children: [
                                        if (_currentItem?.thumbnailPath != null && File(_currentItem!.thumbnailPath!).existsSync())
                                          Image.file(
                                            File(_currentItem!.thumbnailPath!),
                                            fit: BoxFit.cover,
                                            errorBuilder: (_, __, ___) => Container(color: Colors.black),
                                          )
                                        else
                                          Container(color: Colors.black),
                                        Center(
                                          child: CircularProgressIndicator(
                                            color: Colors.white.withOpacity(0.5),
                                          ),
                                        ),
                                        // Top bar for loading state
                                        Positioned(
                                          top: 0, left: 0, right: 0,
                                          child: Container(
                                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
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
                                                    onPressed: () async {
                                                      _forceExit = true;
                                                      await _handleExit();
                                                      if (context.mounted) Navigator.of(context).pop();
                                                    },
                                                  ),
                                                  const SizedBox(width: 8),
                                                ],
                                                IconButton(
                                                  icon: const Icon(Icons.arrow_back, color: Colors.white),
                                                  onPressed: () => Navigator.of(context).maybePop(),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                          ),

                          // 2. Controls Layer
                          if (_initialized && !_isSubtitleDragMode && !_isGhostDragMode)
                            RepaintBoundary(
                              child: VideoControlsOverlay(
                                controller: _controller,
                                isLocked: _isLocked,
                                onTogglePlay: _togglePlay,
                                onBackPressed: () => Navigator.of(context).maybePop(),
                                onExitPressed: () async {
                                  _forceExit = true;
                                  await _handleExit();
                                  if (context.mounted) Navigator.of(context).pop();
                                },
                                onOpenSettings: () => setState(() {
                                  _previousSidebarType = SidebarType.none;
                                  _activeSidebar = SidebarType.settings;
                                }), 
                                onToggleSidebar: () {
                                   setState(() {
                                     if (_activeSidebar == SidebarType.subtitles) {
                                       _activeSidebar = SidebarType.none;
                                     } else {
                                       _activeSidebar = SidebarType.subtitles;
                                     }
                                   });
                                },
                                onToggleFullScreen: () => settings.toggleFullScreen(),
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
                                subtitleStyle: _isAudio ? settings.audioSubtitleStyleLandscape : settings.subtitleStyleLandscape,
                                    subtitleAlignment: settings.subtitleAlignment,
                                    onEnterSubtitleDragMode: _enterSubtitleDragMode,
                                    onClearSelection: () => _selectionKey.currentState?.clearSelection(),
                                    focusNode: _videoFocusNode,
                                    onPlayPrevious: () => Provider.of<MediaPlaybackService>(context, listen: false).playPrevious(autoPlay: settings.autoPlayNextVideo),
                                    onPlayNext: () => Provider.of<MediaPlaybackService>(context, listen: false).playNext(autoPlay: settings.autoPlayNextVideo),
                                    hasPrevious: Provider.of<PlaylistManager>(context).hasPrevious,
                                    hasNext: Provider.of<PlaylistManager>(context).hasNext,
                                  ),
                                ),

                          // 3. Drag Mode Layer (Standard)
                          if (settings.showSubtitles && _initialized && _isSubtitleDragMode)
                            LayoutBuilder(
                              builder: (context, constraints) {
                                return Center(
                                  child: AspectRatio(
                                    aspectRatio: _controller.value.aspectRatio,
                                    child: Stack(
                                      fit: StackFit.expand,
                                      children: [
                                        Align(
                                          alignment: settings.subtitleAlignment,
                                          child: GestureDetector(
                                            onPanUpdate: (details) => _updateSubtitlePosition(details, constraints),
                                            child: SubtitleOverlay(
                                              text: _currentSubtitleText,
                                              secondaryText: _currentSecondaryText, // Pass secondary
                                              image: _currentSubtitleImage,
                                              style: _isAudio ? settings.audioSubtitleStyleLandscape : settings.subtitleStyleLandscape,
                                              isDragging: true,
                                              isGestureOnly: true,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                );
                              }
                            ),
                            
                          // 4. Drag Hints
                          if (_isSubtitleDragMode || _isGhostDragMode) ...[
                            if (_isSubtitleSnapped)
                              Positioned.fill(
                                child: Center(
                                  child: Container(
                                    width: 2, height: double.infinity,
                                    color: Colors.white.withOpacity(0.5),
                                  ),
                                ),
                              ),
                            Positioned(
                              top: 20,
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                                decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(20)),
                                child: Text(_isGhostDragMode ? "拖拽调整幽灵模式位置" : "拖拽调整位置", style: const TextStyle(color: Colors.white)),
                              ),
                            ),
                          ],

                          // 5. Ghost Mode Subtitle Layer
                          if (settings.showSubtitles && isGhostActive)
                             Positioned.fill(
                               child: AnimatedAlign(
                                 duration: const Duration(milliseconds: 300),
                                 curve: Curves.easeOutCubic,
                                 alignment: settings.ghostModeAlignment,
                                 child: GestureDetector(
                                    onPanUpdate: _isGhostDragMode 
                                        ? (details) => _updateSubtitlePosition(details, screenConstraints, isGhost: true)
                                        : null,
                                    child: SubtitleOverlay(
                                      text: _currentSubtitleText,
                                      secondaryText: _currentSecondaryText, // Pass secondary
                                      style: _isAudio ? settings.audioSubtitleStyleLandscape : settings.subtitleStyleLandscape,
                                      isDragging: _isGhostDragMode,
                                      isVisualOnly: !_isGhostDragMode, 
                                    ),
                                  ),
                                ),
                             ),
                        ],
                      );
                    }
                  ),
                ),
                
                // Sidebar Resizer
                if (_isSidebarOpen && _activeSidebar == SidebarType.subtitles)
                  RawGestureDetector(
                    gestures: <Type, GestureRecognizerFactory>{
                      LongPressGestureRecognizer: GestureRecognizerFactoryWithHandlers<LongPressGestureRecognizer>(
                        () => LongPressGestureRecognizer(duration: const Duration(milliseconds: 250)),
                        (instance) {
                          instance.onLongPressStart = (_) => setState(() => _isResizingSidebar = true);
                          instance.onLongPressMoveUpdate = (details) {
                            final screenWidth = MediaQuery.of(context).size.width;
                            settings.updateSetting('userSubtitleSidebarWidth', (screenWidth - details.globalPosition.dx).clamp(200.0, 600.0));
                          };
                          instance.onLongPressEnd = (_) => setState(() => _isResizingSidebar = false);
                        },
                      ),
                    },
                    child: Container(
                      width: 12,
                      color: _isResizingSidebar ? Colors.blueAccent : Colors.black12,
                      child: const Center(child: VerticalDivider(color: Colors.white24, width: 4, thickness: 4, indent: 40, endIndent: 40)),
                    ),
                  ),

                // Sidebar
                AnimatedContainer(
                  duration: _isResizingSidebar ? Duration.zero : const Duration(milliseconds: 250),
                  curve: Curves.easeOutCubic,
                  width: _isSidebarOpen ? _getSidebarWidth(context, settings) : 0,
                  child: _isSidebarOpen 
                    ? ClipRect(
                        child: OverflowBox(
                          minWidth: _getSidebarWidth(context, settings),
                          maxWidth: _getSidebarWidth(context, settings),
                          alignment: Alignment.centerLeft,
                          child: _buildSidebarContent(settings),
                        ),
                      )
                    : null,
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
},
);
}

  Widget? _buildSidebarContent(SettingsService settings) {
    if (!_isSidebarOpen) return null;

    switch (_activeSidebar) {
      case SidebarType.subtitles:
        return SubtitleSidebar(
          subtitles: _subtitles,
          secondarySubtitles: _secondarySubtitles,
          controller: _controller,
          onItemTap: (time) => _controller.seekTo(time),
          onOpenSettings: () => setState(() {
            _previousSidebarType = SidebarType.subtitles;
            _activeSidebar = SidebarType.settings;
          }),
          onClose: () => setState(() => _activeSidebar = SidebarType.none),
          onLoadSubtitle: _pickSubtitle,
          onOpenSubtitleStyle: () => setState(() => _activeSidebar = SidebarType.subtitleStyle),
          onOpenSubtitleManager: _showSubtitleManager,
          onClearSelection: () => _selectionKey.currentState?.clearSelection(),
          onScanEmbeddedSubtitles: _checkAndLoadEmbeddedSubtitle,
          isCompact: true,
          isPortrait: false,
          focusNode: _videoFocusNode, // Pass focus node
        );

      case SidebarType.subtitleStyle:
        return SubtitleSettingsSheet(
          style: _isAudio ? settings.audioSubtitleStyleLandscape : settings.subtitleStyleLandscape,
          onStyleChanged: (newStyle) {
            if (_isAudio) {
              settings.saveAudioSubtitleStyleLandscape(newStyle);
            } else {
              settings.saveSubtitleStyleLandscape(newStyle);
            }
          },
          onClose: () => setState(() => _activeSidebar = SidebarType.none),
          onBack: () => setState(() => _activeSidebar = SidebarType.subtitles),
          isAudio: _isAudio,
        );
      
      case SidebarType.settings:
        return SettingsPanel(
          playbackSpeed: settings.playbackSpeed,
          showSubtitles: settings.showSubtitles,
          isMirroredH: settings.isMirroredH,
          isMirroredV: settings.isMirroredV,
          onLoadSubtitle: () async {
              await _pickSubtitle();
          },
          onOpenSubtitleSettings: () => setState(() => _activeSidebar = SidebarType.subtitleStyle),
          onClose: () => setState(() {
            if (_previousSidebarType == SidebarType.subtitles) {
              _activeSidebar = SidebarType.subtitles;
            } else {
              _activeSidebar = SidebarType.none;
            }
            _previousSidebarType = SidebarType.none;
          }),
          onSpeedChanged: (speed) {
            _controller.setPlaybackSpeed(speed);
            settings.updateSetting('playbackSpeed', speed);
          },
          longPressSpeed: settings.longPressSpeed,
          onLongPressSpeedChanged: (speed) => settings.updateSetting('longPressSpeed', speed),
          onSubtitleToggle: (value) => settings.updateSetting('showSubtitles', value),
          onMirrorHChanged: (value) => settings.updateSetting('isMirroredH', value),
          onMirrorVChanged: (value) => settings.updateSetting('isMirroredV', value),
          doubleTapSeekSeconds: settings.doubleTapSeekSeconds,
          onSeekSecondsChanged: (seconds) => settings.updateSetting('doubleTapSeekSeconds', seconds),
          enableDoubleTapSubtitleSeek: settings.enableDoubleTapSubtitleSeek,
          onDoubleTapSubtitleSeekChanged: (val) => settings.updateSetting('enableDoubleTapSubtitleSeek', val),
          subtitleDelay: settings.subtitleOffset.inMilliseconds / 1000.0,
          onSubtitleDelayChanged: (delay) => settings.updateSetting('subtitleOffset', (delay * 1000).round()),
          onSubtitleDelayChangeEnd: (_) {},
          isHardwareDecoding: settings.isHardwareDecoding,
          onHardwareDecodingChanged: (value) {
            settings.updateSetting('isHardwareDecoding', value);
            // Re-init video logic would go here, but complex with shared controller. 
            // For now, prompt user to restart video.
          },
          // New: Auto Cache Toggle
          autoCacheSubtitles: settings.autoCacheSubtitles,
          onAutoCacheSubtitlesChanged: (value) => settings.updateSetting('autoCacheSubtitles', value),
          
          // New: Split Subtitle Toggle
          splitSubtitleByLine: settings.splitSubtitleByLine,
          onSplitSubtitleByLineChanged: (val) => settings.updateSetting('splitSubtitleByLine', val),
          
          // New: Continuous Subtitle Toggle
          continuousSubtitle: _isAudio ? settings.audioContinuousSubtitle : settings.videoContinuousSubtitle,
          onContinuousSubtitleChanged: (value) {
            if (_isAudio) {
              settings.updateSetting('audioContinuousSubtitle', value);
            } else {
              settings.updateSetting('videoContinuousSubtitle', value);
            }
          },
          
          // New: Auto Pause on Exit
          autoPauseOnExit: settings.autoPauseOnExit,
          onAutoPauseOnExitChanged: (value) => settings.updateSetting('autoPauseOnExit', value),
          
          // New: Auto Play Next Video
          autoPlayNextVideo: settings.autoPlayNextVideo,
          onAutoPlayNextVideoChanged: (value) => settings.updateSetting('autoPlayNextVideo', value),
        );

      case SidebarType.subtitleStyle:
        return SubtitleSettingsSheet(
          style: _isAudio ? settings.audioSubtitleStyleLandscape : settings.subtitleStyleLandscape,
          onStyleChanged: (newStyle) {
            if (_isAudio) {
              settings.saveAudioSubtitleStyleLandscape(newStyle);
            } else {
              settings.saveSubtitleStyleLandscape(newStyle);
            }
          },
          onClose: () => setState(() => _activeSidebar = SidebarType.none),
          onBack: () => setState(() => _activeSidebar = SidebarType.settings),
          isAudio: _isAudio,
        );
        
      case SidebarType.subtitlePosition:
        final isGhost = _isGhostDragMode;
        final currentAlign = isGhost ? settings.ghostModeAlignment : settings.subtitleAlignment;
        
        return SubtitlePositionSidebar(
          currentAlignment: currentAlign,
          onAlignmentChanged: (align) => isGhost ? settings.saveGhostModeAlignment(align) : settings.saveSubtitleAlignment(align),
          presets: settings.subtitlePresets,
          onSavePreset: () {
            final newPresets = List<Map<String, double>>.from(settings.subtitlePresets);
            newPresets.insert(0, {'x': currentAlign.x, 'y': currentAlign.y});
            if (newPresets.length > 10) newPresets.removeLast();
            settings.saveSubtitlePresets(newPresets);
          },
          onReset: () => isGhost 
              ? settings.saveGhostModeAlignment(const Alignment(0.0, 0.9)) 
              : settings.saveSubtitleAlignment(const Alignment(0.0, 0.9)),
          onConfirm: _exitSubtitleDragMode,
          isGhostModeEnabled: settings.isGhostModeEnabled,
          onGhostModeToggle: (val) {
            settings.updateSetting('isGhostModeEnabled', val);
            // Force rebuild to update UI state
            setState(() {});
          },
          onEnterGhostMode: _enterGhostDragMode,
          isGhostModeActive: _isGhostDragMode,
        );

      case SidebarType.subtitleManager:
         String path = _currentItem?.path ?? widget.videoFile?.path ?? "";
         if (path.isEmpty) return null;
         
         return SubtitleManagementSheet(
           videoPath: path,
           additionalSubtitles: _currentItem?.additionalSubtitles,
           initialSelectedPaths: _currentSubtitlePaths,
           onSubtitleChanged: () {
              // Logic to refresh if needed
           },
           onSubtitleSelected: (paths) async {
              await _loadSubtitles(paths);
              if (_currentItem != null) {
                 final settings = Provider.of<SettingsService>(context, listen: false);
                 
                 String? path0;
                 String? path1;
                 
                 if (paths.isNotEmpty) path0 = paths[0];
                 if (paths.length > 1) path1 = paths[1];
                 
                 Provider.of<LibraryService>(context, listen: false)
                     .updateVideoSubtitles(
                        _currentItem!.id, 
                        path0, 
                        settings.autoCacheSubtitles,
                        secondarySubtitlePath: path1,
                        isSecondaryCached: settings.autoCacheSubtitles
                     );
              }
           },
           onSubtitlePreview: (path) async {
              await _loadSubtitles([path]);
           },
           onOpenAi: () {
             setState(() => _activeSidebar = SidebarType.aiTranscription);
           },
           onClose: () => setState(() => _activeSidebar = SidebarType.subtitles),
         );

      case SidebarType.aiTranscription:
         String pathAi = _currentItem?.path ?? widget.videoFile?.path ?? "";
         if (pathAi.isEmpty) return null;
         
         return AiTranscriptionPanel(
           videoPath: pathAi,
           videoId: _currentItem?.id,
           onCompleted: (srtPath) async {
              // 只负责UI刷新，数据持久化已由 TranscriptionManager 处理
              await _loadSubtitles([srtPath]);
              
              if (mounted) {
                 ScaffoldMessenger.of(context).showSnackBar(
                   const SnackBar(content: Text("AI 字幕已加载")),
                 );
              }
              setState(() => _activeSidebar = SidebarType.subtitles);
           },
         );

      default:
        return null;
    }
  }
}
