import 'package:video_player_app/models/bilibili_download_task.dart';

sealed class BilibiliDownloadListRow {
  const BilibiliDownloadListRow(this.task, {required this.isLastInTask});

  final BilibiliDownloadTask task;
  final bool isLastInTask;
}

final class BilibiliTaskHeaderRow extends BilibiliDownloadListRow {
  const BilibiliTaskHeaderRow(super.task, {required super.isLastInTask});
}

final class BilibiliVideoHeaderRow extends BilibiliDownloadListRow {
  const BilibiliVideoHeaderRow(
    super.task,
    this.video, {
    required super.isLastInTask,
  });

  final BilibiliVideoItem video;
}

final class BilibiliEpisodeRow extends BilibiliDownloadListRow {
  const BilibiliEpisodeRow(
    super.task,
    this.video,
    this.episode, {
    required this.useSingleControls,
    required super.isLastInTask,
  });

  final BilibiliVideoItem video;
  final BilibiliDownloadEpisode episode;
  final bool useSingleControls;
}

class BilibiliDownloadListProjection {
  const BilibiliDownloadListProjection._();

  static List<BilibiliDownloadListRow> build(
    Iterable<BilibiliDownloadTask> tasks, {
    bool forceTasksCollapsed = false,
  }) {
    final rows = <BilibiliDownloadListRow>[];
    for (final task in tasks) {
      if (forceTasksCollapsed || !task.isExpanded) {
        rows.add(BilibiliTaskHeaderRow(task, isLastInTask: true));
        continue;
      }

      final isSingle =
          !task.isCollection &&
          task.videos.length == 1 &&
          task.videos.first.episodes.length == 1;
      final descendants = <BilibiliDownloadListRow>[];
      if (isSingle) {
        final video = task.videos.first;
        descendants.add(
          BilibiliEpisodeRow(
            task,
            video,
            video.episodes.first,
            useSingleControls: true,
            isLastInTask: true,
          ),
        );
      } else {
        for (final video in task.videos) {
          if (task.isCollection && video.episodes.length > 1) {
            descendants.add(
              BilibiliVideoHeaderRow(task, video, isLastInTask: false),
            );
          }
          for (final episode in video.episodes) {
            descendants.add(
              BilibiliEpisodeRow(
                task,
                video,
                episode,
                useSingleControls: false,
                isLastInTask: false,
              ),
            );
          }
        }
      }

      rows.add(BilibiliTaskHeaderRow(task, isLastInTask: descendants.isEmpty));
      for (var index = 0; index < descendants.length; index++) {
        final row = descendants[index];
        final isLast = index == descendants.length - 1;
        rows.add(switch (row) {
          BilibiliVideoHeaderRow(:final video) => BilibiliVideoHeaderRow(
            task,
            video,
            isLastInTask: isLast,
          ),
          BilibiliEpisodeRow(
            :final video,
            :final episode,
            :final useSingleControls,
          ) =>
            BilibiliEpisodeRow(
              task,
              video,
              episode,
              useSingleControls: useSingleControls,
              isLastInTask: isLast,
            ),
          BilibiliTaskHeaderRow() => throw StateError('Unexpected row'),
        });
      }
    }
    return rows;
  }
}
