import 'dart:async';

/// Original editor saves one second after the latest text change. Drafts are
/// captured before switching notes or disposing controllers/command transport.
class NoteSaveScheduler {
  NoteSaveScheduler(
    this.write, {
    this.onError,
    this.onSaved,
    this.createTimer = Timer.new,
  });
  final Timer Function(Duration, void Function()) createTimer;
  final Future<void> Function(int id, String body, int? lastManualEdit) write;
  final void Function(Object error, StackTrace stack)? onError;
  final void Function(int id)? onSaved;
  Timer? _timer;
  (int, String, int, int?)? _pending;
  final _failed = <int, (String, int, int?)>{};
  final _latest = <int, int>{};
  final _accepted = <int, int>{};
  var _serial = 0, _inFlight = 0;
  Future<void> _tail = Future.value();
  Future<void> _lastResult = Future.value();
  bool _closed = false;
  bool get hasWork => _pending != null || _failed.isNotEmpty || _inFlight > 0;

  bool isDirty(int id) => _latest[id] != _accepted[id];

  void schedule(int id, String body, {int? lastManualEdit}) {
    if (_closed) return;
    if (_pending != null && _pending!.$1 != id) _automaticFlush();
    _latest[id] = ++_serial;
    _failed.remove(id);
    _pending = (id, body, _serial, lastManualEdit);
    _timer?.cancel();
    _timer = createTimer(const Duration(seconds: 1), _automaticFlush);
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
    final drafts = <int, (String, int, int?)>{..._failed};
    _failed.clear();
    final pending = _pending;
    if (pending != null)
      drafts[pending.$1] = (pending.$2, pending.$3, pending.$4);
    _pending = null;
    if (drafts.isEmpty) return _lastResult;
    _inFlight++;
    final result = _tail
        .then((_) async {
          final entries = drafts.entries.toList();
          for (var index = 0; index < entries.length; index++) {
            final draft = entries[index];
            try {
              await write(draft.key, draft.value.$1, draft.value.$3);
              _accepted[draft.key] = draft.value.$2;
              onSaved?.call(draft.key);
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
