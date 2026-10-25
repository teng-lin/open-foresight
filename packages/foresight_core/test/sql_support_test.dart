import 'dart:isolate';
import 'dart:io';

import 'package:foresight_core/persistence_bootstrap.dart';
import 'package:foresight_core/src/persistence/sql_support.dart';
import 'package:foresight_core/src/persistence/sqlite_runtime.dart';
import 'package:foresight_core/src/persistence/sqlite_statement_budget.dart';
import 'package:foresight_core/src/platform_services.dart';
import 'package:foresight_core/src/rpc_error.dart';
import 'package:test/test.dart';

import 'sql_support_test_bootstrap.dart';

void main() {
  // This must happen in the parent, before any connection or test isolate.
  bootstrapSqlSupportFixture();

  test(
    'repeated exact selection reuses code and changed selection refuses after DB open',
    () {
      final selected =
          Platform.environment['FORESIGHT_TEST_SQL_SUPPORT_LIBRARY']!;
      final db = openApplicationDatabase(':memory:');
      try {
        initializeSqliteRuntime(supportLibrary: selected);
        expect(
          () => initializeSqliteRuntime(supportLibrary: '$selected.changed'),
          throwsStateError,
        );
        expect(db.select('SELECT 42').single.values.single, 42);
      } finally {
        db.dispose();
      }
    },
  );

  test(
    'missed private handoff refuses DB access despite already mapped code',
    () async {
      final error = await Isolate.run(() {
        try {
          final db = openApplicationDatabase(':memory:');
          db.dispose();
        } catch (error) {
          return error.toString();
        }
        return 'unexpected connection';
      });
      expect(error, contains('SQL support early gate was missed'));
    },
  );

  test(
    'embedding gate refuses a basename before a native path can load',
    () async {
      final error = await Isolate.run(() {
        try {
          initializeSqliteRuntime(
            supportLibrary: 'libforesight_sql_support.so',
          );
        } catch (error) {
          return error;
        }
        return null;
      });
      expect(error, isA<ArgumentError>());
    },
  );

  test(
    'original code handoff works without loading the application-native image',
    () async {
      final support = currentSqlSupportBootstrap;
      final environment = {
        ...runtimeConfiguration.environment,
        'FORESIGHT_NATIVE': '/absent/heavy/application-native-image',
      };
      final result = await Isolate.run(() {
        installServiceWorkerEnvironment(environment);
        bindSqlSupportBootstrap(support);
        final db = openApplicationDatabase(':memory:');
        try {
          final budget = SqliteStatementBudget(db);
          return budget.run(
            const Duration(seconds: 1),
            () => db.select('SELECT 42').single.values.single,
          );
        } finally {
          db.dispose();
        }
      });
      expect(result, 42);
    },
  );

  test(
    'retirement refusal quarantines the owner instead of resetting admission',
    () async {
      final bootstrap = currentSqlSupportBootstrap;
      final result = await Isolate.run(() {
        bindSqlSupportBootstrap(bootstrap);
        Object? failure;
        try {
          currentSqlSupport.end(0);
        } catch (error) {
          failure = error;
        }
        bindSqlSupportBootstrap(
          bootstrap,
        ); // Same record cannot clear quarantine.
        Object? admission;
        try {
          currentSqlSupport.ensureAvailable();
        } catch (error) {
          admission = error;
        }
        return (failure, admission);
      });
      expect(
        result.$1,
        isA<RpcError>().having((e) => e.code, 'code', RpcErrorCode.unavailable),
      );
      expect(
        result.$2,
        isA<RpcError>().having((e) => e.code, 'code', RpcErrorCode.unavailable),
      );
    },
  );
}
