import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../theme/app_tokens.dart';

import '../models/media_library_root_entry.dart';
import '../models/media_library_root_entry_order.dart';
import '../models/media_library_root_swipe_policy.dart';
import 'media_library_compact_app_bar.dart';

/// Compact root-entry switcher intended to replace the "我的媒体库" title.
///
/// All destinations are mounted on the root page. A disabled chip only
/// appears when the host has not yet listed that entry as available.
/// Drag a title to reorder; a short press still only switches.
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
    // Keep one chip row widget for the whole swipe. Swapping
    // ReorderableListView ↔ Row when [reorderEnabled] flips is what
    // made the titles jump mid-gesture.
    final useReorderableRow = onReorder != null && ordered.length > 1;
    final canDragReorder = useReorderableRow && reorderEnabled;

    final chips = <Widget>[
      for (var i = 0; i < ordered.length; i++)
        _chip(
          index: i,
          ordered: ordered,
          highlight: highlight,
          style: style,
          useReorderableRow: useReorderableRow,
          canDragReorder: canDragReorder,
        ),
    ];

    final translated = Transform.translate(
      offset: const Offset(0, mediaLibraryCompactTitleOpticalOffset),
      child: SizedBox(
        height: compact ? 32 : 36,
        child: useReorderableRow
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

    if (useReorderableRow) {
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
    required bool useReorderableRow,
    required bool canDragReorder,
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
      trailingGap: index == ordered.length - 1
          ? 0
          : _EntryChip.gapAfter(compact),
      canDragReorder: canDragReorder,
    );
    if (!useReorderableRow) return chip;
    return _ChipReorderDragStartListener(
      key: ValueKey<MediaLibraryRootEntry>(entry),
      index: index,
      enabled: canDragReorder,
      child: chip,
    );
  }

  static Widget _proxyDecorator(
    Widget child,
    int index,
    Animation<double> animation,
  ) {
    // Same lifted size as the press animation, with no second scale-up.
    // Starting another grow here is what made a short click swell, stall,
    // then snap back when the page changed.
    return Transform.scale(
      scale: _kChipPressScale,
      child: child,
    );
  }
}

class _EntryChip extends StatefulWidget {
  const _EntryChip({
    required this.entry,
    required this.selected,
    required this.highlightWeight,
    required this.enabled,
    required this.compact,
    required this.style,
    required this.onSelected,
    required this.trailingGap,
    required this.canDragReorder,
  });

  final MediaLibraryRootEntry entry;
  final bool selected;
  final double highlightWeight;
  final bool enabled;
  final bool compact;
  final TextStyle style;
  final ValueChanged<MediaLibraryRootEntry> onSelected;
  final double trailingGap;
  final bool canDragReorder;

  /// Inner padding is the clickable box. Keep a 4px dead strip between chips
  /// so a slightly larger target cannot select the neighbor.
  static EdgeInsets hitPadding(bool compact) {
    return compact
        ? const EdgeInsets.symmetric(horizontal: 6, vertical: 0)
        : const EdgeInsets.symmetric(horizontal: 8, vertical: 0);
  }

  static double gapAfter(bool compact) => compact ? 4 : 6;

  @override
  State<_EntryChip> createState() => _EntryChipState();
}

const double _kChipPressScale = 1.05;

class _EntryChipState extends State<_EntryChip>
    with SingleTickerProviderStateMixin {
  int? _pointer;
  Offset? _downPosition;
  bool _passedDragSlop = false;
  late final AnimationController _press;
  late final CurvedAnimation _pressCurve;
  late final Animation<double> _pressScale;

  @override
  void initState() {
    super.initState();
    _press = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 140),
      reverseDuration: const Duration(milliseconds: 140),
    );
    _pressCurve = CurvedAnimation(
      parent: _press,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeOutCubic,
    );
    _pressScale = Tween<double>(
      begin: 1,
      end: _kChipPressScale,
    ).animate(_pressCurve);
  }

  bool _isPrimaryPress(PointerDownEvent event) {
    if (event.kind != PointerDeviceKind.mouse) return true;
    return (event.buttons & kPrimaryButton) != 0;
  }

  double _dragSlop(PointerEvent event) {
    return math.max(
      kTouchSlop,
      computeHitSlop(event.kind, MediaQuery.maybeGestureSettingsOf(context)),
    );
  }

  void _select() {
    if (!widget.enabled || widget.selected) return;
    widget.onSelected(widget.entry);
  }

  void _beginPress() {
    if (MediaQuery.disableAnimationsOf(context)) return;
    _press.forward();
  }

  void _endPress() {
    if (_passedDragSlop) return;
    _press.reverse();
  }

  void _onPointerDown(PointerDownEvent event) {
    if (!widget.enabled || widget.selected || !_isPrimaryPress(event)) return;
    _beginPress();
    // No reorder is possible, so a press can switch immediately.
    if (!widget.canDragReorder) {
      _select();
      _endPress();
      return;
    }
    // Reorder uses the same press. Wait until release before switching, and
    // skip the switch once the pointer has moved far enough to reorder.
    _pointer = event.pointer;
    _downPosition = event.position;
    _passedDragSlop = false;
    GestureBinding.instance.pointerRouter.addRoute(
      event.pointer,
      _routePointer,
      event.transform,
    );
  }

  void _routePointer(PointerEvent event) {
    if (event is PointerMoveEvent) {
      _onPointerMove(event);
    } else if (event is PointerUpEvent) {
      _onPointerUp(event);
    } else if (event is PointerCancelEvent) {
      _onPointerCancel(event);
    }
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (event.pointer != _pointer || _downPosition == null || _passedDragSlop) {
      return;
    }
    if ((event.position - _downPosition!).distance > _dragSlop(event)) {
      _passedDragSlop = true;
      // The reorder proxy owns the lift from here. Leaving the press scale
      // running makes the chip swell, stall, then snap when the drag ends.
      _press.reverse();
    }
  }

  void _onPointerUp(PointerUpEvent event) {
    if (event.pointer != _pointer) return;
    final switchOnRelease = !_passedDragSlop;
    _clearPointer();
    if (switchOnRelease) {
      _select();
      _endPress();
    }
  }

  void _onPointerCancel(PointerCancelEvent event) {
    if (event.pointer != _pointer) return;
    _clearPointer();
  }

  void _clearPointer() {
    final pointer = _pointer;
    if (pointer != null) {
      GestureBinding.instance.pointerRouter.removeRoute(pointer, _routePointer);
    }
    _pointer = null;
    _downPosition = null;
    _passedDragSlop = false;
  }

  @override
  void dispose() {
    _clearPointer();
    _pressCurve.dispose();
    _press.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = !widget.enabled
        ? AppTokens.text4
        : Color.lerp(
            AppTokens.text3,
            AppTokens.text1,
            widget.highlightWeight,
          )!;
    // One weight for every chip. Swapping w300 and w500 when a swipe
    // commits changes the glyph color's apparent brightness in one frame,
    // so the highlight looks like it jumps instead of crossfading.
    final canSelect = widget.enabled && !widget.selected;
    return Padding(
      padding: EdgeInsets.only(right: widget.trailingGap),
      child: MouseRegion(
        cursor: widget.canDragReorder
            ? SystemMouseCursors.grab
            : canSelect
            ? SystemMouseCursors.click
            : SystemMouseCursors.basic,
        opaque: true,
        hitTestBehavior: HitTestBehavior.opaque,
        child: Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: canSelect ? _onPointerDown : null,
          child: RepaintBoundary(
            child: ScaleTransition(
              scale: _pressScale,
            child: SizedBox(
              height: widget.compact ? 32 : 36,
              child: Padding(
                padding: _EntryChip.hitPadding(widget.compact),
                child: Column(
                  children: [
                    Expanded(
                      child: Align(
                        alignment: Alignment.center,
                        child: Text(
                          widget.entry.label,
                          maxLines: 1,
                          style: widget.style.copyWith(
                            color: color,
                            fontWeight: widget.enabled
                                ? FontWeight.w500
                                : widget.style.fontWeight,
                          ),
                        ),
                      ),
                    ),
                    Container(
                      height: 2,
                      color: Color.lerp(
                        Colors.transparent,
                        AppTokens.text1,
                        widget.enabled ? widget.highlightWeight : 0,
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
    );
  }
}

/// Drag only after the pointer has actually traveled [_kChipReorderSlop].
///
/// Windows sometimes reports a large move delta on an otherwise still click.
/// Trusting that delta starts a reorder, and the title jumps into a neighbor's
/// slot. The recognizer therefore watches the pointer's position.
class _ChipReorderDragStartListener extends ReorderableDragStartListener {
  const _ChipReorderDragStartListener({
    super.key,
    required super.child,
    required super.index,
    super.enabled,
  });

  @override
  MultiDragGestureRecognizer createRecognizer() {
    return _DragAfterSlopRecognizer(debugOwner: this);
  }
}

/// How far the pointer must really move before a title changes places.
const double _kChipReorderSlop = 36;

class _PointerSample {
  _PointerSample(this.position);
  Offset position;
}

class _DragAfterSlopRecognizer extends MultiDragGestureRecognizer {
  _DragAfterSlopRecognizer({super.debugOwner});

  final Map<int, _PointerSample> _samples = <int, _PointerSample>{};

  @override
  void addAllowedPointer(PointerDownEvent event) {
    _samples[event.pointer] = _PointerSample(event.position);
    GestureBinding.instance.pointerRouter.addRoute(
      event.pointer,
      _trackPosition,
      event.transform,
    );
    super.addAllowedPointer(event);
  }

  void _trackPosition(PointerEvent event) {
    _samples[event.pointer]?.position = event.position;
  }

  @override
  void dispose() {
    for (final pointer in _samples.keys.toList()) {
      GestureBinding.instance.pointerRouter.removeRoute(pointer, _trackPosition);
    }
    _samples.clear();
    super.dispose();
  }

  @override
  MultiDragPointerState createNewPointerState(PointerDownEvent event) {
    final sample = _samples[event.pointer] ?? _PointerSample(event.position);
    return _DragAfterSlopPointerState(
      event.position,
      event.kind,
      gestureSettings,
      positionOf: () => sample.position,
    );
  }

  @override
  String get debugDescription => 'chip drag-after-slop';
}

class _DragAfterSlopPointerState extends MultiDragPointerState {
  _DragAfterSlopPointerState(
    Offset initialPosition,
    PointerDeviceKind kind,
    DeviceGestureSettings? gestureSettings, {
    required this.positionOf,
  }) : super(initialPosition, kind, gestureSettings);

  final Offset Function() positionOf;
  GestureMultiDragStartCallback? _starter;
  bool _claimedArena = false;
  bool _started = false;

  double get _arenaSlop =>
      math.max(kTouchSlop, computeHitSlop(kind, gestureSettings));

  Offset get _travel => positionOf() - initialPosition;

  @override
  void checkForResolutionAfterMove() {
    final travel = _travel;
    final horizontal = travel.dx.abs() >= travel.dy.abs() && travel.dx.abs() > _arenaSlop;
    if (!_claimedArena && horizontal) {
      _claimedArena = true;
      resolve(GestureDisposition.accepted);
    }
    _tryStart();
  }

  @override
  void accepted(GestureMultiDragStartCallback starter) {
    _starter = starter;
    _tryStart();
  }

  void _tryStart() {
    if (_started || _starter == null) return;
    final travel = _travel;
    if (travel.dx.abs() < _kChipReorderSlop) return;
    if (travel.dx.abs() < travel.dy.abs()) return;
    _started = true;
    _starter!(initialPosition);
  }
}

