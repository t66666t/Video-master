import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:audio_service/audio_service.dart' as audio_service;
import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../models/subtitle_model.dart';
import '../models/video_item.dart';
import 'media_playback_service.dart';
import 'playlist_manager.dart';
import 'settings_service.dart';
import 'subtitle_timeline_resolver.dart';

class SystemMediaSessionService {
  SystemMediaSessionService._internal();

  static final SystemMediaSessionService instance =
      SystemMediaSessionService._internal();

  static const Duration _progressSyncThrottle = Duration(milliseconds: 800);
  static const Duration _seekJumpThreshold = Duration(milliseconds: 1500);
  static const Duration _subtitleBoundarySyncPadding = Duration(
    milliseconds: 45,
  );
  static const Duration _minimumSubtitleBoundaryDelay = Duration(
    milliseconds: 60,
  );

  _SystemMediaAudioHandler? _handler;
  MediaPlaybackService? _playbackService;
  PlaylistManager? _playlistManager;
  final SettingsService _settingsService = SettingsService();
  StreamSubscription<AudioInterruptionEvent>? _interruptionSubscription;
  StreamSubscription<void>? _becomingNoisySubscription;
  Timer? _scheduledSyncTimer;
  Timer? _scheduledSubtitleBoundaryTimer;
  bool _initialized = false;

  _PlaybackSnapshot? _lastSnapshot;
  DateTime _lastPublishedAt = DateTime.fromMillisecondsSinceEpoch(0);
  String? _audioPlaceholderArtworkPath;
  audio_service.MediaItem? _lastPublishedMediaItem;
  bool? _lastAllowConcurrentPlayback;
  bool? _lastHeadsetControlEnabled;
  int _publishRevision = 0;
  String? _lastVisibleNotificationItemId;
  String? _artworkCacheKey;
  Uri? _artworkCacheValue;
  bool _artworkCacheValid = false;

  void _logMediaSessionEvent(String message, {Map<String, Object?>? data}) {
    if (!kDebugMode) return;
    final buffer = StringBuffer('SystemMediaSessionService: $message');
    if (data != null && data.isNotEmpty) {
      buffer.write(' | ');
      bool first = true;
      data.forEach((key, value) {
        if (!first) buffer.write(', ');
        first = false;
        buffer.write('$key=$value');
      });
    }
    debugPrint(buffer.toString());
  }

  bool get isSupportedPlatform {
    if (kIsWeb) return false;
    return Platform.isAndroid || Platform.isIOS;
  }

  bool get headsetControlsEnabled =>
      _settingsService.enableHeadsetMediaControls;

  Future<void> _configureAudioSession() async {
    if (!isSupportedPlatform) {
      return;
    }
    final session = await AudioSession.instance;
    final bool allowConcurrentPlayback =
        _settingsService.allowConcurrentPlayback;
    await session.configure(
      const AudioSessionConfiguration.music()
          .copyWith(
            avAudioSessionCategoryOptions: AVAudioSessionCategoryOptions.none,
          )
          .copyWith(
            avAudioSessionCategoryOptions: allowConcurrentPlayback
                ? AVAudioSessionCategoryOptions.mixWithOthers
                : AVAudioSessionCategoryOptions.none,
          ),
    );
    _logMediaSessionEvent(
      'audio session configured',
      data: <String, Object?>{
        'platform': Platform.isIOS ? 'ios' : 'android',
        'dynamicIslandMode': Platform.isIOS ? 'system_mapped' : 'n/a',
        'allowConcurrentPlayback': allowConcurrentPlayback,
      },
    );
  }

  void _handleSettingsChanged() {
    final bool allowConcurrentPlayback =
        _settingsService.allowConcurrentPlayback;
    final bool headsetControlsEnabled =
        _settingsService.enableHeadsetMediaControls;
    if (_lastAllowConcurrentPlayback != allowConcurrentPlayback) {
      _lastAllowConcurrentPlayback = allowConcurrentPlayback;
      unawaited(_configureAudioSession());
    }
    if (_lastHeadsetControlEnabled != headsetControlsEnabled) {
      _lastHeadsetControlEnabled = headsetControlsEnabled;
      final snapshot = _buildSnapshot();
      _schedulePublish(immediate: true, snapshot: snapshot);
    }
  }

  Future<void> initialize({
    required MediaPlaybackService playbackService,
    required PlaylistManager playlistManager,
  }) async {
    if (!isSupportedPlatform) {
      return;
    }

    if (!_initialized) {
      final session = await AudioSession.instance;
      _lastAllowConcurrentPlayback = _settingsService.allowConcurrentPlayback;
      _lastHeadsetControlEnabled = _settingsService.enableHeadsetMediaControls;
      _settingsService.addListener(_handleSettingsChanged);
      await _configureAudioSession();

      _handler = await audio_service.AudioService.init(
        builder: _SystemMediaAudioHandler.new,
        config: audio_service.AudioServiceConfig(
          androidNotificationChannelId:
              'com.example.video_player_app.media_playback',
          androidNotificationChannelName: '媒体播放',
          androidNotificationIcon: 'drawable/ic_notification_icon',
          androidShowNotificationBadge: false,
          androidNotificationOngoing: true,
          androidStopForegroundOnPause: false,
          preloadArtwork: true,
        ),
      );

      _interruptionSubscription = session.interruptionEventStream.listen((
        event,
      ) {
        _logMediaSessionEvent(
          'audio interruption',
          data: <String, Object?>{
            'begin': event.begin,
            'type': event.type.name,
          },
        );
        if (event.begin) {
          unawaited(_playbackService?.pause());
          return;
        }
        if (event.type == AudioInterruptionType.pause &&
            _playbackService?.state == PlaybackState.paused) {
          unawaited(_playbackService?.resume());
        }
      });
      _becomingNoisySubscription = session.becomingNoisyEventStream.listen((_) {
        _logMediaSessionEvent('becoming noisy received');
        unawaited(_playbackService?.pause());
      });

      _initialized = true;
    }

    _bindPlaybackService(playbackService);
    _bindPlaylistManager(playlistManager);
    _handler?.attach(
      playbackService: playbackService,
      playlistManager: playlistManager,
    );
    _publishQueue();
    await _publishSnapshot(force: true);
  }

  void dispose() {
    _scheduledSyncTimer?.cancel();
    _scheduledSyncTimer = null;
    _scheduledSubtitleBoundaryTimer?.cancel();
    _scheduledSubtitleBoundaryTimer = null;
    _settingsService.removeListener(_handleSettingsChanged);
    _playbackService?.removeListener(_onPlaybackServiceChanged);
    _playbackService?.coarsePositionNotifier.removeListener(
      _onPlaybackPositionChanged,
    );
    _playlistManager?.removeListener(_onPlaylistChanged);
    _playbackService = null;
    _playlistManager = null;
    unawaited(_interruptionSubscription?.cancel());
    _interruptionSubscription = null;
    unawaited(_becomingNoisySubscription?.cancel());
    _becomingNoisySubscription = null;
  }

  void _bindPlaybackService(MediaPlaybackService playbackService) {
    if (identical(_playbackService, playbackService)) {
      return;
    }
    _playbackService?.removeListener(_onPlaybackServiceChanged);
    _playbackService?.coarsePositionNotifier.removeListener(
      _onPlaybackPositionChanged,
    );
    _playbackService = playbackService;
    _playbackService?.addListener(_onPlaybackServiceChanged);
    _playbackService?.coarsePositionNotifier.addListener(
      _onPlaybackPositionChanged,
    );
  }

  void _onPlaybackPositionChanged() => _onPlaybackServiceChanged();

  void _bindPlaylistManager(PlaylistManager playlistManager) {
    if (identical(_playlistManager, playlistManager)) {
      return;
    }
    _playlistManager?.removeListener(_onPlaylistChanged);
    _playlistManager = playlistManager;
    _playlistManager?.addListener(_onPlaylistChanged);
  }

  void _onPlaybackServiceChanged() {
    if (!_initialized || _handler == null) {
      return;
    }
    final snapshot = _buildSnapshot();
    final shouldPublishImmediately = _shouldPublishImmediately(snapshot);
    if (shouldPublishImmediately) {
      _logMediaSessionEvent(
        'playback snapshot changed immediately',
        data: <String, Object?>{
          'itemId': snapshot.itemId,
          'state': snapshot.state.name,
          'positionMs': snapshot.position.inMilliseconds,
          'queueIndex': snapshot.queueIndex,
        },
      );
    }
    _schedulePublish(immediate: shouldPublishImmediately, snapshot: snapshot);
  }

  void _onPlaylistChanged() {
    if (!_initialized || _handler == null) {
      return;
    }
    _logMediaSessionEvent(
      'playlist changed',
      data: <String, Object?>{
        'queueLength': _playlistManager?.playlist.length,
        'queueIndex': _playlistManager?.currentIndex,
      },
    );
    _publishQueue();
    final snapshot = _buildSnapshot();
    _schedulePublish(immediate: true, snapshot: snapshot);
  }

  void _schedulePublish({
    required bool immediate,
    required _PlaybackSnapshot snapshot,
  }) {
    if (immediate) {
      _scheduledSyncTimer?.cancel();
      _scheduledSyncTimer = null;
      unawaited(_publishSnapshot(snapshot: snapshot));
      return;
    }
    if (_scheduledSyncTimer != null) {
      return;
    }
    final elapsed = DateTime.now().difference(_lastPublishedAt);
    final wait = elapsed >= _progressSyncThrottle
        ? Duration.zero
        : (_progressSyncThrottle - elapsed);
    _scheduledSyncTimer = Timer(wait, () {
      _scheduledSyncTimer = null;
      _logMediaSessionEvent(
        'throttled publish triggered',
        data: <String, Object?>{'waitMs': wait.inMilliseconds},
      );
      unawaited(_publishSnapshot());
    });
  }

  bool _shouldPublishImmediately(_PlaybackSnapshot snapshot) {
    final previous = _lastSnapshot;
    if (previous == null) {
      return true;
    }
    if (previous.itemId != snapshot.itemId ||
        previous.state != snapshot.state ||
        previous.queueIndex != snapshot.queueIndex ||
        previous.title != snapshot.title ||
        previous.subtitle != snapshot.subtitle ||
        previous.duration != snapshot.duration) {
      return true;
    }
    final int positionDelta =
        (snapshot.position.inMilliseconds - previous.position.inMilliseconds)
            .abs();
    final int bufferedDelta =
        (snapshot.bufferedPosition.inMilliseconds -
                previous.bufferedPosition.inMilliseconds)
            .abs();
    return positionDelta >= _seekJumpThreshold.inMilliseconds ||
        bufferedDelta >= _seekJumpThreshold.inMilliseconds;
  }

  Future<void> _publishSnapshot({
    _PlaybackSnapshot? snapshot,
    bool force = false,
  }) async {
    if (!_initialized || _handler == null) {
      return;
    }

    final resolvedSnapshot = snapshot ?? _buildSnapshot();
    if (!force && resolvedSnapshot == _lastSnapshot) {
      return;
    }
    final previous = _lastSnapshot;
    final int publishRevision = ++_publishRevision;
    _logMediaSessionEvent(
      'publishing playback state',
      data: <String, Object?>{
        'itemId': resolvedSnapshot.itemId,
        'state': resolvedSnapshot.state.name,
        'positionMs': resolvedSnapshot.position.inMilliseconds,
        'durationMs': resolvedSnapshot.duration.inMilliseconds,
        'subtitle': resolvedSnapshot.subtitle,
        'force': force,
      },
    );

    audio_service.MediaItem? mediaItem;
    if (force || _shouldRefreshMediaItem(previous, resolvedSnapshot)) {
      mediaItem = await _buildCurrentMediaItem();
    } else if (_lastPublishedMediaItem == null &&
        resolvedSnapshot.itemId != null) {
      mediaItem = await _buildCurrentMediaItem();
    }
    if (publishRevision != _publishRevision) {
      _logMediaSessionEvent(
        'stale publish skipped',
        data: <String, Object?>{
          'itemId': resolvedSnapshot.itemId,
          'revision': publishRevision,
          'latestRevision': _publishRevision,
        },
      );
      return;
    }
    _lastSnapshot = resolvedSnapshot;
    _lastPublishedAt = DateTime.now();
    if (resolvedSnapshot.itemId == null) {
      _lastVisibleNotificationItemId = null;
    } else if (resolvedSnapshot.isPlaying) {
      _lastVisibleNotificationItemId = resolvedSnapshot.itemId;
    }
    if (mediaItem != null) {
      _lastPublishedMediaItem = mediaItem;
      _handler!.mediaItem.add(mediaItem);
    }
    _handler!.playbackState.add(_buildPlaybackState(resolvedSnapshot));
    _scheduleSubtitleBoundaryPublish(resolvedSnapshot);
  }

  void _publishQueue() {
    if (!_initialized || _handler == null) {
      return;
    }
    final mediaItems = _buildQueueMediaItems();
    _handler!.queue.add(mediaItems);
    _logMediaSessionEvent(
      'queue published',
      data: <String, Object?>{
        'queueLength': mediaItems.length,
        'currentIndex': _playlistManager?.currentIndex,
      },
    );
  }

  Future<void> refreshNow({bool ensureNotificationVisible = false}) async {
    if (!_initialized || _handler == null) {
      return;
    }
    final snapshot = _buildSnapshot();
    _logMediaSessionEvent(
      'manual refresh requested',
      data: <String, Object?>{
        'itemId': _playbackService?.currentItem?.id,
        'ensureNotificationVisible': ensureNotificationVisible,
      },
    );
    _publishQueue();
    await _publishSnapshot(snapshot: snapshot, force: true);
    if (ensureNotificationVisible) {
      await _ensureAndroidNotificationVisible(snapshot);
    }
  }

  Future<void> _ensureAndroidNotificationVisible(
    _PlaybackSnapshot snapshot,
  ) async {
    if (!Platform.isAndroid || _handler == null) {
      return;
    }
    if (snapshot.itemId == null ||
        snapshot.state == PlaybackState.idle ||
        snapshot.isPlaying ||
        _lastVisibleNotificationItemId == snapshot.itemId) {
      return;
    }
    _logMediaSessionEvent(
      'priming paused notification visibility',
      data: <String, Object?>{
        'itemId': snapshot.itemId,
        'state': snapshot.state.name,
      },
    );
    _handler!.playbackState.add(
      _buildPlaybackState(snapshot, forcePlaying: true),
    );
    await Future<void>.delayed(const Duration(milliseconds: 80));
    _handler!.playbackState.add(_buildPlaybackState(snapshot));
    _lastVisibleNotificationItemId = snapshot.itemId;
  }

  bool _shouldRefreshMediaItem(
    _PlaybackSnapshot? previous,
    _PlaybackSnapshot current,
  ) {
    if (previous == null) {
      return true;
    }
    return previous.itemId != current.itemId ||
        previous.title != current.title ||
        previous.subtitle != current.subtitle ||
        previous.duration != current.duration;
  }

  _PlaybackSnapshot _buildSnapshot({
    Duration? positionOverride,
    Duration? bufferedPositionOverride,
  }) {
    final playbackService = _playbackService;
    final playlistManager = _playlistManager;
    final currentItem = playbackService?.currentItem;
    final currentIndex = playlistManager?.currentIndex;
    final playlistLength = playlistManager?.playlist.length ?? 0;
    final canCircularNavigateQueue = playlistLength > 1;
    final resolvedPosition =
        positionOverride ??
        _resolveLivePosition(playbackService) ??
        playbackService?.position ??
        Duration.zero;
    final resolvedBufferedPosition =
        bufferedPositionOverride ??
        _resolveLiveBufferedPosition(playbackService) ??
        playbackService?.bufferedPosition ??
        Duration.zero;
    final resolvedSubtitle = _resolveCurrentSubtitleText(
      playbackService: playbackService,
      position: resolvedPosition,
    );
    return _PlaybackSnapshot(
      itemId: currentItem?.id,
      title: currentItem?.title,
      subtitle: resolvedSubtitle,
      state: playbackService?.state ?? PlaybackState.idle,
      position: resolvedPosition,
      duration: playbackService?.duration ?? Duration.zero,
      bufferedPosition: resolvedBufferedPosition,
      queueIndex: currentIndex != null && currentIndex >= 0
          ? currentIndex
          : null,
      isPlaying: playbackService?.isPlaying ?? false,
      hasPrevious: canCircularNavigateQueue,
      hasNext: canCircularNavigateQueue,
      speed: _resolvePlaybackSpeed(playbackService?.controller),
    );
  }

  List<audio_service.MediaItem> _buildQueueMediaItems() {
    final playbackService = _playbackService;
    final playlist = _playlistManager?.playlist ?? const <VideoItem>[];
    final currentSubtitleText = _resolveCurrentSubtitleText(
      playbackService: playbackService,
    );
    return playlist
        .map((item) {
          final secondaryText = _resolveSecondaryText(
            playbackService: playbackService,
            item: item,
            currentSubtitleText: currentSubtitleText,
          );
          return audio_service.MediaItem(
            id: item.id,
            title: item.title,
            album: item.type == MediaType.audio ? '音频' : '视频',
            artist: secondaryText,
            duration:
                item.id == playbackService?.currentItem?.id &&
                    playbackService != null &&
                    playbackService.duration > Duration.zero
                ? playbackService.duration
                : _durationFromItem(item),
            displayTitle: item.title,
            displaySubtitle: secondaryText,
            displayDescription: secondaryText,
          );
        })
        .toList(growable: false);
  }

  Future<audio_service.MediaItem?> _buildCurrentMediaItem() async {
    final playbackService = _playbackService;
    final item = playbackService?.currentItem;
    if (item == null) {
      return null;
    }

    final currentSubtitleText = _resolveCurrentSubtitleText(
      playbackService: playbackService,
    );
    final secondaryText = _resolveSecondaryText(
      playbackService: playbackService,
      item: item,
      currentSubtitleText: currentSubtitleText,
    );

    return audio_service.MediaItem(
      id: item.id,
      title: item.title,
      album: item.type == MediaType.audio ? '音频' : '视频',
      artist: secondaryText,
      duration: playbackService!.duration > Duration.zero
          ? playbackService.duration
          : _durationFromItem(item),
      artUri: await _resolveArtworkUri(item),
      displayTitle: item.title,
      displaySubtitle: secondaryText,
      displayDescription: secondaryText,
      extras: <String, dynamic>{
        'mediaType': item.type.name,
        // ignore: use_null_aware_elements
        if (currentSubtitleText case final subtitleText?)
          'currentSubtitle': subtitleText,
      },
    );
  }

  audio_service.PlaybackState _buildPlaybackState(
    _PlaybackSnapshot snapshot, {
    bool forcePlaying = false,
  }) {
    final bool remoteControlsEnabled = headsetControlsEnabled;
    final bool effectivePlaying = forcePlaying || snapshot.isPlaying;
    final List<audio_service.MediaControl> controls = remoteControlsEnabled
        ? <audio_service.MediaControl>[
            if (snapshot.hasPrevious) audio_service.MediaControl.skipToPrevious,
            if (_canStepWithinMedia(snapshot))
              audio_service.MediaControl.rewind,
            effectivePlaying
                ? audio_service.MediaControl.pause
                : audio_service.MediaControl.play,
            if (_canStepWithinMedia(snapshot))
              audio_service.MediaControl.fastForward,
            if (snapshot.hasNext) audio_service.MediaControl.skipToNext,
          ]
        : const <audio_service.MediaControl>[];

    final List<int> compactActionIndices = <int>[];
    final previousIndex = snapshot.hasPrevious ? 0 : null;
    final centerIndex = _canStepWithinMedia(snapshot)
        ? (snapshot.hasPrevious ? 2 : 1)
        : (snapshot.hasPrevious ? 1 : 0);
    final nextIndex = snapshot.hasNext ? controls.length - 1 : null;
    if (previousIndex != null) {
      compactActionIndices.add(previousIndex);
    }
    if (centerIndex >= 0 && centerIndex < controls.length) {
      compactActionIndices.add(centerIndex);
    }
    if (nextIndex != null && !compactActionIndices.contains(nextIndex)) {
      compactActionIndices.add(nextIndex);
    }

    return audio_service.PlaybackState(
      controls: controls,
      systemActions: remoteControlsEnabled && snapshot.duration > Duration.zero
          ? const <audio_service.MediaAction>{audio_service.MediaAction.seek}
          : const <audio_service.MediaAction>{},
      androidCompactActionIndices: compactActionIndices,
      processingState: _mapProcessingState(snapshot.state),
      playing: effectivePlaying,
      updatePosition: snapshot.position,
      bufferedPosition: snapshot.bufferedPosition,
      speed: snapshot.speed,
      queueIndex: snapshot.queueIndex,
    );
  }

  bool _canStepWithinMedia(_PlaybackSnapshot snapshot) {
    return snapshot.itemId != null && snapshot.duration > Duration.zero;
  }

  audio_service.AudioProcessingState _mapProcessingState(PlaybackState state) {
    switch (state) {
      case PlaybackState.idle:
        return audio_service.AudioProcessingState.idle;
      case PlaybackState.loading:
        return audio_service.AudioProcessingState.loading;
      case PlaybackState.playing:
        return audio_service.AudioProcessingState.ready;
      case PlaybackState.paused:
        return audio_service.AudioProcessingState.ready;
      case PlaybackState.error:
        return audio_service.AudioProcessingState.error;
    }
  }

  Duration? _durationFromItem(VideoItem item) {
    if (item.durationMs <= 0) {
      return null;
    }
    return Duration(milliseconds: item.durationMs);
  }

  double _resolvePlaybackSpeed(VideoPlayerControllerLike? controller) {
    if (controller == null) {
      return 1.0;
    }
    try {
      return controller.playbackSpeed;
    } catch (_) {
      return 1.0;
    }
  }

  String? _resolveSubtitle(SubtitleItem? subtitle) {
    if (subtitle == null) {
      return null;
    }
    final text = subtitle.text.trim();
    if (text.isEmpty) {
      return null;
    }
    return text;
  }

  String _resolveSecondaryText({
    required MediaPlaybackService? playbackService,
    required VideoItem item,
    String? currentSubtitleText,
  }) {
    final bool isCurrentItem = playbackService?.currentItem?.id == item.id;
    if (isCurrentItem) {
      final currentSubtitle =
          currentSubtitleText ??
          _resolveCurrentSubtitleText(playbackService: playbackService);
      if (currentSubtitle != null && currentSubtitle.isNotEmpty) {
        return currentSubtitle;
      }
    }
    return item.type == MediaType.audio ? '音频' : '视频';
  }

  Duration? _resolveLivePosition(MediaPlaybackService? playbackService) {
    final controller = playbackService?.controller;
    if (controller == null) {
      return null;
    }
    try {
      final value = controller.value;
      if (!value.isInitialized) {
        return null;
      }
      return value.position;
    } catch (_) {
      return null;
    }
  }

  Duration? _resolveLiveBufferedPosition(
    MediaPlaybackService? playbackService,
  ) {
    final controller = playbackService?.controller;
    if (controller == null) {
      return null;
    }
    try {
      final value = controller.value;
      if (!value.isInitialized) {
        return null;
      }
      final buffered = value.buffered;
      if (buffered.isEmpty) {
        return null;
      }
      return buffered.last.end;
    } catch (_) {
      return null;
    }
  }

  String? _resolveCurrentSubtitleText({
    required MediaPlaybackService? playbackService,
    Duration? position,
  }) {
    final subtitles = playbackService?.subtitles ?? const <SubtitleItem>[];
    if (subtitles.isEmpty) {
      return _resolveSubtitle(playbackService?.currentSubtitle);
    }
    final resolvedPosition =
        position ??
        _resolveLivePosition(playbackService) ??
        playbackService?.position ??
        Duration.zero;
    final resolver = SubtitleTimelineResolver(subtitles);
    final subtitle = resolver.subtitleAt(resolvedPosition);
    return _resolveSubtitle(subtitle) ??
        _resolveSubtitle(playbackService?.currentSubtitle);
  }

  void _scheduleSubtitleBoundaryPublish(_PlaybackSnapshot snapshot) {
    _scheduledSubtitleBoundaryTimer?.cancel();
    _scheduledSubtitleBoundaryTimer = null;

    if (!_initialized || _handler == null || !snapshot.isPlaying) {
      return;
    }

    final playbackService = _playbackService;
    final subtitles = playbackService?.subtitles ?? const <SubtitleItem>[];
    if (snapshot.itemId == null || subtitles.isEmpty) {
      return;
    }

    final livePosition =
        _resolveLivePosition(playbackService) ?? snapshot.position;
    final resolver = SubtitleTimelineResolver(subtitles);
    final nextBoundary = resolver.nextBoundaryAfter(livePosition);
    if (nextBoundary == null) {
      return;
    }

    Duration wait = nextBoundary - livePosition + _subtitleBoundarySyncPadding;
    if (wait.isNegative) {
      wait = Duration.zero;
    } else if (wait < _minimumSubtitleBoundaryDelay) {
      wait = _minimumSubtitleBoundaryDelay;
    }

    _scheduledSubtitleBoundaryTimer = Timer(wait, () {
      _scheduledSubtitleBoundaryTimer = null;
      if (!_initialized || _handler == null) {
        return;
      }
      final liveSnapshot = _buildSnapshot();
      _logMediaSessionEvent(
        'subtitle boundary publish triggered',
        data: <String, Object?>{
          'itemId': liveSnapshot.itemId,
          'positionMs': liveSnapshot.position.inMilliseconds,
          'subtitle': liveSnapshot.subtitle,
        },
      );
      unawaited(_publishSnapshot(snapshot: liveSnapshot));
    });
  }

  Future<Uri?> _resolveArtworkUri(VideoItem item) async {
    final cacheKey = '${item.id}|${item.type.name}|${item.thumbnailPath ?? ''}';
    if (_artworkCacheValid && _artworkCacheKey == cacheKey) {
      return _artworkCacheValue;
    }

    Uri? resolvedUri;
    if (item.type == MediaType.video) {
      final thumbnailPath = item.thumbnailPath;
      if (thumbnailPath != null && thumbnailPath.isNotEmpty) {
        final file = File(thumbnailPath);
        if (await file.exists()) {
          resolvedUri = file.uri;
        }
      }
    }

    if (resolvedUri == null) {
      final placeholderPath = await _ensureAudioPlaceholderArtworkPath();
      resolvedUri = placeholderPath == null ? null : File(placeholderPath).uri;
    }

    _artworkCacheKey = cacheKey;
    _artworkCacheValue = resolvedUri;
    _artworkCacheValid = true;
    return _artworkCacheValue;
  }

  Future<String?> _ensureAudioPlaceholderArtworkPath() async {
    if (_audioPlaceholderArtworkPath != null) {
      final existingFile = File(_audioPlaceholderArtworkPath!);
      if (await existingFile.exists()) {
        return _audioPlaceholderArtworkPath;
      }
    }

    try {
      final directory = await getTemporaryDirectory();
      final file = File(
        '${directory.path}${Platform.pathSeparator}media_audio_placeholder.png',
      );
      if (!await file.exists()) {
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder);
        const size = Size(512, 512);
        final paint = Paint()
          ..color = const Color(0xFF1E1E1E)
          ..style = PaintingStyle.fill;
        final rect = RRect.fromRectAndRadius(
          Offset.zero & size,
          const Radius.circular(96),
        );
        canvas.drawRRect(rect, paint);

        final glowPaint = Paint()
          ..color = const Color(0xFF4F7BF5).withValues(alpha: 0.22)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 48);
        canvas.drawCircle(
          Offset(size.width / 2, size.height / 2),
          160,
          glowPaint,
        );

        final textPainter = TextPainter(
          text: TextSpan(
            text: String.fromCharCode(Icons.music_note.codePoint),
            style: TextStyle(
              fontSize: 220,
              color: Colors.white,
              fontFamily: Icons.music_note.fontFamily,
              package: Icons.music_note.fontPackage,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        final offset = Offset(
          (size.width - textPainter.width) / 2,
          (size.height - textPainter.height) / 2,
        );
        textPainter.paint(canvas, offset);

        final image = await recorder.endRecording().toImage(
          size.width.toInt(),
          size.height.toInt(),
        );
        final pngBytes = await image.toByteData(format: ui.ImageByteFormat.png);
        if (pngBytes == null) {
          return null;
        }
        await file.writeAsBytes(pngBytes.buffer.asUint8List(), flush: true);
      }

      _audioPlaceholderArtworkPath = file.path;
      return _audioPlaceholderArtworkPath;
    } catch (_) {
      return null;
    }
  }
}

class _SystemMediaAudioHandler extends audio_service.BaseAudioHandler
    with audio_service.QueueHandler, audio_service.SeekHandler {
  MediaPlaybackService? _playbackService;
  PlaylistManager? _playlistManager;
  bool? _pendingQueueSkipAutoPlay;
  int _queueSkipRequestId = 0;

  bool _shouldHandleRemoteCommand(String command) {
    final enabled = SystemMediaSessionService.instance.headsetControlsEnabled;
    if (!enabled) {
      SystemMediaSessionService.instance._logMediaSessionEvent(
        'remote command ignored',
        data: <String, Object?>{'command': command, 'reason': 'disabled'},
      );
    }
    return enabled;
  }

  void attach({
    required MediaPlaybackService playbackService,
    required PlaylistManager playlistManager,
  }) {
    _playbackService = playbackService;
    _playlistManager = playlistManager;
  }

  @override
  Future<void> play() async {
    if (!_shouldHandleRemoteCommand('play')) return;
    SystemMediaSessionService.instance._logMediaSessionEvent(
      'remote play command received',
      data: <String, Object?>{'itemId': _playbackService?.currentItem?.id},
    );
    await _playbackService?.resume();
  }

  @override
  Future<void> pause() async {
    if (!_shouldHandleRemoteCommand('pause')) return;
    SystemMediaSessionService.instance._logMediaSessionEvent(
      'remote pause command received',
      data: <String, Object?>{'itemId': _playbackService?.currentItem?.id},
    );
    await _playbackService?.pause();
  }

  @override
  Future<void> stop() async {
    if (!_shouldHandleRemoteCommand('stop')) return;
    SystemMediaSessionService.instance._logMediaSessionEvent(
      'remote stop command received',
    );
    await _playbackService?.stop();
  }

  @override
  Future<void> seek(Duration position) async {
    if (!_shouldHandleRemoteCommand('seek')) return;
    SystemMediaSessionService.instance._logMediaSessionEvent(
      'remote seek command received',
      data: <String, Object?>{
        'targetMs': position.inMilliseconds,
        'itemId': _playbackService?.currentItem?.id,
      },
    );
    await _playbackService?.seekTo(position, source: 'system_media');
  }

  @override
  Future<void> rewind() async {
    if (!_shouldHandleRemoteCommand('rewind')) return;
    await _handleConfiguredStepDirection(isBackward: true);
  }

  @override
  Future<void> fastForward() async {
    if (!_shouldHandleRemoteCommand('fastForward')) return;
    await _handleConfiguredStepDirection(isBackward: false);
  }

  @override
  Future<void> skipToNext() async {
    if (!_shouldHandleRemoteCommand('skipToNext')) return;
    SystemMediaSessionService.instance._logMediaSessionEvent(
      'remote next command received',
      data: <String, Object?>{'itemId': _playbackService?.currentItem?.id},
    );
    await _handleQueueSkip(isNext: true);
  }

  @override
  Future<void> skipToPrevious() async {
    if (!_shouldHandleRemoteCommand('skipToPrevious')) return;
    SystemMediaSessionService.instance._logMediaSessionEvent(
      'remote previous command received',
      data: <String, Object?>{'itemId': _playbackService?.currentItem?.id},
    );
    await _handleQueueSkip(isNext: false);
  }

  @override
  Future<void> skipToQueueItem(int index) async {
    if (!_shouldHandleRemoteCommand('skipToQueueItem')) return;
    final playlistManager = _playlistManager;
    final playbackService = _playbackService;
    if (playlistManager == null || playbackService == null) {
      return;
    }
    final playlist = playlistManager.playlist;
    if (index < 0 || index >= playlist.length) {
      return;
    }
    SystemMediaSessionService.instance._logMediaSessionEvent(
      'remote queue item command received',
      data: <String, Object?>{'index': index, 'itemId': playlist[index].id},
    );
    await playbackService.playPlaylistItem(playlist[index], autoPlay: true);
  }

  @override
  Future<void> playMediaItem(audio_service.MediaItem mediaItem) async {
    if (!_shouldHandleRemoteCommand('playMediaItem')) return;
    final playlistManager = _playlistManager;
    final playbackService = _playbackService;
    if (playlistManager == null || playbackService == null) {
      return;
    }
    final index = playlistManager.indexOfItem(mediaItem.id);
    if (index < 0) {
      return;
    }
    SystemMediaSessionService.instance._logMediaSessionEvent(
      'remote media item command received',
      data: <String, Object?>{'index': index, 'itemId': mediaItem.id},
    );
    await playbackService.playPlaylistItem(
      playlistManager.playlist[index],
      autoPlay: true,
    );
  }

  Future<void> _handleConfiguredStepDirection({
    required bool isBackward,
  }) async {
    final playbackService = _playbackService;
    if (playbackService == null) {
      return;
    }
    final settings = SettingsService();
    final bool useSubtitleStep =
        settings.enableDoubleTapSubtitleSeek &&
        playbackService.subtitles.isNotEmpty;
    final direction = isBackward ? 'backward' : 'forward';
    SystemMediaSessionService.instance._logMediaSessionEvent(
      'remote step command received',
      data: <String, Object?>{
        'direction': direction,
        'mode': useSubtitleStep ? 'subtitle' : 'seconds',
        'seconds': settings.doubleTapSeekSeconds,
        'itemId': playbackService.currentItem?.id,
      },
    );
    playbackService.handleExternalDoubleTapSeek(
      isLeft: isBackward,
      doubleTapSeekSeconds: settings.doubleTapSeekSeconds,
      enableDoubleTapSubtitleSeek: useSubtitleStep,
      subtitleOffset: settings.subtitleOffset,
      source: 'system_media',
    );
  }

  Future<void> _handleQueueSkip({required bool isNext}) async {
    final playbackService = _playbackService;
    final playlistManager = _playlistManager;
    if (playbackService == null || playlistManager == null) {
      return;
    }
    final int requestId = ++_queueSkipRequestId;
    // Preserve the user's play/pause intent across an overlapping controller
    // hand-off. Loading temporarily reports isPlaying=false, so a second
    // notification action must inherit the first action's intent instead of
    // loading the final item paused.
    final bool autoPlay = playbackService.state == PlaybackState.loading
        ? (_pendingQueueSkipAutoPlay ?? false)
        : playbackService.isPlaying;
    _pendingQueueSkipAutoPlay = autoPlay;
    try {
      playlistManager.reloadPlaylist();
      final playlist = playlistManager.playlist;
      if (playlist.isEmpty) {
        return;
      }
      if (playlist.length == 1) {
        await playbackService.play(
          playlist.first,
          autoPlay: autoPlay,
          startPosition: playbackService.position,
        );
        return;
      }
      final currentIndex = playlistManager.currentIndex;
      final fallbackIndex = currentIndex >= 0 ? currentIndex : 0;
      final targetIndex = isNext
          ? (fallbackIndex + 1) % playlist.length
          : (fallbackIndex - 1 + playlist.length) % playlist.length;
      await playbackService.playPlaylistItem(
        playlist[targetIndex],
        autoPlay: autoPlay,
      );
    } finally {
      if (requestId == _queueSkipRequestId) {
        _pendingQueueSkipAutoPlay = null;
      }
    }
  }
}

class _PlaybackSnapshot {
  const _PlaybackSnapshot({
    required this.itemId,
    required this.title,
    required this.subtitle,
    required this.state,
    required this.position,
    required this.duration,
    required this.bufferedPosition,
    required this.queueIndex,
    required this.isPlaying,
    required this.hasPrevious,
    required this.hasNext,
    required this.speed,
  });

  final String? itemId;
  final String? title;
  final String? subtitle;
  final PlaybackState state;
  final Duration position;
  final Duration duration;
  final Duration bufferedPosition;
  final int? queueIndex;
  final bool isPlaying;
  final bool hasPrevious;
  final bool hasNext;
  final double speed;

  @override
  bool operator ==(Object other) {
    return other is _PlaybackSnapshot &&
        other.itemId == itemId &&
        other.title == title &&
        other.subtitle == subtitle &&
        other.state == state &&
        other.position == position &&
        other.duration == duration &&
        other.bufferedPosition == bufferedPosition &&
        other.queueIndex == queueIndex &&
        other.isPlaying == isPlaying &&
        other.hasPrevious == hasPrevious &&
        other.hasNext == hasNext &&
        (other.speed - speed).abs() < 0.001;
  }

  @override
  int get hashCode => Object.hash(
    itemId,
    title,
    subtitle,
    state,
    position,
    duration,
    bufferedPosition,
    queueIndex,
    isPlaying,
    hasPrevious,
    hasNext,
    speed.toStringAsFixed(3),
  );
}

typedef VideoPlayerControllerLike = dynamic;
