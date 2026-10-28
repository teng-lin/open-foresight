import 'sql_support_test_bootstrap.dart';
import 'dart:async';
import 'dart:io';

import 'package:foresight_core/src/application_services/recording_transcript_persistence.dart';
import 'package:foresight_core/src/meeting_attribution.dart';
import 'package:foresight_core/src/meeting_speakers.dart';
import 'package:foresight_core/src/meeting_workflow_store.dart';
import 'package:foresight_core/src/persistence/application_queries.dart';
import 'package:foresight_core/src/persistence/meeting_index_jobs.dart';
import 'package:foresight_core/src/persistence/meeting_operations_queries.dart';
import 'package:foresight_core/src/persistence/meeting_transcript_projection.dart';
import 'package:foresight_core/src/persistence/schema_migrations.dart';
import 'package:foresight_core/src/persistence/sqlite_runtime.dart';
import 'package:foresight_core/src/rpc_error.dart';
import 'package:foresight_core/src/store.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';

MeetingParticipant participant(
  String key,
  String name, {
  String scope = 'session-1/window-1',
  bool self = false,
  int first = 0,
  int last = 100,
}) => MeetingParticipant(
  scope: scope,
  identityKey: key,
  displayName: name,
  isSelf: self,
  firstSeenMs: first,
  lastSeenMs: last,
);

TranscriptAttribution automatic(
  int? participantId,
  String name, {
  String parser = 'parser-1',
  Map<String, Object?> evidence = const {'covered_ms': 900},
}) => TranscriptAttribution(
  participantId: participantId,
  displayName: name,
  state: AttributionState.attributed,
  method: AttributionMethod.participantStatus,
  parserVersion: parser,
  policyVersion: 'policy-1',
  evidence: evidence,
);

void main() {
  bootstrapSqlSupportFixture();
  late Directory root;
  late String path;
  late Store store;
  late int meeting;

  void open() => store = Store(path);
  int rowsOf(String sql, [List<Object?> args = const []]) =>
      store.rows(sql, args).length;
  int revision() =>
      store.rows('SELECT revision FROM meetings WHERE id=?', [
            meeting,
          ]).single['revision']
          as int;
  int finalRow(String text, {String source = 'playback', bool final_ = true}) {
    store.transcript(meeting, text, final_, 10, 20, source);
    return store.db.lastInsertRowId;
  }

  String sourceBody() =>
      store.rows('SELECT content FROM source_contents WHERE id=?', [
            'meeting-$meeting',
          ]).single['content']
          as String;

  void mapSource() {
    MeetingTranscriptProjection(
      store,
    ).ensureSource(meeting, store.workspaceEpoch);
  }

  setUp(() {
    root = createTestTempDirectorySync('meeting-attribution-');
    path = '${root.path}/application.db';
    open();
    addTearDown(() {
      store.close();
      root.deleteSync(recursive: true);
    });
    meeting = store.meeting('Zoom call');
  });

  group('models', () {
    test(
      'rendered names are one-line and cannot forge a transcript prefix',
      () {
        expect(renderedAttributionName('  Ada   Lovelace '), 'Ada Lovelace');
        expect(
          renderedAttributionName('Eve]\n[Microphone 0–1 ms] injected'),
          'Eve) (Microphone 0–1 ms) injected',
        );
        expect(renderedAttributionName('​  '), '');
        expect(renderedAttributionName('Wu, Li (QA)'), 'Wu, Li (QA)');
        expect(
          renderedAttributionName('x' * 400).length,
          maxRenderedNameLength,
        );
      },
    );

    test(
      'attribution validates names, versions, manual shape and evidence',
      () {
        expect(
          () => TranscriptAttribution(state: AttributionState.attributed),
          throwsArgumentError,
        );
        expect(
          () => TranscriptAttribution(
            state: AttributionState.attributed,
            displayName: '\n',
          ),
          throwsArgumentError,
        );
        expect(
          () => TranscriptAttribution(
            state: AttributionState.unknown,
            method: 'm' * 65,
          ),
          throwsArgumentError,
        );
        expect(
          () => TranscriptAttribution(
            state: AttributionState.unknown,
            evidence: {'blob': 'x' * 3000},
          ),
          throwsArgumentError,
        );
        expect(
          () => TranscriptAttribution(
            state: AttributionState.unknown,
            manual: true,
            method: 'participant_status',
          ),
          throwsArgumentError,
        );
        expect(() => AttributionState.parse('bogus'), throwsFormatException);
      },
    );

    test('values round-trip through plain JSON', () {
      final attribution = automatic(
        7,
        'Ada',
        evidence: {
          'a': 1,
          'b': [2],
        },
      );
      final copy = TranscriptAttribution.fromJson(attribution.toJson());
      expect(copy.sameContent(attribution), isTrue);
      expect(copy.renderedName, 'Ada');
      expect(TranscriptAttribution.manualUnnamed().renderedName, isEmpty);
      final person = participant('k', 'Ada', self: true);
      final decoded = MeetingParticipant.fromJson(person.toJson());
      expect(decoded.toJson(), person.toJson());
      expect(() => participant('k', ''), throwsArgumentError);
      expect(
        () => MeetingParticipant(
          scope: 's',
          identityKey: 'k',
          displayName: 'n',
          firstSeenMs: 5,
          lastSeenMs: 4,
        ),
        throwsArgumentError,
      );
    });
  });

  group('migration', () {
    Database v24(String target) {
      final db = openApplicationDatabase(target);
      db.execute(
        File(
          'test/fixtures/persistence-c28a1561/schema15.sql',
        ).readAsStringSync(),
      );
      for (var version = 16; version <= 19; version++) {
        ApplicationMigrations(db).run(version);
      }
      db.execute("INSERT INTO meetings(id,title,state) VALUES(1,'Old','idle')");
      db.execute(
        "INSERT INTO transcript(meeting_id,text,final,start_ms,end_ms,source) VALUES(1,'legacy words',1,10,20,'playback; captured-sample timeline')",
      );
      db.execute(
        "INSERT INTO sources(id,title,content,mime,revision,state,provenance) VALUES('meeting-1','Meeting 1 transcript','','text/plain',1,'indexed','meeting:1')",
      );
      for (var version = 20; version <= 24; version++) {
        ApplicationMigrations(db).run(version);
      }
      db.execute('PRAGMA user_version=24');
      return db;
    }

    test('upgrade keeps historical meetings unattributed and channel-only', () {
      final target =
          '${createTestTempDirectorySync('attr-old-').path}/application.db';
      v24(target).dispose();
      final upgraded = Store(target);
      addTearDown(upgraded.close);
      expect(
        upgraded.rows('PRAGMA user_version').single.values.single,
        Store.schemaVersion,
      );
      expect(Store.schemaVersion, 25);
      expect(upgraded.rows('SELECT * FROM transcript_attributions'), isEmpty);
      expect(upgraded.rows('SELECT * FROM meeting_participants'), isEmpty);
      final row = upgraded.meetingQueries.transcript(1).single;
      expect(row.participantId, isNull);
      expect(row.attributionState, isNull);
      expect(row.participantName, isNull);
      expect(row.channel, MeetingSpeaker.remote);
      expect(row.source, 'playback; captured-sample timeline');
      expect(
        upgraded
            .rows("SELECT content FROM source_contents WHERE id='meeting-1'")
            .single['content'],
        '[Remote 10–20 ms] legacy words',
      );
      expect(upgraded.rows('PRAGMA foreign_key_check'), isEmpty);
    });

    test('interrupted upgrade rolls back every table, trigger and view', () {
      final target =
          '${createTestTempDirectorySync('attr-int-').path}/application.db';
      final db = v24(target);
      // The second CREATE TABLE collides after the first has already run.
      db.execute('CREATE TABLE transcript_attributions(x)');
      db.dispose();
      expect(() => Store(target), throwsA(isA<SqliteException>()));
      final check = sqlite3.open(target);
      try {
        expect(check.select('PRAGMA user_version').single.values.single, 24);
        expect(
          check.select(
            "SELECT name FROM sqlite_master WHERE name IN ('meeting_participants','transcript_attribution_insert_text')",
          ),
          isEmpty,
        );
        expect(
          check
                  .select(
                    "SELECT sql FROM sqlite_master WHERE name='source_contents'",
                  )
                  .single['sql']
              as String,
          isNot(contains('transcript_attributions')),
        );
        check.execute('DROP TABLE transcript_attributions');
      } finally {
        check.dispose();
      }
      final retried = Store(target);
      addTearDown(retried.close);
      expect(
        retried.rows('PRAGMA user_version').single.values.single,
        Store.schemaVersion,
      );
      expect(retried.meetingQueries.transcript(1).single.text, 'legacy words');
    });

    test('the pre-upgrade snapshot restores an attribution-free profile', () {
      final target =
          '${createTestTempDirectorySync('attr-bak-').path}/application.db';
      v24(target).dispose();
      final upgraded = Store(target);
      final meetingId = 1;
      final id = upgraded.rows('SELECT id FROM transcript').single['id'] as int;
      upgraded.setManualAttribution(
        id,
        TranscriptAttribution.manual(displayName: 'Ada'),
      );
      final snapshot = upgraded.migrationBackups
          .snapshots(supportedVersion: Store.schemaVersion)
          .single;
      expect(snapshot.schema, 24);
      final restored = upgraded.migrationBackups.restoreCopy(
        snapshot.name,
        supportedVersion: 24,
        confirmDataLoss: true,
      );
      upgraded.close();
      final reader = openApplicationDatabase(restored, mode: OpenMode.readOnly);
      try {
        expect(reader.select('PRAGMA user_version').single.values.single, 24);
        expect(
          reader.select(
            "SELECT 1 FROM sqlite_master WHERE name='transcript_attributions'",
          ),
          isEmpty,
        );
        expect(
          reader.select('SELECT text FROM transcript WHERE meeting_id=?', [
            meetingId,
          ]).single['text'],
          'legacy words',
        );
      } finally {
        reader.dispose();
      }
      // A restored snapshot upgrades again, losing only post-snapshot edits.
      final again = Store(restored);
      addTearDown(again.close);
      expect(again.rows('SELECT * FROM transcript_attributions'), isEmpty);
      expect(
        again.rows('PRAGMA user_version').single.values.single,
        Store.schemaVersion,
      );
    });
  });

  group('transactional writes', () {
    test('text and attribution commit together and survive restart', () {
      final ada = store.saveMeetingParticipants(meeting, [
        participant('ax:1', 'Ada'),
      ]).single;
      final before = revision();
      final write = store.transcriptWithAttribution(
        meeting,
        'hello there',
        true,
        10,
        20,
        'playback',
        attribution: automatic(ada.id, 'Ada'),
      );
      expect(write.attributionSaved, isTrue);
      expect(write.attributionError, isNull);
      expect(revision(), greaterThan(before));
      store.close();
      open();
      final segment = store.meetingQueries.transcript(meeting).single;
      expect(segment.id, write.transcriptId);
      expect(segment.text, 'hello there');
      expect(segment.source, 'playback');
      expect(segment.channel, MeetingSpeaker.remote);
      expect(segment.participantId, ada.id);
      expect(segment.participantName, 'Ada');
      expect(segment.attributionState, 'attributed');
      expect(segment.attributionMethod, AttributionMethod.participantStatus);
      expect(segment.attributionManual, isFalse);
      final stored = store.meetingQueries.attribution(write.transcriptId)!;
      expect(stored.parserVersion, 'parser-1');
      expect(stored.policyVersion, 'policy-1');
      expect(stored.evidence, {'covered_ms': 900});
      expect(stored.revision, 1);
      expect(store.meetingQueries.participants(meeting).single.id, ada.id);
      expect(
        MeetingOperationsQueries(
          store,
        ).transcript(meeting).single.participantName,
        'Ada',
      );
    });

    test(
      'a row without attribution keeps legacy output and plain writes work',
      () {
        final plain = finalRow('plain');
        final segment = store.meetingQueries.transcript(meeting).single;
        expect(segment.id, plain);
        expect(segment.participantId, isNull);
        expect(segment.attributionState, isNull);
        expect(segment.participantName, isNull);
        final write = store.transcriptWithAttribution(
          meeting,
          'no names',
          true,
          1,
          2,
          'microphone',
        );
        expect(write.attributionSaved, isFalse);
        expect(write.attributionError, isNull);
        expect(rowsOf('SELECT * FROM transcript_attributions'), 0);
      },
    );

    test('attribution rejection never blocks the recognized text', () {
      final other = store.meeting('Other call');
      final foreign = store.saveMeetingParticipants(other, [
        participant('ax:9', 'Mallory'),
      ]).single;
      final before = revision();
      final crossMeeting = store.transcriptWithAttribution(
        meeting,
        'kept text',
        true,
        1,
        2,
        'playback',
        attribution: automatic(foreign.id, 'Mallory'),
      );
      final missing = store.transcriptWithAttribution(
        meeting,
        'kept again',
        true,
        3,
        4,
        'playback',
        attribution: automatic(999999, 'Nobody'),
      );
      for (final write in [crossMeeting, missing]) {
        expect(write.attributionSaved, isFalse);
        expect(write.attributionError, isA<SqliteException>());
      }
      expect(store.meetingQueries.finalTranscriptText(meeting), [
        'kept text',
        'kept again',
      ]);
      expect(rowsOf('SELECT * FROM transcript_attributions'), 0);
      // Only the two text commits bumped the revision.
      expect(revision(), before + 2);
      expect(store.rows('PRAGMA foreign_key_check'), isEmpty);
    });

    test('an interrupted write rolls back text, revision and attribution', () {
      final before = revision();
      expect(
        () => store.workflowTransaction(() {
          store.transcriptWithAttribution(
            meeting,
            'lost',
            true,
            1,
            2,
            'playback',
            attribution: automatic(null, 'Ada'),
          );
          throw StateError('commit interrupted');
        }),
        throwsStateError,
      );
      expect(rowsOf('SELECT * FROM transcript'), 0);
      expect(rowsOf('SELECT * FROM transcript_attributions'), 0);
      expect(revision(), before);
      expect(
        rowsOf('SELECT * FROM meeting_transcript_changes WHERE meeting_id=?', [
          meeting,
        ]),
        0,
      );
    });

    test('bounded retry stores one row and one attribution per segment', () {
      final timers = <void Function()>[];
      var committed = 0;
      final persistence = RecordingTranscriptPersistence(
        store: store,
        meeting: meeting,
        createTimer: (_, callback) {
          timers.add(callback);
          return Timer.periodic(const Duration(days: 1), (_) {});
        },
        committed: (_) => committed++,
        retrying: () {},
        exhausted: () => fail('retry budget must not be exhausted'),
      );
      addTearDown(persistence.dispose);
      store.db.execute(
        "INSERT INTO preferences(key,value) VALUES('test.fail','1')",
      );
      store.db.execute(
        "CREATE TRIGGER fail_transcript BEFORE INSERT ON transcript "
        "WHEN (SELECT value FROM preferences WHERE key='test.fail')='1' "
        "BEGIN SELECT RAISE(ABORT,'transient'); END",
      );
      final person = store.saveMeetingParticipants(meeting, [
        participant('ax:1', 'Ada'),
      ]).single;
      final segment = RecordingTranscriptSegment(
        'retried words',
        10,
        20,
        'playback',
        finalText: true,
        attribution: automatic(person.id, 'Ada'),
      );
      persistence.add(segment);
      expect(timers, hasLength(1));
      expect(rowsOf('SELECT * FROM transcript'), 0);
      expect(rowsOf('SELECT * FROM transcript_attributions'), 0);
      store.db.execute(
        "UPDATE preferences SET value='0' WHERE key='test.fail'",
      );
      timers.removeLast()();
      expect(committed, 1);
      expect(rowsOf('SELECT * FROM transcript'), 1);
      expect(rowsOf('SELECT * FROM transcript_attributions'), 1);
      expect(segment.attributionSaved, isTrue);
      expect(segment.transcriptId, isNotNull);
      expect(persistence.pending, 0);
    });

    test('queue accounting includes attribution and reports its rejection', () {
      final persistence = RecordingTranscriptPersistence(
        store: store,
        meeting: meeting,
        createTimer: (_, __) => throw StateError('no retry expected'),
        committed: (_) {},
        retrying: () {},
        exhausted: () => fail('must not exhaust'),
      );
      addTearDown(persistence.dispose);
      final bare = RecordingTranscriptSegment(
        'abc',
        1,
        2,
        'playback',
        finalText: true,
      );
      final named = RecordingTranscriptSegment(
        'abc',
        1,
        2,
        'playback',
        finalText: true,
        attribution: automatic(424242, 'Ghost'),
      );
      expect(named.bytes, greaterThan(bare.bytes));
      persistence.add(named);
      expect(persistence.pending, 0);
      expect(named.attributionSaved, isFalse);
      expect(named.attributionError, isA<SqliteException>());
      expect(store.meetingQueries.finalTranscriptText(meeting), ['abc']);
    });
  });

  group('participants', () {
    test('roster upsert is batched, idempotent and never merges by name', () {
      final saved = store.saveMeetingParticipants(meeting, [
        participant('ax:1', 'Sam', first: 5, last: 50),
        participant('ax:2', 'Sam', self: true, first: 6, last: 60),
        participant('ax:1', 'Sam', scope: 'session-2/window-1'),
      ]);
      expect(saved.map((p) => p.id).toSet(), hasLength(3));
      final again = store.saveMeetingParticipants(meeting, [
        participant('ax:1', 'Sam', first: 9, last: 80),
        participant('ax:2', 'Sam', first: 1, last: 10),
      ]);
      expect(again.map((p) => p.id), [saved[0].id, saved[1].id]);
      expect(again[0].firstSeenMs, 5);
      expect(again[0].lastSeenMs, 80);
      expect(again[1].firstSeenMs, 1);
      expect(again[1].lastSeenMs, 60);
      expect(again[1].isSelf, isTrue, reason: 'self evidence is sticky');
      expect(again[0].renameCount, 0);
      expect(store.meetingQueries.participants(meeting), hasLength(3));
      expect(
        () => store.saveMeetingParticipants(
          meeting,
          List.generate(
            maxParticipantBatch + 1,
            (i) => participant('k$i', 'N$i'),
          ),
        ),
        throwsArgumentError,
      );
    });

    test('a roster refresh invalidates and reindexes nothing', () {
      mapSource();
      final id = finalRow('stable words');
      store.setManualAttribution(
        id,
        TranscriptAttribution.manual(displayName: 'Ada'),
      );
      final projection = MeetingTranscriptProjection(store);
      projection.prepare(meeting, store.workspaceEpoch, 0);
      final changes = rowsOf('SELECT * FROM meeting_transcript_changes');
      final pieces = rowsOf('SELECT * FROM meeting_index_segments');
      final before = revision();
      final sourceRevision = store.rows(
        "SELECT revision FROM sources WHERE id='meeting-$meeting'",
      );
      store.saveMeetingParticipants(meeting, [
        for (var i = 0; i < 40; i++) participant('ax:$i', 'Person $i'),
      ]);
      store.saveMeetingParticipants(meeting, [
        for (var i = 0; i < 40; i++)
          participant('ax:$i', 'Person $i', last: 5000),
      ]);
      store.saveMeetingParticipants(meeting, [
        participant('ax:3', 'Person Three', last: 6000),
      ]);
      expect(revision(), before);
      expect(rowsOf('SELECT * FROM meeting_transcript_changes'), changes);
      expect(rowsOf('SELECT * FROM meeting_index_segments'), pieces);
      expect(
        store.rows("SELECT revision FROM sources WHERE id='meeting-$meeting'"),
        sourceRevision,
      );
    });

    test('observed rename is tracked without rewriting existing snapshots', () {
      final ada = store.saveMeetingParticipants(meeting, [
        participant('ax:1', 'iPhone'),
      ]).single;
      final id = finalRow('said while iPhone');
      store.saveAutomaticAttribution(id, automatic(ada.id, 'iPhone'));
      final renamed = store.saveMeetingParticipants(meeting, [
        participant('ax:1', 'Ada Lovelace', last: 900),
      ]).single;
      expect(renamed.id, ada.id);
      expect(renamed.displayName, 'Ada Lovelace');
      expect(renamed.previousDisplayName, 'iPhone');
      expect(renamed.renameCount, 1);
      expect(renamed.nameChangedMs, 900);
      final stored = store.meetingQueries.attribution(id)!;
      expect(stored.displayName, 'iPhone');
      expect(stored.revision, 1);
      // Same spelling again is not another rename.
      expect(
        store
            .saveMeetingParticipants(meeting, [
              participant('ax:1', 'Ada Lovelace', last: 950),
            ])
            .single
            .renameCount,
        1,
      );
    });

    test('a user rename relabels one participant and is not overwritten', () {
      mapSource();
      final ada = store.saveMeetingParticipants(meeting, [
        participant('ax:1', 'iPhone'),
        participant('ax:2', 'Bob'),
      ]);
      final a1 = finalRow('first');
      final a2 = finalRow('second');
      final b1 = finalRow('third');
      final other = finalRow('fourth, unattributed');
      store.saveAutomaticAttribution(a1, automatic(ada[0].id, 'iPhone'));
      store.saveAutomaticAttribution(a2, automatic(ada[0].id, 'iPhone'));
      store.saveAutomaticAttribution(b1, automatic(ada[1].id, 'Bob'));
      final projection = MeetingTranscriptProjection(store);
      projection.prepare(meeting, store.workspaceEpoch, 0);
      projection.acknowledge(
        meeting,
        store.workspaceEpoch,
        projection.pending(meeting, store.workspaceEpoch)!,
      );
      expect(rowsOf('SELECT * FROM meeting_transcript_changes'), 0);

      expect(store.renameMeetingParticipant(ada[0].id!, 'Ada Lovelace'), 2);
      expect(
        store
            .rows(
              'SELECT transcript_id FROM meeting_transcript_changes ORDER BY 1',
            )
            .map((r) => r['transcript_id']),
        [a1, a2],
        reason: 'only rows naming the renamed participant are reprojected',
      );
      expect(store.meetingQueries.attribution(a1)!.displayName, 'Ada Lovelace');
      expect(store.meetingQueries.attribution(b1)!.displayName, 'Bob');
      expect(store.meetingQueries.attribution(other), isNull);
      expect(store.meetingQueries.attribution(a1)!.revision, 2);
      expect(
        store.meetingQueries
            .participants(meeting)
            .firstWhere((p) => p.id == ada[0].id)
            .nameManual,
        isTrue,
      );
      // A later observation of the old spelling cannot undo the user's name.
      final observed = store.saveMeetingParticipants(meeting, [
        participant('ax:1', 'iPhone', last: 9000),
      ]).single;
      expect(observed.displayName, 'Ada Lovelace');
      expect(observed.renameCount, 1);
      expect(observed.lastSeenMs, 9000);
      // Idempotent: renaming to the current spelling relabels nothing.
      expect(store.renameMeetingParticipant(ada[0].id!, 'Ada Lovelace'), 0);
      expect(
        () => store.renameMeetingParticipant(ada[0].id!, ' \n'),
        throwsA(isA<RpcError>()),
      );
      expect(
        () => store.renameMeetingParticipant(424242, 'Nobody'),
        throwsA(
          isA<RpcError>().having((e) => e.code, 'code', RpcErrorCode.notFound),
        ),
      );
    });
  });

  group('rename ownership', () {
    test('a delayed observation keeps the user-assigned participant name', () {
      final person = store.saveMeetingParticipants(meeting, [
        participant('ax:1', 'iPhone'),
      ]).single;
      final old = finalRow('earlier');
      store.saveAutomaticAttribution(old, automatic(person.id, 'iPhone'));
      store.renameMeetingParticipant(person.id!, 'Ada Lovelace');
      final before = revision();
      // A retried or late observation still carries the old spelling.
      expect(
        store.saveAutomaticAttribution(old, automatic(person.id, 'iPhone')),
        AttributionWriteOutcome.unchanged,
      );
      final fresh = finalRow('later');
      store.saveAutomaticAttribution(fresh, automatic(person.id, 'iPhone'));
      expect(
        store.meetingQueries.attribution(old)!.displayName,
        'Ada Lovelace',
      );
      expect(
        store.meetingQueries.attribution(fresh)!.displayName,
        'Ada Lovelace',
      );
      expect(
        revision(),
        before + 2,
        reason: 'the new text and its attribution; nothing else changed',
      );
      // An unrelated participant is untouched by the rule.
      final bob = store.saveMeetingParticipants(meeting, [
        participant('ax:2', 'Bob'),
      ]).single;
      final other = finalRow('bob speaks');
      store.saveAutomaticAttribution(other, automatic(bob.id, 'Robert'));
      expect(store.meetingQueries.attribution(other)!.displayName, 'Robert');
    });

    test('a rename keeps rows the user corrected to a custom name', () {
      final person = store.saveMeetingParticipants(meeting, [
        participant('ax:1', 'iPhone'),
      ]).single;
      final plain = finalRow('auto');
      final custom = finalRow('custom');
      final same = finalRow('manual, same name');
      store.saveAutomaticAttribution(plain, automatic(person.id, 'iPhone'));
      store.setManualAttribution(
        custom,
        TranscriptAttribution.manual(
          participantId: person.id,
          displayName: 'Dr. Ada',
        ),
      );
      store.setManualAttribution(
        same,
        TranscriptAttribution.manual(
          participantId: person.id,
          displayName: 'iPhone',
        ),
      );
      expect(store.renameMeetingParticipant(person.id!, 'Ada'), 2);
      expect(store.meetingQueries.attribution(plain)!.displayName, 'Ada');
      expect(store.meetingQueries.attribution(same)!.displayName, 'Ada');
      expect(store.meetingQueries.attribution(same)!.manual, isTrue);
      expect(store.meetingQueries.attribution(custom)!.displayName, 'Dr. Ada');
    });
  });

  group('corrections', () {
    test('automatic observation never overwrites a manual override', () {
      final id = finalRow('contested');
      store.saveAutomaticAttribution(id, automatic(null, 'Auto'));
      store.setManualAttribution(
        id,
        TranscriptAttribution.manual(displayName: 'Ada'),
      );
      final revisionAfterManual = revision();
      expect(
        store.saveAutomaticAttribution(id, automatic(null, 'Robot')),
        AttributionWriteOutcome.protectedByManual,
      );
      final stored = store.meetingQueries.attribution(id)!;
      expect(stored.displayName, 'Ada');
      expect(stored.manual, isTrue);
      expect(stored.method, AttributionMethod.manual);
      expect(revision(), revisionAfterManual);
      // The database itself rejects an automatic downgrade of a manual row.
      expect(
        () => store.db.execute(
          'UPDATE transcript_attributions SET manual=0 WHERE transcript_id=?',
          [id],
        ),
        throwsA(isA<SqliteException>()),
      );
      expect(
        () => store.saveAutomaticAttribution(
          id,
          TranscriptAttribution.manual(displayName: 'Ada'),
        ),
        throwsArgumentError,
      );
      expect(
        () => store.setManualAttribution(id, automatic(null, 'Auto')),
        throwsArgumentError,
      );
    });

    test(
      'manual unnamed blocks names; reset reopens the row to automation',
      () {
        final id = finalRow('not Ada');
        store.saveAutomaticAttribution(id, automatic(null, 'Ada'));
        store.setManualAttribution(id, TranscriptAttribution.manualUnnamed());
        final segment = store.meetingQueries.transcript(meeting).single;
        expect(segment.participantName, isNull);
        expect(segment.attributionState, 'unknown');
        expect(segment.attributionManual, isTrue);
        expect(
          store.saveAutomaticAttribution(id, automatic(null, 'Ada')),
          AttributionWriteOutcome.protectedByManual,
        );
        expect(store.resetAttribution(id), isTrue);
        expect(store.resetAttribution(id), isFalse);
        expect(
          store.saveAutomaticAttribution(id, automatic(null, 'Ada')),
          AttributionWriteOutcome.written,
        );
        expect(
          store.saveAutomaticAttribution(id, automatic(null, 'Ada')),
          AttributionWriteOutcome.unchanged,
        );
      },
    );

    test('missing rows are not found, not silently ignored', () {
      expect(
        () => store.setManualAttribution(
          99,
          TranscriptAttribution.manual(displayName: 'Ada'),
        ),
        throwsA(
          isA<RpcError>().having((e) => e.code, 'code', RpcErrorCode.notFound),
        ),
      );
      expect(
        () => store.saveAutomaticAttribution(99, automatic(null, 'Ada')),
        throwsA(isA<RpcError>()),
      );
      expect(() => store.resetAttribution(99), throwsA(isA<RpcError>()));
    });

    test('a correction records durable reindex intent at the new revision', () {
      final id = finalRow('fix me');
      store.setManualAttribution(
        id,
        TranscriptAttribution.manual(displayName: 'Ada'),
      );
      final job = store.rows('SELECT * FROM meeting_index_jobs').single;
      expect(job['meeting_id'], meeting);
      expect(job['revision'], revision());
      expect(job['workspace_epoch'], store.workspaceEpoch);
      final recovered = MeetingIndexJobs.forStore(store).recover();
      expect(recovered.single.revision, revision());
    });
  });

  group('invalidation and projection', () {
    test('attribution bumps revision, journals the row and renders the name', () {
      mapSource();
      final named = finalRow('Hello from Ada', source: 'playback');
      final plain = finalRow('Hello from nobody', source: 'microphone');
      final projection = MeetingTranscriptProjection(store);
      var batch = projection.prepare(meeting, store.workspaceEpoch, 0)!;
      projection.acknowledge(meeting, store.workspaceEpoch, batch);
      expect(rowsOf('SELECT * FROM meeting_transcript_changes'), 0);
      expect(sourceBody(), contains('[Remote 10–20 ms] Hello from Ada'));

      final before = revision();
      store.saveAutomaticAttribution(named, automatic(null, 'Ada Lovelace'));
      expect(revision(), before + 1);
      expect(
        store
            .rows(
              'SELECT transcript_id,projected FROM meeting_transcript_changes',
            )
            .map((r) => r['transcript_id']),
        [named],
      );
      expect(
        store
            .rows("SELECT state FROM sources WHERE id='meeting-$meeting'")
            .single['state'],
        'pending',
      );
      expect(
        store.rows('SELECT * FROM meeting_index_deletes'),
        isNotEmpty,
        reason: 'the superseded helper piece is retired',
      );
      batch = projection.prepare(meeting, store.workspaceEpoch, 1)!;
      final texts = batch.request.upserts.map((u) => u.text).toList();
      expect(texts, ['[Ada Lovelace 10–20 ms] Hello from Ada']);
      expect(batch.request.upserts.single.key.channel.value, 1);
      expect(batch.request.deletes, hasLength(1));
      expect(
        sourceBody(),
        '[Ada Lovelace 10–20 ms] Hello from Ada\n[Microphone 10–20 ms] Hello from nobody',
      );
      expect(plain, isNot(named));
      // The raw transcript text and legacy source are untouched.
      final row = store.meetingQueries.transcript(meeting).first;
      expect(row.text, 'Hello from Ada');
      expect(row.source, 'playback');
    });

    test(
      'non-rendering changes bump revision only and evidence-only changes nothing',
      () {
        mapSource();
        final id = finalRow('quiet');
        final projection = MeetingTranscriptProjection(store);
        projection.acknowledge(
          meeting,
          store.workspaceEpoch,
          projection.prepare(meeting, store.workspaceEpoch, 0)!,
        );
        var before = revision();
        // A segment attributed to nobody is information-free.
        store.saveAutomaticAttribution(
          id,
          TranscriptAttribution(state: AttributionState.unknown),
        );
        expect(revision(), before);
        expect(rowsOf('SELECT * FROM meeting_transcript_changes'), 0);
        // A meaningful non-name state changes consumers but not indexed text.
        store.saveAutomaticAttribution(
          id,
          TranscriptAttribution(state: AttributionState.multiple, method: 'x'),
        );
        expect(revision(), before + 1);
        expect(rowsOf('SELECT * FROM meeting_transcript_changes'), 0);
        expect(
          rowsOf('SELECT * FROM meeting_index_segments WHERE acknowledged=0'),
          0,
        );
        before = revision();
        // Evidence-only update rewrites no text and invalidates no cache.
        store.saveAutomaticAttribution(
          id,
          TranscriptAttribution(
            state: AttributionState.multiple,
            method: 'x',
            evidence: {'covered_ms': 1},
          ),
        );
        expect(revision(), before);
        expect(store.meetingQueries.attribution(id)!.revision, 3);
      },
    );

    test('only replaced or removed names mark backup erasure', () {
      bool pending() => store
          .rows(
            "SELECT 1 FROM preferences WHERE key='internal.backupErasurePending'",
          )
          .isNotEmpty;
      void clear() => store.db.execute(
        "DELETE FROM preferences WHERE key='internal.backupErasurePending'",
      );
      final id = finalRow('private');
      final person = store.saveMeetingParticipants(meeting, [
        participant('ax:1', 'Ada'),
      ]).single;
      clear();
      store.saveAutomaticAttribution(id, automatic(person.id, 'Ada'));
      expect(pending(), isFalse, reason: 'creating a name erases nothing');
      store.saveAutomaticAttribution(
        id,
        automatic(person.id, 'Ada', evidence: const {'covered_ms': 1}),
      );
      expect(pending(), isFalse, reason: 'evidence is not a name');
      store.saveAutomaticAttribution(id, automatic(person.id, 'Ada L.'));
      expect(pending(), isTrue);
      clear();
      store.renameMeetingParticipant(person.id!, 'Ada Lovelace');
      expect(pending(), isTrue);
      clear();
      store.resetAttribution(id);
      expect(pending(), isTrue);
      clear();
      store.saveMeetingParticipants(meeting, [participant('ax:1', 'Other')]);
      expect(pending(), isFalse, reason: 'manual participant name is kept');
      store.renameMeetingParticipant(person.id!, 'Ada Again');
      expect(pending(), isTrue, reason: 'an older previous name was dropped');
    });

    test('interim rows and uncommitted text are never invalidated', () {
      mapSource();
      final interim = finalRow('partial', final_: false);
      final before = revision();
      store.saveAutomaticAttribution(interim, automatic(null, 'Ada'));
      expect(revision(), before);
      expect(rowsOf('SELECT * FROM meeting_transcript_changes'), 0);
      expect(sourceBody(), isEmpty);
    });

    test('a stale prepared batch cannot acknowledge or resurrect old text', () {
      mapSource();
      final id = finalRow('contested line');
      final projection = MeetingTranscriptProjection(store);
      final stale = projection.prepare(meeting, store.workspaceEpoch, 0)!;
      store.setManualAttribution(
        id,
        TranscriptAttribution.manual(displayName: 'Ada'),
      );
      expect(
        projection.pending(meeting, store.workspaceEpoch),
        isNull,
        reason: 'the saved batch no longer matches its pieces',
      );
      projection.acknowledge(meeting, store.workspaceEpoch, stale);
      expect(
        rowsOf('SELECT * FROM meeting_index_segments WHERE acknowledged=1'),
        0,
      );
      final fresh = projection.prepare(meeting, store.workspaceEpoch, 1)!;
      expect(fresh.request.upserts.map((u) => u.text), [
        '[Ada 10–20 ms] contested line',
      ]);
      projection.acknowledge(meeting, store.workspaceEpoch, fresh);
      expect(projection.unfinished(meeting), isFalse);
    });

    test(
      'reset reprojects the channel label and a large relabel stays bounded',
      () {
        mapSource();
        final person = store.saveMeetingParticipants(meeting, [
          participant('ax:1', 'iPhone'),
        ]).single;
        final ids = [for (var i = 0; i < 40; i++) finalRow('line $i')];
        for (final id in ids) {
          store.saveAutomaticAttribution(id, automatic(person.id, 'iPhone'));
        }
        final projection = MeetingTranscriptProjection(store);
        for (
          var pass = 0;
          pass < 10 && projection.unfinished(meeting);
          pass++
        ) {
          final batch = projection.prepare(meeting, store.workspaceEpoch, pass);
          if (batch != null) {
            projection.acknowledge(meeting, store.workspaceEpoch, batch);
          }
        }
        expect(projection.unfinished(meeting), isFalse);
        expect(sourceBody(), contains('[iPhone 10–20 ms] line 0'));
        expect(store.renameMeetingParticipant(person.id!, 'Ada'), 40);
        expect(sourceBody(), contains('[Ada 10–20 ms] line 39'));
        expect(sourceBody(), isNot(contains('iPhone')));
        expect(store.resetAttribution(ids.first), isTrue);
        expect(sourceBody(), startsWith('[Remote 10–20 ms] line 0'));
      },
    );

    test('indexed and stored source text agree on sanitized labels', () {
      mapSource();
      final id = finalRow('spoof');
      store.setManualAttribution(
        id,
        TranscriptAttribution.manual(displayName: 'Eve]\n[Microphone 0–1 ms'),
      );
      final projection = MeetingTranscriptProjection(store);
      final batch = projection.prepare(meeting, store.workspaceEpoch, 0)!;
      final indexed = batch.request.upserts.single.text;
      expect(indexed, '[Eve) (Microphone 0–1 ms 10–20 ms] spoof');
      expect(sourceBody(), indexed);
      expect(
        store.meetingQueries.transcript(meeting).single.participantName,
        'Eve]\n[Microphone 0–1 ms',
        reason: 'the stored display name stays verbatim',
      );
    });
  });

  group('deletion', () {
    test('deleting a transcript row cascades its attribution quietly', () {
      mapSource();
      final id = finalRow('to be removed');
      store.saveAutomaticAttribution(id, automatic(null, 'Ada'));
      final before = revision();
      store.db.execute('DELETE FROM transcript WHERE id=?', [id]);
      expect(rowsOf('SELECT * FROM transcript_attributions'), 0);
      expect(revision(), greaterThan(before));
      expect(store.rows('PRAGMA foreign_key_check'), isEmpty);
      expect(
        store.rows(
          "SELECT value FROM preferences WHERE key='internal.backupErasurePending'",
        ),
        isNotEmpty,
      );
    });

    test('deleting a meeting removes its participants and attributions', () {
      final person = store.saveMeetingParticipants(meeting, [
        participant('ax:1', 'Ada'),
      ]).single;
      final id = finalRow('gone');
      store.saveAutomaticAttribution(id, automatic(person.id, 'Ada'));
      store.db.execute('DELETE FROM transcript WHERE meeting_id=?', [meeting]);
      store.db.execute('DELETE FROM meeting_details WHERE meeting_id=?', [
        meeting,
      ]);
      store.db.execute('DELETE FROM meetings WHERE id=?', [meeting]);
      expect(rowsOf('SELECT * FROM meeting_participants'), 0);
      expect(rowsOf('SELECT * FROM transcript_attributions'), 0);
      expect(store.rows('PRAGMA foreign_key_check'), isEmpty);
    });

    test(
      'removing a participant keeps the name snapshot but drops the link',
      () {
        final person = store.saveMeetingParticipants(meeting, [
          participant('ax:1', 'Ada'),
        ]).single;
        final id = finalRow('remembered');
        store.saveAutomaticAttribution(id, automatic(person.id, 'Ada'));
        store.db.execute('DELETE FROM meeting_participants WHERE id=?', [
          person.id,
        ]);
        final stored = store.meetingQueries.attribution(id)!;
        expect(stored.participantId, isNull);
        expect(stored.displayName, 'Ada');
        expect(
          store.meetingQueries.transcript(meeting).single.participantName,
          'Ada',
        );
      },
    );

    test('workspace clear removes every participant and attribution', () {
      final person = store.saveMeetingParticipants(meeting, [
        participant('ax:1', 'Private Person'),
      ]).single;
      final id = finalRow('private words');
      store.saveAutomaticAttribution(
        id,
        automatic(person.id, 'Private Person'),
      );
      mapSource();
      final cleared = WorkspacePersistence(store).clearLocalData(const []);
      expect(cleared.sourceIds, isEmpty);
      for (final table in ['meeting_participants', 'transcript_attributions']) {
        expect(workspaceContentTables, contains(table));
        expect(rowsOf('SELECT * FROM $table'), 0, reason: table);
      }
      expect(rowsOf('SELECT * FROM transcript'), 0);
      expect(store.rows('PRAGMA foreign_key_check'), isEmpty);
    });
  });

  group('restart', () {
    test('participants, corrections and rendered text survive reopen', () {
      mapSource();
      final person = store.saveMeetingParticipants(meeting, [
        participant('ax:1', 'Ada', self: true),
      ]).single;
      final id = finalRow('persistent');
      store.saveAutomaticAttribution(id, automatic(person.id, 'Ada'));
      store.setManualAttribution(
        id,
        TranscriptAttribution.manual(
          participantId: person.id,
          displayName: 'Ada L.',
        ),
      );
      final epoch = store.workspaceEpoch;
      store.close();
      open();
      expect(store.workspaceEpoch, epoch);
      final stored = store.meetingQueries.attribution(id)!;
      expect(stored.manual, isTrue);
      expect(stored.displayName, 'Ada L.');
      expect(stored.participantId, person.id);
      expect(store.meetingQueries.participants(meeting).single.isSelf, isTrue);
      expect(sourceBody(), '[Ada L. 10–20 ms] persistent');
      expect(
        store.saveAutomaticAttribution(id, automatic(null, 'Robot')),
        AttributionWriteOutcome.protectedByManual,
      );
      expect(
        MeetingIndexJobs.forStore(store).recover().single.meeting,
        meeting,
      );
    });
  });
}
