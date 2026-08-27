import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/models/bilibili_download_task.dart';
import 'package:video_player_app/services/bilibili/download_integrity.dart';
import 'package:video_player_app/services/bilibili/media_connection_pool.dart';
import 'package:video_player_app/services/bilibili/post_process_task_queue.dart';

void main() {
  group('SerialPostProcessQueue', () {
    test('超时任务不会永久阻塞后续任务', () async {
      final queue = SerialPostProcessQueue();
      final blocked = Completer<void>();
      final first = queue.enqueue(
        () => blocked.future,
        phase: '测试合成',
        timeout: const Duration(milliseconds: 20),
      );
      final second = queue.enqueue(
        () async => 42,
        phase: '后续合成',
        timeout: const Duration(seconds: 1),
      );

      await expectLater(first, throwsA(isA<PostProcessTimeoutException>()));
      expect(await second, 42);
    });

    test('失败任务不会污染串行队列', () async {
      final queue = SerialPostProcessQueue();
      final first = queue.enqueue<void>(
        () => Future<void>.error(StateError('merge failed')),
        phase: '失败合成',
        timeout: const Duration(seconds: 1),
      );
      final second = queue.enqueue(
        () async => 'ok',
        phase: '后续合成',
        timeout: const Duration(seconds: 1),
      );

      await expectLater(first, throwsStateError);
      expect(await second, 'ok');
    });

    test('独立修复队列不会阻塞普通合成队列', () async {
      final mergeQueue = SerialPostProcessQueue();
      final repairQueue = SerialPostProcessQueue();
      final repairGate = Completer<void>();

      final repair = repairQueue.enqueue(
        () => repairGate.future,
        phase: '兼容性修复',
        timeout: const Duration(seconds: 1),
      );
      final merge = mergeQueue.enqueue(
        () async => 'merged',
        phase: '普通合成',
        timeout: const Duration(seconds: 1),
      );

      expect(await merge, 'merged');
      repairGate.complete();
      await repair;
    });
  });

  group('BilibiliDownloadIntegrity', () {
    test('严格解析续传 Content-Range 起点', () {
      expect(
        BilibiliDownloadIntegrity.contentRangeStart('bytes 1024-2047/4096'),
        1024,
      );
      expect(BilibiliDownloadIntegrity.contentRangeStart('bytes 0-99/*'), 0);
      expect(BilibiliDownloadIntegrity.contentRangeStart('invalid'), isNull);
    });

    test('严格校验完整 Content-Range，拒绝错位和总长度变化', () {
      expect(
        BilibiliDownloadIntegrity.matchesRequestedRange(
          contentRange: 'bytes 100-199/1000',
          start: 100,
          endInclusive: 199,
          totalBytes: 1000,
        ),
        isTrue,
      );
      expect(
        BilibiliDownloadIntegrity.matchesRequestedRange(
          contentRange: 'bytes 99-199/1000',
          start: 100,
          endInclusive: 199,
          totalBytes: 1000,
        ),
        isFalse,
      );
      expect(
        BilibiliDownloadIntegrity.matchesRequestedRange(
          contentRange: 'bytes 100-199/999',
          start: 100,
          endInclusive: 199,
          totalBytes: 1000,
        ),
        isFalse,
      );
    });

    test('分片计划完整覆盖文件且能迁移连续旧断点', () {
      final parts = BilibiliDownloadIntegrity.createRangePlan(
        totalBytes: 1000,
        requestedConnections: 4,
        contiguousBytes: 375,
        minBytesPerConnection: 1,
      );

      expect(parts, hasLength(4));
      expect(
        BilibiliDownloadIntegrity.isValidRangePlan(parts, totalBytes: 1000),
        isTrue,
      );
      expect(parts.first.downloadedBytes, 250);
      expect(parts[1].downloadedBytes, 125);
      expect(parts[2].downloadedBytes, 0);
      expect(parts.last.endInclusive, 999);
    });

    test('拒绝有空洞、重叠或越界进度的分片计划', () {
      expect(
        BilibiliDownloadIntegrity.isValidRangePlan(const [
          DownloadRangePartState(
            start: 0,
            endInclusive: 49,
            downloadedBytes: 50,
          ),
          DownloadRangePartState(start: 51, endInclusive: 99),
        ], totalBytes: 100),
        isFalse,
      );
      expect(
        BilibiliDownloadIntegrity.isValidRangePlan(const [
          DownloadRangePartState(
            start: 0,
            endInclusive: 99,
            downloadedBytes: 101,
          ),
        ], totalBytes: 100),
        isFalse,
      );
    });

    test('拒绝截断、超长和空分片', () {
      expect(
        () => BilibiliDownloadIntegrity.validateCompletedLength(
          label: '视频分片',
          actualBytes: 99,
          expectedBytes: 100,
        ),
        throwsA(isA<DownloadIntegrityException>()),
      );
      expect(
        () => BilibiliDownloadIntegrity.validateCompletedLength(
          label: '视频分片',
          actualBytes: 101,
          expectedBytes: 100,
        ),
        throwsA(isA<DownloadIntegrityException>()),
      );
      expect(
        () => BilibiliDownloadIntegrity.validateCompletedLength(
          label: '视频分片',
          actualBytes: 0,
          expectedBytes: null,
        ),
        throwsA(isA<DownloadIntegrityException>()),
      );
    });

    test('接受长度完整或总长度未知的非空分片', () {
      BilibiliDownloadIntegrity.validateCompletedLength(
        label: '视频分片',
        actualBytes: 100,
        expectedBytes: 100,
      );
      BilibiliDownloadIntegrity.validateCompletedLength(
        label: '音频分片',
        actualBytes: 100,
        expectedBytes: null,
      );
    });
  });

  group('BilibiliMediaConnectionPool', () {
    test('等待连接时取消会立即退出且不会泄漏许可', () async {
      final pool = BilibiliMediaConnectionPool(limit: 1);
      final first = await pool.acquire();
      final token = CancelToken();
      final waiting = pool.acquire(cancelToken: token);

      expect(pool.activeConnections, 1);
      expect(pool.waitingRequests, 1);
      token.cancel('paused');
      await expectLater(
        waiting,
        throwsA(
          isA<DioException>().having(
            (error) => error.type,
            'type',
            DioExceptionType.cancel,
          ),
        ),
      );

      first.release();
      await Future<void>.delayed(Duration.zero);
      expect(pool.activeConnections, 0);
      expect(pool.waitingRequests, 0);
    });

    test('许可重复释放是安全的', () async {
      final pool = BilibiliMediaConnectionPool(limit: 1);
      final permit = await pool.acquire();
      permit.release();
      permit.release();
      expect(pool.activeConnections, 0);
    });
  });
}
