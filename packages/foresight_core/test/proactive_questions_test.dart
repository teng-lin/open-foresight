import 'package:foresight_test_support/test_paths.dart';
import 'dart:async';
import 'dart:io';
import 'package:test/test.dart';
import 'package:foresight_core/foresight_core.dart';
import 'package:foresight_core/src/proactive_questions.dart';
import 'package:foresight_core/src/reference_query_detector.dart';

void main() {
  late Directory directory;
  late Store store;
  late ProactiveQuestions queue;
  late int meeting;
  late List<String> detectedText, answered, cancelled;
  var busy = false, failDetection = false;
  var milliseconds = 0;
  String? failAnswer;
  ReferenceQueryDetector? referenceDetector;
  List<String>? detectionResult;
  Completer<List<String>>? detectionGate;
  ProactiveQuestions create() => ProactiveQuestions(
    store: store,
    nowMilliseconds: () => milliseconds,
    delay: const Duration(days: 1),
    changed: () {},
    busy: () => busy,
    cancel: (id) {
      cancelled.add(id);
    },
    detect: (text, request) async {
      detectedText.add(text);
      if (failDetection) throw StateError('Detection fixture failure');
      if (referenceDetector != null) {
        return referenceDetector!.detect(text, request);
      }
      if (detectionGate != null) return detectionGate!.future;
      return detectionResult ??
          RegExp(
            r'[^?？]+[?？]',
          ).allMatches(text).map((match) => match.group(0)!.trim()).toList();
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
    directory = createTestTempDirectorySync('proactive-');
    store = Store('${directory.path}/app.db');
    meeting = store.meeting('Fixture');
    detectedText = [];
    answered = [];
    cancelled = [];
    busy = false;
    milliseconds = 0;
    failDetection = false;
    failAnswer = null;
    referenceDetector = null;
    detectionResult = null;
    detectionGate = null;
    queue = create();
  });
  setUp(() {
    addTearDown(() async {
      await queue.close();
      store.close();
      directory.deleteSync(recursive: true);
    });
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
    'window normalization uses the recovered timestamp and punctuation rules',
    () {
      expect(
        normalizeTranscriptWindow('[12:34:56]  Who---owns (this)?'),
        'who owns this',
      );
      expect(normalizeTranscriptWindow('  A\n\tB!  '), 'a b');
      expect(normalizeTranscriptWindow('谁负责？'), '谁负责？');
      expect(normalizeTranscriptWindow('“Quoted”'), '“quoted”');
      expect(
        normalizeTranscriptWindow('middle [12:34:56] timestamp'),
        'middle [12 34 56] timestamp',
      );
    },
  );

  test(
    'accepts detector wording and deduplicates multilingual questions',
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
        'Inferred question?',
      ];
      await drain();
      expect(detectedText, ['What now? 部署日期是什么？']);
      expect(answered, ['What now?', '部署日期是什么？', 'Inferred question?']);
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
      expect(answered, hasLength(3));
      expect(store.rows('SELECT * FROM meeting_questions'), hasLength(3));
    },
  );

  test(
    'empty detection retains context without repeatedly invoking the model',
    () async {
      queue.begin(meeting);
      append('When can we');
      detectionResult = [];
      await drain();
      expect(detectedText, ['When can we']);
      expect(
        store
            .rows('SELECT transcript_id FROM meeting_question_cursors')
            .single['transcript_id'],
        0,
      );
      await queue.process();
      queue.wake();
      await queue.process();
      expect(detectedText, hasLength(1));

      append('ship?');
      detectionResult = ['When can we ship?'];
      await drain();
      expect(detectedText.last, 'When can we ship?');
      expect(answered, ['When can we ship?']);
      expect(
        store
            .rows('SELECT transcript_id FROM meeting_question_cursors')
            .single['transcript_id'],
        store.rows('SELECT MAX(id) AS id FROM transcript').single['id'],
      );
    },
  );

  test(
    'detection sees a growing window across more than six segments',
    () async {
      queue.begin(meeting);
      for (final word in [
        'When',
        'will',
        'the',
        'team',
        'be',
        'ready',
        'to',
        'ship?',
      ]) {
        append(word);
      }
      detectionResult = ['When will the team be ready to ship?'];
      await drain();
      expect(detectedText.single, 'When will the team be ready to ship?');
      expect(answered, ['When will the team be ready to ship?']);
    },
  );

  test(
    'detection bounds the growing window to its last 1000 Unicode scalars',
    () async {
      queue.begin(meeting);
      append(List.generate(220, (i) => 'word$i').join(' '));
      detectionResult = [];
      await drain();
      expect(
        detectedText.single,
        String.fromCharCodes(
          List.generate(
            220,
            (i) => 'word$i',
          ).join(' ').runes.toList().reversed.take(1000).toList().reversed,
        ),
      );
      // Capping model input does not consume undetected history.
      expect(
        store
            .rows('SELECT transcript_id FROM meeting_question_cursors')
            .single['transcript_id'],
        0,
      );
    },
  );

  test(
    'new speech arriving during empty detection is processed next',
    () async {
      queue.begin(meeting);
      append('When can we');
      detectionGate = Completer<List<String>>();
      final work = queue.process();
      append('ship?');
      detectionGate!.complete([]);
      await work;
      detectionGate = null;
      detectionResult = ['When can we ship?'];
      await drain();
      expect(detectedText, ['When can we', 'When can we ship?']);
      expect(answered, ['When can we ship?']);
    },
  );

  test(
    'restart retains undetected history for the next transcript segment',
    () async {
      queue.begin(meeting);
      append('When can we');
      detectionResult = [];
      await drain();
      await queue.close();
      store.close();
      store = Store('${directory.path}/app.db');
      queue = create();
      queue.restore();
      append('ship?');
      detectionResult = ['When can we ship?'];
      await drain();
      expect(detectedText.last, 'When can we ship?');
      expect(answered, ['When can we ship?']);
    },
  );

  test(
    'interim-only questions exclude the changing five-unit tail and have no false origin',
    () async {
      queue.begin(meeting);
      queue.updateInterim(
        meeting,
        'microphone',
        'Who owns this? one two three four five',
      );
      await drain();
      expect(detectedText, ['Who owns this?']);
      expect(answered, ['Who owns this?']);
      expect(
        store
            .rows('SELECT transcript_id FROM meeting_questions')
            .single['transcript_id'],
        isNull,
      );
      expect(store.rows('SELECT * FROM transcript'), isEmpty);
      expect(
        store
            .rows('SELECT transcript_id FROM meeting_question_cursors')
            .single['transcript_id'],
        0,
      );
    },
  );

  test('interim input of at most five units waits for more speech', () async {
    queue.begin(meeting);
    queue.updateInterim(meeting, 'microphone', 'Who owns this? one two');
    await drain();
    expect(detectedText, isEmpty);
    queue.updateInterim(
      meeting,
      'microphone',
      'Who owns this? one two three four five',
    );
    await drain();
    expect(detectedText, ['Who owns this?']);
  });

  test(
    'interim windows join retained final history and independent channels',
    () async {
      queue.begin(meeting);
      append('When can we');
      detectionResult = [];
      await drain();
      queue.updateInterim(meeting, 'microphone', 'ship?');
      queue.updateInterim(meeting, 'playback', 'one two three four five');
      detectionResult = ['When can we ship?'];
      await drain();
      expect(detectedText.last, 'When can we ship?');
      expect(answered, ['When can we ship?']);
      expect(
        store
            .rows('SELECT transcript_id FROM meeting_questions')
            .single['transcript_id'],
        store.rows('SELECT id FROM transcript').single['id'],
      );
    },
  );

  test('interim tail exclusion occurs before the scalar budget', () async {
    queue.begin(meeting);
    queue.updateInterim(
      meeting,
      'microphone',
      List.generate(220, (i) => 'word$i').join(' '),
    );
    detectionResult = [];
    await drain();
    expect(
      detectedText.single,
      String.fromCharCodes(
        List.generate(
          215,
          (i) => 'word$i',
        ).join(' ').runes.toList().reversed.take(1000).toList().reversed,
      ),
    );
  });

  test(
    'duplicate interim windows refresh suppression and permit exactly five seconds',
    () async {
      queue.begin(meeting);
      const text = 'Who owns this? one two three four five';
      detectionResult = [];
      queue.updateInterim(meeting, 'microphone', text);
      await drain();
      expect(detectedText, hasLength(1));
      milliseconds = 4999;
      queue.updateInterim(meeting, 'microphone', text);
      await drain();
      expect(detectedText, hasLength(1));
      milliseconds = 5000;
      queue.updateInterim(meeting, 'microphone', text.toUpperCase());
      await drain();
      expect(detectedText, hasLength(1));
      milliseconds = 10000;
      queue.updateInterim(meeting, 'microphone', text);
      await drain();
      expect(detectedText, hasLength(2));
    },
  );

  test(
    'final input bypasses window dedup and does not reuse its interim hypothesis',
    () async {
      queue.begin(meeting);
      const text = 'Who owns this? one two three four five';
      detectionResult = [];
      queue.updateInterim(meeting, 'microphone', text);
      await drain();
      queue.clearInterim(meeting, 'microphone');
      append(text);
      await drain();
      expect(detectedText, ['Who owns this?', text]);
      queue.notify(meeting);
      await drain();
      expect(detectedText, ['Who owns this?', text, text]);
    },
  );

  test(
    'clearing and resetting interim input prevents stale speech in later windows',
    () async {
      queue.begin(meeting);
      queue.updateInterim(
        meeting,
        'microphone',
        'Stale question? one two three four five',
      );
      queue.clearInterim(meeting);
      await drain();
      expect(detectedText, isEmpty);
      queue.updateInterim(
        meeting,
        'microphone',
        'Also stale? one two three four five',
      );
      await queue.reset();
      append('Fresh question?');
      await drain();
      expect(detectedText, ['Fresh question?']);
    },
  );

  for (final requiredOrigin in [true, false]) {
    test(
      'legacy origin=$requiredOrigin migration preserves jobs, IDs, and answer links',
      () async {
        store.transcript(
          meeting,
          'Existing question?',
          true,
          0,
          1000,
          'microphone',
        );
        final transcriptId = store.db.lastInsertRowId;
        store.answer(
          'Existing question?',
          'Existing answer',
          'completed',
          [],
          'fixture',
        );
        final answerId = store.db.lastInsertRowId;
        store.db.execute('DROP TABLE meeting_questions');
        store.db.execute("""
      CREATE TABLE meeting_questions(
        id INTEGER PRIMARY KEY,
        meeting_id INTEGER NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
        transcript_id INTEGER ${requiredOrigin ? 'NOT NULL' : ''} REFERENCES transcript(id) ON DELETE CASCADE,
        question TEXT NOT NULL,normalized TEXT NOT NULL,state TEXT NOT NULL DEFAULT 'queued',
        answer_id INTEGER REFERENCES answers(id) ON DELETE SET NULL,
        error TEXT NOT NULL DEFAULT '',created INTEGER NOT NULL,UNIQUE(meeting_id,normalized));
    """);
        store.db.execute(
          'INSERT INTO meeting_questions VALUES(?,?,?,?,?,?,?,?,?)',
          [
            77,
            meeting,
            transcriptId,
            'Existing question?',
            'existing question',
            'completed',
            answerId,
            '',
            123,
          ],
        );
        store.db.execute('PRAGMA user_version=6');
        final before = store.rows('SELECT * FROM meeting_questions').single;
        await queue.close();
        store.close();
        store = Store('${directory.path}/app.db');
        queue = create();
        expect(store.rows('SELECT * FROM meeting_questions').single, before);
        expect(store.rows('PRAGMA foreign_key_check'), isEmpty);
        queue.begin(meeting);
        queue.updateInterim(
          meeting,
          'microphone',
          'New question? one two three four five',
        );
        await drain();
        expect(
          store
              .rows('SELECT transcript_id FROM meeting_questions ORDER BY id')
              .last['transcript_id'],
          isNull,
        );
        expect(
          store.rows('SELECT body FROM answers ORDER BY id').first['body'],
          'Existing answer',
        );
        // The removed lifetime constraint permits a fresh identical job after
        // the dispatcher's twenty-second state expires.
        milliseconds = 20000;
        queue.updateInterim(
          meeting,
          'microphone',
          'New question? one two three four five',
        );
        await drain();
        expect(store.rows('SELECT * FROM meeting_questions'), hasLength(3));
        // Reopening the migrated schema is idempotent.
        await queue.close();
        store.close();
        store = Store('${directory.path}/app.db');
        queue = create();
        expect(store.rows('SELECT * FROM meeting_questions'), hasLength(3));
        expect(store.rows('PRAGMA foreign_key_check'), isEmpty);
      },
    );
  }

  test(
    'a repeated question can produce a new answer after twenty-second expiry',
    () async {
      queue.begin(meeting);
      append('When is launch?');
      await drain();
      milliseconds = 4999;
      append('When is launch?');
      await drain();
      expect(answered, ['When is launch?']);
      milliseconds = 20000;
      append('When is launch?');
      await drain();
      expect(answered, ['When is launch?', 'When is launch?']);
      expect(store.rows('SELECT * FROM meeting_questions'), hasLength(2));
    },
  );

  test(
    'new input expands a queued question before starting its answer',
    () async {
      queue.begin(meeting);
      append('Who?');
      await queue.process();
      append('Who owns the draft?');
      await drain();
      expect(answered, ['Who owns the draft?']);
      expect(store.rows('SELECT question,state FROM meeting_questions'), [
        {'question': 'Who?', 'state': 'superseded'},
        {'question': 'Who owns the draft?', 'state': 'completed'},
      ]);
    },
  );

  test(
    'a shorter revision is suppressed while the existing longer question answers',
    () async {
      queue.begin(meeting);
      append('Who owns the draft?');
      await queue.process();
      detectionResult = ['Who owns?'];
      append('Who owns?');
      await drain();
      expect(answered, ['Who owns the draft?']);
      expect(store.rows('SELECT * FROM meeting_questions'), hasLength(1));
    },
  );

  test('short interim input does not strand already queued answers', () async {
    queue.begin(meeting);
    append('Who owns the draft?');
    await queue.process();
    queue.updateInterim(meeting, 'microphone', 'short');
    await drain();
    expect(answered, ['Who owns the draft?']);
  });

  test(
    'failed newer detection does not strand previously queued answers',
    () async {
      queue.begin(meeting);
      append('Who owns the draft?');
      await queue.process();
      failDetection = true;
      append('What is the deadline?');
      await drain();
      expect(answered, ['Who owns the draft?']);
      failDetection = false;
      queue.notify(meeting);
      await drain();
      expect(answered, ['Who owns the draft?', 'What is the deadline?']);
    },
  );

  test(
    'replacements preserve completed answers and exact meeting ownership',
    () async {
      queue.begin(meeting);
      append('Who?');
      await drain();
      append('Who owns the draft?');
      await drain();
      expect(answered, ['Who?', 'Who owns the draft?']);
      expect(
        store
            .rows('SELECT state FROM meeting_questions')
            .map((r) => r['state']),
        everyElement('completed'),
      );
      expect(store.rows('SELECT * FROM answers'), hasLength(2));
      expect(
        store
            .rows('SELECT meeting_id FROM meeting_answers')
            .map((r) => r['meeting_id']),
        everyElement(meeting),
      );
    },
  );

  test(
    'failed SQL dispatch rolls back jobs, replacements, and rolling eligibility',
    () async {
      queue.begin(meeting);
      append('Who?');
      await queue.process();
      store.db.execute(
        """CREATE TRIGGER reject_expansion BEFORE INSERT ON meeting_questions
      WHEN NEW.question='Who owns the draft?' BEGIN SELECT RAISE(ABORT,'fixture rejection'); END;""",
      );
      append('Who owns the draft?');
      detectionResult = ['Who owns the draft?'];
      await queue.process();
      expect(queue.errors[meeting], contains('fixture rejection'));
      expect(store.rows('SELECT question,state FROM meeting_questions'), [
        {'question': 'Who?', 'state': 'queued'},
      ]);
      store.db.execute('DROP TRIGGER reject_expansion');
      queue.notify(meeting);
      await drain();
      expect(answered, ['Who owns the draft?']);
      expect(store.rows('PRAGMA foreign_key_check'), isEmpty);
    },
  );

  test(
    'rolling question suppression is scoped to each meeting and reset clears it',
    () async {
      queue.begin(meeting);
      append('Who owns the draft?');
      await drain();
      final other = store.meeting('Other meeting');
      queue.begin(other);
      append('Who owns the draft?', id: other);
      await drain();
      expect(answered, hasLength(2));
      await queue.reset();
      append('Who owns the draft?');
      await drain();
      expect(answered, hasLength(3));
    },
  );

  test(
    'blank and excluded detector output retains history without dispatch',
    () async {
      queue.begin(meeting);
      append('We need to decide');
      detectionResult = ['', '   ', ' >> no questions'];
      await drain();
      expect(store.rows('SELECT * FROM meeting_questions'), isEmpty);
      expect(
        store
            .rows('SELECT transcript_id FROM meeting_question_cursors')
            .single['transcript_id'],
        0,
      );
      append('when can we ship?');
      detectionResult = ['When can we ship?', 'When can we ship?'];
      await drain();
      expect(detectedText.last, 'We need to decide when can we ship?');
      expect(answered, ['When can we ship?']);
    },
  );

  test(
    'reference completion protocol dispatches reversed questions without changing transcript',
    () async {
      queue.begin(meeting);
      referenceDetector = ReferenceQueryDetector((prompt, request) async {
        expect(prompt, ' <ctrl1>Who owns the draft? 谁负责测试？ When is launch?');
        expect(request, startsWith('proactive-detect-'));
        return 'Who owns the draft? 谁负责测试？ When is launch? >> no more questions';
      });
      append('Who owns the draft? 谁负责测试？ When is launch?');
      await drain();
      expect(answered, ['When is launch?', 'Who owns the draft?']);
      expect(
        store.rows('SELECT text FROM transcript').single['text'],
        'Who owns the draft? 谁负责测试？ When is launch?',
      );
      expect(store.rows('SELECT * FROM meeting_answers'), hasLength(2));
      expect(queue.errors, isEmpty);
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
        'DROP TABLE meeting_questions; DROP TABLE meeting_question_cursors; DROP INDEX answer_request_id; ALTER TABLE answers DROP COLUMN request_id; PRAGMA user_version=1;',
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

  test('restart restores queued answers without duplicate answers', () async {
    queue.begin(meeting);
    const distinctQuestions = [
      'Who approved budget?',
      'When is launch?',
      'Where are we meeting?',
      'How should data be archived?',
      'Which supplier ships equipment?',
      'Does access expire tomorrow?',
      'Can volunteers bring bicycles?',
      'Why were receipts rejected?',
    ];
    for (final question in distinctQuestions) {
      append(question);
    }
    await queue.process(); // Detection commits durable jobs for the window.
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
    expect(answered, distinctQuestions);
    expect(store.rows('SELECT * FROM answers'), hasLength(8));
    queue.restore();
    await drain();
    expect(answered, hasLength(8));
  });

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
