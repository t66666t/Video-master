import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/danmaku_style.dart';
import '../models/video_item.dart';
import '../services/bilibili/bilibili_download_service.dart';
import '../services/library_service.dart';
import '../services/settings_service.dart';
import 'bilibili_login_dialogs.dart';

const _accent = Color(0xFFFF6699);

/// Phone landscape is height-starved; these metrics shrink chrome so every
/// control stays on one screen instead of relying on vertical scrolling.
@immutable
class _DanmakuDialogMetrics {
  const _DanmakuDialogMetrics({
    required this.compact,
    required this.extraCompact,
    required this.insetPadding,
    required this.contentPadding,
    required this.headerGap,
    required this.titleSize,
    required this.bodySize,
    required this.valueSize,
    required this.captionSize,
    required this.headerButtonIconSize,
    required this.headerButtonPadding,
    required this.sliderVerticalPadding,
    required this.sliderTrackHeight,
    required this.sliderThumbRadius,
    required this.sliderLabelWidth,
    required this.sliderValueWidth,
    required this.sliderPadding,
    required this.switchHeight,
    required this.twoColumn,
    required this.previewHeight,
    required this.previewFontSize,
    required this.sectionGap,
    required this.fieldVerticalPadding,
    required this.outlineRunSpacing,
    required this.outlineItemPadding,
  });

  factory _DanmakuDialogMetrics.fromSize(Size screen, EdgeInsets viewPadding) {
    // Typical phone landscape is ~360–400px tall; portrait phones stay roomy.
    final extraCompact = screen.height < 430;
    final compact = extraCompact || screen.height < 560;
    final landscapePhone =
        screen.width > screen.height && screen.shortestSide < 600;
    final verticalInset = extraCompact
        ? 6.0
        : compact
        ? 10.0
        : 24.0;
    final horizontalInset = screen.width < 600
        ? 12.0
        : compact
        ? 16.0
        : 20.0;

    return _DanmakuDialogMetrics(
      compact: compact,
      extraCompact: extraCompact,
      insetPadding: EdgeInsets.fromLTRB(
        horizontalInset + viewPadding.left,
        verticalInset + viewPadding.top,
        horizontalInset + viewPadding.right,
        verticalInset + viewPadding.bottom,
      ),
      contentPadding: extraCompact
          ? const EdgeInsets.fromLTRB(12, 6, 8, 8)
          : compact
          ? const EdgeInsets.fromLTRB(16, 8, 12, 12)
          : const EdgeInsets.fromLTRB(22, 14, 16, 20),
      headerGap: extraCompact ? 0 : (compact ? 2 : 4),
      titleSize: extraCompact ? 15 : (compact ? 16 : 18),
      bodySize: extraCompact ? 12.5 : (compact ? 13.5 : 15),
      valueSize: extraCompact ? 11.5 : (compact ? 12.5 : 14),
      captionSize: extraCompact ? 10 : 12,
      headerButtonIconSize: extraCompact ? 15 : 17,
      headerButtonPadding: extraCompact
          ? const EdgeInsets.symmetric(horizontal: 4, vertical: 2)
          : const EdgeInsets.symmetric(horizontal: 7, vertical: 7),
      sliderVerticalPadding: extraCompact ? 0 : (compact ? 2 : 5),
      sliderTrackHeight: extraCompact ? 3.5 : (compact ? 5 : 7),
      sliderThumbRadius: extraCompact ? 6 : (compact ? 7 : 8),
      sliderLabelWidth: extraCompact ? 58 : 72,
      sliderValueWidth: extraCompact ? 70 : 62,
      sliderPadding: extraCompact
          ? const EdgeInsets.symmetric(horizontal: 4, vertical: 1)
          : compact
          ? const EdgeInsets.symmetric(horizontal: 6, vertical: 2)
          : null,
      switchHeight: extraCompact ? 26 : (compact ? 32 : 40),
      twoColumn: (extraCompact || landscapePhone) && screen.width >= 560,
      previewHeight: extraCompact ? 48 : (compact ? 64 : 92),
      previewFontSize: extraCompact ? 18 : (compact ? 20 : 24),
      sectionGap: extraCompact ? 6 : (compact ? 10 : 20),
      fieldVerticalPadding: extraCompact ? 8 : 12,
      outlineRunSpacing: extraCompact ? 6 : 10,
      outlineItemPadding: extraCompact
          ? const EdgeInsets.symmetric(horizontal: 6, vertical: 5)
          : const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
    );
  }

  final bool compact;
  final bool extraCompact;
  final EdgeInsets insetPadding;
  final EdgeInsets contentPadding;
  final double headerGap;
  final double titleSize;
  final double bodySize;
  final double valueSize;
  final double captionSize;
  final double headerButtonIconSize;
  final EdgeInsets headerButtonPadding;
  final double sliderVerticalPadding;
  final double sliderTrackHeight;
  final double sliderThumbRadius;
  final double sliderLabelWidth;
  final double sliderValueWidth;
  final EdgeInsetsGeometry? sliderPadding;
  final double switchHeight;
  final bool twoColumn;
  final double previewHeight;
  final double previewFontSize;
  final double sectionGap;
  final double fieldVerticalPadding;
  final double outlineRunSpacing;
  final EdgeInsets outlineItemPadding;
}

class _DanmakuDialogScope extends InheritedWidget {
  const _DanmakuDialogScope({required this.metrics, required super.child});

  final _DanmakuDialogMetrics metrics;

  static _DanmakuDialogMetrics of(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<_DanmakuDialogScope>();
    assert(scope != null, 'Danmaku settings widgets need dialog metrics');
    return scope!.metrics;
  }

  @override
  bool updateShouldNotify(_DanmakuDialogScope oldWidget) =>
      metrics != oldWidget.metrics;
}

Future<void> showDanmakuSettingsDialog(
  BuildContext context, {
  VideoItem? videoItem,
  VoidCallback? onDanmakuUpdated,
}) {
  return showDialog<void>(
    context: context,
    barrierColor: Colors.black54,
    builder: (context) => _DanmakuSettingsDialog(
      videoItem: videoItem,
      onDanmakuUpdated: onDanmakuUpdated,
    ),
  );
}

class _DanmakuSettingsDialog extends StatefulWidget {
  final VideoItem? videoItem;
  final VoidCallback? onDanmakuUpdated;

  const _DanmakuSettingsDialog({this.videoItem, this.onDanmakuUpdated});

  @override
  State<_DanmakuSettingsDialog> createState() => _DanmakuSettingsDialogState();
}

class _DanmakuSettingsDialogState extends State<_DanmakuSettingsDialog> {
  bool _updating = false;
  String? _status;
  bool _statusIsError = false;

  Future<void> _updateDanmaku() async {
    if (_updating) return;
    final videoItem = widget.videoItem;
    if (videoItem == null) {
      setState(() {
        _status = '缺少B站视频信息';
        _statusIsError = true;
      });
      return;
    }
    setState(() {
      _updating = true;
      _status = '正在获取最新弹幕…';
      _statusIsError = false;
    });
    try {
      final service = context.read<BilibiliDownloadService>();
      final library = context.read<LibraryService>();
      await service.updateDanmakuForVideo(videoItem, library);
      if (!mounted) return;
      widget.onDanmakuUpdated?.call();
      setState(() {
        _updating = false;
        _status = '弹幕已更新';
      });
    } catch (error) {
      if (!mounted) return;
      final message = error is BilibiliDanmakuUpdateException
          ? error.message
          : '获取最新弹幕失败，请重试';
      setState(() {
        _updating = false;
        _status = message;
        _statusIsError = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsService>();
    final metrics = _DanmakuDialogMetrics.fromSize(
      MediaQuery.sizeOf(context),
      MediaQuery.paddingOf(context),
    );
    return _SettingsDialogFrame(
      title: '弹幕设置',
      maxWidth: metrics.twoColumn ? 640 : 460,
      metrics: metrics,
      headerAction: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextButton.icon(
            onPressed: () => showDialog<void>(
              context: context,
              barrierColor: Colors.black54,
              builder: (_) => const _DanmakuAdvancedSettingsDialog(),
            ),
            icon: Icon(Icons.tune_rounded, size: metrics.headerButtonIconSize),
            label: const Text('高级设置'),
            style: TextButton.styleFrom(
              foregroundColor: _accent,
              padding: metrics.headerButtonPadding,
              visualDensity: VisualDensity.compact,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
          TextButton.icon(
            onPressed: () => unawaited(showBilibiliLoginDialog(context)),
            icon: Icon(
              Icons.person_rounded,
              size: metrics.headerButtonIconSize,
            ),
            label: const Text('登录/Cookie'),
            style: TextButton.styleFrom(
              foregroundColor: _accent,
              padding: metrics.headerButtonPadding,
              visualDensity: VisualDensity.compact,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
        ],
      ),
      child: Flexible(
        child: SingleChildScrollView(
          key: const ValueKey('danmaku-settings-scroll'),
          child: metrics.twoColumn
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      flex: 3,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: _sliderControls(settings),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      flex: 2,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _SwitchRow(
                            label: '弹幕仅在视频区域内展示',
                            value: settings.bilibiliDanmakuOnlyInVideoArea,
                            onChanged: (value) => unawaited(
                              settings.saveBilibiliDanmakuOnlyInVideoArea(
                                value,
                              ),
                            ),
                          ),
                          _CheckboxRow(
                            label: '以锁定倍速为弹幕速度基准',
                            value: settings
                                .bilibiliDanmakuUseLockedSpeedAsBaseline,
                            onChanged: (value) => unawaited(
                              settings
                                  .saveBilibiliDanmakuUseLockedSpeedAsBaseline(
                                    value,
                                  ),
                            ),
                          ),
                          const SizedBox(height: 4),
                          const Divider(color: Colors.white12, height: 1),
                          const SizedBox(height: 6),
                          ..._updateControls(metrics),
                        ],
                      ),
                    ),
                  ],
                )
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _SwitchRow(
                      label: '弹幕仅在视频区域内展示',
                      value: settings.bilibiliDanmakuOnlyInVideoArea,
                      onChanged: (value) => unawaited(
                        settings.saveBilibiliDanmakuOnlyInVideoArea(value),
                      ),
                    ),
                    ..._sliderControls(settings),
                    _CheckboxRow(
                      label: '以锁定倍速为弹幕速度基准',
                      value: settings.bilibiliDanmakuUseLockedSpeedAsBaseline,
                      onChanged: (value) => unawaited(
                        settings.saveBilibiliDanmakuUseLockedSpeedAsBaseline(
                          value,
                        ),
                      ),
                    ),
                    SizedBox(height: metrics.extraCompact ? 4 : 8),
                    const Divider(color: Colors.white12, height: 1),
                    SizedBox(height: metrics.extraCompact ? 6 : 12),
                    ..._updateControls(metrics),
                  ],
                ),
        ),
      ),
    );
  }

  List<Widget> _sliderControls(SettingsService settings) {
    return [
      _SliderRow(
        label: '显示区域',
        valueText: '${(settings.bilibiliDanmakuDisplayArea * 100).round()}%',
        value: settings.bilibiliDanmakuDisplayArea,
        min: kDanmakuDisplayAreaMin,
        max: kDanmakuDisplayAreaMax,
        divisions: 99,
        onChanged: (value) =>
            unawaited(settings.saveBilibiliDanmakuDisplayArea(value)),
      ),
      _SliderRow(
        label: '不透明度',
        valueText: '${(settings.bilibiliDanmakuOpacity * 100).round()}%',
        value: settings.bilibiliDanmakuOpacity,
        min: 0.1,
        max: 1,
        divisions: 90,
        onChanged: (value) =>
            unawaited(settings.saveBilibiliDanmakuOpacity(value)),
      ),
      _SliderRow(
        label: '弹幕字号',
        valueText: '${(settings.bilibiliDanmakuFontScale * 100).round()}%',
        value: settings.bilibiliDanmakuFontScale,
        min: kDanmakuFontScaleMin,
        max: kDanmakuFontScaleMax,
        divisions: 190,
        onChanged: (value) =>
            unawaited(settings.saveBilibiliDanmakuFontScale(value)),
      ),
      _SliderRow(
        label: '弹幕速度',
        valueText: _speedLabel(settings.bilibiliDanmakuSpeed),
        value: danmakuSpeedToSlider(settings.bilibiliDanmakuSpeed),
        min: 0,
        max: 1,
        divisions: 200,
        onChanged: (value) => unawaited(
          settings.saveBilibiliDanmakuSpeed(danmakuSpeedFromSlider(value)),
        ),
      ),
    ];
  }

  List<Widget> _updateControls(_DanmakuDialogMetrics metrics) {
    return [
      Row(
        children: [
          Expanded(
            child: Text(
              '更新弹幕',
              style: TextStyle(
                color: Colors.white,
                fontSize: metrics.bodySize,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          FilledButton.icon(
            onPressed: _updating ? null : _updateDanmaku,
            icon: _updating
                ? SizedBox(
                    width: metrics.extraCompact ? 13 : 15,
                    height: metrics.extraCompact ? 13 : 15,
                    child: const CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : Icon(
                    Icons.refresh_rounded,
                    size: metrics.extraCompact ? 16 : 18,
                  ),
            label: Text(_updating ? '更新中' : '立即更新'),
            style: FilledButton.styleFrom(
              backgroundColor: _accent,
              foregroundColor: Colors.white,
              disabledBackgroundColor: _accent.withValues(alpha: 0.55),
              disabledForegroundColor: Colors.white70,
              visualDensity: VisualDensity.compact,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              padding: metrics.extraCompact
                  ? const EdgeInsets.symmetric(horizontal: 10, vertical: 6)
                  : null,
            ),
          ),
        ],
      ),
      if (_status != null)
        Padding(
          padding: EdgeInsets.only(top: metrics.extraCompact ? 4 : 6),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  _status!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: _statusIsError
                        ? const Color(0xFFFF8A80)
                        : Colors.white60,
                    fontSize: metrics.captionSize,
                  ),
                ),
              ),
              if (_statusIsError)
                InkWell(
                  onTap: () => setState(() => _status = null),
                  borderRadius: BorderRadius.circular(12),
                  child: const Padding(
                    padding: EdgeInsets.all(3),
                    child: Icon(
                      Icons.close_rounded,
                      size: 15,
                      color: Colors.white54,
                    ),
                  ),
                ),
            ],
          ),
        ),
    ];
  }

  String _speedLabel(double value) {
    final description = switch (value) {
      < 0.15 => '极慢',
      < 0.5 => '很慢',
      < 0.85 => '较慢',
      <= 1.2 => '适中',
      <= 2.0 => '较快',
      <= 5.0 => '很快',
      _ => '极快',
    };
    final digits = value < 1 ? 2 : (value < 10 ? 1 : 0);
    return '$description · ${value.toStringAsFixed(digits)}×';
  }
}

class _DanmakuAdvancedSettingsDialog extends StatelessWidget {
  const _DanmakuAdvancedSettingsDialog();

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsService>();
    final metrics = _DanmakuDialogMetrics.fromSize(
      MediaQuery.sizeOf(context),
      MediaQuery.paddingOf(context),
    );
    return _SettingsDialogFrame(
      title: '弹幕高级设置',
      maxWidth: 570,
      metrics: metrics,
      child: Flexible(
        child: SingleChildScrollView(
          key: const ValueKey('danmaku-advanced-settings-scroll'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _DanmakuPreview(settings: settings),
              SizedBox(height: metrics.sectionGap),
              const _SectionTitle('弹幕字体'),
              SizedBox(height: metrics.extraCompact ? 4 : 8),
              DropdownButtonFormField<String>(
                initialValue: settings.bilibiliDanmakuFontFamily ?? '',
                isExpanded: true,
                isDense: metrics.compact,
                dropdownColor: const Color(0xFF292929),
                iconEnabledColor: Colors.white70,
                style: TextStyle(
                  color: Colors.white,
                  fontFamily: settings.bilibiliDanmakuFontFamily,
                  fontSize: metrics.bodySize,
                ),
                decoration: _fieldDecoration(metrics),
                items: [
                  for (final family in kDanmakuFontFamilies)
                    DropdownMenuItem<String>(
                      value: family ?? '',
                      child: Text(
                        danmakuFontFamilyLabel(family),
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontFamily: family),
                      ),
                    ),
                ],
                onChanged: (value) => unawaited(
                  settings.saveBilibiliDanmakuFontFamily(
                    value == null || value.isEmpty ? null : value,
                  ),
                ),
              ),
              SizedBox(height: metrics.extraCompact ? 8 : 17),
              _SliderRow(
                label: '字重',
                valueText: '${settings.bilibiliDanmakuFontWeight}',
                value: settings.bilibiliDanmakuFontWeight.toDouble(),
                min: 100,
                max: 900,
                divisions: 8,
                onChanged: (value) => unawaited(
                  settings.saveBilibiliDanmakuFontWeight(value.round()),
                ),
              ),
              SizedBox(height: metrics.extraCompact ? 6 : 15),
              const _SectionTitle('描边类型'),
              SizedBox(height: metrics.extraCompact ? 6 : 10),
              LayoutBuilder(
                builder: (context, constraints) {
                  final spacing = metrics.outlineRunSpacing;
                  final itemWidth = constraints.maxWidth < 450
                      ? (constraints.maxWidth - spacing) / 2
                      : (constraints.maxWidth - spacing * 3) / 4;
                  return Wrap(
                    spacing: spacing,
                    runSpacing: spacing,
                    children: [
                      for (final type in DanmakuOutlineType.values)
                        SizedBox(
                          width: itemWidth,
                          child: _OutlineOption(
                            type: type,
                            selected:
                                settings.bilibiliDanmakuOutlineType == type,
                            onTap: () => unawaited(
                              settings.saveBilibiliDanmakuOutlineType(type),
                            ),
                          ),
                        ),
                    ],
                  );
                },
              ),
              SizedBox(height: metrics.extraCompact ? 10 : 22),
              OutlinedButton.icon(
                onPressed: () =>
                    unawaited(settings.resetBilibiliDanmakuSettings()),
                icon: Icon(
                  Icons.restart_alt_rounded,
                  size: metrics.extraCompact ? 16 : 20,
                ),
                label: const Text('恢复弹幕默认设置'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white,
                  side: const BorderSide(color: Colors.white30),
                  visualDensity: VisualDensity.compact,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  padding: metrics.extraCompact
                      ? const EdgeInsets.symmetric(horizontal: 12, vertical: 6)
                      : const EdgeInsets.symmetric(
                          horizontal: 18,
                          vertical: 12,
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  InputDecoration _fieldDecoration(_DanmakuDialogMetrics metrics) =>
      InputDecoration(
        filled: true,
        fillColor: const Color(0xFF171717),
        isDense: metrics.compact,
        contentPadding: EdgeInsets.symmetric(
          horizontal: metrics.compact ? 10 : 14,
          vertical: metrics.fieldVerticalPadding,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(7),
          borderSide: const BorderSide(color: Colors.white24),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(7),
          borderSide: const BorderSide(color: _accent),
        ),
      );
}

class _SettingsDialogFrame extends StatelessWidget {
  final String title;
  final double maxWidth;
  final _DanmakuDialogMetrics metrics;
  final Widget? headerAction;
  final Widget child;

  const _SettingsDialogFrame({
    required this.title,
    required this.maxWidth,
    required this.metrics,
    this.headerAction,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.sizeOf(context);
    final maxHeight = (screen.height - metrics.insetPadding.vertical).clamp(
      0.0,
      screen.height,
    );
    return Dialog(
      backgroundColor: const Color(0xF2222222),
      insetPadding: metrics.insetPadding,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: _DanmakuDialogScope(
        metrics: metrics,
        child: Theme(
          data: Theme.of(context).copyWith(
            materialTapTargetSize: metrics.compact
                ? MaterialTapTargetSize.shrinkWrap
                : Theme.of(context).materialTapTargetSize,
            visualDensity: metrics.extraCompact
                ? const VisualDensity(horizontal: -4, vertical: -4)
                : metrics.compact
                ? const VisualDensity(horizontal: -2, vertical: -3)
                : VisualDensity.compact,
          ),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: maxWidth,
              maxHeight: maxHeight,
            ),
            child: Padding(
              padding: metrics.contentPadding,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: metrics.titleSize,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      if (headerAction != null)
                        Flexible(
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            alignment: Alignment.centerRight,
                            child: headerAction,
                          ),
                        ),
                      IconButton(
                        onPressed: () => Navigator.of(context).pop(),
                        icon: Icon(
                          Icons.close,
                          color: Colors.white70,
                          size: metrics.extraCompact ? 18 : 22,
                        ),
                        visualDensity: VisualDensity.compact,
                        padding: metrics.extraCompact
                            ? const EdgeInsets.all(4)
                            : null,
                        constraints: metrics.extraCompact
                            ? const BoxConstraints(minWidth: 28, minHeight: 28)
                            : null,
                      ),
                    ],
                  ),
                  SizedBox(height: metrics.headerGap),
                  child,
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DanmakuPreview extends StatelessWidget {
  final SettingsService settings;

  const _DanmakuPreview({required this.settings});

  @override
  Widget build(BuildContext context) {
    final metrics = _DanmakuDialogScope.of(context);
    return Container(
      height: metrics.previewHeight,
      width: double.infinity,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: const Color(0xFF10151A),
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: Colors.white12),
      ),
      child: _OutlinedPreviewText(
        text: '弹幕预览  Danmaku',
        type: settings.bilibiliDanmakuOutlineType,
        fontFamily: settings.bilibiliDanmakuFontFamily,
        fontWeight: settings.bilibiliDanmakuFontWeight,
        fontSize: metrics.previewFontSize,
      ),
    );
  }
}

class _OutlineOption extends StatelessWidget {
  final DanmakuOutlineType type;
  final bool selected;
  final VoidCallback onTap;

  const _OutlineOption({
    required this.type,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final metrics = _DanmakuDialogScope.of(context);
    return Material(
      color: selected ? _accent : const Color(0xFF555555),
      borderRadius: BorderRadius.circular(7),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(7),
        child: Padding(
          padding: metrics.outlineItemPadding,
          child: Column(
            children: [
              _OutlinedPreviewText(
                text: '弹幕',
                type: type,
                fontWeight: 600,
                fontSize: metrics.extraCompact ? 14 : 17,
              ),
              SizedBox(height: metrics.extraCompact ? 2 : 5),
              Text(
                type.label,
                maxLines: 1,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: metrics.captionSize,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Text(
                type.description,
                maxLines: 1,
                style: TextStyle(
                  color: Colors.white70,
                  fontSize: metrics.extraCompact ? 9 : 10,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _OutlinedPreviewText extends StatelessWidget {
  final String text;
  final DanmakuOutlineType type;
  final String? fontFamily;
  final int fontWeight;
  final double fontSize;

  const _OutlinedPreviewText({
    required this.text,
    required this.type,
    this.fontFamily,
    required this.fontWeight,
    required this.fontSize,
  });

  @override
  Widget build(BuildContext context) {
    final width = switch (type) {
      DanmakuOutlineType.standard => 2.2,
      DanmakuOutlineType.thin => 1.2,
      DanmakuOutlineType.heavy => 3.2,
      DanmakuOutlineType.projection => 0.8,
    };
    final base = TextStyle(
      fontFamily: fontFamily,
      fontWeight: danmakuFontWeight(fontWeight),
      fontSize: fontSize,
      height: 1,
    );
    return Stack(
      alignment: Alignment.center,
      children: [
        if (type == DanmakuOutlineType.projection)
          Transform.translate(
            offset: const Offset(3, 3),
            child: Text(text, style: base.copyWith(color: Colors.black87)),
          ),
        Text(
          text,
          style: base.copyWith(
            foreground: Paint()
              ..style = PaintingStyle.stroke
              ..strokeJoin = StrokeJoin.round
              ..strokeWidth = width
              ..color = Colors.black,
          ),
        ),
        Text(text, style: base.copyWith(color: Colors.white)),
      ],
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String text;

  const _SectionTitle(this.text);

  @override
  Widget build(BuildContext context) {
    final metrics = _DanmakuDialogScope.of(context);
    return Text(
      text,
      style: TextStyle(
        color: Colors.white,
        fontSize: metrics.bodySize,
        fontWeight: FontWeight.w600,
      ),
    );
  }
}

class _SwitchRow extends StatelessWidget {
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _SwitchRow({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final metrics = _DanmakuDialogScope.of(context);
    return Padding(
      padding: EdgeInsets.symmetric(vertical: metrics.extraCompact ? 0 : 2),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                color: Colors.white,
                fontSize: metrics.bodySize,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          SizedBox(
            height: metrics.switchHeight,
            width: metrics.switchHeight * 1.85,
            child: FittedBox(
              fit: BoxFit.contain,
              alignment: Alignment.centerRight,
              child: Switch(
                value: value,
                activeTrackColor: _accent,
                activeThumbColor: Colors.white,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                onChanged: onChanged,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CheckboxRow extends StatelessWidget {
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _CheckboxRow({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final metrics = _DanmakuDialogScope.of(context);
    // Compact trailing checkbox so the extra setting can sit under the speed
    // slider without growing the dialog past a small phone viewport.
    return InkWell(
      onTap: () => onChanged(!value),
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: EdgeInsets.fromLTRB(0, metrics.extraCompact ? 0 : 2, 0, 0),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: metrics.bodySize,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            SizedBox(
              width: metrics.extraCompact ? 28 : 32,
              height: metrics.extraCompact ? 28 : 32,
              child: IgnorePointer(
                child: Checkbox(
                  key: const ValueKey('danmaku-locked-speed-baseline-checkbox'),
                  value: value,
                  onChanged: (_) {},
                  activeColor: _accent,
                  checkColor: Colors.white,
                  side: const BorderSide(color: Colors.white54, width: 1.25),
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: VisualDensity.compact,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SliderRow extends StatelessWidget {
  final String label;
  final String valueText;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final ValueChanged<double> onChanged;

  const _SliderRow({
    required this.label,
    required this.valueText,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final metrics = _DanmakuDialogScope.of(context);
    return Padding(
      padding: EdgeInsets.symmetric(vertical: metrics.sliderVerticalPadding),
      child: Row(
        children: [
          SizedBox(
            width: metrics.sliderLabelWidth,
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: Colors.white,
                fontSize: metrics.bodySize,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                activeTrackColor: _accent,
                inactiveTrackColor: Colors.white24,
                thumbColor: Colors.white,
                overlayColor: const Color(0x33FF6699),
                trackHeight: metrics.sliderTrackHeight,
                padding: metrics.sliderPadding,
                // Overlay padding is the main height sink on Material sliders.
                overlayShape: metrics.compact
                    ? SliderComponentShape.noOverlay
                    : RoundSliderOverlayShape(
                        overlayRadius: metrics.sliderThumbRadius + 8,
                      ),
                thumbShape: RoundSliderThumbShape(
                  enabledThumbRadius: metrics.sliderThumbRadius,
                ),
              ),
              child: metrics.compact
                  ? SizedBox(
                      height: metrics.extraCompact ? 24 : 28,
                      child: Slider(
                        value: value.clamp(min, max),
                        min: min,
                        max: max,
                        divisions: divisions,
                        onChanged: onChanged,
                      ),
                    )
                  : Slider(
                      value: value.clamp(min, max),
                      min: min,
                      max: max,
                      divisions: divisions,
                      onChanged: onChanged,
                    ),
            ),
          ),
          SizedBox(
            width: metrics.sliderValueWidth,
            child: Text(
              valueText,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white70,
                fontSize: metrics.valueSize,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
