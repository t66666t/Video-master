import 'dart:async';
import 'package:flutter/material.dart';

enum AppToastType { info, success, error }

class AppToast {
  static final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();
  static final NavigatorObserver observer = _ToastNavigatorObserver();

  static OverlayEntry? _entry;
  static Timer? _dismissTimer;
  static bool _isLoading = false;

  static void show(
    String message, {
    AppToastType type = AppToastType.info,
    Duration duration = const Duration(milliseconds: 1600),
  }) {
    _isLoading = false;
    _showEntry(
      _ToastContent(
        message: message,
        type: type,
        showSpinner: false,
      ),
      autoDismissAfter: duration,
    );
  }

  static void showLoading(String message) {
    _isLoading = true;
    _showEntry(
      _ToastContent(
        message: message,
        type: AppToastType.info,
        showSpinner: true,
      ),
      autoDismissAfter: const Duration(seconds: 8),
    );
  }

  static void dismiss() {
    _dismissTimer?.cancel();
    _dismissTimer = null;
    _entry?.remove();
    _entry = null;
    _isLoading = false;
  }

  static void _showEntry(_ToastContent content, {Duration? autoDismissAfter}) {
    final overlay = navigatorKey.currentState?.overlay;
    if (overlay == null) return;

    _dismissTimer?.cancel();
    _dismissTimer = null;

    _entry?.remove();
    _entry = null;

    final entry = OverlayEntry(
      builder: (context) {
        return Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: SafeArea(
            bottom: false,
            child: Align(
              alignment: Alignment.topCenter,
              child: Padding(
                padding: const EdgeInsets.only(top: 12, left: 12, right: 12),
                child: IgnorePointer(
                  ignoring: true,
                  child: _ToastAnimatedContainer(
                    child: content,
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );

    _entry = entry;
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
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    AppToast.dismiss();
    super.didPush(route, previousRoute);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    AppToast.dismiss();
    super.didPop(route, previousRoute);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    AppToast.dismiss();
    super.didReplace(newRoute: newRoute, oldRoute: oldRoute);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    AppToast.dismiss();
    super.didRemove(route, previousRoute);
  }
}
class _ToastAnimatedContainer extends StatefulWidget {
  final Widget child;
  const _ToastAnimatedContainer({required this.child});

  @override
  State<_ToastAnimatedContainer> createState() => _ToastAnimatedContainerState();
}

class _ToastAnimatedContainerState extends State<_ToastAnimatedContainer> {
  bool _visible = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() => _visible = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedOpacity(
      opacity: _visible ? 1 : 0,
      duration: const Duration(milliseconds: 120),
      curve: Curves.easeOut,
      child: AnimatedSlide(
        offset: _visible ? Offset.zero : const Offset(0, -0.08),
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
        child: widget.child,
      ),
    );
  }
}

class _ToastContent extends StatelessWidget {
  final String message;
  final AppToastType type;
  final bool showSpinner;

  const _ToastContent({
    required this.message,
    required this.type,
    required this.showSpinner,
  });

  Color _backgroundColor(BuildContext context) {
    switch (type) {
      case AppToastType.success:
        return const Color(0xFF1F2B1F);
      case AppToastType.error:
        return const Color(0xFF2B1F1F);
      case AppToastType.info:
        return const Color(0xFF1E1E1E);
    }
  }

  Color _accentColor(BuildContext context) {
    switch (type) {
      case AppToastType.success:
        return const Color(0xFF4CAF50);
      case AppToastType.error:
        return const Color(0xFFF44336);
      case AppToastType.info:
        return const Color(0xFF90CAF9);
    }
  }

  @override
  Widget build(BuildContext context) {
    final accent = _accentColor(context);
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 520),
      child: Material(
        type: MaterialType.transparency,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: _backgroundColor(context).withValues(alpha: 0.92),
            borderRadius: BorderRadius.circular(12),
            boxShadow: const [
              BoxShadow(
                color: Color(0x33000000),
                blurRadius: 14,
                offset: Offset(0, 6),
              ),
            ],
            border: Border.all(color: accent.withValues(alpha: 0.35), width: 1),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 6,
                  height: 18,
                  decoration: BoxDecoration(
                    color: accent,
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
                const SizedBox(width: 10),
                if (showSpinner) ...[
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 10),
                ],
                Flexible(
                  child: Text(
                    message,
                    style: const TextStyle(fontSize: 13, height: 1.2),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
