import 'dart:async';

import 'package:flutter/material.dart';

import '../models/video_item.dart';
import '../screens/portrait_video_screen.dart';
import '../utils/app_toast.dart';

class PlaybackNavigationService {
  PlaybackNavigationService._();

  static final PlaybackNavigationService instance =
      PlaybackNavigationService._();

  static const String portraitRouteName = '/playback/portrait';
  static const String landscapeRouteName = '/playback/landscape';

  final PlaybackRouteObserver observer = PlaybackRouteObserver();
  Future<void> _navigationQueue = Future<void>.value();
  bool _suppressAutoPauseOnRouteCleanup = false;

  bool get suppressAutoPauseOnRouteCleanup => _suppressAutoPauseOnRouteCleanup;

  static bool isPlaybackRouteName(String? routeName) {
    return routeName == portraitRouteName || routeName == landscapeRouteName;
  }

  static RouteSettings portraitRouteSettings(VideoItem item) {
    return RouteSettings(name: portraitRouteName, arguments: item.id);
  }

  static RouteSettings landscapeRouteSettings(VideoItem item) {
    return RouteSettings(name: landscapeRouteName, arguments: item.id);
  }

  Route<void> buildPortraitRoute(VideoItem item) {
    return PageRouteBuilder<void>(
      pageBuilder: (context, animation, secondaryAnimation) =>
          PortraitVideoScreen(videoItem: item),
      transitionsBuilder: (context, animation, secondaryAnimation, child) {
        return child;
      },
      transitionDuration: Duration.zero,
      reverseTransitionDuration: Duration.zero,
      settings: portraitRouteSettings(item),
    );
  }

  Future<void> openPortraitFromNotification(VideoItem item) async {
    _navigationQueue = _navigationQueue.then(
      (_) => _openPortraitFromNotificationInternal(item),
    );
    return _navigationQueue;
  }

  Future<void> _openPortraitFromNotificationInternal(VideoItem item) async {
    final navigator = await _waitForNavigator();
    if (navigator == null) {
      return;
    }

    final playbackRoutes = observer.routes
        .where((route) => isPlaybackRouteName(route.settings.name))
        .toList(growable: false);

    final Route<dynamic>? topRoute = observer.topRoute;
    final bool alreadyOnTargetPlayback =
        topRoute != null &&
        isPlaybackRouteName(topRoute.settings.name) &&
        topRoute.settings.arguments == item.id;
    if (alreadyOnTargetPlayback) {
      return;
    }

    _suppressAutoPauseOnRouteCleanup = true;
    try {
      for (final route in playbackRoutes.reversed) {
        navigator.removeRoute(route);
      }

      unawaited(navigator.push(buildPortraitRoute(item)));
    } finally {
      _suppressAutoPauseOnRouteCleanup = false;
    }
  }

  Future<NavigatorState?> _waitForNavigator() async {
    final navigator = AppToast.navigatorKey.currentState;
    if (navigator != null) {
      return navigator;
    }

    final completer = Completer<NavigatorState?>();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      completer.complete(AppToast.navigatorKey.currentState);
    });
    return completer.future;
  }
}

class PlaybackRouteObserver extends NavigatorObserver {
  final List<Route<dynamic>> _routes = <Route<dynamic>>[];

  List<Route<dynamic>> get routes => List.unmodifiable(_routes);
  Route<dynamic>? get topRoute => _routes.isEmpty ? null : _routes.last;

  void _recordPush(Route<dynamic> route) {
    _routes.remove(route);
    _routes.add(route);
  }

  void _recordRemoval(Route<dynamic> route) {
    _routes.remove(route);
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _recordPush(route);
    super.didPush(route, previousRoute);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _recordRemoval(route);
    super.didPop(route, previousRoute);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _recordRemoval(route);
    super.didRemove(route, previousRoute);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    if (oldRoute != null) {
      _recordRemoval(oldRoute);
    }
    if (newRoute != null) {
      _recordPush(newRoute);
    }
    super.didReplace(newRoute: newRoute, oldRoute: oldRoute);
  }
}
