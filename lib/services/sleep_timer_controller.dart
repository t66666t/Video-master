import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum SleepTimerMode {
  off,
  afterDuration,
  afterPlaybackDuration,
  endOfCurrentItem,
  endOfQueue,
  afterItemCount,
  atTime,
}

/// Page-independent sleep timer driven by the global playback session.
class SleepTimerController extends ChangeNotifier {
  SleepTimerController({DateTime Function()? now}) : _now = now ?? DateTime.now;

  static const String _modeKey = 'sleepTimer.mode';
  static const String _deadlineKey = 'sleepTimer.deadlineMs';
  static const Duration _heartbeatInterval = Duration(milliseconds: 500);

  final DateTime Function() _now;
  Timer? _heartbeat;
  Listenable? _playbackListenable;
  bool Function()? _isPlaybackRunning;
  Future<void> Function()? _onExpired;
  DateTime _lastSettledAt = DateTime.fromMillisecondsSinceEpoch(0);
  bool _wasPlaybackRunning = false;
  bool _expirationInFlight = false;
  int _lastNotifiedSecond = -1;
  Future<void> _persistenceTail = Future<void>.value();

  SleepTimerMode _mode = SleepTimerMode.off;
  DateTime? _deadline;
  Duration _playbackRemaining = Duration.zero;
  int _remainingItemCount = 0;

  SleepTimerMode get mode => _mode;
  bool get isActive => _mode != SleepTimerMode.off;
  DateTime? get deadline => _deadline;
  int get remainingItemCount => _remainingItemCount;

  Duration get remaining {
    if (!isActive) return Duration.zero;
    if (_mode == SleepTimerMode.afterDuration ||
        _mode == SleepTimerMode.atTime) {
      final value = _deadline?.difference(_now()) ?? Duration.zero;
      return value.isNegative ? Duration.zero : value;
    }
    if (_mode == SleepTimerMode.afterPlaybackDuration) {
      var value = _playbackRemaining;
      if (_wasPlaybackRunning) value -= _now().difference(_lastSettledAt);
      return value.isNegative ? Duration.zero : value;
    }
    return Duration.zero;
  }

  String get statusText {
    switch (_mode) {
      case SleepTimerMode.off:
        return '未设置';
      case SleepTimerMode.afterDuration:
        return '将在 ${_formatDuration(remaining)} 后暂停';
      case SleepTimerMode.afterPlaybackDuration:
        return '再播放 ${_formatDuration(remaining)} 后暂停';
      case SleepTimerMode.endOfCurrentItem:
        return '当前内容结束后暂停';
      case SleepTimerMode.endOfQueue:
        return '当前队列结束后暂停';
      case SleepTimerMode.afterItemCount:
        return '再播放 $_remainingItemCount 个内容后暂停';
      case SleepTimerMode.atTime:
        final target = _deadline;
        if (target == null) return '未设置';
        return '${_twoDigits(target.hour)}:${_twoDigits(target.minute)} 暂停';
    }
  }

  Future<void> initialize({
    required Listenable playbackListenable,
    required bool Function() isPlaybackRunning,
    required Future<void> Function() onExpired,
  }) async {
    _playbackListenable?.removeListener(_handlePlaybackStateChanged);
    _playbackListenable = playbackListenable;
    _isPlaybackRunning = isPlaybackRunning;
    _onExpired = onExpired;
    _wasPlaybackRunning = isPlaybackRunning();
    _lastSettledAt = _now();
    playbackListenable.addListener(_handlePlaybackStateChanged);

    final preferences = await SharedPreferences.getInstance();
    final storedMode = preferences.getInt(_modeKey);
    final storedDeadlineMs = preferences.getInt(_deadlineKey);
    if (storedMode != null &&
        storedMode >= 0 &&
        storedMode < SleepTimerMode.values.length &&
        storedDeadlineMs != null) {
      final restoredMode = SleepTimerMode.values[storedMode];
      final restoredDeadline = DateTime.fromMillisecondsSinceEpoch(
        storedDeadlineMs,
      );
      if ((restoredMode == SleepTimerMode.afterDuration ||
              restoredMode == SleepTimerMode.atTime) &&
          restoredDeadline.isAfter(_now())) {
        _mode = restoredMode;
        _deadline = restoredDeadline;
        _ensureHeartbeat();
      } else {
        await _clearPersistence(preferences);
      }
    }
    notifyListeners();
  }

  Future<void> scheduleAfter(
    Duration duration, {
    bool countOnlyWhilePlaying = false,
  }) async {
    if (duration <= Duration.zero) return;
    _settlePlaybackTime();
    _mode = countOnlyWhilePlaying
        ? SleepTimerMode.afterPlaybackDuration
        : SleepTimerMode.afterDuration;
    _deadline = countOnlyWhilePlaying ? null : _now().add(duration);
    _playbackRemaining = countOnlyWhilePlaying ? duration : Duration.zero;
    _remainingItemCount = 0;
    _lastSettledAt = _now();
    _wasPlaybackRunning = _isPlaybackRunning?.call() ?? false;
    _lastNotifiedSecond = -1;
    _ensureHeartbeat();
    await _persist();
    notifyListeners();
  }

  Future<void> scheduleAt(DateTime time) async {
    if (!time.isAfter(_now())) return;
    _mode = SleepTimerMode.atTime;
    _deadline = time;
    _playbackRemaining = Duration.zero;
    _remainingItemCount = 0;
    _lastNotifiedSecond = -1;
    _ensureHeartbeat();
    await _persist();
    notifyListeners();
  }

  Future<void> scheduleAtEndOfCurrentItem() =>
      _scheduleCompletionMode(SleepTimerMode.endOfCurrentItem);

  Future<void> scheduleAtEndOfQueue() =>
      _scheduleCompletionMode(SleepTimerMode.endOfQueue);

  Future<void> scheduleAfterItems(int count) async {
    if (count <= 0) return;
    await _scheduleCompletionMode(SleepTimerMode.afterItemCount, count: count);
  }

  Future<void> _scheduleCompletionMode(
    SleepTimerMode mode, {
    int count = 0,
  }) async {
    _mode = mode;
    _deadline = null;
    _playbackRemaining = Duration.zero;
    _remainingItemCount = count;
    _lastNotifiedSecond = -1;
    _heartbeat?.cancel();
    _heartbeat = null;
    await _persist();
    notifyListeners();
  }

  Future<void> extend(Duration duration) async {
    if (!isActive || duration <= Duration.zero) return;
    _settlePlaybackTime();
    if (_mode == SleepTimerMode.afterDuration ||
        _mode == SleepTimerMode.atTime) {
      _deadline = (_deadline ?? _now()).add(duration);
    } else if (_mode == SleepTimerMode.afterPlaybackDuration) {
      _playbackRemaining += duration;
      _lastSettledAt = _now();
    } else {
      return;
    }
    _lastNotifiedSecond = -1;
    await _persist();
    notifyListeners();
  }

  Future<void> cancel() async {
    _clearInMemory();
    await _persist();
    notifyListeners();
  }

  /// Called before the normal auto-play-on-completion decision.
  bool consumeItemCompletion({required bool hasNextItem}) {
    var shouldStop = false;
    switch (_mode) {
      case SleepTimerMode.endOfCurrentItem:
        shouldStop = true;
      case SleepTimerMode.endOfQueue:
        shouldStop = !hasNextItem;
      case SleepTimerMode.afterItemCount:
        if (_remainingItemCount > 0) _remainingItemCount--;
        shouldStop = _remainingItemCount <= 0;
      case SleepTimerMode.off:
      case SleepTimerMode.afterDuration:
      case SleepTimerMode.afterPlaybackDuration:
      case SleepTimerMode.atTime:
        break;
    }
    if (shouldStop) _clearInMemory();
    unawaited(_persist());
    notifyListeners();
    return shouldStop;
  }

  /// Reconciles an overdue wall-clock timer immediately after foregrounding.
  void checkNow() => _heartbeatTick();

  void _handlePlaybackStateChanged() {
    _settlePlaybackTime();
    _wasPlaybackRunning = _isPlaybackRunning?.call() ?? false;
    _lastSettledAt = _now();
  }

  void _settlePlaybackTime() {
    final now = _now();
    if (_mode == SleepTimerMode.afterPlaybackDuration && _wasPlaybackRunning) {
      final elapsed = now.difference(_lastSettledAt);
      if (!elapsed.isNegative) _playbackRemaining -= elapsed;
    }
    _lastSettledAt = now;
  }

  void _ensureHeartbeat() {
    _heartbeat ??= Timer.periodic(_heartbeatInterval, (_) => _heartbeatTick());
  }

  void _heartbeatTick() {
    if (!isActive) {
      _heartbeat?.cancel();
      _heartbeat = null;
      return;
    }
    _settlePlaybackTime();
    _wasPlaybackRunning = _isPlaybackRunning?.call() ?? false;
    _lastSettledAt = _now();
    final value = remaining;
    if ((_mode == SleepTimerMode.afterDuration ||
            _mode == SleepTimerMode.afterPlaybackDuration ||
            _mode == SleepTimerMode.atTime) &&
        value <= Duration.zero) {
      unawaited(_expire());
      return;
    }
    final seconds = value.inSeconds;
    if (seconds != _lastNotifiedSecond) {
      _lastNotifiedSecond = seconds;
      notifyListeners();
    }
  }

  Future<void> _expire() async {
    if (_expirationInFlight || !isActive) return;
    _expirationInFlight = true;
    try {
      _clearInMemory();
      await _persist();
      notifyListeners();
      await _onExpired?.call();
    } finally {
      _expirationInFlight = false;
    }
  }

  void _clearInMemory() {
    _mode = SleepTimerMode.off;
    _deadline = null;
    _playbackRemaining = Duration.zero;
    _remainingItemCount = 0;
    _lastNotifiedSecond = -1;
    _heartbeat?.cancel();
    _heartbeat = null;
  }

  Future<void> _persist() async {
    final mode = _mode;
    final deadline = _deadline;
    final operation = _persistenceTail.then((_) async {
      final preferences = await SharedPreferences.getInstance();
      if ((mode == SleepTimerMode.afterDuration ||
              mode == SleepTimerMode.atTime) &&
          deadline != null) {
        await preferences.setInt(_modeKey, mode.index);
        await preferences.setInt(_deadlineKey, deadline.millisecondsSinceEpoch);
        return;
      }
      await _clearPersistence(preferences);
    });
    _persistenceTail = operation.catchError((Object _) {});
    await operation;
  }

  Future<void> _clearPersistence(SharedPreferences preferences) async {
    await preferences.remove(_modeKey);
    await preferences.remove(_deadlineKey);
  }

  static String _formatDuration(Duration duration) {
    final totalMinutes = duration.inMinutes;
    final seconds = duration.inSeconds.remainder(60);
    final hours = totalMinutes ~/ 60;
    final minutes = totalMinutes.remainder(60);
    if (hours > 0) {
      return '$hours:${_twoDigits(minutes)}:${_twoDigits(seconds)}';
    }
    return '$minutes:${_twoDigits(seconds)}';
  }

  static String _twoDigits(int value) => value.toString().padLeft(2, '0');

  @override
  void dispose() {
    _heartbeat?.cancel();
    _playbackListenable?.removeListener(_handlePlaybackStateChanged);
    super.dispose();
  }
}
