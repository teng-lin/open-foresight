import '../sql_support_test_bootstrap.dart';
import 'dart:io';
import 'package:foresight_core/src/persistence/sqlite_runtime.dart';

void main(List<String> arguments) {
  bootstrapSqlSupportFixture();
  Database? db;
  try {
    db = openApplicationDatabase(arguments.single);
    db.execute('BEGIN IMMEDIATE');
    db.execute('ROLLBACK');
    stderr.writeln('Unexpectedly acquired migration writer lock');
    exitCode = 1;
  } on SqliteException catch (error) {
    if (error.resultCode == 5) {
      stdout.writeln('SQLITE_BUSY');
    } else {
      stderr.writeln('$error');
      exitCode = 1;
    }
  } finally {
    db?.dispose();
  }
}
