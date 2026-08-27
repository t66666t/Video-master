import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/danmaku_style.dart';
import '../services/settings_service.dart';

const _accent = Color(0xFFFF6699);

Future<void> showDanmakuSettingsDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    barrierColor: Colors.black54,
    builder: (context) => const _DanmakuSettingsDialog(),
  );
}

class _DanmakuSettingsDialog extends StatelessWidget {
  const _DanmakuSettingsDialog();

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsService>();
    return _SettingsDialogFrame(
      title: '弹幕设置',
      maxWidth: 460,
      headerAction: TextButton.icon(
        onPressed: () => showDialog<void>(
          context: context,
          barrierColor: Colors.black54,
          builder: (_) => const _DanmakuAdvancedSettingsDialog(),
        ),
        icon: const Icon(Icons.tune_rounded, size: 17),
        label: const Text('高级设置'),
        style: TextButton.styleFrom(
          foregroundColor: _accent,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
          visualDensity: VisualDensity.compact,
        ),
      ),
      child: Flexible(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _SwitchRow(
                label: '弹幕仅在视频区域内展示',
                value: settings.bilibiliDanmakuOnlyInVideoArea,
                onChanged: (value) => unawaited(
                  settings.saveBilibiliDanmakuOnlyInVideoArea(value),
                ),
              ),
              _SliderRow(
                label: '显示区域',
                valueText:
                    '${(settings.bilibiliDanmakuDisplayArea * 100).round()}%',
                value: settings.bilibiliDanmakuDisplayArea,
                min: kDanmakuDisplayAreaMin,
                max: kDanmakuDisplayAreaMax,
                divisions: 99,
                onChanged: (value) =>
                    unawaited(settings.saveBilibiliDanmakuDisplayArea(value)),
              ),
              _SliderRow(
                label: '不透明度',
                valueText:
                    '${(settings.bilibiliDanmakuOpacity * 100).round()}%',
                value: settings.bilibiliDanmakuOpacity,
                min: 0.1,
                max: 1,
                divisions: 90,
                onChanged: (value) =>
                    unawaited(settings.saveBilibiliDanmakuOpacity(value)),
              ),
              _SliderRow(
                label: '弹幕字号',
                valueText:
                    '${(settings.bilibiliDanmakuFontScale * 100).round()}%',
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
                value: settings.bilibiliDanmakuSpeed,
                min: kDanmakuSpeedMin,
                max: kDanmakuSpeedMax,
                divisions: 79,
                onChanged: (value) =>
                    unawaited(settings.saveBilibiliDanmakuSpeed(value)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _speedLabel(double value) {
    if (value < 0.75) return '很慢';
    if (value < 0.95) return '较慢';
    if (value <= 1.15) return '适中';
    if (value <= 1.5) return '较快';
    return '很快';
  }
}

class _DanmakuAdvancedSettingsDialog extends StatelessWidget {
  const _DanmakuAdvancedSettingsDialog();

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsService>();
    return _SettingsDialogFrame(
      title: '弹幕高级设置',
      maxWidth: 570,
      child: Flexible(
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _DanmakuPreview(settings: settings),
              const SizedBox(height: 20),
              const _SectionTitle('弹幕字体'),
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                initialValue: settings.bilibiliDanmakuFontFamily ?? '',
                isExpanded: true,
                dropdownColor: const Color(0xFF292929),
                iconEnabledColor: Colors.white70,
                style: TextStyle(
                  color: Colors.white,
                  fontFamily: settings.bilibiliDanmakuFontFamily,
                  fontSize: 15,
                ),
                decoration: _fieldDecoration(),
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
              const SizedBox(height: 17),
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
              const SizedBox(height: 15),
              const _SectionTitle('描边类型'),
              const SizedBox(height: 10),
              LayoutBuilder(
                builder: (context, constraints) {
                  final itemWidth = constraints.maxWidth < 450
                      ? (constraints.maxWidth - 10) / 2
                      : (constraints.maxWidth - 30) / 4;
                  return Wrap(
                    spacing: 10,
                    runSpacing: 10,
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
              const SizedBox(height: 22),
              OutlinedButton.icon(
                onPressed: () =>
                    unawaited(settings.resetBilibiliDanmakuSettings()),
                icon: const Icon(Icons.restart_alt_rounded),
                label: const Text('恢复弹幕默认设置'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white,
                  side: const BorderSide(color: Colors.white30),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 18,
                    vertical: 12,
                  ),
                ),
              ),
              const SizedBox(height: 2),
            ],
          ),
        ),
      ),
    );
  }

  InputDecoration _fieldDecoration() => InputDecoration(
    filled: true,
    fillColor: const Color(0xFF171717),
    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
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
  final Widget? headerAction;
  final Widget child;

  const _SettingsDialogFrame({
    required this.title,
    required this.maxWidth,
    this.headerAction,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xF2222222),
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: maxWidth,
          maxHeight: MediaQuery.sizeOf(context).height - 48,
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(22, 14, 16, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      title,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  headerAction ?? const SizedBox.shrink(),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close, color: Colors.white70),
                    visualDensity: VisualDensity.compact,
                  ),
                ],
              ),
              const SizedBox(height: 4),
              child,
            ],
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
    return Container(
      height: 92,
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
        fontSize: 24,
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
    return Material(
      color: selected ? _accent : const Color(0xFF555555),
      borderRadius: BorderRadius.circular(7),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(7),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
          child: Column(
            children: [
              _OutlinedPreviewText(
                text: '弹幕',
                type: type,
                fontWeight: 600,
                fontSize: 17,
              ),
              const SizedBox(height: 5),
              Text(
                type.label,
                maxLines: 1,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Text(
                type.description,
                maxLines: 1,
                style: const TextStyle(color: Colors.white70, fontSize: 10),
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
  Widget build(BuildContext context) => Text(
    text,
    style: const TextStyle(
      color: Colors.white,
      fontSize: 15,
      fontWeight: FontWeight.w600,
    ),
  );
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
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Switch(
            value: value,
            activeTrackColor: _accent,
            activeThumbColor: Colors.white,
            onChanged: onChanged,
          ),
        ],
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
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          SizedBox(
            width: 92,
            child: Text(
              label,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 15,
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
                trackHeight: 7,
              ),
              child: Slider(
                value: value.clamp(min, max),
                min: min,
                max: max,
                divisions: divisions,
                onChanged: onChanged,
              ),
            ),
          ),
          SizedBox(
            width: 62,
            child: Text(
              valueText,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
