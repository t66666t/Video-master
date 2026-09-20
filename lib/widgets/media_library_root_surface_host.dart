import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../models/media_library_root_entry.dart';
import '../models/media_library_root_entry_order.dart';
import '../models/media_library_root_swipe_policy.dart';

/// Builds one root surface. [isActive] is true only for the painted entry.
typedef MediaLibraryRootSurfaceBuilder =
    Widget Function(BuildContext context, bool isActive);

/// Duration of the incoming-library fade. Short enough to feel snappy on
/// desktop, long enough that a prepared grid is not a hard cut.
const Duration kMediaLibraryRootFadeDuration = Duration(milliseconds: 140);

const Duration kMediaLibraryRootSwipeSnapDuration = Duration(milliseconds: 240);

/// Keeps visited 继续学习 / 最近添加 / 文件夹 trees without paging.
///
/// A chip tap must not layout the destination on the same frame: Windows
/// would hitch, then hard-cut. The outgoing page stays painted, the incoming
/// page warms (layout, no paint) on the next frame, then fades in.
///
/// Touch/stylus may also slide to an adjacent tab. Mouse and trackpad cannot:
/// they would fight box-select, file drops, and scrolling.
class MediaLibraryRootSurfaceHost extends StatefulWidget {
  const MediaLibraryRootSurfaceHost({
    super.key,
    required this.displayedEntry,
    required this.continueBuilder,
    required this.recentBuilder,
    required this.foldersBuilder,
    this.onUserSwipe,
    this.swipeEnabled = true,
    this.swipeHighlightIndex,
    this.swipeSettled,
    this.entryOrder = MediaLibraryRootEntryOrder.defaults,
  });

  final MediaLibraryRootEntry displayedEntry;
  final MediaLibraryRootSurfaceBuilder continueBuilder;
  final MediaLibraryRootSurfaceBuilder recentBuilder;
  final MediaLibraryRootSurfaceBuilder foldersBuilder;

  /// Fired after an interactive swipe commits, so the chip and prefs match.
  final ValueChanged<MediaLibraryRootEntry>? onUserSwipe;
  final bool swipeEnabled;

  /// Fractional chip index while the finger (or snap) is moving. The app
  /// bar listens without rebuilding the library grids.
  final ValueNotifier<double>? swipeHighlightIndex;

  /// True only when a full page is parked (no swipe/fade in flight).
  final ValueNotifier<bool>? swipeSettled;

  /// Chip/swipe order. Changing this must not rebuild parked grids.
  final List<MediaLibraryRootEntry> entryOrder;

  @override
  State<MediaLibraryRootSurfaceHost> createState() =>
      _MediaLibraryRootSurfaceHostState();
}

class _MediaLibraryRootSurfaceHostState extends State<MediaLibraryRootSurfaceHost>
    with TickerProviderStateMixin {
  final Set<MediaLibraryRootEntry> _visited = <MediaLibraryRootEntry>{};
  late MediaLibraryRootEntry _paintedEntry;
  MediaLibraryRootEntry? _warmingEntry;
  MediaLibraryRootEntry? _fadingOutEntry;
  late final AnimationController _fade;
  late final AnimationController _snap;
  late final Animation<double> _snapCurve;
  int _switchGeneration = 0;

  /// Finger offset. A [ValueNotifier] so layers can slide without setState
  /// on the parked grids.
  final ValueNotifier<double> _dragDx = ValueNotifier<double>(0);
  MediaLibraryRootEntry? _dragTarget;
  bool _dragging = false;
  bool _incomingNeedsLiveLayout = false;
  double _lastWidth = 0;
  VoidCallback? _snapTick;

  @override
  void initState() {
    super.initState();
    _paintedEntry = widget.displayedEntry;
    _visited.add(_paintedEntry);
    _fade = AnimationController(
      vsync: this,
      duration: kMediaLibraryRootFadeDuration,
      value: 1,
    );
    _fade.addStatusListener(_onFadeStatus);
    _snap = AnimationController(
      vsync: this,
      duration: kMediaLibraryRootSwipeSnapDuration,
    );
    _snapCurve = CurvedAnimation(parent: _snap, curve: Curves.easeOutCubic);
    _publishHighlight();
    _publishSettled();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final disable = MediaQuery.disableAnimationsOf(context);
    _fade.duration = disable ? Duration.zero : kMediaLibraryRootFadeDuration;
    _snap.duration = disable
        ? Duration.zero
        : kMediaLibraryRootSwipeSnapDuration;
  }

  @override
  void didUpdateWidget(covariant MediaLibraryRootSurfaceHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.swipeHighlightIndex != widget.swipeHighlightIndex ||
        !listEquals(oldWidget.entryOrder, widget.entryOrder)) {
      _publishHighlight();
    }
    if (oldWidget.swipeSettled != widget.swipeSettled) {
      _publishSettled();
    }
    if (oldWidget.displayedEntry == widget.displayedEntry) return;
    if (widget.displayedEntry == _paintedEntry) {
      _publishHighlight();
      return;
    }
    _cancelDrag(snap: false);
    _requestSwitch(widget.displayedEntry);
  }

  void _onFadeStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed || !mounted) return;
    if (_fadingOutEntry == null) {
      _publishSettled();
      return;
    }
    setState(() => _fadingOutEntry = null);
    _publishSettled();
  }

  void _requestSwitch(MediaLibraryRootEntry next) {
    if (next == _paintedEntry && _warmingEntry == null) return;
    final generation = ++_switchGeneration;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || generation != _switchGeneration) return;
      if (widget.displayedEntry != next) return;
      final firstVisit = !_visited.contains(next);
      setState(() {
        _visited.add(next);
        if (firstVisit) {
          _warmingEntry = next;
        } else {
          _commit(next);
        }
      });
      _publishSettled();
      if (!firstVisit) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || generation != _switchGeneration) return;
        if (widget.displayedEntry != next) return;
        setState(() => _commit(next));
      });
    });
  }

  void _commit(MediaLibraryRootEntry next) {
    if (next == _paintedEntry) {
      _warmingEntry = null;
      return;
    }
    _fadingOutEntry = _paintedEntry;
    _paintedEntry = next;
    _warmingEntry = null;
    _fade.forward(from: 0);
    _publishSettled();
  }

  double _hostWidth() {
    final box = context.findRenderObject() as RenderBox?;
    final fromBox = box?.size.width ?? 0;
    return fromBox > 0 ? fromBox : _lastWidth;
  }

  void _setDx(double value) {
    if (_dragDx.value != value) {
      _dragDx.value = value;
    }
    _publishHighlight();
    _publishSettled();
  }

  void _publishHighlight() {
    final notifier = widget.swipeHighlightIndex;
    if (notifier == null) return;
    notifier.value = MediaLibraryRootSwipePolicy.highlightIndex(
      current: _paintedEntry,
      dragDx: _dragDx.value,
      width: _hostWidth(),
      order: widget.entryOrder,
    );
  }

  void _publishSettled() {
    final notifier = widget.swipeSettled;
    if (notifier == null) return;
    notifier.value =
        !_dragging &&
        _dragDx.value.abs() < 0.5 &&
        _warmingEntry == null &&
        (_fadingOutEntry == null || _fade.value >= 1);
  }

  void _onSwipeStart(DragStartDetails details) {
    if (_dragging) return;
    _snap.stop();
    _clearSnapTick();
    _setDx(0);
    setState(() {
      _dragging = true;
      _dragTarget = null;
      _incomingNeedsLiveLayout = false;
      _fadingOutEntry = null;
      _fade.value = 1;
    });
    _publishSettled();
  }

  void _onSwipeUpdate(DragUpdateDetails details) {
    if (!_dragging) return;
    final width = _hostWidth();
    final tentative = _dragDx.value + details.delta.dx;
    final neighbor = MediaLibraryRootSwipePolicy.neighbor(
      current: _paintedEntry,
      dx: tentative,
      order: widget.entryOrder,
    );
    final clamped = MediaLibraryRootSwipePolicy.clampDrag(
      dx: tentative,
      width: width,
      hasNeighbor: neighbor != null,
    );
    if (neighbor != _dragTarget) {
      final firstVisit = neighbor != null && !_visited.contains(neighbor);
      setState(() {
        _dragTarget = neighbor;
        if (neighbor != null) _visited.add(neighbor);
        _incomingNeedsLiveLayout = firstVisit;
      });
      if (firstVisit) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || !_dragging) return;
          if (!_incomingNeedsLiveLayout) return;
          setState(() => _incomingNeedsLiveLayout = false);
        });
      }
    }
    _setDx(clamped);
  }

  void _onSwipeEnd(DragEndDetails details) {
    if (!_dragging) return;
    final width = _hostWidth();
    final target = _dragTarget;
    final velocity = details.velocity.pixelsPerSecond.dx;
    final commit =
        target != null &&
        MediaLibraryRootSwipePolicy.shouldCommit(
          dragDx: _dragDx.value,
          width: width,
          velocityDx: velocity,
        );
    if (commit) {
      final end = _dragDx.value < 0 ? -width : width;
      _animateDragTo(end, () => _finishSwipe(target));
      return;
    }
    _animateDragTo(0, () {
      if (!mounted) return;
      setState(() {
        _dragging = false;
        _dragTarget = null;
        _incomingNeedsLiveLayout = false;
        if (_warmingEntry != _paintedEntry) {
          _warmingEntry = null;
        }
      });
      _setDx(0);
    });
  }

  void _cancelDrag({required bool snap}) {
    if (!_dragging && _dragDx.value == 0) return;
    if (!snap) {
      _clearSnapTick();
      _snap.stop();
      _dragging = false;
      _dragTarget = null;
      _incomingNeedsLiveLayout = false;
      _setDx(0);
      return;
    }
    _animateDragTo(0, () {
      if (!mounted) return;
      setState(() {
        _dragging = false;
        _dragTarget = null;
        _incomingNeedsLiveLayout = false;
      });
      _setDx(0);
    });
  }

  void _onSwipeCancel() => _cancelDrag(snap: true);

  void _clearSnapTick() {
    if (_snapTick == null) return;
    _snap.removeListener(_snapTick!);
    _snapTick = null;
  }

  void _animateDragTo(double end, VoidCallback onDone) {
    _clearSnapTick();
    final start = _dragDx.value;
    late final VoidCallback tick;
    tick = () {
      if (!mounted) return;
      _setDx(start + (end - start) * _snapCurve.value);
    };
    _snapTick = tick;
    _snap.addListener(tick);
    _snap.forward(from: 0).whenComplete(() {
      _clearSnapTick();
      onDone();
    });
  }

  void _finishSwipe(MediaLibraryRootEntry next) {
    _paintedEntry = next;
    _warmingEntry = null;
    _fadingOutEntry = null;
    _dragging = false;
    _dragTarget = null;
    _incomingNeedsLiveLayout = false;
    _fade.value = 1;
    _switchGeneration++;
    _setDx(0);
    widget.onUserSwipe?.call(next);
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _clearSnapTick();
    _fade.removeStatusListener(_onFadeStatus);
    _fade.dispose();
    _snap.dispose();
    _dragDx.dispose();
    super.dispose();
  }

  List<MediaLibraryRootEntry> get _paintOrder {
    final below = <MediaLibraryRootEntry>[];
    for (final entry in MediaLibraryRootEntry.values) {
      if (!_visited.contains(entry) || entry == _paintedEntry) continue;
      below.add(entry);
    }
    if (_visited.contains(_paintedEntry)) below.add(_paintedEntry);
    return below;
  }

  MediaLibraryRootSurfaceBuilder _builderFor(MediaLibraryRootEntry entry) {
    return switch (entry) {
      MediaLibraryRootEntry.continueLearning => widget.continueBuilder,
      MediaLibraryRootEntry.recent => widget.recentBuilder,
      MediaLibraryRootEntry.folders => widget.foldersBuilder,
    };
  }

  double _offsetFor(MediaLibraryRootEntry entry, double dx, double width) {
    if (dx == 0 && !_dragging) return 0;
    if (entry == _paintedEntry) return dx;
    if (entry == _dragTarget) {
      return dx < 0 ? dx + width : dx - width;
    }
    return 0;
  }

  bool _entryActive(MediaLibraryRootEntry entry) {
    if (_dragging) {
      return _incomingNeedsLiveLayout && entry == _dragTarget;
    }
    return entry == _paintedEntry || entry == _warmingEntry;
  }

  Map<Type, GestureRecognizerFactory> _swipeGestures() {
    if (!widget.swipeEnabled) return const {};
    return {
      MediaLibraryRootSwipeRecognizer:
          GestureRecognizerFactoryWithHandlers<MediaLibraryRootSwipeRecognizer>(
            () => MediaLibraryRootSwipeRecognizer(widthOf: _hostWidth),
            (recognizer) {
              recognizer
                ..onStart = _onSwipeStart
                ..onUpdate = _onSwipeUpdate
                ..onEnd = _onSwipeEnd
                ..onCancel = _onSwipeCancel;
            },
          ),
    };
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        _lastWidth = constraints.maxWidth;
        return RawGestureDetector(
          behavior: HitTestBehavior.translucent,
          gestures: _swipeGestures(),
          child: Stack(
            fit: StackFit.expand,
            children: [
              for (final entry in _paintOrder)
                _FollowFingerSlide(
                  key: ValueKey<MediaLibraryRootEntry>(entry),
                  dx: _dragDx,
                  offsetFor: (dx) => _offsetFor(entry, dx, _lastWidth),
                  child: _ParkedRootSurface(
                    allowLayout:
                        entry == _paintedEntry ||
                        entry == _warmingEntry ||
                        entry == _dragTarget,
                    allowPaint:
                        entry == _paintedEntry ||
                        entry == _fadingOutEntry ||
                        entry == _dragTarget,
                    allowHit: !_dragging && entry == _paintedEntry,
                    fade:
                        (!_dragging &&
                            _dragDx.value == 0 &&
                            entry == _paintedEntry)
                        ? _fade
                        : null,
                    active: _entryActive(entry),
                    builder: _builderFor(entry),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// Translates one parked surface from a [ValueNotifier] so pointer moves
/// do not rebuild the grid underneath.
class _FollowFingerSlide extends StatelessWidget {
  const _FollowFingerSlide({
    super.key,
    required this.dx,
    required this.offsetFor,
    required this.child,
  });

  final ValueListenable<double> dx;
  final double Function(double dx) offsetFor;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: dx,
      child: child,
      builder: (context, child) {
        return Transform.translate(
          offset: Offset(offsetFor(dx.value), 0),
          filterQuality: FilterQuality.none,
          child: child,
        );
      },
    );
  }
}

/// Touch/stylus horizontal drag that ignores mouse, trackpad, and back-edge
/// starts so it cannot steal box-select or system back.
class MediaLibraryRootSwipeRecognizer extends HorizontalDragGestureRecognizer {
  MediaLibraryRootSwipeRecognizer({required this.widthOf})
    : super(
        supportedDevices: const {
          PointerDeviceKind.touch,
          PointerDeviceKind.stylus,
        },
      );

  final double Function() widthOf;

  @override
  void addAllowedPointer(PointerDownEvent event) {
    if (!MediaLibraryRootSwipePolicy.isEligiblePointer(event.kind)) return;
    if (!MediaLibraryRootSwipePolicy.isAwayFromSystemEdges(
      localX: event.localPosition.dx,
      width: widthOf(),
    )) {
      return;
    }
    super.addAllowedPointer(event);
  }
}

/// Calls [builder] for the first frame, while visible, and once when hiding.
/// Hidden frames reuse the last widget so a parent rebuild cannot walk the grid.
class _ParkedRootSurface extends StatefulWidget {
  const _ParkedRootSurface({
    required this.allowLayout,
    required this.allowPaint,
    required this.allowHit,
    required this.fade,
    required this.active,
    required this.builder,
  });

  final bool allowLayout;
  final bool allowPaint;
  final bool allowHit;
  final Animation<double>? fade;
  final bool active;
  final MediaLibraryRootSurfaceBuilder builder;

  @override
  State<_ParkedRootSurface> createState() => _ParkedRootSurfaceState();
}

class _ParkedRootSurfaceState extends State<_ParkedRootSurface> {
  Widget? _child;
  bool _wasActive = true;

  @override
  Widget build(BuildContext context) {
    final activeChanged = _child == null || _wasActive != widget.active;
    if (widget.active || activeChanged) {
      _child = widget.builder(context, widget.active);
    }
    _wasActive = widget.active;
    return _InactiveLayoutGate(
      allowLayout: widget.allowLayout,
      allowPaint: widget.allowPaint,
      allowHit: widget.allowHit,
      fade: widget.fade,
      child: TickerMode(
        enabled: widget.active,
        child: ExcludeFocus(
          excluding: !widget.active,
          child: RepaintBoundary(child: _child!),
        ),
      ),
    );
  }
}

/// Occupies the stack slot. Layout and paint are independently gated so an
/// incoming library can warm without replacing the outgoing pixels yet.
class _InactiveLayoutGate extends SingleChildRenderObjectWidget {
  const _InactiveLayoutGate({
    required this.allowLayout,
    required this.allowPaint,
    required this.allowHit,
    required this.fade,
    required super.child,
  });

  final bool allowLayout;
  final bool allowPaint;
  final bool allowHit;
  final Animation<double>? fade;

  @override
  RenderObject createRenderObject(BuildContext context) {
    return _RenderInactiveLayoutGate(
      allowLayout: allowLayout,
      allowPaint: allowPaint,
      allowHit: allowHit,
      fade: fade,
    );
  }

  @override
  void updateRenderObject(
    BuildContext context,
    covariant _RenderInactiveLayoutGate renderObject,
  ) {
    renderObject
      ..allowLayout = allowLayout
      ..allowPaint = allowPaint
      ..allowHit = allowHit
      ..fade = fade;
  }
}

class _RenderInactiveLayoutGate extends RenderProxyBox {
  _RenderInactiveLayoutGate({
    required bool allowLayout,
    required bool allowPaint,
    required bool allowHit,
    required Animation<double>? fade,
  }) : _allowLayout = allowLayout,
       _allowPaint = allowPaint,
       _allowHit = allowHit,
       _fade = fade;

  bool _allowLayout;
  bool _allowPaint;
  bool _allowHit;
  Animation<double>? _fade;

  set allowLayout(bool value) {
    if (_allowLayout == value) return;
    _allowLayout = value;
    markNeedsLayout();
  }

  set allowPaint(bool value) {
    if (_allowPaint == value) return;
    _allowPaint = value;
    markNeedsPaint();
    markNeedsSemanticsUpdate();
  }

  set allowHit(bool value) {
    if (_allowHit == value) return;
    _allowHit = value;
  }

  set fade(Animation<double>? value) {
    if (identical(_fade, value)) return;
    if (attached) _fade?.removeListener(_onFade);
    _fade = value;
    if (attached) _fade?.addListener(_onFade);
    markNeedsPaint();
  }

  void _onFade() => markNeedsPaint();

  double get _opacity => _fade?.value ?? 1;

  @override
  bool get isRepaintBoundary => true;

  @override
  void detach() {
    _fade?.removeListener(_onFade);
    super.detach();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _fade?.addListener(_onFade);
  }

  @override
  void performLayout() {
    size = constraints.biggest;
    final child = this.child;
    if (child == null) return;
    if (!_allowLayout && !child.debugNeedsLayout) return;
    child.layout(constraints, parentUsesSize: false);
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (!_allowPaint || child == null) return;
    final opacity = _opacity;
    if (opacity <= 0) return;
    if (opacity >= 1) {
      super.paint(context, offset);
      return;
    }
    context.pushOpacity(offset, (255 * opacity).round(), super.paint);
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    if (!_allowHit || !_allowPaint || _opacity <= 0) return false;
    return super.hitTestChildren(result, position: position);
  }

  @override
  void visitChildrenForSemantics(RenderObjectVisitor visitor) {
    if (_allowPaint) super.visitChildrenForSemantics(visitor);
  }
}

/// Reuses the last child instance while inactive so a parent rebuild cannot
/// walk a full thumbnail grid that is not on screen.
class MediaLibraryFrozenWhenInactive extends StatefulWidget {
  const MediaLibraryFrozenWhenInactive({
    super.key,
    required this.active,
    required this.child,
  });

  final bool active;
  final Widget child;

  @override
  State<MediaLibraryFrozenWhenInactive> createState() =>
      _MediaLibraryFrozenWhenInactiveState();
}

class _MediaLibraryFrozenWhenInactiveState
    extends State<MediaLibraryFrozenWhenInactive> {
  Widget? _frozen;

  @override
  Widget build(BuildContext context) {
    if (widget.active) {
      _frozen = widget.child;
      return widget.child;
    }
    return _frozen ?? widget.child;
  }
}
