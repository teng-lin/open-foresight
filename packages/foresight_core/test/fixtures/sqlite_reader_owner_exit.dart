import '../sql_support_test_bootstrap.dart';
import 'package:foresight_core/src/persistence/sql_support.dart';
import 'dart:async';
import 'dart:isolate';

import 'package:foresight_core/src/read_coordinator.dart';
import 'package:foresight_core/src/platform_services.dart';
import 'package:foresight_core/src/sqlite_read_worker.dart';

Future<void> main(List<String> args) async {
  bootstrapSqlSupportFixture();
  final done = ReceivePort();
  await Isolate.spawn(_owner, (
    args.first,
    runtimeConfiguration.environment,
    done.sendPort,
    currentSqlSupportBootstrap,
  ));
  await done.first;
  done.close();
  // A leaked reader commands port would keep this entire process alive.
  print('owner dispatched and exited');
  // Keep the original supervised-owner oracle. The immediate-main-return
  // mode exposed the old Dart callback failure; native progress must now
  // settle it independently of the supervising VM's continued operation.
  if (!args.contains('immediate-main-return')) {
    await Future<void>.delayed(const Duration(seconds: 1));
  }
}

Future<void> _owner(
  (String, Map<String, String>, SendPort, SqlSupportBootstrap) args,
) async {
  final (path, environment, done, support) = args;
  bindSqlSupportBootstrap(support);
  final worker = SqliteReadWorker(
    path,
    environment: environment,
    executionBudget: const Duration(milliseconds: 100),
  );
  const identity = ReadIdentity(
    owner: 'fixture',
    profile: 'fixture',
    connection: 'fixture',
    epoch: 'fixture',
    revision: 'fixture',
  );
  ReadWorkerRequest read(String key) => ReadWorkerRequest(
    projection: 'preference',
    arguments: {'key': key},
    identity: identity,
    sequence: 1,
  );
  await worker.read(read('workspaceEpoch'));
  // The warmed worker synchronously dispatches this command. No close/kill is
  // sent; the reader must handle its owner's real exit after SQL settlement.
  unawaited(worker.read(read('slow')));
  Isolate.exit(done, true);
}
