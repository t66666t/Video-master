import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/bilibili/bilibili_open_timeline.dart';
import '../../services/bilibili/bilibili_player_panel_memory.dart';
import '../../services/bilibili/bilibili_player_panel_policy.dart';
import '../../services/bilibili/bilibili_watch_cards.dart';
import '../../services/bilibili/bilibili_watch_launch.dart';
import '../../services/settings_service.dart';
import '../../theme/app_tokens.dart';
import '../../widgets/bilibili_cover_image.dart';
import '../../widgets/bilibili_player_panel.dart';
import '../../widgets/bilibili_portrait_tabs.dart';
import '../../widgets/subtitle_sidebar.dart';
import 'bilibili_watch_page_layout.dart';

/// Opens the playback page of a video that is ready: [page] is this loading
/// page's route, which the playback page takes the place of.
typedef BilibiliWatchOpener =
    Future<void> Function(
      NavigatorState navigator,
      Route<dynamic> page,
      BilibiliWatchPlan plan,
      BilibiliOpenTimeline timeline,
    );

/// Shown the moment a Bilibili video is tapped: the cover and title the list
/// already had, with a spinner, while the video gets ready. It is laid out as
/// the playback page will be (the cover where that page shows the video, the
/// side panel shown as the page will show it), so the switch moves nothing.
/// It does not play
/// anything; once the video is ready the regular playback page takes its
/// place. Back leaves at once and drops the request; a failure or the time
/// limit shows the reason with a retry button instead of spinning on.
class BilibiliWatchLoadingPage extends StatefulWidget {
  const BilibiliWatchLoadingPage({
    super.key,
    required this.bvid,
    required this.load,
    required this.open,
    required this.timeline,
    this.preview,
    this.discard,
    this.onClosed,
    this.timeLimit = kBilibiliWatchTimeLimit,
    this.shape,
  });

  static const String routeName = '/bilibili/watch-loading';

  final String bvid;
  final BilibiliWatchPreview? preview;
  final Future<BilibiliWatchPlan> Function(BilibiliWatchAttempt attempt) load;
  final BilibiliWatchOpener open;
  final BilibiliOpenTimeline Function() timeline;

  /// Cleans up after a try that was given up; [kept] is the plan that
  /// opened, whose entries stay.
  final Future<void> Function(BilibiliWatchPlan plan, BilibiliWatchPlan? kept)?
  discard;

  /// Runs when the page goes away, whichever way.
  final VoidCallback? onClosed;
  final Duration timeLimit;

  /// How the playback page will be laid out; null reads the settings.
  final BilibiliWatchPageShape? shape;

  @override
  State<BilibiliWatchLoadingPage> createState() =>
      _BilibiliWatchLoadingPageState();
}

class _BilibiliWatchLoadingPageState extends State<BilibiliWatchLoadingPage> {
  late final BilibiliWatchLaunch<BilibiliWatchPlan> _launch;
  bool _opening = false;

  /// The portrait 「详情 | 字幕」 tab shown here. A tap only changes what this
  /// page and the playback page it opens show, never the remembered tab.
  PortraitBilibiliTab _portraitTab = BilibiliPortraitTabMemory.of(
    SettingsService(),
  ).remembered;
  bool _portraitTabPicked = false;

  /// The Bilibili panel was collapsed on this page.
  bool _panelCollapsed = false;

  @override
  void initState() {
    super.initState();
    _launch = BilibiliWatchLaunch<BilibiliWatchPlan>(
      load: widget.load,
      timelineFor: widget.timeline,
      discard: widget.discard,
      timeLimit: widget.timeLimit,
      onReady: _openPlayback,
    )..addListener(_onLaunchChanged);
    _launch.start();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _launch.timeline?.mark('loading page shown');
    });
  }

  void _onLaunchChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _openPlayback(
    BilibiliWatchPlan plan,
    BilibiliOpenTimeline timeline,
  ) async {
    var route = mounted ? ModalRoute.of(context) : null;
    if (route != null && route.isActive) {
      // The playback page draws the card's cover file in its first frame
      // when the image is decoded already. It also takes over this page's
      // transition as it stands, so that has to be over.
      await Future.wait(<Future<void>>[
        _precacheCover(plan.item.thumbnailPath),
        _shown(route),
      ]);
      route = mounted ? ModalRoute.of(context) : null;
    }
    if (!mounted || route == null || !route.isActive) {
      // Left in the instant between ready and open: what this watch made,
      // including cards a retry took over from a given-up try, goes now.
      _launch.discardReady();
      return;
    }
    _opening = true;
    if (_portraitTabPicked) {
      BilibiliPortraitTabMemory.handOff(plan.item.id, _portraitTab);
    }
    unawaited(widget.open(Navigator.of(context), route, plan, timeline));
  }

  /// Completes once [route] finished coming in (or is going away).
  static Future<void> _shown(ModalRoute<dynamic> route) async {
    final animation = route.animation;
    bool over(AnimationStatus status) =>
        status == AnimationStatus.completed ||
        status == AnimationStatus.reverse ||
        !route.isActive;
    if (animation == null || over(animation.status)) return;
    final done = Completer<void>();
    void onStatus(AnimationStatus status) {
      if (over(status) && !done.isCompleted) done.complete();
    }

    animation.addStatusListener(onStatus);
    try {
      await done.future.timeout(const Duration(seconds: 1), onTimeout: () {});
    } finally {
      animation.removeStatusListener(onStatus);
    }
  }

  Future<void> _precacheCover(String? path) async {
    if (path == null || path.isEmpty || !File(path).existsSync()) return;
    try {
      await precacheImage(
        FileImage(File(path)),
        context,
      ).timeout(const Duration(milliseconds: 800));
    } catch (_) {
      // Only the first frame of the playback page is at stake.
    }
  }

  @override
  void dispose() {
    _launch
      ..removeListener(_onLaunchChanged)
      ..dispose();
    widget.onClosed?.call();
    super.dispose();
  }

  void _back() {
    _launch.cancel();
    Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final failed = _launch.phase == BilibiliWatchLaunchPhase.failed;
    var shape = widget.shape ?? BilibiliWatchPageShape.current();
    if (_panelCollapsed && shape.bilibiliPanelRemembered) {
      shape = BilibiliWatchPageShape(
        landscape: shape.landscape,
        leftHanded: shape.leftHanded,
        bilibiliPanelRemembered: false,
        subtitleSidebarRemembered: shape.subtitleSidebarRemembered,
        subtitleSidebarWidth: shape.subtitleSidebarWidth,
        isMobilePlatform: shape.isMobilePlatform,
        isDesktop: shape.isDesktop,
      );
    }
    return PopScope<Object?>(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop && !_opening) _launch.cancel();
      },
      child: CallbackShortcuts(
        bindings: <ShortcutActivator, VoidCallback>{
          const SingleActivator(LogicalKeyboardKey.escape): _back,
        },
        child: Focus(
          autofocus: true,
          child: Scaffold(
            key: const ValueKey('bilibili-watch-loading'),
            backgroundColor: Colors.black,
            resizeToAvoidBottomInset: false,
            body: shape.landscape
                ? _landscape(context, shape, failed)
                : _portrait(context, shape, failed),
          ),
        ),
      ),
    );
  }

  String get _title {
    final title = widget.preview?.title?.trim();
    return title == null || title.isEmpty ? widget.bvid : title;
  }

  /// The playback page's Bilibili panel: the detail right away when it is
  /// kept already, else the panel's own outline while it loads (the
  /// request is shared with the playback page's panel).
  Widget _bilibiliPanel({VoidCallback? onCollapse}) {
    return BilibiliPlayerPanel(
      bvid: widget.bvid,
      fallbackTitle: widget.preview?.title ?? '',
      onCollapse: onCollapse,
    );
  }

  void _collapsePanel() {
    BilibiliPlayerPanelMemory.of(SettingsService()).userCollapsed();
    setState(() => _panelCollapsed = true);
  }

  /// As the landscape playback page: the cover over the whole area beside
  /// the side panel the page opens with, which is kept free here.
  Widget _landscape(
    BuildContext context,
    BilibiliWatchPageShape shape,
    bool failed,
  ) {
    final media = MediaQuery.of(context);
    final layout = shape.landscapeLayout(
      window: media.size,
      padding: media.padding,
    );
    // The page's only safe area is the top one.
    return MediaQuery.removePadding(
      context: context,
      removeTop: true,
      child: Stack(
        children: [
          Positioned.fromRect(
            rect: layout.surface,
            child: _videoArea(
              failed: failed,
              backButton: _backButton(shape),
              backAt: const EdgeInsets.only(top: 16, left: 16),
              titleInArea: true,
            ),
          ),
          if (layout.slot != BilibiliWatchSidebarSlot.none)
            Positioned.fromRect(
              rect: layout.sidebar,
              child: _sidebar(layout.slot, shape.leftHanded),
            ),
        ],
      ),
    );
  }

  /// As the portrait playback page: the video area on top of a centered
  /// column at most [kPortraitPlayerMaxWidth] wide, the player's controls
  /// below it, then the 「详情 | 字幕」 switch with its panel.
  Widget _portrait(
    BuildContext context,
    BilibiliWatchPageShape shape,
    bool failed,
  ) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: kPortraitPlayerMaxWidth),
        child: SafeArea(
          top: true,
          bottom: true,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ColoredBox(
                color: Colors.black,
                child: AspectRatio(
                  aspectRatio: 16 / 9,
                  child: _videoArea(
                    failed: failed,
                    backButton: _backButton(shape),
                    backAt: const EdgeInsets.only(top: 4, left: 4),
                    titleInArea: false,
                  ),
                ),
              ),
              const _PortraitControlsOutline(),
              Expanded(
                child: BilibiliPortraitTabs(
                  key: const ValueKey('bilibili-watch-loading-portrait-tabs'),
                  tab: _portraitTab,
                  onSelect: (tab) => setState(() {
                    _portraitTab = tab;
                    _portraitTabPicked = true;
                  }),
                  details: _bilibiliPanel(),
                  // The player's empty list as it shows before subtitles are
                  // there; its buttons work once the player is open.
                  subtitles: IgnorePointer(
                    child: SubtitleSidebar(
                      subtitles: const [],
                      onOpenSettings: _noop,
                      onLoadSubtitle: _noop,
                      onOpenSubtitleStyle: _noop,
                      onOpenSubtitleManager: _noop,
                      onScanEmbeddedSubtitles: _noop,
                      onOpenEpisodePicker: _noop,
                      onOpenVideoCompose: _noop,
                      onOpenOcrSubtitle: _playerOffersOcr ? _noop : null,
                      onOpenSubtitleEditor: _noop,
                      isCompact: true,
                      isPortrait: true,
                      isVisible: _portraitTab == PortraitBilibiliTab.subtitles,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static void _noop() {}

  /// As the portrait player decides whether its subtitle list offers OCR.
  static bool get _playerOffersOcr =>
      Platform.isAndroid ||
      Platform.isIOS ||
      Platform.isWindows ||
      Platform.isMacOS;

  /// Where the playback page shows its loading cover: the cover filling
  /// the area, a spinner, and the way back in the corner.
  Widget _videoArea({
    required bool failed,
    required Widget backButton,
    required EdgeInsets backAt,
    required bool titleInArea,
  }) {
    return Stack(
      key: const ValueKey('bilibili-watch-loading-video-area'),
      fit: StackFit.expand,
      children: [
        const ColoredBox(color: Colors.black),
        BilibiliSharpCoverImage(
          key: const ValueKey('bilibili-watch-loading-cover'),
          url: widget.preview?.coverUrl,
          borderRadius: 0,
        ),
        if (failed) ...[
          const ColoredBox(color: Color(0x99000000)),
          Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: _failure(CrossAxisAlignment.center),
            ),
          ),
        ] else if (!failed)
          Center(
            child: SizedBox(
              width: 48,
              height: 48,
              child: CircularProgressIndicator(
                key: const ValueKey('bilibili-watch-loading-spinner'),
                strokeWidth: 3,
                color: Colors.white.withValues(alpha: 0.8),
              ),
            ),
          ),
        Positioned(
          top: backAt.top,
          left: backAt.left,
          right: titleInArea ? backAt.left : null,
          child: SafeArea(
            bottom: false,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                backButton,
                if (titleInArea) ...[
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      _title,
                      key: const ValueKey('bilibili-watch-loading-title'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _backButton(BilibiliWatchPageShape shape) {
    return IconButton(
      key: const ValueKey('bilibili-watch-loading-back'),
      tooltip: shape.isDesktop ? '退出播放 (Esc)' : '返回',
      onPressed: _back,
      icon: Icon(
        shape.isDesktop ? Icons.close : Icons.arrow_back,
        color: Colors.white,
      ),
    );
  }

  /// The side panel's place: the Bilibili panel itself (collapsing it here
  /// is remembered as on the playback page), or the subtitle list's
  /// background.
  Widget _sidebar(BilibiliWatchSidebarSlot slot, bool leftHanded) {
    if (slot == BilibiliWatchSidebarSlot.subtitles) {
      final handle = Container(
        width: kPlayerSubtitleSidebarResizerWidth,
        color: Colors.black12,
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 4),
          child: const Center(
            child: VerticalDivider(
              color: Colors.white24,
              width: 4,
              thickness: 4,
              indent: 40,
              endIndent: 40,
            ),
          ),
        ),
      );
      return Row(
        key: const ValueKey('bilibili-watch-loading-sidebar-subtitles'),
        children: [
          if (!leftHanded) handle,
          const Expanded(child: ColoredBox(color: Color(0xFF1E1E1E))),
          if (leftHanded) handle,
        ],
      );
    }
    return KeyedSubtree(
      key: const ValueKey('bilibili-watch-loading-sidebar-bilibili'),
      child: _bilibiliPanel(onCollapse: _collapsePanel),
    );
  }

  Widget _failure(CrossAxisAlignment alignment) {
    return Column(
      key: const ValueKey('bilibili-watch-failed'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: alignment,
      children: [
        Text(
          _launch.failure ?? '播放准备失败',
          textAlign: alignment == CrossAxisAlignment.center
              ? TextAlign.center
              : TextAlign.start,
          style: const TextStyle(color: Colors.white70, fontSize: 13),
        ),
        const SizedBox(height: 14),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextButton(
              onPressed: _back,
              child: const Text('返回', style: TextStyle(color: Colors.white70)),
            ),
            const SizedBox(width: 8),
            FilledButton.icon(
              key: const ValueKey('bilibili-watch-retry'),
              style: FilledButton.styleFrom(
                backgroundColor: AppTokens.brandBilibili,
                foregroundColor: Colors.white,
              ),
              onPressed: _launch.retry,
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text('重试'),
            ),
          ],
        ),
      ],
    );
  }
}

/// The portrait player's controls as they show before the video is ready
/// (the same heights, all greyed), so the panel below starts where the
/// player's does.
class _PortraitControlsOutline extends StatelessWidget {
  const _PortraitControlsOutline();

  /// Heights of the portrait player's play controls and its progress bar
  /// while it loads.
  static const double controlsHeight = 50;
  static const double progressHeight = 36;

  @override
  Widget build(BuildContext context) {
    const background = Color(0xFF1E1E1E);
    Widget seek({required bool forward}) => SizedBox(
      width: 44,
      height: 44,
      child: Transform(
        alignment: Alignment.center,
        transform: forward ? Matrix4.rotationY(3.14159) : Matrix4.identity(),
        child: const Icon(Icons.replay, color: Colors.white38, size: 28),
      ),
    );
    return Column(
      key: const ValueKey('bilibili-watch-loading-controls'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          height: controlsHeight,
          color: background,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const SizedBox(
                width: 48,
                height: 48,
                child: Icon(
                  Icons.skip_previous,
                  color: Colors.white38,
                  size: 32,
                ),
              ),
              const SizedBox(width: 16),
              seek(forward: false),
              const SizedBox(width: 30),
              const Icon(
                Icons.play_circle_fill,
                color: Colors.white38,
                size: 50,
              ),
              const SizedBox(width: 30),
              seek(forward: true),
              const SizedBox(width: 16),
              const SizedBox(
                width: 48,
                height: 48,
                child: Icon(Icons.skip_next, color: Colors.white38, size: 32),
              ),
            ],
          ),
        ),
        Container(
          height: progressHeight,
          color: background,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            children: [
              const Text(
                '00:00:00 / --:--:--',
                style: TextStyle(color: Colors.white70, fontSize: 10),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Container(height: 2, color: Colors.white24),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
