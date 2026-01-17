import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'dart:math' as math;
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
  });

  @override
  State<SubtitleSidebar> createState() => _SubtitleSidebarState();
}

class _SubtitleSidebarState extends State<SubtitleSidebar> {
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
  int _lastFoundIndex = -1;

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
    super.dispose();
  }

  void _updateIndex() {
    if (!mounted || widget.subtitles.isEmpty) return;
    
    final currentPosition = widget.controller.value.position;
    final int index = _findCurrentIndex(currentPosition);
    
    if (index != _activeIndexNotifier.value) {
      _activeIndexNotifier.value = index;
      if (SettingsService().autoScrollSubtitles) {
        _scrollToActiveIndex(isAuto: true);
      }
    }
  }

  int _findCurrentIndex(Duration position) {
    final settings = SettingsService();
    final continuousSubtitleEnabled = settings.videoContinuousSubtitle;
    
    // Optimization: Check if close to last found index first
    if (_lastFoundIndex >= 0 && _lastFoundIndex < widget.subtitles.length) {
      final item = widget.subtitles[_lastFoundIndex];
      Duration effectiveEndTime = item.endTime;
      if (continuousSubtitleEnabled && _lastFoundIndex + 1 < widget.subtitles.length) {
        effectiveEndTime = widget.subtitles[_lastFoundIndex + 1].startTime;
      }
      if (position >= item.startTime && position < effectiveEndTime) {
        return _lastFoundIndex;
      }
      // Check next one (sequential playback)
      if (_lastFoundIndex + 1 < widget.subtitles.length) {
        final nextItem = widget.subtitles[_lastFoundIndex + 1];
        Duration nextEffectiveEndTime = nextItem.endTime;
        if (continuousSubtitleEnabled && _lastFoundIndex + 2 < widget.subtitles.length) {
          nextEffectiveEndTime = widget.subtitles[_lastFoundIndex + 2].startTime;
        }
        if (position >= nextItem.startTime && position < nextEffectiveEndTime) {
          _lastFoundIndex++;
          return _lastFoundIndex;
        }
      }
    }
    
    // Fallback to linear search
    for (int i = 0; i < widget.subtitles.length; i++) {
      final item = widget.subtitles[i];
      Duration effectiveEndTime = item.endTime;
      if (continuousSubtitleEnabled && i + 1 < widget.subtitles.length) {
        effectiveEndTime = widget.subtitles[i + 1].startTime;
      }
      if (position >= item.startTime && position < effectiveEndTime) {
        _lastFoundIndex = i;
        return i;
      }
    }
    return -1;
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
       
       _articleItemScrollController.scrollTo(
          index: chunkIndex,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOut,
          alignment: 0.15, // Align near top to ensure visibility
       );
    } else {
      _itemScrollController.scrollTo(
        index: index,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
        alignment: 0.30, // 30% from top
      );
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
                            onTap: (index) => setState(() => _lineFilterMode = index),
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
                                  border: Border.all(color: Colors.purpleAccent.withOpacity(0.5)),
                                  borderRadius: BorderRadius.circular(4),
                                  color: Colors.purpleAccent.withOpacity(0.1),
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
                    color: Colors.white.withOpacity(0.05),
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
                ? const Center(child: Text("暂无字幕", style: TextStyle(color: Colors.white54)))
                : ValueListenableBuilder<int>(
                    valueListenable: _activeIndexNotifier,
                    builder: (context, activeIndex, child) {
                      return _isArticleMode 
                          ? _buildArticleView(activeIndex) 
                          : _buildListView(activeIndex);
                    },
                  ),
          ),
        ],
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
        color: Colors.white.withOpacity(0.05),
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

  // 列表模式视图
  Widget _buildListView(int currentIndex) {
    final isSmallScreen = MediaQuery.of(context).size.width < 600;
    
    // 动态计算间距，随字体大小缩放，使小字体模式更紧凑
    final double scale = _fontSizeScale < 1.0 ? _fontSizeScale : _fontSizeScale * 0.9; 
    final double innerH = (isSmallScreen ? 6 : 8) * scale; // 内部水平间距
    final double innerV = (isSmallScreen ? 4 : 6) * scale; // 内部垂直间距
    final double itemGap = (isSmallScreen ? 2 : 4) * scale; // 列表项间距
    final double timeGap = (isSmallScreen ? 6 : 8) * scale; // 时间戳和文本的间距

    return ScrollablePositionedList.builder(
        itemScrollController: _itemScrollController,
        itemPositionsListener: _itemPositionsListener,
        itemCount: widget.subtitles.length,
        itemBuilder: (context, index) {
          final item = widget.subtitles[index];
          final isCurrent = index == currentIndex;
          
          return Padding(
            padding: EdgeInsets.symmetric(
              horizontal: isSmallScreen ? 2 : 6, // 极窄的外边距
            ),
            child: Padding(
              padding: EdgeInsets.only(bottom: itemGap), // 列表项之间的间距
              child: InkWell(
                onTap: () {
                  widget.onClearSelection?.call();
                  widget.onItemTap?.call(item.startTime);
                  // 确保在下一帧请求焦点，避免被 InkWell 重新抢占
                  Future.microtask(() => widget.focusNode?.requestFocus());
                },
                canRequestFocus: false, // 防止 InkWell 获取焦点
                borderRadius: BorderRadius.circular(4),
                child: Container(
                  padding: EdgeInsets.symmetric(horizontal: innerH, vertical: innerV),
                  decoration: BoxDecoration(
                    color: isCurrent ? Colors.blueAccent.withOpacity(0.15) : Colors.transparent,
                    borderRadius: BorderRadius.circular(4),
                    border: isCurrent ? Border.all(color: Colors.blueAccent.withOpacity(0.3)) : null,
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // 时间戳
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
                      // 字幕内容
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
  }

  // 文章模式视图
  Widget _buildArticleView(int activeIndex) {
    final isSmallScreen = MediaQuery.of(context).size.width < 600;
    final int chunkCount = (widget.subtitles.length / _articleChunkSize).ceil();

    return ScrollablePositionedList.builder(
      itemScrollController: _articleItemScrollController,
      itemPositionsListener: _articleItemPositionsListener,
      itemCount: chunkCount,
      padding: EdgeInsets.all(isSmallScreen ? 12 : 20),
      itemBuilder: (context, chunkIndex) {
        final int startIndex = chunkIndex * _articleChunkSize;
        final int endIndex = (startIndex + _articleChunkSize) > widget.subtitles.length 
            ? widget.subtitles.length 
            : startIndex + _articleChunkSize;
        
        return SubtitleArticleChunk(
          subtitles: widget.subtitles,
          startIndex: startIndex,
          endIndex: endIndex,
          activeIndex: activeIndex,
          fontSizeScale: _fontSizeScale,
          onItemTap: widget.onItemTap,
          onClearSelection: widget.onClearSelection,
          isSmallScreen: isSmallScreen,
          lineFilterMode: _lineFilterMode,
          // Pass cache and mode for article chunk
          secondaryTextCache: _secondaryTextCache,
          isBilingualMode: _isBilingualMode,
          focusNode: widget.focusNode,
        );
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
  final int activeIndex;
  final double fontSizeScale;
  final ValueChanged<Duration>? onItemTap;
  final VoidCallback? onClearSelection;
  final bool isSmallScreen;
  final int lineFilterMode;
  final Map<int, String> secondaryTextCache; // New
  final bool isBilingualMode; // New
  final FocusNode? focusNode;

  const SubtitleArticleChunk({
    super.key,
    required this.subtitles,
    required this.startIndex,
    required this.endIndex,
    required this.activeIndex,
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
      final isCurrent = i == widget.activeIndex;
      String rawText = _getFilteredText(item.text, i);
      if (rawText.isEmpty && item.imageLoader != null) {
        rawText = "[图片字幕]";
      }
      final text = rawText.replaceAll('\n', ' ');

      final recognizer = TapGestureRecognizer()
        ..onTap = () {
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
            backgroundColor: isCurrent ? Colors.blueAccent.withOpacity(0.1) : null,
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
