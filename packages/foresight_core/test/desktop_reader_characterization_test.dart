import 'package:foresight_core/src/store.dart';
import 'package:foresight_test_support/persistence_fixtures.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';

void main() {
  late Store writer;
  late String path;

  setUp(() {
    final root = createTestTempDirectorySync('desktop-reader-contract-');
    path = '${root.path}/application.db';
    writer = Store(path);
    addTearDown(() {
      writer.close();
      root.deleteSync(recursive: true);
    });
  });

  test('a stable reader invalidates after another connection commits', () {
    final id = writer.importText('First', 'old body', 'text/plain', 'fixture');
    final reader = Store.readOnly(path);
    addTearDown(reader.close);
    final before = reader.dataRevision;
    expect(reader.sourceSummaries.single['title'], 'First');
    expect(reader.dataRevision, before);

    writer.importText('Second', 'new body', 'text/plain', 'fixture', id: id);

    expect(reader.dataRevision, isNot(before));
    expect(reader.sourceSummaries.single['title'], 'Second');
    final fresh = Store.readOnly(path);
    try {
      // A new connection reads committed rows independently of the token used
      // by the long-lived reader. Tokens are never cross-connection identities.
      expect(fresh.sourceById(id).single['content'], 'new body');
      expect(reader.sourceById(id).single['revision'], 2);
    } finally {
      fresh.close();
    }
  });

  test('one read transaction keeps epoch and projection in one snapshot', () {
    final id = writer.importText('Before', 'old body', 'text/plain', 'fixture');
    final beforeEpoch = writer.workspaceEpoch;
    final reader = Store.readOnly(path);
    addTearDown(reader.close);
    reader.db.execute('BEGIN');
    try {
      // This first read establishes the snapshot used by every projection read.
      expect(reader.workspaceEpoch, beforeEpoch);
      writer.db.execute('BEGIN IMMEDIATE');
      try {
        writer.renewWorkspaceEpoch();
        writer.db.execute(
          'UPDATE sources SET title=?,content=?,revision=revision+1 WHERE id=?',
          ['After', 'new body', id],
        );
        writer.db.execute('COMMIT');
      } catch (_) {
        writer.db.execute('ROLLBACK');
        rethrow;
      }

      expect(writer.workspaceEpoch, isNot(beforeEpoch));
      expect(reader.workspaceEpoch, beforeEpoch);
      final projected = reader.sourceById(id).single;
      expect(projected['title'], 'Before');
      expect(projected['content'], 'old body');
      expect(projected['revision'], 1);
    } finally {
      reader.db.execute('ROLLBACK');
    }
    expect(reader.workspaceEpoch, writer.workspaceEpoch);
    expect(reader.sourceById(id).single['title'], 'After');
    expect(reader.sourceById(id).single['revision'], 2);
  });

  test('opening a read-only reader does not advance a supported schema', () {
    // A newer compatible writer owns upgrades. Opening the desktop reader must
    // not rerun migrations or make current schema assumptions into write work.
    legacyLabelFixture(writer.db);
    writer.db.execute('PRAGMA user_version=14');
    final reader = Store.readOnly(path);
    try {
      expect(reader.rows('PRAGMA user_version').single.values.single, 14);
      expect(reader.rows('SELECT total_changes()').single.values.single, 0);
    } finally {
      reader.close();
    }
    expect(writer.rows('PRAGMA user_version').single.values.single, 14);
  });
}
