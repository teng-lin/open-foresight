import 'package:foresight_test_support/persistence_fixtures.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';

import 'package:foresight_core/src/store.dart';
import 'package:foresight_core/src/persistence/sqlite_runtime.dart';
import 'package:test/test.dart';

void main() {
  late Directory directory;
  late String path;
  setUp(() {
    directory = createTestTempDirectorySync('foresight-migration-');
    path = '${directory.path}/application.db';
  });
  setUp(() {
    addTearDown(() => directory.deleteSync(recursive: true));
  });

  test(
    'v19 preserves existing meetings and records manual title ownership',
    () {
      var store = Store(path);
      final id = store.meeting('Existing meeting');
      store.saveMeetingNotes(id, 'Existing notes');
      store.transcript(id, 'Existing transcript', true, 0, 1000, 'microphone');
      store.db.execute(
        'ALTER TABLE meetings DROP COLUMN title_manually_edited',
      );
      store.db.execute('PRAGMA user_version=18');
      final epoch = store.workspaceEpoch;
      store.close();
      store = Store(path);
      try {
        expect(store.workspaceEpoch, epoch);
        expect(
          store.rows('SELECT title,title_manually_edited FROM meetings').single,
          {'title': 'Existing meeting', 'title_manually_edited': 0},
        );
        expect(store.meetingQueries.note(id)!.body, 'Existing notes');
        expect(
          store.meetingQueries.transcript(id).single.text,
          'Existing transcript',
        );
        store.meetingStore.renameMeeting(id, 'Manual title');
        expect(store.rows('PRAGMA foreign_key_check'), isEmpty);
      } finally {
        store.close();
      }
      store = Store(path);
      try {
        expect(store.meetingQueries.workspace(id)!.title, 'Manual title');
        expect(
          store
              .rows('SELECT title_manually_edited FROM meetings')
              .single
              .values
              .single,
          1,
        );
      } finally {
        store.close();
      }
    },
  );

  test('v19 DDL rolls back when startup fails before migration commit', () {
    final store = Store(path);
    final id = store.meeting('Retained title');
    store.db.execute('ALTER TABLE meetings DROP COLUMN title_manually_edited');
    store.db.execute('PRAGMA user_version=18');
    store.db.execute(
      "CREATE TRIGGER interrupt_rename_migration BEFORE INSERT ON preferences BEGIN SELECT RAISE(ABORT, 'interrupted migration'); END",
    );
    store.close();
    expect(() => Store(path), throwsA(isA<SqliteException>()));
    final db = sqlite3.open(path);
    try {
      expect(db.select('PRAGMA user_version').single.values.single, 18);
      expect(
        db.select('PRAGMA table_info(meetings)').map((row) => row['name']),
        isNot(contains('title_manually_edited')),
      );
      expect(
        db.select('SELECT title FROM meetings WHERE id=?', [
          id,
        ]).single['title'],
        'Retained title',
      );
      db.execute('DROP TRIGGER interrupt_rename_migration');
    } finally {
      db.dispose();
    }
    final reopened = Store(path);
    addTearDown(reopened.close);
    expect(reopened.rows('PRAGMA user_version').single.values.single, 19);
  });

  test('v15 migrates legacy action aliases without losing manual edits', () {
    var store = Store(path);
    final meeting = store.meeting('Legacy actions');
    store.artifact(meeting, 'action_items', 'Generated checklist', 'old-model');
    final artifact =
        store.meetingArtifacts(meeting, 'action_items').single['id'] as int;
    store.editArtifact(artifact, 'Human correction');
    store.db.execute('DROP TABLE meeting_tasks');
    store.db.execute('DROP TABLE document_summary_cache');
    legacyLabelFixture(store.db);
    store.db.execute('PRAGMA user_version=14');
    store.close();
    store = Store(path);
    try {
      final row = store.meetingArtifacts(meeting, 'actions').single;
      expect(row['generated'], 'Generated checklist');
      expect(row['edited'], 'Human correction');
      expect(store.rows('SELECT * FROM meeting_tasks'), isEmpty);
      expect(store.rows('SELECT * FROM document_summary_cache'), isEmpty);
      expect(store.rows('PRAGMA foreign_key_check'), isEmpty);
    } finally {
      store.close();
    }
  });

  test('v14 preserves old summaries without inventing checkpoints', () {
    var store = Store(path);
    final meeting = store.meeting('Kept meeting');
    store.artifact(meeting, 'summary', 'Accepted brief', 'old-model');
    store.editArtifact(1, 'Reviewed brief');
    store.db.execute('DROP TABLE meeting_summary_checkpoints');
    legacyLabelFixture(store.db);
    store.db.execute('ALTER TABLE artifacts DROP COLUMN manifest');
    store.db.execute('PRAGMA user_version=13');
    store.close();
    store = Store(path);
    try {
      final artifact = store.meetingArtifacts(meeting, 'summary').single;
      expect(artifact['generated'], 'Accepted brief');
      expect(artifact['edited'], 'Reviewed brief');
      expect(artifact['manifest'], isNull);
      expect(store.summaryCheckpoint(meeting), isNull);
      expect(store.rows('PRAGMA foreign_key_check'), isEmpty);
      expect(
        store.rows('PRAGMA user_version').single.values.single,
        Store.schemaVersion,
      );
    } finally {
      store.close();
    }
  });

  test('v13 adds request keys and keeps one workspace epoch', () {
    var store = Store(path);
    store.saveNote(null, 'Kept', 'Body');
    store.db.execute('DROP TABLE IF EXISTS request_keys');
    store.db.execute("DELETE FROM preferences WHERE key='workspaceEpoch'");
    legacyLabelFixture(store.db);
    store.db.execute('PRAGMA user_version=12');
    store.close();
    store = Store(path);
    String? epoch() =>
        store
                .rows(
                  "SELECT value FROM preferences WHERE key='workspaceEpoch'",
                )
                .singleOrNull?['value']
            as String?;
    try {
      expect(
        store.rows('PRAGMA user_version').single.values.single,
        Store.schemaVersion,
      );
      expect(
        store
            .rows('PRAGMA table_info(request_keys)')
            .map(
              (row) => [row['name'], row['type'], row['notnull'], row['pk']],
            ),
        [
          ['key', 'TEXT', 0, 1],
          ['operation', 'TEXT', 1, 0],
          ['arguments', 'TEXT', 1, 0],
          ['result', 'TEXT', 1, 0],
          ['created', 'INTEGER', 1, 0],
        ],
      );
      expect(store.rows('SELECT title,body FROM notes').single, {
        'title': 'Kept',
        'body': 'Body',
      });
      final first = epoch();
      expect(first, matches(RegExp(r'^[0-9a-f]{32}$')));
      store.close();
      store = Store(path);
      expect(epoch(), first);
      expect(store.rows('SELECT total_changes() AS n').single['n'], 0);
    } finally {
      store.close();
    }
  });

  test('v12 dates new output without inventing dates for legacy artifacts', () {
    var store = Store(path);
    final meeting = store.meeting('An older meeting');
    store.artifact(meeting, 'summary', 'legacy output', 'fixture');
    legacyLabelFixture(store.db);
    store.db.execute('ALTER TABLE artifacts DROP COLUMN created');
    store.db.execute('PRAGMA user_version=11');
    store.close();
    store = Store(path);
    try {
      expect(
        store.rows('SELECT created FROM artifacts').single['created'],
        isNull,
      );
      final before = DateTime.now().millisecondsSinceEpoch;
      store.artifact(meeting, 'enhanced_notes', 'new local output', 'fixture');
      final now = DateTime.now();
      final created =
          store
                  .rows('SELECT created FROM artifacts ORDER BY id DESC')
                  .first['created']
              as int;
      expect(created, inInclusiveRange(before, now.millisecondsSinceEpoch));
      expect(store.localOutputWords, 5);
      expect(store.weeklyOutputWords(now), [0, 0, 0, 0, 3]);
      store.editArtifact(
        2,
        'Manual edits must not increase generation accounting',
      );
      expect(store.localOutputWords, 5);
    } finally {
      store.close();
    }
    final reader = Store.readOnly(path);
    try {
      expect(reader.localOutputWords, 5);
    } finally {
      reader.close();
    }
  });

  test('v11 backfills local edits and repeated edits never nest provenance', () {
    var store = Store(path);
    final id = store.importText(
      'Document',
      'original',
      'text/plain',
      'url:https://example.test/doc',
    );
    store.db.execute(
      "UPDATE sources SET provenance='user edit; user edit; url:https://example.test/doc' WHERE id=?",
      [id],
    );
    legacyLabelFixture(store.db);
    store.db.execute('PRAGMA user_version=10');
    store.close();
    store = Store(path);
    try {
      expect(store.sources.single['locally_edited'], 1);
      expect(
        store.sources.single['provenance'],
        'url:https://example.test/doc',
      );
      for (var i = 0; i < 3; i++) {
        store.importText(
          'Document',
          'edit $i',
          'text/plain',
          store.sources.single['provenance'] as String,
          id: id,
          locallyEdited: true,
        );
      }
      expect(
        store.sources.single['provenance'],
        'url:https://example.test/doc',
      );
      expect(store.sources.single['locally_edited'], 1);
      expect(store.sources.single['source_uri'], 'https://example.test/doc');
    } finally {
      store.close();
    }
  });

  test('a reader opened after writer close follows later WAL commits', () {
    var writer = Store(path);
    addTearDown(() => writer.close());
    final id = writer.saveNote(null, 'Kept', 'First body');
    writer.close();
    final reader = Store.readOnly(path);
    addTearDown(reader.close);
    expect(reader.rows('SELECT body FROM notes').single['body'], 'First body');
    writer = Store(path);
    writer.saveNote(id, 'Kept', 'Latest body');
    expect(reader.rows('SELECT body FROM notes').single['body'], 'Latest body');
  });

  for (final writerClosesFirst in [false, true]) {
    test(
      'WAL readers retain committed data with writer first=$writerClosesFirst',
      () {
        final writer = Store(path);
        addTearDown(writer.close);
        final id = writer.saveNote(null, 'Kept', 'First body');
        final reader = Store.readOnly(path);
        addTearDown(reader.close);
        reader.db.execute('BEGIN');
        expect(
          reader.rows('SELECT body FROM notes').single['body'],
          'First body',
        );
        writer.saveNote(id, 'Kept', 'Latest body');
        if (writerClosesFirst) {
          writer.close();
          expect(File('$path-wal').existsSync(), isTrue);
        }
        // A pinned reader keeps its original snapshot through writer close.
        expect(
          reader.rows('SELECT body FROM notes').single['body'],
          'First body',
        );
        reader.db.execute('COMMIT');
        expect(
          reader.rows('SELECT body FROM notes').single['body'],
          'Latest body',
        );
        reader.close();
        if (!writerClosesFirst) writer.close();
        final reopened = Store(path);
        addTearDown(reopened.close);
        expect(
          reopened.rows('SELECT body FROM notes').single['body'],
          'Latest body',
        );
      },
    );
  }

  test('fresh and current profiles support concurrent read-only connections', () {
    var publication = 0;
    void checkReader() {
      final writer = Store(path);
      try {
        // No application writes occur before the desktop opens its reader.
        final reader = Store.readOnly(path);
        try {
          expect(reader.sources, isEmpty);
          expect(
            reader.rows('PRAGMA user_version').single.values.single,
            Store.schemaVersion,
          );
          expect(
            reader.rows('PRAGMA journal_mode').single.values.single,
            'wal',
          );
          final committed = '${++publication}';
          writer.db.execute(
            "INSERT OR REPLACE INTO preferences VALUES('reader-probe',?)",
            [committed],
          );
          // Live readers must see later WAL commits; immutable is appropriate
          // only for the short, sidecar-free version probe.
          expect(
            reader
                .rows("SELECT value FROM preferences WHERE key='reader-probe'")
                .single['value'],
            committed,
          );
        } finally {
          reader.close();
        }
      } finally {
        writer.close();
      }
    }

    checkReader(); // The migration transaction populated a new WAL.
    checkReader(); // The current schema needs no migration or application writes.
  });

  test('Store owns Google tables before a connection exists', () {
    final store = Store(path);
    addTearDown(store.close);
    expect(
      store.rows('PRAGMA user_version').single.values.single,
      Store.schemaVersion,
    );
    for (final table in [
      'google_sources',
      'calendar_events',
      'google_folders',
    ]) {
      expect(
        store.rows('SELECT name FROM sqlite_master WHERE name=?', [table]),
        hasLength(1),
      );
    }
    expect(store.rows('PRAGMA foreign_key_check'), isEmpty);
  });

  test('newer schemas are refused without modifying the database', () {
    final db = sqlite3.open(path);
    db.execute('CREATE TABLE future(value TEXT)');
    db.execute('INSERT INTO future VALUES(?)', ['future data']);
    db.execute('PRAGMA user_version=${Store.schemaVersion + 1}');
    db.dispose();
    final bytes = File(path).readAsBytesSync();
    expect(() => Store(path), throwsStateError);
    expect(() => Store.readOnly(path), throwsStateError);
    expect(File(path).readAsBytesSync(), bytes);
    expect(File('$path-wal').existsSync(), isFalse);
    expect(File('$path-shm').existsSync(), isFalse);
  });

  for (final variant in ['plain', 'symlink', 'missing shared memory']) {
    test(
      'future uncheckpointed WAL remains unchanged ($variant)',
      () async {
        final process = await Process.start(Platform.resolvedExecutable, [
          '--packages=${File('.dart_tool/package_config.json').absolute.path}',
          File('test/fixtures/schema_wal_writer.dart').absolute.path,
          path,
          '${Store.schemaVersion + 1}',
        ]);
        final errors = StringBuffer();
        process.stderr.transform(utf8.decoder).listen(errors.write);
        try {
          expect(
            await process.stdout
                .transform(utf8.decoder)
                .transform(const LineSplitter())
                .first
                .timeout(const Duration(seconds: 15)),
            'committed',
            reason: errors.toString(),
          );
        } finally {
          process.kill(ProcessSignal.sigkill);
          await process.stdin.close();
          await process.exitCode.timeout(const Duration(seconds: 15));
        }
        final mainBytes = File(path).readAsBytesSync();
        final walBytes = File('$path-wal').readAsBytesSync();
        // The main file still predates the future version. Reading only its
        // header, or probing the alias with immutable=1, would miss the WAL.
        expect(ByteData.sublistView(mainBytes).getUint32(60), 0);
        expect(walBytes.length, greaterThan(32));
        var openingPath = path;
        if (variant == 'symlink') {
          openingPath = '${directory.path}/alias.db';
          Link(openingPath).createSync(path);
        } else if (variant == 'missing shared memory') {
          File('$path-shm').deleteSync();
        }
        expect(() => Store(openingPath), throwsStateError);
        expect(File(path).readAsBytesSync(), mainBytes);
        expect(File('$path-wal').readAsBytesSync(), walBytes);
        expect(() => Store.readOnly(openingPath), throwsStateError);
        expect(File(path).readAsBytesSync(), mainBytes);
        expect(File('$path-wal').readAsBytesSync(), walBytes);
      },
      skip: Platform.isWindows
          ? 'Requires POSIX writer death and symlinks'
          : false,
    );
  }

  test(
    'checkpointed future WAL profile is refused without creating sidecars',
    () {
      path = '${directory.path}/future # ? % café.db';
      final db = sqlite3.open(path);
      db.execute('PRAGMA journal_mode=WAL');
      db.execute('CREATE TABLE future(value TEXT)');
      db.execute('PRAGMA user_version=${Store.schemaVersion + 1}');
      expect(db.select('PRAGMA wal_checkpoint(TRUNCATE)').single['busy'], 0);
      db.dispose();
      final bytes = File(path).readAsBytesSync();
      expect(
        ByteData.sublistView(bytes).getUint32(60),
        Store.schemaVersion + 1,
      );
      // Apple SQLite can retain sidecars after the final connection closes.
      // Build the sidecar-free fixture explicitly after proving its WAL is
      // checkpointed; Store must subsequently leave this state unchanged.
      final wal = File('$path-wal');
      if (wal.existsSync()) {
        expect(wal.lengthSync(), 0);
        wal.deleteSync();
      }
      final shm = File('$path-shm');
      if (shm.existsSync()) shm.deleteSync();
      expect(wal.existsSync(), isFalse);
      expect(shm.existsSync(), isFalse);
      expect(() => Store(path), throwsStateError);
      expect(File(path).readAsBytesSync(), bytes);
      expect(File('$path-wal').existsSync(), isFalse);
      expect(File('$path-shm').existsSync(), isFalse);
    },
  );

  test('an empty existing file can initialize as a fresh profile', () {
    File(path).createSync();
    final store = Store(path);
    addTearDown(store.close);
    expect(
      store.rows('PRAGMA user_version').single.values.single,
      Store.schemaVersion,
    );
  });

  test('legacy version one migrates in order and preserves stored data', () {
    // A genuine old baseline, before source-details and Google tables existed.
    final db = sqlite3.open(path);
    db.execute('''
      CREATE TABLE sources(id TEXT PRIMARY KEY,title TEXT NOT NULL,
        content TEXT NOT NULL,mime TEXT NOT NULL,revision INTEGER NOT NULL,
        state TEXT NOT NULL,error TEXT NOT NULL DEFAULT '',
        deleted INTEGER NOT NULL DEFAULT 0,provenance TEXT NOT NULL);
      INSERT INTO sources VALUES('legacy','Title','Body','text/plain',1,
        'imported','',0,'url:https://example.com/original');
      PRAGMA user_version=1;
    ''');
    db.dispose();
    var store = Store(path);
    expect(store.sources.single['content'], 'Body');
    expect(store.sources.single['source_uri'], 'https://example.com/original');
    expect(
      store.rows('PRAGMA user_version').single.values.single,
      Store.schemaVersion,
    );
    store.close();
    store = Store(path);
    addTearDown(store.close);
    expect(store.sources.single['source_uri'], 'https://example.com/original');
    expect(store.rows('SELECT total_changes() AS n').single['n'], 0);
  });

  test('failure after migration DDL rolls back schema, data and version', () {
    var store = Store(path);
    final id = store.importText(
      'Title',
      'Body',
      'text/plain',
      'url:https://example.com/original',
    );
    store.db.execute('ALTER TABLE source_details DROP COLUMN source_uri');
    legacyLabelFixture(store.db);
    store.db.execute('PRAGMA user_version=4');
    // Simulate interruption after ADD COLUMN but during its data backfill.
    store.db.execute('''CREATE TRIGGER interrupt_migration
      BEFORE UPDATE ON source_details BEGIN
        SELECT RAISE(ABORT, 'interrupted migration');
      END''');
    store.close();
    expect(() => Store(path), throwsA(isA<SqliteException>()));
    final db = sqlite3.open(path);
    expect(db.select('PRAGMA user_version').single.values.single, 4);
    expect(
      db.select('PRAGMA table_info(source_details)').map((row) => row['name']),
      isNot(contains('source_uri')),
    );
    expect(
      db.select('SELECT content FROM sources WHERE id=?', [
        id,
      ]).single['content'],
      'Body',
    );
    db.execute('DROP TRIGGER interrupt_migration');
    db.dispose();
    store = Store(path);
    addTearDown(store.close);
    expect(store.sources.single['source_uri'], 'https://example.com/original');
    expect(
      store.rows('PRAGMA user_version').single.values.single,
      Store.schemaVersion,
    );
  });

  test('v10 adds a durable helper purge queue without changing content', () {
    var store = Store(path);
    final id = store.importText('Retained', 'Body', 'text/plain', 'fixture');
    store.db.execute('DROP TABLE pending_helper_deletes');
    legacyLabelFixture(store.db);
    store.db.execute('PRAGMA user_version=9');
    store.close();
    store = Store(path);
    addTearDown(store.close);
    expect(store.sources.single['id'], id);
    store.db.execute('INSERT INTO pending_helper_deletes VALUES(?,?)', [
      'old-id',
      123,
    ]);
    expect(store.rows('SELECT * FROM pending_helper_deletes').single, {
      'document_id': 'old-id',
      'queued_at': 123,
    });
  });

  test('legacy malformed labels repair once without repeating writes', () {
    var store = Store(path);
    final id = store.importText('Title', 'Body', 'text/plain', 'fixture');
    legacyLabelFixture(store.db);
    store.db.execute('UPDATE source_details SET labels=? WHERE source_id=?', [
      'invalid JSON',
      id,
    ]);
    store.db.execute('PRAGMA user_version=8');
    store.close();
    store = Store(path);
    expect(store.sources.single['labels'], '[]');
    store.close();
    store = Store(path);
    addTearDown(store.close);
    expect(store.rows('SELECT total_changes() AS n').single['n'], 0);
  });
}
