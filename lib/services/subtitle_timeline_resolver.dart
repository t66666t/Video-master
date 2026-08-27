import '../models/subtitle_model.dart';

class SubtitleTimelineResolver {
  factory SubtitleTimelineResolver(List<SubtitleItem> subtitles) {
    final List<SubtitleItem> immutableSubtitles =
        List<SubtitleItem>.unmodifiable(subtitles);
    final List<int> startTimesMs = List<int>.unmodifiable(
      subtitles.map((item) => item.startTime.inMilliseconds),
    );
    final List<int> endTimesMs = List<int>.unmodifiable(
      subtitles.map((item) => item.endTime.inMilliseconds),
    );
    final List<int> extendedEndTimesMs = List<int>.unmodifiable(
      _buildGapFilledEndTimes(subtitles),
    );
    return SubtitleTimelineResolver._(
      subtitles: immutableSubtitles,
      startTimesMs: startTimesMs,
      extendedEndTimesMs: extendedEndTimesMs,
      prefixMaxEndTimesMs: _buildPrefixMax(endTimesMs),
      prefixMaxExtendedEndTimesMs: _buildPrefixMax(extendedEndTimesMs),
    );
  }

  const SubtitleTimelineResolver._({
    required List<SubtitleItem> subtitles,
    required List<int> startTimesMs,
    required List<int> extendedEndTimesMs,
    required List<int> prefixMaxEndTimesMs,
    required List<int> prefixMaxExtendedEndTimesMs,
  }) : _subtitles = subtitles,
       _startTimesMs = startTimesMs,
       _extendedEndTimesMs = extendedEndTimesMs,
       _prefixMaxEndTimesMs = prefixMaxEndTimesMs,
       _prefixMaxExtendedEndTimesMs = prefixMaxExtendedEndTimesMs;

  final List<SubtitleItem> _subtitles;
  final List<int> _startTimesMs;
  final List<int> _extendedEndTimesMs;
  final List<int> _prefixMaxEndTimesMs;
  final List<int> _prefixMaxExtendedEndTimesMs;

  bool get isEmpty => _subtitles.isEmpty;
  int get length => _subtitles.length;

  int firstStartAfterMs(int positionMs) {
    if (_subtitles.isEmpty) return 0;

    int low = 0;
    int high = _startTimesMs.length - 1;
    int answer = _startTimesMs.length;
    while (low <= high) {
      final int mid = (low + high) >> 1;
      if (_startTimesMs[mid] > positionMs) {
        answer = mid;
        high = mid - 1;
      } else {
        low = mid + 1;
      }
    }
    return answer;
  }

  /// Returns every cue active at [positionMs], in source order.
  ///
  /// When [extendToNextStart] is enabled, overlapping cues are treated as one
  /// coverage group. Their original durations remain intact, and only the cue
  /// that ends last is extended across the real gap before the next group.
  /// This keeps a short on-screen translation from lingering just because it
  /// appeared during a much longer narration cue.
  /// Prefix maximum end times let the backwards scan stop as soon as no
  /// earlier cue can still be active.
  List<int> activeIndicesAtMs(
    int positionMs, {
    bool extendToNextStart = false,
  }) {
    if (_subtitles.isEmpty) return const <int>[];

    final int candidate = _lastStartAtOrBeforeMs(positionMs);
    if (candidate < 0) return const <int>[];

    final List<int> prefixMaxEndTimes = extendToNextStart
        ? _prefixMaxExtendedEndTimesMs
        : _prefixMaxEndTimesMs;
    final List<int> activeReversed = <int>[];
    for (int index = candidate; index >= 0; index--) {
      if (prefixMaxEndTimes[index] <= positionMs) break;
      if (_effectiveEndTimeMs(index, extendToNextStart) > positionMs) {
        activeReversed.add(index);
      }
    }
    return activeReversed.reversed.toList(growable: false);
  }

  int indexAtMs(int positionMs, {int? preferredIndex}) {
    if (_subtitles.isEmpty) return -1;

    final int? preferred = _normalizeIndex(preferredIndex);
    if (preferred != null && _containsPosition(preferred, positionMs)) {
      return preferred;
    }
    final int? next = preferred == null ? null : _normalizeIndex(preferred + 1);
    if (next != null && _containsPosition(next, positionMs)) {
      return next;
    }

    int low = 0;
    int high = _startTimesMs.length - 1;
    int answer = -1;
    while (low <= high) {
      final int mid = (low + high) >> 1;
      if (_startTimesMs[mid] <= positionMs) {
        answer = mid;
        low = mid + 1;
      } else {
        high = mid - 1;
      }
    }

    if (answer < 0 || !_containsPosition(answer, positionMs)) {
      return -1;
    }
    return answer;
  }

  SubtitleItem? subtitleAt(Duration position, {int? preferredIndex}) {
    final index = indexAtMs(
      position.inMilliseconds,
      preferredIndex: preferredIndex,
    );
    if (index < 0) return null;
    return _subtitles[index];
  }

  Duration? nextBoundaryAfter(Duration position) {
    if (_subtitles.isEmpty) return null;

    final int positionMs = position.inMilliseconds;
    final int firstGreaterIndex = firstStartAfterMs(positionMs);
    if (firstGreaterIndex < _subtitles.length) {
      return _subtitles[firstGreaterIndex].startTime;
    }

    final lastSubtitle = _subtitles.last;
    if (positionMs < lastSubtitle.endTime.inMilliseconds) {
      return lastSubtitle.endTime;
    }
    return null;
  }

  int? _normalizeIndex(int? index) {
    if (index == null || index < 0 || index >= _subtitles.length) {
      return null;
    }
    return index;
  }

  bool _containsPosition(int index, int positionMs) {
    final int startMs = _startTimesMs[index];
    final int endMs = index + 1 < _subtitles.length
        ? _startTimesMs[index + 1]
        : _subtitles[index].endTime.inMilliseconds;
    return positionMs >= startMs && positionMs < endMs;
  }

  int _lastStartAtOrBeforeMs(int positionMs) {
    int low = 0;
    int high = _startTimesMs.length - 1;
    int answer = -1;
    while (low <= high) {
      final int mid = (low + high) >> 1;
      if (_startTimesMs[mid] <= positionMs) {
        answer = mid;
        low = mid + 1;
      } else {
        high = mid - 1;
      }
    }
    return answer;
  }

  int _effectiveEndTimeMs(int index, bool extendToNextStart) {
    return extendToNextStart
        ? _extendedEndTimesMs[index]
        : _subtitles[index].endTime.inMilliseconds;
  }

  static List<int> _buildPrefixMax(List<int> values) {
    final List<int> result = <int>[];
    int prefixMax = -1;
    for (final int value in values) {
      if (value > prefixMax) prefixMax = value;
      result.add(prefixMax);
    }
    return List<int>.unmodifiable(result);
  }

  static List<int> _buildGapFilledEndTimes(List<SubtitleItem> subtitles) {
    final List<int> result = subtitles
        .map((item) => item.endTime.inMilliseconds)
        .toList(growable: false);
    if (subtitles.length < 2) return result;

    int groupLastEndMs = result.first;
    int groupLastEndOwner = 0;
    for (int index = 1; index < subtitles.length; index++) {
      final int startMs = subtitles[index].startTime.inMilliseconds;
      final int endMs = result[index];
      if (startMs <= groupLastEndMs) {
        if (endMs >= groupLastEndMs) {
          groupLastEndMs = endMs;
          groupLastEndOwner = index;
        }
        continue;
      }

      // There is no active subtitle between the previous coverage group and
      // this cue. Extend only the cue that naturally ended last in that group.
      result[groupLastEndOwner] = startMs;
      groupLastEndMs = endMs;
      groupLastEndOwner = index;
    }
    return result;
  }
}
