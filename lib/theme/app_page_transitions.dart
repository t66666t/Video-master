import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// Full-page zoom used on every platform.
///
/// This is the transition Windows and Linux already used. iOS, macOS, and
/// Android use the same zoom so a push does not slide sideways.
const PageTransitionsTheme appPageTransitionsTheme = PageTransitionsTheme(
  builders: <TargetPlatform, PageTransitionsBuilder>{
    TargetPlatform.android: ZoomPageTransitionsBuilder(),
    TargetPlatform.iOS: ZoomPageTransitionsBuilder(),
    TargetPlatform.macOS: ZoomPageTransitionsBuilder(),
    TargetPlatform.windows: ZoomPageTransitionsBuilder(),
    TargetPlatform.linux: ZoomPageTransitionsBuilder(),
    TargetPlatform.fuchsia: ZoomPageTransitionsBuilder(),
  },
);

/// [MaterialPageRoute] whose zoom starts on the frame after the navigation.
///
/// A library or player route is heavy enough that a zoom started during the
/// push or pop is already finished when that frame is painted. Waiting one
/// frame lets the same zoom actually play on the way in and the way out, on
/// every platform.
class AppMaterialPageRoute<T> extends MaterialPageRoute<T> {
  AppMaterialPageRoute({
    required super.builder,
    super.settings,
    super.requestFocus,
    super.maintainState,
    super.fullscreenDialog,
    super.allowSnapshotting,
    super.barrierDismissible,
    super.traversalEdgeBehavior,
    super.directionalTraversalEdgeBehavior,
  });

  bool _disposed = false;

  /// Subclasses that must appear in the same frame skip the one-frame hold.
  @protected
  bool get delayPushOneFrame => true;

  @override
  TickerFuture didPush() {
    final pushed = super.didPush();
    if (delayPushOneFrame) _holdUntilNextFrame(exit: false);
    return pushed;
  }

  @override
  bool didPop(T? result) {
    final popped = super.didPop(result);
    if (popped) _holdUntilNextFrame(exit: true);
    return popped;
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  void _holdUntilNextFrame({required bool exit}) {
    final animationController = controller;
    if (animationController == null) return;
    animationController.value = exit ? 1 : 0;
    animationController.stop(canceled: false);
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (_disposed) return;
      final current = controller;
      if (current == null) return;
      if (exit) {
        if (current.status == AnimationStatus.dismissed || current.value == 0) {
          return;
        }
        current.reverse();
        return;
      }
      if (current.status == AnimationStatus.reverse ||
          current.status == AnimationStatus.completed) {
        return;
      }
      current.forward();
    });
  }
}
