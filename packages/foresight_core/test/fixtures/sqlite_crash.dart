// Runs in a separate source-compiler process. exit deliberately bypasses SQLite
// close/checkpoint; journals and WAL are produced by SQLite itself.
import 'dart:io';
import 'package:foresight_core/src/persistence/sqlite_runtime.dart';

void main(List<String> args) {
  final db = sqlite3.open(args[0]);
  final version = int.parse(args[2]);
  db.execute('CREATE TABLE payload(id INTEGER PRIMARY KEY,body TEXT)');
  db.execute('PRAGMA user_version=$version');
  if (args[1] == 'wal') {
    db.execute('PRAGMA journal_mode=WAL');
    db.execute('PRAGMA wal_autocheckpoint=0');
    db.execute('PRAGMA user_version=${version + 1}');
    db.execute("INSERT INTO payload VALUES(1,'committed WAL body')");
  } else {
    db.execute('PRAGMA cache_size=5');
    db.execute('BEGIN IMMEDIATE');
    db.execute('PRAGMA user_version=0');
    for (var i = 0; i < 100; i++) {
      db.execute('INSERT INTO payload VALUES(?,?)', [i, 'body' * 4096]);
    }
  }
  exit(0);
}
