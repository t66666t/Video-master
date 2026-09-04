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
import 'media_playback_service.dart';

class PlaybackNavigationService {
  PlaybackNavigationService._();

  static final PlaybackNavigationService instance =
      PlaybackNavigationService._();

  static const String portraitRouteName = '/playback/portrait';
  static const String landscapeRouteName = '/playback/landscape';

  final PlaybackRouteObserver observer = PlaybackRouteObserver();
  Future<void> _navigationQueue = Future<void>.value();
  bool _suppressAutoPauseOnRouteCleanup = false;
  final Object _navigationVisibilityOwner = Object();

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
    return MaterialPageRoute<void>(
      builder: (context) => PortraitVideoScreen(videoItem: item),
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
      (_) => _openPlaybackInternal(item, notificationEntry: true),
    );
    return _navigationQueue;
  }

  /// Opens the authoritative current session for both notification and mini
  /// player taps. The temporary visibility owner lets Android create a real
  /// video output before the route exists, while navigation happens as soon as
  /// that controller is mountable (first-frame readiness may then complete).
  Future<void> openCurrentPlaybackSession(
    MediaPlaybackService playbackService, {
    int? expectedGeneration,
  }) async {
    _navigationQueue = _navigationQueue.then((_) async {
      // Generations only move forward. A delayed tap is allowed to converge on
      // a newer current session, but must never navigate using a service that
      // has somehow been reset behind the captured notification generation.
      if (expectedGeneration != null &&
          playbackService.sessionGeneration < expectedGeneration) {
        return;
      }
      var item = playbackService.currentItem;
      if (item == null) return;

      playbackService.setPlaybackPageVisible(_navigationVisibilityOwner, true);
      try {
        if (playbackService.needsVisibleVideoOutputRecovery(item.id)) {
          unawaited(playbackService.ensureVisibleVideoOutput(item.id));
        }
        await _waitForPresentableSession(playbackService, item.id);
        // The wait above can time out (25s) with the session still lacking a
        // visible output — e.g. the background attach attempts already failed.
        // Run the recovery once more and let it finish: it now reopens the
        // same media at the same position with the same play intent as a last
        // resort, so the playback page mounts a working controller instead of
        // falling back to a full media reload after navigation.
        if (playbackService.currentItem?.id == item.id &&
            playbackService.needsVisibleVideoOutputRecovery(item.id)) {
          await playbackService
              .ensureVisibleVideoOutput(item.id)
              .timeout(const Duration(seconds: 25), onTimeout: () => false);
        }
        item = playbackService.currentItem;
        if (item == null) return;
        await _openPlaybackInternal(item);
        await WidgetsBinding.instance.endOfFrame;
      } finally {
        playbackService.setPlaybackPageVisible(
          _navigationVisibilityOwner,
          false,
        );
      }
    });
    return _navigationQueue;
  }

  /// Notification body taps follow the pre-streaming behavior: navigate to
  /// the service's current item immediately. They must not join video-output
  /// recovery or reopen the media, because a control-button episode change
  /// may still be settling when Android brings the app to the foreground.
  Future<void> openCurrentPlaybackSessionFromNotification(
    MediaPlaybackService playbackService, {
    int? expectedGeneration,
  }) async {
    _navigationQueue = _navigationQueue.then((_) async {
      if (expectedGeneration != null &&
          playbackService.sessionGeneration < expectedGeneration) {
        return;
      }
      final item = playbackService.currentItem;
      if (item == null) return;
      final warmOnlineVideo = playbackService.isCurrentItemOnlineBilibiliStream;
      if (warmOnlineVideo) {
        // Resume the split video track as soon as the notification body is
        // tapped. The portrait route still mounts the same Player and external
        // audio clock, so foreground entry never performs an audible hand-off.
        // Materialized Bilibili items and ordinary local files skip this path.
        playbackService.setPlaybackPageVisible(
          _navigationVisibilityOwner,
          true,
        );
      }
      try {
        await _openPlaybackInternal(item, notificationEntry: true);
        if (warmOnlineVideo) await WidgetsBinding.instance.endOfFrame;
      } finally {
        if (warmOnlineVideo) {
          playbackService.setPlaybackPageVisible(
            _navigationVisibilityOwner,
            false,
          );
        }
      }
    });
    return _navigationQueue;
  }

  Future<void> _waitForPresentableSession(
    MediaPlaybackService service,
    String itemId,
  ) async {
    bool isPresentable() {
      if (service.currentItem?.id != itemId) return true;
      return service.canMountControllerFor(itemId) ||
          service.isSourceMissing ||
          service.state == PlaybackState.error ||
          service.state == PlaybackState.idle;
    }

    if (isPresentable()) return;
    final completer = Completer<void>();
    void listener() {
      if (isPresentable() && !completer.isCompleted) completer.complete();
    }

    service.addListener(listener);
    try {
      await completer.future.timeout(
        const Duration(seconds: 25),
        onTimeout: () {},
      );
    } finally {
      service.removeListener(listener);
    }
  }

  Future<void> _openPlaybackInternal(
    VideoItem item, {
    bool notificationEntry = false,
  }) async {
    final navigator = await _waitForNavigator();
    if (navigator == null) {
      return;
    }

    final trackedRoutes = observer.routes;
    final playbackRoutes = trackedRoutes
        .where((route) => isPlaybackRouteName(route.settings.name))
        .toList(growable: false);

    final Route<dynamic>? topRoute = observer.topRoute;
    final bool alreadyOnTargetPlayback =
        topRoute != null &&
        isPlaybackRouteName(topRoute.settings.name) &&
        topRoute.settings.arguments == item.id;
    // A notification entry has one canonical mobile back stack: media library
    // root -> current portrait player. Merely finding the target player on top
    // is insufficient because a stale MusicPlayerScreen may still sit below it.
    final bool hasCanonicalNotificationStack =
        notificationEntry &&
        trackedRoutes.length == 2 &&
        alreadyOnTargetPlayback &&
        trackedRoutes.first.isFirst;
    if ((!notificationEntry && alreadyOnTargetPlayback) ||
        hasCanonicalNotificationStack) {
      return;
    }

    _suppressAutoPauseOnRouteCleanup = true;
    try {
      final routesToRemove = notificationEntry
          ? trackedRoutes.skip(1).toList(growable: false)
          : playbackRoutes;
      for (final route in routesToRemove.reversed) {
        navigator.removeRoute(route);
      }

      // iOS and Android notification taps always enter the portrait playback
      // page, independent of the normal "skip portrait player" preference.
      // Popping it therefore returns directly to the media-management root.
      final route = notificationEntry
          ? buildPortraitRoute(item)
          : buildPlaybackEntryRoute(item);
      unawaited(navigator.push(route));
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
