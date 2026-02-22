import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:open_filex/open_filex.dart';
import 'package:file_picker/file_picker.dart';
import 'package:video_player/video_player.dart';
import '../services/library_service.dart';
import '../services/settings_service.dart';
import 'collection_screen.dart';
import 'recycle_bin_screen.dart';
import '../models/video_collection.dart';
import '../models/video_item.dart';
import '../widgets/folder_drop_target.dart';
import '../widgets/cached_thumbnail_widget.dart';
import 'package:flutter/services.dart';
import '../services/bilibili/bilibili_download_service.dart';
import '../models/bilibili_download_task.dart';
import '../models/bilibili_models.dart';
import 'portrait_video_screen.dart';
import 'video_player_screen.dart';

import 'bilibili_download_screen.dart';
import 'package:video_player_app/widgets/bilibili_login_dialogs.dart';
import '../widgets/mini_playback_card.dart';
import 'package:desktop_drop/desktop_drop.dart';
import '../widgets/video_action_buttons.dart';
import '../services/media_playback_service.dart';
import '../services/playlist_manager.dart';
import 'dart:convert';
import '../utils/app_toast.dart';
import '../utils/bilibili_url_parser.dart';

class _ClipboardDisplayInfo {
  final String title;
  final String cover;
  final String? collectionTitle;
  final String? collectionCover;
  final bool showCollectionBadge;

  const _ClipboardDisplayInfo({
    required this.title,
    required this.cover,
    required this.collectionTitle,
    required this.collectionCover,
    required this.showCollectionBadge,
  });
}

class _BoxSelectionPainter extends CustomPainter {
  final Rect selectionRect;

  _BoxSelectionPainter({required this.selectionRect});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.blueAccent.withValues(alpha: 0.2)
      ..style = PaintingStyle.fill;
    
    final borderPaint = Paint()
      ..color = Colors.blueAccent.withValues(alpha: 0.8)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;

    canvas.drawRect(selectionRect, paint);
    canvas.drawRect(selectionRect, borderPaint);
  }

  @override
  bool shouldRepaint(covariant _BoxSelectionPainter oldDelegate) {
    return selectionRect != oldDelegate.selectionRect;
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  bool _isSelectionMode = false;
  final Set<String> _selectedIds = {};

  // Pinch to zoom state
  int _baseCrossAxisCount = 2;

  // Selection Logic State
  // 1. Circle Drag Selection (All Platforms)
  int? _dragSelectionStartIndex;
  Set<String> _dragSelectionSnapshot = {};
  
  // 2. Box Selection
  bool _isBoxSelecting = false;
  Offset? _boxStartPos;
  Offset? _boxCurrentPos;
  
  // File Drag & Drop (Windows)
  bool _isDraggingFiles = false;

  // Track items that have been "touched" by the current box selection session
  final Set<String> _capturedIds = {};

  // Clipboard
  String? _lastProcessedClipboard;

  // Added variables for missing definitions
  bool _hasPendingPlaybackState = false;
  bool _showExportSettingsButton = false;
  DateTime? _lastTitleTapAt;
  int _titleTapCount = 0;
  final FocusNode _shortcutFocusNode = FocusNode();
  bool? _lastIsFullScreen;
  bool _bilibiliLoginCheckQueued = false;
  
  // ... (existing code)

  final ScrollController _scrollController = ScrollController(); // Need scroll controller for calculation

  // ...

  /// Helper: Get total item count safely
  int _getItemCount() {
    final library = Provider.of<LibraryService>(context, listen: false);
    return library.getContents(null).length;
  }

  /// Helper: Get content ID at index
  String? _getItemId(int index) {
    final library = Provider.of<LibraryService>(context, listen: false);
    final contents = library.getContents(null);
    if (index < 0 || index >= contents.length) return null;
    return (contents[index] as dynamic).id;
  }

  /// Helper: Check if a point (relative to scrollable content) is inside an item
  /// Returns the index of the item, or null if in spacing/padding
  int? _getIndexAt(Offset contentOffset) {
     final settings = Provider.of<SettingsService>(context, listen: false);
     final crossAxisCount = settings.homeGridCrossAxisCount;
     final count = _getItemCount();
     if (crossAxisCount <= 0 || count == 0) return null;

     final mediaQuery = MediaQuery.of(context);
     final screenWidth = mediaQuery.size.width;
     
     // Grid Parameters (Must match GridView layout)
     const double spacing = 16.0;
     const double hPadding = 16.0;
     const double topPadding = 16.0;
     
     final double totalSpacing = (crossAxisCount - 1) * spacing + (hPadding * 2);
     final double itemWidth = (screenWidth - totalSpacing) / crossAxisCount;
     final double itemHeight = itemWidth / settings.homeCardAspectRatio;
     
     // Check horizontal bounds
     if (contentOffset.dx < hPadding || contentOffset.dx > screenWidth - hPadding) return null;
     
     // Check top bound
     if (contentOffset.dy < topPadding) return null;
     
     // Calculate Col
     double relativeX = contentOffset.dx - hPadding;
     int col = (relativeX / (itemWidth + spacing)).floor();
     
     // Check if in horizontal spacing
     double remainderX = relativeX % (itemWidth + spacing);
     if (remainderX > itemWidth) return null; 
     if (col >= crossAxisCount) return null;
     
     // Calculate Row
     double relativeY = contentOffset.dy - topPadding;
     int row = (relativeY / (itemHeight + spacing)).floor();
     
     // Check if in vertical spacing
     double remainderY = relativeY % (itemHeight + spacing);
     if (remainderY > itemHeight) return null; 
     
     int index = row * crossAxisCount + col;
     if (index >= 0 && index < count) {
       return index;
     }
     return null;
  }

  /// Helper: Get the Rect of an item at [index] relative to the scrollable content area
  Rect? _getItemRect(int index) {
     final settings = Provider.of<SettingsService>(context, listen: false);
     final crossAxisCount = settings.homeGridCrossAxisCount;
     final count = _getItemCount();
     if (crossAxisCount <= 0 || index < 0 || index >= count) return null;
     
     final mediaQuery = MediaQuery.of(context);
     final screenWidth = mediaQuery.size.width;
     
     // Grid Parameters
     const double spacing = 16.0;
     const double hPadding = 16.0;
     const double topPadding = 16.0;
     
     final double totalSpacing = (crossAxisCount - 1) * spacing + (hPadding * 2);
     final double itemWidth = (screenWidth - totalSpacing) / crossAxisCount;
     final double itemHeight = itemWidth / settings.homeCardAspectRatio;
     
     final int row = index ~/ crossAxisCount;
     final int col = index % crossAxisCount;
     
     final double x = hPadding + col * (itemWidth + spacing);
     final double y = topPadding + row * (itemHeight + spacing);
     
     return Rect.fromLTWH(x, y, itemWidth, itemHeight);
  }

  /// Handle Circle Drag Selection Update
  void _updateDragSelection(Offset globalPos) {
    if (_dragSelectionStartIndex == null) return;

    final RenderBox? renderBox = context.findRenderObject() as RenderBox?;
    if (renderBox == null) return;
    
    final Offset localPos = renderBox.globalToLocal(globalPos);
    
    // Adjust for AppBar
    final double appBarHeight = kToolbarHeight + MediaQuery.of(context).padding.top;
    
    // Offset relative to the Viewport
    final double viewportY = localPos.dy - appBarHeight;
    
    // Offset relative to Content
    final double contentX = localPos.dx;
    final double contentY = viewportY + _scrollController.offset;
    
    // Calculate Box for Visualization (Circle Drag)
    final startRect = _getItemRect(_dragSelectionStartIndex!);
    if (startRect != null) {
       final startPoint = startRect.center;
       final viewportStart = startPoint - Offset(0, _scrollController.offset);
       final viewportCurrent = Offset(contentX, contentY) - Offset(0, _scrollController.offset);
       
       _boxStartPos = viewportStart;
       _boxCurrentPos = viewportCurrent;
       _isBoxSelecting = true; // Enable painting
    }

    if (_boxStartPos != null && _boxCurrentPos != null) {
        final rect = Rect.fromPoints(_boxStartPos!, _boxCurrentPos!);
        final contentRect = rect.shift(Offset(0, _scrollController.offset));
        
        final Set<String> currentInBox = {};
        final count = _getItemCount();
        
        for (int i = 0; i < count; i++) {
            final itemRect = _getItemRect(i);
            if (itemRect != null && itemRect.overlaps(contentRect)) {
                final id = _getItemId(i);
                if (id != null) currentInBox.add(id);
            }
        }
        
        _capturedIds.addAll(currentInBox);
        
        final Set<String> newSelection = {};
        
        for (final id in _dragSelectionSnapshot) {
            if (!_capturedIds.contains(id)) {
                newSelection.add(id);
            }
        }
        
        newSelection.addAll(currentInBox);
        
        if (newSelection.length != _selectedIds.length || !_selectedIds.containsAll(newSelection)) {
           setState(() {
             _selectedIds.clear();
             _selectedIds.addAll(newSelection);
           });
           if (Platform.isAndroid || Platform.isIOS) {
              HapticFeedback.selectionClick();
           }
        }
    }
  }

  /// 计算播放卡片的底部填充，确保内容不被遮挡
  double _getPlaybackCardBottomPadding() {
    final playbackService = Provider.of<MediaPlaybackService>(context, listen: false);
    final isVisible = playbackService.currentItem != null &&
        (playbackService.state == PlaybackState.playing ||
         playbackService.state == PlaybackState.paused);
    
    if (!isVisible) {
      // 如果有待恢复的播放状态，预留空间避免首次启动时遮挡
      if (_hasPendingPlaybackState) {
        final screenWidth = MediaQuery.of(context).size.width;
        final isPhone = screenWidth < 600;
        final isTablet = screenWidth >= 600 && screenWidth < 1200;
        
        if (isPhone) return 117.0 + _getPlaybackCardVerticalOffset();
        if (isTablet) return 127.0 + _getPlaybackCardVerticalOffset();
        return 107.0 + _getPlaybackCardVerticalOffset();
      }
      return 0.0;
    }
    
    // 根据屏幕宽度计算卡片高度（与 PlaybackCardLayout 保持一致）
    final screenWidth = MediaQuery.of(context).size.width;
    final isPhone = screenWidth < 600;
    final isTablet = screenWidth >= 600 && screenWidth < 1200;
    
    if (isPhone) return 117.0 + _getPlaybackCardVerticalOffset();
    if (isTablet) return 127.0 + _getPlaybackCardVerticalOffset();
    return 107.0 + _getPlaybackCardVerticalOffset();
  }

  double _getPlaybackCardVerticalOffset() {
    return 6.0;
  }

  Route<void> _buildVideoPlayerRoute(VideoItem item, VideoPlayerController? existingController) {
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      return PageRouteBuilder(
        pageBuilder: (context, animation, secondaryAnimation) {
          return VideoPlayerScreen(
            videoItem: item,
            existingController: existingController,
          );
        },
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          return child;
        },
        transitionDuration: Duration.zero,
        reverseTransitionDuration: Duration.zero,
        opaque: true,
      );
    }
    return MaterialPageRoute(
      builder: (context) => PortraitVideoScreen(videoItem: item),
    );
  }

  /// 检查是否有待恢复的播放状态（用于首次启动时预留空间）
  Future<void> _checkPendingPlaybackState() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonString = prefs.getString('playback_state_snapshot');
      if (jsonString != null && jsonString.isNotEmpty) {
        final json = jsonDecode(jsonString) as Map<String, dynamic>;
        final currentItemId = json['currentItemId'] as String?;
        _hasPendingPlaybackState = currentItemId != null;
      }
    } catch (e) {
      debugPrint('检查播放状态失败: $e');
    }
  }

  Future<void> _loadExportButtonPreference() async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getBool('show_export_settings_button') ?? false;
    if (mounted) {
      setState(() {
        _showExportSettingsButton = value;
      });
    } else {
      _showExportSettingsButton = value;
    }
  }

  Future<void> _toggleExportButtonVisibility() async {
    final newValue = !_showExportSettingsButton;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('show_export_settings_button', newValue);
    if (!mounted) return;
    setState(() {
      _showExportSettingsButton = newValue;
    });
    AppToast.show(newValue ? "导出按钮已显示" : "导出按钮已隐藏", type: AppToastType.info);
  }

  void _handleTitleTap() {
    final now = DateTime.now();
    if (_lastTitleTapAt == null || now.difference(_lastTitleTapAt!).inMilliseconds > 1200) {
      _titleTapCount = 0;
    }
    _lastTitleTapAt = now;
    _titleTapCount += 1;
    if (_titleTapCount >= 5) {
      _titleTapCount = 0;
      _toggleExportButtonVisibility();
    }
  }

  Future<void> _exportSettingsSnapshot() async {
    try {
      final settings = Provider.of<SettingsService>(context, listen: false);
      final bilibili = Provider.of<BilibiliDownloadService>(context, listen: false);
      final prefs = await SharedPreferences.getInstance();
      final subtitleDownloadPath = prefs.getString('subtitle_download_path');
      final showExportSettingsButton = prefs.getBool('show_export_settings_button') ?? false;

      final exportJson = {
        'schemaVersion': 1,
        'exportedAt': DateTime.now().toIso8601String(),
        'settings': settings.exportSettingsSnapshot(),
        'bilibili': {
          'maxConcurrentDownloads': bilibili.maxConcurrentDownloads,
          'preferredQuality': bilibili.preferredQuality,
          'preferredSubtitleLang': bilibili.preferredSubtitleLang,
          'preferAiSubtitles': bilibili.preferAiSubtitles,
          'autoImportToLibrary': bilibili.autoImportToLibrary,
          'autoDeleteTaskAfterImport': bilibili.autoDeleteTaskAfterImport,
          'sequentialExport': bilibili.sequentialExport,
        },
        'paths': {
          'subtitleDownloadPath': subtitleDownloadPath,
        },
        'ui': {
          'showExportSettingsButton': showExportSettingsButton,
        },
      };

      final dir = await _resolveExportDirectory();
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      final filePath = p.join(dir.path, 'video_player_settings_export.json');
      final file = File(filePath);
      const encoder = JsonEncoder.withIndent('  ');
      await file.writeAsString(encoder.convert(exportJson));

      if (mounted) {
        final result = await OpenFilex.open(filePath, type: 'application/json');
        if (result.type == ResultType.done) {
          AppToast.show("设置已导出并打开: $filePath", type: AppToastType.success);
        } else {
          AppToast.show("设置已导出，但打开失败: $filePath", type: AppToastType.error);
        }
      }
    } catch (e) {
      if (mounted) {
        AppToast.show("导出失败: $e", type: AppToastType.error);
      }
    }
  }

  Future<Directory> _resolveExportDirectory() async {
    if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
      final downloads = await getDownloadsDirectory();
      if (downloads != null) return downloads;
    }
    if (Platform.isAndroid) {
      final external = await getExternalStorageDirectory();
      if (external != null) return external;
    }
    return getApplicationDocumentsDirectory();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (Platform.isWindows && mounted) {
        _shortcutFocusNode.requestFocus();
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // 使用非阻塞方式调用,避免卡住UI
      _checkBilibiliLogin();
      _checkClipboard();
      _checkPendingPlaybackState();
      _loadExportButtonPreference();
    });
    
    // 监听播放服务状态，当播放状态恢复完成后清除待恢复标志
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final playbackService = Provider.of<MediaPlaybackService>(context, listen: false);
      playbackService.addListener(_onPlaybackServiceChanged);
    });
  }
  
  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    final playbackService = Provider.of<MediaPlaybackService>(context, listen: false);
    playbackService.removeListener(_onPlaybackServiceChanged);
    _shortcutFocusNode.dispose();
    super.dispose();
  }

  KeyEventResult _handleShortcutKeyEvent(KeyEvent event) {
    if (!Platform.isWindows) return KeyEventResult.ignored;
    if (FocusManager.instance.primaryFocus?.context?.widget is EditableText) {
      return KeyEventResult.ignored;
    }
    if (event is KeyRepeatEvent) return KeyEventResult.handled;
    final key = event.logicalKey;
    final isTargetKey = key == LogicalKeyboardKey.space ||
        key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.arrowRight ||
        key == LogicalKeyboardKey.escape;
    if (!isTargetKey) return KeyEventResult.ignored;
    if (event is! KeyDownEvent) return KeyEventResult.handled;

    if (key == LogicalKeyboardKey.escape) {
      if (_isSelectionMode) {
        Navigator.of(context).maybePop();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }

    final playbackService = Provider.of<MediaPlaybackService>(context, listen: false);
    final settings = Provider.of<SettingsService>(context, listen: false);
    final canControl = playbackService.currentItem != null &&
        (playbackService.state == PlaybackState.playing ||
            playbackService.state == PlaybackState.paused);
    if (!canControl) return KeyEventResult.handled;

    if (key == LogicalKeyboardKey.space) {
      if (playbackService.isPlaying) {
        playbackService.pause();
      } else {
        playbackService.resume();
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft) {
      playbackService.handleExternalDoubleTapSeek(
        isLeft: true,
        doubleTapSeekSeconds: settings.doubleTapSeekSeconds,
        enableDoubleTapSubtitleSeek: settings.enableDoubleTapSubtitleSeek,
        subtitleOffset: settings.subtitleOffset,
      );
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowRight) {
      playbackService.handleExternalDoubleTapSeek(
        isLeft: false,
        doubleTapSeekSeconds: settings.doubleTapSeekSeconds,
        enableDoubleTapSubtitleSeek: settings.enableDoubleTapSubtitleSeek,
        subtitleOffset: settings.subtitleOffset,
      );
      return KeyEventResult.handled;
    }
    return KeyEventResult.handled;
  }
  
  /// 播放服务状态变化监听器
  void _onPlaybackServiceChanged() {
    if (_hasPendingPlaybackState) {
      final playbackService = Provider.of<MediaPlaybackService>(context, listen: false);
      // 当播放状态恢复完成（currentItem 被设置）后，清除待恢复标志
      if (playbackService.currentItem != null) {
        setState(() {
          _hasPendingPlaybackState = false;
        });
      }
    }
  }

  Future<void> _checkBilibiliLogin() async {
    if (!mounted) return;
    
    try {
      final service = Provider.of<BilibiliDownloadService>(context, listen: false);
      bool initReady = true;
      final initFuture = service.init();
      await initFuture.timeout(const Duration(milliseconds: 800), onTimeout: () {
        initReady = false;
      });
      if (!initReady) {
        if (!_bilibiliLoginCheckQueued) {
          _bilibiliLoginCheckQueued = true;
          initFuture.then((_) {
            if (!mounted) return;
            _bilibiliLoginCheckQueued = false;
            _checkBilibiliLogin();
          });
        }
        return;
      }
      if (!mounted) return;
      final settings = Provider.of<SettingsService>(context, listen: false);

      if (settings.suppressBilibiliRestrictedDialog) return;
      
      // Check if login is valid (calls Bilibili API)
      // We only check this on startup to avoid spamming the user
      // 添加超时处理,避免网络请求卡住UI
      final isValid = await service.apiService.checkLoginStatus()
          .timeout(const Duration(seconds: 5), onTimeout: () {
        debugPrint('B站登录状态检查超时');
        return false;
      });
    
      if (!isValid) {
        if (!mounted) return;
        
        bool dontShowAgain = false;

        await showDialog(
          context: context,
          builder: (context) => StatefulBuilder(
            builder: (context, setState) => AlertDialog(
              backgroundColor: const Color(0xFF2C2C2C),
              title: const Text("B站功能受限提示", style: TextStyle(color: Colors.white)),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    "检测到您尚未登录或Cookie已过期。\n\n不扫码就无法使用剪贴板识别b站视频与B站视频解析功能。",
                    style: TextStyle(color: Colors.white70),
                  ),
                  const SizedBox(height: 16),
                  GestureDetector(
                    onTap: () {
                      setState(() {
                        dontShowAgain = !dontShowAgain;
                      });
                    },
                    child: Row(
                      children: [
                        SizedBox(
                          width: 24,
                          height: 24,
                          child: Checkbox(
                            value: dontShowAgain,
                            onChanged: (val) {
                              setState(() {
                                dontShowAgain = val ?? false;
                              });
                            },
                            fillColor: WidgetStateProperty.resolveWith((states) => 
                              states.contains(WidgetState.selected) ? const Color(0xFFFB7299) : Colors.grey),
                          ),
                        ),
                        const SizedBox(width: 8),
                        const Text("之后不显示", style: TextStyle(color: Colors.white70)),
                      ],
                    ),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () async {
                    if (dontShowAgain) {
                      final confirm = await showDialog<bool>(
                        context: context,
                        builder: (context) => AlertDialog(
                          backgroundColor: const Color(0xFF2C2C2C),
                          title: const Text("确认不再提示", style: TextStyle(color: Colors.white)),
                          content: const Text(
                            "您选择了不再提示。\n\n后续如需登录B站账号以解锁完整功能（如剪贴板识别、视频解析），请前往：\n\n设置页 -> B站下载设置 -> 点击头像登录",
                            style: TextStyle(color: Colors.white70),
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(context, false),
                              child: const Text("取消", style: TextStyle(color: Colors.grey)),
                            ),
                            TextButton(
                              onPressed: () => Navigator.pop(context, true),
                              child: const Text("确认", style: TextStyle(color: Color(0xFFFB7299))),
                            ),
                          ],
                        ),
                      );
                      
                      if (confirm == true) {
                        if (context.mounted) {
                          Provider.of<SettingsService>(context, listen: false)
                              .updateSetting('suppressBilibiliRestrictedDialog', true);
                          Navigator.pop(context);
                        }
                      }
                    } else {
                      Navigator.pop(context);
                    }
                  },
                  child: const Text("暂不登录", style: TextStyle(color: Colors.grey)),
                ),
                ElevatedButton(
                  onPressed: () {
                    Navigator.pop(context);
                    showBilibiliLoginDialog(context);
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFFB7299),
                    foregroundColor: Colors.white,
                  ),
                  child: const Text("去扫码"),
                ),
              ],
            ),
          ),
        );
      }
    } catch (e) {
      // 静默处理错误,不影响应用启动
      debugPrint('B站登录状态检查失败: $e');
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
       _checkClipboard();
    }
  }

  Future<void> _checkClipboard() async {
    try {
      // 1. Check Login
      if (!mounted) return;
      final service = Provider.of<BilibiliDownloadService>(context, listen: false);
      
      // 添加超时处理
      final hasCookie = await service.apiService.hasCookie()
          .timeout(const Duration(seconds: 2), onTimeout: () => false);
      if (!hasCookie) return;

      // 2. Get Clipboard
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final content = data?.text;
      if (content == null || content.trim().isEmpty) return;
      
      // 3. Avoid duplicate checks
      if (content == _lastProcessedClipboard) return;
      
      // 4. Try Parse
      if (!content.contains("bilibili.com") && 
          !content.contains("b23.tv") && 
          !content.contains("BV") && 
          !content.contains("av") && 
          !content.contains("ss") && 
          !content.contains("ep")) {
         return;
      }

      final task = await service.parseSingleLine(content)
          .timeout(const Duration(seconds: 5), onTimeout: () => null);
      if (task != null) {
        _lastProcessedClipboard = content;
        if (mounted) {
           final displayInfo = await _buildClipboardDisplayInfo(content, task);
           if (!mounted) return;
           _showClipboardDialog(content, task, displayInfo);
        }
      }
    } catch (e) {
      // Ignore - 不影响应用启动
      debugPrint('剪贴板检查失败: $e');
    }
  }

  Future<_ClipboardDisplayInfo> _buildClipboardDisplayInfo(String content, BilibiliDownloadTask task) async {
    final collectionTitle = task.collectionInfo?.title;
    final collectionCover = task.collectionInfo?.cover;
    BilibiliVideoInfo? targetVideo;
    if (task.singleVideoInfo != null) {
      targetVideo = task.singleVideoInfo;
    } else if (task.collectionInfo != null) {
      final id = await _extractBilibiliIdFromContent(content);
      if (id != null) {
        final lowerId = id.toLowerCase();
        for (final video in task.videos) {
          final bvid = video.videoInfo.bvid.toLowerCase();
          final aid = video.videoInfo.aid.toLowerCase();
          if (bvid == lowerId || aid == lowerId) {
            targetVideo = video.videoInfo;
            break;
          }
        }
      }
      targetVideo ??= task.videos.length == 1 ? task.videos.first.videoInfo : null;
    }
    final title = targetVideo?.title ?? task.singleVideoInfo?.title ?? task.collectionInfo?.title ?? "未知标题";
    final cover = targetVideo?.pic ?? task.singleVideoInfo?.pic ?? task.collectionInfo?.cover ?? "";
    final showCollectionBadge = task.collectionInfo != null && targetVideo != null;
    return _ClipboardDisplayInfo(
      title: title,
      cover: cover,
      collectionTitle: collectionTitle,
      collectionCover: collectionCover,
      showCollectionBadge: showCollectionBadge,
    );
  }

  Future<String?> _extractBilibiliIdFromContent(String content) async {
    try {
      String cleanInput = content.trim();
      final linkMatch = RegExp(r'(https?://[^\s]+)').firstMatch(content);
      if (linkMatch != null) {
        cleanInput = linkMatch.group(0)!;
        cleanInput = cleanInput.replaceAll(RegExp(r'[.,!?;:")]*$'), '');
      } else {
        final bvMatch = RegExp(r'(BV[a-zA-Z0-9]{10})', caseSensitive: false).firstMatch(content);
        if (bvMatch != null) {
          cleanInput = bvMatch.group(0)!;
        } else {
          final ssMatch = RegExp(r'(ss[0-9]+)', caseSensitive: false).firstMatch(content);
          if (ssMatch != null) {
            cleanInput = ssMatch.group(0)!;
          } else {
            final epMatch = RegExp(r'(ep[0-9]+)', caseSensitive: false).firstMatch(content);
            if (epMatch != null) {
              cleanInput = epMatch.group(0)!;
            }
          }
        }
      }
      var type = BilibiliUrlParser.determineType(cleanInput);
      if (type == BilibiliUrlType.shortLink) {
        final service = Provider.of<BilibiliDownloadService>(context, listen: false);
        final resolvedUrl = await service.apiService.resolveShortLink(cleanInput);
        cleanInput = resolvedUrl;
        type = BilibiliUrlParser.determineType(cleanInput);
      }
      return BilibiliUrlParser.extractId(cleanInput, type);
    } catch (_) {
      return null;
    }
  }

  void _showClipboardDialog(String content, BilibiliDownloadTask task, _ClipboardDisplayInfo displayInfo) {
    final title = displayInfo.title;
    final cover = displayInfo.cover;
    
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF2C2C2C),
        contentPadding: EdgeInsets.zero,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (cover.isNotEmpty)
              ClipRRect(
                borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
                child: Image.network(
                  cover,
                  height: 160,
                  fit: BoxFit.cover,
                  errorBuilder: (context, error, stackTrace) => Container(
                    height: 160,
                    color: Colors.grey[800],
                    child: const Icon(Icons.broken_image),
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text("检测到 Bilibili 视频", style: TextStyle(fontSize: 12, color: Colors.blueAccent, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: Colors.white), maxLines: 2, overflow: TextOverflow.ellipsis),
                  if (displayInfo.showCollectionBadge) ...[
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        if ((displayInfo.collectionCover ?? '').isNotEmpty)
                          ClipRRect(
                            borderRadius: BorderRadius.circular(3),
                            child: Image.network(
                              displayInfo.collectionCover!,
                              width: 22,
                              height: 16,
                              fit: BoxFit.cover,
                              errorBuilder: (context, error, stackTrace) => Container(
                                width: 22,
                                height: 16,
                                color: Colors.grey[800],
                              ),
                            ),
                          )
                        else
                          Container(width: 22, height: 16, color: Colors.grey[800]),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            "来自合集：${displayInfo.collectionTitle ?? ''}",
                            style: const TextStyle(fontSize: 11, color: Colors.white54),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 12),
                  const Text("是否前往下载页导入该视频？", style: TextStyle(fontSize: 13, color: Colors.white70)),
                ],
              ),
            )
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("忽略", style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              const routeName = '/bilibili_download';
              if (AppToast.isCurrentRoute(routeName)) {
                Navigator.pushReplacement(
                  context,
                  MaterialPageRoute(
                    builder: (_) => BilibiliDownloadScreen(initialInput: content),
                    settings: const RouteSettings(name: routeName),
                  ),
                );
              } else {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => BilibiliDownloadScreen(initialInput: content),
                    settings: const RouteSettings(name: routeName),
                  ),
                );
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.blueAccent,
              foregroundColor: Colors.white,
            ),
            child: const Text("导入"),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final settings = Provider.of<SettingsService>(context);
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      if (_lastIsFullScreen != settings.isFullScreen) {
        _lastIsFullScreen = settings.isFullScreen;
        if (_lastIsFullScreen == true) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && !_shortcutFocusNode.hasFocus) {
              _shortcutFocusNode.requestFocus();
            }
          });
        }
      }
    }

    return PopScope(
      canPop: !_isSelectionMode,
      onPopInvokedWithResult: (didPop, _) {
            if (didPop) return;
            setState(() {
              _isSelectionMode = false;
              _selectedIds.clear();
              _isBoxSelecting = false;
              _boxStartPos = null;
              _boxCurrentPos = null;
              _capturedIds.clear();
            });
          },
      child: Scaffold(
        backgroundColor: const Color(0xFF121212),
        appBar: AppBar(
        title: _isSelectionMode 
            ? Text("已选择 ${_selectedIds.length} 项") 
            : GestureDetector(
                onTap: _handleTitleTap,
                child: const Text('我的视频库'),
              ),
        centerTitle: true,
        leading: _isSelectionMode 
            ? IconButton(
                icon: const Icon(Icons.close),
                onPressed: () {
                      setState(() {
                        _isSelectionMode = false;
                        _selectedIds.clear();
                        _isBoxSelecting = false;
                        _boxStartPos = null;
                        _boxCurrentPos = null;
                        _capturedIds.clear();
                      });
                    },
              )
            : null,
        actions: [
          if (!_isSelectionMode) ...[
            if (Platform.isWindows || Platform.isLinux || Platform.isMacOS)
              IconButton(
                icon: Icon(settings.isFullScreen ? Icons.fullscreen_exit : Icons.fullscreen),
                tooltip: settings.isFullScreen ? "退出全屏" : "全屏",
                onPressed: () => settings.toggleFullScreen(),
              ),
            if (Platform.isWindows)
              IconButton(
                icon: const Icon(Icons.folder_open),
                tooltip: "大文件目录",
                onPressed: () => _showLargeDataPathDialog(context),
              ),
            if (_showExportSettingsButton)
              IconButton(
                icon: const Icon(Icons.file_download),
                tooltip: "导出设置",
                onPressed: _exportSettingsSnapshot,
              ),
             IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: "回收站",
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const RecycleBinScreen()),
                );
              },
            ),
             IconButton(
              icon: const Icon(Icons.tune),
              tooltip: "调整卡片样式",
              onPressed: () => _showCardStyleBottomSheet(context, settings),
            ),
            IconButton(
              icon: const Icon(Icons.checklist),
              tooltip: "批量管理",
              onPressed: () {
                setState(() {
                  _isSelectionMode = true;
                });
              },
            ),
          ] else ...[
            IconButton(
              icon: const Icon(Icons.select_all),
              tooltip: "全选",
              onPressed: () {
                final library = Provider.of<LibraryService>(context, listen: false);
                final contents = library.getContents(null);
                setState(() {
                  if (_selectedIds.length == contents.length) {
                    _selectedIds.clear();
                  } else {
                    _selectedIds.addAll(contents.map((e) => (e as dynamic).id as String));
                  }
                });
              },
            ),
          ],
        ],
      ),
      body: Focus(
        focusNode: _shortcutFocusNode,
        autofocus: Platform.isWindows,
        onKeyEvent: (node, event) => _handleShortcutKeyEvent(event),
        child: Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: (_) {
            if (Platform.isWindows && !_shortcutFocusNode.hasFocus) {
              _shortcutFocusNode.requestFocus();
            }
          },
          child: Consumer<LibraryService>(
            builder: (context, library, child) {
              final contents = library.getContents(null);

              return DropTarget(
                onDragDone: (details) {
                  if (ModalRoute.of(context)?.isCurrent != true) return;
                  setState(() { _isDraggingFiles = false; });
                  final paths = details.files.map((f) => f.path).toList();
                  if (paths.isNotEmpty) {
                    VideoActionButtons.processImportedFiles(context, paths, null);
                  }
                },
                onDragEntered: (_) {
                  if (ModalRoute.of(context)?.isCurrent != true) return;
                  setState(() => _isDraggingFiles = true);
                },
                onDragExited: (_) => setState(() => _isDraggingFiles = false),
                child: Stack(
                  children: [
                    if (contents.isEmpty)
                      Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Icon(Icons.folder_open, size: 80, color: Colors.white24),
                            const SizedBox(height: 16),
                            const Text("还没有内容", style: TextStyle(color: Colors.white54)),
                            const SizedBox(height: 16),
                            const VideoActionButtons(collectionId: null, isHorizontal: true),
                          ],
                        ),
                      )
                    else ...[
                  GestureDetector(
                    onScaleStart: (details) {
                       // Allow box selection logic (Same as CollectionScreen)
                       bool canStartBoxSelection = false;
                       
                       if (_isSelectionMode) {
                          canStartBoxSelection = true;
                       } else if (Platform.isWindows && details.pointerCount == 1) {
                          canStartBoxSelection = true;
                       }
                       
                       if (canStartBoxSelection) {
                          final renderBox = context.findRenderObject() as RenderBox?;
                          if (renderBox != null) {
                             final contentOffset = details.localFocalPoint + Offset(0, _scrollController.offset);
                             if (_getIndexAt(contentOffset) == null) {
                                // Started on empty area
                                _isBoxSelecting = true;
                                _boxStartPos = details.localFocalPoint;
                                _boxCurrentPos = details.localFocalPoint;
                                _capturedIds.clear(); 
                                
                                if (_isSelectionMode) {
                                   _dragSelectionSnapshot = Set.from(_selectedIds);
                                } else {
                                   _dragSelectionSnapshot.clear();
                                }
                                
                                setState(() {});
                                return;
                             }
                          }
                       }
                      _baseCrossAxisCount = settings.homeGridCrossAxisCount;
                    },
                    onScaleUpdate: (details) {
                      if (_isBoxSelecting) {
                         setState(() {
                           _boxCurrentPos = details.localFocalPoint;
                         });
                         
                         if (_boxStartPos != null && _boxCurrentPos != null) {
                            final rect = Rect.fromPoints(_boxStartPos!, _boxCurrentPos!);
                            final contentRect = rect.shift(Offset(0, _scrollController.offset));
                            
                            final Set<String> currentInBox = {};
                            final count = _getItemCount();
                            
                            // Optimization: Only check items in the visible range of the selection box
                            // Pre-calculate layout parameters to avoid repeated Provider/MediaQuery calls
                            final double screenWidth = MediaQuery.of(context).size.width;
                            const double spacing = 16.0;
                            const double hPadding = 16.0;
                            const double topPadding = 16.0;
                            
                            final double totalSpacing = (settings.homeGridCrossAxisCount - 1) * spacing + (hPadding * 2);
                            final double itemWidth = (screenWidth - totalSpacing) / settings.homeGridCrossAxisCount;
                            final double itemHeight = itemWidth / settings.homeCardAspectRatio;

                            // Calculate grid range affected by contentRect
                            int minRow = ((contentRect.top - topPadding) / (itemHeight + spacing)).floor();
                            int maxRow = ((contentRect.bottom - topPadding) / (itemHeight + spacing)).floor();
                            int minCol = ((contentRect.left - hPadding) / (itemWidth + spacing)).floor();
                            int maxCol = ((contentRect.right - hPadding) / (itemWidth + spacing)).floor();

                            // Clamp ranges
                            if (minRow < 0) minRow = 0;
                            if (minCol < 0) minCol = 0;
                            if (maxCol >= settings.homeGridCrossAxisCount) maxCol = settings.homeGridCrossAxisCount - 1;

                            // Iterate only through potentially overlapping items
                            for (int row = minRow; row <= maxRow; row++) {
                               for (int col = minCol; col <= maxCol; col++) {
                                  final index = row * settings.homeGridCrossAxisCount + col;
                                  if (index >= 0 && index < count) {
                                     final double x = hPadding + col * (itemWidth + spacing);
                                     final double y = topPadding + row * (itemHeight + spacing);
                                     final itemRect = Rect.fromLTWH(x, y, itemWidth, itemHeight);

                                     if (itemRect.overlaps(contentRect)) {
                                        final id = _getItemId(index);
                                        if (id != null) currentInBox.add(id);
                                     }
                                  }
                               }
                            }
                            
                            if (!_isSelectionMode) {
                               // Visual only
                            } else {
                               _capturedIds.addAll(currentInBox);
                               
                               final Set<String> newSelection = {};
                               for (final id in _dragSelectionSnapshot) {
                                   if (!_capturedIds.contains(id)) {
                                       newSelection.add(id);
                                   }
                               }
                               newSelection.addAll(currentInBox);
                               
                               if (newSelection.length != _selectedIds.length || !_selectedIds.containsAll(newSelection)) {
                                  _selectedIds.clear();
                                  _selectedIds.addAll(newSelection);
                                  if (Platform.isAndroid || Platform.isIOS) {
                                     HapticFeedback.selectionClick();
                                  }
                               }
                            }
                         }
                         return;
                      }
                      
                      // Pinch to Zoom Logic
                      // We use a sensitivity factor to make it feel more "natural"
                      // Scale > 1 means zooming in (fewer columns)
                      // Scale < 1 means zooming out (more columns)
                      
                      double newScale = details.scale;
                      int newCount = _baseCrossAxisCount;
                      
                      if (newScale > 1.3) {
                         newCount = (_baseCrossAxisCount - 1).clamp(1, 5);
                      } else if (newScale < 0.7) {
                         newCount = (_baseCrossAxisCount + 1).clamp(1, 5);
                      }
                      
                      // Only update if changed to avoid unnecessary rebuilds
                      if (newCount != settings.homeGridCrossAxisCount) {
                        // HapticFeedback.selectionClick(); // Optional: feedback
                        settings.updateSetting('homeGridCrossAxisCount', newCount);
                      }
                    },
                    onScaleEnd: (details) {
                       if (_isBoxSelecting) {
                          if (!_isSelectionMode && _boxStartPos != null && _boxCurrentPos != null) {
                             final rect = Rect.fromPoints(_boxStartPos!, _boxCurrentPos!);
                             final contentRect = rect.shift(Offset(0, _scrollController.offset));
                             
                             final Set<String> newSelected = {};
                             final count = _getItemCount();
                             
                             for (int i = 0; i < count; i++) {
                                final itemRect = _getItemRect(i);
                                if (itemRect != null && itemRect.overlaps(contentRect)) {
                                   final id = _getItemId(i);
                                   if (id != null) newSelected.add(id);
                                }
                             }
                             
                             if (newSelected.isNotEmpty) {
                                setState(() {
                                   _isSelectionMode = true;
                                   _selectedIds.addAll(newSelected);
                                });
                             }
                          }
                          
                          setState(() {
                            _isBoxSelecting = false;
                            _boxStartPos = null;
                            _boxCurrentPos = null;
                            _capturedIds.clear();
                          });
                          return;
                       }
                    },
                    child: Container(
                      height: MediaQuery.of(context).size.height,
                      color: Colors.transparent,
                      child: GridView.builder(
                      controller: _scrollController,
                      padding: EdgeInsets.only(
                        left: 16,
                        right: 16,
                        top: 16,
                        bottom: 16 + _getPlaybackCardBottomPadding(),
                      ),
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: settings.homeGridCrossAxisCount.clamp(1, 10),
                        childAspectRatio: settings.homeCardAspectRatio.clamp(0.1, 5.0), 
                        crossAxisSpacing: 16,
                        mainAxisSpacing: 16,
                      ),
                      itemCount: contents.length,
                      itemBuilder: (context, index) {
                        final item = contents[index];
                        if (item is VideoCollection) {
                          return _buildCollectionCard(context, library, item, index, settings, contents);
                        } else if (item is VideoItem) {
                          return _buildVideoCard(context, item, index, settings, contents);
                        }
                        return const SizedBox.shrink();
                      },
                    ),
                  ),
                  ),
                  // Fill the rest of the screen with a transparent hit target to ensure GestureDetector catches taps in empty space
                  if (contents.length < 20) 
                    Positioned.fill(
                       child: Listener(
                          behavior: HitTestBehavior.translucent,
                          onPointerDown: (_) {}, 
                       ),
                    ),
                  if (_isBoxSelecting && _boxStartPos != null && _boxCurrentPos != null && !_isSelectionMode)
                    Positioned.fill(
                      child: IgnorePointer(
                        child: CustomPaint(
                          painter: _BoxSelectionPainter(
                            selectionRect: Rect.fromPoints(_boxStartPos!, _boxCurrentPos!),
                          ),
                        ),
                      ),
                    ),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: Consumer<MediaPlaybackService>(
                      builder: (context, playbackService, child) {
                        final isVisible = playbackService.currentItem != null &&
                            (playbackService.state == PlaybackState.playing ||
                             playbackService.state == PlaybackState.paused);
                        if (!isVisible) return const SizedBox.shrink();
                        return Container(
                          height: _getPlaybackCardVerticalOffset(),
                          color: const Color(0xFF2C2C2C),
                        );
                      },
                    ),
                  ),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: _getPlaybackCardVerticalOffset(),
                    child: Consumer<MediaPlaybackService>(
                      builder: (context, playbackService, child) {
                        final isVisible = playbackService.currentItem != null &&
                            (playbackService.state == PlaybackState.playing ||
                             playbackService.state == PlaybackState.paused);
                        
                        return MiniPlaybackCard(
                          isVisible: isVisible,
                          onTap: () async {
                            // 点击卡片进入全屏播放页面
                            final currentItem = playbackService.currentItem;
                            if (currentItem == null) return;
                            final exists = await File(currentItem.path).exists();
                            if (!context.mounted) return;
                            if (!exists) {
                              AppToast.show("媒体文件不存在，可能已被移动或删除", type: AppToastType.error);
                              return;
                            }
                            
                            // 1. 立即触发一次 UI 刷新，防止点击卡顿感
                            setState(() {});
                            
                            // 2. 短暂延迟，让 UI 引擎有时间处理可能的积压帧或窗口状态更新
                            await Future.delayed(const Duration(milliseconds: 150));
                            if (!context.mounted) return;

                            // 3. 再次强制刷新 (Superstitious refresh requested by user)
                            setState(() {});
                            
                            Navigator.of(context, rootNavigator: true).push(
                              _buildVideoPlayerRoute(currentItem, playbackService.controller),
                            );
                          },
                        );
                      },
                    ),
                  ),
                  ],
                  if (_isDraggingFiles)
                    Positioned.fill(
                      child: Container(
                        color: Colors.black54,
                        child: const Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.cloud_upload, size: 80, color: Colors.blueAccent),
                              SizedBox(height: 16),
                              Text(
                                "松开以导入媒体文件",
                                style: TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              );
            },
          ),
        ),
      ),
      floatingActionButton: !_isSelectionMode 
          ? Padding(
              padding: EdgeInsets.only(bottom: _getPlaybackCardBottomPadding()),
              child: const VideoActionButtons(collectionId: null),
            )
          : null,
      bottomNavigationBar: _isSelectionMode && _selectedIds.isNotEmpty
          ? BottomAppBar(
              color: const Color(0xFF1E1E1E),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  TextButton.icon(
                    icon: const Icon(Icons.delete, color: Colors.redAccent),
                    label: const Text("移入回收站", style: TextStyle(color: Colors.redAccent)),
                    onPressed: () {
                      final library = Provider.of<LibraryService>(context, listen: false);
                      library.moveToRecycleBin(_selectedIds.toList());
                      setState(() {
                        _selectedIds.clear();
                        _isSelectionMode = false;
                      });
                      AppToast.show("已移入回收站", type: AppToastType.success);
                    },
                  ),
                  if (_selectedIds.length == 1)
                    TextButton.icon(
                      icon: const Icon(Icons.edit, color: Colors.blueAccent),
                      label: const Text("重命名", style: TextStyle(color: Colors.blueAccent)),
                      onPressed: () {
                        final library = Provider.of<LibraryService>(context, listen: false);
                        final id = _selectedIds.first;
                        // Find item name
                        final col = library.getCollection(id);
                        final vid = library.getVideo(id);
                        final name = col?.name ?? vid?.title ?? "";
                        
                        _showRenameDialog(context, id, name);
                      },
                    ),
                ],
              ),
            )
          : null,
      ),
    );
  }

  Widget _buildCollectionCard(
      BuildContext context, 
      LibraryService library, 
      VideoCollection collection, 
      int index,
      SettingsService settings,
      List<dynamic> contents
  ) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final double cardWidth = constraints.maxWidth;
        final double radius = (cardWidth * 0.09).clamp(4.0, 40.0);

        final isSelected = _selectedIds.contains(collection.id);
        final thumbnailPath = collection.thumbnailPath;
        final hasThumbnail = thumbnailPath != null && thumbnailPath.isNotEmpty;
        
        // 1. The Visual Content of the Card
        Widget cardVisual = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Thumbnail Area (Fixed Folder Icon)
            AspectRatio(
              aspectRatio: 4 / 3,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final iconSize = constraints.maxWidth * 0.15;
                  final iconPadding = iconSize * 0.4;
                  final borderRadius = iconSize * 0.6;
                  final centerIconSize = constraints.maxWidth * 0.55;

                  return Container(
                    color: Colors.black26,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        // Layer 1: Thumbnail or Placeholder
                        hasThumbnail
                            ? CachedThumbnailWidget(
                                videoId: collection.id,
                                thumbnailPath: thumbnailPath,
                                cacheWidth: 512,
                                cacheHeight: 384,
                                placeholder: const SizedBox.expand(
                                  child: ColoredBox(color: Colors.black26),
                                ),
                                errorWidget: Center(
                                  child: Icon(
                                    Icons.folder,
                                    size: centerIconSize,
                                    color: Colors.blueAccent.withValues(alpha: 0.8),
                                  ),
                                ),
                              )
                            : Center(
                                child: Icon(
                                  Icons.folder,
                                  size: centerIconSize,
                                  color: Colors.blueAccent.withValues(alpha: 0.8),
                                ),
                              ),
                        // Layer 2: Folder Badge (Top-Left) - Only if has thumbnail
                        if (hasThumbnail)
                          Positioned(
                            left: 0,
                            top: 0,
                            child: Container(
                              padding: EdgeInsets.all(iconPadding),
                              decoration: BoxDecoration(
                                color: Colors.black45,
                                borderRadius: BorderRadius.only(
                                  bottomRight: Radius.circular(borderRadius),
                                ),
                              ),
                              child: Icon(
                                Icons.folder,
                                size: iconSize,
                                color: Colors.blueAccent.withValues(alpha: 0.9),
                              ),
                            ),
                          ),
                      ],
                    ),
                  );
                },
              ),
            ),
            // Info Area
            Expanded(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                color: isSelected ? Colors.blueAccent.withValues(alpha: 0.1) : Colors.transparent,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        collection.name,
                        style: TextStyle(
                          fontSize: settings.homeCardTitleFontSize, 
                          fontWeight: FontWeight.w600,
                          color: Colors.white,
                        ),
                        maxLines: 10, 
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      "${collection.childrenIds.length} 个项目",
                      style: const TextStyle(fontSize: 11, color: Colors.white54),
                    ),
                  ],
                ),
              ),
            ),
          ],
        );

        // 2. Interaction Wrapper
        Widget interactiveCard = Card(
          color: isSelected ? Colors.blueAccent.withValues(alpha: 0.2) : const Color(0xFF2C2C2C),
          elevation: isSelected ? 4 : 2,
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radius),
            side: isSelected ? const BorderSide(color: Colors.blueAccent, width: 2) : BorderSide.none,
          ),
          child: InkWell(
            onTap: () {
              if (_isSelectionMode) {
                setState(() {
                  if (isSelected) {
                    _selectedIds.remove(collection.id);
                  } else {
                    _selectedIds.add(collection.id);
                  }
                });
              } else {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (context) => CollectionScreen(collectionId: collection.id),
                  ),
                );
              }
            },
            child: cardVisual,
          ),
        );

        return Stack(
          children: [
            LongPressDraggable<int>(
              delay: const Duration(milliseconds: 160),
              data: index,
              onDragStarted: () {
                if (!_isSelectionMode) {
                  setState(() {
                    _isSelectionMode = true;
                    if (!_selectedIds.contains(collection.id)) {
                      _selectedIds.add(collection.id);
                    }
                  });
                }
              },
              feedback: SizedBox(
                width: 140,
                height: 160,
                child: Opacity(
                  opacity: 0.9, 
                  child: Card(
                    color: const Color(0xFF333333),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(140 * 0.09)),
                    child: Center(
                      child: _selectedIds.length > 1 && isSelected
                          ? Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                const Icon(Icons.folder, size: 50, color: Colors.blueAccent),
                                Text(
                                  "${_selectedIds.length} 个项目",
                                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                                )
                              ],
                            )
                          : Icon(Icons.folder, size: 60, color: Colors.blueAccent),
                    ),
                  )
                ),
              ),
              childWhenDragging: Opacity(
                opacity: 0.3,
                child: interactiveCard,
              ),
              child: FolderDropTarget(
                folderId: collection.id,
                index: index,
                onMoveToFolder: (draggedIndex, targetId) {
                  if (draggedIndex >= 0 && draggedIndex < contents.length) {
                    final draggedItem = contents[draggedIndex];
                    final draggedId = (draggedItem as dynamic).id;
                    
                    List<String> itemsToMove = [];
                    if (_selectedIds.contains(draggedId)) {
                       itemsToMove = contents
                           .where((item) => _selectedIds.contains((item as dynamic).id))
                           .map((item) => (item as dynamic).id as String)
                           .toList();
                    } else {
                       itemsToMove = [draggedId];
                    }

                    library.moveItemsToCollection(itemsToMove, targetId);
                    AppToast.show("已移动到文件夹", type: AppToastType.success);
                  }
                },
                onReorder: (oldIndex, newIndex) {
                  final draggedItem = contents[oldIndex];
                  final draggedId = (draggedItem as dynamic).id;

                  if (_selectedIds.contains(draggedId)) {
                     final itemsToMove = contents
                          .where((item) => _selectedIds.contains((item as dynamic).id))
                          .map((item) => (item as dynamic).id as String)
                          .toList();
                     library.reorderMultipleItems(null, itemsToMove, oldIndex, newIndex);
                  } else {
                     library.reorderItems(null, oldIndex, newIndex);
                  }
                },
                child: interactiveCard,
              ),
            ),
            if (_isSelectionMode)
              Positioned(
                top: 0,
                right: 0,
                child: GestureDetector(
                  onTap: () {
                    setState(() {
                      if (isSelected) {
                        _selectedIds.remove(collection.id);
                      } else {
                        _selectedIds.add(collection.id);
                      }
                    });
                  },
                  onPanStart: (details) {
                    setState(() {
                       _dragSelectionStartIndex = index;
                       _dragSelectionSnapshot = Set.from(_selectedIds);
                       _capturedIds.clear();
                       _isBoxSelecting = false;
                       _boxStartPos = null;
                       _boxCurrentPos = null;
                       if (!_selectedIds.contains(collection.id)) {
                          _selectedIds.add(collection.id);
                          _dragSelectionSnapshot.add(collection.id);
                       }
                       _updateDragSelection(details.globalPosition);
                    });
                  },
                  onPanUpdate: (details) {
                    _updateDragSelection(details.globalPosition);
                  },
                  onPanEnd: (details) {
                    setState(() {
                      _dragSelectionStartIndex = null;
                      _dragSelectionSnapshot.clear();
                      _isBoxSelecting = false;
                      _boxStartPos = null;
                      _boxCurrentPos = null;
                      _capturedIds.clear();
                    });
                  },
                  onLongPressStart: (details) {
                    setState(() {
                       _dragSelectionStartIndex = index;
                       _dragSelectionSnapshot = Set.from(_selectedIds);
                       _capturedIds.clear();
                       _isBoxSelecting = false;
                       _boxStartPos = null;
                       _boxCurrentPos = null;
                       if (!_selectedIds.contains(collection.id)) {
                          _selectedIds.add(collection.id);
                          _dragSelectionSnapshot.add(collection.id);
                       }
                       _updateDragSelection(details.globalPosition);
                    });
                  },
                  onLongPressMoveUpdate: (details) {
                    _updateDragSelection(details.globalPosition);
                  },
                  onLongPressEnd: (details) {
                    setState(() {
                      _dragSelectionStartIndex = null;
                      _dragSelectionSnapshot.clear();
                      _isBoxSelecting = false;
                      _boxStartPos = null;
                      _boxCurrentPos = null;
                      _capturedIds.clear();
                    });
                  },
                  behavior: HitTestBehavior.opaque,
                  child: Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Icon(
                      isSelected ? Icons.check_circle : Icons.circle_outlined,
                      color: isSelected ? Colors.blueAccent : Colors.white70,
                      size: 24,
                    ),
                  ),
                ),
              ),
          ],
        );
      }
    );
  }


  Widget _buildVideoCard(
      BuildContext context, 
      VideoItem item, 
      int index,
      SettingsService settings,
      List<dynamic> contents
  ) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final double cardWidth = constraints.maxWidth;
        final double radius = (cardWidth * 0.09).clamp(4.0, 40.0);

        final isSelected = _selectedIds.contains(item.id);
        
        // 1. Visual Content
        Widget cardVisual = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Thumbnail Area
            AspectRatio(
              aspectRatio: 4 / 3,
              child: Container(
                color: Colors.black26,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    item.thumbnailPath != null && File(item.thumbnailPath!).existsSync()
                        ? Image.file(
                            File(item.thumbnailPath!),
                            fit: BoxFit.cover,
                            errorBuilder: (context, error, stackTrace) =>
                                const Icon(Icons.broken_image, size: 50),
                          )
                        : Container(
                            color: Colors.black,
                            child: Icon(
                              item.type == MediaType.audio ? Icons.music_note : Icons.movie,
                              size: 50,
                              color: Colors.white24,
                            ),
                          ),
                    Positioned(
                      bottom: 0,
                      left: 0,
                      right: 0,
                      child: Selector<MediaPlaybackService, ({bool isCurrent, int positionMs, int durationMs})>(
                        selector: (context, service) {
                          final isCurrent = service.currentItem?.id == item.id;
                          if (!isCurrent) {
                            return (isCurrent: false, positionMs: 0, durationMs: 0);
                          }
                          return (
                            isCurrent: true,
                            positionMs: service.position.inMilliseconds,
                            durationMs: service.duration.inMilliseconds,
                          );
                        },
                        builder: (context, data, child) {
                          final bool isCurrent = data.isCurrent;
                          final int durationMs = isCurrent ? data.durationMs : item.durationMs;
                          final int positionMs = isCurrent ? data.positionMs : item.lastPositionMs;

                          final shouldShow = durationMs > 0 && (isCurrent || positionMs > 0);
                          if (!shouldShow) return const SizedBox.shrink();

                          final value = (positionMs / durationMs).clamp(0.0, 1.0);
                          return SizedBox(
                            height: 4,
                            child: LinearProgressIndicator(
                              value: value,
                              backgroundColor: Colors.white24,
                              color: Colors.redAccent,
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        item.title,
                        style: TextStyle(
                          fontSize: settings.homeCardTitleFontSize, 
                          fontWeight: FontWeight.w500,
                          color: Colors.white,
                        ),
                        maxLines: 10, 
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (item.durationMs > 0) ...[
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                               "${(item.durationMs / 1000 / 60).floor()}:${((item.durationMs / 1000) % 60).floor().toString().padLeft(2, '0')}",
                               style: const TextStyle(fontSize: 10, color: Colors.white54),
                            ),
                          ),

                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        );

        // 2. Interaction Wrapper
        Widget interactiveCard = Card(
          clipBehavior: Clip.antiAlias,
          color: isSelected ? Colors.blueAccent.withValues(alpha: 0.2) : const Color(0xFF2C2C2C),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radius),
            side: isSelected ? const BorderSide(color: Colors.blueAccent, width: 2) : BorderSide.none,
          ),
          child: InkWell(
            onTap: () async {
              if (_isSelectionMode) {
                setState(() {
                  if (isSelected) {
                    _selectedIds.remove(item.id);
                  } else {
                    _selectedIds.add(item.id);
                  }
                });
              } else {
                // 通过 MediaPlaybackService 开始播放
                final playbackService = Provider.of<MediaPlaybackService>(context, listen: false);
                final playlistManager = Provider.of<PlaylistManager>(context, listen: false);
                final navigator = Navigator.of(context);

                final file = File(item.path);
                if (!await file.exists()) {
                  if (!context.mounted) return;
                  AppToast.show("媒体文件不存在，可能已被移动或删除", type: AppToastType.error);
                  return;
                }
                
                // 加载播放列表（同文件夹的所有媒体）
                playlistManager.loadFolderPlaylist(item.parentId, item.id);

                // 进入播放页面
                if (!mounted) return;

                // 仅当当前播放的视频与点击的视频一致时，才复用控制器
                // 否则传入 null，让 VideoPlayerScreen 自行处理初始化（它会调用 MediaPlaybackService.play）
                final currentController = playbackService.currentItem?.id == item.id 
                    ? playbackService.controller 
                    : null;

                // 1. 立即触发一次 UI 刷新，防止点击卡顿感
                setState(() {});
                
                // 2. 短暂延迟，让 UI 引擎有时间处理可能的积压帧或窗口状态更新
                await Future.delayed(const Duration(milliseconds: 150));
                if (!context.mounted) return;

                // 3. 再次强制刷新 (Superstitious refresh requested by user)
                setState(() {});

                navigator.push(
                  _buildVideoPlayerRoute(item, currentController),
                );
              }
            },
            child: cardVisual,
          ),
        );

        return Stack(
          children: [
            LongPressDraggable<int>(
              delay: const Duration(milliseconds: 160),
              data: index,
              onDragStarted: () {
                if (!_isSelectionMode) {
                  setState(() {
                    _isSelectionMode = true;
                    if (!_selectedIds.contains(item.id)) {
                      _selectedIds.add(item.id);
                    }
                  });
                }
              },
              feedback: SizedBox(
                width: 140,
                height: 160,
                child: Opacity(
                  opacity: 0.9, 
                  child: Card(
                    color: const Color(0xFF333333),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(140 * 0.09)),
                    child: Center(
                      child: _selectedIds.length > 1 && isSelected
                          ? Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                const Icon(Icons.movie, size: 50, color: Colors.blueAccent),
                                Text(
                                  "${_selectedIds.length} 个项目",
                                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                                )
                              ],
                            )
                          : Icon(Icons.movie, size: 60, color: Colors.blueAccent),
                    ),
                  )
                ),
              ),
              childWhenDragging: Opacity(
                opacity: 0.3,
                child: interactiveCard,
              ),
              child: DragTarget<int>(
                onWillAcceptWithDetails: (details) => details.data != index,
                onAcceptWithDetails: (details) {
                  final oldIndex = details.data;
                  final library = Provider.of<LibraryService>(context, listen: false);
                  final draggedItem = contents[oldIndex];
                  final draggedId = (draggedItem as dynamic).id;

                  if (_selectedIds.contains(draggedId)) {
                     final itemsToMove = contents
                          .where((item) => _selectedIds.contains((item as dynamic).id))
                          .map((item) => (item as dynamic).id as String)
                          .toList();
                     library.reorderMultipleItems(null, itemsToMove, oldIndex, index);
                  } else {
                     library.reorderItems(null, oldIndex, index);
                  }
                },
                builder: (context, candidateData, rejectedData) {
                  Widget targetChild = interactiveCard;
                  if (candidateData.isNotEmpty) {
                     targetChild = Container(
                       decoration: BoxDecoration(
                         border: Border.all(color: Colors.blueAccent, width: 2),
                         borderRadius: BorderRadius.circular(radius),
                       ),
                       child: interactiveCard,
                     );
                  }
                  return targetChild;
                },
              ),
            ),
            if (_isSelectionMode)
              Positioned(
                top: 0,
                right: 0,
                child: GestureDetector(
                  onTap: () {
                    setState(() {
                      if (isSelected) {
                        _selectedIds.remove(item.id);
                      } else {
                        _selectedIds.add(item.id);
                      }
                    });
                  },
                  onPanStart: (details) {
                    setState(() {
                       _dragSelectionStartIndex = index;
                       _dragSelectionSnapshot = Set.from(_selectedIds);
                       _capturedIds.clear();
                       _isBoxSelecting = false;
                       _boxStartPos = null;
                       _boxCurrentPos = null;
                       if (!_selectedIds.contains(item.id)) {
                          _selectedIds.add(item.id);
                          _dragSelectionSnapshot.add(item.id);
                       }
                       _updateDragSelection(details.globalPosition);
                    });
                  },
                  onPanUpdate: (details) {
                    _updateDragSelection(details.globalPosition);
                  },
                  onPanEnd: (details) {
                    setState(() {
                      _dragSelectionStartIndex = null;
                      _dragSelectionSnapshot.clear();
                      _isBoxSelecting = false;
                      _boxStartPos = null;
                      _boxCurrentPos = null;
                      _capturedIds.clear();
                    });
                  },
                  onLongPressStart: (details) {
                    setState(() {
                       _dragSelectionStartIndex = index;
                       _dragSelectionSnapshot = Set.from(_selectedIds);
                       _capturedIds.clear();
                       _isBoxSelecting = false;
                       _boxStartPos = null;
                       _boxCurrentPos = null;
                       if (!_selectedIds.contains(item.id)) {
                          _selectedIds.add(item.id);
                          _dragSelectionSnapshot.add(item.id);
                       }
                       _updateDragSelection(details.globalPosition);
                    });
                  },
                  onLongPressMoveUpdate: (details) {
                    _updateDragSelection(details.globalPosition);
                  },
                  onLongPressEnd: (details) {
                    setState(() {
                      _dragSelectionStartIndex = null;
                      _dragSelectionSnapshot.clear();
                      _isBoxSelecting = false;
                      _boxStartPos = null;
                      _boxCurrentPos = null;
                      _capturedIds.clear();
                    });
                  },
                  behavior: HitTestBehavior.opaque,
                  child: Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Icon(
                      isSelected ? Icons.check_circle : Icons.circle_outlined,
                      color: isSelected ? Colors.blueAccent : Colors.white70,
                      size: 24,
                    ),
                  ),
                ),
              ),
          ],
        );
      }
    );
  }









  void _showRenameDialog(BuildContext context, String id, String currentName) {
    final controller = TextEditingController(text: currentName);
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("重命名"),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(hintText: "输入新名称"),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("取消"),
          ),
          TextButton(
            onPressed: () {
              if (controller.text.isNotEmpty) {
                Provider.of<LibraryService>(context, listen: false)
                    .renameItem(id, controller.text);
                Navigator.pop(context);
                
                // Exit selection mode or just clear selection?
                // User might want to rename multiple items one by one.
                // But usually rename is a single item action.
                // Let's keep selection mode but maybe update the name in the UI is automatic.
              }
            },
            child: const Text("确定"),
          ),
        ],
      ),
    );
  }

  Future<void> _showLargeDataPathDialog(BuildContext context) async {
    if (!Platform.isWindows) return;
    final settings = Provider.of<SettingsService>(context, listen: false);
    final library = Provider.of<LibraryService>(context, listen: false);
    final defaultPath = await settings.getDefaultLargeDataRootPath();
    String tempPath = settings.largeDataRootPath ?? defaultPath;

    if (!context.mounted) return;
    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          backgroundColor: const Color(0xFF2C2C2C),
          title: const Text("大文件数据目录", style: TextStyle(color: Colors.white)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text("当前目录", style: TextStyle(color: Colors.white70)),
              const SizedBox(height: 6),
              Text(tempPath, style: const TextStyle(color: Colors.white)),
              const SizedBox(height: 12),
              const Text("默认目录", style: TextStyle(color: Colors.white70)),
              const SizedBox(height: 6),
              Text(defaultPath, style: const TextStyle(color: Colors.white)),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton(
                      onPressed: () async {
                        final result = await FilePicker.platform.getDirectoryPath();
                        if (result != null && result.isNotEmpty) {
                          setState(() => tempPath = result);
                        }
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF3A3A3A),
                        foregroundColor: Colors.white,
                      ),
                      child: const Text("选择目录"),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextButton(
                      onPressed: () => setState(() => tempPath = defaultPath),
                      child: const Text("恢复默认", style: TextStyle(color: Colors.white70)),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              const Text(
                "修改后会迁移媒体库视频、缩略图和字幕到新目录。",
                style: TextStyle(color: Colors.white54, fontSize: 12),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text("取消", style: TextStyle(color: Colors.grey)),
            ),
            ElevatedButton(
              onPressed: () async {
                final ok = await library.migrateLargeDataRoot(tempPath);
                if (!context.mounted) return;
                if (ok) {
                  AppToast.show("迁移完成", type: AppToastType.success);
                  Navigator.pop(context);
                } else {
                  AppToast.show("迁移失败，请检查目录权限", type: AppToastType.error);
                }
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF4F7BF5),
                foregroundColor: Colors.white,
              ),
              child: const Text("应用并迁移"),
            ),
          ],
        ),
      ),
    );
  }

  void _showCardStyleBottomSheet(BuildContext context, SettingsService settings) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        // Initialize local state from settings
        double tempFontSize = settings.homeCardTitleFontSize;
        // Invert Aspect Ratio for "Height Scale": Value = 1 / AspectRatio
        // Higher Value = Taller Card
        double tempHeightScale = 1.0 / settings.homeCardAspectRatio;
        double tempColumnCount = settings.homeGridCrossAxisCount.toDouble();

        return StatefulBuilder(
          builder: (context, setSheetState) {
            return Container(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
              height: 450,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text("卡片样式调整", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white)),
                  const SizedBox(height: 24),

                  // 1. Grid Columns Slider
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text("每行卡片数量", style: TextStyle(color: Colors.white70)),
                      Text("${tempColumnCount.toInt()} 列", style: const TextStyle(color: Colors.blueAccent, fontWeight: FontWeight.bold)),
                    ],
                  ),
                  SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      activeTrackColor: Colors.blueAccent,
                      thumbColor: Colors.blueAccent,
                      overlayColor: Colors.blueAccent.withValues(alpha: 0.2),
                      trackHeight: 4,
                    ),
                    child: Slider(
                      value: tempColumnCount,
                      min: 1,
                      max: 8,
                      divisions: 7,
                      label: tempColumnCount.toInt().toString(),
                      onChanged: (val) {
                        setSheetState(() {
                          tempColumnCount = val;
                        });
                      },
                      onChangeEnd: (val) {
                         if (val.round() != settings.homeGridCrossAxisCount) {
                           settings.updateSetting('homeGridCrossAxisCount', val.round());
                         }
                      },
                    ),
                  ),

                  const SizedBox(height: 16),
                  
                  // 2. Font Size Slider
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text("标题字号", style: TextStyle(color: Colors.white70)),
                      Text("${tempFontSize.toInt()}", style: const TextStyle(color: Colors.blueAccent, fontWeight: FontWeight.bold)),
                    ],
                  ),
                  SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      activeTrackColor: Colors.blueAccent,
                      thumbColor: Colors.blueAccent,
                      overlayColor: Colors.blueAccent.withValues(alpha: 0.2),
                      trackHeight: 4,
                    ),
                    child: Slider(
                      value: tempFontSize,
                      min: 1,
                      max: 24,
                      divisions: 23,
                      label: tempFontSize.toInt().toString(),
                      onChanged: (val) {
                        setSheetState(() {
                          tempFontSize = val;
                        });
                        settings.updateSetting('homeCardTitleFontSize', val);
                      },
                    ),
                  ),
                  
                  const SizedBox(height: 16),
                  
                  // 3. Card Height Slider (Inverted Logic)
                  // Min: 0.8 (Short, Ratio ~1.25)
                  // Max: 2.0 (Tall, Ratio ~0.5)
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text("卡片高度", style: TextStyle(color: Colors.white70)),
                      Text(tempHeightScale.toStringAsFixed(2), style: const TextStyle(color: Colors.blueAccent, fontWeight: FontWeight.bold)),
                    ],
                  ),
                  SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      activeTrackColor: Colors.blueAccent,
                      thumbColor: Colors.blueAccent,
                      overlayColor: Colors.blueAccent.withValues(alpha: 0.2),
                      trackHeight: 4,
                    ),
                    child: Slider(
                      value: tempHeightScale.clamp(0.8, 2.0),
                      min: 0.8,
                      max: 2.0,
                      divisions: 12,
                      label: tempHeightScale.toStringAsFixed(2),
                      onChanged: (val) {
                         setSheetState(() {
                           tempHeightScale = val;
                         });
                         // Convert "Height Scale" back to Aspect Ratio
                         // AspectRatio = 1 / HeightScale
                         settings.updateSetting('homeCardAspectRatio', 1.0 / val);
                      },
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}
