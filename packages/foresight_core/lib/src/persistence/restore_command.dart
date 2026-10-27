import 'dart:convert';

import '../profile_paths.dart';
import '../store.dart' show Store;
import 'restore_activation.dart';

/// The offline restore utility's arguments, served by `foresight-service`.
/// The entrypoint prepares the runtime; nothing here bootstraps, logs or owns
/// a profile beyond [RestoreActivation]'s own offline profile lock.
const restoreUsage = '''
Usage: foresight-service --restore-list
       foresight-service --restore-activate=SNAPSHOT --accept-data-loss=SNAPSHOT
       foresight-service --restore-recover

Offline recovery for the profile selected by FORESIGHT_DATA (or the default
profile). Stop every Open Foresight service and reader first, and close any
other program that has the profile database open: activation refuses while the
profile is owned, a connection holds a SQLite lock on its database or a
deletion is still erasing backups, but it cannot detect an idle connection.
Changes after the snapshot's data-loss point leave the active profile and are
kept only in the displaced snapshot this command reports. Like every migration
snapshot it is kept at most seven days (fewer if two newer snapshots exist) and
is erased by a workspace clear or content deletion. The schema limit is this
build's: it also refuses a live profile newer than this build, so restore with
the newer installation before installing an older one. Binaries, helpers and
models are not rolled back. Until an interrupted activation is recovered, Open
Foresight refuses to open the profile.''';

/// Whether [arguments] ask for the restore utility rather than the service.
bool isRestoreInvocation(List<String> arguments) => arguments.any(
  (argument) =>
      argument.startsWith('--restore-') ||
      argument.startsWith('--accept-data-loss'),
);

/// A validated restore command line. Parsing needs no runtime, profile or
/// SQLite.
final class RestoreCommand {
  const RestoreCommand._(this.mode, [this.snapshot]);
  final String mode;
  final String? snapshot;

  /// Returns null with [error] written for usage errors and unconfirmed
  /// activations (exit 64); nothing is loaded or changed for them.
  static RestoreCommand? parse(List<String> arguments, StringSink error) {
    final options = <String, String>{};
    for (final argument in arguments) {
      final match = RegExp(r'^--([a-z-]+)(?:=(.*))?$').firstMatch(argument);
      if (match == null || options.containsKey(match[1])) {
        error.writeln(restoreUsage);
        return null;
      }
      options[match[1]!] = match[2] ?? '';
    }
    switch (options.keys.toList()..sort()) {
      case ['restore-list'] when options['restore-list']!.isEmpty:
        return const RestoreCommand._('list');
      case ['restore-recover'] when options['restore-recover']!.isEmpty:
        return const RestoreCommand._('recover');
      case ['restore-activate'] || ['accept-data-loss', 'restore-activate']:
        final name = options['restore-activate']!;
        if (name.isEmpty) break;
        if (options['accept-data-loss'] != name) {
          error.writeln(
            'Repeat the snapshot name as --accept-data-loss=$name to confirm '
            'that changes after its data-loss point leave the active profile. '
            'Nothing was changed.',
          );
          return null;
        }
        return RestoreCommand._('activate', name);
    }
    error.writeln(restoreUsage);
    return null;
  }
}

/// The utility after process startup: the entrypoint has prepared the
/// runtime. Returns its exit status (0, 75 profile owned, 1 other refusal).
Future<int> runRestoreProfile(
  RestoreCommand command,
  ProfilePaths profile,
  StringSink out,
  StringSink err,
) async {
  try {
    final activation = RestoreActivation(
      profile: profile,
      // The profile database name Store and the service open.
      databasePath: '${profile.data}/application.db',
      supportedVersion: Store.schemaVersion,
    );
    switch (command.mode) {
      case 'list':
        out.writeln(
          jsonEncode({
            'supported_schema': Store.schemaVersion,
            'snapshots': [
              for (final snapshot in activation.candidates())
                {
                  'name': snapshot.name,
                  'schema': snapshot.schema,
                  'data_loss_point': snapshot.created.toIso8601String(),
                  'sha256': snapshot.sha256,
                },
            ],
          }),
        );
      case 'recover':
        out.writeln(
          jsonEncode({
            'displaced_snapshots': [
              for (final snapshot in await activation.recover()) snapshot.name,
            ],
          }),
        );
      default:
        final name = command.snapshot!;
        final result = await activation.activate(name, acceptDataLossOf: name);
        out.writeln(jsonEncode(result.toJson()));
    }
  } on ActiveProfileOwner catch (error) {
    err.writeln(error.message);
    return 75;
  } on StateError catch (error) {
    err.writeln(error.message);
    return 1;
  } on ArgumentError catch (error) {
    err.writeln(error.message);
    return 1;
  } on Exception catch (error) {
    err.writeln(error);
    return 1;
  }
  return 0;
}
