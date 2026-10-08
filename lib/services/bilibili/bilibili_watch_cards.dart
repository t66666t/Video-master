import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../debug/developer_log.dart' as developer;
import '../../models/bilibili_models.dart';
import '../../models/media_source_ref.dart';
import '../../models/video_item.dart';
import '../library_service.dart';
import '../settings_service.dart';
import 'bilibili_download_service.dart';
import 'bilibili_history_service.dart';
import 'bilibili_stream_card.dart';

/// Where a watch starts: 1-based part and position inside it.
@immutable
class BilibiliWatchStart {
  final int page;
  final int positionMs;

  const BilibiliWatchStart({required this.page, this.positionMs = 0});

  @override
  bool operator ==(Object other) =>
      other is BilibiliWatchStart &&
      other.page == page &&
      other.positionMs == positionMs;

  @override
  int get hashCode => Object.hash(page, positionMs);

  @override
  String toString() => 'BilibiliWatchStart(P$page @ ${positionMs}ms)';
}

/// Picks the part and position a watch starts at.
///
/// An explicit [startAt] (a link with `t=`) wins. Otherwise, while watch
/// history is on, the saved entry continues: its part when no part was asked
/// for, and its position when the part matches. History off means no resume.
BilibiliWatchStart resolveBilibiliWatchStart({
  BilibiliWatchHistoryEntry? entry,
  int? requestedPage,
  Duration? startAt,
  required bool historyEnabled,
}) {
  final asked = requestedPage != null && requestedPage > 0
      ? requestedPage
      : null;
  if (startAt != null) {
    return BilibiliWatchStart(
      page: asked ?? 1,
      positionMs: startAt.isNegative ? 0 : startAt.inMilliseconds,
    );
  }
  if (!historyEnabled || entry == null) {
    return BilibiliWatchStart(page: asked ?? 1);
  }
  if (asked == null || asked == entry.page) {
    return BilibiliWatchStart(page: entry.page, positionMs: entry.positionMs);
  }
  return BilibiliWatchStart(page: asked);
}

/// Result of [prepareBilibiliWatch].
class BilibiliWatchPlan {
  final VideoItem item;
  final BilibiliVideoInfo videoInfo;

  /// True when the library card was reused or created because "auto import
  /// on play" is on.
  final bool imported;

  /// Episode queue of a watch-only card, one entry per part in part order
  /// (just [item] for a single-part video); null for a library card, which
  /// keeps its folder as the queue.
  final List<VideoItem>? queue;

  const BilibiliWatchPlan({
    required this.item,
    required this.videoInfo,
    required this.imported,
    this.queue,
  });

  /// Whether the playback page gets [queue] instead of the folder queue.
  bool get usesOwnQueue => queue != null;
}

String _partTitle(BilibiliVideoInfo info, int page) {
  if (info.pages.length <= 1) return '';
  for (final part in info.pages) {
    if (part.page == page) return part.part;
  }
  return '';
}

/// Card half of a watch from the Bilibili pages (search, history, uploader,
/// collection, pasted link). Opening the playback page is left to the caller.
///
/// With "auto import on play" on, the library card for the BV + part is
/// reused or created as before. Otherwise an existing library card for the
/// BV + part is reused, or a watch-only card is used. A watch-only card that
/// is not playing right now starts at the resolved history position through
/// its regular saved position. The watch history entry is written here.
Future<BilibiliWatchPlan> prepareBilibiliWatch({
  required BilibiliDownloadService service,
  required LibraryService library,
  required String bvid,
  int? page,
  Duration? startAt,
  BilibiliHistoryService? history,
  SettingsService? settings,
  BilibiliWatchCards? cards,
  String? playingItemId,
}) async {
  final watchHistory = history ?? BilibiliHistoryService.instance;
  final prefs = settings ?? SettingsService();
  await watchHistory.ensureLoaded();
  final start = resolveBilibiliWatchStart(
    entry: watchHistory.watchEntryOf(bvid),
    requestedPage: page,
    startAt: startAt,
    historyEnabled: prefs.bilibiliRecordWatchHistory,
  );
  final info = await service.apiService.fetchVideoInfo(bvid);

  final VideoItem item;
  final bool imported;
  if (prefs.bilibiliAutoImportOnPlay) {
    final batch = await service.obtainStreamCardsForVideo(
      library,
      bvid: bvid,
      pages: <int>[start.page],
      videoInfo: info,
    );
    item = batch.cards.first.item;
    imported = true;
  } else {
    final result = await service.obtainWatchCard(
      library,
      bvid: bvid,
      page: start.page,
      videoInfo: info,
    );
    item = result.item;
    imported = false;
    if (item.isTransient && item.id != playingItemId) {
      item.lastPositionMs = start.positionMs;
    }
  }
  cards?.track(item);

  final playedPage = item.sourceRef?.page ?? start.page;
  List<VideoItem>? queue;
  if (item.isTransient) {
    queue = await _watchQueue(
      service: service,
      library: library,
      info: info,
      bvid: bvid,
      current: item,
      currentPage: playedPage,
    );
    for (final entry in queue) {
      cards?.track(entry);
    }
  }
  try {
    await watchHistory.recordWatch(
      BilibiliWatchHistoryEntry(
        bvid: info.bvid.isNotEmpty ? info.bvid : bvid,
        title: info.title,
        ownerName: info.ownerName,
        coverUrl: info.pic,
        page: playedPage,
        partTitle: _partTitle(info, playedPage),
        watchedAt: DateTime.now(),
        positionMs: item.lastPositionMs,
      ),
    );
  } catch (error) {
    // History is best effort and never blocks playback.
    developer.log('Watch history not recorded', error: error);
  }
  return BilibiliWatchPlan(
    item: item,
    videoInfo: info,
    imported: imported,
    queue: queue,
  );
}

/// The episode list of a watch-only card: for every part the library card or
/// a watch-only card still alive, else a lightweight entry that only gets
/// its player data once it is switched to
/// ([BilibiliDownloadService.addWatchParts]).
Future<List<VideoItem>> _watchQueue({
  required BilibiliDownloadService service,
  required LibraryService library,
  required BilibiliVideoInfo info,
  required String bvid,
  required VideoItem current,
  required int currentPage,
}) async {
  if (info.pages.length <= 1) return <VideoItem>[current];
  final videoBvid = info.bvid.trim().isNotEmpty ? info.bvid.trim() : bvid;
  final slots = <int, VideoItem>{currentPage: current};
  final missing = <BilibiliPage>[];
  for (final part in info.pages) {
    if (slots.containsKey(part.page)) continue;
    final existing =
        service.findStreamCard(library, bvid: videoBvid, page: part) ??
        findBilibiliStreamCard(
          library.transientVideos,
          bvid: videoBvid,
          page: part.page,
          cid: part.cid,
          collectionOf: library.getCollection,
        );
    if (existing != null) {
      slots[part.page] = existing;
    } else {
      missing.add(part);
    }
  }
  for (final entry in await service.addWatchParts(
    library,
    videoInfo: info,
    pages: missing,
  )) {
    final page = entry.sourceRef?.page;
    if (page != null) slots[page] = entry;
  }
  return <VideoItem>[for (final part in info.pages) ?slots[part.page]];
}

bool _isOnlineCard(VideoItem item) =>
    item.sourceRef?.kind == MediaSourceKind.bilibiliStream ||
    item.path.startsWith('bilibili://stream/');

typedef _PendingProgress = ({
  String bvid,
  int page,
  int positionMs,
  String title,
});

/// Writes the playback position of cards opened from the Bilibili pages into
/// the watch history: at most once per [interval] while playing, and right
/// away on [flush] (playback page closed, card about to be removed).
class BilibiliWatchProgressRecorder {
  BilibiliWatchProgressRecorder({
    required this.library,
    BilibiliHistoryService? history,
    this.interval = const Duration(seconds: 10),
    DateTime Function()? now,
  }) : history = history ?? BilibiliHistoryService.instance,
       _now = now ?? DateTime.now;

  final LibraryService library;
  final BilibiliHistoryService history;
  final Duration interval;
  final DateTime Function() _now;

  final Set<String> _tracked = <String>{};
  final Map<String, _PendingProgress> _pending = <String, _PendingProgress>{};
  final Map<String, DateTime> _lastWrite = <String, DateTime>{};
  bool _attached = false;

  void attach() {
    if (_attached) return;
    _attached = true;
    library.addProgressObserver(_onProgress);
  }

  void detach() {
    if (!_attached) return;
    _attached = false;
    library.removeProgressObserver(_onProgress);
  }

  /// Positions of [item] are recorded from now on.
  void track(VideoItem item) {
    if (_isOnlineCard(item)) _tracked.add(item.id);
  }

  bool isTracked(String itemId) => _tracked.contains(itemId);

  void _onProgress(VideoItem item, int positionMs) {
    if (!_tracked.contains(item.id)) return;
    final bvid = bilibiliStreamCardBvid(item);
    if (bvid == null || bvid.isEmpty) return;
    _pending[item.id] = (
      bvid: bvid,
      page: item.sourceRef?.page ?? 1,
      positionMs: positionMs,
      title: item.title,
    );
    final last = _lastWrite[item.id];
    if (last == null || _now().difference(last) >= interval) {
      unawaited(_write(item.id));
    }
  }

  /// Writes the latest unsaved position of [itemId], if any.
  Future<void> flush(String itemId) => _write(itemId);

  Future<void> flushAll() async {
    for (final id in List<String>.of(_pending.keys)) {
      await _write(id);
    }
  }

  /// Saves what is pending for [itemId] and stops tracking it.
  Future<void> forget(String itemId) async {
    await _write(itemId);
    _tracked.remove(itemId);
    _lastWrite.remove(itemId);
  }

  Future<void> _write(String itemId) async {
    final pending = _pending.remove(itemId);
    if (pending == null) return;
    _lastWrite[itemId] = _now();
    try {
      await history.recordProgress(
        bvid: pending.bvid,
        page: pending.page,
        positionMs: pending.positionMs,
        partTitle: pending.title,
      );
    } catch (error) {
      developer.log('Watch progress not saved', error: error);
    }
  }
}

/// Removes watch-only cards nothing uses any more.
///
/// A card is in use while it is the current playback item, while a playback
/// page shows it ([inUseIds]) and for [grace] after its last update, which
/// covers the moment between creating a card and opening its page. A skipped
/// card gets another sweep once its grace has passed.
class BilibiliTransientCardJanitor {
  BilibiliTransientCardJanitor({
    required this.library,
    required this.inUseIds,
    this.beforeDiscard,
    this.grace = const Duration(seconds: 15),
    this.sweepDelay = const Duration(milliseconds: 400),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final LibraryService library;
  final Set<String> Function() inUseIds;

  /// Runs before a card is removed (saves its last position).
  final Future<void> Function(VideoItem item)? beforeDiscard;
  final Duration grace;
  final Duration sweepDelay;
  final DateTime Function() _now;

  Future<int>? _sweeping;
  bool _again = false;
  Timer? _timer;
  Timer? _graceTimer;
  bool _disposed = false;

  bool _isFresh(VideoItem item) {
    final age = _now().millisecondsSinceEpoch - item.lastUpdated;
    return age >= 0 && age < grace.inMilliseconds;
  }

  /// Sweeps after [sweepDelay] (or [delay]); a waiting sweep is replaced.
  void scheduleSweep([Duration? delay]) {
    if (_disposed) return;
    _timer?.cancel();
    _timer = Timer(delay ?? sweepDelay, () => unawaited(sweep()));
  }

  /// Removes every watch-only card that is not in use; returns how many.
  /// Concurrent calls share one pass, which runs again if asked meanwhile.
  Future<int> sweep() {
    final running = _sweeping;
    if (running != null) {
      _again = true;
      return running;
    }
    final future = _sweep();
    _sweeping = future;
    return future.whenComplete(() => _sweeping = null);
  }

  Future<int> _sweep() async {
    var removed = 0;
    var waitingForGrace = false;
    do {
      _again = false;
      for (final item in library.transientVideos) {
        if (inUseIds().contains(item.id)) continue;
        if (_isFresh(item)) {
          waitingForGrace = true;
          continue;
        }
        try {
          await beforeDiscard?.call(item);
        } catch (error) {
          developer.log('Before-discard step failed', error: error);
        }
        // It may have been opened again while the position was saved.
        if (inUseIds().contains(item.id)) continue;
        try {
          if (await library.discardTransientVideo(item.id)) removed++;
        } catch (error) {
          developer.log('Watch-only card not removed', error: error);
        }
      }
    } while (_again && !_disposed);
    if (waitingForGrace && !_disposed) {
      _graceTimer?.cancel();
      _graceTimer = Timer(grace, () => unawaited(sweep()));
    }
    return removed;
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _graceTimer?.cancel();
  }
}

/// App-wide wiring of watch-only cards: progress into the watch history and
/// clean-up once a card is neither playing nor on screen.
class BilibiliWatchCards {
  BilibiliWatchCards({required this.recorder, required this.janitor});

  /// Connects to the running app. [currentItemId] is the playback service's
  /// current item and [openPageItemIds] the items of playback pages still on
  /// the navigator stack; [playbackChanges] notifies when the current item
  /// may have changed.
  factory BilibiliWatchCards.forApp({
    required LibraryService library,
    required Listenable playbackChanges,
    required String? Function() currentItemId,
    required Iterable<String> Function() openPageItemIds,
    Iterable<String> Function()? queueItemIds,
    Future<void> Function(String itemId)? prepareCurrentItem,
    BilibiliHistoryService? history,
  }) {
    final recorder = BilibiliWatchProgressRecorder(
      library: library,
      history: history,
    )..attach();
    final janitor = BilibiliTransientCardJanitor(
      library: library,
      inUseIds: () {
        final pages = openPageItemIds().toSet();
        return <String>{
          ?currentItemId(),
          ...pages,
          // While a playback page is open its episode list stays usable.
          if (pages.isNotEmpty && queueItemIds != null) ...queueItemIds(),
        };
      },
      beforeDiscard: (item) => recorder.forget(item.id),
    );
    final cards = BilibiliWatchCards(recorder: recorder, janitor: janitor);
    var lastCurrent = currentItemId();
    void onPlayback() {
      final current = currentItemId();
      if (current == lastCurrent) return;
      lastCurrent = current;
      // Playback stopped (for example the mini player was closed): save the
      // last positions now rather than on the next start.
      if (current == null) {
        unawaited(recorder.flushAll());
      } else if (prepareCurrentItem != null) {
        // A part switched to in the episode list gets its player data now.
        unawaited(prepareCurrentItem(current));
      }
      janitor.scheduleSweep();
    }

    playbackChanges.addListener(onPlayback);
    cards._unwatch = () => playbackChanges.removeListener(onPlayback);
    janitor.scheduleSweep();
    return cards;
  }

  final BilibiliWatchProgressRecorder recorder;
  final BilibiliTransientCardJanitor janitor;
  VoidCallback? _unwatch;

  static BilibiliWatchCards? _instance;

  /// The app-wide instance installed at startup; null in tests that do not
  /// set one.
  static BilibiliWatchCards? get instance => _instance;

  static void install(BilibiliWatchCards? cards) {
    if (identical(_instance, cards)) return;
    _instance?.dispose();
    _instance = cards;
  }

  /// Observer for the app navigator: closing a playback page (routes named
  /// per [isPlaybackRoute]) saves positions and sweeps watch-only cards.
  static NavigatorObserver routeObserver({
    required bool Function(String? routeName) isPlaybackRoute,
  }) => _PlaybackRouteCloseObserver(isPlaybackRoute);

  /// Delay after a playback page closes, so the page has written its last
  /// position before it is saved to the history.
  static const Duration pageCloseDelay = Duration(milliseconds: 800);

  void track(VideoItem item) => recorder.track(item);

  void onPlaybackPageClosed() {
    Timer(pageCloseDelay, () {
      unawaited(recorder.flushAll());
      janitor.scheduleSweep(Duration.zero);
    });
  }

  void dispose() {
    _unwatch?.call();
    _unwatch = null;
    recorder.detach();
    janitor.dispose();
  }
}

class _PlaybackRouteCloseObserver extends NavigatorObserver {
  _PlaybackRouteCloseObserver(this.isPlaybackRoute);

  final bool Function(String? routeName) isPlaybackRoute;

  void _closed(Route<dynamic>? route) {
    if (route == null || !isPlaybackRoute(route.settings.name)) return;
    BilibiliWatchCards.instance?.onPlaybackPageClosed();
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _closed(route);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _closed(route);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    _closed(oldRoute);
  }
}
