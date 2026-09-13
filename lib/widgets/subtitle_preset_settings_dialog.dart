import 'package:flutter/material.dart';
import '../services/subtitle_debug_session.dart';
import 'subtitle_overlay.dart';

class SubtitlePresetSettingsPanel extends StatelessWidget {
  final String id;
  final VoidCallback onBack;
  const SubtitlePresetSettingsPanel({
    super.key,
    required this.id,
    required this.onBack,
  });
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: SubtitleDebugSession.instance,
    builder: (context, _) {
      final session = SubtitleDebugSession.instance;
      final p = session.resolved(id);
      return Column(
        key: const ValueKey('subtitle-preset-inline-settings'),
        children: [
          Row(
            children: [
              IconButton(
                onPressed: onBack,
                tooltip: '返回预设列表',
                icon: const Icon(Icons.arrow_back),
              ),
              Expanded(
                child: Text(
                  '${p.name} · 微调',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              TextButton(
                onPressed: () => session.resetPreset(id),
                child: const Text('重置本预设'),
              ),
            ],
          ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    '自动保存到本预设；其他预设不受影响。',
                    style: TextStyle(fontSize: 12, color: Colors.white70),
                  ),
                  Container(
                    margin: const EdgeInsets.symmetric(vertical: 8),
                    color: const Color(0xFF425362),
                    padding: const EdgeInsets.all(10),
                    child: SubtitlePresetContent(
                      entry: const SubtitleOverlayEntry(
                        text: '风起时，我们再次相遇。',
                        secondaryText: 'When the wind rises, we meet again.',
                      ),
                      preset: p,
                      referenceHeight: 430,
                    ),
                  ),
                  _slider(
                    '主副字幕整体大小',
                    p.textScale,
                    .6,
                    1.8,
                    '${(p.textScale * 100).round()}%',
                    (v) => session.updatePreset(p.copyWith(textScale: v)),
                  ),
                  Text(
                    '主 ${(p.size * p.textScale).toStringAsFixed(1)} / 副 ${(p.size * p.ratio * p.textScale).toStringAsFixed(1)}（720 基准）',
                    style: const TextStyle(fontSize: 11, color: Colors.white60),
                  ),
                  _color(
                    context,
                    '主字幕颜色',
                    p.color,
                    (v) => session.updatePreset(p.copyWith(color: v)),
                  ),
                  _color(
                    context,
                    '副字幕颜色',
                    p.secondaryColor,
                    (v) => session.updatePreset(p.copyWith(secondaryColor: v)),
                  ),
                  _slider(
                    '描边粗细',
                    p.outline,
                    0,
                    6,
                    p.outline.toStringAsFixed(1),
                    (v) => session.updatePreset(p.copyWith(outline: v)),
                  ),
                  _color(
                    context,
                    '描边颜色',
                    p.borderColor,
                    (v) => session.updatePreset(p.copyWith(borderColor: v)),
                  ),
                  _color(
                    context,
                    '背景颜色',
                    p.backgroundColor,
                    (v) => session.updatePreset(p.copyWith(backgroundColor: v)),
                  ),
                  _slider(
                    '背景不透明度',
                    p.box,
                    0,
                    1,
                    '${(p.box * 100).round()}%',
                    (v) => session.updatePreset(p.copyWith(box: v)),
                  ),
                  const Text(
                    '保留本预设的背景形状、内边距与双行排列。',
                    style: TextStyle(fontSize: 11, color: Colors.white60),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('阴影'),
                    value: p.shadowEnabled,
                    onChanged: (v) =>
                        session.updatePreset(p.copyWith(shadowEnabled: v)),
                  ),
                  if (p.shadowEnabled) ...[
                    _color(
                      context,
                      '阴影颜色',
                      p.shadowColor,
                      (v) => session.updatePreset(p.copyWith(shadowColor: v)),
                    ),
                    _slider(
                      '阴影模糊',
                      p.shadowBlur,
                      0,
                      10,
                      p.shadowBlur.toStringAsFixed(1),
                      (v) => session.updatePreset(p.copyWith(shadowBlur: v)),
                    ),
                    _slider(
                      '阴影横向偏移',
                      p.shadowOffset.dx,
                      -8,
                      8,
                      p.shadowOffset.dx.toStringAsFixed(1),
                      (v) => session.updatePreset(
                        p.copyWith(shadowOffset: Offset(v, p.shadowOffset.dy)),
                      ),
                    ),
                    _slider(
                      '阴影纵向偏移',
                      p.shadowOffset.dy,
                      -8,
                      8,
                      p.shadowOffset.dy.toStringAsFixed(1),
                      (v) => session.updatePreset(
                        p.copyWith(shadowOffset: Offset(p.shadowOffset.dx, v)),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          TextButton(onPressed: onBack, child: const Text('完成')),
        ],
      );
    },
  );
  Widget _slider(
    String name,
    double value,
    double min,
    double max,
    String label,
    ValueChanged<double> onChanged,
  ) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(
        padding: const EdgeInsets.only(top: 10),
        child: Text('$name · $label', style: const TextStyle(fontSize: 12)),
      ),
      Slider(
        value: value.clamp(min, max),
        min: min,
        max: max,
        onChanged: onChanged,
      ),
    ],
  );
  Widget _color(
    BuildContext context,
    String title,
    Color value,
    ValueChanged<Color> onChanged,
  ) => ExpansionTile(
    tilePadding: EdgeInsets.zero,
    title: Text(title, style: const TextStyle(fontSize: 12)),
    leading: Container(
      width: 24,
      height: 24,
      decoration: BoxDecoration(
        color: value,
        border: Border.all(color: Colors.white54),
      ),
    ),
    children: [
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children:
            [
                  Colors.white,
                  Colors.black,
                  Colors.yellow,
                  Colors.amber,
                  Colors.orange,
                  Colors.red,
                  Colors.pink,
                  Colors.purple,
                  Colors.blue,
                  Colors.cyan,
                  Colors.teal,
                  Colors.green,
                  Colors.grey,
                ]
                .map(
                  (c) => Semantics(
                    label: '$title ${c.toARGB32().toRadixString(16)}',
                    button: true,
                    child: InkWell(
                      onTap: () => onChanged(c),
                      child: Container(
                        width: 30,
                        height: 30,
                        decoration: BoxDecoration(
                          color: c,
                          border: Border.all(color: Colors.white54),
                        ),
                      ),
                    ),
                  ),
                )
                .toList(),
      ),
      TextFormField(
        key: ValueKey('$title-${value.toARGB32()}'),
        initialValue: value
            .toARGB32()
            .toRadixString(16)
            .padLeft(8, '0')
            .toUpperCase(),
        decoration: const InputDecoration(labelText: '颜色代码 AARRGGBB / RRGGBB'),
        autovalidateMode: AutovalidateMode.onUserInteraction,
        validator: (v) =>
            _parseColor(v ?? '') == null ? '请输入 6 或 8 位十六进制颜色' : null,
        onFieldSubmitted: (v) {
          final color = _parseColor(v);
          if (color != null) onChanged(color);
        },
      ),
      const Text('输入颜色代码后按回车应用', style: TextStyle(fontSize: 11)),
    ],
  );
  Color? _parseColor(String value) {
    final hex = value.trim().replaceFirst('#', '');
    if (!RegExp(r'^(?:[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$').hasMatch(hex)) {
      return null;
    }
    return Color(int.parse(hex.length == 6 ? 'FF$hex' : hex, radix: 16));
  }
}
