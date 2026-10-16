import 'dart:async';
import 'store.dart';

String normalizeMeetingQuestion(String text) => text
    .toLowerCase()
    .replaceAll(RegExp(r'''[\s?？.!。！,，:：;；"“”'‘’]+'''), ' ')
    .trim();

/// One service-owned pipeline: final transcript -> local detection -> durable
/// deduplication -> grounded answer. Capture never waits for model work.
class ProactiveQuestions {
  ProactiveQuestions({
    required this.store,
    required this.detect,
    required this.answer,
    required this.busy,
    required this.cancel,
    required this.changed,
    this.delay = const Duration(seconds: 1),
  });
  final Store store;
  final Future<List<String>> Function(String text, String requestId) detect;
  final Future<int> Function(int meetingId, String question, String requestId)
  answer;
  final bool Function() busy;
  final void Function(String requestId) cancel;
  final void Function() changed;
  final Duration delay;
  final _pending = <int>{};
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
      _pending.add(row['meeting_id'] as int);
    }
    wake();
  }

  void notify(int meetingId) {
    if (_closed) return;
    _pending.add(meetingId);
    wake();
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

  bool get _allowed => !_closed && !_suspended && enabled;
  Future<void> _processOne() async {
    if (!_allowed || _pending.isEmpty || busy()) return;
    final meetingId = _pending.first;
    _activeMeeting = meetingId;
    _pending.remove(meetingId);
    int? questionId;
    try {
      errors.remove(meetingId);
      final queued = store.rows(
        "SELECT * FROM meeting_questions WHERE meeting_id=? AND state='queued' ORDER BY id LIMIT 1",
        [meetingId],
      ).firstOrNull;
      if (queued != null) {
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
        final cursor = store.rows(
          'SELECT transcript_id FROM meeting_question_cursors WHERE meeting_id=?',
          [meetingId],
        ).firstOrNull;
        if (cursor == null) return;
        final batch = store.rows(
          'SELECT id,text FROM transcript WHERE meeting_id=? AND final=1 AND id>? ORDER BY id LIMIT 6',
          [meetingId, cursor['transcript_id']],
        );
        if (batch.isEmpty) return;
        final transcript = batch.map((row) => row['text']).join('\n');
        _request =
            'proactive-detect-$meetingId-${DateTime.now().microsecondsSinceEpoch}';
        final questions = await detect(transcript, _request!);
        if (!_allowed) {
          _pending.add(meetingId);
          return;
        }
        if (questions.length > 32)
          throw const FormatException('Too many detected questions');
        store.db.execute('SAVEPOINT detect_meeting_questions');
        try {
          for (final question in questions) {
            final normalized = normalizeMeetingQuestion(question);
            // The model selects transcript wording; it cannot introduce a new
            // question or execute instructions embedded in recorded speech.
            if (normalized.isEmpty ||
                question.length > 1000 ||
                !normalizeMeetingQuestion(transcript).contains(normalized))
              continue;
            store.db.execute(
              'INSERT OR IGNORE INTO meeting_questions(meeting_id,transcript_id,question,normalized,created) VALUES(?,?,?,?,?)',
              [
                meetingId,
                batch.last['id'],
                question.trim(),
                normalized,
                DateTime.now().millisecondsSinceEpoch,
              ],
            );
          }
          store.db.execute(
            'UPDATE meeting_question_cursors SET transcript_id=? WHERE meeting_id=?',
            [batch.last['id'], meetingId],
          );
          store.db.execute('RELEASE detect_meeting_questions');
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
