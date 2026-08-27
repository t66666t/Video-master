import 'dart:async';
import 'dart:collection';

import 'package:dio/dio.dart';

/// Caps media CDN connections across all Bilibili download tasks.
///
/// A cancelled waiter is completed immediately and is skipped when a permit
/// becomes available, so pausing a queued task can never leave it stuck behind
/// another download.
class BilibiliMediaConnectionPool {
  BilibiliMediaConnectionPool({required int limit})
    : assert(limit > 0),
      _limit = limit;

  final int _limit;
  final Queue<_ConnectionWaiter> _waiters = Queue<_ConnectionWaiter>();
  int _active = 0;

  int get limit => _limit;
  int get activeConnections => _active;
  int get waitingRequests =>
      _waiters.where((waiter) => !waiter.completer.isCompleted).length;

  Future<BilibiliMediaConnectionPermit> acquire({CancelToken? cancelToken}) {
    if (cancelToken?.isCancelled == true) {
      return Future<BilibiliMediaConnectionPermit>.error(
        _cancelException(cancelToken),
      );
    }

    final waiter = _ConnectionWaiter();
    _waiters.addLast(waiter);
    if (cancelToken != null) {
      unawaited(
        cancelToken.whenCancel.then((_) {
          if (!waiter.completer.isCompleted) {
            waiter.completer.completeError(_cancelException(cancelToken));
            _drain();
          }
        }),
      );
    }
    _drain();
    return waiter.completer.future;
  }

  void _drain() {
    while (_active < _limit && _waiters.isNotEmpty) {
      final waiter = _waiters.removeFirst();
      if (waiter.completer.isCompleted) continue;
      _active++;
      waiter.completer.complete(BilibiliMediaConnectionPermit._(this));
    }
  }

  void _release() {
    if (_active <= 0) return;
    _active--;
    _drain();
  }

  DioException _cancelException(CancelToken? cancelToken) {
    return cancelToken?.cancelError ??
        DioException(
          requestOptions: RequestOptions(path: ''),
          type: DioExceptionType.cancel,
          error: 'Download cancelled while waiting for a connection',
        );
  }
}

class BilibiliMediaConnectionPermit {
  BilibiliMediaConnectionPermit._(this._pool);

  BilibiliMediaConnectionPool? _pool;

  void release() {
    final pool = _pool;
    if (pool == null) return;
    _pool = null;
    pool._release();
  }
}

class _ConnectionWaiter {
  final Completer<BilibiliMediaConnectionPermit> completer =
      Completer<BilibiliMediaConnectionPermit>();
}
