import 'package:flutter/material.dart';

import '../models/media_library_root_entry.dart';
import '../models/media_library_root_entry_order.dart';
import '../models/media_library_root_swipe_policy.dart';
import 'media_library_compact_app_bar.dart';

/// Compact root-entry switcher intended to replace the "我的媒体库" title.
///
/// All destinations are mounted on the root page. A disabled chip only
/// appears when the host has not yet listed that entry as available.
/// Long-press then drag reorders chips; a short press still only switches.
class MediaLibraryEntrySwitcher extends StatelessWidget {
  const MediaLibraryEntrySwitcher({
    super.key,
    required this.selected,
    required this.availableEntries,
    required this.onSelected,
    this.compact = false,
    this.highlightIndex,
    this.entries = MediaLibraryRootEntryOrder.defaults,
    this.reorderEnabled = false,
    this.onReorder,
  });

  final MediaLibraryRootEntry selected;
  final Set<MediaLibraryRootEntry> availableEntries;
  final ValueChanged<MediaLibraryRootEntry> onSelected;
  final bool compact;

  /// Fractional chip index while a page swipe is in flight. Discrete
  /// [selected] still owns taps and commit; this only paints the follow.
  final double? highlightIndex;

  final List<MediaLibraryRootEntry> entries;

  /// Chip reorder is off while a page is mid-swipe or mid-fade.
  final bool reorderEnabled;

  final void Function(int oldIndex, int newIndex)? onReorder;

  /// Ignore a stale notifier that is not on or next to the real selected chip.
  double get _visualHighlight {
    final selectedIndex = entries.indexOf(selected).toDouble();
    final incoming = highlightIndex;
    if (incoming == null || selectedIndex < 0) {
      return selectedIndex < 0 ? 0 : selectedIndex;
    }
    if ((incoming - selectedIndex).abs() > 1.0001) return selectedIndex;
    return incoming;
  }

  @override
  Widget build(BuildContext context) {
    final style = compact
        ? mediaLibraryCompactTitleStyle.copyWith(fontSize: 13)
        : mediaLibraryCompactTitleStyle;
    final highlight = _visualHighlight;
    final ordered = MediaLibraryRootEntryOrder.normalize(entries);
    final canReorder = reorderEnabled && onReorder != null && ordered.length > 1;

    final chips = <Widget>[
      for (var i = 0; i < ordered.length; i++)
        _chip(
          index: i,
          ordered: ordered,
          highlight: highlight,
          style: style,
          canReorder: canReorder,
        ),
    ];

    final translated = Transform.translate(
      offset: const Offset(0, mediaLibraryCompactTitleOpticalOffset),
      child: SizedBox(
        height: compact ? 32 : 36,
        child: canReorder
            ? ReorderableListView(
                scrollDirection: Axis.horizontal,
                shrinkWrap: true,
                primary: false,
                padding: EdgeInsets.zero,
                buildDefaultDragHandles: false,
                physics: const NeverScrollableScrollPhysics(),
                proxyDecorator: _proxyDecorator,
                onReorderItem: onReorder!,
                children: chips,
              )
            : Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: chips,
              ),
      ),
    );

    if (canReorder) {
      return Align(alignment: Alignment.centerLeft, child: translated);
    }
    return Align(
      alignment: Alignment.centerLeft,
      child: FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.centerLeft,
        child: translated,
      ),
    );
  }

  Widget _chip({
    required int index,
    required List<MediaLibraryRootEntry> ordered,
    required double highlight,
    required TextStyle style,
    required bool canReorder,
  }) {
    final entry = ordered[index];
    final chip = _EntryChip(
      entry: entry,
      selected: entry == selected,
      highlightWeight: MediaLibraryRootSwipePolicy.chipWeight(
        entryIndex: index,
        highlightIndex: highlight,
      ),
      enabled: availableEntries.contains(entry),
      compact: compact,
      style: style,
      onSelected: onSelected,
      trailingGap: index == ordered.length - 1 ? 0 : _EntryChip._gapAfter(compact),
    );
    if (!canReorder) return chip;
    return ReorderableDelayedDragStartListener(
      key: ValueKey<MediaLibraryRootEntry>(entry),
      index: index,
      child: chip,
    );
  }

  static Widget _proxyDecorator(
    Widget child,
    int index,
    Animation<double> animation,
  ) {
    return AnimatedBuilder(
      animation: animation,
      child: child,
      builder: (context, child) {
        final t = Curves.easeOutCubic.transform(animation.value);
        return Transform.scale(
          scale: 1.0 + (0.08 * t),
          child: Opacity(opacity: 0.92 + (0.08 * t), child: child),
        );
      },
    );
  }
}

class _EntryChip extends StatelessWidget {
  const _EntryChip({
    required this.entry,
    required this.selected,
    required this.highlightWeight,
    required this.enabled,
    required this.compact,
    required this.style,
    required this.onSelected,
    required this.trailingGap,
  });

  final MediaLibraryRootEntry entry;
  final bool selected;
  final double highlightWeight;
  final bool enabled;
  final bool compact;
  final TextStyle style;
  final ValueChanged<MediaLibraryRootEntry> onSelected;
  final double trailingGap;

  /// Inner padding is the clickable box. Keep a 4px dead strip between chips
  /// so a slightly larger target cannot select the neighbor.
  static EdgeInsets _hitPadding(bool compact) {
    return compact
        ? const EdgeInsets.symmetric(horizontal: 6, vertical: 0)
        : const EdgeInsets.symmetric(horizontal: 8, vertical: 0);
  }

  static double _gapAfter(bool compact) => compact ? 4 : 6;

  void _onTap() {
    if (!enabled || selected) return;
    onSelected(entry);
  }

  @override
  Widget build(BuildContext context) {
    final color = !enabled
        ? Colors.white24
        : Color.lerp(Colors.white70, Colors.blueAccent, highlightWeight)!;
    final weight = FontWeight.lerp(
      style.fontWeight ?? FontWeight.w400,
      FontWeight.w500,
      highlightWeight,
    );
    final canSelect = enabled && !selected;
    return Padding(
      padding: EdgeInsets.only(right: trailingGap),
      child: MouseRegion(
        cursor: canSelect
            ? SystemMouseCursors.click
            : SystemMouseCursors.basic,
        opaque: true,
        hitTestBehavior: HitTestBehavior.opaque,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: canSelect ? _onTap : null,
          child: SizedBox(
            height: compact ? 32 : 36,
            child: Padding(
              padding: _hitPadding(compact),
              child: Align(
                alignment: Alignment.center,
                child: Text(
                  entry.label,
                  maxLines: 1,
                  style: style.copyWith(
                    color: color,
                    fontWeight: enabled ? weight : style.fontWeight,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
