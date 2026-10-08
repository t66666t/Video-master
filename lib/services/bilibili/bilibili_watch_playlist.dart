import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../debug/developer_log.dart' as developer;
import '../../models/bilibili_models.dart';
import '../../models/media_source_ref.dart';
import '../../models/video_item.dart';
import '../library_service.dart';
import '../playlist_manager.dart';
import 'bilibili_download_service.dart';
import 'bilibili_history_service.dart';
import 'bilibili_stream_card.dart';
import 'bilibili_watch_cards.dart';

/// One video of the temporary Bilibili playlist: no files, just what it
/// takes to list it and to make its entry again without a request.
class BilibiliWatchPlaylistEntry {
  BilibiliWatchPlaylistEntry({
    required this.bvid,
    required this.page,
    required this.info,
  });

  final String bvid;

  /// The part last opened or played.
  int page;

  /// Title, cover and parts.
  BilibiliVideoInfo info;

  String get title => info.title;
  String get coverUrl => info.pic;

  BilibiliPage? get part {
    for (final candidate in info.pages) {
      if (candidate.page == page) return candidate;
    }
    return info.pages.isEmpty ? null : info.pages.first;
  }
}

/// The temporary playlist of the videos opened from the Bilibili pages, in
/// the order they were opened. Separate from the media library's queues; it
/// lives in memory only, so it outlasts closing the playback page and is
/// gone after a restart.
///
/// A video is in it once, with all its parts: opening it again goes back to
/// it. At most [capacity] videos; beyond that the oldest one leaves, or the
/// one after it when the oldest is playing.
class BilibiliWatchPlaylist extends ChangeNotifier {
  static const int capacity = 50;

  /// The list of this app run.
  static final BilibiliWatchPlaylist instance = BilibiliWatchPlaylist();

  final List<BilibiliWatchPlaylistEntry> _entries =
      <BilibiliWatchPlaylistEntry>[];
  String? _currentBvid;

  List<BilibiliWatchPlaylistEntry> get entries =>
      List<BilibiliWatchPlaylistEntry>.unmodifiable(_entries);

  /// The video that plays from the list.
  String? get currentBvid => _currentBvid;

  BilibiliWatchPlaylistEntry? entryOf(String bvid) {
    for (final entry in _entries) {
      if (entry.bvid == bvid) return entry;
    }
    return null;
  }

  /// [bvid] opened at part [page]: added at the end, or, when listed
  /// already, gone back to. [playingBvid] is the video playing until now,
  /// which is not dropped to make room.
  void open({
    required String bvid,
    required int page,
    required BilibiliVideoInfo info,
    String? playingBvid,
  }) {
    final listed = entryOf(bvid);
    if (listed != null) {
      listed
        ..page = page
        ..info = info;
    } else {
      _entries.add(
        BilibiliWatchPlaylistEntry(bvid: bvid, page: page, info: info),
      );
      while (_entries.length > capacity) {
        final index = _entries.indexWhere(
          (entry) => entry.bvid != bvid && entry.bvid != playingBvid,
        );
        if (index < 0) break;
        _entries.removeAt(index);
      }
    }
    _currentBvid = bvid;
    notifyListeners();
  }

  /// The list moved on to part [page] of [bvid] (next, previous, a pick in
  /// the list). False when [bvid] is not listed.
  bool select(String bvid, int page) {
    final entry = entryOf(bvid);
    if (entry == null) return false;
    if (entry.page == page && _currentBvid == bvid) return true;
    entry.page = page;
    _currentBvid = bvid;
    notifyListeners();
    return true;
  }

  /// Empties the list except for the video that plays ([keepBvid]).
  void clear({String? keepBvid}) {
    _entries.removeWhere((entry) => entry.bvid != keepBvid);
    if (_entries.isEmpty) _currentBvid = null;
    notifyListeners();
  }

  @visibleForTesting
  void resetForTest() {
    _entries.clear();
    _currentBvid = null;
    notifyListeners();
  }
}

/// Plays the [BilibiliWatchPlaylist] through the regular playback queue
/// ([PlaylistManager]): every listed video is one queue entry (its card, or
/// a lightweight entry without files), the playing one with all its parts so
/// the episode list switches parts; previous, next and auto-continue follow
/// the list. Only a watch that really opens a playback page is added
/// ([opened]). The queue is the list's only while nothing else (a library
/// folder, another queue) replaced it; other playback is never touched.
class BilibiliWatchPlaylistSession {
  BilibiliWatchPlaylistSession({
    required this.list,
    required this.service,
    required this.library,
    required this.queue,
    required this.playbackChanges,
    required this.currentItem,
    BilibiliHistoryService? history,
  }) : history = history ?? BilibiliHistoryService.instance {
    playbackChanges.addListener(_onPlayback);
    library.addListener(_onLibrary);
  }

  final BilibiliWatchPlaylist list;
  final BilibiliDownloadService service;
  final LibraryService library;
  final PlaylistManager queue;
  final Listenable playbackChanges;
  final VideoItem? Function() currentItem;
  final BilibiliHistoryService history;

  static BilibiliWatchPlaylistSession? _instance;

  /// The app's session; null where none was installed (most tests).
  static BilibiliWatchPlaylistSession? get instance => _instance;

  static void install(BilibiliWatchPlaylistSession? session) {
    if (identical(_instance, session)) return;
    _instance?.dispose();
    _instance = session;
  }

  List<String>? _queueIds;
  int _generation = 0;
  String? _lastCurrentId;
  bool _repairScheduled = false;

  /// Whether the playback queue is this list right now.
  bool get isActive {
    final ids = _queueIds;
    if (ids == null) return false;
    return listEquals(ids, <String>[
      for (final item in queue.playlist) item.id,
    ]);
  }

  /// Entries of the list's queue that have no files yet; they stay while
  /// the list plays on (the mini player's previous / next use them).
  Iterable<String> placeholderIds() {
    if (!isActive) return const <String>[];
    return _queueIds!.where(service.isWatchPlaceholder);
  }

  /// The playback page of [plan] opened: its video joins the list (or the
  /// list goes back to it) and the queue becomes the list.
  void opened(BilibiliWatchPlan plan) {
    final item = plan.item;
    final ref = item.sourceRef;
    final info = plan.videoInfo;
    final bvid = _bvidOf(item) ?? info.bvid;
    if (bvid.isEmpty) return;
    list.open(
      bvid: bvid,
      page: ref?.page ?? 1,
      info: info,
      playingBvid: list.currentBvid,
    );
    _lastCurrentId = item.id;
    // The part list is there at once; the other videos join a moment later.
    _apply(plan.queue ?? <VideoItem>[item], item.id);
    unawaited(_project(item, currentParts: plan.queue));
  }

  /// Builds the list's queue again (cards made or removed meanwhile).
  void refresh() {
    final anchored = queue.currentItem;
    if (isActive && anchored != null) unawaited(_project(anchored));
  }

  /// The list's "clear": every video goes except the playing one.
  Future<void> clear() async {
    final current = currentItem();
    list.clear(keepBvid: current == null ? null : _bvidOf(current));
    final anchored = queue.currentItem;
    if (anchored != null && isActive) await _project(anchored);
    BilibiliWatchCards.instance?.janitor.scheduleSweep();
  }

  void _onPlayback() {
    final current = currentItem();
    if (current == null || current.id == _lastCurrentId) return;
    _lastCurrentId = current.id;
    if (!isActive || !_queueIds!.contains(current.id)) return;
    final bvid = _bvidOf(current);
    if (bvid == null) return;
    final page = current.sourceRef?.page ?? 1;
    final sameVideo = bvid == list.currentBvid;
    if (!list.select(bvid, page)) return;
    if (sameVideo) return;
    // Another video of the list: it is watched now, and its parts show.
    final entry = list.entryOf(bvid)!;
    unawaited(_noteWatched(entry, current));
    unawaited(_project(current));
  }

  /// A listed card was cleaned up (its page closed): its place gets a
  /// lightweight entry again.
  void _onLibrary() {
    if (_repairScheduled || !isActive) return;
    final ids = _queueIds!;
    if (ids.every((id) => library.getVideo(id) != null)) return;
    _repairScheduled = true;
    scheduleMicrotask(() {
      _repairScheduled = false;
      final anchored = queue.currentItem;
      if (isActive && anchored != null) unawaited(_project(anchored));
    });
  }

  Future<void> _noteWatched(
    BilibiliWatchPlaylistEntry entry,
    VideoItem item,
  ) async {
    try {
      await history.recordWatch(
        bilibiliWatchHistoryEntry(
          info: entry.info,
          bvid: entry.bvid,
          page: entry.page,
          positionMs: item.lastPositionMs,
        ),
      );
    } catch (error) {
      developer.log('Watch history not recorded', error: error);
    }
  }

  /// Builds the queue of the list around [current] and makes it the
  /// playback queue, unless something else took over meanwhile.
  Future<void> _project(
    VideoItem current, {
    List<VideoItem>? currentParts,
  }) async {
    final generation = ++_generation;
    final List<VideoItem> items;
    try {
      items = await _queueAround(current, currentParts: currentParts);
    } catch (error, stack) {
      developer.log(
        'Bilibili playlist not built',
        error: error,
        stackTrace: stack,
      );
      return;
    }
    if (generation != _generation || !isActive) return;
    final anchored = queue.currentItem;
    if (anchored == null) return;
    if (anchored.id != current.id) {
      // Moved on meanwhile (a part picked in the list): build around that.
      unawaited(_project(anchored));
      return;
    }
    _apply(items, current.id);
  }

  void _apply(List<VideoItem> items, String currentId) {
    queue.setPlaylist(items, currentItemId: currentId);
    _queueIds = <String>[for (final item in queue.playlist) item.id];
    final cards = BilibiliWatchCards.instance;
    for (final item in items) {
      if (item.isTransient) cards?.track(item);
    }
  }

  Future<List<VideoItem>> _queueAround(
    VideoItem current, {
    List<VideoItem>? currentParts,
  }) async {
    final currentBvid = list.currentBvid;
    final slots = <VideoItem?>[];
    final missing = <(BilibiliVideoInfo, BilibiliPage)>[];
    final missingSlots = <int>[];
    for (final entry in list.entries) {
      if (entry.bvid == currentBvid) {
        slots.addAll(
          currentParts ??
              await bilibiliWatchPartsQueue(
                service: service,
                library: library,
                info: entry.info,
                bvid: entry.bvid,
                current: current,
                currentPage: entry.page,
              ),
        );
        continue;
      }
      final part = entry.part;
      if (part == null) continue;
      final existing =
          service.findStreamCard(library, bvid: entry.bvid, page: part) ??
          findBilibiliStreamCard(
            library.transientVideos,
            bvid: entry.bvid,
            page: part.page,
            cid: part.cid,
            collectionOf: library.getCollection,
          );
      if (existing != null) {
        slots.add(existing);
      } else {
        missingSlots.add(slots.length);
        missing.add((entry.info, part));
        slots.add(null);
      }
    }
    if (missing.isNotEmpty) {
      final made = await service.addWatchEntries(library, missing);
      // Parts without a BV or cid are skipped by addWatchEntries.
      var next = 0;
      for (var i = 0; i < missingSlots.length && next < made.length; i++) {
        final (info, part) = missing[i];
        final candidate = made[next];
        if (candidate.sourceRef?.cid != part.cid) continue;
        next++;
        _resumeFromHistory(candidate, info);
        slots[missingSlots[i]] = candidate;
      }
    }
    return <VideoItem>[for (final slot in slots) ?slot];
  }

  /// A new entry starts where the history says the video was left, when
  /// that was this part.
  void _resumeFromHistory(VideoItem item, BilibiliVideoInfo info) {
    final bvid = _bvidOf(item) ?? info.bvid;
    final saved = history.watchEntryOf(bvid);
    if (saved != null && saved.page == item.sourceRef?.page) {
      item.lastPositionMs = saved.positionMs;
    }
  }

  static String? _bvidOf(VideoItem item) {
    final ref = item.sourceRef;
    if (ref == null || ref.kind != MediaSourceKind.bilibiliStream) {
      return null;
    }
    final bvid = (ref.bvid ?? ref.value).trim();
    return bvid.isEmpty ? null : bvid;
  }

  bool _disposed = false;

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    playbackChanges.removeListener(_onPlayback);
    library.removeListener(_onLibrary);
  }
}
