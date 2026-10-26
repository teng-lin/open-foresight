/// Startup-only persistence capability. Runtime owners validate the selected
/// support artifact before calling; features never select native code paths.
library;

import 'src/persistence/sql_support.dart';
import 'src/persistence/sqlite_runtime.dart' show prepareSqliteRuntimeEarly;

/// Opaque original-code handoff from the process entrypoint to its isolates.
/// Contains no database or native context pointer and exposes no code addresses.
/// Send this record before worker entry and bind it before any database access.
final class SqliteRuntimeBootstrap {
  final SqlSupportBootstrap _support;
  const SqliteRuntimeBootstrap._(this._support);
}

/// Initialize the mandatory system-only SQL support image at the process
/// entrypoint, before ANY Store, SQLite connection or application worker.
/// The selected absolute path must already have passed the embedding's
/// runtime/artifact ownership checks.
///
/// The entrypoint owns loading. Pass the returned opaque record to every owned
/// isolate and call [bindSqliteRuntime] there instead of initializing a path.
/// Repeated calls in this isolate reuse its exact original selection; a worker
/// binding or changed selection refuses before loading. This Dart guard is
/// isolate-local: it cannot prevent an arbitrary unbound isolate from violating
/// the embedding's process-entrypoint-only loading contract.
SqliteRuntimeBootstrap initializeSqliteRuntime({
  required String supportLibrary,
}) {
  initializeSelectedSqlSupport(supportLibrary);
  prepareSqliteRuntimeEarly();
  return SqliteRuntimeBootstrap._(currentSqlSupportBootstrap);
}

/// Bind the entrypoint's original pinned code in an owned fresh isolate.
/// No library open, symbol lookup, environment selector or fallback occurs.
/// A different record or missed handoff refuses before SQLite can open.
void bindSqliteRuntime(SqliteRuntimeBootstrap bootstrap) =>
    bindSqlSupportBootstrap(bootstrap._support);
