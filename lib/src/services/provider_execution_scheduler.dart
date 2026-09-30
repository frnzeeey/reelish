import 'dart:async';
import 'dart:collection';

/// Bounds parallel provider work separately from native QuickJS heap use.
/// Defaults preserve Reelish's existing policy: four script fetch /
/// provider workers with at most two 64 MiB runtimes alive at once.
class ProviderExecutionScheduler {
  ProviderExecutionScheduler({this.workerLimit = 4, this.runtimeLimit = 2})
    : assert(workerLimit > 0),
      assert(runtimeLimit > 0),
      _runtimeSlots = _AsyncSemaphore(runtimeLimit);

  final int workerLimit;
  final int runtimeLimit;
  final _AsyncSemaphore _runtimeSlots;

  int workersFor(int providers) =>
      providers < workerLimit ? providers : workerLimit;
  Future<void> acquireRuntime() => _runtimeSlots.acquire();
  void releaseRuntime() => _runtimeSlots.release();
}

class _AsyncSemaphore {
  _AsyncSemaphore(this._capacity);

  final int _capacity;
  final Queue<Completer<void>> _waiters = Queue<Completer<void>>();
  int _active = 0;

  Future<void> acquire() {
    if (_active < _capacity) {
      _active++;
      return Future<void>.value();
    }
    final waiter = Completer<void>();
    _waiters.addLast(waiter);
    return waiter.future;
  }

  void release() {
    if (_waiters.isNotEmpty) {
      _waiters.removeFirst().complete();
    } else if (_active > 0) {
      _active--;
    }
  }
}
