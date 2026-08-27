import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../models/subtitle_model.dart';

/// Apple Music 风格歌词列表视图（响应式 vh 单位）
///
/// 自实现版本（不再依赖 flutter_lyric），修复以下问题：
/// - 鼠标滚轮无法控制歌词上下滚动（原版用 CustomPaint+GestureDetector，无 Scrollable）
/// - 点击某行无法迅速、准确跳转到该行（原版点击后需等待 progress 回流才滚动）
///
/// 核心机制：
/// - 基于 SingleChildScrollView + ScrollController，桌面端鼠标滚轮原生支持
/// - 当前行锚定在视口 30% 处（Apple Music 风格）
/// - 进度变化时自动平滑滚动到当前行
/// - 用户滚动（鼠标滚轮/拖拽）后 3 秒自动恢复跟随当前行
/// - 点击某行立即跳转 seek 并滚动到该行
/// - 顶部/底部渐变遮罩
///
/// === 性能优化 ===
/// 通过 positionListenable（`ValueListenable<Duration>`）驱动进度更新，
/// 只有歌词行在进度变化时重绘，整棵歌词控件不因进度变化重建。
///
/// === 双语歌词排版规范（对标 Apple Music 手机端 UI）===
/// - 主字幕（原文）：大字号 ~4.5vh，英文 800 (ExtraBold)，中文 600 (SemiBold)，纯白高亮
/// - 副字幕（翻译）：小字号 ~2.2vh（约主字幕的 0.48 倍），字重与主字幕完全一致，半透明辅助
/// - 中文字体：Noto Sans SC（思源黑体，SemiBold），英文字体：Inter（ExtraBold）
class MusicLyricView extends StatefulWidget {
  final List<SubtitleItem> subtitles;
  final List<SubtitleItem> secondarySubtitles;
  final ValueChanged<Duration>? onSeek;

  /// 进度通知器 — 每帧由 MediaPlaybackService.positionNotifier 更新，
  /// 歌词视图通过监听此通知器来高亮当前行，无需父组件重建。
  final ValueListenable<Duration>? positionListenable;

  /// 用户滚动方向变化回调。
  ///
  /// Apple Music 手机端交互：用户向下滚动歌词时隐藏底部播放控件，
  /// 向上滚动时重新显示。正值表示向上滚（内容向下移），负值表示向下滚（内容向下移）。
  /// null 表示恢复自动跟随模式（控件应重新显示）。
  final void Function(double? direction)? onScrollDirectionChanged;

  /// 歌词字号缩放比例（1.0 = 默认中等偏大，0.6 = 小，1.4 = 大）
  final double lyricFontSizeScale;

  /// 是否将第一行识别为主字幕、其余行作为副字幕（与 video_player_screen 一致）。
  /// 仅当没有独立副字幕轨道（secondarySubtitles 为空）时生效。
  final bool splitSubtitleByLine;

  const MusicLyricView({
    super.key,
    required this.subtitles,
    this.secondarySubtitles = const [],
    this.onSeek,
    this.positionListenable,
    this.onScrollDirectionChanged,
    this.lyricFontSizeScale = 1.0,
    this.splitSubtitleByLine = false,
  });

  @override
  State<MusicLyricView> createState() => MusicLyricViewState();
}

/// Public State class for MusicLyricView.
///
/// This allows external widgets (e.g., MusicPlayerScreen) to call
/// public methods like [scrollToCurrentIndex] via a [GlobalKey].
// ignore_for_file: library_private_classes
class MusicLyricViewState extends State<MusicLyricView>
    with SingleTickerProviderStateMixin {
  final ScrollController _scrollController = ScrollController();
  final List<GlobalKey> _lineKeys = [];

  /// 预计算的副字幕文本列表（与 widget.subtitles 一一对应）。
  /// 在 initState/didUpdateWidget 中预计算一次，构建时 O(1) 查表，
  /// 消除每次歌词树重建时 N 行各调用 _findSecondaryText 的开销。
  List<String> _secondaryTexts = const [];

  /// 当前行索引（基于播放进度计算）
  int _activeIndex = 0;

  /// 当前播放位置（由 positionListenable 驱动，每帧更新）
  Duration _currentPosition = Duration.zero;

  /// 用于控制滚动动画的 AnimationController
  late AnimationController _scrollAnimationController;

  /// 用户点击高亮的行索引（点击后到进度追上之前高亮显示）
  int _tappedIndex = -1;

  /// 是否已完成过「进入页面时的初始定位」。
  /// 用于保证即使当前索引与初始值相同（例如暂停在 0 秒、当前就是第 0 行），
  /// 也能把该行滚动到锚点位置，而不是停留在自然滚动位置（顶部）。
  bool _initialLocateDone = false;

  /// 鼠标悬停的行索引（-1 表示没有悬停）
  int _hoveredIndex = -1;

  /// 用户是否正在手动滚动（触摸拖拽 / 鼠标拖拽）
  bool _isUserScrolling = false;

  /// 是否正在执行程序化滚动（用于区分用户滚动与自动滚动）
  bool _isProgrammaticScroll = false;

  /// 上一次手动滚动位置，用于检测手动滚动方向（不含程序化滚动）
  double? _lastManualScrollOffset;

  /// 记录最后一次手动滚动方向的符号（>0 向下滚隐藏控件，<0 向上滚显示控件）
  double? _lastManualScrollDirection;

  Timer? _resumeTimer;
  bool _disposed = false;

  /// 当前正在进行的滚动动画，用于取消冲突的动画
  Completer<void>? _currentScrollCompleter;

  /// 用于 NotificationListener 判断是否为用户拖拽滚动
  bool _isDragScrolling = false;

  /// 是否正在执行点击跳转（用于避免点击跳转时的滚动被误判为用户手动滚动）
  bool _isTappingLine = false;

  /// 当前行锚点：视口高度的 30%（Apple Music 风格 — 当前行靠上，留 70% 空间给后续歌词）
  static const double _anchorFraction = 0.30;

  /// 用户滚动后恢复自动跟随的延时
  static const Duration _autoResumeDelay = Duration(seconds: 3);

  // ========== Apple Music 风格动画参数 ==========

  /// 正常播放时透明度变化动画时长（ms）— Apple Music 风格：流畅但不过慢
  static const int _normalOpacityDuration = 400;

  /// 大幅度跳转时透明度变化动画时长（ms）— 更快的响应
  static const int _jumpOpacityDuration = 250;

  /// 正常播放时滚动动画时长（ms）
  static const int _normalScrollDuration = 400;

  /// 大幅度跳转时滚动动画时长（ms）— 快速定位
  static const int _jumpScrollDuration = 250;

  /// 判断是否为大幅度跳转的行数阈值
  static const int _largeJumpThreshold = 5;

  // ========== 字体规范（参考竖屏设计文档）==========

  /// 英文字体族：Inter（Apple SF Pro 最佳替代）
  static const String _fontFamilyEng = 'Inter';

  /// 中文字体族：Noto Sans SC（思源黑体，首选）/ MiSans（备选），开源可商用
  /// 思源黑体由 Google 和 Adobe 联合开发，最接近 Apple PingFang SC
  static const String _fontFamilyZh = 'Noto Sans SC';

  /// 检测文本是否包含中文字符（CJK 统一表意文字 U+4E00~U+9FFF）
  /// 用于自动判断原文/翻译应该用哪个字体显示
  static bool _isChineseText(String text) {
    for (final rune in text.runes) {
      if (rune >= 0x4E00 && rune <= 0x9FFF) return true;
    }
    return false;
  }

  /// 原文与翻译的字号比例（中文约为英文的 0.48 倍）
  static const double _zhSizeRatio = 0.48;

  /// 中英文行间距（中文紧贴在英文下方，约 1vh）
  static const double _engZhGapRatio = 0.022;

  /// 段落间距（组与组之间的大间距，约 4.5vh）
  static const double _stanzaGapRatio = 0.045;

  @override
  void initState() {
    super.initState();
    _initLineKeys();
    _precomputeSecondaryTexts();

    // 初始化滚动动画控制器
    _scrollAnimationController = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: _normalScrollDuration),
    );

    // 监听 positionListenable 以更新歌词高亮
    widget.positionListenable?.addListener(_onPositionChanged);
    _currentPosition = widget.positionListenable?.value ?? Duration.zero;

    // 首帧布局完成后做一次无动画定位
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_disposed) {
        _updateActiveIndex(animate: false);
        // 即使从未播放（暂停在 0 秒），也强制把当前行滚动到锚点位置
        _performInitialLocate();
      }
    });
  }

  /// 当 positionListenable 变化时更新 _currentPosition 并刷新歌词高亮
  ///
  /// 优化：直接调用 _updateActiveIndex，确保定位响应及时
  /// - 移除 Timer(Duration.zero) 节流，避免不必要的延迟
  /// - _updateActiveIndex 内部会检查索引是否变化，避免不必要的重建
  void _onPositionChanged() {
    if (!mounted) return;

    _currentPosition = widget.positionListenable?.value ?? Duration.zero;

    // 直接调用 _updateActiveIndex，该方法内部会检查索引是否变化
    // 这种方式比 Timer(Duration.zero) 更及时，避免定位延迟
    _updateActiveIndex();
  }

  void _initLineKeys() {
    _lineKeys.clear();
    for (var i = 0; i < widget.subtitles.length; i++) {
      _lineKeys.add(GlobalKey(debugLabel: 'lyric_line_$i'));
    }
  }

  /// 预计算每行主字幕对应的副字幕文本（与 _findSecondaryText 逻辑完全一致，
  /// 仅提前计算一次并缓存，构建时直接查表，避免每次重建重复计算）。
  void _precomputeSecondaryTexts() {
    final subs = widget.subtitles;
    final result = List<String>.filled(subs.length, '');
    for (int i = 0; i < subs.length; i++) {
      result[i] = _findSecondaryText(subs[i].startTime);
    }
    _secondaryTexts = result;
  }

  @override
  void didUpdateWidget(covariant MusicLyricView oldWidget) {
    super.didUpdateWidget(oldWidget);

    // 检查 subtitles 是否真正变化（不仅比较引用，还比较内容）
    // 避免调节字号等操作时，因引用变化导致误重置用户滚动状态
    if (oldWidget.subtitles != widget.subtitles) {
      final contentChanged = _isSubtitlesContentChanged(
        oldWidget.subtitles,
        widget.subtitles,
      );

      if (contentChanged) {
        _initLineKeys();
        _precomputeSecondaryTexts();
        _activeIndex = 0;
        _tappedIndex = -1;
        _isUserScrolling = false;
        _resumeTimer?.cancel();
        // 字幕数据集变化（含从空到非空、异步加载完成），需要重新做一次初始定位
        _initialLocateDone = false;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!_disposed) {
            _updateActiveIndex(animate: false);
            _performInitialLocate();
          }
        });
      }
      // 如果内容没变，只是引用变化，则不重置用户滚动状态
    }

    // 处理 positionListenable 变化（父组件传入不同的 listenable 时）
    if (oldWidget.positionListenable != widget.positionListenable) {
      oldWidget.positionListenable?.removeListener(_onPositionChanged);
      widget.positionListenable?.addListener(_onPositionChanged);
      _currentPosition = widget.positionListenable?.value ?? Duration.zero;
      _updateActiveIndex(animate: false);
    }
  }

  /// 检查字幕列表内容是否真正变化
  bool _isSubtitlesContentChanged(
    List<SubtitleItem> oldSubs,
    List<SubtitleItem> newSubs,
  ) {
    if (oldSubs.length != newSubs.length) return true;
    for (int i = 0; i < oldSubs.length; i++) {
      if (oldSubs[i].startTime != newSubs[i].startTime ||
          oldSubs[i].text != newSubs[i].text) {
        return true;
      }
    }
    return false;
  }

  /// 二分查找当前进度对应的歌词行索引
  int _findActiveIndex(Duration position) {
    final subs = widget.subtitles;
    if (subs.isEmpty) return 0;
    int left = 0;
    int right = subs.length - 1;
    int result = 0;
    while (left <= right) {
      final mid = left + ((right - left) >> 1);
      if (position < subs[mid].startTime) {
        right = mid - 1;
      } else {
        result = mid;
        left = mid + 1;
      }
    }
    return result;
  }

  void _updateActiveIndex({bool animate = true}) {
    if (!mounted || widget.subtitles.isEmpty) return;

    final newIndex = _findActiveIndex(_currentPosition);
    if (newIndex != _activeIndex) {
      // 判断是否为大幅度跳转
      final jumpDistance = (newIndex - _activeIndex).abs();
      final isLargeJump = jumpDistance > _largeJumpThreshold;

      // setState 触发所有行重新计算透明度（Apple Music 淡入淡出效果）
      setState(() {
        _activeIndex = newIndex;
        // 当播放进度追上点击行时，清除点击高亮
        if (_tappedIndex >= 0 && newIndex >= _tappedIndex) {
          _tappedIndex = -1;
        }
        // 记录跳转类型，供 AnimatedOpacity 使用
        _isLargeJump = isLargeJump;
      });
      if (!_isUserScrolling) {
        _scrollToIndex(newIndex, animate: animate, isLargeJump: isLargeJump);
      }

      // 动画完成后重置 _isLargeJump 标志
      // 使用动画时长 + 缓冲时间
      final resetDelay = isLargeJump
          ? _jumpOpacityDuration + 50
          : _normalOpacityDuration + 50;
      Future.delayed(Duration(milliseconds: resetDelay), () {
        if (mounted && _isLargeJump == isLargeJump) {
          setState(() {
            _isLargeJump = false;
          });
        }
      });
    } else {
      // 索引没变，但可能需要更新 _tappedIndex 和 _isLargeJump
      // 优化：只在需要时才 setState
      bool needUpdate = false;

      if (_tappedIndex >= 0 && newIndex >= _tappedIndex) {
        _tappedIndex = -1;
        needUpdate = true;
      }

      if (_isLargeJump) {
        _isLargeJump = false;
        needUpdate = true;
      }

      if (needUpdate && mounted) {
        setState(() {});
      }
    }
  }

  /// 是否为大幅度跳转（用于控制动画速度）
  bool _isLargeJump = false;

  /// 将指定行滚动到锚点位置（视口 30%）
  ///
  /// Apple Music 风格：优雅的滚动动画，支持正常播放和大幅度跳转两种模式
  Future<void> _scrollToIndex(
    int index, {
    bool animate = true,
    bool isLargeJump = false,
  }) async {
    if (!mounted || index < 0 || index >= _lineKeys.length) return;
    final key = _lineKeys[index];
    final ctx = key.currentContext;
    if (ctx == null) {
      // 行尚未构建，下一帧重试
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_disposed && mounted) {
          _scrollToIndex(index, animate: animate, isLargeJump: isLargeJump);
        }
      });
      return;
    }

    // 取消正在进行的滚动动画
    _currentScrollCompleter?.complete();
    final completer = Completer<void>();
    _currentScrollCompleter = completer;

    _isProgrammaticScroll = true;
    try {
      // 根据是否是大幅度跳转选择动画参数
      final duration = animate
          ? (isLargeJump
                ? Duration(milliseconds: _jumpScrollDuration)
                : Duration(milliseconds: _normalScrollDuration))
          : Duration.zero;
      final curve = isLargeJump
          ? Curves.easeInOutCubic
          : const Cubic(0.25, 0.8, 0.25, 1);

      await Scrollable.ensureVisible(
        ctx,
        alignment: _anchorFraction,
        alignmentPolicy: ScrollPositionAlignmentPolicy.explicit,
        duration: duration,
        curve: curve,
      );

      if (!completer.isCompleted) {
        completer.complete();
      }
    } catch (e) {
      if (!completer.isCompleted) {
        completer.complete();
      }
    } finally {
      // 延迟重置标志位，确保滚动动画完全结束，避免 NotificationListener 误判
      // 延迟时间略长于滚动动画，确保所有可能的 ScrollNotification 都已处理完毕
      final resetDelay = animate
          ? (isLargeJump
                ? _jumpScrollDuration + 100
                : _normalScrollDuration + 100)
          : 50;
      Future.delayed(Duration(milliseconds: resetDelay), () {
        if (mounted && !_disposed) {
          _isProgrammaticScroll = false;
        }
      });
      if (_currentScrollCompleter == completer) {
        _currentScrollCompleter = null;
      }
    }
  }

  /// 点击某行：立即 seek + 立即滚动到该行
  void _handleTapLine(int index) {
    if (index < 0 || index >= widget.subtitles.length) return;
    final sub = widget.subtitles[index];
    setState(() {
      _tappedIndex = index;
      _isUserScrolling = false;
      _isTappingLine = true; // ✅ 标记正在执行点击跳转
    });
    _resumeTimer?.cancel();
    // ✅ 点击歌词时不再通知父组件显示控件，避免干扰原有的显隐状态
    // widget.onScrollDirectionChanged?.call(-1);
    widget.onSeek?.call(sub.startTime);
    _scrollToIndex(index, animate: true).then((_) {
      // 滚动完成后延迟重置标志位，确保所有滚动通知都已处理
      Future.delayed(const Duration(milliseconds: 100), () {
        if (mounted && !_disposed) {
          _isTappingLine = false;
        }
      });
    });
  }

  /// Apple Music 歌词透明度算法（包含点击和悬停效果）
  ///
  /// - 当前行 (offset=0)：完全不透明
  /// - 已播放 (offset<0)：快速淡出，但最低保持在 0.35
  /// - 后续行 (offset>0)：逐渐降低透明度，最低保持在 0.35
  /// - 鼠标悬停：该行透明度稍微增加（变亮）
  double _opacityForOffset(int offset, bool isTapped, bool isHovered) {
    // 点击状态：完全不透明
    if (isTapped) return 1.0;

    // 当前行：完全不透明
    if (offset == 0) return 1.0;

    // 计算基础透明度
    double opacity;

    if (offset < 0) {
      // 已播放歌词：快速淡出，但最低保持在 0.35
      final distance = -offset; // 距离当前行的行数
      if (distance == 1) {
        opacity = 0.50; // 上一行：较淡
      } else if (distance == 2) {
        opacity = 0.42; // 上两行：更淡
      } else {
        opacity = 0.35; // 上三行及以后：最低透明度
      }
    } else {
      // 后续歌词：逐渐淡出，最低 0.35
      if (offset == 1) {
        opacity = 0.55; // 下一行：稍淡
      } else if (offset == 2) {
        opacity = 0.42; // 下两行：更淡
      } else {
        opacity = 0.35; // 下三行及以后：最低透明度
      }
    }

    // 鼠标悬停效果：透明度稍微增加（变亮）
    // Apple Music 效果：悬停时透明度增加 0.15（微妙的变化）
    if (isHovered) {
      opacity = (opacity + 0.15).clamp(0.0, 1.0);
    }

    return opacity;
  }

  @override
  void dispose() {
    _disposed = true;
    _resumeTimer?.cancel();
    widget.positionListenable?.removeListener(_onPositionChanged);
    _scrollController.dispose();
    _scrollAnimationController.dispose();
    super.dispose();
  }

  /// 暴露给外部的滚动方法：滚动到当前播放位置的字幕
  ///
  /// 用于全屏切换后自动定位到当前字幕，
  /// 也可以在其他需要刷新定位的场景下调用。
  /// [animate] 控制是否有动画，默认有动画。
  void scrollToCurrentIndex({bool animate = true}) {
    if (!mounted || widget.subtitles.isEmpty) return;
    final currentIndex = _findActiveIndex(_currentPosition);
    _scrollToIndex(currentIndex, animate: animate, isLargeJump: true);
  }

  /// 进入页面（或字幕首次就绪）时，把歌词滚动到当前播放位置对应的行。
  ///
  /// 与 [scrollToCurrentIndex] 的区别：本方法会忽略「索引是否变化」的判断，
  /// 即使当前行就是初始的第 0 行（例如视频一直暂停在 0 秒）也会强制把该行
  /// 滚动到锚点（视口约 30%）位置，而不是停留在自然滚动位置（顶部）。
  /// 同时保证在「视频从未播放」的场景下也能完成一次自动定位。
  /// 仅在尚未完成过初始定位时执行一次，避免干扰用户后续的手动滚动。
  void _performInitialLocate() {
    if (!mounted || widget.subtitles.isEmpty) return;
    if (_initialLocateDone) return;
    _initialLocateDone = true;
    final index = _findActiveIndex(_currentPosition);
    _scrollToIndex(index, animate: false, isLargeJump: true);
  }

  @override
  Widget build(BuildContext context) {
    final screenHeight = MediaQuery.of(context).size.height;
    final screenWidth = MediaQuery.of(context).size.width; // ✅ 获取屏幕宽度用于计算边距
    // 统一字号：Apple Music 风格 — 不改变字号，只改变透明度（亮度）
    // 原文（英文）：4.5vh，clamp 20~44；lyricFontSizeScale 控制缩放（1.0=默认中等偏大）
    final engFontSize = (screenHeight * 0.045 * widget.lyricFontSizeScale)
        .clamp(20.0, 44.0);
    // 翻译（中文）：约为原文的 0.48 倍（相对比例不变）
    final zhFontSize = (engFontSize * _zhSizeRatio).clamp(12.0, 22.0);
    // 段落间距（组间）：4.5vh，clamp 16~32
    final stanzaGap = (screenHeight * _stanzaGapRatio).clamp(16.0, 32.0);
    // 中英文间距（行内）：1vh，clamp 4~10
    final engZhGap = (screenHeight * _engZhGapRatio).clamp(4.0, 10.0);

    return LayoutBuilder(
      builder: (context, constraints) {
        final viewportHeight = constraints.maxHeight;
        // 顶/底内边距：让首/末行也能滚动到锚点位置
        final topPadding = viewportHeight * _anchorFraction;
        final bottomPadding = viewportHeight * (1.0 - _anchorFraction);

        return ShaderMask(
          shaderCallback: (Rect bounds) {
            return const LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Color(0x00FFFFFF),
                Color(0xFFFFFFFF),
                Color(0xFFFFFFFF),
                Color(0x00FFFFFF),
              ],
              stops: [0.0, 0.15, 0.85, 1.0],
            ).createShader(bounds);
          },
          blendMode: BlendMode.dstIn,
          child: _buildScrollContent(
            screenWidth: screenWidth, // ✅ 传入 screenWidth
            engFontSize: engFontSize,
            zhFontSize: zhFontSize,
            stanzaGap: stanzaGap,
            engZhGap: engZhGap,
            topPadding: topPadding,
            bottomPadding: bottomPadding,
          ),
        );
      },
    );
  }

  /// 处理 ScrollNotification，精准区分用户手动滚动与程序化滚动
  ///
  /// 核心逻辑：
  /// - 点击跳转时（_isTappingLine == true）完全忽略通知，避免误触发控件显隐
  /// - 程序化滚动（_isProgrammaticScroll == true）时完全忽略通知，避免自动跟随动画干扰控件显隐
  /// - 用户拖拽（dragDetails != null）或鼠标滚轮时记录方向并通知父组件
  /// - 滚动停止后延时恢复自动跟随
  bool _handleScrollNotification(ScrollNotification notification) {
    // ✅ 点击跳转时忽略所有通知（避免点击跳转被误判为用户手动滚动）
    if (_isTappingLine) return false;

    // 程序化滚动时忽略所有通知（自动跟随动画不应触发控件显隐）
    if (_isProgrammaticScroll) return false;

    if (notification is ScrollStartNotification) {
      // dragDetails != null 表示用户通过触摸/鼠标拖拽发起的滚动（非程序化）
      if (notification.dragDetails != null) {
        _isDragScrolling = true;
        _isUserScrolling = true;
        _resumeTimer?.cancel();
      }
    }

    if (notification is ScrollUpdateNotification) {
      // 仅处理用户手动滚动（拖拽或鼠标滚轮）
      if (_isUserScrolling) {
        final currentOffset = _scrollController.offset;
        if (_lastManualScrollOffset != null &&
            (_lastManualScrollOffset! - currentOffset).abs() > 1.0) {
          final delta = _lastManualScrollOffset! - currentOffset;
          // ✅ 修正方向逻辑（对标 Apple Music）：
          // delta > 0: 内容向下移动（用户向上滑/往前翻字幕）→ 显示控件（direction = 1.0）
          // delta < 0: 内容向上移动（用户向下滑/往后翻字幕）→ 隐藏控件（direction = -1.0）
          final direction = delta > 0 ? 1.0 : -1.0;
          // 仅当方向变化时才通知，避免重复回调
          if (_lastManualScrollDirection == null ||
              (direction > 0 && _lastManualScrollDirection! < 0) ||
              (direction < 0 && _lastManualScrollDirection! > 0)) {
            _lastManualScrollDirection = direction;
            widget.onScrollDirectionChanged?.call(direction);
          }
        }
        _lastManualScrollOffset = currentOffset;
      }

      // 鼠标滚轮检测：无 dragDetails 但 offset 发生了变化（鼠标滚轮不会设置 dragDetails）
      if (!_isDragScrolling && !_isProgrammaticScroll) {
        final currentOffset = _scrollController.offset;
        if (_lastManualScrollOffset != null &&
            (_lastManualScrollOffset! - currentOffset).abs() > 1.0) {
          _isUserScrolling = true;
          _resumeTimer?.cancel();
          final delta = _lastManualScrollOffset! - currentOffset;
          // ✅ 修正方向逻辑
          final direction = delta > 0 ? 1.0 : -1.0;
          _lastManualScrollDirection = direction;
          widget.onScrollDirectionChanged?.call(direction);
        }
        _lastManualScrollOffset = currentOffset;
      }
    }

    if (notification is ScrollEndNotification) {
      if (_isUserScrolling && !_isProgrammaticScroll) {
        _scheduleResumeAutoFollow();
      }
      _isDragScrolling = false;
    }

    return false; // 不阻止通知冒泡
  }

  /// 用户停止滚动后延时恢复自动跟随
  void _scheduleResumeAutoFollow() {
    _resumeTimer?.cancel();
    _resumeTimer = Timer(_autoResumeDelay, () {
      if (_disposed || !mounted) return;
      _isUserScrolling = false;
      _lastManualScrollOffset = null;
      _lastManualScrollDirection = null;
      _isDragScrolling = false;
      // 通知父组件恢复自动跟随（显示控件）
      widget.onScrollDirectionChanged?.call(null);
      _scrollToIndex(_activeIndex, animate: true);
    });
  }

  Widget _buildScrollContent({
    required double screenWidth, // ✅ 屏幕宽度用于计算左右边距
    required double engFontSize,
    required double zhFontSize,
    required double stanzaGap,
    required double engZhGap,
    required double topPadding,
    required double bottomPadding,
  }) {
    final subs = widget.subtitles;
    if (subs.isEmpty) {
      return const SizedBox.shrink();
    }

    final scrollView = SingleChildScrollView(
      controller: _scrollController,
      padding: EdgeInsets.only(
        top: topPadding,
        bottom: bottomPadding,
        left: screenWidth * 0.05, // ✅ 对标 Apple Music：屏幕宽度的5%
        right: screenWidth * 0.05,
      ),
      // 桌面端鼠标滚轮 + 触摸拖拽均原生支持
      physics: const BouncingScrollPhysics(
        parent: RangeMaintainingScrollPhysics(),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (int i = 0; i < subs.length; i++)
            _buildLyricGroup(
              index: i,
              sub: subs[i],
              engFontSize: engFontSize,
              zhFontSize: zhFontSize,
              stanzaGap: stanzaGap,
              engZhGap: engZhGap,
            ),
        ],
      ),
    );

    // 用 NotificationListener 包裹，精准区分用户手动滚动与程序化滚动
    return NotificationListener<ScrollNotification>(
      onNotification: _handleScrollNotification,
      child: scrollView,
    );
  }

  /// 根据时间点查找匹配的副字幕文本
  ///
  /// 返回匹配时间点的副字幕文本，如果未找到则返回空字符串
  String _findSecondaryText(Duration startTime) {
    if (widget.secondarySubtitles.isEmpty) return '';

    // 查找与当前主字幕时间点匹配的副字幕
    // 使用二分查找提高效率
    int left = 0;
    int right = widget.secondarySubtitles.length - 1;

    while (left <= right) {
      final mid = left + ((right - left) >> 1);
      final sub = widget.secondarySubtitles[mid];

      if (startTime.inMilliseconds < sub.startTime.inMilliseconds) {
        right = mid - 1;
      } else if (startTime.inMilliseconds > sub.startTime.inMilliseconds) {
        left = mid + 1;
      } else {
        // 精确匹配
        return sub.text;
      }
    }

    // 如果未精确匹配，查找时间最接近的（允许 100ms 误差）
    for (final sub in widget.secondarySubtitles) {
      if ((sub.startTime.inMilliseconds - startTime.inMilliseconds).abs() <=
          100) {
        return sub.text;
      }
    }

    return '';
  }

  /// 构建双语歌词组（主字幕 + 副字幕）
  ///
  /// Apple Music 风格：不改变字体大小，只通过透明度和颜色区分当前行
  /// 优化：使用 RepaintBoundary 减少重绘
  Widget _buildLyricGroup({
    required int index,
    required SubtitleItem sub,
    required double engFontSize,
    required double zhFontSize,
    required double stanzaGap,
    required double engZhGap,
  }) {
    final isActive = index == _activeIndex;
    final isTapped = index == _tappedIndex;
    final isHovered = index == _hoveredIndex;
    final offset = index - _activeIndex;
    // Apple Music 透明度：基于与当前行的距离 + 悬停效果
    final opacity = _opacityForOffset(offset, isTapped, isHovered);
    final highlight = isActive || isTapped;

    // 主字幕文本（原文）
    String mainText = sub.text;
    // 查找匹配的副字幕文本（翻译）— 查预计算表，O(1)，避免每次构建重复计算
    String translatedText = index < _secondaryTexts.length
        ? _secondaryTexts[index]
        : '';

    // 识别第一行为主字幕：当没有独立副字幕轨道且设置开启时，
    // 将第一行作为主字幕，其余行作为副字幕（与 video_player_screen 逻辑一致）
    if (widget.splitSubtitleByLine &&
        widget.secondarySubtitles.isEmpty &&
        mainText.contains('\n')) {
      final lines = mainText.split('\n');
      mainText = lines[0];
      translatedText = lines.sublist(1).join('\n');
    }

    // 优化：对静态行使用 Opacity，对动态行使用 AnimatedOpacity
    // 静态行：距离当前行 > 2，透明度不变，不需要动画
    final isStaticLine = offset.abs() > 2 && !isHovered;

    // 构建歌词内容（复用）
    Widget lyricContent = Container(
      key: _lineKeys[index],
      width: double.infinity,
      padding: EdgeInsets.only(bottom: stanzaGap),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // === 原文（自动检测语言，中文用思源黑体，其他用 Inter）— 主导视觉 ===
          // 统一字号，只通过透明度区分（Apple Music 风格）
          // 注意：整体透明度由 AnimatedOpacity 控制，这里只设置颜色
          Text(
            mainText,
            textAlign: TextAlign.left,
            softWrap: true,
            maxLines: null,
            style: TextStyle(
              // 自动检测：含中文用思源黑体，否则用 Inter
              fontFamily: _isChineseText(mainText)
                  ? _fontFamilyZh
                  : _fontFamilyEng,
              fontSize: engFontSize, // 统一字号，不变
              // 中文用 SemiBold (w600)，英文用 ExtraBold (w800)
              fontWeight: _isChineseText(mainText)
                  ? FontWeight.w600
                  : FontWeight.w800,
              color: Colors.white, // 颜色固定为白色，透明度由 AnimatedOpacity 控制
              height: 1.3,
              letterSpacing: -0.5, // 收紧字间距更有现代感
            ),
          ),

          // === 翻译（中文）— 辅助补充 ===
          // 副字幕比主字幕稍淡，通过颜色 alpha 实现
          if (translatedText.isNotEmpty)
            Padding(
              padding: EdgeInsets.only(top: engZhGap),
              child: Text(
                translatedText,
                textAlign: TextAlign.left,
                softWrap: true,
                maxLines: null,
                style: TextStyle(
                  fontFamily: _fontFamilyZh,
                  fontSize: zhFontSize,
                  // 与主字幕字重完全一致（中文 w600，英文 w800）
                  fontWeight: _isChineseText(translatedText)
                      ? FontWeight.w600
                      : FontWeight.w800,
                  // 副字幕比主字幕稍淡（当前行 0.7，非当前行 0.5）
                  color: Colors.white.withValues(
                    alpha: highlight ? 0.70 : 0.50,
                  ),
                  height: 1.5,
                ),
              ),
            ),
        ],
      ),
    );

    // 优化：静态行使用 Opacity，动态行使用 AnimatedOpacity
    Widget opacityWrapper;
    if (isStaticLine) {
      // 静态行：透明度不变，不需要动画
      opacityWrapper = Opacity(opacity: opacity, child: lyricContent);
    } else {
      // 动态行：透明度可能变化，使用动画
      opacityWrapper = AnimatedOpacity(
        opacity: opacity,
        // Apple Music 风格：根据跳转类型使用不同的动画时长
        duration: Duration(
          milliseconds: _isLargeJump
              ? _jumpOpacityDuration
              : _normalOpacityDuration,
        ),
        curve: _isLargeJump
            ? Curves.easeInOutCubic
            : const Cubic(0.25, 0.8, 0.25, 1),
        child: lyricContent,
      );
    }

    // 优化：只对动态行使用 RepaintBoundary
    // 静态行不需要独立重绘边界
    Widget repaintWrapper;
    if (isStaticLine) {
      repaintWrapper = opacityWrapper;
    } else {
      repaintWrapper = RepaintBoundary(child: opacityWrapper);
    }

    // 优化：只对动态行监听鼠标事件（移动端不启用 MouseRegion）
    if (isStaticLine) {
      // 静态行：不需要鼠标事件监听
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _handleTapLine(index),
        child: repaintWrapper,
      );
    } else {
      // 动态行：需要鼠标事件监听（只在桌面端启用）
      return MouseRegion(
        onEnter: (_) {
          // 鼠标进入：更新悬停索引
          if (mounted) {
            setState(() {
              _hoveredIndex = index;
            });
          }
        },
        onExit: (_) {
          // 鼠标离开：只有当离开的行是当前悬停的行时，才清除
          Future.delayed(const Duration(milliseconds: 50), () {
            if (_hoveredIndex == index && mounted) {
              setState(() {
                _hoveredIndex = -1;
              });
            }
          });
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => _handleTapLine(index),
          child: repaintWrapper,
        ),
      );
    }
  }
}
