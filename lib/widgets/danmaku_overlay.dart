import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../models/danmaku_model.dart';
import '../models/danmaku_style.dart';
import '../utils/danmaku_ass_parser.dart';
import '../utils/subtitle_parser.dart';

const int _unrestrictedDanmakuAdmissions = 0x3fffffff;
const int _normalDanmakuAdmissionCap = 640;
const int _adaptiveDanmakuAdmissionCap = 320;
const int _severeDanmakuAdmissionCap = 200;

DanmakuDocument _parseDanmakuBytes(Uint8List bytes) {
  return DanmakuAssParser.parse(SubtitleParser.decodeBytes(bytes));
}

class DanmakuOverlay extends StatefulWidget {
  final String path;
  final ValueListenable<Duration> position;
  final double displayArea;
  final double opacity;
  final double fontScale;

  /// User-selected motion multiplier in media time. Playback speed must not
  /// be multiplied here: [position] is the shared presentation clock and
  /// already advances at the rate accepted by the native player.
  final double speed;
  final String? fontFamily;
  final int fontWeight;
  final DanmakuOutlineType outlineType;
  final double playerHeight;

  const DanmakuOverlay({
    super.key,
    required this.path,
    required this.position,
    required this.displayArea,
    required this.opacity,
    required this.fontScale,
    required this.speed,
    required this.fontFamily,
    required this.fontWeight,
    required this.outlineType,
    required this.playerHeight,
  });

  @override
  State<DanmakuOverlay> createState() => _DanmakuOverlayState();
}

class _DanmakuOverlayState extends State<DanmakuOverlay> {
  DanmakuDocument? _document;
  DanmakuActiveSet? _activeSet;
  int _loadToken = 0;
  late final _DanmakuAtlasManager _atlasManager;
  late final _DanmakuPerformanceGovernor _performanceGovernor;
  final DanmakuAssetAdmissionGate _assetAdmissionGate =
      DanmakuAssetAdmissionGate();
  _DanmakuAtlasStyle? _preparedStyle;
  int? _requestedPrefetchBucket;
  int? _completedPrefetchBucket;
  int? _completedPrefetchGeneration;
  bool _prefetchScheduled = false;
  bool _prefetchRunning = false;
  double _viewportWidth = 1920;

  @override
  void initState() {
    super.initState();
    _atlasManager = _DanmakuAtlasManager(maximumBytes: _atlasMemoryBudget());
    _performanceGovernor = _DanmakuPerformanceGovernor()..start();
    _performanceGovernor.addListener(_onPerformancePolicyChanged);
    widget.position.addListener(_onPositionChanged);
    _load();
  }

  @override
  void didUpdateWidget(covariant DanmakuOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.path != widget.path) _load();
    if (oldWidget.position != widget.position) {
      oldWidget.position.removeListener(_onPositionChanged);
      widget.position.addListener(_onPositionChanged);
    }
    if (oldWidget.fontScale != widget.fontScale ||
        oldWidget.fontFamily != widget.fontFamily ||
        oldWidget.fontWeight != widget.fontWeight ||
        oldWidget.outlineType != widget.outlineType ||
        oldWidget.playerHeight != widget.playerHeight ||
        oldWidget.speed != widget.speed) {
      _invalidatePrefetchProgress();
      _schedulePrefetch();
    }
  }

  Future<void> _load() async {
    final token = ++_loadToken;
    _assetAdmissionGate.reset();
    try {
      final bytes = await File(widget.path).readAsBytes();
      final document = await compute(
        _parseDanmakuBytes,
        bytes,
        debugLabel: 'parse-bilibili-danmaku',
      );
      if (!mounted || token != _loadToken) return;
      _atlasManager.clear();
      _invalidatePrefetchProgress();
      setState(() {
        _document = document;
        _activeSet = DanmakuActiveSet(document.items);
      });
      _schedulePrefetch();
    } catch (_) {
      if (!mounted || token != _loadToken) return;
      _atlasManager.clear();
      setState(() {
        _document = null;
        _activeSet = null;
      });
    }
  }

  @override
  void dispose() {
    widget.position.removeListener(_onPositionChanged);
    _performanceGovernor.removeListener(_onPerformancePolicyChanged);
    _performanceGovernor.dispose();
    _atlasManager.dispose();
    super.dispose();
  }

  void _onPositionChanged() => _schedulePrefetch();

  void _onPerformancePolicyChanged() {
    _invalidatePrefetchProgress();
    _schedulePrefetch();
  }

  void _invalidatePrefetchProgress() {
    _requestedPrefetchBucket = null;
    _completedPrefetchBucket = null;
  }

  void _schedulePrefetch() {
    // One maintenance pass per second is enough because upcoming atlas work is
    // grouped into stable five-second media-time segments below. Running this
    // four times per second caused small but measurable periodic UI work.
    final positionBucket = widget.position.value.inMilliseconds ~/ 1000;
    if (_completedPrefetchBucket == positionBucket &&
        _completedPrefetchGeneration == _atlasManager.generation) {
      return;
    }
    if (_requestedPrefetchBucket == positionBucket &&
        (_prefetchScheduled || _prefetchRunning)) {
      return;
    }
    _requestedPrefetchBucket = positionBucket;
    if (_prefetchScheduled || _prefetchRunning) return;
    _prefetchScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _prefetchScheduled = false;
      if (!mounted || _prefetchRunning) return;
      unawaited(_runPrefetchLoop());
    });
  }

  Future<void> _runPrefetchLoop() async {
    _prefetchRunning = true;
    try {
      while (mounted) {
        final document = _document;
        final style = _preparedStyle;
        final requestedBucket = _requestedPrefetchBucket;
        if (document == null || style == null || requestedBucket == null) {
          return;
        }

        final generation = _atlasManager.generation;
        final positionUs = widget.position.value.inMicroseconds;
        // Even under pressure, keep a small bounded future runway. Disabling
        // look-ahead entirely guarantees that a sprite can only be created
        // after its media timestamp, which makes it pop into the middle of its
        // trajectory. Upcoming work is deliberately ordered before old active
        // items so the entry edge remains the protected deadline.
        final indices = resolveDanmakuPrefetchIndices(
          document.items,
          positionUs: positionUs,
          speed: widget.speed,
          viewportWidth: _viewportWidth,
          referenceWidth: document.referenceWidth,
          maximumActiveItems: _performanceGovernor.constrainPrefetch
              ? math.min(_performanceGovernor.admissionCap, 200)
              : 640,
          maximumUpcomingItems: _performanceGovernor.constrainPrefetch
              ? 128
              : 800,
          // Keep the horizon in media time at ten seconds. At an 8x temporary
          // playback rate that is only 1.25 seconds of wall-clock preparation;
          // reducing it further would recreate the late-entry race.
          lookAheadUs: 10000000,
          atlasSegmentUs: _performanceGovernor.constrainPrefetch
              ? 1000000
              : 5000000,
        );

        _atlasManager.beginPrefetchCycle();
        _atlasManager.pinPreparedItems(<int>[
          for (final index in indices)
            if (document.items[index].startTime.inMicroseconds <= positionUs)
              index,
        ]);
        // Text layout and Picture.toImage both share frame-critical resources.
        // Smaller pages reduce the size of each individual raster/upload spike
        // while the video and the danmaku animation are already running.
        const batchSize = 32;
        for (var offset = 0; offset < indices.length; offset += batchSize) {
          if (!mounted || generation != _atlasManager.generation) break;
          final end = math.min(offset + batchSize, indices.length);
          final items = <DanmakuItem>[
            for (var i = offset; i < end; i++) document.items[indices[i]],
          ];
          final pinsCurrentFrame = items.any((item) {
            final elapsedUs = positionUs - item.startTime.inMicroseconds;
            final durationUs = resolveDanmakuDurationUs(
              item,
              speed: widget.speed,
              viewportWidth: _viewportWidth,
              referenceWidth: document.referenceWidth,
            );
            return elapsedUs >= 0 && elapsedUs < durationUs;
          });
          final preparedNewAssets = await _atlasManager.prepare(
            items,
            generation: generation,
            pinPages: pinsCurrentFrame,
          );
          // Atlas construction is kept outside paint() and yields after every
          // batch, so a dense burst cannot monopolize the UI isolate.
          if (preparedNewAssets && end < indices.length && mounted) {
            await WidgetsBinding.instance.endOfFrame;
          }
        }

        if (requestedBucket == _requestedPrefetchBucket &&
            generation == _atlasManager.generation) {
          _completedPrefetchBucket = requestedBucket;
          _completedPrefetchGeneration = generation;
          return;
        }
      }
    } finally {
      _prefetchRunning = false;
      if (mounted &&
          (_requestedPrefetchBucket != _completedPrefetchBucket ||
              _completedPrefetchGeneration != _atlasManager.generation) &&
          !_prefetchScheduled) {
        _schedulePrefetch();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    _performanceGovernor.updateRefreshRate(
      View.of(context).display.refreshRate,
    );
    final document = _document;
    final activeSet = _activeSet;
    if (document == null || document.items.isEmpty || activeSet == null) {
      return const SizedBox.shrink();
    }
    final devicePixelRatio = MediaQuery.devicePixelRatioOf(context);
    final style = _DanmakuAtlasStyle(
      fontSize: resolveDanmakuFontSize(
        playerHeight: widget.playerHeight,
        fontScale: widget.fontScale,
      ),
      devicePixelRatio: devicePixelRatio,
      fontFamily: widget.fontFamily,
      fontWeight: widget.fontWeight,
      outlineType: widget.outlineType,
    );
    _atlasManager.ensureStyle(style);
    _preparedStyle = style;
    _schedulePrefetch();

    return LayoutBuilder(
      builder: (context, constraints) {
        final viewportWidth =
            constraints.hasBoundedWidth &&
                constraints.maxWidth.isFinite &&
                constraints.maxWidth > 0
            ? constraints.maxWidth
            : document.referenceWidth;
        if ((_viewportWidth - viewportWidth).abs() >= 0.5) {
          _viewportWidth = viewportWidth;
          _invalidatePrefetchProgress();
          _schedulePrefetch();
        }
        return IgnorePointer(
          child: RepaintBoundary(
            child: CustomPaint(
              painter: _DanmakuPainter(
                document: document,
                position: widget.position,
                displayArea: widget.displayArea,
                opacity: widget.opacity,
                speed: widget.speed,
                requestedFontSize: style.fontSize,
                activeSet: activeSet,
                atlasManager: _atlasManager,
                performanceGovernor: _performanceGovernor,
                assetAdmissionGate: _assetAdmissionGate,
              ),
              // The overlay changes on every VSync. Marking it as complex
              // invites a raster-cache attempt which cannot be reused.
              isComplex: false,
              willChange: true,
              size: Size.infinite,
            ),
          ),
        );
      },
    );
  }
}

class _DanmakuPainter extends CustomPainter {
  final DanmakuDocument document;
  final ValueListenable<Duration> position;
  final double displayArea;
  final double opacity;
  final double speed;
  final double requestedFontSize;
  final DanmakuActiveSet activeSet;
  final _DanmakuAtlasManager atlasManager;
  final _DanmakuPerformanceGovernor performanceGovernor;
  final DanmakuAssetAdmissionGate assetAdmissionGate;
  late final Paint _atlasPaint = Paint()
    ..isAntiAlias = true
    // Scrolling comments deliberately retain a fractional X coordinate. Linear
    // sampling lets those sub-pixel steps remain continuous instead of turning
    // them into a repeated-frame/one-pixel-jump pattern on high-refresh-rate
    // Windows displays.
    ..filterQuality = FilterQuality.low;

  _DanmakuPainter({
    required this.document,
    required this.position,
    required this.displayArea,
    required this.opacity,
    required this.speed,
    required this.requestedFontSize,
    required this.activeSet,
    required this.atlasManager,
    required this.performanceGovernor,
    required this.assetAdmissionGate,
  }) : super(
         repaint: Listenable.merge(<Listenable>[
           position,
           atlasManager,
           performanceGovernor,
         ]),
       );

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final positionUs = position.value.inMicroseconds;
    assetAdmissionGate.beginFrame(positionUs);
    // All movement is derived from shared media time. At 2x, position itself
    // advances twice as fast in wall time, so danmaku accelerates with the
    // video without maintaining a second, drift-prone animation clock.
    final visibleHeight =
        size.height *
        displayArea.clamp(kDanmakuDisplayAreaMin, kDanmakuDisplayAreaMax);
    final fontSize = atlasManager.activeStyle?.fontSize ?? requestedFontSize;
    final edgePadding = math.max(2.0, fontSize * 0.1);
    final laneExtent = fontSize + edgePadding;
    final renderRect = Rect.fromLTWH(0, 0, size.width, visibleHeight);
    final contentRect = Rect.fromLTRB(
      renderRect.left + edgePadding,
      renderRect.top + edgePadding,
      math.max(renderRect.left + edgePadding, renderRect.right - edgePadding),
      math.max(renderRect.top + edgePadding, renderRect.bottom - edgePadding),
    );
    final activeIndices = activeSet.update(
      positionUs: positionUs,
      speed: speed,
      admissionCap: performanceGovernor.admissionCap,
      viewportWidth: renderRect.width,
      referenceWidth: document.referenceWidth,
    );
    if (activeIndices.isEmpty) return;

    atlasManager.beginFrame();
    canvas.save();
    canvas.clipRect(renderRect);
    final usesFallback = atlasManager.usesFallback;
    if (usesFallback && opacity < 0.999) {
      canvas.saveLayer(
        renderRect,
        Paint()..color = Color.fromRGBO(255, 255, 255, opacity.clamp(0.1, 1.0)),
      );
    }
    for (var active = activeIndices.length - 1; active >= 0; active--) {
      final item = document.items[activeIndices[active]];
      final elapsedUs = positionUs - item.startTime.inMicroseconds;
      final durationUs = resolveDanmakuDurationUs(
        item,
        speed: speed,
        viewportWidth: renderRect.width,
        referenceWidth: document.referenceWidth,
      );
      if (elapsedUs < 0 || elapsedUs >= durationUs) continue;

      final y = _resolveY(
        item,
        contentRect: contentRect,
        laneExtent: laneExtent,
      );
      final sprite = atlasManager.lookup(item.index);
      final fallback = atlasManager.lookupFallback(item.index);
      final layoutWidth = sprite?.width ?? fallback?.width;
      final layoutHeight = sprite?.height ?? fallback?.height;
      if (layoutWidth == null || layoutHeight == null) {
        assetAdmissionGate.shouldPaint(
          itemIndex: item.index,
          assetReady: false,
        );
        continue;
      }
      if (!assetAdmissionGate.shouldPaint(
            itemIndex: item.index,
            assetReady: true,
          ) ||
          y < contentRect.top ||
          y + layoutHeight > contentRect.bottom) {
        continue;
      }
      final progress = elapsedUs / durationUs;
      final x = switch (item.type) {
        DanmakuType.scroll =>
          contentRect.right - progress * (contentRect.width + layoutWidth),
        DanmakuType.top ||
        DanmakuType.bottom => contentRect.center.dx - layoutWidth / 2,
      };
      if (sprite != null) {
        atlasManager.addSprite(
          sprite,
          x,
          y,
          continuousHorizontal: item.type == DanmakuType.scroll,
        );
      } else {
        fallback!.paintTextAt(canvas, x, y);
      }
    }

    atlasManager.paintFrame(canvas, _atlasPaint, opacity.clamp(0.1, 1.0));
    if (usesFallback && opacity < 0.999) canvas.restore();
    canvas.restore();
  }

  double _resolveY(
    DanmakuItem item, {
    required Rect contentRect,
    required double laneExtent,
  }) {
    if (item.type == DanmakuType.bottom) {
      final sourceDistanceFromBottom = (document.referenceHeight - item.sourceY)
          .clamp(0, document.referenceHeight);
      final lane = (sourceDistanceFromBottom / 40).floor();
      return contentRect.bottom - (lane + 1) * laneExtent;
    }
    final lane = (item.sourceY / 40).floor();
    return contentRect.top + lane * laneExtent;
  }

  @override
  bool shouldRepaint(covariant _DanmakuPainter oldDelegate) {
    return oldDelegate.document != document ||
        oldDelegate.displayArea != displayArea ||
        oldDelegate.opacity != opacity ||
        oldDelegate.speed != speed ||
        oldDelegate.requestedFontSize != requestedFontSize;
  }
}

/// Prevents an asset which missed its entry deadline from appearing halfway
/// across the screen once its asynchronous atlas upload eventually finishes.
///
/// A seek clears the suppression set because it establishes a new presentation
/// epoch. Normal playback-rate changes remain continuous and therefore never
/// clear it.
@visibleForTesting
class DanmakuAssetAdmissionGate {
  int? _lastPositionUs;
  final Set<int> _suppressedItems = <int>{};

  void beginFrame(int positionUs) {
    final previous = _lastPositionUs;
    if (previous != null && positionUs < previous) {
      _suppressedItems.clear();
    }
    _lastPositionUs = positionUs;
  }

  bool shouldPaint({required int itemIndex, required bool assetReady}) {
    if (_suppressedItems.contains(itemIndex)) return false;
    if (assetReady) return true;
    _suppressedItems.add(itemIndex);
    return false;
  }

  void reset() {
    _lastPositionUs = null;
    _suppressedItems.clear();
  }
}

@visibleForTesting
double resolveDanmakuFontSize({
  required double playerHeight,
  required double fontScale,
}) {
  const referencePlayerHeight = 1080.0;
  const referenceFontSize = 40.0;
  final safePlayerHeight = playerHeight.isFinite && playerHeight > 0
      ? playerHeight
      : referencePlayerHeight;
  return (referenceFontSize *
          safePlayerHeight /
          referencePlayerHeight *
          fontScale.clamp(kDanmakuFontScaleMin, kDanmakuFontScaleMax))
      .clamp(2.0, 160.0);
}

/// Resolves motion duration from the stage width instead of assigning every
/// window the same travel time. The source duration remains unchanged at the
/// ASS reference width, while wider stages receive proportionally more time.
@visibleForTesting
int resolveDanmakuDurationUs(
  DanmakuItem item, {
  required double speed,
  required double viewportWidth,
  required double referenceWidth,
}) {
  final safeSpeed = speed.clamp(kDanmakuSpeedMin, kDanmakuSpeedMax);
  final widthScale = item.type == DanmakuType.scroll
      ? _safeDanmakuWidthScale(viewportWidth, referenceWidth)
      : 1.0;
  return math.max(
    1,
    (item.duration.inMicroseconds * widthScale / safeSpeed).round(),
  );
}

double _safeDanmakuWidthScale(double viewportWidth, double referenceWidth) {
  final safeReference = referenceWidth.isFinite && referenceWidth > 0
      ? referenceWidth
      : 1920.0;
  final safeViewport = viewportWidth.isFinite && viewportWidth > 0
      ? viewportWidth
      : safeReference;
  return (safeViewport / safeReference).clamp(0.1, 8.0);
}

@visibleForTesting
class DanmakuIndexRange {
  final int start;
  final int endExclusive;

  const DanmakuIndexRange(this.start, this.endExclusive);

  bool get isEmpty => start >= endExclusive;
  int get length => math.max(0, endExclusive - start);
}

@visibleForTesting
DanmakuIndexRange resolveDanmakuActiveRange(
  List<DanmakuItem> items, {
  required int positionUs,
  required double speed,
  double viewportWidth = 1920,
  double referenceWidth = 1920,
}) {
  if (items.isEmpty) return const DanmakuIndexRange(0, 0);
  final safeSpeed = speed.clamp(kDanmakuSpeedMin, kDanmakuSpeedMax);
  final widthScale = math.max(
    1.0,
    _safeDanmakuWidthScale(viewportWidth, referenceWidth),
  );
  final earliestStartUs =
      positionUs - (16000000 * widthScale / safeSpeed).round();
  return DanmakuIndexRange(
    _firstStartAtOrAfter(items, earliestStartUs),
    _firstStartAfter(items, positionUs),
  );
}

@visibleForTesting
List<int> resolveDanmakuPrefetchIndices(
  List<DanmakuItem> items, {
  required int positionUs,
  required double speed,
  double viewportWidth = 1920,
  double referenceWidth = 1920,
  int maximumActiveItems = 640,
  int maximumUpcomingItems = 800,
  int lookAheadUs = 10000000,
  int atlasSegmentUs = 5000000,
}) {
  final result = <int>[];
  final active = resolveDanmakuActiveRange(
    items,
    positionUs: positionUs,
    speed: speed,
    viewportWidth: viewportWidth,
    referenceWidth: referenceWidth,
  );
  final safeMaximumUpcomingItems = math.max(0, maximumUpcomingItems);
  final safeLookAheadUs = math.max(0, lookAheadUs);
  final safeAtlasSegmentUs = math.max(1, atlasSegmentUs);
  final requestedFutureUs = positionUs + safeLookAheadUs;
  final alignedFutureUs =
      ((requestedFutureUs + safeAtlasSegmentUs - 1) ~/ safeAtlasSegmentUs) *
      safeAtlasSegmentUs;
  final upcomingEnd = _firstStartAfter(items, alignedFutureUs);
  var upcomingCount = 0;
  for (
    var i = active.endExclusive;
    i < upcomingEnd && upcomingCount < safeMaximumUpcomingItems;
    i++
  ) {
    result.add(i);
    upcomingCount++;
  }
  final safeMaximumActiveItems = math.max(0, maximumActiveItems);
  var activeCount = 0;
  for (
    var i = active.endExclusive - 1;
    i >= active.start && activeCount < safeMaximumActiveItems;
    i--
  ) {
    result.add(i);
    activeCount++;
  }
  return result;
}

int _firstStartAtOrAfter(List<DanmakuItem> items, int positionUs) {
  var low = 0;
  var high = items.length;
  while (low < high) {
    final mid = (low + high) >> 1;
    if (items[mid].startTime.inMicroseconds < positionUs) {
      low = mid + 1;
    } else {
      high = mid;
    }
  }
  return low;
}

int _firstStartAfter(List<DanmakuItem> items, int positionUs) {
  var low = 0;
  var high = items.length;
  while (low < high) {
    final mid = (low + high) >> 1;
    if (items[mid].startTime.inMicroseconds <= positionUs) {
      low = mid + 1;
    } else {
      high = mid;
    }
  }
  return low;
}

/// Incremental media-time index used by the painter's hot path.
///
/// This is public only so the overload behavior can be regression-tested
/// without pumping a platform-specific raster surface.
@visibleForTesting
class DanmakuActiveSet {
  DanmakuActiveSet(this.items)
    : _maximumScrollDurationUs = items.fold<int>(
        0,
        (maximum, item) => item.type == DanmakuType.scroll
            ? math.max(maximum, item.duration.inMicroseconds)
            : maximum,
      ),
      _maximumFixedDurationUs = items.fold<int>(
        0,
        (maximum, item) => item.type != DanmakuType.scroll
            ? math.max(maximum, item.duration.inMicroseconds)
            : maximum,
      );

  final List<DanmakuItem> items;
  final int _maximumScrollDurationUs;
  final int _maximumFixedDurationUs;
  final List<int> _active = <int>[];
  final Map<String, int> _activeTextCounts = <String, int>{};
  int _nextStartIndex = 0;
  int? _lastPositionUs;
  double? _lastSpeed;
  double? _lastWidthScale;

  List<int> update({
    required int positionUs,
    required double speed,
    required int admissionCap,
    double viewportWidth = 1920,
    double referenceWidth = 1920,
  }) {
    final safeSpeed = speed.clamp(kDanmakuSpeedMin, kDanmakuSpeedMax);
    final widthScale = _safeDanmakuWidthScale(viewportWidth, referenceWidth);
    final mustReset =
        _lastPositionUs == null ||
        positionUs < _lastPositionUs! ||
        positionUs - _lastPositionUs! > 2000000 ||
        _lastSpeed != safeSpeed ||
        _lastWidthScale == null ||
        (_lastWidthScale! - widthScale).abs() >= 0.001;
    if (mustReset) {
      _reset(
        positionUs,
        safeSpeed,
        admissionCap,
        viewportWidth,
        referenceWidth,
      );
    } else {
      _removeExpired(positionUs, safeSpeed, viewportWidth, referenceWidth);
      _addNew(
        positionUs,
        safeSpeed,
        admissionCap,
        viewportWidth,
        referenceWidth,
      );
      // A performance-policy change can lower the cap while a dense burst is
      // already on screen. Only applying the cap in _addNew leaves all of the
      // existing items alive for their full duration, which is exactly when
      // the raster thread most needs relief.
      _trimToAdmissionCap(admissionCap);
    }
    _lastPositionUs = positionUs;
    _lastSpeed = safeSpeed;
    _lastWidthScale = widthScale;
    return _active;
  }

  void _reset(
    int positionUs,
    double speed,
    int admissionCap,
    double viewportWidth,
    double referenceWidth,
  ) {
    _active.clear();
    _activeTextCounts.clear();
    final widthScale = _safeDanmakuWidthScale(viewportWidth, referenceWidth);
    final maximumDurationUs = math.max(
      _maximumFixedDurationUs,
      (_maximumScrollDurationUs * widthScale).ceil(),
    );
    final earliest = positionUs - (maximumDurationUs / speed).ceil();
    final first = _firstStartAtOrAfter(items, earliest);
    _nextStartIndex = _firstStartAfter(items, positionUs);
    final candidates = <int>[];
    for (var index = first; index < _nextStartIndex; index++) {
      if (_isActive(
        items[index],
        positionUs,
        speed,
        viewportWidth,
        referenceWidth,
      )) {
        candidates.add(index);
      }
    }
    _admit(candidates, admissionCap);
  }

  void _removeExpired(
    int positionUs,
    double speed,
    double viewportWidth,
    double referenceWidth,
  ) {
    var write = 0;
    for (final index in _active) {
      final item = items[index];
      if (_isActive(item, positionUs, speed, viewportWidth, referenceWidth)) {
        _active[write++] = index;
      } else {
        final count = _activeTextCounts[item.text] ?? 0;
        if (count <= 1) {
          _activeTextCounts.remove(item.text);
        } else {
          _activeTextCounts[item.text] = count - 1;
        }
      }
    }
    _active.length = write;
  }

  void _addNew(
    int positionUs,
    double speed,
    int admissionCap,
    double viewportWidth,
    double referenceWidth,
  ) {
    final candidates = <int>[];
    while (_nextStartIndex < items.length &&
        items[_nextStartIndex].startTime.inMicroseconds <= positionUs) {
      final index = _nextStartIndex++;
      if (_isActive(
        items[index],
        positionUs,
        speed,
        viewportWidth,
        referenceWidth,
      )) {
        candidates.add(index);
      }
    }
    _admit(candidates, admissionCap);
  }

  void _admit(List<int> candidates, int admissionCap) {
    if (candidates.isEmpty) return;
    final isAdaptiveOverload = admissionCap < _normalDanmakuAdmissionCap;
    if (isAdaptiveOverload) {
      candidates.sort((left, right) {
        final leftDuplicate = _activeTextCounts.containsKey(items[left].text);
        final rightDuplicate = _activeTextCounts.containsKey(items[right].text);
        if (leftDuplicate != rightDuplicate) return leftDuplicate ? 1 : -1;
        return _stablePriority(
          items[right],
        ).compareTo(_stablePriority(items[left]));
      });
    }
    for (final index in candidates) {
      if (_active.length >= admissionCap) break;
      final item = items[index];
      if (isAdaptiveOverload &&
          _active.length >= admissionCap * 3 ~/ 4 &&
          _activeTextCounts.containsKey(item.text)) {
        continue;
      }
      _active.add(index);
      _activeTextCounts.update(
        item.text,
        (count) => count + 1,
        ifAbsent: () => 1,
      );
    }
  }

  void _trimToAdmissionCap(int admissionCap) {
    if (admissionCap >= _unrestrictedDanmakuAdmissions ||
        _active.length <= admissionCap) {
      return;
    }
    if (admissionCap <= 0) {
      _active.clear();
      _activeTextCounts.clear();
      return;
    }

    // Keep the reduction deterministic so a policy transition never causes
    // random-looking flicker. Prefer one copy of each text before duplicates,
    // then use the same stable priority as admission for both groups.
    final ranked = List<int>.of(_active)
      ..sort(
        (left, right) => _stablePriority(
          items[right],
        ).compareTo(_stablePriority(items[left])),
      );
    final selected = <int>[];
    final selectedIndices = <int>{};
    final selectedTexts = <String>{};
    for (final index in ranked) {
      if (selectedTexts.add(items[index].text)) {
        selected.add(index);
        selectedIndices.add(index);
      }
      if (selected.length == admissionCap) break;
    }
    if (selected.length < admissionCap) {
      for (final index in ranked) {
        if (!selectedIndices.add(index)) continue;
        selected.add(index);
        if (selected.length == admissionCap) break;
      }
    }
    selected.sort();
    _active
      ..clear()
      ..addAll(selected);
    _rebuildTextCounts();
  }

  void _rebuildTextCounts() {
    _activeTextCounts.clear();
    for (final index in _active) {
      _activeTextCounts.update(
        items[index].text,
        (count) => count + 1,
        ifAbsent: () => 1,
      );
    }
  }

  bool _isActive(
    DanmakuItem item,
    int positionUs,
    double speed,
    double viewportWidth,
    double referenceWidth,
  ) {
    final elapsedUs = positionUs - item.startTime.inMicroseconds;
    final durationUs = resolveDanmakuDurationUs(
      item,
      speed: speed,
      viewportWidth: viewportWidth,
      referenceWidth: referenceWidth,
    );
    return elapsedUs >= 0 && elapsedUs < durationUs;
  }

  int _stablePriority(DanmakuItem item) {
    var hash = item.index * 0x1f1f1f1f;
    for (final codeUnit in item.text.codeUnits) {
      hash = 0x1fffffff & (hash * 31 + codeUnit);
    }
    return hash;
  }
}

class _DanmakuAtlasStyle {
  const _DanmakuAtlasStyle({
    required this.fontSize,
    required this.devicePixelRatio,
    required this.fontFamily,
    required this.fontWeight,
    required this.outlineType,
  });

  final double fontSize;
  final double devicePixelRatio;
  final String? fontFamily;
  final int fontWeight;
  final DanmakuOutlineType outlineType;

  @override
  bool operator ==(Object other) {
    return other is _DanmakuAtlasStyle &&
        other.fontSize == fontSize &&
        other.devicePixelRatio == devicePixelRatio &&
        other.fontFamily == fontFamily &&
        other.fontWeight == fontWeight &&
        other.outlineType == outlineType;
  }

  @override
  int get hashCode => Object.hash(
    fontSize,
    devicePixelRatio,
    fontFamily,
    fontWeight,
    outlineType,
  );
}

class _DanmakuSpriteKey {
  const _DanmakuSpriteKey(this.text, this.colorValue);

  final String text;
  final int colorValue;

  @override
  bool operator ==(Object other) {
    return other is _DanmakuSpriteKey &&
        other.text == text &&
        other.colorValue == colorValue;
  }

  @override
  int get hashCode => Object.hash(text, colorValue);
}

class _DanmakuAtlasManager extends ChangeNotifier {
  _DanmakuAtlasManager({required this.maximumBytes});

  final int maximumBytes;
  _DanmakuAtlasStyle? _requestedStyle;
  _DanmakuAtlasCache? _active;
  _DanmakuAtlasCache? _building;
  _DanmakuAtlasStyle? _fallbackStyle;
  final Map<_DanmakuSpriteKey, _PreparedDanmakuText> _fallbackSprites =
      <_DanmakuSpriteKey, _PreparedDanmakuText>{};
  final Map<int, _PreparedDanmakuText> _fallbackItems =
      <int, _PreparedDanmakuText>{};
  int _generation = 0;
  bool _disposed = false;
  bool _fallbackEnabled = false;
  bool _fallbackNotificationScheduled = false;

  int get generation => _generation;
  _DanmakuAtlasStyle? get activeStyle => _fallbackStyle ?? _active?.style;
  bool get usesFallback => _fallbackEnabled;

  void ensureStyle(_DanmakuAtlasStyle style) {
    if (_requestedStyle == style) return;
    _requestedStyle = style;
    _generation++;
    if (_fallbackEnabled) {
      _disposeFallbackLayouts();
      _fallbackStyle = style;
      return;
    }
    if (_active == null) {
      _active = _DanmakuAtlasCache(style, maximumBytes);
    } else {
      _building?.dispose();
      _building = _DanmakuAtlasCache(style, maximumBytes);
    }
  }

  void beginPrefetchCycle() {
    _active?.unpinAll();
    _building?.unpinAll();
  }

  void pinPreparedItems(Iterable<int> itemIndices) {
    _active?.pinItems(itemIndices);
    _building?.pinItems(itemIndices);
  }

  Future<bool> prepare(
    List<DanmakuItem> items, {
    required int generation,
    required bool pinPages,
  }) async {
    if (_disposed || generation != _generation || items.isEmpty) return false;
    if (_fallbackEnabled) {
      final changed = _prepareFallback(items);
      if (changed) notifyListeners();
      return changed;
    }
    final target = _building ?? _active;
    if (target == null) return false;
    bool changed;
    try {
      changed = await target.prepareBatch(items, pinPages: pinPages);
    } catch (_) {
      if (!_disposed && generation == _generation) {
        _activateFallback(target.style, items);
        notifyListeners();
      }
      return true;
    }
    if (_disposed || generation != _generation) return false;
    if (identical(_building, target) && target.hasSprites) {
      final previous = _active;
      _active = target;
      _building = null;
      previous?.dispose();
      notifyListeners();
    } else if (identical(_active, target) && changed) {
      notifyListeners();
    }
    return changed;
  }

  _DanmakuSprite? lookup(int itemIndex) => _active?.lookup(itemIndex);

  _PreparedDanmakuText? lookupFallback(int itemIndex) {
    return _fallbackItems[itemIndex];
  }

  void beginFrame() => _active?.beginFrame();

  void addSprite(
    _DanmakuSprite sprite,
    double x,
    double y, {
    required bool continuousHorizontal,
  }) {
    _active?.addSprite(
      sprite,
      x,
      y,
      continuousHorizontal: continuousHorizontal,
    );
  }

  void paintFrame(Canvas canvas, Paint paint, double opacity) {
    if (_fallbackEnabled) return;
    try {
      _active?.paintFrame(canvas, paint, opacity);
    } catch (_) {
      final style = _active?.style ?? _requestedStyle;
      if (style == null) return;
      _activateFallback(style, const <DanmakuItem>[]);
      if (_fallbackNotificationScheduled) return;
      _fallbackNotificationScheduled = true;
      scheduleMicrotask(() {
        _fallbackNotificationScheduled = false;
        if (!_disposed) notifyListeners();
      });
    }
  }

  void _activateFallback(
    _DanmakuAtlasStyle style,
    List<DanmakuItem> initialItems,
  ) {
    _active?.dispose();
    _building?.dispose();
    _active = null;
    _building = null;
    _fallbackEnabled = true;
    _fallbackStyle = style;
    _disposeFallbackLayouts();
    _prepareFallback(initialItems);
  }

  bool _prepareFallback(List<DanmakuItem> items) {
    final style = _fallbackStyle;
    if (style == null) return false;
    var changed = false;
    for (final item in items) {
      final text = item.text.replaceAll(RegExp(r'[\r\n]+'), ' ');
      final key = _DanmakuSpriteKey(text, item.colorValue);
      final layout = _fallbackSprites.putIfAbsent(
        key,
        () => _PreparedDanmakuText(item, style),
      );
      if (!_fallbackItems.containsKey(item.index)) changed = true;
      _fallbackItems[item.index] = layout;
    }
    return changed;
  }

  void _disposeFallbackLayouts() {
    for (final layout in _fallbackSprites.values) {
      layout.dispose();
    }
    _fallbackSprites.clear();
    _fallbackItems.clear();
  }

  void clear() {
    _generation++;
    _active?.dispose();
    _building?.dispose();
    _disposeFallbackLayouts();
    _active = null;
    _building = null;
    _fallbackStyle = null;
    _fallbackEnabled = false;
    _requestedStyle = null;
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    clear();
    super.dispose();
  }
}

class _DanmakuAtlasCache {
  _DanmakuAtlasCache(this.style, this.maximumBytes);

  static const int _pageWidth = 2048;
  static const int _pageHeight = 1024;
  static const int _gutter = 2;

  final _DanmakuAtlasStyle style;
  final int maximumBytes;
  final Map<_DanmakuSpriteKey, _DanmakuSprite> _sprites =
      <_DanmakuSpriteKey, _DanmakuSprite>{};
  final Map<int, _DanmakuSprite> _itemSprites = <int, _DanmakuSprite>{};
  final List<_DanmakuAtlasPage> _pages = <_DanmakuAtlasPage>[];
  final List<_DanmakuAtlasPage> _framePages = <_DanmakuAtlasPage>[];
  int _byteSize = 0;
  int _touchSequence = 0;
  bool _disposed = false;

  bool get hasSprites => _sprites.isNotEmpty;

  _DanmakuSprite? lookup(int itemIndex) => _itemSprites[itemIndex];

  void unpinAll() {
    for (final page in _pages) {
      page.pinned = false;
    }
  }

  void pinItems(Iterable<int> itemIndices) {
    for (final itemIndex in itemIndices) {
      final sprite = _itemSprites[itemIndex];
      if (sprite == null) continue;
      sprite.page.pinned = true;
      sprite.page.lastTouch = ++_touchSequence;
    }
  }

  Future<bool> prepareBatch(
    List<DanmakuItem> items, {
    required bool pinPages,
  }) async {
    if (_disposed) return false;
    final pending = <_DanmakuSpriteKey, _PendingDanmakuSprite>{};
    var changed = false;
    for (final item in items) {
      final normalizedText = item.text.replaceAll(RegExp(r'[\r\n]+'), ' ');
      final key = _DanmakuSpriteKey(normalizedText, item.colorValue);
      final cached = _sprites[key];
      if (cached != null) {
        _itemSprites[item.index] = cached;
        cached.page.pinned = cached.page.pinned || pinPages;
        cached.page.lastTouch = ++_touchSequence;
        continue;
      }
      final entry = pending.putIfAbsent(
        key,
        () => _PendingDanmakuSprite(
          key: key,
          prepared: _PreparedDanmakuText(item, style),
        ),
      );
      entry.itemIndices.add(item.index);
    }
    if (pending.isEmpty) return changed;

    final plans = <_DanmakuAtlasPagePlan>[];
    _DanmakuAtlasPagePlan? current;
    for (final entry in pending.values) {
      final prepared = entry.prepared;
      if (prepared.pixelWidth + _gutter * 2 > _pageWidth ||
          prepared.pixelHeight + _gutter * 2 > _pageHeight) {
        final dedicated = _DanmakuAtlasPagePlan(
          math.max(1, prepared.pixelWidth + _gutter * 2),
          math.max(1, prepared.pixelHeight + _gutter * 2),
          _gutter,
        );
        dedicated.tryPlace(entry);
        plans.add(dedicated);
        continue;
      }
      current ??= _DanmakuAtlasPagePlan(_pageWidth, _pageHeight, _gutter);
      if (!current.tryPlace(entry)) {
        plans.add(current);
        current = _DanmakuAtlasPagePlan(_pageWidth, _pageHeight, _gutter)
          ..tryPlace(entry);
      }
    }
    if (current != null && current.placements.isNotEmpty) plans.add(current);

    try {
      for (final plan in plans) {
        final recorder = ui.PictureRecorder();
        final pictureCanvas = Canvas(recorder)..scale(style.devicePixelRatio);
        for (final placement in plan.placements) {
          placement.pending.prepared.paint(
            pictureCanvas,
            placement.left / style.devicePixelRatio,
            placement.top / style.devicePixelRatio,
          );
        }
        final picture = recorder.endRecording();
        ui.Image image;
        try {
          image = await picture.toImage(plan.usedWidth, plan.usedHeight);
        } finally {
          picture.dispose();
        }
        if (_disposed) {
          image.dispose();
          return false;
        }
        final page = _DanmakuAtlasPage(
          image: image,
          devicePixelRatio: style.devicePixelRatio,
          byteSize: plan.usedWidth * plan.usedHeight * 4,
          pinned: pinPages,
          lastTouch: ++_touchSequence,
        );
        _pages.add(page);
        _byteSize += page.byteSize;
        for (final placement in plan.placements) {
          final pendingSprite = placement.pending;
          final prepared = pendingSprite.prepared;
          final sprite = _DanmakuSprite(
            page: page,
            sourceLeft: placement.left.toDouble(),
            sourceTop: placement.top.toDouble(),
            sourceWidth: prepared.pixelWidth.toDouble(),
            sourceHeight: prepared.pixelHeight.toDouble(),
            width: prepared.width,
            height: prepared.height,
            imagePadding: prepared.imagePadding,
          );
          _sprites[pendingSprite.key] = sprite;
          for (final itemIndex in pendingSprite.itemIndices) {
            _itemSprites[itemIndex] = sprite;
          }
        }
        changed = true;
        _evictIfNeeded();
      }
      return changed;
    } finally {
      for (final entry in pending.values) {
        entry.prepared.dispose();
      }
    }
  }

  void _evictIfNeeded() {
    while (_byteSize > maximumBytes && _pages.length > 1) {
      _DanmakuAtlasPage? oldest;
      for (final page in _pages) {
        if (page.pinned) continue;
        if (oldest == null || page.lastTouch < oldest.lastTouch) oldest = page;
      }
      if (oldest == null) return;
      _pages.remove(oldest);
      _byteSize -= oldest.byteSize;
      _sprites.removeWhere((_, sprite) => identical(sprite.page, oldest));
      _itemSprites.removeWhere((_, sprite) => identical(sprite.page, oldest));
      oldest.dispose();
    }
  }

  void beginFrame() {
    // Cached pages can far outnumber the pages visible in one frame. Reset
    // only pages used by the previous frame and collect this frame lazily.
    for (final page in _framePages) {
      page.beginFrame();
    }
    _framePages.clear();
  }

  void addSprite(
    _DanmakuSprite sprite,
    double x,
    double y, {
    required bool continuousHorizontal,
  }) {
    final page = sprite.page;
    if (!page.inFrame) {
      page.inFrame = true;
      _framePages.add(page);
    }
    page.addSprite(sprite, x, y, continuousHorizontal: continuousHorizontal);
  }

  void paintFrame(Canvas canvas, Paint paint, double opacity) {
    for (final page in _framePages) {
      page.paint(canvas, paint, opacity);
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final page in _pages) {
      page.dispose();
    }
    _pages.clear();
    _framePages.clear();
    _sprites.clear();
    _itemSprites.clear();
    _byteSize = 0;
  }
}

class _PendingDanmakuSprite {
  _PendingDanmakuSprite({required this.key, required this.prepared});

  final _DanmakuSpriteKey key;
  final _PreparedDanmakuText prepared;
  final List<int> itemIndices = <int>[];
}

class _PreparedDanmakuText {
  _PreparedDanmakuText(DanmakuItem item, _DanmakuAtlasStyle style)
    : _devicePixelRatio = style.devicePixelRatio {
    final text = item.text.replaceAll(RegExp(r'[\r\n]+'), ' ');
    _fill = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: Color(item.colorValue),
          fontSize: style.fontSize,
          fontFamily: style.fontFamily,
          fontWeight: danmakuFontWeight(style.fontWeight),
          height: 1,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    final strokeWidth = switch (style.outlineType) {
      DanmakuOutlineType.standard => math.max(1.2, style.fontSize * 0.075),
      DanmakuOutlineType.thin => math.max(0.8, style.fontSize * 0.042),
      DanmakuOutlineType.heavy => math.max(1.8, style.fontSize * 0.12),
      DanmakuOutlineType.projection => math.max(0.6, style.fontSize * 0.025),
    };
    _stroke = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontSize: style.fontSize,
          fontFamily: style.fontFamily,
          fontWeight: danmakuFontWeight(style.fontWeight),
          height: 1,
          foreground: Paint()
            ..style = PaintingStyle.stroke
            ..strokeJoin = StrokeJoin.round
            ..strokeWidth = strokeWidth
            ..color = Colors.black.withValues(alpha: 0.9),
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    _projectionDistance = style.outlineType == DanmakuOutlineType.projection
        ? math.max(1.5, style.fontSize * 0.1)
        : 0.0;
    _projection = style.outlineType == DanmakuOutlineType.projection
        ? (TextPainter(
            text: TextSpan(
              text: text,
              style: TextStyle(
                color: Colors.black.withValues(alpha: 0.9),
                fontSize: style.fontSize,
                fontFamily: style.fontFamily,
                fontWeight: danmakuFontWeight(style.fontWeight),
                height: 1,
              ),
            ),
            textDirection: TextDirection.ltr,
            maxLines: 1,
          )..layout())
        : null;
    width = _fill.width;
    height = _fill.height;
    imagePadding = strokeWidth / 2 + _projectionDistance + 1;
    pixelWidth = math.max(
      1,
      ((width + imagePadding * 2) * _devicePixelRatio).ceil(),
    );
    pixelHeight = math.max(
      1,
      ((height + imagePadding * 2) * _devicePixelRatio).ceil(),
    );
  }

  late final TextPainter _fill;
  late final TextPainter _stroke;
  late final TextPainter? _projection;
  late final double _projectionDistance;
  final double _devicePixelRatio;
  late final double width;
  late final double height;
  late final double imagePadding;
  late final int pixelWidth;
  late final int pixelHeight;

  void paint(Canvas canvas, double left, double top) {
    final textOffset = Offset(left + imagePadding, top + imagePadding);
    final projection = _projection;
    if (projection != null) {
      projection.paint(
        canvas,
        textOffset + Offset(_projectionDistance, _projectionDistance),
      );
    }
    _stroke.paint(canvas, textOffset);
    _fill.paint(canvas, textOffset);
  }

  void paintTextAt(Canvas canvas, double x, double y) {
    paint(canvas, x - imagePadding, y - imagePadding);
  }

  void dispose() {
    _fill.dispose();
    _stroke.dispose();
    _projection?.dispose();
  }
}

class _DanmakuAtlasPlacement {
  const _DanmakuAtlasPlacement(this.pending, this.left, this.top);

  final _PendingDanmakuSprite pending;
  final int left;
  final int top;
}

class _DanmakuAtlasPagePlan {
  _DanmakuAtlasPagePlan(this.maximumWidth, this.maximumHeight, this.gutter)
    : _cursorX = gutter,
      _cursorY = gutter;

  final int maximumWidth;
  final int maximumHeight;
  final int gutter;
  final List<_DanmakuAtlasPlacement> placements = <_DanmakuAtlasPlacement>[];
  int _cursorX;
  int _cursorY;
  int _rowHeight = 0;
  int usedWidth = 1;
  int usedHeight = 1;

  bool tryPlace(_PendingDanmakuSprite pending) {
    final width = pending.prepared.pixelWidth;
    final height = pending.prepared.pixelHeight;
    if (width + gutter * 2 > maximumWidth ||
        height + gutter * 2 > maximumHeight) {
      return false;
    }
    if (_cursorX + width + gutter > maximumWidth) {
      _cursorX = gutter;
      _cursorY += _rowHeight + gutter;
      _rowHeight = 0;
    }
    if (_cursorY + height + gutter > maximumHeight) return false;
    placements.add(_DanmakuAtlasPlacement(pending, _cursorX, _cursorY));
    usedWidth = math.max(usedWidth, _cursorX + width + gutter);
    usedHeight = math.max(usedHeight, _cursorY + height + gutter);
    _cursorX += width + gutter;
    _rowHeight = math.max(_rowHeight, height);
    return true;
  }
}

class _DanmakuSprite {
  const _DanmakuSprite({
    required this.page,
    required this.sourceLeft,
    required this.sourceTop,
    required this.sourceWidth,
    required this.sourceHeight,
    required this.width,
    required this.height,
    required this.imagePadding,
  });

  final _DanmakuAtlasPage page;
  final double sourceLeft;
  final double sourceTop;
  final double sourceWidth;
  final double sourceHeight;
  final double width;
  final double height;
  final double imagePadding;
}

class _DanmakuAtlasPage {
  _DanmakuAtlasPage({
    required this.image,
    required this.devicePixelRatio,
    required this.byteSize,
    required this.pinned,
    required this.lastTouch,
  });

  final ui.Image image;
  final double devicePixelRatio;
  final int byteSize;
  bool pinned;
  int lastTouch;
  bool inFrame = false;
  Float32List _transforms = Float32List(64 * 4);
  Float32List _rects = Float32List(64 * 4);
  Int32List _colors = Int32List(64);
  int _spriteCount = 0;

  void beginFrame() {
    _spriteCount = 0;
    inFrame = false;
  }

  void addSprite(
    _DanmakuSprite sprite,
    double x,
    double y, {
    required bool continuousHorizontal,
  }) {
    _ensureCapacity(_spriteCount + 1);
    final offset = _spriteCount * 4;
    final scale = 1 / devicePixelRatio;
    final destination = resolveDanmakuAtlasDestination(
      x - sprite.imagePadding,
      y - sprite.imagePadding,
      devicePixelRatio,
      continuousHorizontal: continuousHorizontal,
    );
    _transforms[offset] = scale;
    _transforms[offset + 1] = 0;
    _transforms[offset + 2] = destination.dx;
    _transforms[offset + 3] = destination.dy;
    _rects[offset] = sprite.sourceLeft;
    _rects[offset + 1] = sprite.sourceTop;
    _rects[offset + 2] = sprite.sourceLeft + sprite.sourceWidth;
    _rects[offset + 3] = sprite.sourceTop + sprite.sourceHeight;
    _spriteCount++;
  }

  void _ensureCapacity(int required) {
    final currentCapacity = _transforms.length ~/ 4;
    if (required <= currentCapacity) return;
    var nextCapacity = currentCapacity;
    while (nextCapacity < required) {
      nextCapacity *= 2;
    }
    final nextTransforms = Float32List(nextCapacity * 4)
      ..setRange(0, _transforms.length, _transforms);
    final nextRects = Float32List(nextCapacity * 4)
      ..setRange(0, _rects.length, _rects);
    final nextColors = Int32List(nextCapacity)
      ..setRange(0, _colors.length, _colors);
    _transforms = nextTransforms;
    _rects = nextRects;
    _colors = nextColors;
  }

  void paint(Canvas canvas, Paint paint, double opacity) {
    if (_spriteCount == 0) return;
    final valueCount = _spriteCount * 4;
    final alpha = (opacity * 255).round().clamp(0, 255);
    final useColors = alpha < 255;
    if (useColors) {
      _colors.fillRange(0, _spriteCount, alpha << 24);
    }
    canvas.drawRawAtlas(
      image,
      Float32List.sublistView(_transforms, 0, valueCount),
      Float32List.sublistView(_rects, 0, valueCount),
      useColors ? Int32List.sublistView(_colors, 0, _spriteCount) : null,
      useColors ? BlendMode.srcIn : null,
      null,
      paint,
    );
  }

  void dispose() => image.dispose();
}

@visibleForTesting
Offset resolveDanmakuAtlasDestination(
  double x,
  double y,
  double devicePixelRatio, {
  bool continuousHorizontal = true,
}) {
  return Offset(
    continuousHorizontal ? x : _snapDanmakuLogicalPixel(x, devicePixelRatio),
    _snapDanmakuLogicalPixel(y, devicePixelRatio),
  );
}

double _snapDanmakuLogicalPixel(double value, double devicePixelRatio) {
  final dpr = devicePixelRatio.isFinite && devicePixelRatio > 0
      ? devicePixelRatio
      : 1.0;
  return (value * dpr).round() / dpr;
}

class _DanmakuPerformanceGovernor extends ChangeNotifier {
  final Queue<bool> _overBudgetWindow = Queue<bool>();
  final Queue<int> _vsyncIntervalsUs = Queue<int>();
  TimingsCallback? _callback;
  int? _lastVsyncUs;
  int _level = 0;
  int _admissionCap = _unrestrictedDanmakuAdmissions;
  int _recoveryFrames = 0;
  int _consecutiveSevereFrames = 0;
  double? _refreshRate;

  bool get constrainPrefetch => _level >= 1;
  int get admissionCap => _admissionCap;

  void updateRefreshRate(double refreshRate) {
    _refreshRate =
        refreshRate.isFinite && refreshRate >= 20 && refreshRate <= 500
        ? refreshRate
        : null;
  }

  void start() {
    if (_callback != null) return;
    _callback = _handleTimings;
    SchedulerBinding.instance.addTimingsCallback(_callback!);
  }

  void _handleTimings(List<FrameTiming> timings) {
    var changed = false;
    for (final timing in timings) {
      final vsyncUs = timing.timestampInMicroseconds(ui.FramePhase.vsyncStart);
      final intervalUs = _lastVsyncUs == null ? 16667 : vsyncUs - _lastVsyncUs!;
      _lastVsyncUs = vsyncUs;
      if (intervalUs >= 5000 && intervalUs <= 34000) {
        _vsyncIntervalsUs.addLast(intervalUs);
        if (_vsyncIntervalsUs.length > 60) _vsyncIntervalsUs.removeFirst();
      }
      final budgetUs = _resolveFrameBudgetUs();
      final workUs = math.max(
        timing.buildDuration.inMicroseconds,
        timing.rasterDuration.inMicroseconds,
      );
      final overBudget = workUs > budgetUs * 0.8;
      _overBudgetWindow.addLast(overBudget);
      if (_overBudgetWindow.length > 12) _overBudgetWindow.removeFirst();

      if (workUs < budgetUs * 0.6) {
        _recoveryFrames++;
      } else {
        _recoveryFrames = 0;
      }

      if (workUs > budgetUs * 1.2) {
        _consecutiveSevereFrames++;
      } else {
        _consecutiveSevereFrames = 0;
      }

      if (_consecutiveSevereFrames >= 3) {
        _consecutiveSevereFrames = 0;
        _recoveryFrames = 0;
        _overBudgetWindow.clear();
        if (_level == 0) {
          _level = 1;
          _admissionCap = _adaptiveDanmakuAdmissionCap;
          changed = true;
        } else if (_level == 1) {
          _level = 2;
          _admissionCap = _severeDanmakuAdmissionCap;
          changed = true;
        } else {
          final reduced = math.max(32, (_admissionCap * 0.8).floor());
          if (reduced != _admissionCap) {
            _admissionCap = reduced;
            changed = true;
          }
        }
      } else if (_overBudgetWindow.length == 12 &&
          _overBudgetWindow.where((value) => value).length >= 8) {
        _recoveryFrames = 0;
        _overBudgetWindow.clear();
        if (_level == 0) {
          _level = 1;
          _admissionCap = _adaptiveDanmakuAdmissionCap;
          changed = true;
        } else if (_level == 1) {
          _level = 2;
          _admissionCap = _severeDanmakuAdmissionCap;
          changed = true;
        } else {
          final reduced = math.max(32, (_admissionCap * 0.8).floor());
          if (reduced != _admissionCap) {
            _admissionCap = reduced;
            changed = true;
          }
        }
      } else if (_recoveryFrames >= 120 && _level > 0) {
        _recoveryFrames = 0;
        _overBudgetWindow.clear();
        if (_level == 2) {
          if (_admissionCap < _severeDanmakuAdmissionCap) {
            _admissionCap = math.min(
              _severeDanmakuAdmissionCap,
              math.max(_admissionCap + 1, (_admissionCap * 1.25).ceil()),
            );
          } else {
            _level = 1;
            _admissionCap = _adaptiveDanmakuAdmissionCap;
          }
        } else {
          _level = 0;
          _admissionCap = _unrestrictedDanmakuAdmissions;
        }
        changed = true;
      }
    }
    if (changed) notifyListeners();
  }

  int _resolveFrameBudgetUs() {
    final refreshRate = _refreshRate;
    if (refreshRate != null) return (1000000 / refreshRate).round();
    if (_vsyncIntervalsUs.length < 4) return 16667;
    final samples = _vsyncIntervalsUs.toList()..sort();
    // The lower quartile represents the panel's actual VSync interval while
    // ignoring doubled intervals caused by frames that were already missed.
    return samples[((samples.length - 1) * 0.25).round()].clamp(5000, 34000);
  }

  @override
  void dispose() {
    final callback = _callback;
    if (callback != null) {
      SchedulerBinding.instance.removeTimingsCallback(callback);
      _callback = null;
    }
    super.dispose();
  }
}

int _atlasMemoryBudget() {
  if (kIsWeb) return 64 * 1024 * 1024;
  return switch (defaultTargetPlatform) {
    TargetPlatform.android || TargetPlatform.iOS => 64 * 1024 * 1024,
    _ => 128 * 1024 * 1024,
  };
}
