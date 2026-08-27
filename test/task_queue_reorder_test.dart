import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/models/batch_subtitle_task_view.dart';
import 'package:video_player_app/models/transcription_status.dart';
import 'package:video_player_app/services/transcription_manager.dart';
import 'package:video_player_app/widgets/task_queue_table.dart';

void main() {
  group('batch subtitle queue index conversion', () {
    final displayedTasks = <BatchSubtitleTaskView>[
      _task('active', TranscriptionStatus.transcribing),
      _task('a', TranscriptionStatus.idle),
      _task('b', TranscriptionStatus.idle),
      _task('c', TranscriptionStatus.idle),
      _task('done', TranscriptionStatus.completed),
    ];

    test('moving down ignores active and completed display rows', () {
      expect(
        calculateBatchSubtitleQueueIndex(
          displayedTasks: displayedTasks,
          oldIndex: 1,
          newIndex: 3,
          isDescending: false,
        ),
        2,
      );
    });

    test('moving up produces the exact final queue position', () {
      expect(
        calculateBatchSubtitleQueueIndex(
          displayedTasks: displayedTasks,
          oldIndex: 3,
          newIndex: 1,
          isDescending: false,
        ),
        0,
      );
    });

    test('dropping after the final display row still means queue end', () {
      expect(
        calculateBatchSubtitleQueueIndex(
          displayedTasks: displayedTasks,
          oldIndex: 1,
          newIndex: displayedTasks.length - 1,
          isDescending: false,
        ),
        2,
      );
    });

    test('descending display maps back to the underlying queue order', () {
      expect(
        calculateBatchSubtitleQueueIndex(
          displayedTasks: displayedTasks.reversed.toList(),
          oldIndex: 1,
          newIndex: 3,
          isDescending: true,
        ),
        0,
      );
    });
  });

  test(
    'manager treats destination as final index in both directions',
    () async {
      final manager = TranscriptionManager();
      addTearDown(manager.dispose);

      for (final key in ['a', 'b', 'c', 'd']) {
        await manager.startTranscription(
          '$key.mp4',
          videoId: key,
          videoTitle: key,
        );
      }

      expect(manager.reorderTask('id:a', 3), isTrue);
      expect(_queueKeys(manager), ['id:b', 'id:c', 'id:d', 'id:a']);

      expect(manager.reorderTask('id:a', 1), isTrue);
      expect(_queueKeys(manager), ['id:b', 'id:a', 'id:c', 'id:d']);
    },
  );
}

BatchSubtitleTaskView _task(String key, TranscriptionStatus status) {
  return BatchSubtitleTaskView(
    mediaKey: key,
    videoPath: '$key.mp4',
    videoName: key,
    videoDuration: '',
    isExternal: false,
    status: status,
    progress: 0,
    statusMessage: '',
    createdAt: 0,
  );
}

List<String> _queueKeys(TranscriptionManager manager) {
  return manager
      .getQueueSnapshot()
      .where((task) => task.status == TranscriptionStatus.idle)
      .map((task) => task.mediaKey)
      .toList();
}
