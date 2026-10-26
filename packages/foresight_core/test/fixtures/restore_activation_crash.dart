import 'dart:io';

import 'package:foresight_core/src/persistence/restore_activation.dart';
import 'package:foresight_core/src/profile_paths.dart';
import 'package:foresight_core/src/store.dart' show Store;

import '../sql_support_test_bootstrap.dart';

/// Dies at a named activation stage, as a power loss or kill would, without
/// running any rollback. Arguments: data runtime snapshot stage.
Future<void> main(List<String> arguments) async {
  bootstrapSqlSupportFixture();
  final profile = ProfilePaths(arguments[0], arguments[1]);
  await RestoreActivation(
    profile: profile,
    databasePath: '${profile.data}/application.db',
    supportedVersion: Store.schemaVersion,
    checkpoint: (stage) {
      if (stage == arguments[3]) exit(79);
    },
  ).activate(arguments[2], acceptDataLossOf: arguments[2]);
  stdout.writeln('stage_not_reached');
}
