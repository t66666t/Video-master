import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:open_filex/open_filex.dart';
import 'package:permission_handler/permission_handler.dart';
import '../models/subtitle_style.dart';
import '../models/video_compose_models.dart';
import '../models/video_item.dart';
import '../services/settings_service.dart';
import '../services/video_compose_manager.dart';
import '../services/video_compose/video_compose_preview_controller.dart';
import '../utils/app_toast.dart';
import 'package:intl/intl.dart';
import '../screens/simple_video_player_screen.dart';

class VideoComposePanel extends StatefulWidget {
  final VideoItem videoItem;
  final List<String> currentSelectedPaths;
  final Map<String, String> availableSubtitleMap;
  final VoidCallback? onBack;
  final VoidCallback? onOpenSubtitleStyle;
  final VoidCallback? onOpenSubtitleManager;
  final ValueChanged<VideoComposePreviewConfig>? onPreviewChanged;

  const VideoComposePanel({
    super.key,
    required this.videoItem,
    required this.currentSelectedPaths,
    required this.availableSubtitleMap,
    this.onBack,
    this.onOpenSubtitleStyle,
    this.onOpenSubtitleManager,
    this.onPreviewChanged,
  });

  @override
  State<VideoComposePanel> createState() => _VideoComposePanelState();
}

class _ComposeSelectItem<T> {
  final T value;
  final String label;

  const _ComposeSelectItem({required this.value, required this.label});
}

class _ComposeSelect<T> extends StatefulWidget {
  final T? value;
  final String label;
  final String emptyLabel;
  final List<_ComposeSelectItem<T>> items;
  final ValueChanged<T>? onChanged;
  final double fontSize;

  const _ComposeSelect({
    super.key,
    required this.value,
    required this.label,
    required this.items,
    required this.onChanged,
    required this.fontSize,
    this.emptyLabel = '请选择',
  });

  @override
  State<_ComposeSelect<T>> createState() => _ComposeSelectState<T>();
}

class _ComposeSelectState<T> extends State<_ComposeSelect<T>>
    with SingleTickerProviderStateMixin {
  final LayerLink _layerLink = LayerLink();
  final FocusNode _focusNode = FocusNode();
  OverlayEntry? _overlayEntry;
  late final AnimationController _animationController;
  late final Animation<double> _fadeAnimation;
  late final Animation<double> _scaleAnimation;
  late final Animation<Offset> _slideAnimation;
  bool _isOpen = false;
  bool _isHovered = false;
  bool _isFocused = false;
  double _anchorWidth = 240;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 190),
      reverseDuration: const Duration(milliseconds: 145),
    );
    final curved = CurvedAnimation(
      parent: _animationController,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    _fadeAnimation = curved;
    _scaleAnimation = Tween<double>(begin: 0.96, end: 1).animate(curved);
    _slideAnimation = Tween<Offset>(
      begin: const Offset(0, -0.035),
      end: Offset.zero,
    ).animate(curved);
    _focusNode.addListener(_handleFocusChanged);
  }

  @override
  void didUpdateWidget(covariant _ComposeSelect<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    _overlayEntry?.markNeedsBuild();
  }

  @override
  void dispose() {
    _overlayEntry?.remove();
    _overlayEntry = null;
    _focusNode
      ..removeListener(_handleFocusChanged)
      ..dispose();
    _animationController.dispose();
    super.dispose();
  }

  bool get _isEnabled => widget.items.isNotEmpty && widget.onChanged != null;

  String get _selectedLabel {
    for (final item in widget.items) {
      if (item.value == widget.value) return item.label;
    }
    return widget.items.isEmpty ? '暂无可用选项' : widget.emptyLabel;
  }

  IconData get _fieldIcon {
    if (widget.label.contains('字幕')) return Icons.subtitles_rounded;
    if (widget.label.contains('分辨率')) return Icons.aspect_ratio_rounded;
    if (widget.label.contains('烧录') || widget.label.contains('渲染')) {
      return Icons.auto_awesome_rounded;
    }
    return Icons.tune_rounded;
  }

  void _handleFocusChanged() {
    if (!mounted || _isFocused == _focusNode.hasFocus) return;
    setState(() => _isFocused = _focusNode.hasFocus);
  }

  void _toggleMenu() {
    if (!_isEnabled) return;
    if (_isOpen) {
      _closeMenu();
    } else {
      _openMenu();
    }
  }

  void _openMenu() {
    if (!_isEnabled || _isOpen) return;
    _focusNode.requestFocus();
    _isOpen = true;
    if (mounted) setState(() {});
    _overlayEntry ??= OverlayEntry(builder: _buildOverlay);
    if (!_overlayEntry!.mounted) {
      Overlay.of(context, rootOverlay: true).insert(_overlayEntry!);
    }
    _animationController.forward();
  }

  Future<void> _closeMenu() async {
    if (!_isOpen && _overlayEntry == null) return;
    _isOpen = false;
    if (mounted) setState(() {});
    await _animationController.reverse();
    if (_isOpen) return;
    _overlayEntry?.remove();
    _overlayEntry = null;
  }

  void _selectItem(T value) {
    widget.onChanged?.call(value);
    _overlayEntry?.markNeedsBuild();
    _closeMenu();
  }

  Widget _buildOverlay(BuildContext overlayContext) {
    final double popupWidth = _anchorWidth.clamp(220.0, 520.0);
    final renderBox = context.findRenderObject() as RenderBox?;
    final anchorTop = renderBox?.localToGlobal(Offset.zero).dy ?? 0;
    final anchorHeight = renderBox?.size.height ?? 52;
    final viewportHeight = MediaQuery.sizeOf(context).height;
    final estimatedHeight = (widget.items.length * 47.0 + 48).clamp(
      96.0,
      420.0,
    );
    final spaceBelow = viewportHeight - anchorTop - anchorHeight;
    final bool showAbove =
        spaceBelow < estimatedHeight + 12 && anchorTop > spaceBelow;
    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: _closeMenu,
          ),
        ),
        CompositedTransformFollower(
          link: _layerLink,
          showWhenUnlinked: false,
          targetAnchor: showAbove ? Alignment.topLeft : Alignment.bottomLeft,
          followerAnchor: showAbove ? Alignment.bottomLeft : Alignment.topLeft,
          offset: Offset(0, showAbove ? -8 : 8),
          child: FadeTransition(
            opacity: _fadeAnimation,
            child: SlideTransition(
              position: _slideAnimation,
              child: ScaleTransition(
                scale: _scaleAnimation,
                alignment: Alignment.topCenter,
                child: Material(
                  color: Colors.transparent,
                  child: Container(
                    width: popupWidth,
                    constraints: const BoxConstraints(maxHeight: 420),
                    padding: const EdgeInsets.fromLTRB(7, 8, 7, 7),
                    decoration: BoxDecoration(
                      color: const Color(0xFF20242B),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: const Color(0xFF3A414D)),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.48),
                          blurRadius: 28,
                          offset: const Offset(0, 12),
                        ),
                        BoxShadow(
                          color: const Color(
                            0xFF4D91FF,
                          ).withValues(alpha: 0.08),
                          blurRadius: 18,
                        ),
                      ],
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(10, 4, 10, 8),
                          child: Row(
                            children: [
                              Container(
                                width: 5,
                                height: 14,
                                decoration: BoxDecoration(
                                  color: const Color(0xFF65A2FF),
                                  borderRadius: BorderRadius.circular(99),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  widget.label,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: Colors.white70,
                                    fontSize: (widget.fontSize - 1).clamp(
                                      10.0,
                                      13.0,
                                    ),
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        Flexible(
                          child: SingleChildScrollView(
                            padding: EdgeInsets.zero,
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: widget.items
                                  .map(_buildPopupItem)
                                  .toList(growable: false),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildPopupItem(_ComposeSelectItem<T> item) {
    final bool selected = item.value == widget.value;
    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: _ComposeSelectOption(
        label: item.label,
        selected: selected,
        fontSize: widget.fontSize,
        onTap: () => _selectItem(item.value),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bool highlighted = _isOpen || _isFocused;
    final Color borderColor = highlighted
        ? const Color(0xFF639FFF)
        : (_isHovered ? const Color(0xFF4A5361) : const Color(0xFF383E48));
    final Color fillColor = highlighted
        ? const Color(0xFF27364B)
        : (_isHovered ? const Color(0xFF292F38) : const Color(0xFF242930));
    final double controlHeight = (widget.fontSize * 3.9).clamp(48.0, 56.0);

    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth.isFinite) _anchorWidth = constraints.maxWidth;
        return CompositedTransformTarget(
          link: _layerLink,
          child: Semantics(
            button: true,
            enabled: _isEnabled,
            expanded: _isOpen,
            label: widget.label,
            value: _selectedLabel,
            child: FocusableActionDetector(
              focusNode: _focusNode,
              enabled: _isEnabled,
              mouseCursor: _isEnabled
                  ? SystemMouseCursors.click
                  : SystemMouseCursors.basic,
              onShowHoverHighlight: (value) {
                if (mounted && _isHovered != value) {
                  setState(() => _isHovered = value);
                }
              },
              onShowFocusHighlight: (value) {
                if (mounted && _isFocused != value) {
                  setState(() => _isFocused = value);
                }
              },
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _isEnabled ? _toggleMenu : null,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 170),
                  curve: Curves.easeOutCubic,
                  height: controlHeight,
                  padding: const EdgeInsets.fromLTRB(9, 7, 10, 7),
                  decoration: BoxDecoration(
                    color: fillColor,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: borderColor,
                      width: highlighted ? 1.35 : 1,
                    ),
                    boxShadow: highlighted
                        ? [
                            BoxShadow(
                              color: const Color(
                                0xFF2979FF,
                              ).withValues(alpha: 0.12),
                              blurRadius: 12,
                              spreadRadius: 1,
                            ),
                          ]
                        : const <BoxShadow>[],
                  ),
                  child: Row(
                    children: [
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 170),
                        curve: Curves.easeOutCubic,
                        width: 34,
                        height: 34,
                        decoration: BoxDecoration(
                          color: highlighted
                              ? const Color(0xFF4D91FF)
                              : const Color(0xFF343B46),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Icon(
                          _fieldIcon,
                          size: widget.fontSize + 3,
                          color: highlighted ? Colors.white : Colors.white60,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              widget.label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: highlighted
                                    ? const Color(0xFF8DB8FF)
                                    : Colors.white54,
                                fontSize: (widget.fontSize - 2).clamp(
                                  9.0,
                                  11.0,
                                ),
                                fontWeight: FontWeight.w600,
                                letterSpacing: 0.15,
                              ),
                            ),
                            const SizedBox(height: 2),
                            ClipRect(
                              child: AnimatedSwitcher(
                                duration: const Duration(milliseconds: 160),
                                reverseDuration: const Duration(
                                  milliseconds: 120,
                                ),
                                switchInCurve: Curves.easeOutCubic,
                                switchOutCurve: Curves.easeInCubic,
                                transitionBuilder: (child, animation) {
                                  return FadeTransition(
                                    opacity: animation,
                                    child: SlideTransition(
                                      position: Tween<Offset>(
                                        begin: const Offset(0, 0.16),
                                        end: Offset.zero,
                                      ).animate(animation),
                                      child: child,
                                    ),
                                  );
                                },
                                child: Text(
                                  _selectedLabel,
                                  key: ValueKey<Object?>(widget.value),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: _isEnabled
                                        ? Colors.white
                                        : Colors.white38,
                                    fontSize: widget.fontSize,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 7),
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 170),
                        curve: Curves.easeOutCubic,
                        width: 28,
                        height: 28,
                        decoration: BoxDecoration(
                          color: highlighted
                              ? Colors.white.withValues(alpha: 0.1)
                              : Colors.transparent,
                          shape: BoxShape.circle,
                        ),
                        child: AnimatedRotation(
                          turns: _isOpen ? 0.5 : 0,
                          duration: const Duration(milliseconds: 180),
                          curve: Curves.easeOutCubic,
                          child: Icon(
                            Icons.keyboard_arrow_down_rounded,
                            size: widget.fontSize + 7,
                            color: highlighted
                                ? const Color(0xFFA9CAFF)
                                : Colors.white54,
                          ),
                        ),
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
}

class _ComposeSelectOption extends StatefulWidget {
  final String label;
  final bool selected;
  final double fontSize;
  final VoidCallback onTap;

  const _ComposeSelectOption({
    required this.label,
    required this.selected,
    required this.fontSize,
    required this.onTap,
  });

  @override
  State<_ComposeSelectOption> createState() => _ComposeSelectOptionState();
}

class _ComposeSelectOptionState extends State<_ComposeSelectOption> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final active = widget.selected || _hovered;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 135),
          curve: Curves.easeOutCubic,
          constraints: const BoxConstraints(minHeight: 44),
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
          decoration: BoxDecoration(
            color: widget.selected
                ? const Color(0xFF2C4770)
                : (_hovered ? const Color(0xFF2B323D) : Colors.transparent),
            borderRadius: BorderRadius.circular(11),
            border: Border.all(
              color: widget.selected
                  ? const Color(0xFF477EC4)
                  : Colors.transparent,
            ),
          ),
          child: Row(
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  color: widget.selected
                      ? const Color(0xFF67A3FF)
                      : const Color(0xFF303741),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: active ? const Color(0xFF78ACFF) : Colors.white24,
                  ),
                ),
                child: AnimatedScale(
                  scale: widget.selected ? 1 : 0,
                  duration: const Duration(milliseconds: 150),
                  curve: Curves.easeOutBack,
                  child: const Icon(
                    Icons.check_rounded,
                    size: 15,
                    color: Colors.white,
                  ),
                ),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Text(
                  widget.label,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: widget.selected ? Colors.white : Colors.white70,
                    fontSize: widget.fontSize,
                    height: 1.25,
                    fontWeight: widget.selected
                        ? FontWeight.w600
                        : FontWeight.w400,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _VideoComposePanelState extends State<VideoComposePanel> {
  String? _primaryPath;
  String? _secondaryPath;
  String? _customOutputPath;
  String? _sourceResolutionLabel;
  VideoComposeResolution _resolution = VideoComposeResolution.p1080;
  VideoComposeRenderMode _renderMode = VideoComposeRenderMode.precise;
  bool _continuousSubtitle = false;
  bool _embedSoftSubtitles = false;
  bool _softSubtitleOnly = false;
  bool _softSubtitleUseSourceQuality = true;
  bool _animateVisibility = false;
  bool _deleteOutputOnTaskDelete = true;
  bool get _showCustomOutputDirectory => !Platform.isIOS;

  String get _openOutputLabel {
    if (Platform.isWindows) return '用文件资源管理器打开';
    if (Platform.isMacOS) return '在“访达”中显示';
    if (Platform.isLinux) return '在文件管理器中显示';
    return '用其他应用打开';
  }

  String get _savedOutputHint {
    if (Platform.isWindows) return '已保存，可在文件资源管理器中定位该文件';
    if (Platform.isMacOS) return '已保存，可在“访达”中定位该文件';
    if (Platform.isLinux) return '已保存，可在文件管理器中定位该文件';
    return '已保存，可使用其他应用打开该视频';
  }

  String get _defaultOutputDirectoryLabel {
    if (Platform.isAndroid) {
      return '/storage/emulated/0/Download/ComposedVideos';
    }
    if (Platform.isWindows || Platform.isMacOS) {
      return '默认目录（程序所在目录/ComposedVideos）';
    }
    return '默认目录（应用文档/ComposedVideos）';
  }

  @override
  void initState() {
    super.initState();
    _loadInitialFromSettings(applyState: false);
    _loadSourceResolution();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _notifyPreviewChanged();
      setState(() {
        _animateVisibility = true;
      });
    });
  }

  void _notifyPreviewChanged() {
    widget.onPreviewChanged?.call(
      VideoComposePreviewConfig(
        primarySubtitlePath: _primaryPath,
        secondarySubtitlePath: _secondaryPath,
        renderSecondarySubtitle: _secondaryPath != null &&
            _secondaryPath!.isNotEmpty,
        continuousSubtitle: _continuousSubtitle,
        splitSubtitleByLine: Provider.of<SettingsService>(
          context,
          listen: false,
        ).splitSubtitleByLine,
        burnSubtitles: !_softSubtitleOnly,
      ),
    );
  }

  Future<void> _loadSourceResolution() async {
    final manager = Provider.of<VideoComposeManager>(context, listen: false);
    final source = await manager.getSourceResolutionLabel(
      widget.videoItem.path,
    );
    if (!mounted) return;
    setState(() {
      _sourceResolutionLabel = source;
    });
  }

  void _loadInitialFromSettings({bool applyState = true}) {
    final settings = Provider.of<SettingsService>(context, listen: false);
    final List<String> candidates = widget.availableSubtitleMap.keys.toList();
    String? selectedPrimary;
    String? selectedSecondary;

    final String? currentPrimary = widget.currentSelectedPaths.isNotEmpty
        ? widget.currentSelectedPaths.first
        : null;
    final String? currentSecondary = widget.currentSelectedPaths.length > 1
        ? widget.currentSelectedPaths[1]
        : null;

    // 跟随当前视频卡片/当前播放选择：优先当前播放器选中的主字幕，
    // 其次视频条目持久化的主字幕，最后回退到候选列表第一项。
    if (currentPrimary != null && candidates.contains(currentPrimary)) {
      selectedPrimary = currentPrimary;
    } else if (widget.videoItem.subtitlePath != null &&
        candidates.contains(widget.videoItem.subtitlePath)) {
      selectedPrimary = widget.videoItem.subtitlePath;
    } else if (candidates.isNotEmpty) {
      selectedPrimary = candidates.first;
    }

    // 副字幕跟随当前播放器选择，其次视频条目持久化的副字幕，
    // 都没有则保持"无"。
    if (currentSecondary != null && candidates.contains(currentSecondary)) {
      selectedSecondary = currentSecondary;
    } else if (widget.videoItem.secondarySubtitlePath != null &&
        candidates.contains(widget.videoItem.secondarySubtitlePath)) {
      selectedSecondary = widget.videoItem.secondarySubtitlePath;
    }

    void assignState() {
      _primaryPath = selectedPrimary;
      _secondaryPath = selectedSecondary;
      _customOutputPath = _showCustomOutputDirectory
          ? settings.videoComposeCustomOutputPath
          : null;
      if (Platform.isAndroid &&
          (_customOutputPath == null || _customOutputPath!.isEmpty)) {
        _customOutputPath = '/storage/emulated/0/Download/ComposedVideos';
      }
      _resolution = _resolutionFromHeight(
        settings.videoComposeResolutionHeight,
      );
      _renderMode = VideoComposeRenderMode.fromStorage(
        settings.videoComposeRenderMode,
        fallback: VideoComposeRenderMode.precise,
      );
      _continuousSubtitle = settings.videoComposeContinuousSubtitle;
      _embedSoftSubtitles = settings.videoComposeEmbedSoftSubtitles;
      _softSubtitleOnly =
          settings.videoComposeSoftSubtitleOnly && _embedSoftSubtitles;
      _softSubtitleUseSourceQuality =
          settings.videoComposeSoftSubtitleUseSourceQuality;
      _deleteOutputOnTaskDelete = settings.videoComposeDeleteOutputOnTaskDelete;
    }

    if (applyState) {
      if (!mounted) return;
      setState(assignState);
      return;
    }
    assignState();
  }

  VideoComposeResolution _resolutionFromHeight(int value) {
    return switch (value) {
      360 => VideoComposeResolution.p360,
      480 => VideoComposeResolution.p480,
      720 => VideoComposeResolution.p720,
      1080 => VideoComposeResolution.p1080,
      1440 => VideoComposeResolution.p1440,
      2160 => VideoComposeResolution.p2160,
      _ => VideoComposeResolution.source,
    };
  }

  int _heightFromResolution(VideoComposeResolution value) {
    return switch (value) {
      VideoComposeResolution.source => 0,
      VideoComposeResolution.p360 => 360,
      VideoComposeResolution.p480 => 480,
      VideoComposeResolution.p720 => 720,
      VideoComposeResolution.p1080 => 1080,
      VideoComposeResolution.p1440 => 1440,
      VideoComposeResolution.p2160 => 2160,
    };
  }

  Future<void> _enqueueCompose() async {
    final manager = Provider.of<VideoComposeManager>(context, listen: false);
    final settings = Provider.of<SettingsService>(context, listen: false);
    final bool softOnly = _softSubtitleOnly;
    final bool embedSoftSubtitles = _embedSoftSubtitles || softOnly;
    final List<VideoComposeSoftSubtitleTrack> softTracks = embedSoftSubtitles
        ? widget.availableSubtitleMap.entries
              .where((e) => e.key.trim().isNotEmpty)
              .map(
                (e) => VideoComposeSoftSubtitleTrack(
                  path: e.key,
                  title: e.value.trim().isEmpty ? '字幕' : e.value.trim(),
                ),
              )
              .toList()
        : const <VideoComposeSoftSubtitleTrack>[];
    String? primary = _primaryPath;
    String? secondary = (_secondaryPath != null && _secondaryPath!.isNotEmpty)
        ? _secondaryPath
        : null;
    if (!softOnly) {
      if ((primary == null || primary.isEmpty) &&
          (secondary == null || secondary.isEmpty)) {
        if (mounted) {
          AppToast.show('请先选择至少一个字幕', type: AppToastType.error);
        }
        return;
      }
      if ((primary == null || primary.isEmpty) &&
          secondary != null &&
          secondary.isNotEmpty) {
        primary = secondary;
        secondary = null;
      }
    }
    String? effectiveOutputPath = _showCustomOutputDirectory
        ? _customOutputPath?.trim()
        : null;
    if (effectiveOutputPath != null && effectiveOutputPath.isEmpty) {
      effectiveOutputPath = null;
    }
    if (Platform.isAndroid && effectiveOutputPath == null) {
      effectiveOutputPath = '/storage/emulated/0/Download/ComposedVideos';
      _customOutputPath = effectiveOutputPath;
      settings.updateSetting(
        'videoComposeCustomOutputPath',
        effectiveOutputPath,
      );
    }
    if (Platform.isAndroid &&
        effectiveOutputPath != null &&
        effectiveOutputPath.startsWith('/storage/emulated/0/')) {
      final granted = await _ensureAndroidExternalStoragePermission(
        requestFromUser: true,
      );
      if (!granted) return;
    }
    if (effectiveOutputPath != null) {
      try {
        final dir = Directory(effectiveOutputPath);
        if (!await dir.exists()) {
          await dir.create(recursive: true);
        }
      } catch (_) {
        if (mounted) {
          AppToast.show('输出目录不可用，请重新选择', type: AppToastType.error);
        }
        return;
      }
    }
    final SubtitleStyle landscapeStyle =
        widget.videoItem.type == MediaType.audio
        ? settings.audioSubtitleStyleLandscape
        : settings.subtitleStyleLandscape;
    final SubtitleStyle portraitStyle = widget.videoItem.type == MediaType.audio
        ? settings.audioSubtitleStylePortrait
        : settings.subtitleStylePortrait;
    await manager.enqueue(
      videoId: widget.videoItem.id,
      videoPath: widget.videoItem.path,
      title: widget.videoItem.title,
      primarySubtitlePath: primary,
      secondarySubtitlePath: secondary,
      renderSecondarySubtitle: secondary != null,
      continuousSubtitle: _continuousSubtitle,
      embedSoftSubtitles: embedSoftSubtitles,
      softSubtitleOnly: softOnly,
      softSubtitleUseSourceQuality: _softSubtitleUseSourceQuality,
      softSubtitleTracks: softTracks,
      resolution: _resolution,
      renderMode: _renderMode,
      subtitleStyle: landscapeStyle,
      subtitleStylePortrait: portraitStyle,
      subtitleAlignment: settings.subtitleAlignment,
      splitSubtitleByLine: settings.splitSubtitleByLine,
      customOutputPath: effectiveOutputPath,
    );
  }

  Future<bool> _ensureAndroidExternalStoragePermission({
    required bool requestFromUser,
  }) async {
    if (!Platform.isAndroid) return true;
    if (await Permission.manageExternalStorage.isGranted) return true;
    if (!requestFromUser) return false;
    await Permission.manageExternalStorage.request();
    if (await Permission.manageExternalStorage.isGranted) return true;
    if (!mounted) return false;
    await showDialog<void>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: const Color(0xFF2C2C2C),
          title: const Text('需要文件管理权限', style: TextStyle(color: Colors.white)),
          content: const Text(
            '要保存到 Download/ComposedVideos，请在系统设置中授予“管理所有文件”权限。',
            style: TextStyle(color: Colors.white70),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () async {
                Navigator.pop(ctx);
                await openAppSettings();
              },
              child: const Text('去设置'),
            ),
          ],
        );
      },
    );
    return await Permission.manageExternalStorage.isGranted;
  }

  void _showSoftSubtitleHelp() {
    showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          backgroundColor: const Color(0xFF2C2C2C),
          title: const Text('软字幕内嵌说明', style: TextStyle(color: Colors.white)),
          content: const Text(
            '开启“软字幕内嵌”后，合成完成的视频会额外内置当前选择的主字幕和副字幕轨道，播放器可切换或关闭字幕。\n\n开启“仅合成软字幕”后，将不再把字幕烧录到画面中，只保留可切换的内嵌字幕轨道。',
            style: TextStyle(color: Colors.white70),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('我知道了'),
            ),
          ],
        );
      },
    );
  }

  Duration get _fastTransitionDuration =>
      _animateVisibility ? const Duration(milliseconds: 140) : Duration.zero;

  void _openSubtitleManager() {
    final callback = widget.onOpenSubtitleManager;
    if (callback == null) {
      AppToast.show('字幕管理区暂不可用', type: AppToastType.info);
      return;
    }
    callback();
  }

  void _openQueueDialog() {
    showDialog<void>(
      context: context,
      builder: (ctx) {
        final size = MediaQuery.of(ctx).size;
        final screenW = size.width;
        final screenH = size.height;
        final shortSide = screenW < screenH ? screenW : screenH;
        final scale = (shortSide / 390).clamp(0.86, 1.22);
        final dialogWidth = (screenW * 0.9).clamp(320.0, 760.0);
        final maxDialogHeight = (screenH * 0.78).clamp(300.0, 780.0);
        final dialogPadding = (14.0 * scale).clamp(12.0, 20.0);
        final sectionGap = (10.0 * scale).clamp(8.0, 16.0);
        final titleSize = (18.0 * scale).clamp(15.0, 22.0);
        final subtitleSize = (13.0 * scale).clamp(11.0, 15.0);
        final timeSize = (11.0 * scale).clamp(9.0, 13.0);
        final iconSize = (19.0 * scale).clamp(16.0, 24.0);
        final actionButtonSize = (34.0 * scale).clamp(30.0, 42.0);
        final itemRadius = (12.0 * scale).clamp(10.0, 16.0);
        final listHeight = (maxDialogHeight - 96.0 * scale).clamp(180.0, 620.0);
        final emptyHeight = (120.0 * scale).clamp(92.0, 150.0);

        return Dialog(
          backgroundColor: const Color(0xFF1E1E1E),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14 * scale),
          ),
          insetPadding: EdgeInsets.symmetric(
            horizontal: (screenW * 0.05).clamp(12.0, 40.0),
            vertical: (screenH * 0.04).clamp(12.0, 36.0),
          ),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: dialogWidth,
              maxHeight: maxDialogHeight,
            ),
            child: Padding(
              padding: EdgeInsets.all(dialogPadding),
              child: Consumer<VideoComposeManager>(
                builder: (context, manager, child) {
                  final tasks = manager.allTasks;
                  final queuedCount = manager.queuedTasks.length;
                  final runningCount = manager.runningTask == null ? 0 : 1;
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Row(
                              children: [
                                Text(
                                  '视频合成队列',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: titleSize,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                SizedBox(width: (8.0 * scale).clamp(6.0, 12.0)),
                                Container(
                                  padding: EdgeInsets.symmetric(
                                    horizontal: (8.0 * scale).clamp(6.0, 10.0),
                                    vertical: (3.0 * scale).clamp(2.0, 5.0),
                                  ),
                                  decoration: BoxDecoration(
                                    color: Colors.white10,
                                    borderRadius: BorderRadius.circular(
                                      10 * scale,
                                    ),
                                  ),
                                  child: Text(
                                    '运行$runningCount · 排队$queuedCount',
                                    style: TextStyle(
                                      color: Colors.white70,
                                      fontSize: timeSize,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          SizedBox(
                            width: actionButtonSize,
                            height: actionButtonSize,
                            child: IconButton(
                              padding: EdgeInsets.zero,
                              iconSize: iconSize,
                              icon: const Icon(
                                Icons.close,
                                color: Colors.white,
                              ),
                              onPressed: () => Navigator.of(ctx).pop(),
                            ),
                          ),
                        ],
                      ),
                      SizedBox(height: sectionGap),
                      if (tasks.isEmpty)
                        Container(
                          width: double.infinity,
                          height: emptyHeight,
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.03),
                            borderRadius: BorderRadius.circular(itemRadius),
                            border: Border.all(color: Colors.white12),
                          ),
                          child: Center(
                            child: Text(
                              '当前没有合成任务',
                              style: TextStyle(
                                color: Colors.white70,
                                fontSize: subtitleSize,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        )
                      else
                        SizedBox(
                          height: listHeight,
                          child: ListView.separated(
                            itemCount: tasks.length,
                            separatorBuilder: (context, index) => SizedBox(
                              height: (8.0 * scale).clamp(6.0, 12.0),
                            ),
                            itemBuilder: (context, index) {
                              final task = tasks[index];
                              final isRunning =
                                  manager.runningTask?.taskId == task.taskId;
                              final isCompleted =
                                  task.stage == VideoComposeStage.completed;
                              final double progressValue = isCompleted
                                  ? 1.0
                                  : task.progress.clamp(0, 1).toDouble();
                              final stageColor =
                                  task.stage == VideoComposeStage.failed
                                  ? Colors.redAccent
                                  : (isRunning
                                        ? Colors.blueAccent
                                        : Colors.orangeAccent);
                              final stageText = task.message;
                              final errorText = task.error?.trim();
                              final hasErrorText =
                                  task.stage == VideoComposeStage.failed &&
                                  errorText != null &&
                                  errorText.isNotEmpty;
                              final hasOutputFile =
                                  isCompleted &&
                                  File(task.request.outputPath).existsSync();
                              return Container(
                                padding: EdgeInsets.all(
                                  (10.0 * scale).clamp(8.0, 14.0),
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.white.withValues(alpha: 0.04),
                                  borderRadius: BorderRadius.circular(
                                    itemRadius,
                                  ),
                                  border: Border.all(color: Colors.white12),
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Expanded(
                                          flex: 5,
                                          child: Text(
                                            task.request.title,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              color: Colors.white,
                                              fontWeight: FontWeight.w600,
                                              fontSize: subtitleSize + 1,
                                            ),
                                          ),
                                        ),
                                        SizedBox(
                                          width: (8.0 * scale).clamp(6.0, 12.0),
                                        ),
                                        Flexible(
                                          flex: 4,
                                          child: Container(
                                            padding: EdgeInsets.symmetric(
                                              horizontal: (7.0 * scale).clamp(
                                                6.0,
                                                10.0,
                                              ),
                                              vertical: (2.0 * scale).clamp(
                                                2.0,
                                                4.0,
                                              ),
                                            ),
                                            decoration: BoxDecoration(
                                              color: stageColor.withValues(
                                                alpha: 0.16,
                                              ),
                                              borderRadius:
                                                  BorderRadius.circular(
                                                    8 * scale,
                                                  ),
                                            ),
                                            child: Text(
                                              stageText,
                                              maxLines: 2,
                                              overflow: TextOverflow.ellipsis,
                                              softWrap: true,
                                              style: TextStyle(
                                                color: stageColor,
                                                fontSize: timeSize,
                                                fontWeight: FontWeight.w600,
                                              ),
                                            ),
                                          ),
                                        ),
                                        SizedBox(
                                          width: (6.0 * scale).clamp(4.0, 10.0),
                                        ),
                                        SizedBox(
                                          width: actionButtonSize,
                                          height: actionButtonSize,
                                          child: IconButton(
                                            iconSize: iconSize,
                                            padding: EdgeInsets.zero,
                                            tooltip: '删除记录与视频',
                                            icon: const Icon(
                                              Icons.delete_outline,
                                              color: Colors.redAccent,
                                            ),
                                            onPressed: () {
                                              bool shouldDeleteOutput =
                                                  _deleteOutputOnTaskDelete;
                                              final settingsService =
                                                  Provider.of<SettingsService>(
                                                    context,
                                                    listen: false,
                                                  );
                                              showDialog(
                                                context: context,
                                                builder: (dialogContext) => StatefulBuilder(
                                                  builder: (ctx, setDialogState) {
                                                    return AlertDialog(
                                                      backgroundColor:
                                                          const Color(
                                                            0xFF2C2C2C,
                                                          ),
                                                      title: const Text(
                                                        '确认删除',
                                                        style: TextStyle(
                                                          color: Colors.white,
                                                        ),
                                                      ),
                                                      content: Column(
                                                        mainAxisSize:
                                                            MainAxisSize.min,
                                                        crossAxisAlignment:
                                                            CrossAxisAlignment
                                                                .start,
                                                        children: [
                                                          const Text(
                                                            '确定要删除该合成记录吗？',
                                                            style: TextStyle(
                                                              color: Colors
                                                                  .white70,
                                                            ),
                                                          ),
                                                          SizedBox(
                                                            height:
                                                                (6.0 * scale)
                                                                    .clamp(
                                                                      4.0,
                                                                      10.0,
                                                                    ),
                                                          ),
                                                          CheckboxListTile(
                                                            value:
                                                                shouldDeleteOutput,
                                                            contentPadding:
                                                                EdgeInsets.zero,
                                                            controlAffinity:
                                                                ListTileControlAffinity
                                                                    .leading,
                                                            dense: true,
                                                            title: const Text(
                                                              '同时删除已合成的视频文件',
                                                              style: TextStyle(
                                                                color: Colors
                                                                    .white,
                                                              ),
                                                            ),
                                                            subtitle: const Text(
                                                              '仅删除该任务对应的输出文件',
                                                              style: TextStyle(
                                                                color: Colors
                                                                    .white54,
                                                                fontSize: 12,
                                                              ),
                                                            ),
                                                            onChanged: (v) async {
                                                              final value =
                                                                  v ?? true;
                                                              setDialogState(() {
                                                                shouldDeleteOutput =
                                                                    value;
                                                              });
                                                              if (_deleteOutputOnTaskDelete !=
                                                                  value) {
                                                                setState(() {
                                                                  _deleteOutputOnTaskDelete =
                                                                      value;
                                                                });
                                                                await settingsService
                                                                    .updateSetting(
                                                                      'videoComposeDeleteOutputOnTaskDelete',
                                                                      value,
                                                                    );
                                                              }
                                                            },
                                                          ),
                                                        ],
                                                      ),
                                                      actions: [
                                                        TextButton(
                                                          onPressed: () =>
                                                              Navigator.pop(
                                                                dialogContext,
                                                              ),
                                                          child: const Text(
                                                            '取消',
                                                            style: TextStyle(
                                                              color: Colors
                                                                  .white70,
                                                            ),
                                                          ),
                                                        ),
                                                        TextButton(
                                                          onPressed: () async {
                                                            if (shouldDeleteOutput &&
                                                                Platform
                                                                    .isAndroid &&
                                                                task
                                                                    .request
                                                                    .outputPath
                                                                    .startsWith(
                                                                      '/storage/emulated/0/',
                                                                    )) {
                                                              final granted =
                                                                  await _ensureAndroidExternalStoragePermission(
                                                                    requestFromUser:
                                                                        true,
                                                                  );
                                                              if (!granted) {
                                                                if (mounted) {
                                                                  AppToast.show(
                                                                    '没有存储权限，任务和视频均未删除',
                                                                    type: AppToastType
                                                                        .error,
                                                                  );
                                                                }
                                                                return;
                                                              }
                                                            }
                                                            final outputDeleted =
                                                                await manager.deleteTaskAndFile(
                                                                  task.taskId,
                                                                  deleteOutput:
                                                                      shouldDeleteOutput,
                                                                );
                                                            if (dialogContext
                                                                .mounted) {
                                                              Navigator.pop(
                                                                dialogContext,
                                                              );
                                                            }
                                                            if (shouldDeleteOutput &&
                                                                !outputDeleted &&
                                                                mounted) {
                                                              AppToast.show(
                                                                '视频文件删除失败，任务已保留；请关闭占用或授权后重试',
                                                                type:
                                                                    AppToastType
                                                                        .error,
                                                              );
                                                            }
                                                          },
                                                          child: const Text(
                                                            '删除',
                                                            style: TextStyle(
                                                              color: Colors
                                                                  .redAccent,
                                                            ),
                                                          ),
                                                        ),
                                                      ],
                                                    );
                                                  },
                                                ),
                                              );
                                            },
                                          ),
                                        ),
                                      ],
                                    ),
                                    Text(
                                      task.request.softSubtitleOnly
                                          ? '仅软字幕'
                                          : (task.request.renderMode ==
                                                    VideoComposeRenderMode
                                                        .precise
                                                ? '精确渲染 · 非幽灵字幕'
                                                : '粗略渲染 · ASS'),
                                      style: TextStyle(
                                        color: Colors.white54,
                                        fontSize: timeSize,
                                      ),
                                    ),
                                    SizedBox(
                                      height: (8.0 * scale).clamp(6.0, 10.0),
                                    ),
                                    Row(
                                      children: [
                                        Expanded(
                                          child: ClipRRect(
                                            borderRadius: BorderRadius.circular(
                                              4 * scale,
                                            ),
                                            child: LinearProgressIndicator(
                                              minHeight: (5.0 * scale).clamp(
                                                4.0,
                                                8.0,
                                              ),
                                              value: progressValue,
                                              backgroundColor: Colors.white10,
                                              valueColor:
                                                  AlwaysStoppedAnimation<Color>(
                                                    stageColor,
                                                  ),
                                            ),
                                          ),
                                        ),
                                        SizedBox(
                                          width: (10.0 * scale).clamp(
                                            8.0,
                                            14.0,
                                          ),
                                        ),
                                        Text(
                                          '${(progressValue * 100).toStringAsFixed(0)}%',
                                          style: TextStyle(
                                            color: Colors.white70,
                                            fontSize: subtitleSize,
                                            fontWeight: FontWeight.w500,
                                          ),
                                        ),
                                      ],
                                    ),
                                    if (hasErrorText) ...[
                                      SizedBox(
                                        height: (7.0 * scale).clamp(5.0, 10.0),
                                      ),
                                      Container(
                                        width: double.infinity,
                                        padding: EdgeInsets.symmetric(
                                          horizontal: (7.0 * scale).clamp(
                                            6.0,
                                            10.0,
                                          ),
                                          vertical: (4.0 * scale).clamp(
                                            3.0,
                                            6.0,
                                          ),
                                        ),
                                        decoration: BoxDecoration(
                                          color: Colors.redAccent.withValues(
                                            alpha: 0.12,
                                          ),
                                          borderRadius: BorderRadius.circular(
                                            6 * scale,
                                          ),
                                          border: Border.all(
                                            color: Colors.redAccent.withValues(
                                              alpha: 0.35,
                                            ),
                                          ),
                                        ),
                                        child: SingleChildScrollView(
                                          scrollDirection: Axis.horizontal,
                                          child: SelectableText(
                                            errorText,
                                            maxLines: 1,
                                            style: TextStyle(
                                              color: Colors.redAccent,
                                              fontSize: timeSize,
                                              fontWeight: FontWeight.w500,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ],
                                    if (task.completedAt != null) ...[
                                      SizedBox(
                                        height: (7.0 * scale).clamp(6.0, 10.0),
                                      ),
                                      Text(
                                        '完成时间: ${DateFormat('yyyy-MM-dd HH:mm:ss').format(task.completedAt!)}',
                                        style: TextStyle(
                                          color: Colors.white54,
                                          fontSize: timeSize,
                                        ),
                                      ),
                                    ],
                                    if (isCompleted ||
                                        task.stage ==
                                            VideoComposeStage.failed) ...[
                                      SizedBox(
                                        height: (6.0 * scale).clamp(4.0, 9.0),
                                      ),
                                      SelectableText(
                                        '输出位置：${task.request.outputPath}',
                                        maxLines: 2,
                                        style: TextStyle(
                                          color: Colors.white54,
                                          fontSize: timeSize,
                                        ),
                                      ),
                                    ],
                                    if (hasOutputFile) ...[
                                      SizedBox(
                                        height: (8.0 * scale).clamp(6.0, 12.0),
                                      ),
                                      Row(
                                        children: [
                                          SizedBox(
                                            height: actionButtonSize,
                                            child: OutlinedButton.icon(
                                              icon: Icon(
                                                Icons.play_circle_outline,
                                                size: iconSize - 1,
                                              ),
                                              label: Text(
                                                '预览',
                                                style: TextStyle(
                                                  fontSize: timeSize + 1,
                                                ),
                                              ),
                                              style: OutlinedButton.styleFrom(
                                                foregroundColor: Colors.white,
                                                side: const BorderSide(
                                                  color: Colors.white24,
                                                ),
                                                padding: EdgeInsets.symmetric(
                                                  horizontal: (10.0 * scale)
                                                      .clamp(8.0, 14.0),
                                                ),
                                                shape: RoundedRectangleBorder(
                                                  borderRadius:
                                                      BorderRadius.circular(
                                                        9 * scale,
                                                      ),
                                                ),
                                              ),
                                              onPressed: () {
                                                Navigator.push(
                                                  context,
                                                  MaterialPageRoute(
                                                    builder: (context) =>
                                                        SimpleVideoPlayerScreen(
                                                          videoPath: task
                                                              .request
                                                              .outputPath,
                                                          title: task
                                                              .request
                                                              .title,
                                                        ),
                                                  ),
                                                );
                                              },
                                            ),
                                          ),
                                          SizedBox(
                                            width: (8.0 * scale).clamp(
                                              6.0,
                                              12.0,
                                            ),
                                          ),
                                          SizedBox(
                                            height: actionButtonSize,
                                            child: OutlinedButton.icon(
                                              icon: Icon(
                                                Icons.open_in_new_outlined,
                                                size: iconSize - 1,
                                              ),
                                              label: Text(
                                                _openOutputLabel,
                                                style: TextStyle(
                                                  fontSize: timeSize + 1,
                                                ),
                                              ),
                                              style: OutlinedButton.styleFrom(
                                                foregroundColor: Colors.white,
                                                side: const BorderSide(
                                                  color: Colors.white24,
                                                ),
                                                padding: EdgeInsets.symmetric(
                                                  horizontal: (10.0 * scale)
                                                      .clamp(8.0, 14.0),
                                                ),
                                                shape: RoundedRectangleBorder(
                                                  borderRadius:
                                                      BorderRadius.circular(
                                                        9 * scale,
                                                      ),
                                                ),
                                              ),
                                              onPressed: () async {
                                                await _openOutput(
                                                  task.request.outputPath,
                                                );
                                              },
                                            ),
                                          ),
                                        ],
                                      ),
                                    ],
                                  ],
                                ),
                              );
                            },
                          ),
                        ),
                    ],
                  );
                },
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildTopActionButton({
    required VoidCallback? onPressed,
    required IconData icon,
    required String label,
    required double buttonHeight,
    required double textSize,
  }) {
    return OutlinedButton(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        minimumSize: Size.fromHeight(buttonHeight),
        padding: const EdgeInsets.symmetric(horizontal: 4),
        foregroundColor: Colors.white,
        side: const BorderSide(color: Colors.white30),
        textStyle: TextStyle(fontSize: textSize),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: textSize + 2),
          const SizedBox(width: 4),
          Flexible(
            child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
        ],
      ),
    );
  }

  Widget _buildCompactSwitchCard({
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
    required double textSize,
    required double smallSize,
    required double switchScale,
    Widget? child,
    bool showChild = false,
    bool embedChildInLeading = false,
  }) {
    final Widget? effectiveChild = child == null
        ? null
        : AnimatedSize(
            duration: _fastTransitionDuration,
            curve: Curves.easeOutCubic,
            child: showChild
                ? Padding(padding: const EdgeInsets.only(top: 6), child: child)
                : const SizedBox.shrink(),
          );
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: Colors.white24),
        borderRadius: BorderRadius.circular(8),
        color: Colors.white.withValues(alpha: 0.03),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      title,
                      style: TextStyle(color: Colors.white, fontSize: textSize),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: TextStyle(
                        color: Colors.white54,
                        fontSize: smallSize,
                      ),
                    ),
                    if (embedChildInLeading && effectiveChild != null)
                      effectiveChild,
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Transform.scale(
                scale: switchScale,
                alignment: Alignment.centerRight,
                child: Switch.adaptive(
                  value: value,
                  onChanged: onChanged,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
            ],
          ),
          if (!embedChildInLeading && effectiveChild != null) effectiveChild,
        ],
      ),
    );
  }

  String _resolutionLabel(VideoComposeResolution value) {
    return switch (value) {
      VideoComposeResolution.source =>
        _sourceResolutionLabel == null
            ? '原始分辨率'
            : '原始分辨率 (${_sourceResolutionLabel!})',
      VideoComposeResolution.p360 => '360P',
      VideoComposeResolution.p480 => '480P',
      VideoComposeResolution.p720 => '720P',
      VideoComposeResolution.p1080 => '1080P',
      VideoComposeResolution.p1440 => '1440P',
      VideoComposeResolution.p2160 => '2160P',
    };
  }

  String _stageText(VideoComposeStage stage, String message, String? error) {
    if (stage == VideoComposeStage.failed &&
        error != null &&
        error.trim().isNotEmpty) {
      return '$message: ${error.trim()}';
    }
    return message;
  }

  Future<String> _prepareExternalOpenPath(String sourcePath) async {
    if (!Platform.isAndroid) return sourcePath;
    final sourceFile = File(sourcePath);
    if (!await sourceFile.exists()) return sourcePath;

    Directory? publicBase;
    final publicDownload = Directory('/storage/emulated/0/Download');
    if (await publicDownload.exists()) {
      publicBase = publicDownload;
    } else {
      final fallback = await getDownloadsDirectory();
      if (fallback != null) {
        publicBase = fallback;
      }
    }
    if (publicBase == null) return sourcePath;

    final targetDir = Directory(p.join(publicBase.path, 'ComposedVideos'));
    if (!await targetDir.exists()) {
      await targetDir.create(recursive: true);
    }
    final fileName = p.basename(sourcePath);
    var targetPath = p.join(targetDir.path, fileName);
    if (p.normalize(targetPath) == p.normalize(sourcePath)) return sourcePath;

    final targetFile = File(targetPath);
    if (await targetFile.exists()) {
      final srcStat = await sourceFile.stat();
      final dstStat = await targetFile.stat();
      if (srcStat.size == dstStat.size) {
        return targetPath;
      }
      final base = p.basenameWithoutExtension(fileName);
      final ext = p.extension(fileName);
      targetPath = p.join(
        targetDir.path,
        '${base}_${DateTime.now().millisecondsSinceEpoch}$ext',
      );
    }
    await sourceFile.copy(targetPath);
    return targetPath;
  }

  Future<void> _openOutput(String path) async {
    final file = File(path);
    if (!file.existsSync()) {
      if (!mounted) return;
      AppToast.show('文件不存在，无法打开', type: AppToastType.error);
      return;
    }
    if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
      try {
        final ProcessResult result;
        if (Platform.isWindows) {
          result = await Process.run('explorer.exe', <String>[
            '/select,',
            path,
          ]);
        } else if (Platform.isMacOS) {
          result = await Process.run('open', <String>['-R', path]);
        } else {
          result = await Process.run('xdg-open', <String>[p.dirname(path)]);
        }
        if (result.exitCode == 0) return;
      } catch (_) {
        // Fall through to the platform's default file opener.
      }
    }
    String openPath = path;
    try {
      openPath = await _prepareExternalOpenPath(path);
    } catch (_) {}
    var result = await OpenFilex.open(openPath);
    if (result.type != ResultType.done && openPath != path) {
      result = await OpenFilex.open(path);
    }
    if (!mounted) return;
    if (result.type != ResultType.done) {
      AppToast.show('无法打开输出文件', type: AppToastType.error);
    }
  }

  Widget _buildComposeProgressCard({
    required VideoComposeTaskState task,
    required bool isRunningCurrent,
    required double spacing,
    required double textSize,
    required double smallSize,
  }) {
    final double progress = task.stage == VideoComposeStage.completed
        ? 1
        : task.progress.clamp(0, 1).toDouble();
    final Color progressColor = task.stage == VideoComposeStage.failed
        ? Colors.redAccent
        : (task.stage == VideoComposeStage.completed
              ? const Color(0xFF58D68D)
              : (isRunningCurrent
                    ? const Color(0xFF5B9CFF)
                    : const Color(0xFFFFB55B)));
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: (spacing * 1.6).clamp(10.0, 14.0),
        vertical: (spacing * 1.15).clamp(8.0, 12.0),
      ),
      decoration: BoxDecoration(
        color: const Color(0xFF252930),
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: progressColor.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                task.stage == VideoComposeStage.completed
                    ? Icons.check_circle_outline_rounded
                    : (task.stage == VideoComposeStage.failed
                          ? Icons.error_outline_rounded
                          : Icons.movie_filter_outlined),
                size: textSize + 4,
                color: progressColor,
              ),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  _stageText(task.stage, task.message, task.error),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.white70,
                    fontSize: smallSize,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '${(progress * 100).round()}%',
                style: TextStyle(
                  color: progressColor,
                  fontSize: smallSize,
                  fontWeight: FontWeight.w700,
                  fontFeatures: const <FontFeature>[
                    FontFeature.tabularFigures(),
                  ],
                ),
              ),
            ],
          ),
          SizedBox(height: (spacing * 0.85).clamp(5.0, 8.0)),
          TweenAnimationBuilder<double>(
            tween: Tween<double>(end: progress),
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            builder: (context, value, child) {
              return ClipRRect(
                borderRadius: BorderRadius.circular(99),
                child: LinearProgressIndicator(
                  value: value,
                  minHeight: 6,
                  backgroundColor: Colors.black26,
                  valueColor: AlwaysStoppedAnimation<Color>(progressColor),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final screenH = MediaQuery.of(context).size.height;
    return LayoutBuilder(
      builder: (context, constraints) {
        final h = constraints.maxHeight.isInfinite
            ? screenH
            : constraints.maxHeight;
        final w = constraints.maxWidth;

        final pad = (h * 0.012).clamp(6.0, 10.0);
        final titleSize = (h * 0.018).clamp(12.0, 15.0);
        final textSize = (h * 0.0158).clamp(10.0, 13.0);
        final smallSize = (h * 0.0135).clamp(9.0, 11.0);
        final buttonHeight = (h * 0.045).clamp(30.0, 38.0);
        final spacing = (h * 0.0075).clamp(3.0, 8.0);
        final topBarHeight = (h * 0.043).clamp(30.0, 36.0);
        final topIconSize = (h * 0.023).clamp(16.0, 21.0);
        final actionGap = (h * 0.007).clamp(4.0, 8.0);
        final formPairGap = (spacing * 1.5).clamp(8.0, 12.0);
        final useTwoColumnForm = w >= 360;
        final switchScale = (textSize / 13.0).clamp(0.68, 0.86);

        return Container(
          color: const Color(0xFF1E1E1E),
          padding: EdgeInsets.all(pad),
          child: Consumer2<VideoComposeManager, SettingsService>(
            builder: (context, manager, settings, child) {
              final latest = manager.latestTaskForVideo(widget.videoItem.id);
              final bool isRunningCurrent =
                  manager.runningTask?.request.videoId == widget.videoItem.id;
              return SingleChildScrollView(
                padding: EdgeInsets.only(
                  bottom: MediaQuery.viewPaddingOf(context).bottom + spacing,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(
                      height: topBarHeight,
                      child: Row(
                        children: [
                          SizedBox(
                            width: topBarHeight,
                            height: topBarHeight,
                            child: IconButton(
                              padding: EdgeInsets.zero,
                              onPressed: widget.onBack,
                              iconSize: topIconSize,
                              icon: const Icon(
                                Icons.arrow_back,
                                color: Colors.white,
                              ),
                              tooltip: '返回',
                            ),
                          ),
                          SizedBox(width: spacing),
                          Expanded(
                            child: Text(
                              '视频合成',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: titleSize,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          SizedBox(
                            height: topBarHeight - 2,
                            child: OutlinedButton.icon(
                              onPressed: _openQueueDialog,
                              icon: Icon(
                                Icons.queue_play_next,
                                size: topIconSize - 1,
                              ),
                              label: Text(
                                '队列',
                                style: TextStyle(fontSize: smallSize),
                              ),
                              style: OutlinedButton.styleFrom(
                                padding: EdgeInsets.symmetric(
                                  horizontal: (pad * 0.85).clamp(6.0, 10.0),
                                ),
                                foregroundColor: Colors.white70,
                                side: const BorderSide(color: Colors.white30),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(8),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    SizedBox(height: spacing),
                    Text(
                      widget.videoItem.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white70,
                        fontSize: textSize,
                      ),
                    ),
                    if (!_softSubtitleOnly) ...[
                      SizedBox(height: spacing),
                      _ComposeSelect<VideoComposeRenderMode>(
                        key: const ValueKey('compose_render_mode_dropdown'),
                        value: _renderMode,
                        label: '字幕烧录方式',
                        fontSize: textSize,
                        items: VideoComposeRenderMode.values
                            .map(
                              (mode) => _ComposeSelectItem(
                                value: mode,
                                label: mode == VideoComposeRenderMode.precise
                                    ? '精确渲染（推荐）'
                                    : '粗略渲染',
                              ),
                            )
                            .toList(),
                        onChanged: (mode) {
                          setState(() => _renderMode = mode);
                          settings.updateSetting(
                            'videoComposeRenderMode',
                            mode.storageValue,
                          );
                        },
                      ),
                      SizedBox(height: spacing * 0.5),
                      if (useTwoColumnForm)
                        IntrinsicHeight(
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Expanded(
                                child: AnimatedSwitcher(
                                  duration: _fastTransitionDuration,
                                  switchInCurve: Curves.easeOutCubic,
                                  switchOutCurve: Curves.easeInCubic,
                                  child:
                                      !(_softSubtitleOnly &&
                                          _softSubtitleUseSourceQuality)
                                      ? _ComposeSelect<VideoComposeResolution>(
                                          key: const ValueKey(
                                            'resolution_dropdown',
                                          ),
                                          value: _resolution,
                                          label: _sourceResolutionLabel == null
                                              ? '视频分辨率'
                                              : '视频分辨率（原始: $_sourceResolutionLabel）',
                                          fontSize: textSize,
                                          items: VideoComposeResolution.values
                                              .map(
                                                (e) => _ComposeSelectItem(
                                                  value: e,
                                                  label: _resolutionLabel(e),
                                                ),
                                              )
                                              .toList(),
                                          onChanged: (v) {
                                            setState(() => _resolution = v);
                                            settings.updateSetting(
                                              'videoComposeResolutionHeight',
                                              _heightFromResolution(v),
                                            );
                                          },
                                        )
                                      : const SizedBox.shrink(),
                                ),
                              ),
                              SizedBox(width: formPairGap),
                              Expanded(
                                child: _buildCompactSwitchCard(
                                  title: '字幕连续显示',
                                  subtitle: '按播放逻辑延长至下一条',
                                  value: _continuousSubtitle,
                                  onChanged: (v) {
                                    setState(() => _continuousSubtitle = v);
                                    settings.updateSetting(
                                      'videoComposeContinuousSubtitle',
                                      v,
                                    );
                                    _notifyPreviewChanged();
                                  },
                                  textSize: textSize,
                                  smallSize: smallSize,
                                  switchScale: switchScale,
                                ),
                              ),
                            ],
                          ),
                        )
                      else ...[
                        AnimatedSwitcher(
                          duration: _fastTransitionDuration,
                          switchInCurve: Curves.easeOutCubic,
                          switchOutCurve: Curves.easeInCubic,
                          child:
                              !(_softSubtitleOnly &&
                                  _softSubtitleUseSourceQuality)
                              ? _ComposeSelect<VideoComposeResolution>(
                                  key: const ValueKey('resolution_dropdown'),
                                  value: _resolution,
                                  label: _sourceResolutionLabel == null
                                      ? '视频分辨率'
                                      : '视频分辨率（原始: $_sourceResolutionLabel）',
                                  fontSize: textSize,
                                  items: VideoComposeResolution.values
                                      .map(
                                        (e) => _ComposeSelectItem(
                                          value: e,
                                          label: _resolutionLabel(e),
                                        ),
                                      )
                                      .toList(),
                                  onChanged: (v) {
                                    setState(() => _resolution = v);
                                    settings.updateSetting(
                                      'videoComposeResolutionHeight',
                                      _heightFromResolution(v),
                                    );
                                  },
                                )
                              : const SizedBox.shrink(),
                        ),
                        SizedBox(height: spacing * 0.5),
                        _buildCompactSwitchCard(
                          title: '字幕连续显示',
                          subtitle: '按播放逻辑延长至下一条',
                          value: _continuousSubtitle,
                          onChanged: (v) {
                            setState(() => _continuousSubtitle = v);
                            settings.updateSetting(
                              'videoComposeContinuousSubtitle',
                              v,
                            );
                            _notifyPreviewChanged();
                          },
                          textSize: textSize,
                          smallSize: smallSize,
                          switchScale: switchScale,
                        ),
                      ],
                      SizedBox(height: spacing * 0.5),
                      if (useTwoColumnForm)
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: _ComposeSelect<String>(
                                value: _primaryPath,
                                label: '主字幕渲染',
                                fontSize: textSize,
                                items: widget.availableSubtitleMap.entries
                                    .map(
                                      (e) => _ComposeSelectItem(
                                        value: e.key,
                                        label: e.value,
                                      ),
                                    )
                                    .toList(),
                                onChanged: (v) {
                                  setState(() => _primaryPath = v);
                                  settings.updateSetting(
                                    'videoComposePrimarySubtitlePath',
                                    v,
                                  );
                                  _notifyPreviewChanged();
                                },
                              ),
                            ),
                            SizedBox(width: formPairGap),
                            Expanded(
                              child: _ComposeSelect<String>(
                                key: const ValueKey('secondary_dropdown'),
                                value: _secondaryPath ?? '',
                                label: '副字幕渲染',
                                fontSize: textSize,
                                items: <_ComposeSelectItem<String>>[
                                  const _ComposeSelectItem<String>(
                                    value: '',
                                    label: '无',
                                  ),
                                  ...widget.availableSubtitleMap.entries.map(
                                    (e) => _ComposeSelectItem(
                                      value: e.key,
                                      label: e.value,
                                    ),
                                  ),
                                ],
                                onChanged: (v) {
                                  setState(() {
                                    _secondaryPath = v.isEmpty ? null : v;
                                  });
                                  settings.updateSetting(
                                    'videoComposeSecondarySubtitlePath',
                                    v,
                                  );
                                  _notifyPreviewChanged();
                                },
                              ),
                            ),
                          ],
                        )
                      else ...[
                        _ComposeSelect<String>(
                          value: _primaryPath,
                          label: '主字幕渲染',
                          fontSize: textSize,
                          items: widget.availableSubtitleMap.entries
                              .map(
                                (e) => _ComposeSelectItem(
                                  value: e.key,
                                  label: e.value,
                                ),
                              )
                              .toList(),
                          onChanged: (v) {
                            setState(() => _primaryPath = v);
                            settings.updateSetting(
                              'videoComposePrimarySubtitlePath',
                              v,
                            );
                            _notifyPreviewChanged();
                          },
                        ),
                        SizedBox(height: spacing * 0.5),
                        _ComposeSelect<String>(
                          key: const ValueKey('secondary_dropdown'),
                          value: _secondaryPath ?? '',
                          label: '副字幕渲染',
                          fontSize: textSize,
                          items: <_ComposeSelectItem<String>>[
                            const _ComposeSelectItem<String>(
                              value: '',
                              label: '无',
                            ),
                            ...widget.availableSubtitleMap.entries.map(
                              (e) => _ComposeSelectItem(
                                value: e.key,
                                label: e.value,
                              ),
                            ),
                          ],
                          onChanged: (v) {
                            setState(() {
                              _secondaryPath = v.isEmpty ? null : v;
                            });
                            settings.updateSetting(
                              'videoComposeSecondarySubtitlePath',
                              v,
                            );
                            _notifyPreviewChanged();
                          },
                        ),
                      ],
                    ],
                    if (_softSubtitleOnly) ...[
                      SizedBox(height: spacing),
                      AnimatedSwitcher(
                        duration: _fastTransitionDuration,
                        switchInCurve: Curves.easeOutCubic,
                        switchOutCurve: Curves.easeInCubic,
                        child:
                            !(_softSubtitleOnly &&
                                _softSubtitleUseSourceQuality)
                            ? _ComposeSelect<VideoComposeResolution>(
                                key: const ValueKey('resolution_dropdown'),
                                value: _resolution,
                                label: _sourceResolutionLabel == null
                                    ? '视频分辨率'
                                    : '视频分辨率（原始: $_sourceResolutionLabel）',
                                fontSize: textSize,
                                items: VideoComposeResolution.values
                                    .map(
                                      (e) => _ComposeSelectItem(
                                        value: e,
                                        label: _resolutionLabel(e),
                                      ),
                                    )
                                    .toList(),
                                onChanged: (v) {
                                  setState(() => _resolution = v);
                                  settings.updateSetting(
                                    'videoComposeResolutionHeight',
                                    _heightFromResolution(v),
                                  );
                                },
                              )
                            : const SizedBox.shrink(),
                      ),
                    ],
                    SizedBox(height: spacing * 0.5),
                    Container(
                      decoration: BoxDecoration(
                        border: Border.all(color: Colors.white24),
                        borderRadius: BorderRadius.circular(8),
                        color: Colors.white.withValues(alpha: 0.03),
                      ),
                      padding: EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: spacing * 0.2,
                      ),
                      child: Column(
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Padding(
                                  padding: EdgeInsets.only(
                                    right: actionGap * 0.5,
                                  ),
                                  child: Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              '软字幕内嵌',
                                              style: TextStyle(
                                                color: Colors.white,
                                                fontSize: textSize,
                                              ),
                                            ),
                                            const SizedBox(height: 2),
                                            Text(
                                              '合成后额外内嵌主/副字幕轨道',
                                              style: TextStyle(
                                                color: Colors.white54,
                                                fontSize: smallSize,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      Transform.scale(
                                        scale: switchScale,
                                        alignment: Alignment.centerRight,
                                        child: Switch.adaptive(
                                          value: _embedSoftSubtitles,
                                          onChanged: (v) {
                                            setState(() {
                                              _embedSoftSubtitles = v;
                                              if (!v) {
                                                _softSubtitleOnly = false;
                                              }
                                            });
                                            settings.updateSetting(
                                              'videoComposeEmbedSoftSubtitles',
                                              v,
                                            );
                                            if (!v) {
                                              settings.updateSetting(
                                                'videoComposeSoftSubtitleOnly',
                                                false,
                                              );
                                            }
                                            _notifyPreviewChanged();
                                          },
                                          materialTapTargetSize:
                                              MaterialTapTargetSize.shrinkWrap,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              Text(
                                '字幕 ${widget.availableSubtitleMap.length}',
                                style: TextStyle(
                                  color: Colors.white70,
                                  fontSize: smallSize,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              SizedBox(width: actionGap),
                              OutlinedButton.icon(
                                onPressed: _openSubtitleManager,
                                style: OutlinedButton.styleFrom(
                                  minimumSize: Size(
                                    0,
                                    (buttonHeight * 0.82).clamp(28.0, 34.0),
                                  ),
                                  padding: EdgeInsets.symmetric(
                                    horizontal: (pad * 0.6).clamp(5.0, 8.0),
                                  ),
                                  foregroundColor: Colors.white70,
                                  side: const BorderSide(color: Colors.white24),
                                  textStyle: TextStyle(fontSize: smallSize),
                                ),
                                icon: Icon(
                                  Icons.subtitles_outlined,
                                  size: smallSize + 4,
                                ),
                                label: const Text('管理'),
                              ),
                            ],
                          ),
                          CheckboxListTile(
                            contentPadding: EdgeInsets.zero,
                            visualDensity: const VisualDensity(
                              horizontal: 0,
                              vertical: -4,
                            ),
                            dense: true,
                            value: _softSubtitleOnly,
                            title: Text(
                              '仅合成软字幕',
                              style: TextStyle(
                                color: _embedSoftSubtitles
                                    ? Colors.white
                                    : Colors.white54,
                                fontSize: textSize,
                              ),
                            ),
                            subtitle: Text(
                              '不烧录到画面，仅保留内嵌字幕轨道',
                              style: TextStyle(
                                color: Colors.white54,
                                fontSize: smallSize,
                              ),
                            ),
                            onChanged: _embedSoftSubtitles
                                ? (v) {
                                    final value = v ?? false;
                                    setState(() => _softSubtitleOnly = value);
                                    settings.updateSetting(
                                      'videoComposeSoftSubtitleOnly',
                                      value,
                                    );
                                    _notifyPreviewChanged();
                                  }
                                : null,
                          ),
                          AnimatedSwitcher(
                            duration: _fastTransitionDuration,
                            switchInCurve: Curves.easeOutCubic,
                            switchOutCurve: Curves.easeInCubic,
                            child: _softSubtitleOnly
                                ? CheckboxListTile(
                                    key: const ValueKey(
                                      'source_quality_checkbox',
                                    ),
                                    contentPadding: EdgeInsets.zero,
                                    visualDensity: const VisualDensity(
                                      horizontal: 0,
                                      vertical: -4,
                                    ),
                                    dense: true,
                                    value: _softSubtitleUseSourceQuality,
                                    title: Text(
                                      '采用视频原画质',
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontSize: textSize,
                                      ),
                                    ),
                                    subtitle: Text(
                                      '仅封装字幕轨道，不重编码视频',
                                      style: TextStyle(
                                        color: Colors.white54,
                                        fontSize: smallSize,
                                      ),
                                    ),
                                    onChanged: (v) {
                                      final value = v ?? true;
                                      setState(
                                        () => _softSubtitleUseSourceQuality =
                                            value,
                                      );
                                      settings.updateSetting(
                                        'videoComposeSoftSubtitleUseSourceQuality',
                                        value,
                                      );
                                    },
                                  )
                                : const SizedBox.shrink(),
                          ),
                        ],
                      ),
                    ),
                    SizedBox(height: spacing),
                    if (_showCustomOutputDirectory) ...[
                      Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '自定义输出目录',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: textSize,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  _customOutputPath ??
                                      _defaultOutputDirectoryLabel,
                                  style: TextStyle(
                                    color: Colors.white54,
                                    fontSize: smallSize,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(),
                            icon: const Icon(
                              Icons.folder_open,
                              color: Colors.blueAccent,
                            ),
                            onPressed: () async {
                              if (Platform.isAndroid) {
                                final granted =
                                    await _ensureAndroidExternalStoragePermission(
                                      requestFromUser: true,
                                    );
                                if (!granted) return;
                              }
                              String? selectedDirectory = await FilePicker
                                  .platform
                                  .getDirectoryPath(dialogTitle: '选择保存目录');
                              if (selectedDirectory != null) {
                                setState(() {
                                  _customOutputPath = selectedDirectory;
                                });
                                settings.updateSetting(
                                  'videoComposeCustomOutputPath',
                                  selectedDirectory,
                                );
                              }
                            },
                          ),
                          if (Platform.isAndroid)
                            IconButton(
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(),
                              icon: const Icon(
                                Icons.security_outlined,
                                color: Colors.orangeAccent,
                              ),
                              onPressed: () async {
                                await _ensureAndroidExternalStoragePermission(
                                  requestFromUser: true,
                                );
                              },
                            ),
                        ],
                      ),
                      if (Platform.isAndroid) ...[
                        SizedBox(height: spacing * 0.4),
                        Text(
                          '默认输出目录: /storage/emulated/0/Download/ComposedVideos',
                          style: TextStyle(
                            color: Colors.greenAccent,
                            fontSize: smallSize,
                          ),
                        ),
                      ],
                      SizedBox(height: spacing * 1.5),
                    ] else
                      SizedBox(height: spacing * 0.5),
                    Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(10),
                        color: Colors.white.withValues(alpha: 0.035),
                        border: Border.all(color: Colors.white24),
                      ),
                      padding: EdgeInsets.all((pad * 0.45).clamp(4.0, 8.0)),
                      child: Row(
                        children: [
                          Expanded(
                            child: _buildTopActionButton(
                              onPressed: _openSubtitleManager,
                              icon: Icons.subtitles,
                              label: '字幕管理',
                              buttonHeight: buttonHeight,
                              textSize: textSize,
                            ),
                          ),
                          SizedBox(width: actionGap * 0.8),
                          Expanded(
                            child: _buildTopActionButton(
                              onPressed: _showSoftSubtitleHelp,
                              icon: Icons.info_outline,
                              label: '软字幕说明',
                              buttonHeight: buttonHeight,
                              textSize: textSize,
                            ),
                          ),
                          SizedBox(width: actionGap * 0.8),
                          Expanded(
                            child: _buildTopActionButton(
                              onPressed: _softSubtitleOnly
                                  ? null
                                  : widget.onOpenSubtitleStyle,
                              icon: Icons.style,
                              label: '字幕样式',
                              buttonHeight: buttonHeight,
                              textSize: textSize,
                            ),
                          ),
                          SizedBox(width: actionGap * 0.8),
                          Expanded(
                            child: _buildTopActionButton(
                              onPressed: _openQueueDialog,
                              icon: Icons.queue_play_next,
                              label: '查看队列',
                              buttonHeight: buttonHeight,
                              textSize: textSize,
                            ),
                          ),
                        ],
                      ),
                    ),
                    SizedBox(height: spacing),
                    if (latest != null) ...[
                      _buildComposeProgressCard(
                        task: latest,
                        isRunningCurrent: isRunningCurrent,
                        spacing: spacing,
                        textSize: textSize,
                        smallSize: smallSize,
                      ),
                      SizedBox(height: spacing),
                    ],
                    ElevatedButton.icon(
                      onPressed: _enqueueCompose,
                      style: ElevatedButton.styleFrom(
                        minimumSize: Size.fromHeight(buttonHeight),
                        padding: EdgeInsets.zero,
                        backgroundColor: Colors.blueAccent,
                        foregroundColor: Colors.white,
                        textStyle: TextStyle(
                          fontSize: textSize,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      icon: Icon(
                        Icons.movie_creation_outlined,
                        size: textSize + 4,
                      ),
                      label: const Text('加入合成队列'),
                    ),
                    SizedBox(height: spacing),
                    if (latest != null) ...[
                      if (latest.stage == VideoComposeStage.completed ||
                          latest.stage == VideoComposeStage.failed)
                        SelectableText(
                          latest.stage == VideoComposeStage.completed
                              ? '输出位置：${latest.request.outputPath}'
                              : '失败任务的输出位置：${latest.request.outputPath}',
                          style: TextStyle(
                            color: Colors.white54,
                            fontSize: smallSize,
                          ),
                        ),
                      if (latest.stage == VideoComposeStage.completed &&
                          File(latest.request.outputPath).existsSync()) ...[
                        SizedBox(height: spacing * 0.6),
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                _savedOutputHint,
                                style: TextStyle(
                                  color: Colors.greenAccent,
                                  fontSize: smallSize,
                                ),
                              ),
                            ),
                            IconButton(
                              icon: const Icon(
                                Icons.play_circle_outline,
                                color: Colors.white,
                              ),
                              tooltip: '预览',
                              iconSize: 28,
                              onPressed: () {
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (context) =>
                                        SimpleVideoPlayerScreen(
                                          videoPath: latest.request.outputPath,
                                          title: latest.request.title,
                                        ),
                                  ),
                                );
                              },
                            ),
                            IconButton(
                              icon: const Icon(
                                Icons.open_in_new_outlined,
                                color: Colors.white,
                              ),
                              tooltip: _openOutputLabel,
                              iconSize: 28,
                              onPressed: () async {
                                await _openOutput(latest.request.outputPath);
                              },
                            ),
                          ],
                        ),
                      ],
                    ],
                  ],
                ),
              );
            },
          ),
        );
      },
    );
  }
}
