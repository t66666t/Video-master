import 'package:flutter/material.dart';
import '../models/subtitle_debug_preset.dart';
import '../services/subtitle_debug_session.dart';
import 'subtitle_preset_settings_dialog.dart';

class SubtitleDebugPanel extends StatefulWidget {
  const SubtitleDebugPanel({super.key});
  @override
  State<SubtitleDebugPanel> createState() => _SubtitleDebugPanelState();
}

class _SubtitleDebugPanelState extends State<SubtitleDebugPanel> {
  final _session = SubtitleDebugSession.instance;
  late final _scroll = ScrollController(
    initialScrollOffset: _session.browserOffset,
  );
  late final _search = TextEditingController(text: _session.browserQuery);
  String? _editing;
  bool _filters = false;
  @override
  void initState() {
    super.initState();
    _scroll.addListener(_remember);
  }

  void _remember() {
    _session.browserOffset = _scroll.offset;
  }

  @override
  void dispose() {
    _scroll.dispose();
    _search.dispose();
    super.dispose();
  }

  void _filterChanged() {
    if (_scroll.hasClients) _scroll.jumpTo(0);
    setState(() {});
  }

  void _edit(String id) {
    _session.select(_session.resolved(id));
    setState(() => _editing = id);
  }

  void _locate(double extent, int columns) {
    _session.browserCategory = '全部';
    _session.browserQuery = '';
    _search.clear();
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final index = subtitleDebugPresets.indexWhere(
        (p) => p.id == _session.preset?.id,
      );
      _scroll.jumpTo(
        ((index ~/ columns) * (extent + 4)).clamp(
          0.0,
          _scroll.position.maxScrollExtent,
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _session,
    builder: (context, _) {
      if (!_session.enabled) return const SizedBox.shrink();
      final filtered = subtitleDebugPresets
          .where(
            (p) =>
                (_session.browserCategory == '全部' ||
                    p.category == _session.browserCategory) &&
                '${p.name} ${p.fontSummary}'.toLowerCase().contains(
                  _session.browserQuery.toLowerCase(),
                ),
          )
          .toList();
      return LayoutBuilder(
        builder: (context, constraints) {
          final height = constraints.hasBoundedHeight
              ? constraints.maxHeight
              : MediaQuery.sizeOf(context).height;
          final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
          final extent = 114.0 * scale.clamp(1, 3);
          final columns = (constraints.maxWidth / 300).floor().clamp(1, 6);
          return SizedBox(
            height: height,
            child: Theme(
              data: ThemeData(
                brightness: Brightness.dark,
                fontFamily: 'Noto Sans SC',
              ),
              child: Material(
                color: const Color(0xFF17272D),
                child: IndexedStack(
                  index: _editing == null ? 0 : 1,
                  children: [
                    Column(
                      children: [
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  '当前：${_session.preset?.name ?? "原样式"}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Colors.tealAccent,
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                              IconButton(
                                tooltip: '定位当前样式',
                                onPressed: _session.preset == null
                                    ? null
                                    : () => _locate(extent, columns),
                                icon: const Icon(Icons.my_location, size: 18),
                              ),
                              IconButton(
                                tooltip: '搜索与分类',
                                onPressed: () =>
                                    setState(() => _filters = !_filters),
                                icon: const Icon(Icons.search, size: 18),
                              ),
                            ],
                          ),
                        ),
                        Row(
                          children: [
                            Expanded(
                              child: TextButton(
                                onPressed: _session.useOriginal,
                                child: const Text('使用原样式'),
                              ),
                            ),
                            if (_session.preset != null)
                              Expanded(
                                child: TextButton.icon(
                                  onPressed: () => _edit(_session.preset!.id),
                                  icon: const Icon(Icons.tune, size: 16),
                                  label: const Text('微调当前预设'),
                                ),
                              ),
                          ],
                        ),
                        if (_filters)
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            child: Row(
                              children: [
                                Expanded(
                                  child: TextField(
                                    controller: _search,
                                    decoration: const InputDecoration(
                                      isDense: true,
                                      hintText: '昵称 / 字体',
                                    ),
                                    onChanged: (v) {
                                      _session.browserQuery = v;
                                      _filterChanged();
                                    },
                                  ),
                                ),
                                const SizedBox(width: 8),
                                DropdownButton<String>(
                                  value: _session.browserCategory,
                                  items:
                                      [
                                            '全部',
                                            ...subtitleDebugPresets
                                                .map((p) => p.category)
                                                .toSet(),
                                          ]
                                          .map(
                                            (c) => DropdownMenuItem(
                                              value: c,
                                              child: Text(
                                                c,
                                                style: const TextStyle(
                                                  fontSize: 12,
                                                ),
                                              ),
                                            ),
                                          )
                                          .toList(),
                                  onChanged: (v) {
                                    _session.browserCategory = v!;
                                    _filterChanged();
                                  },
                                ),
                              ],
                            ),
                          ),
                        if (_session.saveError != null)
                          Text(
                            _session.saveError!,
                            style: const TextStyle(
                              color: Colors.orangeAccent,
                              fontSize: 11,
                            ),
                          ),
                        Expanded(
                          child: Scrollbar(
                            controller: _scroll,
                            thumbVisibility: true,
                            child: CustomScrollView(
                              key: const ValueKey(
                                'subtitle-preset-full-height-scroll',
                              ),
                              controller: _scroll,
                              slivers: [
                                SliverPadding(
                                  padding: const EdgeInsets.all(4),
                                  sliver: SliverGrid(
                                    gridDelegate:
                                        SliverGridDelegateWithFixedCrossAxisCount(
                                          crossAxisCount: columns,
                                          mainAxisExtent: extent,
                                          mainAxisSpacing: 4,
                                          crossAxisSpacing: 4,
                                        ),
                                    delegate: SliverChildBuilderDelegate((
                                      context,
                                      index,
                                    ) {
                                      final p = _session.resolved(
                                        filtered[index].id,
                                      );
                                      final selected =
                                          _session.preset?.id == p.id;
                                      return Material(
                                        key: ValueKey('preset-card-${p.id}'),
                                        color: selected
                                            ? const Color(0xFF245349)
                                            : const Color(0xFF202C30),
                                        borderRadius: BorderRadius.circular(6),
                                        child: InkWell(
                                          onTap: () => _session.select(p),
                                          child: Padding(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 8,
                                              vertical: 4,
                                            ),
                                            child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.stretch,
                                              children: [
                                                Row(
                                                  children: [
                                                    Expanded(
                                                      child: Text(
                                                        '${selected ? "✓ " : ""}${p.name}',
                                                        maxLines: 1,
                                                        overflow: TextOverflow
                                                            .ellipsis,
                                                        style: const TextStyle(
                                                          fontSize: 13,
                                                          fontWeight:
                                                              FontWeight.w600,
                                                        ),
                                                      ),
                                                    ),
                                                    IconButton(
                                                      tooltip: '微调${p.name}',
                                                      onPressed: () =>
                                                          _edit(p.id),
                                                      padding: EdgeInsets.zero,
                                                      constraints:
                                                          const BoxConstraints(
                                                            minWidth: 28,
                                                            minHeight: 28,
                                                          ),
                                                      visualDensity:
                                                          VisualDensity.compact,
                                                      icon: const Icon(
                                                        Icons.tune,
                                                        size: 16,
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                                Text(
                                                  p.fontSummary,
                                                  maxLines: 2,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: const TextStyle(
                                                    fontSize: 10,
                                                    height: 1.3,
                                                    color: Colors.white70,
                                                  ),
                                                ),
                                                const Spacer(),
                                                Text(
                                                  '风起时，我们再次相遇。',
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: TextStyle(
                                                    fontFamily: p.primaryFont,
                                                    fontWeight:
                                                        FontWeight.values[p
                                                                    .primaryWeight ~/
                                                                100 -
                                                            1],
                                                    fontSize: 15,
                                                    color: p.color,
                                                  ),
                                                ),
                                                Text(
                                                  'When the wind rises, we meet again.',
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: TextStyle(
                                                    fontFamily: p.secondaryFont,
                                                    fontSize: 10,
                                                    color: p.secondaryColor,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),
                                      );
                                    }, childCount: filtered.length),
                                  ),
                                ),
                                SliverToBoxAdapter(
                                  child: Padding(
                                    padding: const EdgeInsets.all(8),
                                    child: Text(
                                      filtered.isEmpty
                                          ? '没有匹配的预设'
                                          : '${filtered.length} 套 · 点击即全局应用并自动保存',
                                      style: const TextStyle(
                                        fontSize: 11,
                                        color: Colors.white60,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                    if (_editing != null)
                      SubtitlePresetSettingsPanel(
                        key: ValueKey(_editing),
                        id: _editing!,
                        onBack: () => setState(() => _editing = null),
                      ),
                  ],
                ),
              ),
            ),
          );
        },
      );
    },
  );
}
