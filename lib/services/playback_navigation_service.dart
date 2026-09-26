import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:video_player_app/theme/app_page_transitions.dart';
import 'package:video_player/video_player.dart' show VideoPlayerController;

import '../models/video_item.dart';
import '../screens/portrait_video_screen.dart';
import '../screens/video_player_screen.dart';
import '../utils/app_toast.dart';
import 'settings_service.dart';
import 'media_playback_service.dart';

bool resolvePlaybackPageEntryAutoPlay({
  required bool? entryAutoPlay,
  required bool isCurrentItem,
  required bool desiredPlaying,
}) {
  // Enabling page-entry auto-play is an explicit request to start/resume.
  if (entryAutoPlay == true) return true;

  // Opening the page must never pause an already-active session when the
  // setting is off. This also preserves pause/play state during portrait ↔
  // landscape hand-offs and notification/mini-player navigation.
  if (isCurrentItem) return desiredPlaying;

  // null is used by internal/non-library routes and keeps their legacy
  // behavior. A library entry always supplies the persisted boolean.
  return entryAutoPlay ?? true;
}

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
    return buildPlaybackPageRoute<void>(
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
  /// 播放页和其它整页路由都使用 [AppMaterialPageRoute]，进入和退出的缩放
  /// 都会等下一帧再开始，避免重页面把动画吃成硬切。
  /// 播放页本身不拍缩放快照，避免 Windows 上回读视频纹理时把缩放卡住。
  static Route<void> buildPlaybackEntryRoute(
    VideoItem item, {
    VideoPlayerController? existingController,
  }) {
    final autoPlayOnEntry = SettingsService().autoPlayOnPageEntry;
    if (entrySkipsPortraitPlayer) {
      return buildPlaybackPageRoute<void>(
        settings: landscapeRouteSettings(item),
        builder: (context) => VideoPlayerScreen(
          videoItem: item,
          existingController: existingController,
          autoPlayOnEntry: autoPlayOnEntry,
        ),
      );
    }
    return buildPlaybackPageRoute<void>(
      settings: portraitRouteSettings(item),
      builder: (context) => PortraitVideoScreen(
        videoItem: item,
        autoPlayOnEntry: autoPlayOnEntry,
      ),
    );
  }

  /// 视频播放页路由。缩放照常播放，但不把这一页拍成快照。
  ///
  /// 快照会把正在显示的视频纹理从 GPU 读回。Windows 上这次回读会堵住光栅线程，
  /// 缩放要等回读结束才开始动。底下的文件夹路由仍使用自己的快照。
  static AppMaterialPageRoute<T> buildPlaybackPageRoute<T>({
    required WidgetBuilder builder,
    RouteSettings? settings,
  }) {
    return AppMaterialPageRoute<T>(
      builder: builder,
      settings: settings,
      allowSnapshotting: false,
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

      // Keep the warmup owner until a real playback page registers. Dropping
      // it after one frame used to deselect Bilibili's video track while the
      // route was still mounting, painting a black texture over a ready stream.
      _holdPlaybackPageVisibleUntilOwned(playbackService, maxAttempts: 1800);
      if (playbackService.controller == null) {
        // Restored Mini chrome has metadata only. Start prepare now so the
        // playback page does not wait 25s for a player that was never created.
        unawaited(
          playbackService.play(
            item,
            autoPlay: resolvePlaybackPageEntryAutoPlay(
              entryAutoPlay: SettingsService().autoPlayOnPageEntry,
              isCurrentItem: true,
              desiredPlaying: playbackService.desiredPlaying,
            ),
            startPosition: MediaPlaybackService.startPositionForCurrentSession(
              currentItemId: playbackService.currentItem?.id,
              itemId: item.id,
              currentPosition: playbackService.position,
            ),
          ),
        );
      }
      // Do not await video attach/enable. The page should open on the live
      // audio clock immediately; the texture catches up under the poster.
      if (playbackService.needsVisibleVideoOutputRecovery(item.id)) {
        unawaited(playbackService.ensureVisibleVideoOutput(item.id));
      }
      item = playbackService.currentItem;
      if (item == null) return;
      await _openPlaybackInternal(item);
    });
    return _navigationQueue;
  }

  /// Starts source preparation as soon as a library card is tapped, overlapping
  /// the page-route animation. Also marks a playback page as imminent so a
  /// Bilibili split stream keeps its video track selected during initialize.
  void primeLibraryPlaybackEntry({
    required MediaPlaybackService playbackService,
    required VideoItem item,
    VideoPlayerController? existingController,
  }) {
    _holdPlaybackPageVisibleUntilOwned(playbackService);

    if (existingController != null) return;
    if (playbackService.currentItem?.id == item.id &&
        playbackService.controller != null) {
      return;
    }

    unawaited(
      playbackService.play(
        item,
        autoPlay: resolvePlaybackPageEntryAutoPlay(
          entryAutoPlay: SettingsService().autoPlayOnPageEntry,
          isCurrentItem: playbackService.currentItem?.id == item.id,
          desiredPlaying: playbackService.desiredPlaying,
        ),
        startPosition: MediaPlaybackService.startPositionForCurrentSession(
          currentItemId: playbackService.currentItem?.id,
          itemId: item.id,
          currentPosition: playbackService.position,
        ),
      ),
    );
  }

  /// Keep the warmup owner until a real playback page registers. Dropping it on
  /// the first frame can deselect Bilibili's video track while the route is
  /// still mounting, which paints a black texture over an already-ready stream.
  void _holdPlaybackPageVisibleUntilOwned(
    MediaPlaybackService playbackService, {
    int maxAttempts = 12,
  }) {
    playbackService.setPlaybackPageVisible(_navigationVisibilityOwner, true);
    var attempts = 0;
    void releaseWhenPageOwnsIt() {
      attempts++;
      if (playbackService.hasPlaybackPageOwnerOtherThan(
            _navigationVisibilityOwner,
          ) ||
          attempts >= maxAttempts) {
        playbackService.setPlaybackPageVisible(
          _navigationVisibilityOwner,
          false,
        );
        return;
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        releaseWhenPageOwnsIt();
      });
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      releaseWhenPageOwnsIt();
    });
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
        _holdPlaybackPageVisibleUntilOwned(playbackService, maxAttempts: 1800);
        if (playbackService.needsVisibleVideoOutputRecovery(item.id)) {
          unawaited(playbackService.ensureVisibleVideoOutput(item.id));
        }
      }
      await _openPlaybackInternal(item, notificationEntry: true);
    });
    return _navigationQueue;
  }

  Future<void> _waitForPresentableSession(
    MediaPlaybackService service,
    String itemId,
  ) async {
    bool isPresentable() {
      if (service.currentItem?.id != itemId) return true;
      if (service.canMountControllerFor(itemId) ||
          service.isSourceMissing ||
          service.state == PlaybackState.error ||
          service.state == PlaybackState.idle) {
        return true;
      }
      // A restored bookmark has item metadata and no native player yet.
      // Navigate immediately; the page (or the play() started above) prepares.
      return service.controller == null &&
          (service.state == PlaybackState.paused ||
              service.state == PlaybackState.loading);
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
