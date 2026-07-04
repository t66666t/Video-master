import '../models/subtitle_model.dart';

class SubtitleTimelineResolver {
  SubtitleTimelineResolver(List<SubtitleItem> subtitles)
    : _subtitles = List<SubtitleItem>.unmodifiable(subtitles),
      _startTimesMs = List<int>.unmodifiable(
        subtitles.map((item) => item.startTime.inMilliseconds),
      );

  final List<SubtitleItem> _subtitles;
  final List<int> _startTimesMs;

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

  SubtitleItem? subtitleAt(
    Duration position, {
    int? preferredIndex,
  }) {
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
}
