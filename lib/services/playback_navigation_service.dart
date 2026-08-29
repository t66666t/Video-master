import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart' show VideoPlayerController;

import '../models/video_item.dart';
import '../screens/portrait_video_screen.dart';
import '../screens/video_player_screen.dart';
import '../utils/app_toast.dart';
import 'settings_service.dart';

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

  /// 在临时抑制"退出自动暂停"的前提下移除路由，
  /// 避免被移除的播放页在清理时误暂停仍在播放的控制器。
  void removeRouteSuppressed(NavigatorState navigator, Route<dynamic> route) {
    _suppressAutoPauseOnRouteCleanup = true;
    try {
      navigator.removeRoute(route);
    } finally {
      _suppressAutoPauseOnRouteCleanup = false;
    }
  }

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

  /// 桌面端以及开启"跳过竖屏播放页"的移动端，直接进入横屏播放页。
  static bool get entrySkipsPortraitPlayer {
    if (kIsWeb) return true;
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      return true;
    }
    return SettingsService().skipPortraitPlayer;
  }

  /// 媒体卡片点击后的统一播放入口路由：
  /// 桌面端或开启"跳过竖屏播放页"时直入横屏播放页，否则进入竖屏播放页。
  /// 两个分支都使用 `MaterialPageRoute`，共用平台默认页面转场，
  /// 使直入横屏页的进入/返回与竖屏播放页的导航手感一致。
  static Route<void> buildPlaybackEntryRoute(
    VideoItem item, {
    VideoPlayerController? existingController,
  }) {
    if (entrySkipsPortraitPlayer) {
      return MaterialPageRoute<void>(
        settings: landscapeRouteSettings(item),
        builder: (context) => VideoPlayerScreen(
          videoItem: item,
          existingController: existingController,
        ),
      );
    }
    return MaterialPageRoute<void>(
      settings: portraitRouteSettings(item),
      builder: (context) => PortraitVideoScreen(videoItem: item),
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

      unawaited(navigator.push(buildPlaybackEntryRoute(item)));
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
