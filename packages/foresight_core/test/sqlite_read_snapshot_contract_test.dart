import 'package:foresight_core/src/persistence/read_schema_guard.dart';
import 'package:foresight_core/src/rpc_error.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  late Database db;
  setUp(() {
    final root = createTestTempDirectorySync('snapshot-contract-');
    db = sqlite3.open('${root.path}/snapshot.db');
    db.execute('CREATE TABLE payload(body TEXT)');
    db.execute("INSERT INTO payload VALUES('committed')");
    addTearDown(() {
      db.dispose();
      root.deleteSync(recursive: true);
    });
  });

  test(
    'async snapshot callbacks refuse and roll back their owned transaction',
    () {
      expect(
        () => readSnapshot(db, () {
          db.execute("INSERT INTO payload VALUES('must roll back')");
          return Future.value('not a synchronous snapshot');
        }, supportedVersion: 1),
        throwsArgumentError,
      );
      expect(db.autocommit, isTrue);
      expect(db.select('SELECT body FROM payload').map((r) => r['body']), [
        'committed',
      ]);
    },
  );

  test(
    'failed nested snapshots leave transaction decisions with their caller',
    () {
      db.execute('BEGIN');
      db.execute("INSERT INTO payload VALUES('caller-owned')");
      expect(
        () => readSnapshot<void>(
          db,
          () => throw StateError('read failed'),
          supportedVersion: 1,
        ),
        throwsStateError,
      );
      expect(db.autocommit, isFalse);
      expect(db.select('SELECT body FROM payload'), hasLength(2));
      db.execute('ROLLBACK');
      expect(db.select('SELECT body FROM payload'), hasLength(1));
    },
  );

  test(
    'future schema refusal reports an actionable typed error before rows',
    () {
      db.execute('PRAGMA user_version=2');
      var called = false;
      expect(
        () => readSnapshot(db, () => called = true, supportedVersion: 1),
        throwsA(
          isA<IncompatibleReadSchema>()
              .having((e) => e.rpcError.code, 'code', RpcErrorCode.unavailable)
              .having(
                (e) => e.toString(),
                'action',
                contains('Update Open Foresight and reconnect'),
              ),
        ),
      );
      expect(called, isFalse);
      expect(db.autocommit, isTrue);
      expect(db.select('PRAGMA user_version').single.values.single, 2);
      expect(db.select('SELECT body FROM payload').single['body'], 'committed');
    },
  );
}
