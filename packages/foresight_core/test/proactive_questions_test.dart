import 'dart:async';
import 'dart:io';
import 'package:test/test.dart';
import 'package:foresight_core/foresight_core.dart';
import 'package:foresight_core/src/proactive_questions.dart';

void main() {
  late Directory directory;
  late Store store;
  late ProactiveQuestions queue;
  late int meeting;
  late List<String> detectedText, answered, cancelled;
  var busy = false, failDetection = false;
  String? failAnswer;
  List<String>? detectionResult;
  Completer<List<String>>? detectionGate;
  ProactiveQuestions create() => ProactiveQuestions(
    store: store,
    delay: const Duration(days: 1),
    changed: () {},
    busy: () => busy,
    cancel: (id) {
      cancelled.add(id);
    },
    detect: (text, _) async {
      detectedText.add(text);
      if (failDetection) throw StateError('Detection fixture failure');
      if (detectionGate != null) return detectionGate!.future;
      return detectionResult ??
          text
              .split('\n')
              .where((line) => line.contains(RegExp('[?？]')))
              .toList();
    },
    answer: (id, question, request) async {
      if (question == failAnswer) throw StateError('Answer fixture failure');
      answered.add(question);
      store.answer(
        question,
        'Grounded fixture answer',
        'completed',
        [],
        'fixture',
        conversation: 'meeting:$id',
        requestId: request,
      );
      final answerId = store.db.lastInsertRowId;
      store.db.execute('INSERT INTO meeting_answers VALUES(?,?)', [
        id,
        answerId,
      ]);
      return answerId;
    },
  );
  setUp(() {
    directory = Directory.systemTemp.createTempSync('proactive-');
    store = Store('${directory.path}/app.db');
    meeting = store.meeting('Fixture');
    detectedText = [];
    answered = [];
    cancelled = [];
    busy = false;
    failDetection = false;
    failAnswer = null;
    detectionResult = null;
    detectionGate = null;
    queue = create();
  });
  tearDown(() async {
    await queue.close();
    store.close();
    directory.deleteSync(recursive: true);
  });
  void append(String text, {bool finalText = true, int? id}) {
    store.transcript(id ?? meeting, text, finalText, 0, 1000, 'microphone');
    queue.notify(id ?? meeting);
  }

  Future<void> drain() async {
    for (
      var i = 0;
      i < 30 && (queue.state['pending_meetings'] as List).isNotEmpty;
      i++
    ) {
      await queue.process();
    }
    expect(queue.state['pending_meetings'], isEmpty);
  }

  test(
    'detects only new final speech, deduplicates multilingual questions and rejects invented ones',
    () async {
      store.transcript(
        meeting,
        'Historical question?',
        true,
        0,
        1000,
        'imported',
      );
      queue.begin(meeting);
      append('Provisional question?', finalText: false);
      append('What now?\n部署日期是什么？');
      detectionResult = [
        'What now?',
        'WHAT NOW？',
        '部署日期是什么？',
        'Invented question?',
      ];
      await drain();
      expect(detectedText, ['What now?\n部署日期是什么？']);
      expect(answered, ['What now?', '部署日期是什么？']);
      expect(
        store
            .rows('SELECT state FROM meeting_questions')
            .map((row) => row['state']),
        everyElement('completed'),
      );
      expect(
        store
            .rows('SELECT request_id FROM answers')
            .map((row) => row['request_id']),
        everyElement(startsWith('proactive-answer-')),
      );
      append('WHAT NOW？');
      detectionResult = ['WHAT NOW？'];
      await drain();
      expect(answered, hasLength(2));
      expect(store.rows('SELECT * FROM meeting_questions'), hasLength(2));
    },
  );

  test(
    'model busy and disabled settings retain work without invoking detection',
    () async {
      queue.begin(meeting);
      append('Who owns this?');
      busy = true;
      await queue.process();
      expect(detectedText, isEmpty);
      store.setPreference('proactiveAnswers', 'false');
      busy = false;
      queue.wake();
      await queue.process();
      expect(detectedText, isEmpty);
      store.setPreference('proactiveAnswers', 'true');
      queue.wake();
      await drain();
      expect(answered, ['Who owns this?']);
    },
  );

  test(
    'short Chinese questions remain eligible and migration preserves older answers',
    () async {
      store.answer(
        'Legacy question',
        'Legacy answer',
        'completed',
        [],
        'legacy',
      );
      await queue.close();
      store.db.execute(
        'DROP TABLE meeting_questions; DROP TABLE meeting_question_cursors; DROP INDEX answer_request_id; ALTER TABLE answers DROP COLUMN request_id;',
      );
      store.close();
      store = Store('${directory.path}/app.db');
      queue = create();
      expect(store.rows('SELECT body,request_id FROM answers').single, {
        'body': 'Legacy answer',
        'request_id': null,
      });
      queue.begin(meeting);
      append('谁？');
      await drain();
      expect(answered, ['谁？']);
    },
  );

  test(
    'detection failure preserves the cursor and allows explicit retry',
    () async {
      queue.begin(meeting);
      append('What is the date?');
      failDetection = true;
      await queue.process();
      expect(queue.errors[meeting], contains('Detection fixture failure'));
      expect(
        store
            .rows('SELECT transcript_id FROM meeting_question_cursors')
            .single['transcript_id'],
        0,
      );
      expect(store.rows('SELECT * FROM meeting_questions'), isEmpty);
      failDetection = false;
      queue.notify(meeting);
      await drain();
      expect(answered, ['What is the date?']);
      expect(queue.errors, isEmpty);
    },
  );

  test(
    'failed answers do not block subsequent questions and can be retried',
    () async {
      queue.begin(meeting);
      append('What failed?\nWhat next?');
      failAnswer = 'What failed?';
      await drain();
      expect(answered, ['What next?']);
      final failed = store
          .rows("SELECT * FROM meeting_questions WHERE state='failed'")
          .single;
      expect(failed['error'], contains('Answer fixture failure'));
      failAnswer = null;
      queue.retry(failed['id'] as int);
      await drain();
      expect(answered, ['What next?', 'What failed?']);
      expect(
        store.rows("SELECT * FROM meeting_questions WHERE state='failed'"),
        isEmpty,
      );
    },
  );

  test(
    'disabling in-flight detection cancels only its request and does not advance the cursor',
    () async {
      queue.begin(meeting);
      append('What now?');
      detectionGate = Completer<List<String>>();
      final work = queue.process();
      expect(queue.running, true);
      store.setPreference('proactiveAnswers', 'false');
      queue.wake();
      expect(cancelled.single, startsWith('proactive-detect-'));
      detectionGate!.complete(['What now?']);
      await work;
      expect(store.rows('SELECT * FROM meeting_questions'), isEmpty);
      expect(
        store
            .rows('SELECT transcript_id FROM meeting_question_cursors')
            .single['transcript_id'],
        0,
      );
      detectionGate = null;
      store.setPreference('proactiveAnswers', 'true');
      queue.wake();
      await drain();
      expect(answered, ['What now?']);
    },
  );

  test(
    'restart restores queued answers and unfinished transcript batches without duplicate answers',
    () async {
      queue.begin(meeting);
      for (var i = 0; i < 8; i++) append('Question $i?');
      await queue
          .process(); // One detection batch of six segments is committed.
      final first = store
          .rows('SELECT id FROM meeting_questions ORDER BY id LIMIT 1')
          .single['id'];
      store.db.execute(
        "UPDATE meeting_questions SET state='answering' WHERE id=?",
        [first],
      );
      await queue.close();
      store.close();
      store = Store('${directory.path}/app.db');
      queue = create();
      queue.restore();
      await drain();
      expect(answered, List.generate(8, (i) => 'Question $i?'));
      expect(store.rows('SELECT * FROM answers'), hasLength(8));
      queue.restore();
      await drain();
      expect(answered, hasLength(8));
    },
  );

  test(
    'reset waits for owned cancellation and clears work before workspace deletion',
    () async {
      queue.begin(meeting);
      append('What now?');
      detectionGate = Completer<List<String>>();
      final work = queue.process();
      final reset = queue.reset();
      expect(cancelled, hasLength(1));
      detectionGate!.completeError(StateError('Owned cancellation'));
      await work;
      await reset;
      expect(queue.state['pending_meetings'], isEmpty);
      expect(queue.errors, isEmpty);
      expect(store.rows('SELECT * FROM meeting_questions'), isEmpty);
    },
  );
}
