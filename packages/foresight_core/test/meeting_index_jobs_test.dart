import 'dart:io';

import 'package:foresight_core/src/persistence/meeting_index_jobs.dart';
import 'package:foresight_core/src/persistence/sqlite_runtime.dart';
import 'package:foresight_core/src/rpc_error.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';

void main() {
  late Database db;
  late MeetingIndexJobs jobs;
  var epoch = 'original';

  void schema(Database connection) {
    connection.execute('PRAGMA foreign_keys=ON');
    // A minimal real-SQLite repository fixture. Store's ordered migration owns
    // these tables in production and is independently exercised by A3.
    connection.execute('''
      CREATE TABLE meetings(id INTEGER PRIMARY KEY,revision INTEGER NOT NULL);
      CREATE TABLE transcript(id INTEGER PRIMARY KEY,meeting_id INTEGER,final INTEGER);
      CREATE TABLE sources(id TEXT PRIMARY KEY,state TEXT,deleted INTEGER);
      CREATE TABLE meeting_index_jobs(
        meeting_id INTEGER PRIMARY KEY REFERENCES meetings(id) ON DELETE CASCADE,
        workspace_epoch TEXT NOT NULL,revision INTEGER NOT NULL,requested INTEGER NOT NULL);
      CREATE TABLE meeting_index_state(
        meeting_id INTEGER PRIMARY KEY REFERENCES meetings(id) ON DELETE CASCADE,
        workspace_epoch TEXT NOT NULL,revision INTEGER NOT NULL);
    ''');
  }

  void meeting(int id, {int revision = 1, bool transcript = true}) {
    db.execute('INSERT INTO meetings VALUES(?,?)', [id, revision]);
    if (transcript) {
      db.execute('INSERT INTO transcript(meeting_id,final) VALUES(?,1)', [id]);
    }
  }

  setUp(() {
    epoch = 'original';
    db = sqlite3.openInMemory();
    schema(db);
    jobs = MeetingIndexJobs(db, workspaceEpoch: () => epoch);
    addTearDown(db.dispose);
  });

  test('requests coalesce to the latest transcript revision', () {
    meeting(1);
    jobs.request(1);
    db.execute('UPDATE meetings SET revision=2 WHERE id=1');
    final latest = jobs.request(1);
    expect(latest.revision, 2);
    expect(db.select('SELECT * FROM meeting_index_jobs'), hasLength(1));
    expect(jobs.recover().single.revision, 2);
  });

  test('missing meetings cannot acquire work', () {
    expect(
      () => jobs.request(1),
      throwsA(
        isA<RpcError>().having((e) => e.code, 'code', RpcErrorCode.notFound),
      ),
    );
    expect(db.select('SELECT * FROM meeting_index_jobs'), isEmpty);
  });

  test('old completion cannot erase a newer request', () {
    meeting(1);
    final original = jobs.request(1);
    db.execute('UPDATE meetings SET revision=2 WHERE id=1');
    jobs.request(1);
    jobs.complete(original);
    expect(
      db.select('SELECT revision FROM meeting_index_jobs').single['revision'],
      2,
    );
    expect(
      db.select('SELECT revision FROM meeting_index_state').single['revision'],
      1,
    );
  });

  test('late completion cannot regress a successful revision', () {
    meeting(1);
    final original = jobs.request(1);
    db.execute('UPDATE meetings SET revision=2 WHERE id=1');
    final newer = jobs.request(1);
    jobs.complete(newer);
    jobs.complete(original);
    expect(
      db.select('SELECT revision FROM meeting_index_state').single['revision'],
      2,
    );
    expect(db.select('SELECT * FROM meeting_index_jobs'), isEmpty);
  });

  test('old workspace completion cannot acknowledge a reused meeting ID', () {
    meeting(1);
    final original = jobs.request(1);
    epoch = 'replacement';
    final replacement = jobs.request(1);
    jobs.complete(original);
    expect(db.select('SELECT * FROM meeting_index_state'), isEmpty);
    expect(jobs.recover().single.epoch, replacement.epoch);
  });

  test('deletion removes intent and cannot be reversed by completion', () {
    meeting(1);
    final original = jobs.request(1);
    db.execute('DELETE FROM meetings WHERE id=1');
    jobs.complete(original);
    expect(db.select('SELECT * FROM meeting_index_jobs'), isEmpty);
    expect(db.select('SELECT * FROM meeting_index_state'), isEmpty);
  });

  test(
    'recovery reconstructs missing intent from committed transcript revision',
    () {
      meeting(1, revision: 600);
      // Source revisions count index updates, not individual transcript commits.
      db.execute("INSERT INTO sources VALUES('meeting-1','indexed',0)");
      db.execute("INSERT INTO meeting_index_state VALUES(1,'original',599)");
      expect(db.select('SELECT * FROM meeting_index_jobs'), isEmpty);
      final pending = jobs.recover().single;
      expect(pending.meeting, 1);
      expect(pending.revision, 600);
    },
  );

  test('a successful source needs no repeated recovery', () {
    meeting(1);
    db.execute("INSERT INTO sources VALUES('meeting-1','indexed',0)");
    jobs.complete(jobs.request(1));
    expect(jobs.recover(), isEmpty);
  });

  test(
    'startup verification includes successful generated sources for helper cursor repair',
    () {
      db.execute(
        'ALTER TABLE sources ADD COLUMN generated INTEGER NOT NULL DEFAULT 0',
      );
      meeting(1);
      db.execute("INSERT INTO sources VALUES('meeting-1','indexed',0,1)");
      jobs.complete(jobs.request(1));
      expect(jobs.recover(), isEmpty);
      expect(jobs.recover(verifyCompleted: true).single.meeting, 1);
    },
  );

  test('recovery pages advance beyond failed earlier meeting intents', () {
    for (var id = 1; id <= 3; id++) {
      meeting(id);
      jobs.request(id);
    }
    expect(jobs.recover(limit: 1).single.meeting, 1);
    expect(jobs.recover(limit: 1, afterMeeting: 1).single.meeting, 2);
    expect(jobs.recover(limit: 1, afterMeeting: 2).single.meeting, 3);
    expect(jobs.recover(limit: 1, afterMeeting: 3), isEmpty);
  });

  test(
    'startup does not resurrect an explicitly deleted transcript source',
    () {
      meeting(1, revision: 600);
      jobs.request(1);
      db.execute("INSERT INTO sources VALUES('meeting-1','deleting',1)");
      expect(jobs.recover(), isEmpty);
      expect(db.select('SELECT * FROM meeting_index_jobs'), isEmpty);
      expect(db.select('SELECT deleted FROM sources').single['deleted'], 1);
    },
  );

  for (final state in ['pending', 'failed', 'indexing']) {
    test('recovery retains a $state source even at the same revision', () {
      meeting(1);
      db.execute('INSERT INTO sources VALUES(?,?,0)', ['meeting-1', state]);
      jobs.complete(jobs.request(1));
      expect(jobs.recover().single.meeting, 1);
    });
  }

  test('empty meetings do not generate recovery loops', () {
    meeting(1, transcript: false);
    expect(jobs.recover(), isEmpty);
  });

  test('recovery batch is bounded and invalid bounds are rejected', () {
    for (var id = 1; id <= 100; id++) {
      meeting(id);
    }
    expect(jobs.recover(), hasLength(64));
    expect(() => jobs.recover(limit: 0), throwsArgumentError);
    expect(() => jobs.recover(limit: 257), throwsArgumentError);
  });

  test('acknowledgement failure rolls back state and preserves intent', () {
    meeting(1);
    final pending = jobs.request(1);
    db.execute('''
      CREATE TRIGGER reject_index_ack BEFORE DELETE ON meeting_index_jobs BEGIN
        SELECT RAISE(ABORT,'controlled storage rejection');
      END;
    ''');
    expect(() => jobs.complete(pending), throwsA(isA<Exception>()));
    expect(db.select('SELECT * FROM meeting_index_state'), isEmpty);
    expect(db.select('SELECT * FROM meeting_index_jobs'), hasLength(1));
  });

  test('intent survives connection loss and restart', () {
    final directory = createTestTempDirectorySync('index-intent-');
    final path = '${directory.path}/jobs.db';
    final original = sqlite3.open(path);
    schema(original);
    original.execute('INSERT INTO meetings VALUES(7,3)');
    original.execute('INSERT INTO transcript(meeting_id,final) VALUES(7,1)');
    MeetingIndexJobs(original, workspaceEpoch: () => epoch).request(7);
    original.dispose();
    final reopened = sqlite3.open(path);
    addTearDown(reopened.dispose);
    final restored = MeetingIndexJobs(reopened, workspaceEpoch: () => epoch);
    expect(restored.recover().single.meeting, 7);
    expect(restored.recover().single.revision, 3);
    expect(File(path).existsSync(), true);
  });
}
