import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/bilibili/bilibili_open_timeline.dart';
import '../../services/bilibili/bilibili_watch_cards.dart';
import '../../services/bilibili/bilibili_watch_launch.dart';
import '../../theme/app_tokens.dart';
import '../../widgets/bilibili_cover_image.dart';

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
/// already had, with a spinner, while the video gets ready. It does not play
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
  });

  static const String routeName = '/bilibili/watch-loading';

  final String bvid;
  final BilibiliWatchPreview? preview;
  final Future<BilibiliWatchPlan> Function(BilibiliWatchAttempt attempt) load;
  final BilibiliWatchOpener open;
  final BilibiliOpenTimeline Function() timeline;
  final Future<void> Function(BilibiliWatchPlan plan)? discard;

  /// Runs when the page goes away, whichever way.
  final VoidCallback? onClosed;
  final Duration timeLimit;

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

  void _openPlayback(BilibiliWatchPlan plan, BilibiliOpenTimeline timeline) {
    final route = mounted ? ModalRoute.of(context) : null;
    if (route == null || !route.isActive) {
      final discard = widget.discard;
      if (discard != null) discard(plan);
      return;
    }
    _opening = true;
    widget.open(Navigator.of(context), route, plan, timeline);
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
    final title = widget.preview?.title?.trim();
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
            body: SafeArea(
              child: Stack(
                children: [
                  Center(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 24,
                        vertical: 56,
                      ),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 560),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _cover(failed),
                            const SizedBox(height: 16),
                            Text(
                              title == null || title.isEmpty
                                  ? widget.bvid
                                  : title,
                              key: const ValueKey(
                                'bilibili-watch-loading-title',
                              ),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                color: AppTokens.text1,
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 12),
                            if (failed) _failure() else _status(),
                          ],
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    left: 4,
                    top: 4,
                    child: IconButton(
                      key: const ValueKey('bilibili-watch-loading-back'),
                      tooltip: '返回',
                      onPressed: _back,
                      icon: const Icon(
                        Icons.arrow_back_rounded,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _cover(bool failed) {
    return AspectRatio(
      aspectRatio: 16 / 9,
      child: Stack(
        fit: StackFit.expand,
        children: [
          BilibiliCoverImage(
            key: const ValueKey('bilibili-watch-loading-cover'),
            url: widget.preview?.coverUrl,
            borderRadius: 10,
          ),
          if (!failed)
            const DecoratedBox(
              decoration: BoxDecoration(color: Color(0x66000000)),
              child: Center(
                child: SizedBox(
                  width: 36,
                  height: 36,
                  child: CircularProgressIndicator(
                    key: ValueKey('bilibili-watch-loading-spinner'),
                    strokeWidth: 3,
                    color: AppTokens.brandBilibili,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _status() {
    return const Text(
      '正在加载…',
      style: TextStyle(color: AppTokens.text2, fontSize: 13),
    );
  }

  Widget _failure() {
    return Column(
      key: const ValueKey('bilibili-watch-failed'),
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          _launch.failure ?? '播放准备失败',
          textAlign: TextAlign.center,
          style: const TextStyle(color: AppTokens.text2, fontSize: 13),
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
