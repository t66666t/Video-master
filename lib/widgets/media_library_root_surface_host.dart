import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../models/media_library_root_entry.dart';
import '../models/media_library_root_entry_order.dart';
import '../models/media_library_root_swipe_policy.dart';
import '../theme/app_tokens.dart';

/// Builds one root surface. [isActive] is true only for the painted entry.
typedef MediaLibraryRootSurfaceBuilder =
    Widget Function(BuildContext context, bool isActive);

/// Incoming-library fade. Alpha changes on the composited layer only.
const Duration kMediaLibraryRootFadeDuration = Duration(milliseconds: 150);

/// Idle gap before the other two root pages are laid out off the tap path.
const Duration kMediaLibraryRootPrewarmDelay = Duration(milliseconds: 450);

const Duration kMediaLibraryRootSwipeSnapDuration = Duration(milliseconds: 280);

/// Keeps visited 继续学习 / 最近添加 / 文件夹 trees without paging.
///
/// A cold page is laid out, then painted under the current page, and only
/// then faded. The fade itself never repaints the grid: it rewrites the
/// layer alpha. Visited pages stay in that layer so the next tap does not
/// lay them out again. The other pages are prewarmed once the first frame
/// has settled, so the first tap is already on the warm path.
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

class _MediaLibraryRootSurfaceHostState
    extends State<MediaLibraryRootSurfaceHost>
    with TickerProviderStateMixin {
  final Set<MediaLibraryRootEntry> _visited = <MediaLibraryRootEntry>{};
  final Set<MediaLibraryRootEntry> _rasterReady = <MediaLibraryRootEntry>{};
  final Map<MediaLibraryRootEntry, ValueNotifier<double>> _opacity = {
    for (final entry in MediaLibraryRootEntry.values)
      entry: ValueNotifier<double>(0),
  };
  late MediaLibraryRootEntry _paintedEntry;
  MediaLibraryRootEntry? _warmingEntry;
  MediaLibraryRootEntry? _fadingOutEntry;
  MediaLibraryRootEntry? _fadingInEntry;
  late final AnimationController _fade;
  late final AnimationController _snap;
  late final Animation<double> _snapCurve;
  int _switchGeneration = 0;
  int _prewarmGeneration = 0;
  int _snapGeneration = 0;
  Timer? _prewarmTimer;

  /// Finger offset. A [ValueNotifier] so layers can slide without setState
  /// on the parked grids.
  final ValueNotifier<double> _dragDx = ValueNotifier<double>(0);

  /// True only while a snap animation is playing. A live finger uses the
  /// cheaper unfiltered transform so a sudden reverse does not re-rasterize.
  final ValueNotifier<bool> _settling = ValueNotifier<bool>(false);
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
    _rasterReady.add(_paintedEntry);
    _opacity[_paintedEntry]!.value = 1;
    _fade = AnimationController(
      vsync: this,
      duration: kMediaLibraryRootFadeDuration,
      value: 1,
    );
    _fade.addListener(_onFadeTick);
    _fade.addStatusListener(_onFadeStatus);
    _prewarmTimer = Timer(kMediaLibraryRootPrewarmDelay, _prewarmNext);
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
    if (widget.displayedEntry == _paintedEntry && _fadingInEntry == null) {
      _publishHighlight();
      return;
    }
    _cancelDrag(snap: false);
    _prewarmGeneration++;
    final next = widget.displayedEntry;
    if (_rasterReady.contains(next)) {
      _switchGeneration++;
      _commit(next);
      return;
    }
    _requestSwitch(next);
  }

  void _onFadeTick() {
    final incoming = _fadingInEntry;
    if (incoming == null) return;
    final t = _fade.value;
    final inNotifier = _opacity[incoming]!;
    if (inNotifier.value != t) inNotifier.value = t;
    final outgoing = _fadingOutEntry;
    if (outgoing == null || outgoing == incoming) return;
    final out = 1 - t;
    final outNotifier = _opacity[outgoing]!;
    if (outNotifier.value != out) outNotifier.value = out;
  }

  void _onFadeStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed || !mounted) return;
    final incoming = _fadingInEntry;
    final outgoing = _fadingOutEntry;
    if (incoming != null && _opacity[incoming]!.value != 1) {
      _opacity[incoming]!.value = 1;
    }
    if (outgoing != null &&
        outgoing != incoming &&
        _opacity[outgoing]!.value != 0) {
      _opacity[outgoing]!.value = 0;
    }
    _fadingInEntry = null;
    _fadingOutEntry = null;
    _publishSettled();
    _schedulePrewarm();
  }

  bool _switchStillCurrent(int generation, MediaLibraryRootEntry next) {
    return mounted &&
        generation == _switchGeneration &&
        widget.displayedEntry == next;
  }

  /// Layout, then one covered paint, then [onReady]. A page that already has
  /// a layer skips both and starts the fade on this frame.
  void _prepareLayer(
    MediaLibraryRootEntry entry, {
    required bool Function() live,
    required VoidCallback onReady,
  }) {
    if (_rasterReady.contains(entry)) {
      onReady();
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!live()) return;
      setState(() {
        _visited.add(entry);
        _warmingEntry = entry;
      });
      _publishSettled();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!live()) return;
        setState(() {
          _rasterReady.add(entry);
          if (_warmingEntry == entry) _warmingEntry = null;
        });
        _publishSettled();
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!live()) return;
          onReady();
        });
      });
    });
  }

  void _requestSwitch(MediaLibraryRootEntry next) {
    if (next == _paintedEntry && _warmingEntry == null) return;
    final generation = ++_switchGeneration;
    _prepareLayer(
      next,
      live: () => _switchStillCurrent(generation, next),
      onReady: () {
        if (!_switchStillCurrent(generation, next)) return;
        setState(() => _commit(next));
      },
    );
  }

  void _schedulePrewarm() {
    _prewarmTimer?.cancel();
    if (_rasterReady.length >= MediaLibraryRootEntry.values.length) return;
    _prewarmTimer = Timer(kMediaLibraryRootPrewarmDelay, _prewarmNext);
  }

  void _prewarmNext() {
    if (!mounted ||
        _dragging ||
        _warmingEntry != null ||
        _fadingInEntry != null) {
      if (mounted) _schedulePrewarm();
      return;
    }
    MediaLibraryRootEntry? pending;
    for (final entry in widget.entryOrder) {
      if (!_rasterReady.contains(entry)) {
        pending = entry;
        break;
      }
    }
    if (pending == null) return;
    final entry = pending;
    final generation = ++_prewarmGeneration;
    _prepareLayer(
      entry,
      live: () =>
          mounted &&
          generation == _prewarmGeneration &&
          !_dragging &&
          _fadingInEntry == null,
      onReady: () {
        if (!mounted || generation != _prewarmGeneration) return;
        if (entry != _paintedEntry && entry != _fadingOutEntry) {
          _opacity[entry]!.value = 0;
        }
        _schedulePrewarm();
      },
    );
  }

  void _commit(MediaLibraryRootEntry next) {
    if (next == _paintedEntry) {
      _warmingEntry = null;
      return;
    }
    final previous = _paintedEntry;
    _fadingOutEntry = previous;
    _paintedEntry = next;
    _warmingEntry = null;
    _fadingInEntry = next;
    if (_opacity[previous]!.value != 1) {
      _opacity[previous]!.value = 1;
    }
    for (final entry in MediaLibraryRootEntry.values) {
      if (entry == next || entry == previous) continue;
      if (_opacity[entry]!.value != 0) _opacity[entry]!.value = 0;
    }
    final target = widget.entryOrder.indexOf(next).toDouble();
    if (target >= 0) {
      widget.swipeHighlightIndex?.value = target;
    }
    _opacity[next]!.value = 0;
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
        !_dragging && _dragDx.value.abs() < 0.5 && _warmingEntry == null;
  }

  void _onSwipeStart(DragStartDetails details) {
    final handoff = _dragging;
    _abortSnap();
    _fadingInEntry = null;
    if (_opacity[_paintedEntry]!.value != 1) {
      _opacity[_paintedEntry]!.value = 1;
    }
    // A reverse swipe during the snap keeps the page where it is and follows
    // the finger. Jumping to the destination, or ignoring the finger until
    // the snap ends, is the hitch.
    if (handoff) {
      _publishSettled();
      return;
    }
    setState(() {
      _dragging = true;
      _dragTarget = null;
      _incomingNeedsLiveLayout = false;
      _fadingOutEntry = null;
      _fade.value = 1;
    });
    _setDx(0);
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
    _showDragNeighbor(neighbor);
    _setDx(clamped);
  }

  /// Keeps the page beside the finger in sync while a snap crosses zero.
  /// A reverse flick animates through the current page onto the other side.
  void _showDragNeighbor(MediaLibraryRootEntry? neighbor) {
    if (neighbor == _dragTarget) return;
    final firstVisit = neighbor != null && !_rasterReady.contains(neighbor);
    final previousTarget = _dragTarget;
    if (previousTarget != null &&
        previousTarget != _paintedEntry &&
        previousTarget != neighbor) {
      _opacity[previousTarget]!.value = 0;
    }
    if (neighbor != null) _opacity[neighbor]!.value = 1;
    _dragTarget = neighbor;
    if (neighbor != null) {
      _visited.add(neighbor);
      if (!firstVisit) _rasterReady.add(neighbor);
    }
    _incomingNeedsLiveLayout = firstVisit;
    // A page that is already painted only changes offset and alpha.
    // setState here relayouts the grids and is the stall on a reverse.
    if (firstVisit) {
      setState(() {});
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_dragging) return;
        if (!_incomingNeedsLiveLayout) return;
        final shown = _dragTarget;
        setState(() {
          _incomingNeedsLiveLayout = false;
          if (shown != null) _rasterReady.add(shown);
        });
      });
    }
  }

  void _onSwipeEnd(DragEndDetails details) {
    if (!_dragging) return;
    final width = _hostWidth();
    final velocity = details.velocity.pixelsPerSecond.dx;
    final target = MediaLibraryRootSwipePolicy.settleTarget(
      current: _paintedEntry,
      dragDx: _dragDx.value,
      width: width,
      velocityDx: velocity,
      order: widget.entryOrder,
    );
    if (target != null) {
      final from = widget.entryOrder.indexOf(_paintedEntry);
      final to = widget.entryOrder.indexOf(target);
      final end = to > from ? -width : width;
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
      _hideParkedPages();
      _setDx(0);
    });
  }

  void _hideParkedPages() {
    for (final entry in MediaLibraryRootEntry.values) {
      if (entry == _paintedEntry || entry == _fadingOutEntry) continue;
      if (_opacity[entry]!.value != 0) _opacity[entry]!.value = 0;
    }
  }

  void _cancelDrag({required bool snap}) {
    if (!_dragging && _dragDx.value == 0) return;
    if (!snap) {
      _abortSnap();
      _dragging = false;
      _dragTarget = null;
      _incomingNeedsLiveLayout = false;
      _hideParkedPages();
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

  void _abortSnap() {
    _snapGeneration++;
    _clearSnapTick();
    _settling.value = false;
    if (_snap.isAnimating) _snap.stop();
  }

  void _animateDragTo(double end, VoidCallback onDone) {
    _clearSnapTick();
    final generation = ++_snapGeneration;
    final start = _dragDx.value;
    final width = _hostWidth() <= 1 ? 1.0 : _hostWidth();
    final fraction = ((end - start).abs() / width).clamp(0.18, 1.0);
    final reduceMotion = mounted && MediaQuery.disableAnimationsOf(context);
    _snap.duration = reduceMotion
        ? Duration.zero
        : Duration(milliseconds: (160 + 180 * fraction).round());
    _settling.value = !reduceMotion;
    late final VoidCallback tick;
    tick = () {
      if (!mounted || generation != _snapGeneration) return;
      final dx = start + (end - start) * _snapCurve.value;
      _showDragNeighbor(
        MediaLibraryRootSwipePolicy.neighbor(
          current: _paintedEntry,
          dx: dx,
          order: widget.entryOrder,
        ),
      );
      _setDx(dx);
    };
    _snapTick = tick;
    _snap.addListener(tick);
    _snap.forward(from: 0).whenComplete(() {
      if (generation != _snapGeneration) return;
      _settling.value = false;
      _clearSnapTick();
      onDone();
    });
  }

  void _finishSwipe(MediaLibraryRootEntry next) {
    _paintedEntry = next;
    _warmingEntry = null;
    _fadingOutEntry = null;
    _fadingInEntry = null;
    _dragging = false;
    _dragTarget = null;
    _incomingNeedsLiveLayout = false;
    _visited.add(next);
    _rasterReady.add(next);
    _fade.value = 1;
    for (final entry in MediaLibraryRootEntry.values) {
      _opacity[entry]!.value = entry == next ? 1 : 0;
    }
    _switchGeneration++;
    _prewarmGeneration++;
    _setDx(0);
    widget.onUserSwipe?.call(next);
    if (mounted) setState(() {});
    _schedulePrewarm();
  }

  @override
  void dispose() {
    _prewarmTimer?.cancel();
    _clearSnapTick();
    _fade.removeListener(_onFadeTick);
    _fade.removeStatusListener(_onFadeStatus);
    _fade.dispose();
    _snap.dispose();
    _dragDx.dispose();
    _settling.dispose();
    for (final notifier in _opacity.values) {
      notifier.dispose();
    }
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
                  settling: _settling,
                  offsetFor: (dx) => _offsetFor(entry, dx, _lastWidth),
                  child: _ParkedRootSurface(
                    allowLayout:
                        _visited.contains(entry) ||
                        entry == _warmingEntry ||
                        entry == _dragTarget,
                    allowPaint:
                        _rasterReady.contains(entry) ||
                        entry == _paintedEntry ||
                        entry == _dragTarget,
                    allowHit: !_dragging && entry == _paintedEntry,
                    opacity: _opacity[entry]!,
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
    required this.settling,
    required this.offsetFor,
    required this.child,
  });

  final ValueListenable<double> dx;
  final ValueListenable<bool> settling;
  final double Function(double dx) offsetFor;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[dx, settling]),
      child: child,
      builder: (context, child) {
        final offset = offsetFor(dx.value);
        return Transform.translate(
          offset: Offset(offset, 0),
          // A live finger stays unfiltered. Filtering the whole library on
          // every move re-rasters when the finger reverses.
          filterQuality: settling.value && offset != 0
              ? FilterQuality.low
              : FilterQuality.none,
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
    required this.opacity,
    required this.active,
    required this.builder,
  });

  final bool allowLayout;
  final bool allowPaint;
  final bool allowHit;
  final ValueListenable<double> opacity;
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
      opacity: widget.opacity,
      child: TickerMode(
        enabled: widget.active,
        child: ExcludeFocus(
          excluding: !widget.active,
          child: RepaintBoundary(
            child: ColoredBox(color: AppTokens.bgBase, child: _child!),
          ),
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
    required this.opacity,
    required super.child,
  });

  final bool allowLayout;
  final bool allowPaint;
  final bool allowHit;
  final ValueListenable<double> opacity;

  @override
  RenderObject createRenderObject(BuildContext context) {
    return _RenderInactiveLayoutGate(
      allowLayout: allowLayout,
      allowPaint: allowPaint,
      allowHit: allowHit,
      opacity: opacity,
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
      ..opacity = opacity;
  }
}

class _RenderInactiveLayoutGate extends RenderProxyBox {
  _RenderInactiveLayoutGate({
    required bool allowLayout,
    required bool allowPaint,
    required bool allowHit,
    required ValueListenable<double> opacity,
  }) : _allowLayout = allowLayout,
       _allowPaint = allowPaint,
       _allowHit = allowHit,
       _opacity = opacity;

  bool _allowLayout;
  bool _allowPaint;
  bool _allowHit;
  ValueListenable<double> _opacity;
  bool _pictureReady = false;

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

  set opacity(ValueListenable<double> value) {
    if (identical(_opacity, value)) return;
    if (attached) _opacity.removeListener(_onOpacity);
    _opacity = value;
    if (attached) _opacity.addListener(_onOpacity);
    _syncAlpha(forcePaint: !_pictureReady);
  }

  int _lastAlpha = -1;

  void _onOpacity() => _syncAlpha(forcePaint: false);

  void _syncAlpha({required bool forcePaint}) {
    final alpha = _compositedAlpha;
    if (alpha == _lastAlpha && !forcePaint) return;
    _lastAlpha = alpha;
    markNeedsSemanticsUpdate();
    if (forcePaint || !_pictureReady) {
      markNeedsPaint();
      return;
    }
    // The grid picture is already in the layer. Never repaint it to change
    // alpha, including the 0 and 255 endpoints.
    markNeedsCompositedLayerUpdate();
  }

  int get _compositedAlpha {
    final raw = _opacity.value;
    if (raw <= 0) return 0;
    if (raw >= 1) return 255;
    return (255 * raw).round();
  }

  @override
  bool get isRepaintBoundary => true;

  @override
  OffsetLayer updateCompositedLayer({
    required covariant OpacityLayer? oldLayer,
  }) {
    final layer = oldLayer ?? OpacityLayer();
    layer.alpha = _compositedAlpha;
    return layer;
  }

  @override
  void detach() {
    _opacity.removeListener(_onOpacity);
    super.detach();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _opacity.addListener(_onOpacity);
    _lastAlpha = _compositedAlpha;
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
    // Record the grid even at alpha 0 so later ticks only rewrite the layer.
    super.paint(context, offset);
    _pictureReady = true;
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    if (!_allowHit || !_allowPaint || _compositedAlpha <= 0) return false;
    return super.hitTestChildren(result, position: position);
  }

  @override
  void visitChildrenForSemantics(RenderObjectVisitor visitor) {
    if (_allowPaint && _compositedAlpha > 0) {
      super.visitChildrenForSemantics(visitor);
    }
  }
}

/// Reuses the last child instance while inactive so a parent rebuild cannot
/// walk a full thumbnail grid that is not on screen.
class MediaLibraryFrozenWhenInactive extends StatefulWidget {
  const MediaLibraryFrozenWhenInactive({
    super.key,
    required this.active,
    required this.child,
    this.changes,
  });

  final bool active;
  final Widget child;

  /// Notifies when the hidden tree is stale and must be rebuilt on the next
  /// activation. A clean reactivation keeps the last element tree.
  final Listenable? changes;

  @override
  State<MediaLibraryFrozenWhenInactive> createState() =>
      _MediaLibraryFrozenWhenInactiveState();
}

class _MediaLibraryFrozenWhenInactiveState
    extends State<MediaLibraryFrozenWhenInactive> {
  Widget? _frozen;
  bool _dirtyWhileHidden = false;
  bool _reuseFrozen = false;

  @override
  void initState() {
    super.initState();
    widget.changes?.addListener(_markDirty);
  }

  @override
  void didUpdateWidget(covariant MediaLibraryFrozenWhenInactive oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.changes != widget.changes) {
      oldWidget.changes?.removeListener(_markDirty);
      widget.changes?.addListener(_markDirty);
    }
    if (widget.changes != null &&
        widget.active &&
        !oldWidget.active &&
        !_dirtyWhileHidden &&
        _frozen != null) {
      _reuseFrozen = true;
    }
  }

  @override
  void dispose() {
    widget.changes?.removeListener(_markDirty);
    super.dispose();
  }

  void _markDirty() {
    if (!widget.active) _dirtyWhileHidden = true;
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.active) {
      _reuseFrozen = false;
      return _frozen ?? widget.child;
    }
    if (_reuseFrozen && _frozen != null) {
      _reuseFrozen = false;
      _dirtyWhileHidden = false;
      return _frozen!;
    }
    _dirtyWhileHidden = false;
    _frozen = widget.child;
    return widget.child;
  }
}
