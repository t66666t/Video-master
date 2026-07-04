import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';

enum AppToastType { info, success, error }

class AppToastAction {
  final String label;
  final VoidCallback onPressed;

  const AppToastAction({
    required this.label,
    required this.onPressed,
  });
}

class AppToast {
  static final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();
  static final NavigatorObserver observer = _ToastNavigatorObserver();
  static final RouteObserver<PageRoute<dynamic>> routeObserver = RouteObserver<PageRoute<dynamic>>();

  static OverlayEntry? _entry;
  static Timer? _dismissTimer;
  static _ToastOverlayController? _controller;
  static ValueNotifier<_ToastViewData>? _contentNotifier;
  static bool _isLoading = false;

  static void show(
    String message, {
    AppToastType type = AppToastType.info,
    Duration duration = const Duration(milliseconds: 1500),
    AppToastAction? action,
  }) {
    _isLoading = false;
    _showEntry(
      _ToastContent(
        message: message,
        type: type,
        showSpinner: false,
        action: action,
      ),
      autoDismissAfter: duration,
    );
  }

  static void showLoading(String message) {
    _isLoading = true;
    _showEntryData(
      const _ToastViewData(
        message: '',
        type: AppToastType.info,
        showSpinner: true,
      ).copyWith(message: message),
      autoDismissAfter: const Duration(seconds: 8),
    );
  }

  static void showProgress(
    String message, {
    double? progress,
    AppToastType type = AppToastType.info,
  }) {
    _isLoading = true;
    _showEntryData(
      _ToastViewData(
        message: message,
        type: type,
        showSpinner: progress == null,
        progress: progress,
      ),
      autoDismissAfter: const Duration(seconds: 8),
    );
  }

  static void updateProgress({
    String? message,
    double? progress,
    AppToastType? type,
  }) {
    final notifier = _contentNotifier;
    final current = notifier?.value;
    if (notifier == null || current == null) {
      if (message != null) {
        showProgress(
          message,
          progress: progress,
          type: type ?? AppToastType.info,
        );
      }
      return;
    }

    _isLoading = true;
    _dismissTimer?.cancel();
    _dismissTimer = Timer(const Duration(seconds: 8), () {
      if (_isLoading) return;
      dismiss();
    });
    notifier.value = current.copyWith(
      message: message,
      progress: progress,
      type: type,
      showSpinner: progress == null,
      action: null,
    );
  }

  static Future<void> dismiss({
    bool immediate = false,
    bool fromSwipe = false,
  }) async {
    _dismissTimer?.cancel();
    _dismissTimer = null;

    final controller = _controller;
    final entry = _entry;
    _controller = null;
    _entry = null;
    final contentNotifier = _contentNotifier;
    _contentNotifier = null;

    if (entry == null) {
      contentNotifier?.dispose();
      _isLoading = false;
      return;
    }

    if (immediate || controller == null) {
      if (entry.mounted) {
        entry.remove();
      }
      contentNotifier?.dispose();
      _isLoading = false;
      return;
    }

    await controller.hide(animateSwipeAway: fromSwipe);
    if (entry.mounted) {
      entry.remove();
    }
    contentNotifier?.dispose();
    _isLoading = false;
  }

  static bool isCurrentRoute(String routeName) {
    return observer is _ToastNavigatorObserver &&
        (observer as _ToastNavigatorObserver).currentRouteName == routeName;
  }

  static void _showEntry(_ToastContent content, {Duration? autoDismissAfter}) {
    _showEntryData(
      _ToastViewData(
        message: content.message,
        type: content.type,
        showSpinner: content.showSpinner,
        action: content.action,
        progress: content.progress,
      ),
      autoDismissAfter: autoDismissAfter,
    );
  }

  static void _showEntryData(
    _ToastViewData content, {
    Duration? autoDismissAfter,
  }) {
    final overlay = navigatorKey.currentState?.overlay;
    if (overlay == null) return;

    _dismissTimer?.cancel();
    _dismissTimer = null;

    final existingNotifier = _contentNotifier;
    final existingEntry = _entry;
    if (existingNotifier != null && existingEntry != null && existingEntry.mounted) {
      existingNotifier.value = content;
      if (autoDismissAfter != null) {
        _dismissTimer = Timer(autoDismissAfter, () {
          if (_isLoading) return;
          dismiss();
        });
      }
      return;
    }

    final oldEntry = _entry;
    final oldNotifier = _contentNotifier;
    _entry = null;
    _controller = null;
    _contentNotifier = null;
    if (oldEntry != null && oldEntry.mounted) {
      oldEntry.remove();
    }
    oldNotifier?.dispose();

    final contentNotifier = ValueNotifier<_ToastViewData>(content);

    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (context) {
        return _ToastOverlayHost(
          onControllerReady: (controller) {
            if (_entry == entry) {
              _controller = controller;
            }
          },
          child: ValueListenableBuilder<_ToastViewData>(
            valueListenable: contentNotifier,
            builder: (context, data, _) {
              return _ToastContent(
                message: data.message,
                type: data.type,
                showSpinner: data.showSpinner,
                action: data.action,
                progress: data.progress,
              );
            },
          ),
        );
      },
    );

    _entry = entry;
    _contentNotifier = contentNotifier;
    overlay.insert(entry);

    if (autoDismissAfter != null) {
      _dismissTimer = Timer(autoDismissAfter, () {
        if (_isLoading) return;
        dismiss();
      });
    }
  }
}

class _ToastNavigatorObserver extends NavigatorObserver {
  String? currentRouteName;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    currentRouteName = route.settings.name;
    super.didPush(route, previousRoute);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    currentRouteName = previousRoute?.settings.name;
    super.didPop(route, previousRoute);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    currentRouteName = newRoute?.settings.name;
    super.didReplace(newRoute: newRoute, oldRoute: oldRoute);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    currentRouteName = previousRoute?.settings.name;
    super.didRemove(route, previousRoute);
  }
}

class _ToastOverlayHost extends StatelessWidget {
  final Widget child;
  final ValueChanged<_ToastOverlayController> onControllerReady;

  const _ToastOverlayHost({
    required this.child,
    required this.onControllerReady,
  });

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final horizontalPadding = (size.width * 0.04).clamp(12.0, 24.0);
    final topPadding = (size.height * 0.014).clamp(8.0, 18.0);

    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        bottom: false,
        child: Align(
          alignment: Alignment.topCenter,
          child: Padding(
            padding: EdgeInsets.only(
              top: topPadding,
              left: horizontalPadding,
              right: horizontalPadding,
            ),
            child: _ToastAnimatedContainer(
              onControllerReady: onControllerReady,
              child: child,
            ),
          ),
        ),
      ),
    );
  }
}

class _ToastAnimatedContainer extends StatefulWidget {
  final Widget child;
  final ValueChanged<_ToastOverlayController> onControllerReady;

  const _ToastAnimatedContainer({
    required this.child,
    required this.onControllerReady,
  });

  @override
  State<_ToastAnimatedContainer> createState() => _ToastAnimatedContainerState();
}

class _ToastAnimatedContainerState extends State<_ToastAnimatedContainer>
    with SingleTickerProviderStateMixin {
  static const Duration _dragReleaseDuration = Duration(milliseconds: 180);

  late final AnimationController _controller;
  late final Animation<double> _opacity;
  late final Animation<double> _scale;
  late final Animation<Offset> _slide;
  final GlobalKey _toastKey = GlobalKey();
  double _dragOffsetY = 0;
  double _toastHeight = 0;
  bool _isDragging = false;
  bool _isHiding = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
      reverseDuration: const Duration(milliseconds: 140),
    );
    final curved = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    _opacity = curved;
    _scale = Tween<double>(begin: 0.965, end: 1).animate(curved);
    _slide = Tween<Offset>(
      begin: const Offset(0, -0.08),
      end: Offset.zero,
    ).animate(curved);
    widget.onControllerReady(_ToastOverlayController(_hide));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _updateToastHeight();
      _controller.forward();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _updateToastHeight() {
    final context = _toastKey.currentContext;
    if (context == null) return;
    final nextHeight = context.size?.height;
    if (nextHeight == null || nextHeight <= 0 || nextHeight == _toastHeight) {
      return;
    }
    _toastHeight = nextHeight;
  }

  double _dismissTargetOffset() {
    final effectiveHeight = _toastHeight > 0 ? _toastHeight : 72.0;
    return -(effectiveHeight + 24);
  }

  Future<void> _hide({bool animateSwipeAway = false}) async {
    if (!mounted || _isHiding) return;
    _isHiding = true;

    if (animateSwipeAway) {
      setState(() {
        _isDragging = false;
        _dragOffsetY = _dismissTargetOffset();
      });
      await Future<void>.delayed(_dragReleaseDuration);
    }

    await _controller.reverse();
  }

  void _handleVerticalDragUpdate(DragUpdateDetails details) {
    if (_isHiding) return;
    final nextOffset = (_dragOffsetY + details.delta.dy).clamp(-160.0, 0.0);
    if (nextOffset == _dragOffsetY) return;
    setState(() {
      _isDragging = true;
      _dragOffsetY = nextOffset;
    });
  }

  void _handleVerticalDragEnd(DragEndDetails details) {
    if (_isHiding) return;
    final velocity = details.primaryVelocity ?? 0;
    final shouldDismiss = _dragOffsetY <= -36 || velocity <= -700;
    if (shouldDismiss) {
      AppToast.dismiss(fromSwipe: true);
      return;
    }
    if (_dragOffsetY == 0 && !_isDragging) return;
    setState(() {
      _isDragging = false;
      _dragOffsetY = 0;
    });
  }

  void _handleVerticalDragCancel() {
    if (_isHiding || (!_isDragging && _dragOffsetY == 0)) return;
    setState(() {
      _isDragging = false;
      _dragOffsetY = 0;
    });
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onVerticalDragUpdate: _handleVerticalDragUpdate,
      onVerticalDragEnd: _handleVerticalDragEnd,
      onVerticalDragCancel: _handleVerticalDragCancel,
      child: TweenAnimationBuilder<double>(
        tween: Tween<double>(end: _dragOffsetY),
        duration: _isDragging
            ? Duration.zero
            : const Duration(milliseconds: 120),
        curve: Curves.easeOutCubic,
        builder: (context, dragOffsetY, child) {
          final dragProgress = (-dragOffsetY / 120).clamp(0.0, 1.0);
          final animatedOpacity = 1 - (dragProgress * 0.32);
          final animatedScale = 1 - (dragProgress * 0.02);

          return Transform.translate(
            offset: Offset(0, dragOffsetY),
            child: Transform.scale(
              scale: animatedScale,
              alignment: Alignment.topCenter,
              child: Opacity(
                opacity: animatedOpacity,
                child: child,
              ),
            ),
          );
        },
        child: FadeTransition(
          opacity: _opacity,
          child: SlideTransition(
            position: _slide,
            child: ScaleTransition(
              scale: _scale,
              alignment: Alignment.topCenter,
              child: KeyedSubtree(
                key: _toastKey,
                child: widget.child,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ToastOverlayController {
  final Future<void> Function({bool animateSwipeAway}) hide;

  _ToastOverlayController(this.hide);
}

class _ToastContent extends StatelessWidget {
  final String message;
  final AppToastType type;
  final bool showSpinner;
  final AppToastAction? action;
  final double? progress;

  const _ToastContent({
    required this.message,
    required this.type,
    required this.showSpinner,
    required this.action,
    this.progress,
  });

  Color _accentColor(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    switch (type) {
      case AppToastType.success:
        return const Color(0xFF62D394);
      case AppToastType.error:
        return scheme.error;
      case AppToastType.info:
        return const Color(0xFF8BC3FF);
    }
  }

  IconData _iconData() {
    switch (type) {
      case AppToastType.success:
        return Icons.check_rounded;
      case AppToastType.error:
        return Icons.error_outline_rounded;
      case AppToastType.info:
        return Icons.info_outlined;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = _accentColor(context);
    final size = MediaQuery.of(context).size;
    final scale = (size.shortestSide / 390).clamp(0.9, 1.16);
    final maxWidth = size.width * 0.68;
    final isDark = theme.brightness == Brightness.dark;
    final backgroundColor = isDark
        ? const Color(0xFF1E1F22).withValues(alpha: 0.78)
        : Colors.white.withValues(alpha: 0.88);
    final textColor = theme.colorScheme.onSurface.withValues(alpha: 0.9);
    final iconSize = 17.5 * scale;
    final iconContainerSize = 27.5 * scale;
    final basePadding = 13.5 * scale;
    final verticalPadding = 10.5 * scale;
    final gap = 10 * scale;
    final fontSize = 13.6 * scale;
    final actionFontSize = 12.9 * scale;
    final hasProgress = progress != null;
    final progressValue = progress?.clamp(0.0, 1.0).toDouble();
    final progressText = progressValue == null
        ? null
        : '${(progressValue * 100).round()}%';

    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: IntrinsicWidth(
        child: Material(
          color: Colors.transparent,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(18 * scale),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: backgroundColor,
                  borderRadius: BorderRadius.circular(18 * scale),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: isDark ? 0.12 : 0.2),
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: isDark ? 0.18 : 0.08),
                      blurRadius: 18,
                      offset: const Offset(0, 8),
                    ),
                  ],
                ),
                child: Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: basePadding,
                    vertical: verticalPadding,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Container(
                            width: iconContainerSize,
                            height: iconContainerSize,
                            decoration: BoxDecoration(
                              color: accent.withValues(alpha: 0.14),
                              borderRadius: BorderRadius.circular(999),
                            ),
                            alignment: Alignment.center,
                            child: hasProgress && progressValue != null
                                ? Stack(
                                    alignment: Alignment.center,
                                    children: [
                                      SizedBox(
                                        width: iconContainerSize,
                                        height: iconContainerSize,
                                        child: CircularProgressIndicator(
                                          value: progressValue,
                                          strokeWidth: 2.1,
                                          backgroundColor: accent.withValues(alpha: 0.18),
                                          valueColor: AlwaysStoppedAnimation<Color>(accent),
                                        ),
                                      ),
                                      Text(
                                        progressText!,
                                        style: TextStyle(
                                          fontSize: 8.4 * scale,
                                          fontWeight: FontWeight.w700,
                                          color: accent,
                                        ),
                                      ),
                                    ],
                                  )
                                : showSpinner
                                    ? SizedBox(
                                        width: iconSize,
                                        height: iconSize,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2.1,
                                          valueColor: AlwaysStoppedAnimation<Color>(accent),
                                        ),
                                      )
                                    : Icon(
                                        _iconData(),
                                        size: iconSize,
                                        color: accent,
                                      ),
                          ),
                          SizedBox(width: gap),
                          Flexible(
                            fit: FlexFit.loose,
                            child: Text(
                              message,
                              style: TextStyle(
                                fontSize: fontSize,
                                height: 1.28,
                                fontWeight: FontWeight.w500,
                                color: textColor,
                              ),
                              maxLines: hasProgress
                                  ? 3
                                  : (action == null ? 2 : 3),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (action != null) ...[
                            SizedBox(width: gap * 0.85),
                            TextButton(
                              onPressed: () {
                                AppToast.dismiss();
                                action!.onPressed();
                              },
                              style: TextButton.styleFrom(
                                minimumSize: Size.zero,
                                padding: EdgeInsets.symmetric(
                                  horizontal: 11.5 * scale,
                                  vertical: 5.5 * scale,
                                ),
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                foregroundColor: accent,
                                backgroundColor: accent.withValues(alpha: 0.12),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(999),
                                ),
                              ),
                              child: Text(
                                action!.label,
                                style: TextStyle(
                                  fontSize: actionFontSize,
                                  fontWeight: FontWeight.w600,
                                  color: accent,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                      if (hasProgress && progressValue != null) ...[
                        SizedBox(height: 8 * scale),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(999),
                          child: LinearProgressIndicator(
                            value: progressValue,
                            minHeight: 4 * scale,
                            backgroundColor: accent.withValues(alpha: 0.14),
                            valueColor: AlwaysStoppedAnimation<Color>(accent),
                          ),
                        ),
                      ],
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

class _ToastViewData {
  final String message;
  final AppToastType type;
  final bool showSpinner;
  final AppToastAction? action;
  final double? progress;

  const _ToastViewData({
    required this.message,
    required this.type,
    required this.showSpinner,
    this.action,
    this.progress,
  });

  _ToastViewData copyWith({
    String? message,
    AppToastType? type,
    bool? showSpinner,
    AppToastAction? action,
    double? progress,
  }) {
    return _ToastViewData(
      message: message ?? this.message,
      type: type ?? this.type,
      showSpinner: showSpinner ?? this.showSpinner,
      action: action,
      progress: progress,
    );
  }
}
