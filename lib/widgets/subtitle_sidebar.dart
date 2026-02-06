import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:video_player/video_player.dart';
import '../services/settings_service.dart';
import '../models/subtitle_model.dart';

class SubtitleSidebar extends StatefulWidget {
  final List<SubtitleItem> subtitles;
  final List<SubtitleItem> secondarySubtitles; // New
  final VideoPlayerController controller;
  final ValueChanged<Duration>? onItemTap;
  final VoidCallback? onClose;
  final VoidCallback? onOpenSettings;
  final VoidCallback? onLoadSubtitle;
  final VoidCallback? onOpenSubtitleStyle;
  final VoidCallback? onOpenSubtitleManager;
  final VoidCallback? onClearSelection;
  final VoidCallback? onScanEmbeddedSubtitles;
  final bool isCompact;
  final bool isPortrait;
  final FocusNode? focusNode; // New
  final bool isVisible;
  final bool showEmbeddedLoadingMessage;

  const SubtitleSidebar({
    super.key,
    required this.subtitles,
    this.secondarySubtitles = const [], // Default empty
    required this.controller,
    this.onItemTap,
    this.onClose,
    this.onOpenSettings,
    this.onLoadSubtitle,
    this.onOpenSubtitleStyle,
    this.onOpenSubtitleManager,
    this.onClearSelection,
    this.onScanEmbeddedSubtitles,
    this.isCompact = false,
    this.isPortrait = false,
    this.focusNode,
    this.isVisible = true,
    this.showEmbeddedLoadingMessage = false,
  });

  @override
  State<SubtitleSidebar> createState() => SubtitleSidebarState();
}

class SubtitleSidebarState extends State<SubtitleSidebar> {
  bool _isArticleMode = false; // 默认为列表模式
  int _lineFilterMode = 0; // 0: 全部, 1: 第一行, 2: 第二行
  // bool _isAutoScroll = false; // Moved to SettingsService
  double _fontSizeScale = 1.0; // 字体缩放比例
  bool _showFontSettings = false; // 是否显示字体设置
  
  // 滚动控制器
  final ItemScrollController _itemScrollController = ItemScrollController();
  final ItemPositionsListener _itemPositionsListener = ItemPositionsListener.create();
  
  // 自动滚动相关
  final ValueNotifier<int> _activeIndexNotifier = ValueNotifier<int>(-1);
  final ValueNotifier<List<int>> _activeIndicesNotifier = ValueNotifier<List<int>>(<int>[]);
  final List<int> _subtitleStartMs = <int>[];
  int _lastIndexComputeAtMs = 0;
  int _lastIndexComputePosMs = -1;
  Timer? _autoScrollTimer;
  int _activePointerCount = 0;
  int? _pointerDownStartIndex;

  // Article Mode Scroll Controller
  static const int _articleChunkSize = 4; // Smaller chunk size for better precision
  final ItemScrollController _articleItemScrollController = ItemScrollController();
  final ItemPositionsListener _articleItemPositionsListener = ItemPositionsListener.create();

  // Cached matches to avoid O(N^2) or repeated searches
  // Key: Primary Index, Value: Secondary Text
  final Map<int, String> _secondaryTextCache = {};
  bool _isBilingualMode = false;

  @override
  void initState() {
    super.initState();
    // Load persisted settings
    final settings = SettingsService();
    _isArticleMode = settings.subtitleViewMode == 1;
    _fontSizeScale = widget.isPortrait 
        ? settings.portraitSidebarFontSizeScale 
        : settings.landscapeSidebarFontSizeScale;
    
    widget.controller.addListener(_updateIndex);
    _checkBilingualSync();
    _rebuildSubtitleIndex();
  }

  @override
  void didUpdateWidget(SubtitleSidebar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.controller != oldWidget.controller) {
      oldWidget.controller.removeListener(_updateIndex);
      widget.controller.addListener(_updateIndex);
    }
    if (widget.subtitles != oldWidget.subtitles || widget.secondarySubtitles != oldWidget.secondarySubtitles) {
       _checkBilingualSync();
       _rebuildSubtitleIndex();
    }
    if (!oldWidget.isVisible && widget.isVisible && SettingsService().autoScrollSubtitles) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _lastIndexComputeAtMs = 0;
        _lastIndexComputePosMs = -1;
        _updateIndex();
        _scrollToActiveIndex();
      });
    }
  }

  void _checkBilingualSync() {
     _secondaryTextCache.clear();
     _isBilingualMode = false;
     
     if (widget.secondarySubtitles.isEmpty) return;
     if (widget.subtitles.isEmpty) return;

     int matchCount = 0;
     // Optimization: use two pointers since both are sorted
     int secIndex = 0;
     
     for (int i = 0; i < widget.subtitles.length; i++) {
        final primary = widget.subtitles[i];
        
        // Advance secondary pointer to at least primary start - tolerance
        // Tolerance: 500ms
        while (secIndex < widget.secondarySubtitles.length && 
               widget.secondarySubtitles[secIndex].startTime < primary.startTime - const Duration(milliseconds: 500)) {
           secIndex++;
        }
        
        if (secIndex >= widget.secondarySubtitles.length) break;
        
        // Check current secIndex and maybe next few
        bool found = false;
        for (int j = secIndex; j < widget.secondarySubtitles.length; j++) {
           final sec = widget.secondarySubtitles[j];
           if (sec.startTime > primary.startTime + const Duration(milliseconds: 500)) break; // Passed window
           
           // Check overlap or start time match
           if ((primary.startTime - sec.startTime).abs() < const Duration(milliseconds: 500)) {
              _secondaryTextCache[i] = sec.text.replaceAll('\n', ' ');
              found = true;
              break; // Found best match (first close one)
           }
        }
        
        if (found) matchCount++;
     }
     
     // Threshold: If > 50% of items have matches, enable bilingual mode
     if (widget.subtitles.isNotEmpty && matchCount > (widget.subtitles.length * 0.5)) {
        _isBilingualMode = true;
     }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_updateIndex);
    _activeIndexNotifier.dispose();
    _activeIndicesNotifier.dispose();
    _autoScrollTimer?.cancel();
    super.dispose();
  }

  void _rebuildSubtitleIndex() {
    _subtitleStartMs
      ..clear()
      ..addAll(widget.subtitles.map((e) => e.startTime.inMilliseconds));
    _lastIndexComputePosMs = -1;
  }

  void _updateIndex() {
    if (!mounted || widget.subtitles.isEmpty) return;
    
    final currentPosition = widget.controller.value.position;
    final int posMs = currentPosition.inMilliseconds;
    final int nowMs = DateTime.now().millisecondsSinceEpoch;
    if (_lastIndexComputePosMs != -1) {
      final int deltaPos = (posMs - _lastIndexComputePosMs).abs();
      final int deltaTime = nowMs - _lastIndexComputeAtMs;
      if (deltaPos < 80 && deltaTime < 80) {
        return;
      }
    }
    _lastIndexComputePosMs = posMs;
    _lastIndexComputeAtMs = nowMs;

    const bool continuousSubtitleEnabled = true;
    final List<int> activeIndices = _findActiveIndicesMs(
      posMs,
      continuousSubtitleEnabled: continuousSubtitleEnabled,
    );
    final int index = activeIndices.isNotEmpty ? activeIndices.first : -1;
    if (!_isSameIndices(activeIndices, _activeIndicesNotifier.value)) {
      _activeIndicesNotifier.value = activeIndices;
    }
    
    if (index != _activeIndexNotifier.value) {
      _activeIndexNotifier.value = index;
      if (widget.isVisible && SettingsService().autoScrollSubtitles && _activePointerCount == 0) {
        _scheduleAutoScroll(posMs);
      }
    }
  }

  int _getEffectiveEndTimeMs(int index, bool continuousSubtitleEnabled) {
    final item = widget.subtitles[index];
    final int actualEndMs = item.endTime.inMilliseconds;
    if (!continuousSubtitleEnabled) {
      return actualEndMs;
    }
    int nextStartMs = actualEndMs;
    if (index + 1 < widget.subtitles.length) {
      if (_subtitleStartMs.length == widget.subtitles.length) {
        nextStartMs = _subtitleStartMs[index + 1];
      } else {
        nextStartMs = widget.subtitles[index + 1].startTime.inMilliseconds;
      }
    } else {
      final controllerValue = widget.controller.value;
      if (controllerValue.isInitialized && controllerValue.duration > item.endTime) {
        nextStartMs = controllerValue.duration.inMilliseconds;
      }
    }
    return nextStartMs < actualEndMs ? actualEndMs : nextStartMs;
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

  List<int> _findActiveIndicesMs(
    int posMs, {
    required bool continuousSubtitleEnabled,
  }) {
    if (widget.subtitles.isEmpty) return <int>[];
    if (_subtitleStartMs.length != widget.subtitles.length) {
      _rebuildSubtitleIndex();
    }
    final int candidate = _binarySearchLastStartLE(posMs);
    if (candidate < 0 || candidate >= widget.subtitles.length) return <int>[];
    final List<int> indices = <int>[];
    for (int i = candidate; i >= 0; i--) {
      if (_subtitleStartMs[i] > posMs) continue;
      final int endMs = _getEffectiveEndTimeMs(i, continuousSubtitleEnabled);
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

  bool _isSameIndices(List<int> next, List<int> prev) {
    if (next.length != prev.length) return false;
    for (int i = 0; i < next.length; i++) {
      if (next[i] != prev[i]) return false;
    }
    return true;
  }

  void _scheduleAutoScroll(int posMs) {
    _autoScrollTimer?.cancel();
    _autoScrollTimer = Timer(Duration.zero, () {
      if (!mounted) return;
      if (_activePointerCount != 0) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (_activePointerCount != 0) return;
        _scrollToActiveIndex(isAuto: true);
      });
    });
  }

  void triggerLocateForAutoFollow() {
    if (!mounted) return;
    if (!widget.isVisible || !SettingsService().autoScrollSubtitles) return;
    if (_activePointerCount != 0) return;
    if (widget.subtitles.isEmpty) return;

    final int posMs = widget.controller.value.position.inMilliseconds;
    // Always recalculate index to ensure accuracy during mode switch
    // This fixes the issue where the cached index might be stale or slightly off
    const bool continuousSubtitleEnabled = true;
    final List<int> activeIndices = _findActiveIndicesMs(
      posMs,
      continuousSubtitleEnabled: continuousSubtitleEnabled,
    );
    final int index = activeIndices.isNotEmpty ? activeIndices.first : -1;
    if (!_isSameIndices(activeIndices, _activeIndicesNotifier.value)) {
      _activeIndicesNotifier.value = activeIndices;
    }
    if (index >= 0 && index < widget.subtitles.length) {
      _activeIndexNotifier.value = index;
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _scrollToActiveIndexAfterModeSwitch(isAuto: true, attempt: 0);
    });
  }

  void _triggerLocateButtonAfterModeSwitch() {
    triggerLocateForAutoFollow();
  }

  void _scrollToActiveIndexAfterModeSwitch({required bool isAuto, required int attempt}) {
    if (!mounted) return;
    if (_activePointerCount != 0) return;

    final int index = _activeIndexNotifier.value;
    if (index < 0 || index >= widget.subtitles.length) return;

    const int maxAttempts = 6;
    if (_isArticleMode) {
      if (!_articleItemScrollController.isAttached) {
        if (attempt < maxAttempts) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _scrollToActiveIndexAfterModeSwitch(isAuto: isAuto, attempt: attempt + 1);
          });
        }
        return;
      }
    } else {
      if (!_itemScrollController.isAttached) {
        if (attempt < maxAttempts) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _scrollToActiveIndexAfterModeSwitch(isAuto: isAuto, attempt: attempt + 1);
          });
        }
        return;
      }
    }

    _scrollToActiveIndex(isAuto: isAuto);
  }

  void _onPointerDown(PointerDownEvent event) {
    if (_activePointerCount == 0) {
      _pointerDownStartIndex = _activeIndexNotifier.value;
    }
    _activePointerCount++;
    _autoScrollTimer?.cancel();
  }

  void _onPointerUpOrCancel(PointerEvent event) {
    _activePointerCount--;
    if (_activePointerCount < 0) _activePointerCount = 0;
    if (_activePointerCount == 0) {
      final int? startIndex = _pointerDownStartIndex;
      _pointerDownStartIndex = null;
      if (startIndex != null && startIndex != _activeIndexNotifier.value) {
        triggerLocateForAutoFollow();
      }
    }
  }

  String _getFilteredText(String text, int index) {
    if (_lineFilterMode == 0) {
      // Dual Mode
      // If we have valid bilingual match, merge them
      if (_isBilingualMode && _secondaryTextCache.containsKey(index)) {
         return "$text ${_secondaryTextCache[index]}";
      }
      return text;
    }
    
    // Line Split Mode (Legacy or Forced)
    // If we have secondary file but mode is 1 or 2, we might want to toggle files?
    // User logic: "If mode is 1, show Primary. If mode is 2, show Secondary."
    if (widget.secondarySubtitles.isNotEmpty) {
       if (_lineFilterMode == 1) return text;
       if (_lineFilterMode == 2) {
          if (_secondaryTextCache.containsKey(index)) return _secondaryTextCache[index]!;
          return ""; // No match found for this line
       }
    }

    // Fallback to split-by-newline logic (Single File)
    final lines = text.split('\n');
    if (_lineFilterMode == 1) {
      return lines.isNotEmpty ? lines[0] : '';
    } else if (_lineFilterMode == 2) {
      return lines.length > 1 ? lines[1] : '';
    }
    return text;
  }

  void _scrollToActiveIndex({bool isAuto = false}) {
    final index = _activeIndexNotifier.value;
    if (index < 0 || index >= widget.subtitles.length) return;

    if (_isArticleMode) {
       final chunkIndex = index ~/ _articleChunkSize;
       
       if (_shouldSkipScrollAnimation(
         targetIndex: chunkIndex,
         isArticleMode: true,
         alignment: 0.15,
       )) {
         return;
       }
       
       _articleItemScrollController.scrollTo(
          index: chunkIndex,
          duration: isAuto ? const Duration(milliseconds: 200) : const Duration(milliseconds: 300),
          curve: Curves.easeInOut,
          alignment: 0.15, // Align near top to ensure visibility
       );
    } else {
      if (_shouldSkipScrollAnimation(
        targetIndex: index,
        isArticleMode: false,
        alignment: 0.30,
      )) {
        return;
      }
      _itemScrollController.scrollTo(
        index: index,
        duration: isAuto ? const Duration(milliseconds: 200) : const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
        alignment: 0.30, // 30% from top
      );
    }
  }

  bool _shouldSkipScrollAnimation({
    required int targetIndex,
    required bool isArticleMode,
    required double alignment,
  }) {
    final positions = isArticleMode
        ? _articleItemPositionsListener.itemPositions.value
        : _itemPositionsListener.itemPositions.value;
    if (positions.isEmpty) return false;

    final int itemCount = isArticleMode
        ? (widget.subtitles.length / _articleChunkSize).ceil()
        : widget.subtitles.length;
    final int lastIndex = itemCount - 1;

    int minIndex = 1 << 30;
    int maxIndex = -1;
    double minLeading = double.infinity;
    double maxTrailing = -double.infinity;
    double? targetLeading;

    for (final pos in positions) {
      if (pos.index < minIndex) {
        minIndex = pos.index;
        minLeading = pos.itemLeadingEdge;
      }
      if (pos.index > maxIndex) {
        maxIndex = pos.index;
        maxTrailing = pos.itemTrailingEdge;
      }
      if (pos.index == targetIndex) {
        targetLeading = pos.itemLeadingEdge;
      }
    }

    if (targetLeading == null) return false;

    const double epsilon = 0.01;
    final bool atTop = minIndex == 0 && minLeading >= -epsilon;
    final bool atBottom = maxIndex == lastIndex && maxTrailing <= 1.0 + epsilon;

    if (atTop && targetLeading <= alignment + epsilon) return true;
    if (atBottom && targetLeading >= alignment - epsilon) return true;
    
    // Skip animation if target is at the very top (index 0) and already at top
    if (targetIndex == 0 && atTop && targetLeading <= epsilon) return true;
    
    // 根治方案：如果所有字幕都在视图中（数量不足以填满屏幕），跳过所有滚动动画
    // 这样可以确保横屏的滚动状态不会影响竖屏的显示
    final bool allItemsVisible = minIndex == 0 && maxIndex == lastIndex;
    if (allItemsVisible) return true;
    
    return false;
  }

  void jumpToFirstSubtitleTop() {
    if (widget.subtitles.isEmpty) return;
    _activeIndexNotifier.value = 0;
    _jumpToIndexTopInternal(targetIndex: 0, attempt: 0);
  }

  void _jumpToIndexTopInternal({required int targetIndex, required int attempt}) {
    if (!mounted) return;
    const int maxAttempts = 6;
    if (_isArticleMode) {
      if (!_articleItemScrollController.isAttached) {
        if (attempt < maxAttempts) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _jumpToIndexTopInternal(targetIndex: targetIndex, attempt: attempt + 1);
          });
        }
        return;
      }
      final int chunkIndex = targetIndex ~/ _articleChunkSize;
      _articleItemScrollController.jumpTo(index: chunkIndex, alignment: 0.0);
    } else {
      if (!_itemScrollController.isAttached) {
        if (attempt < maxAttempts) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _jumpToIndexTopInternal(targetIndex: targetIndex, attempt: attempt + 1);
          });
        }
        return;
      }
      _itemScrollController.jumpTo(index: targetIndex, alignment: 0.0);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Spacing logic
    final double spacing = 0.0; // Zero spacing for compactness
    
    return Focus(
      canRequestFocus: false,
      descendantsAreFocusable: false,
      child: Container(
      width: double.infinity,
      color: const Color(0xFF1E1E1E), // 深色背景
      child: Material(
        color: Colors.transparent,
        child: GestureDetector(
        onTap: () {
          widget.onClearSelection?.call();
          widget.focusNode?.requestFocus();
        },
        behavior: HitTestBehavior.translucent,
        child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: _onPointerDown,
        onPointerUp: _onPointerUpOrCancel,
        onPointerCancel: _onPointerUpOrCancel,
        child: Column(
          children: [
            // 1. 顶部栏 (切换模式 + 过滤 + 关闭)
            Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch, // Ensure content stretches or aligns start
              children: [
                Container(
                  // Reduced vertical padding significantly
                  padding: const EdgeInsets.symmetric(horizontal: 0, vertical: 0),
                  decoration: const BoxDecoration(
                    border: Border(bottom: BorderSide(color: Colors.white10)),
                  ),
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.start, // Left aligned
                      children: [
                        // 视图模式切换
                        Tooltip(
                          message: "切换列表/文章视图",
                          child: _buildCompactToggle(
                            children: [
                              _buildToggleItem(Icons.list, _isArticleMode == false),
                              _buildToggleItem(Icons.article, _isArticleMode == true),
                            ],
                            onTap: (index) {
                              final isArticle = index == 1;
                              setState(() => _isArticleMode = isArticle);
                              SettingsService().updateSetting('subtitleViewMode', isArticle ? 1 : 0);
                              _triggerLocateButtonAfterModeSwitch();
                            },
                            selectedIndex: _isArticleMode ? 1 : 0,
                          ),
                        ),
                        
                        SizedBox(width: spacing),

                        // 语言/行过滤
                        Tooltip(
                          message: "切换双语/单行显示",
                          child: _buildCompactToggle(
                            children: [
                              const Text("双", style: TextStyle(fontSize: 9)), // Larger
                              const Text("1", style: TextStyle(fontSize: 9)), // Larger
                              const Text("2", style: TextStyle(fontSize: 9)), // Larger
                            ],
                            onTap: (index) {
                              setState(() => _lineFilterMode = index);
                              _triggerLocateButtonAfterModeSwitch();
                            },
                            selectedIndex: _lineFilterMode,
                          ),
                        ),

                        SizedBox(width: spacing),

                        // 字体设置按钮
                        _buildCompactIconButton(
                          icon: Icons.format_size,
                          isActive: _showFontSettings,
                          onTap: () {
                            setState(() {
                              _showFontSettings = !_showFontSettings;
                            });
                          },
                          tooltip: "调整字体大小",
                        ),

                        SizedBox(width: spacing),

                        // 自动跟随按钮 (带 'A' 徽标)
                        Tooltip(
                          message: "自动跟随字幕",
                          child: InkWell(
                            onTap: () {
                              final newValue = !SettingsService().autoScrollSubtitles;
                              SettingsService().updateSetting('autoScrollSubtitles', newValue).then((_) {
                                 if (mounted) setState(() {}); // Refresh UI
                                 if (newValue) {
                                   _scrollToActiveIndex();
                                 }
                              });
                            },
                            child: Container(
                              width: widget.isPortrait ? 24 : 15, 
                              height: widget.isPortrait ? 40 : 35, // Slightly larger
                              alignment: Alignment.center,
                              child: Stack(
                                alignment: Alignment.center,
                                children: [
                                  Icon(
                                    SettingsService().autoScrollSubtitles ? Icons.gps_fixed : Icons.gps_not_fixed,
                                    color: SettingsService().autoScrollSubtitles ? Colors.blueAccent : Colors.white70,
                                    size: widget.isPortrait ? 18 : 18 // Slightly larger
                                  ),
                                  if (SettingsService().autoScrollSubtitles)
                                    Positioned(
                                      right: widget.isPortrait ? 0 : 2,
                                      bottom: widget.isPortrait ? 0 : 2,
                                      child: Text(
                                        "A",
                                        style: TextStyle(
                                          fontSize: widget.isPortrait ? 6 : 6, // Slightly larger
                                          fontWeight: FontWeight.bold, 
                                          color: Colors.blueAccent
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                        ),

                        SizedBox(width: spacing),

                        // 定位按钮
                        _buildCompactIconButton(
                          icon: Icons.my_location,
                          onTap: _scrollToActiveIndex,
                          tooltip: "定位到当前字幕",
                        ),

                        SizedBox(width: spacing),

                        // Scan Embedded
                        if (widget.onScanEmbeddedSubtitles != null)
                          _buildCompactIconButton(
                            icon: Icons.youtube_searched_for,
                            onTap: widget.onScanEmbeddedSubtitles,
                            tooltip: "扫描内嵌字幕",
                          ),

                        if (widget.onScanEmbeddedSubtitles != null)
                           SizedBox(width: spacing),

                        // AI 转录按钮 (已移除，移至字幕管理)
                        
                        // 字幕管理按钮 (替代原有的 AI 按钮和导入按钮，或者作为新入口)
                        if (widget.onOpenSubtitleManager != null) ...[
                          Tooltip(
                            message: "字幕管理 (AI/导入/列表)",
                            child: InkWell(
                              onTap: widget.onOpenSubtitleManager,
                              borderRadius: BorderRadius.circular(4),
                              child: Container(
                                padding: EdgeInsets.symmetric(horizontal: widget.isPortrait ? 4 : (widget.isCompact ? 2 : 4), vertical: widget.isPortrait ? 4 : 3),
                                decoration: BoxDecoration(
                                  border: Border.all(color: Colors.purpleAccent.withValues(alpha: 0.5)),
                                  borderRadius: BorderRadius.circular(4),
                                  color: Colors.purpleAccent.withValues(alpha: 0.1),
                                ),
                                child: Row(
                                  children: [
                                    Icon(Icons.subtitles, size: widget.isPortrait ? 16 : 14, color: Colors.purpleAccent), // Distinct icon
                                    if (!widget.isPortrait) SizedBox(width: 4),
                                    if (!widget.isPortrait)
                                      Text(
                                        "字幕库",
                                        style: TextStyle(
                                          color: Colors.purpleAccent, 
                                          fontSize: 8, 
                                          fontWeight: FontWeight.bold
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                          SizedBox(width: spacing),
                        ],
                        
                        // 加载本地字幕 (保留作为快捷方式，或者隐藏?)
                        /*
                        Tooltip(
                          message: "导入本地字幕文件",
                          child: GestureDetector(
                            onTap: widget.onLoadSubtitle,
                            child: Container(
                              padding: EdgeInsets.symmetric(horizontal: widget.isPortrait ? 4 : (widget.isCompact ? 2 : 4), vertical: widget.isPortrait ? 4 : 3),
                              decoration: BoxDecoration(
                                border: Border.all(color: Colors.white30),
                                borderRadius: BorderRadius.circular(4),
                                color: Colors.white10,
                              ),
                              child: widget.isPortrait 
                                ? Icon(Icons.folder_open, size: 16, color: Colors.white)
                                : Text(
                                    widget.isCompact ? "导入" : "导入本地字幕",
                                    style: TextStyle(
                                      color: Colors.white, 
                                      fontSize: 8, 
                                      fontWeight: FontWeight.w500
                                    ),
                                  ),
                            ),
                          ),
                        ),

                        SizedBox(width: spacing),
                        */

                        // 字幕样式设置
                        Tooltip(
                          message: "字幕样式设置",
                          child: InkWell(
                            onTap: widget.onOpenSubtitleStyle,
                            borderRadius: BorderRadius.circular(4),
                            child: Container(
                              padding: EdgeInsets.symmetric(horizontal: widget.isPortrait ? 4 : (widget.isCompact ? 2 : 4), vertical: widget.isPortrait ? 4 : (widget.isCompact ? 1 : 1)),
                              decoration: BoxDecoration(
                                border: Border.all(color: Colors.white30),
                                borderRadius: BorderRadius.circular(4),
                                color: Colors.white10,
                              ),
                              child: (widget.isCompact || widget.isPortrait)
                                ? Icon(Icons.style, color: Colors.white, size: widget.isPortrait ? 16 : 14)
                                : const Text(
                                    "字幕设置",
                                    style: TextStyle(
                                      color: Colors.white, 
                                      fontSize: 8, 
                                      fontWeight: FontWeight.w500
                                    ),
                                  ),
                            ),
                          ),
                        ),
                        
                        // 设置按钮 (Removed Spacer, added directly)
                        SizedBox(width: spacing),
                        
                        _buildCompactIconButton(
                          icon: Icons.settings,
                          onTap: widget.onOpenSettings,
                          tooltip: "设置",
                        ),

                      ],
                    ),
                  ),
                ),
                
                // 字体设置面板
                if (_showFontSettings)
                  Container(
                    color: Colors.white.withValues(alpha: 0.05),
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    child: Row(
                      children: [
                        const Text("A", style: TextStyle(fontSize: 12, color: Colors.white70)),
                        Expanded(
                          child: SliderTheme(
                            data: SliderTheme.of(context).copyWith(
                              trackHeight: 2,
                              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                              overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
                            ),
                            child: Slider(
                              value: _fontSizeScale,
                              min: 0.5,
                              max: 3.0,
                              divisions: 25,
                              label: "${(_fontSizeScale * 100).round()}%",
                              activeColor: Colors.blueAccent,
                              inactiveColor: Colors.white24,
                              onChanged: (value) {
                                setState(() {
                                  _fontSizeScale = value;
                                });
                              },
                              onChangeEnd: (value) {
                                if (widget.isPortrait) {
                                  SettingsService().updateSetting('portraitSidebarFontSizeScale', value);
                                } else {
                                  SettingsService().updateSetting('landscapeSidebarFontSizeScale', value);
                                }
                              },
                            ),
                          ),
                        ),
                        const Text("A", style: TextStyle(fontSize: 18, color: Colors.white70)),
                        const SizedBox(width: 8),
                        SizedBox(
                          width: 35,
                          child: Text(
                            "${(_fontSizeScale * 100).toInt()}%",
                            style: const TextStyle(fontSize: 12, color: Colors.white70),
                            textAlign: TextAlign.right,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          
          // 2. 内容区
          Expanded(
            child: widget.subtitles.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          widget.showEmbeddedLoadingMessage
                              ? "已识别到内嵌字幕\n等待加载中"
                              : "暂无字幕",
                          style: const TextStyle(color: Colors.white54),
                          textAlign: TextAlign.center,
                        ),
                        if (widget.onOpenSubtitleManager != null) ...[
                          const SizedBox(height: 16),
                          InkWell(
                            onTap: widget.onOpenSubtitleManager,
                            borderRadius: BorderRadius.circular(4),
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                              decoration: BoxDecoration(
                                border: Border.all(color: Colors.purpleAccent.withValues(alpha: 0.5)),
                                borderRadius: BorderRadius.circular(4),
                                color: Colors.purpleAccent.withValues(alpha: 0.1),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: const [
                                  Icon(Icons.subtitles, size: 18, color: Colors.purpleAccent),
                                  SizedBox(width: 8),
                                  Text(
                                    "查看字幕管理",
                                    style: TextStyle(
                                      color: Colors.purpleAccent,
                                      fontSize: 14,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  )
                : ValueListenableBuilder<List<int>>(
                    valueListenable: _activeIndicesNotifier,
                    builder: (context, activeIndices, child) {
                      final int activeIndex = activeIndices.isNotEmpty ? activeIndices.first : -1;
                      final Set<int> activeSet = activeIndices.toSet();
                      return _isArticleMode 
                          ? _buildArticleView(activeIndex, activeSet) 
                          : _buildListView(activeIndex, activeSet);
                    },
                  ),
          ),
        ],
        ),
        ),
      ),
      ),
      ),
    );
  }

  Widget _buildCompactToggle({required List<Widget> children, required Function(int) onTap, required int selectedIndex}) {
    final isSmallScreen = MediaQuery.of(context).size.width < 600;
    // Portrait mode: larger touch targets
    final double height = widget.isPortrait ? 28.0 : (isSmallScreen ? 20 : 22);
    
    return Container(
      height: height,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: Colors.white10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: List.generate(children.length, (index) {
          final isSelected = selectedIndex == index;
          return InkWell(
            onTap: () => onTap(index),
            borderRadius: BorderRadius.circular(3),
            child: Container(
              padding: EdgeInsets.symmetric(horizontal: widget.isPortrait ? 6 : (isSmallScreen ? 4 : 6)), 
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: isSelected ? Colors.blueAccent : Colors.transparent,
                borderRadius: BorderRadius.circular(3),
              ),
              child: DefaultTextStyle(
                style: TextStyle(
                  color: isSelected ? Colors.white : Colors.white60,
                  fontSize: widget.isPortrait ? 11 : (isSmallScreen ? 10 : 11), 
                  fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                ),
                child: IconTheme(
                  data: IconThemeData(
                    size: widget.isPortrait ? 14 : (isSmallScreen ? 12 : 13), 
                    color: isSelected ? Colors.white : Colors.white60,
                  ),
                  child: children[index],
                ),
              ),
            ),
          );
        }),
      ),
    );
  }

  Widget _buildToggleItem(IconData icon, bool isSelected) {
    return Icon(icon);
  }

  Widget _buildCompactIconButton({
    required IconData icon,
    VoidCallback? onTap,
    String? tooltip,
    bool isActive = false,
  }) {
    // Portrait mode: larger touch targets
    final double size = widget.isPortrait ? 28.0 : 28.0;
    final double iconSize = widget.isPortrait ? 18.0 : 18.0;

    final child = InkWell(
      onTap: onTap,
      child: Container(
        width: size, 
        height: size, 
        alignment: Alignment.center,
        child: Icon(
          icon,
          color: isActive ? Colors.blueAccent : Colors.white70,
          size: iconSize, 
        ),
      ),
    );

    if (tooltip != null && tooltip.isNotEmpty) {
      return Tooltip(
        message: tooltip,
        child: child,
      );
    }

    return child;
  }

  bool _shouldTopAlignList({
    required double maxHeight,
    required bool isSmallScreen,
    required double innerV,
    required double itemGap,
  }) {
    if (widget.subtitles.isEmpty) return true;
    final int lineCount = _lineFilterMode == 0 && _isBilingualMode ? 2 : 1;
    final double fontSize = (isSmallScreen ? 12 : 13) * _fontSizeScale;
    final double textHeight = fontSize * 1.6 * lineCount;
    final double estimatedItemHeight = textHeight + innerV * 2 + itemGap + (isSmallScreen ? 6 : 8);
    final double estimatedTotalHeight = estimatedItemHeight * widget.subtitles.length + itemGap * 2;
    return estimatedTotalHeight <= maxHeight;
  }

  bool _shouldTopAlignArticle({
    required double maxHeight,
    required bool isSmallScreen,
    required int chunkCount,
  }) {
    if (chunkCount <= 1) return true;
    final int lineCount = _lineFilterMode == 0 && _isBilingualMode ? 2 : 1;
    final double fontSize = (isSmallScreen ? 13 : 15) * _fontSizeScale;
    final double textHeight = fontSize * 1.6 * lineCount;
    final double estimatedChunkHeight = textHeight * _articleChunkSize * 0.75 + (isSmallScreen ? 20 : 32);
    final double estimatedTotalHeight = estimatedChunkHeight * chunkCount + (isSmallScreen ? 24 : 40);
    return estimatedTotalHeight <= maxHeight;
  }

  // 列表模式视图
  Widget _buildListView(int currentIndex, Set<int> activeIndices) {
    final isSmallScreen = MediaQuery.of(context).size.width < 600;
    
    // 动态计算间距，随字体大小缩放，使小字体模式更紧凑
    final double scale = _fontSizeScale < 1.0 ? _fontSizeScale : _fontSizeScale * 0.9; 
    final double innerH = (isSmallScreen ? 6 : 8) * scale; // 内部水平间距
    final double innerV = (isSmallScreen ? 4 : 6) * scale; // 内部垂直间距
    final double itemGap = (isSmallScreen ? 2 : 4) * scale; // 列表项间距
    final double timeGap = (isSmallScreen ? 6 : 8) * scale; // 时间戳和文本的间距

    return LayoutBuilder(
      builder: (context, constraints) {
        final bool shouldTopAlign = _shouldTopAlignList(
          maxHeight: constraints.maxHeight,
          isSmallScreen: isSmallScreen,
          innerV: innerV,
          itemGap: itemGap,
        );
        // 当字幕数量不足时，强制从顶部开始显示，忽略当前索引
        final int effectiveInitialIndex = shouldTopAlign ? 0 : (currentIndex >= 0 ? currentIndex : 0);
        final double effectiveInitialAlignment = shouldTopAlign ? 0.0 : 0.30;
        
        final list = ScrollablePositionedList.builder(
          itemScrollController: _itemScrollController,
          itemPositionsListener: _itemPositionsListener,
          initialScrollIndex: effectiveInitialIndex,
          initialAlignment: effectiveInitialAlignment,
          itemCount: widget.subtitles.length,
          shrinkWrap: shouldTopAlign,
          physics: shouldTopAlign ? const NeverScrollableScrollPhysics() : null,
          itemBuilder: (context, index) {
            final item = widget.subtitles[index];
            final isCurrent = activeIndices.contains(index);
            
            return Padding(
              padding: EdgeInsets.symmetric(
                horizontal: isSmallScreen ? 2 : 6,
              ),
              child: Padding(
                padding: EdgeInsets.only(bottom: itemGap),
                child: InkWell(
                  onTapDown: (_) {
                    widget.onClearSelection?.call();
                    widget.onItemTap?.call(item.startTime);
                    Future.microtask(() => widget.focusNode?.requestFocus());
                  },
                  canRequestFocus: false,
                  borderRadius: BorderRadius.circular(4),
                  child: Container(
                    padding: EdgeInsets.symmetric(horizontal: innerH, vertical: innerV),
                    decoration: BoxDecoration(
                      color: isCurrent ? Colors.blueAccent.withValues(alpha: 0.15) : Colors.transparent,
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(
                        color: isCurrent ? Colors.blueAccent.withValues(alpha: 0.3) : Colors.transparent,
                      ),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: EdgeInsets.only(top: 2 * scale),
                          child: Text(
                            _formatDuration(item.startTime),
                            style: TextStyle(
                              color: isCurrent ? Colors.blueAccent : Colors.white30,
                              fontSize: (isSmallScreen ? 10 : 11) * _fontSizeScale,
                              fontFamily: 'monospace',
                            ),
                          ),
                        ),
                        SizedBox(width: timeGap),
                        Expanded(
                          child: Text(
                            (item.text.isEmpty && item.imageLoader != null) 
                                ? "[图片字幕]" 
                                : _getFilteredText(item.text, index),
                            style: TextStyle(
                              color: isCurrent ? Colors.white : Colors.white70,
                              fontSize: (isSmallScreen ? 12 : 13) * _fontSizeScale,
                              height: 1.3,
                              fontWeight: isCurrent ? FontWeight.w500 : FontWeight.normal,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        );
        return shouldTopAlign ? Align(alignment: Alignment.topCenter, child: list) : list;
      },
    );
  }

  // 文章模式视图
  Widget _buildArticleView(int activeIndex, Set<int> activeIndices) {
    final isSmallScreen = MediaQuery.of(context).size.width < 600;
    final int chunkCount = (widget.subtitles.length / _articleChunkSize).ceil();
    final int initialChunkIndex = (activeIndex >= 0 ? (activeIndex ~/ _articleChunkSize) : 0);

    return LayoutBuilder(
      builder: (context, constraints) {
        final bool shouldTopAlign = _shouldTopAlignArticle(
          maxHeight: constraints.maxHeight,
          isSmallScreen: isSmallScreen,
          chunkCount: chunkCount,
        );
        // 当字幕数量不足时，强制从顶部开始显示，忽略当前索引
        final int effectiveInitialChunkIndex = shouldTopAlign ? 0 : (initialChunkIndex < chunkCount ? initialChunkIndex : 0);
        final double effectiveInitialAlignment = shouldTopAlign ? 0.0 : 0.15;
        
        final list = ScrollablePositionedList.builder(
          itemScrollController: _articleItemScrollController,
          itemPositionsListener: _articleItemPositionsListener,
          initialScrollIndex: effectiveInitialChunkIndex,
          initialAlignment: effectiveInitialAlignment,
          itemCount: chunkCount,
          padding: EdgeInsets.all(isSmallScreen ? 12 : 20),
          shrinkWrap: shouldTopAlign,
          physics: shouldTopAlign ? const NeverScrollableScrollPhysics() : null,
          itemBuilder: (context, chunkIndex) {
            final int startIndex = chunkIndex * _articleChunkSize;
            final int endIndex = (startIndex + _articleChunkSize) > widget.subtitles.length 
                ? widget.subtitles.length 
                : startIndex + _articleChunkSize;
            
            return SubtitleArticleChunk(
              subtitles: widget.subtitles,
              startIndex: startIndex,
              endIndex: endIndex,
              activeIndices: activeIndices,
              fontSizeScale: _fontSizeScale,
              onItemTap: widget.onItemTap,
              onClearSelection: widget.onClearSelection,
              isSmallScreen: isSmallScreen,
              lineFilterMode: _lineFilterMode,
              secondaryTextCache: _secondaryTextCache,
              isBilingualMode: _isBilingualMode,
              focusNode: widget.focusNode,
            );
          },
        );
        return shouldTopAlign ? Align(alignment: Alignment.topCenter, child: list) : list;
      },
    );
  }

  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, "0");
    String twoDigitMinutes = twoDigits(duration.inMinutes.remainder(60));
    String twoDigitSeconds = twoDigits(duration.inSeconds.remainder(60));
    return "$twoDigitMinutes:$twoDigitSeconds";
  }
}

class SubtitleArticleChunk extends StatefulWidget {
  final List<SubtitleItem> subtitles;
  final int startIndex;
  final int endIndex;
  final Set<int> activeIndices;
  final double fontSizeScale;
  final ValueChanged<Duration>? onItemTap;
  final VoidCallback? onClearSelection;
  final bool isSmallScreen;
  final int lineFilterMode;
  final Map<int, String> secondaryTextCache;
  final bool isBilingualMode;
  final FocusNode? focusNode;

  const SubtitleArticleChunk({
    super.key,
    required this.subtitles,
    required this.startIndex,
    required this.endIndex,
    required this.activeIndices,
    required this.fontSizeScale,
    this.onItemTap,
    this.onClearSelection,
    required this.isSmallScreen,
    required this.lineFilterMode,
    this.secondaryTextCache = const {},
    this.isBilingualMode = false,
    this.focusNode,
  });

  @override
  State<SubtitleArticleChunk> createState() => _SubtitleArticleChunkState();
}

class _SubtitleArticleChunkState extends State<SubtitleArticleChunk> {
  final List<TapGestureRecognizer> _recognizers = [];

  @override
  void dispose() {
    for (var r in _recognizers) {
      r.dispose();
    }
    super.dispose();
  }

  String _getFilteredText(String text, int index) {
    if (widget.lineFilterMode == 0) {
      if (widget.isBilingualMode && widget.secondaryTextCache.containsKey(index)) {
         return "$text  ${widget.secondaryTextCache[index]}";
      }
      return text;
    }
    
    // Check cache for line modes if secondary exists (implicitly if cache has items)
    if (widget.secondaryTextCache.isNotEmpty) {
       if (widget.lineFilterMode == 1) return text;
       if (widget.lineFilterMode == 2) {
          if (widget.secondaryTextCache.containsKey(index)) return widget.secondaryTextCache[index]!;
          return "";
       }
    }

    final lines = text.split('\n');
    if (widget.lineFilterMode == 1) {
      return lines.isNotEmpty ? lines[0] : '';
    } else if (widget.lineFilterMode == 2) {
      return lines.length > 1 ? lines[1] : '';
    }
    return text;
  }

  @override
  Widget build(BuildContext context) {
    // Dispose old recognizers
    for (var r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();

    final List<InlineSpan> spans = [];

    for (int i = widget.startIndex; i < widget.endIndex; i++) {
      final item = widget.subtitles[i];
      final isCurrent = widget.activeIndices.contains(i);
      String rawText = _getFilteredText(item.text, i);
      if (rawText.isEmpty && item.imageLoader != null) {
        rawText = "[图片字幕]";
      }
      final text = rawText.replaceAll('\n', ' ');

      final recognizer = TapGestureRecognizer()
        ..onTapDown = (_) {
            widget.onClearSelection?.call();
            widget.onItemTap?.call(item.startTime);
            // 同样延迟请求焦点
            Future.microtask(() => widget.focusNode?.requestFocus());
        };
      _recognizers.add(recognizer);

      spans.add(
        TextSpan(
          text: text,
          style: TextStyle(
            color: isCurrent ? Colors.blueAccent : Colors.white70,
            fontSize: (widget.isSmallScreen ? 13 : 15) * widget.fontSizeScale,
            height: 1.6,
            fontWeight: FontWeight.normal, // Keep consistent to prevent layout shift
            backgroundColor: isCurrent ? Colors.blueAccent.withValues(alpha: 0.1) : null,
          ),
          recognizer: recognizer,
        ),
      );
      
      if (i < widget.endIndex - 1) {
        spans.add(
          TextSpan(
            text: "  ", 
            style: TextStyle(
              fontSize: (widget.isSmallScreen ? 13 : 15) * widget.fontSizeScale,
            )
          )
        );
      }
    }

    return Text.rich(
      TextSpan(children: spans),
    );
  }
}
