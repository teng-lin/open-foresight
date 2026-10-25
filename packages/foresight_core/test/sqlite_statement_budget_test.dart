import 'dart:isolate';

import 'package:foresight_core/src/persistence/sqlite_runtime.dart';
import 'package:foresight_core/src/persistence/sqlite_statement_budget.dart';
import 'package:foresight_core/src/platform_services.dart';
import 'package:foresight_core/src/rpc_error.dart';
import 'package:test/test.dart';
import 'package:sqlite3/open.dart' as loader;

const _longSql = '''
WITH RECURSIVE counter(x) AS (
  VALUES(0) UNION ALL SELECT x+1 FROM counter WHERE x<1000000000
) SELECT sum(x) FROM counter
''';

void main() {
  test(
    'owner-isolate deadline interrupts real SQL and leaves both connections usable',
    () async {
      final environment = runtimeConfiguration.environment;
      final result = await Isolate.run(() {
        installServiceWorkerEnvironment(environment);
        final db = openApplicationDatabase(':memory:');
        final unrelated = openApplicationDatabase(':memory:');
        try {
          // Changing a loader after the connection exists must never reopen a
          // library or select fresh bytes for its connection-local controls.
          loader.open.overrideForAll(
            () => throw StateError('Late library reopen'),
          );
          final budget = SqliteStatementBudget(db);
          final elapsed = Stopwatch()..start();
          Object? failure;
          try {
            budget.run(
              const Duration(milliseconds: 30),
              () => db.select(_longSql),
            );
          } catch (error) {
            failure = error;
          }
          final firstElapsed = elapsed.elapsedMilliseconds;
          final following = budget.run(
            const Duration(seconds: 1),
            () => db.select('SELECT 42').single.values.single,
          );
          final other = unrelated
              .select('''
WITH RECURSIVE counter(x) AS (
  VALUES(0) UNION ALL SELECT x+1 FROM counter WHERE x<100000
) SELECT sum(x) FROM counter
''')
              .single
              .values
              .single;
          return (failure, firstElapsed, following, other);
        } finally {
          db.dispose();
          unrelated.dispose();
        }
      });
      expect(
        result.$1,
        isA<RpcError>().having((e) => e.code, 'code', RpcErrorCode.busy),
      );
      expect(result.$2, lessThan(2000));
      expect(result.$3, 42);
      expect(result.$4, 5000050000);
    },
  );
}
