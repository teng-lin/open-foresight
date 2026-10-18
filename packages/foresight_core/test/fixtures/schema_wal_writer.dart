import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

// The parent kills this process after the commit acknowledgement. Keeping the
// connection alive until then leaves a committed WAL without a close checkpoint.
Future<void> main(List<String> arguments) async {
  final db = sqlite3.open(arguments[0]);
  try {
    db.execute('PRAGMA journal_mode=WAL');
    db.execute('PRAGMA wal_autocheckpoint=0');
    db.execute('CREATE TABLE future(value TEXT)');
    db.execute("INSERT INTO future VALUES('future data')");
    db.execute('PRAGMA user_version=${int.parse(arguments[1])}');
    stdout.writeln('committed');
    await stdout.flush();
    await stdin.drain<void>();
  } finally {
    db.dispose();
  }
}
