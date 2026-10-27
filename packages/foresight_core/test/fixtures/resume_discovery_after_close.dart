import '../sql_support_test_bootstrap.dart';
import 'dart:async';
import 'dart:io';

import 'package:foresight_core/src/domain.dart';
import 'package:foresight_core/src/helper.dart';
import 'package:foresight_core/src/native.dart';
import 'package:foresight_core/src/rpc_error.dart';
import 'package:foresight_core/src/store.dart';

// Keep an unsafe native-handle regression in a child process: an old resume
// path can crash in SQLite rather than reporting a catchable Dart exception.
Future<void> main(List<String> arguments) async {
  bootstrapSqlSupportFixture();
  final root = arguments.single;
  final store = Store('$root/app.db');
  final helper = Helper(
    '$root/helper.sock',
    '$root/helper',
    manageProcess: false,
  );
  final entered = Completer<void>();
  final release = Completer<NativeRuntime?>();
  final domain = Domain(
    store,
    helper,
    discoverGeneration: (_, _, {current, onCandidate, retire}) {
      entered.complete();
      return release.future;
    },
  );
  var storeClosed = false;
  try {
    final pending = domain.resume();
    await entered.future;
    domain.close();
    store.close();
    storeClosed = true;
    release.complete(null);
    try {
      await pending;
      throw StateError('A closed workspace resumed');
    } on RpcError catch (error) {
      if (error.code != RpcErrorCode.cancelled) rethrow;
      stdout.writeln('cancelled-before-closed-store-read');
    }
  } finally {
    if (!release.isCompleted) release.complete(null);
    domain.close();
    await helper.close();
    if (!storeClosed) store.close();
  }
}
