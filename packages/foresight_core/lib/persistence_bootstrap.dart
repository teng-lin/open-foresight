/// Startup-only persistence capability. Runtime owners validate the selected
/// support artifact before calling; features never select native code paths.
library;

import 'src/persistence/sql_support.dart';

/// Initialize the mandatory system-only SQL support image before ANY Store,
/// SQLite connection or application worker. The selected absolute path must
/// already have passed the embedding's runtime/artifact ownership checks.
///
/// Repeated calls with that exact selection reuse the original pinned image.
/// A changed selection, a worker-only binding or a missed gate fails closed.
void initializeSqliteRuntime({required String supportLibrary}) =>
    initializeSelectedSqlSupport(supportLibrary);
