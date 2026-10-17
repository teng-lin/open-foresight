import 'dart:async';
import 'store.dart';

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
  bool get enabled => store.preference('proactiveAnswers', 'true') == 'true';
  bool get running => _inFlight != null;
  bool ownsRequest(String request) => _allowed && _request == request;
  Map<String, Object?> get state => {
    'enabled': enabled,
    'running': running,
    'active_meeting': _activeMeeting,
    'pending_meetings': _pending.toList(),
    'errors': {for (final entry in errors.entries) '${entry.key}': entry.value},
  };

  /// Start at the existing history boundary on a meeting's first recording.
  /// An existing cursor retains unprocessed final segments across a restart.
  void begin(int meetingId) {
    store.db.execute(
      'INSERT OR IGNORE INTO meeting_question_cursors(meeting_id,transcript_id) '
      'VALUES(?,(SELECT COALESCE(MAX(id),0) FROM transcript WHERE meeting_id=?))',
      [meetingId, meetingId],
    );
  }

  void restore() {
    store.db.execute(
      "UPDATE meeting_questions SET state='queued' WHERE state='answering'",
    );
    for (final row in store.rows(
      "SELECT meeting_id FROM meeting_questions WHERE state='queued' UNION "
      'SELECT c.meeting_id FROM meeting_question_cursors c JOIN transcript t '
      'ON t.meeting_id=c.meeting_id WHERE t.final=1 AND t.id>c.transcript_id',
    )) {
      notify(row['meeting_id'] as int);
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
    final question = store.rows('SELECT * FROM meeting_questions WHERE id=?', [
      questionId,
    ]).firstOrNull;
    if (question == null) throw StateError('Question not found');
    if (![
      'failed',
      'insufficient_context',
      'cancelled',
    ].contains(question['state'])) {
      throw StateError('Question is not awaiting retry');
    }
    store.db.execute(
      "UPDATE meeting_questions SET state='queued',error='' WHERE id=?",
      [questionId],
    );
    notify(question['meeting_id'] as int);
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
    if (_examinedVersions[meetingId] == (_inputVersions[meetingId] ?? 0))
      return false;
    if (_interim[meetingId]?.isNotEmpty ?? false) return true;
    return store.rows(
      'SELECT 1 FROM transcript t JOIN meeting_question_cursors c '
      'ON c.meeting_id=t.meeting_id WHERE t.meeting_id=? AND t.final=1 '
      'AND t.id>c.transcript_id LIMIT 1',
      [meetingId],
    ).isNotEmpty;
  }

  bool get _allowed => !_closed && !_suspended && enabled;
  Future<void> _processOne() async {
    if (!_allowed || _pending.isEmpty || busy()) return;
    final meetingId = _pending.first;
    _activeMeeting = meetingId;
    _pending.remove(meetingId);
    int? questionId, examinedInput;
    var queuedWork = false;
    try {
      errors.remove(meetingId);
      final queued = store.rows(
        "SELECT * FROM meeting_questions WHERE meeting_id=? AND state='queued' ORDER BY id LIMIT 1",
        [meetingId],
      ).firstOrNull;
      queuedWork = queued != null;
      if (queued != null && !_hasUnexaminedInput(meetingId)) {
        questionId = queued['id'] as int;
        store.db.execute(
          "UPDATE meeting_questions SET state='answering',error='' WHERE id=?",
          [questionId],
        );
        changed();
        _request =
            'proactive-answer-$questionId-${DateTime.now().microsecondsSinceEpoch}';
        final answerId = await answer(
          meetingId,
          queued['question'] as String,
          _request!,
        );
        if (!_allowed) {
          store.db.execute(
            "UPDATE meeting_questions SET state='queued' WHERE id=?",
            [questionId],
          );
          _pending.add(meetingId);
          return;
        }
        final saved = store.rows('SELECT status FROM answers WHERE id=?', [
          answerId,
        ]).single;
        store.db.execute(
          'UPDATE meeting_questions SET state=?,answer_id=?,error=? WHERE id=?',
          [
            saved['status'],
            answerId,
            saved['status'] == 'failed'
                ? 'Answer generation failed. Try again.'
                : '',
            questionId,
          ],
        );
      } else {
        final inputVersion = _inputVersions[meetingId] ?? 0;
        examinedInput = inputVersion;
        if (_examinedVersions[meetingId] == inputVersion) return;
        final cursor = store.rows(
          'SELECT transcript_id FROM meeting_question_cursors WHERE meeting_id=?',
          [meetingId],
        ).firstOrNull;
        if (cursor == null) return;
        final batch = store.rows(
          'SELECT id,text FROM transcript WHERE meeting_id=? AND final=1 AND id>? ORDER BY id',
          [meetingId, cursor['transcript_id']],
        );
        final isFinal = _lastInputIsFinal[meetingId] ?? true;
        final history = [
          ...batch.map((row) => row['text'] as String),
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
        // The recovered splitter is \s+ and the join separator is a space.
        final units = RegExp(r'\S+').allMatches(history).toList();
        final eligible = units.length - (isFinal ? 0 : 5);
        if (eligible <= 0) {
          if (queued != null) _pending.add(meetingId);
          return;
        }
        final first = eligible > 200 ? eligible - 200 : 0;
        final transcript = units
            .sublist(first, eligible)
            .map((unit) => unit.group(0)!)
            .join(' ');
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
        store.db.execute('SAVEPOINT detect_meeting_questions');
        try {
          for (final question in detectedQuestions) {
            final result = dispatcher.process(question, detectedAt);
            for (final key in result.expired) {
              activeQuestions.remove(key);
            }
            for (final key in result.superseded) {
              final previousId = activeQuestions.remove(key);
              if (previousId != null) {
                store.db.execute(
                  "UPDATE meeting_questions SET state='superseded' WHERE id=? AND state='queued'",
                  [previousId],
                );
              }
            }
            if (!result.accepted) continue;
            store.db.execute(
              'INSERT INTO meeting_questions(meeting_id,transcript_id,question,normalized,created) VALUES(?,?,?,?,?)',
              [
                meetingId,
                batch.isEmpty ? null : batch.last['id'],
                question,
                result.normalized,
                detectedAt,
              ],
            );
            if (result.normalized.isNotEmpty) {
              activeQuestions[result.normalized] = store.db.lastInsertRowId;
            }
          }
          // The original advances history only when detection finds queries.
          // Empty results must retain context for a later segment to complete
          // a question. The input version avoids polling that unchanged text.
          if (detectedQuestions.isNotEmpty && batch.isNotEmpty) {
            store.db.execute(
              'UPDATE meeting_question_cursors SET transcript_id=? WHERE meeting_id=?',
              [batch.last['id'], meetingId],
            );
          }
          store.db.execute('RELEASE detect_meeting_questions');
          _dispatchers[meetingId] = dispatcher;
          _activeQuestions[meetingId] = activeQuestions;
          _examinedVersions[meetingId] = inputVersion;
        } catch (_) {
          store.db.execute('ROLLBACK TO detect_meeting_questions');
          store.db.execute('RELEASE detect_meeting_questions');
          rethrow;
        }
      }
      _pending.add(
        meetingId,
      ); // Drain further answers/segments fairly, one model job per tick.
    } catch (error) {
      if (!_allowed) {
        if (questionId != null)
          store.db.execute(
            "UPDATE meeting_questions SET state='queued' WHERE id=?",
            [questionId],
          );
        _pending.add(meetingId);
      } else {
        errors[meetingId] = error.toString();
        if (questionId == null && examinedInput != null) {
          // Explicit retry/new speech advances the version. A failed newer
          // detection must still let previously queued answers run.
          _examinedVersions[meetingId] = examinedInput;
          if (queuedWork) _pending.add(meetingId);
        }
        if (questionId != null)
          store.db.execute(
            "UPDATE meeting_questions SET state='failed',error=? WHERE id=?",
            [error.toString(), questionId],
          );
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
