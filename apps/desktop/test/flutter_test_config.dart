import 'dart:async';

import '../../../packages/foresight_core/test/sql_support_test_bootstrap.dart';

/// Every Flutter test process selects its explicit fixture before test main,
/// Store construction or worker spawning. Standalone subprocess tests keep
/// their independent bootstrap/absence controls.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  bootstrapSqlSupportFixture();
  await testMain();
}
