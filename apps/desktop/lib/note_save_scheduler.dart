import 'dart:async';

/// Original editor saves one second after the latest text change. Drafts are
/// captured before switching notes or disposing controllers/command transport.
class NoteSaveScheduler {
  NoteSaveScheduler(this.write, {this.onError});
  final Future<void> Function(int id, String body) write;
  final void Function(Object error, StackTrace stack)? onError;
  Timer? _timer;
  (int, String, int)? _pending;
  final _failed = <int, (String, int)>{};
  final _latest = <int, int>{};
  var _serial = 0, _inFlight = 0;
  Future<void> _tail = Future.value();
  Future<void> _lastResult = Future.value();
  bool _closed = false;
  bool get hasWork => _pending != null || _failed.isNotEmpty || _inFlight > 0;

  void schedule(int id, String body) {
    if (_closed) return;
    if (_pending != null && _pending!.$1 != id) _automaticFlush();
    _latest[id] = ++_serial;
    _failed.remove(id);
    _pending = (id, body, _serial);
    _timer?.cancel();
    _timer = Timer(const Duration(seconds: 1), _automaticFlush);
  }

  void _automaticFlush() {
    unawaited(
      flush().catchError((Object error, StackTrace stack) {
        if (onError != null) {
          onError!(error, stack);
        } else {
          Error.throwWithStackTrace(error, stack);
        }
      }),
    );
  }

  Future<void> flush() {
    _timer?.cancel();
    _timer = null;
    final drafts = <int, (String, int)>{..._failed};
    _failed.clear();
    final pending = _pending;
    if (pending != null) drafts[pending.$1] = (pending.$2, pending.$3);
    _pending = null;
    if (drafts.isEmpty) return _lastResult;
    _inFlight++;
    final result = _tail
        .then((_) async {
          final entries = drafts.entries.toList();
          for (var index = 0; index < entries.length; index++) {
            final draft = entries[index];
            try {
              await write(draft.key, draft.value.$1);
            } catch (_) {
              for (final unwritten in entries.skip(index)) {
                if (_latest[unwritten.key] == unwritten.value.$2) {
                  _failed[unwritten.key] = unwritten.value;
                }
              }
              rethrow;
            }
          }
        })
        .whenComplete(() => _inFlight--);
    // A failed write must not prevent a later, independently accepted draft.
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    _lastResult = result;
    return result;
  }

  Future<void> close() {
    _closed = true;
    return flush();
  }
}
