import 'package:flutter/foundation.dart';

import '../models/video_item.dart';
import 'library_service.dart';
import 'playback_queue_policy.dart';

/// Owns the one canonical, source-validated playback queue.
///
/// Library visibility and direct-open eligibility deliberately remain outside
/// this class. A missing local item can be opened, but its id will be detached
/// from [snapshot] and previous/next navigation will be unavailable.
class PlaylistManager extends ChangeNotifier {
  PlaylistManager({PlaybackQueuePolicy? queuePolicy})
    : _queuePolicy = queuePolicy ?? PlaybackQueuePolicy(),
      _snapshot = PlaybackQueueSnapshot(
        revision: 0,
        entries: const <VideoItem>[],
        currentItemId: null,
        folderId: null,
      );

  final PlaybackQueuePolicy _queuePolicy;
  LibraryService? _libraryService;
  PlaybackQueueSnapshot _snapshot;
  List<VideoItem> _sourceItems = const <VideoItem>[];
  String? _currentFolderId;
  String? _anchoredItemId;
  bool _isFolderPlaylist = false;

  PlaybackQueueSnapshot get snapshot => _snapshot;
  List<VideoItem> get playlist => _snapshot.entries;
  int get currentIndex => _snapshot.currentIndex;
  int get revision => _snapshot.revision;
  VideoItem? get currentItem => _snapshot.currentItem;
  String? get anchoredItemId => _anchoredItemId;
  bool get isCurrentItemDetached =>
      _anchoredItemId != null && _snapshot.currentIndex < 0;
  bool isQueueEligible(VideoItem item) => _queuePolicy.isEligible(item);

  void initialize({required LibraryService libraryService}) {
    _libraryService = libraryService;
  }

  /// Replaces the queue with a validated projection.
  ///
  /// [startIndex] addresses the unfiltered input so a missing selected item
  /// becomes detached instead of silently selecting a different playable item.
  void setPlaylist(
    List<VideoItem> items, {
    int startIndex = 0,
    String? currentItemId,
  }) {
    _sourceItems = List<VideoItem>.from(items);
    final requestedId =
        currentItemId ??
        (items.isNotEmpty && startIndex >= 0 && startIndex < items.length
            ? items[startIndex].id
            : null);
    _isFolderPlaylist = false;
    _currentFolderId = null;
    _replaceSnapshot(_sourceItems, currentItemId: requestedId, folderId: null);
  }

  bool matchesFolderPlaylist(String? folderId, String currentItemId) {
    return _isFolderPlaylist &&
        _currentFolderId == folderId &&
        _anchoredItemId == currentItemId &&
        _snapshot.indexOf(currentItemId) >= 0;
  }

  void loadFolderPlaylist(String? folderId, String currentItemId) {
    final library = _libraryService;
    if (library == null) {
      debugPrint('PlaylistManager: LibraryService not initialized');
      return;
    }
    if (matchesFolderPlaylist(folderId, currentItemId)) return;

    _isFolderPlaylist = true;
    _currentFolderId = folderId;
    _sourceItems = library.getVideosInFolder(folderId);
    _replaceSnapshot(
      _sourceItems,
      currentItemId: currentItemId,
      folderId: folderId,
    );
  }

  /// Revalidates source existence and publishes a new queue revision.
  void reloadPlaylist() {
    final library = _libraryService;
    if (!_isFolderPlaylist || library == null) return;
    _sourceItems = library.getVideosInFolder(_currentFolderId);
    _replaceSnapshot(
      _sourceItems,
      currentItemId: _anchoredItemId,
      folderId: _currentFolderId,
    );
  }

  /// Revalidates an explicitly supplied queue without changing its scope.
  void revalidatePlaylist() {
    if (_isFolderPlaylist) {
      reloadPlaylist();
      return;
    }
    _replaceSnapshot(
      _sourceItems,
      currentItemId: _anchoredItemId,
      folderId: null,
    );
  }

  /// Cheap source revalidation used immediately before publishing an OS queue.
  /// It notifies only when membership or the anchored index actually changes,
  /// avoiding a media-session listener loop.
  void refreshQueueEligibility() {
    if (_isFolderPlaylist && _libraryService != null) {
      _sourceItems = _libraryService!.getVideosInFolder(_currentFolderId);
    }
    final filtered = _queuePolicy.filter(_sourceItems);
    final oldIds = _snapshot.entries.map((item) => item.id).toList();
    final newIds = filtered.map((item) => item.id).toList();
    if (listEquals(oldIds, newIds) &&
        _snapshot.currentItemId == _anchoredItemId) {
      return;
    }
    _replaceSnapshot(
      filtered,
      currentItemId: _anchoredItemId,
      folderId: _currentFolderId,
      revalidate: false,
    );
  }

  VideoItem? getNext() => hasNext ? playlist[currentIndex + 1] : null;
  VideoItem? getFirst() => playlist.isEmpty ? null : playlist.first;
  VideoItem? getPrevious() => hasPrevious ? playlist[currentIndex - 1] : null;
  bool get hasNext => _snapshot.hasNext;
  bool get hasPrevious => _snapshot.hasPrevious;

  void setCurrentIndex(int index) {
    if (index < 0 || index >= playlist.length) return;
    _replaceSnapshot(
      _sourceItems,
      currentItemId: playlist[index].id,
      folderId: _currentFolderId,
    );
  }

  /// Keeps a direct-open item associated with its folder while explicitly
  /// detaching it when it does not satisfy queue eligibility.
  void anchorCurrentItem(VideoItem item) {
    final index = indexOfItem(item.id);
    if (index >= 0) {
      setCurrentIndex(index);
      return;
    }
    if (_libraryService != null) {
      loadFolderPlaylist(item.parentId, item.id);
      return;
    }
    _replaceSnapshot(
      _sourceItems,
      currentItemId: item.id,
      folderId: _currentFolderId,
    );
  }

  int indexOfItem(String itemId) => _snapshot.indexOf(itemId);

  void _replaceSnapshot(
    Iterable<VideoItem> items, {
    required String? currentItemId,
    required String? folderId,
    bool revalidate = true,
  }) {
    final entries = revalidate
        ? _queuePolicy.filter(items)
        : List<VideoItem>.unmodifiable(items);
    _anchoredItemId = currentItemId;
    _snapshot = PlaybackQueueSnapshot(
      revision: _snapshot.revision + 1,
      entries: entries,
      currentItemId: currentItemId,
      folderId: folderId,
    );
    notifyListeners();
  }
}
