import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/bilibili/bilibili_open_timeline.dart';
import '../../services/bilibili/bilibili_watch_cards.dart';
import '../../services/bilibili/bilibili_watch_launch.dart';
import '../../theme/app_tokens.dart';
import '../../widgets/bilibili_cover_image.dart';
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
/// side panel's place kept free), so the switch moves nothing. It does not play
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
    final shape = widget.shape ?? BilibiliWatchPageShape.current();
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
  /// column at most [kPortraitPlayerMaxWidth] wide, the title below it.
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
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _title,
                        key: const ValueKey('bilibili-watch-loading-title'),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: AppTokens.text1,
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 12),
                      if (failed)
                        _failure(CrossAxisAlignment.start)
                      else
                        const Text(
                          '正在加载…',
                          style: TextStyle(
                            color: AppTokens.text2,
                            fontSize: 13,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

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
        if (failed && titleInArea) ...[
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

  /// The side panel's place: the Bilibili panel's outline with what is
  /// already known of the video, or the subtitle list's background.
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
    return Material(
      key: const ValueKey('bilibili-watch-loading-sidebar-bilibili'),
      color: AppTokens.bgBase,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
            child: Row(
              children: [
                const Icon(
                  Icons.smart_display_outlined,
                  size: 18,
                  color: AppTokens.brandBilibili,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppTokens.text1,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1, thickness: 1, color: AppTokens.bgCard),
          Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final fraction in const <double>[0.9, 0.6, 0.75, 0.4])
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: FractionallySizedBox(
                      widthFactor: fraction,
                      child: Container(
                        height: 12,
                        decoration: BoxDecoration(
                          color: AppTokens.bgCard,
                          borderRadius: BorderRadius.circular(6),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
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
