import '../models/subtitle_model.dart';

class SubtitleTrackMatchResult {
  final Map<int, int> primaryToSecondary;
  final Map<int, int> secondaryToPrimary;

  const SubtitleTrackMatchResult({
    required this.primaryToSecondary,
    required this.secondaryToPrimary,
  });

  int get matchCount => primaryToSecondary.length;
  bool get hasMatches => primaryToSecondary.isNotEmpty;
}

class SubtitleDisplaySelection {
  final List<SubtitleItem> subtitles;
  final bool usesSecondaryTrack;

  const SubtitleDisplaySelection({
    required this.subtitles,
    required this.usesSecondaryTrack,
  });
}

SubtitleDisplaySelection resolveSubtitleDisplaySelection({
  required int lineFilterMode,
  required List<SubtitleItem> primarySubtitles,
  required List<SubtitleItem> secondarySubtitles,
}) {
  if (lineFilterMode == 2 && secondarySubtitles.isNotEmpty) {
    return SubtitleDisplaySelection(
      subtitles: secondarySubtitles,
      usesSecondaryTrack: true,
    );
  }
  return SubtitleDisplaySelection(
    subtitles: primarySubtitles,
    usesSecondaryTrack: false,
  );
}

SubtitleTrackMatchResult matchSubtitleTracks({
  required List<SubtitleItem> primarySubtitles,
  required List<SubtitleItem> secondarySubtitles,
  int maxGapMs = 1500,
  int lookAhead = 6,
}) {
  final Map<int, int> primaryToSecondary = <int, int>{};
  final Map<int, int> secondaryToPrimary = <int, int>{};

  if (primarySubtitles.isEmpty || secondarySubtitles.isEmpty) {
    return const SubtitleTrackMatchResult(
      primaryToSecondary: <int, int>{},
      secondaryToPrimary: <int, int>{},
    );
  }

  final SubtitleTrackMatchResult? indexAlignedMatch =
      _tryBuildIndexAlignedMatch(
    primarySubtitles: primarySubtitles,
    secondarySubtitles: secondarySubtitles,
  );
  if (indexAlignedMatch != null) {
    return indexAlignedMatch;
  }

  int secondaryCursor = 0;
  for (int primaryIndex = 0; primaryIndex < primarySubtitles.length; primaryIndex++) {
    final SubtitleItem primary = primarySubtitles[primaryIndex];
    final int primaryStartMs = primary.startTime.inMilliseconds;
    final int primaryEndMs = _effectiveEndTimeMs(primarySubtitles, primaryIndex);

    while (secondaryCursor < secondarySubtitles.length) {
      final int secondaryEndMs = _effectiveEndTimeMs(
        secondarySubtitles,
        secondaryCursor,
      );
      if (secondaryEndMs + maxGapMs < primaryStartMs) {
        secondaryCursor++;
        continue;
      }
      break;
    }

    int? bestSecondaryIndex;
    int bestScore = -1 << 30;
    final int searchStart = secondaryCursor;
    final int searchEnd = (searchStart + lookAhead) < secondarySubtitles.length
        ? (searchStart + lookAhead)
        : secondarySubtitles.length;

    for (int secondaryIndex = searchStart;
        secondaryIndex < searchEnd;
        secondaryIndex++) {
      final SubtitleItem secondary = secondarySubtitles[secondaryIndex];
      final int secondaryStartMs = secondary.startTime.inMilliseconds;
      if (secondaryStartMs > primaryEndMs + maxGapMs) {
        break;
      }

      final int secondaryEndMs = _effectiveEndTimeMs(
        secondarySubtitles,
        secondaryIndex,
      );
      final int score = _matchScore(
        primaryStartMs: primaryStartMs,
        primaryEndMs: primaryEndMs,
        secondaryStartMs: secondaryStartMs,
        secondaryEndMs: secondaryEndMs,
        maxGapMs: maxGapMs,
      );
      if (score > bestScore) {
        bestScore = score;
        bestSecondaryIndex = secondaryIndex;
      }
    }

    if (bestSecondaryIndex == null || bestScore <= -100000000) {
      continue;
    }

    primaryToSecondary[primaryIndex] = bestSecondaryIndex;
    secondaryToPrimary[bestSecondaryIndex] = primaryIndex;
    secondaryCursor = bestSecondaryIndex + 1;
  }

  return SubtitleTrackMatchResult(
    primaryToSecondary: primaryToSecondary,
    secondaryToPrimary: secondaryToPrimary,
  );
}

SubtitleTrackMatchResult? _tryBuildIndexAlignedMatch({
  required List<SubtitleItem> primarySubtitles,
  required List<SubtitleItem> secondarySubtitles,
}) {
  if (primarySubtitles.length != secondarySubtitles.length) {
    return null;
  }
  if (primarySubtitles.isEmpty) {
    return const SubtitleTrackMatchResult(
      primaryToSecondary: <int, int>{},
      secondaryToPrimary: <int, int>{},
    );
  }

  const int startToleranceMs = 120;
  const int endToleranceMs = 180;
  const double minSameTimelineRatio = 0.9;

  int timelineNearEqualCount = 0;
  for (int i = 0; i < primarySubtitles.length; i++) {
    final int startDeltaMs = (primarySubtitles[i].startTime.inMilliseconds -
            secondarySubtitles[i].startTime.inMilliseconds)
        .abs();
    final int endDeltaMs = (primarySubtitles[i].endTime.inMilliseconds -
            secondarySubtitles[i].endTime.inMilliseconds)
        .abs();
    if (startDeltaMs <= startToleranceMs && endDeltaMs <= endToleranceMs) {
      timelineNearEqualCount++;
    }
  }

  final double sameTimelineRatio =
      timelineNearEqualCount / primarySubtitles.length;
  if (sameTimelineRatio < minSameTimelineRatio) {
    return null;
  }

  final Map<int, int> primaryToSecondary = <int, int>{};
  final Map<int, int> secondaryToPrimary = <int, int>{};
  for (int i = 0; i < primarySubtitles.length; i++) {
    primaryToSecondary[i] = i;
    secondaryToPrimary[i] = i;
  }

  return SubtitleTrackMatchResult(
    primaryToSecondary: primaryToSecondary,
    secondaryToPrimary: secondaryToPrimary,
  );
}


int subtitleEffectiveEndTimeMs(List<SubtitleItem> subtitles, int index) {
  return _effectiveEndTimeMs(subtitles, index);
}

int _effectiveEndTimeMs(List<SubtitleItem> subtitles, int index) {
  final SubtitleItem item = subtitles[index];
  final int actualEndMs = item.endTime.inMilliseconds;
  if (index + 1 >= subtitles.length) {
    return actualEndMs;
  }
  final int nextStartMs = subtitles[index + 1].startTime.inMilliseconds;
  return nextStartMs < actualEndMs ? actualEndMs : nextStartMs;
}

int _matchScore({
  required int primaryStartMs,
  required int primaryEndMs,
  required int secondaryStartMs,
  required int secondaryEndMs,
  required int maxGapMs,
}) {
  final int overlapStart = primaryStartMs > secondaryStartMs
      ? primaryStartMs
      : secondaryStartMs;
  final int overlapEnd = primaryEndMs < secondaryEndMs ? primaryEndMs : secondaryEndMs;
  final int overlapMs = overlapEnd - overlapStart;
  final int startDelta = (primaryStartMs - secondaryStartMs).abs();
  final int endDelta = (primaryEndMs - secondaryEndMs).abs();

  if (overlapMs > 0) {
    return overlapMs * 1000 - startDelta * 10 - endDelta;
  }

  final int gapMs;
  if (secondaryStartMs > primaryEndMs) {
    gapMs = secondaryStartMs - primaryEndMs;
  } else if (primaryStartMs > secondaryEndMs) {
    gapMs = primaryStartMs - secondaryEndMs;
  } else {
    gapMs = 0;
  }

  if (gapMs > maxGapMs) {
    return -100000000;
  }

  return 500000 - gapMs * 100 - startDelta * 10 - endDelta;
}
