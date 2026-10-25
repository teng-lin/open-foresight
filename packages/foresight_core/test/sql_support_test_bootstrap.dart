import 'dart:io';

import 'package:foresight_core/persistence_bootstrap.dart';

/// Explicit fixture startup, called by the test's main before any Store or
/// isolate spawn. This is a test artifact input, never a production selector.
void bootstrapSqlSupportFixture() {
  final selected = Platform.environment['FORESIGHT_TEST_SQL_SUPPORT_LIBRARY'];
  if (selected == null || !File(selected).isAbsolute) {
    throw StateError(
      'Build foresight_sql_support and set FORESIGHT_TEST_SQL_SUPPORT_LIBRARY '
      'to that fresh absolute fixture library before running SQL tests',
    );
  }
  initializeSqliteRuntime(supportLibrary: selected);
}
