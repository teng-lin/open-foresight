import '../sql_support_test_bootstrap.dart';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:sqlite3/open.dart' as loader;
import 'package:sqlite3/sqlite3.dart' as upstream;
import 'package:foresight_core/src/persistence/sqlite_runtime.dart' as selected;

void main(List<String> arguments) {
  if (arguments.contains('preload-system')) {
    loader.open.overrideFor(
      loader.OperatingSystem.macOS,
      () => DynamicLibrary.open('/usr/lib/libsqlite3.dylib'),
    );
    stdout.writeln('Preloaded ${upstream.sqlite3.version}');
  }
  bootstrapSqlSupportFixture();
  final db = selected.sqlite3.openInMemory();
  try {
    stdout.writeln(
      jsonEncode(
        db
            .select(
              'SELECT sqlite_version() AS version, sqlite_source_id() AS source_id',
            )
            .single,
      ),
    );
  } finally {
    db.dispose();
  }
}
