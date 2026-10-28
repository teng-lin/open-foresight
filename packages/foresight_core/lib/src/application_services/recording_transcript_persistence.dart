import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import '../meeting_attribution.dart';
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
    this.attribution,
  });
  final String text, source;
  final int start, end;
  final bool finalText;

  /// Optional person attribution committed with this row. It is metadata: its
  /// rejection never prevents the text from being saved.
  final TranscriptAttribution? attribution;

  /// Set after the commit that saved this segment.
  int? transcriptId;
  bool attributionSaved = false;

  /// SQLite extended result code when the attribution was rejected. Only the
  /// number is kept: an exception would carry participant names.
  int? attributionErrorCode;
  int attempts = 0;
  final age = Stopwatch()..start();
  late final int bytes = utf8
      .encode(
        jsonEncode([
          text,
          start,
          end,
          source,
          finalText,
          attribution?.toJson(),
        ]),
      )
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
    void Function(String)? report,
  }) : _report = report ?? stderr.writeln;
  final Store store;
  final int meeting;
  final Timer Function(Duration, void Function()) createTimer;
  final void Function(RecordingTranscriptSegment) committed;
  final void Function() retrying, exhausted;
  final void Function(String) _report;
  final _queue = ListQueue<RecordingTranscriptSegment>();
  int _bytes = 0, _overflow = 0, finalCommitted = 0;

  /// Segments saved without their requested attribution, and the latest
  /// rejection's extended result code. The text of each was committed.
  int attributionRejections = 0;
  int? lastAttributionRejectionCode;
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
        // The row, its revision bump and its attribution are separate
        // statements. Roll all back before an idempotent retry.
        final written = store.workflowTransaction(
          () => store.transcriptWithAttribution(
            meeting,
            segment.text,
            segment.finalText,
            segment.start,
            segment.end,
            segment.finalText
                ? '${segment.source}; captured-sample timeline (gaps excluded)'
                : segment.source,
            attribution: segment.attribution,
          ),
        );
        segment
          ..transcriptId = written.transcriptId
          ..attributionSaved = written.attributionSaved
          ..attributionErrorCode = written.attributionErrorCode;
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
      final rejected = segment.attributionErrorCode;
      if (rejected != null) {
        attributionRejections++;
        lastAttributionRejectionCode = rejected;
        // Never the exception or the segment: both can contain names.
        try {
          _report('Transcript attribution rejected (SQLite code $rejected)');
        } catch (_) {
          // A diagnostic sink failure cannot undo a committed transcript.
        }
      }
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
