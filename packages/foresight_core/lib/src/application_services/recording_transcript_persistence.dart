import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import '../meeting_workflow_store.dart';
import '../rpc_error.dart';
import '../store.dart';

final class RecordingTranscriptSegment {
  RecordingTranscriptSegment(
    this.text,
    this.start,
    this.end,
    this.source, {
    required this.finalText,
  });
  final String text, source;
  final int start, end;
  final bool finalText;
  int attempts = 0;
  final age = Stopwatch()..start();
  late final int bytes = utf8
      .encode(jsonEncode([text, start, end, source, finalText]))
      .length;
}

/// Only text/metadata enters this queue. PCM remains owned by Recording.
/// Remove a segment only after its complete transactional write succeeds.
final class RecordingTranscriptPersistence {
  RecordingTranscriptPersistence({
    required this.store,
    required this.meeting,
    required this.createTimer,
    required this.committed,
    required this.retrying,
    required this.exhausted,
  });
  final Store store;
  final int meeting;
  final Timer Function(Duration, void Function()) createTimer;
  final void Function(RecordingTranscriptSegment) committed;
  final void Function() retrying, exhausted;
  final _queue = ListQueue<RecordingTranscriptSegment>();
  int _bytes = 0, _overflow = 0, finalCommitted = 0;
  Timer? _retry;
  Completer<void>? _settlement;
  bool failed = false, _disposed = false;
  Object? failure;
  StackTrace? failureStack;
  int get pending => _queue.length + _overflow;
  Future<void> get settled => failed || _queue.isEmpty
      ? Future<void>.value()
      : (_settlement ??= Completer<void>()).future;

  void add(RecordingTranscriptSegment segment) {
    if (_disposed) return;
    final size = segment.bytes;
    if (failed || _queue.length >= 64 || _bytes + size > 1024 * 1024) {
      _overflow++;
      _fail();
      return;
    }
    _queue.add(segment);
    _bytes += size;
    if (_retry == null) _drain();
  }

  void _drain() {
    _retry = null;
    while (_queue.isNotEmpty && !failed && !_disposed) {
      final segment = _queue.first;
      if (segment.age.elapsed >= const Duration(seconds: 60)) {
        _fail();
        return;
      }
      segment.attempts++;
      try {
        // transcript() inserts a row and increments the meeting revision in
        // separate statements. Roll back both before an idempotent retry.
        store.workflowTransaction(
          () => store.transcript(
            meeting,
            segment.text,
            segment.finalText,
            segment.start,
            segment.end,
            segment.finalText
                ? '${segment.source}; captured-sample timeline (gaps excluded)'
                : segment.source,
          ),
        );
      } catch (error, stack) {
        failure ??= error;
        failureStack ??= stack;
        if (segment.attempts >= 5) {
          _fail();
        } else {
          try {
            _retry = createTimer(const Duration(seconds: 1), _drain);
            retrying();
          } catch (_) {
            // A scheduler/observer failure cannot strand queued text forever.
            _fail();
          }
        }
        return;
      }
      _queue.removeFirst();
      _bytes -= segment.bytes;
      if (segment.finalText) finalCommitted++;
      // Post-commit UI/derived work is outside the retry boundary: a callback
      // failure cannot cause an already committed transcript to be duplicated.
      try {
        committed(segment);
      } catch (error, stack) {
        failure ??= error;
        failureStack ??= stack;
        _fail();
      }
    }
    if (_queue.isEmpty && !failed) {
      failure = null;
      failureStack = null;
      _settlement?.complete();
      _settlement = null;
    }
  }

  void _fail() {
    if (failed) return;
    failed = true;
    failure ??= RpcError(
      RpcErrorCode.unavailable,
      'Transcript storage could not recover within its bounded retry budget',
    );
    failureStack ??= StackTrace.current;
    _retry?.cancel();
    _retry = null;
    _settlement?.complete();
    _settlement = null;
    exhausted();
  }

  void dispose() {
    _disposed = true;
    _retry?.cancel();
    _retry = null;
    _queue.clear();
    _bytes = 0;
    _settlement?.complete();
    _settlement = null;
  }
}
