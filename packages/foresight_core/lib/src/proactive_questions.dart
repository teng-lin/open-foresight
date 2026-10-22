import 'rpc_error.dart';
import 'dart:async';
import 'text_budget.dart';
import 'store.dart';
import 'persistence/proactive_question_queries.dart';

import 'question_dispatch.dart';
export 'question_dispatch.dart'
    show normalizeMeetingQuestion, normalizeTranscriptWindow;

/// Service-owned transcript detection and durable grounded-answer jobs.
/// Capture never waits for model work.
class ProactiveQuestions {
  ProactiveQuestions({
    required this.store,
    required this.detect,
    required this.answer,
    required this.busy,
    required this.cancel,
    required this.changed,
    this.delay = const Duration(seconds: 1),
    int Function()? nowMilliseconds,
  }) : _nowMilliseconds = nowMilliseconds ?? _systemMilliseconds;

  static int _systemMilliseconds() => DateTime.now().millisecondsSinceEpoch;
  final int Function() _nowMilliseconds;

  final Store store;
  late final _queries = ProactiveQuestionQueries(store);
  final Future<List<String>> Function(String text, String requestId) detect;
  final Future<int> Function(int meetingId, String question, String requestId)
  answer;
  final bool Function() busy;
  final void Function(String requestId) cancel;
  final void Function() changed;
  final Duration delay;
  final _pending = <int>{};
  final _inputVersions = <int, int>{};
  final _examinedVersions = <int, int>{};
  final _interim = <int, Map<String, String>>{};
  final _lastInputIsFinal = <int, bool>{};
  final _windowSeen = <int, QuestionTextDeduplicator>{};
  final _dispatchers = <int, MeetingQuestionDispatcher>{};
  final _activeQuestions = <int, Map<String, int>>{};
  final errors = <int, String>{};
  Timer? _timer;
  Future<void>? _inFlight;
  String? _request;
  int? _activeMeeting;
  bool _closed = false, _suspended = false;
  int _yields = 0;
  bool get enabled => store.preference('proactiveAnswers', 'true') == 'true';
  bool get running => _inFlight != null;
  bool ownsRequest(String request) => _allowed && _request == request;
  Map<String, Object?> get state => {
    'enabled': enabled,
    'running': running,
    'active_meeting': _activeMeeting,
    'pending_meetings': _pending.toList(),
    'errors': {for (final entry in errors.entries) '${entry.key}': entry.value},
    'queued_answers': _queries.queuedCount,
    'oldest_queue_age_ms': (() {
      final oldest = _queries.oldestQueuedAt;
      return oldest == null
          ? 0
          : (_nowMilliseconds() - oldest).clamp(0, 1 << 53);
    })(),
    'stage': _request == null
        ? 'idle'
        : _request!.startsWith('proactive-answer-')
        ? 'answering'
        : 'detecting',
  };

  /// Start at the existing history boundary on a meeting's first recording.
  /// An existing cursor retains unprocessed final segments across a restart.
  void begin(int meetingId) => _queries.beginAtCurrentTranscript(meetingId);

  void restore() {
    for (final meeting in _queries.restoreQueuedMeetings()) {
      notify(meeting);
    }
    wake();
  }

  void notify(int meetingId, {bool isFinal = true}) {
    if (_closed) return;
    _lastInputIsFinal[meetingId] = isFinal;
    _inputVersions[meetingId] = (_inputVersions[meetingId] ?? 0) + 1;
    _pending.add(meetingId);
    wake();
  }

  /// Hypotheses replace one capture channel's current text rather than append
  /// to finalized history. Repeated hypotheses refresh window suppression.
  void updateInterim(int meetingId, String source, String text) {
    if (_closed) return;
    final channels = _interim.putIfAbsent(meetingId, () => {});
    final trimmed = text.trim();
    if ((channels[source] ?? '') == trimmed) {
      if (trimmed.isNotEmpty) notify(meetingId, isFinal: false);
      return;
    }
    if (trimmed.isEmpty) {
      channels.remove(source);
    } else {
      channels[source] = trimmed;
    }
    notify(meetingId, isFinal: false);
  }

  /// Final callbacks remove their matching hypothesis before notifying final
  /// input. Pausing/stopping clears all channels so stale speech is not reused.
  void clearInterim(int meetingId, [String? source]) {
    final channels = _interim[meetingId];
    if (channels == null) return;
    if (source == null) {
      channels.clear();
    } else {
      channels.remove(source);
    }
  }

  void wake() {
    if (_closed || _suspended) return;
    if (!enabled) {
      _timer?.cancel();
      _timer = null;
      if (_request != null) cancel(_request!);
      return;
    }
    if (_pending.isEmpty || _inFlight != null || _timer != null) return;
    _timer = Timer(delay, () {
      _timer = null;
      unawaited(process());
    });
  }

  void retry(int questionId) {
    final question = _queries.question(questionId);
    if (question == null) {
      throw RpcError(RpcErrorCode.notFound, 'Question not found');
    }
    if (![
      'failed',
      'insufficient_context',
      'cancelled',
    ].contains(question.state)) {
      throw StateError('Question is not awaiting retry');
    }
    _queries.queueForRetry(questionId);
    notify(question.meetingId);
    changed();
  }

  Future<void> process() {
    if (_inFlight != null) return _inFlight!;
    _timer?.cancel();
    _timer = null;
    return _inFlight = _processOne().whenComplete(() {
      _inFlight = null;
      if (!_closed) changed();
      wake();
    });
  }

  bool _hasUnexaminedInput(int meetingId) {
    if (_examinedVersions[meetingId] == (_inputVersions[meetingId] ?? 0)) {
      return false;
    }
    if (_interim[meetingId]?.isNotEmpty ?? false) return true;
    return _queries.hasFinalAfterCursor(meetingId);
  }

  bool get _allowed => !_closed && !_suspended && _yields == 0 && enabled;
  bool _linkCommittedAnswer(int question, [int? answer]) =>
      _queries.linkCommittedAnswer(question, answer: answer, request: _request);

  Future<void> yieldToForeground() async {
    _yields++;
    _timer?.cancel();
    _timer = null;
    try {
      if (_request != null) cancel(_request!);
      await _inFlight;
    } finally {
      _yields--;
      wake();
    }
  }

  Future<void> _processOne() async {
    if (!_allowed || _pending.isEmpty || busy()) return;
    final meetingId = _pending.first;
    _activeMeeting = meetingId;
    _pending.remove(meetingId);
    int? questionId, examinedInput;
    var queuedWork = false;
    try {
      errors.remove(meetingId);
      final queued = _queries.nextQueued(meetingId);
      queuedWork = queued != null;
      if (queued != null && !_hasUnexaminedInput(meetingId)) {
        questionId = queued.id;
        _queries.markAnswering(questionId);
        changed();
        _request =
            'proactive-answer-$questionId-${DateTime.now().microsecondsSinceEpoch}';
        final answerId = await answer(meetingId, queued.question, _request!);
        if (!_allowed) {
          if (_linkCommittedAnswer(questionId, answerId)) return;
          _queries.returnToQueue(questionId);
          _pending.add(meetingId);
          return;
        }
        final status = _queries.answerStatus(answerId);
        _queries.finishAnswer(
          questionId,
          answerId,
          status,
          status == 'failed' ? 'Answer generation failed. Try again.' : '',
        );
      } else {
        final inputVersion = _inputVersions[meetingId] ?? 0;
        examinedInput = inputVersion;
        if (_examinedVersions[meetingId] == inputVersion) return;
        final cursor = _queries.cursor(meetingId);
        if (cursor == null) return;
        final batch = _queries.finalSegmentsAfter(meetingId, cursor);
        final isFinal = _lastInputIsFinal[meetingId] ?? true;
        final history = [
          ...batch.map((row) => row.text),
          ...?_interim[meetingId]?.values,
        ].join('\n').trim();
        _examinedVersions[meetingId] = inputVersion;
        if (history.isEmpty) {
          if (queued != null) _pending.add(meetingId);
          return;
        }
        // The original hashes the complete window before preparing model input.
        // Finals still detect; only repeated interim input is suppressed.
        final seen = _windowSeen.putIfAbsent(
          meetingId,
          QuestionTextDeduplicator.new,
        );
        final uniqueWindow = seen.process(history, _nowMilliseconds());
        if (!isFinal && !uniqueWindow) {
          if (queued != null) _pending.add(meetingId);
          return;
        }
        final transcript = proactiveTranscriptWindow(history, isFinal: isFinal);
        if (transcript.isEmpty) {
          if (queued != null) _pending.add(meetingId);
          return;
        }
        // Failures remain retryable; only skipped or completed input is marked.
        _examinedVersions.remove(meetingId);
        _request =
            'proactive-detect-$meetingId-${DateTime.now().microsecondsSinceEpoch}';
        final questions = await detect(transcript, _request!);
        if (!_allowed) {
          _pending.add(meetingId);
          return;
        }
        final detectedQuestions = questions
            .map((question) => question.trim())
            .where(
              (question) => question.isNotEmpty && !question.startsWith('>>'),
            )
            .toSet()
            .toList();
        final dispatcher =
            (_dispatchers[meetingId] ?? MeetingQuestionDispatcher()).copy();
        final activeQuestions = Map<String, int>.of(
          _activeQuestions[meetingId] ?? {},
        );
        final detectedAt = _nowMilliseconds();
        _queries.detectionTransaction(() {
          for (final question in detectedQuestions) {
            final result = dispatcher.process(question, detectedAt);
            for (final key in result.expired) {
              activeQuestions.remove(key);
            }
            for (final key in result.superseded) {
              final previousId = activeQuestions.remove(key);
              if (previousId != null) {
                _queries.supersedeQueued(previousId);
              }
            }
            if (!result.accepted) continue;
            final inserted = _queries.insertDetected(
              meeting: meetingId,
              transcript: batch.isEmpty ? null : batch.last.id,
              question: question,
              normalized: result.normalized,
              created: detectedAt,
            );
            if (result.normalized.isNotEmpty) {
              activeQuestions[result.normalized] = inserted;
            }
          }
          // The original advances history only when detection finds queries.
          // Empty results must retain context for a later segment to complete
          // a question. The input version avoids polling that unchanged text.
          if (detectedQuestions.isNotEmpty && batch.isNotEmpty) {
            _queries.advanceCursor(meetingId, batch.last.id);
          }
        });
        _dispatchers[meetingId] = dispatcher;
        _activeQuestions[meetingId] = activeQuestions;
        _examinedVersions[meetingId] = inputVersion;
      }
      _pending.add(
        meetingId,
      ); // Drain further answers/segments fairly, one model job per tick.
    } catch (error) {
      if (!_allowed) {
        if (questionId != null) {
          if (_linkCommittedAnswer(questionId)) return;
          _queries.returnToQueue(questionId);
        }
        _pending.add(meetingId);
      } else {
        errors[meetingId] = error.toString();
        if (questionId == null && examinedInput != null) {
          // Explicit retry/new speech advances the version. A failed newer
          // detection must still let previously queued answers run.
          _examinedVersions[meetingId] = examinedInput;
          if (queuedWork) _pending.add(meetingId);
        }
        if (questionId != null) {
          _queries.failAnswer(questionId, error.toString());
        }
        if (questionId != null) _pending.add(meetingId);
      }
    } finally {
      _request = null;
      _activeMeeting = null;
    }
  }

  Future<void> reset() async {
    _suspended = true;
    _timer?.cancel();
    _timer = null;
    if (_request != null) cancel(_request!);
    await _inFlight;
    _pending.clear();
    _inputVersions.clear();
    _examinedVersions.clear();
    _interim.clear();
    _lastInputIsFinal.clear();
    _windowSeen.clear();
    _dispatchers.clear();
    _activeQuestions.clear();
    errors.clear();
    _suspended = false;
  }

  Future<void> close() async {
    _closed = true;
    _timer?.cancel();
    _timer = null;
    if (_request != null) cancel(_request!);
    await _inFlight;
  }
}
