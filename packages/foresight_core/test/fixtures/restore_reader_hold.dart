import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:foresight_core/src/persistence/sqlite_runtime.dart';
import 'package:foresight_core/src/store.dart';

import '../sql_support_test_bootstrap.dart';

/// `read DATABASE` holds an open read transaction until stdin closes, as an
/// application reader outside the profile lock would.
///
/// `write DATABASE TRIGGER` and `write-raw DATABASE TRIGGER` are writers that
/// arrive during activation: once TRIGGER exists they save one note, through
/// the application Store or through a plain SQLite connection in WAL mode
/// that bypasses Store. They report `written` or `refused: <error>` in
/// TRIGGER.result, then keep any open connection until stdin closes.
///
/// `sql DATABASE TRIGGER STATEMENT` runs STATEMENT on a plain connection once
/// TRIGGER exists, closes it, then reports in TRIGGER.result and exits.
///
/// `idle DATABASE rw|ro` opens a plain connection, reads once and prints
/// `idle`, holding no transaction. Each stdin line is then a command, answered
/// on one stdout line: `read`, `write` (insert one note), `wal-write`
/// (journal_mode=WAL, then insert), `hold-write` (insert inside an open
/// transaction, never committed) or `close`.
Future<void> main(List<String> arguments) async {
  bootstrapSqlSupportFixture();
  switch (arguments.first) {
    case 'write' || 'write-raw':
      await _write(
        arguments[1],
        arguments[2],
        raw: arguments.first == 'write-raw',
      );
    case 'sql':
      await _sql(arguments[1], arguments[2], arguments[3]);
    case 'idle':
      await _idle(arguments[1], readOnly: arguments[2] == 'ro');
    default:
      await _read(arguments[1]);
  }
}

Future<void> _read(String path) async {
  final db = openApplicationDatabase(path);
  try {
    db.execute('BEGIN');
    db.select('SELECT COUNT(*) FROM notes');
    stdout.writeln('holding');
    await stdin.transform(utf8.decoder).drain<void>();
    db.execute('COMMIT');
    stdout.writeln(
      'journal_mode=${db.select('PRAGMA journal_mode').single.values.single}',
    );
  } finally {
    db.dispose();
  }
}

Future<void> _await(String trigger) async {
  stdout.writeln('ready');
  final clock = Stopwatch()..start();
  while (!File(trigger).existsSync()) {
    if (clock.elapsed > const Duration(minutes: 2)) exit(3);
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void _report(String trigger, String outcome) {
  File('$trigger.partial').writeAsStringSync(outcome, flush: true);
  File('$trigger.partial').renameSync('$trigger.result');
}

Future<void> _write(String path, String trigger, {required bool raw}) async {
  await _await(trigger);
  void Function()? close;
  String outcome;
  try {
    if (raw) {
      final db = openApplicationDatabase(path);
      close = db.dispose;
      db.execute('PRAGMA journal_mode=WAL');
      db.execute(
        "INSERT INTO notes(title,body,timestamp) VALUES('Late writer','late writer content',0)",
      );
    } else {
      final store = Store(path);
      close = store.close;
      store.saveNote(null, 'Late writer', 'late writer content');
    }
    outcome = 'written';
  } catch (error) {
    close?.call();
    close = null;
    outcome = 'refused: $error';
  }
  _report(trigger, outcome);
  await stdin.transform(utf8.decoder).drain<void>();
  close?.call();
}

Future<void> _sql(String path, String trigger, String statement) async {
  await _await(trigger);
  String outcome;
  final db = openApplicationDatabase(path);
  try {
    db.execute(statement);
    outcome = 'written';
  } catch (error) {
    outcome = 'refused: $error';
  } finally {
    db.dispose();
  }
  _report(trigger, outcome);
}

Future<void> _idle(String path, {required bool readOnly}) async {
  final db = openApplicationDatabase(
    path,
    mode: readOnly ? OpenMode.readOnly : OpenMode.readWrite,
  );
  db.select('SELECT COUNT(*) FROM notes');
  stdout.writeln('idle');
  String attempt(void Function() write) {
    try {
      write();
      return 'written';
    } on SqliteException catch (error) {
      return 'refused: ${error.extendedResultCode} ${error.message}';
    }
  }

  const insert =
      "INSERT INTO notes(title,body,timestamp) VALUES('Idle writer','idle writer content',0)";
  await for (final line
      in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
    switch (line) {
      case 'read':
        stdout.writeln(
          jsonEncode([
            for (final row in db.select('SELECT body FROM notes ORDER BY id'))
              row['body'],
          ]),
        );
      case 'write':
        stdout.writeln(attempt(() => db.execute(insert)));
      case 'wal-write':
        stdout.writeln(
          attempt(() {
            db.execute('PRAGMA journal_mode=WAL');
            db.execute(insert);
          }),
        );
      case 'hold-write':
        stdout.writeln(
          attempt(() {
            db.execute('BEGIN IMMEDIATE');
            db.execute(insert);
          }),
        );
      case 'close':
        db.dispose();
        stdout.writeln('closed');
        return;
    }
  }
  db.dispose();
}
