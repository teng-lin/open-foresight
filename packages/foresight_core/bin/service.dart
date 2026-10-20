import 'package:foresight_core/src/platform_services.dart';
import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:foresight_core/src/profile_paths.dart';
import 'package:foresight_core/src/rpc_error.dart';
import 'package:foresight_core/src/service.dart';

Future<void> main(List<String> args) async {
  IsolatedApplicationService? service;
  try {
    final profile = ProfilePaths.resolve(runtimeConfiguration.environment);
    if (args.isNotEmpty) {
      if (args.length != 1) {
        throw ArgumentError(
          'Usage: foresight-service [--status|--stop|--stop-if-idle[=PID]]',
        );
      }
      final mode = args.single.split('=').first;
      final expectedPid = args.single.startsWith('--stop-if-idle=')
          ? int.tryParse(args.single.substring('--stop-if-idle='.length))
          : null;
      if (args.length != 1 ||
          !['--status', '--stop', '--stop-if-idle'].contains(mode) ||
          (args.single.contains('=') &&
              (mode != '--stop-if-idle' ||
                  expectedPid == null ||
                  expectedPid <= 0))) {
        throw ArgumentError(
          'Usage: foresight-service [--status|--stop|--stop-if-idle[=PID]]',
        );
      }
      final record = readEndpointRecord(profile);
      if (record is EndpointInvalid) {
        stderr.writeln(
          'The application endpoint record '
          '${profile.data}/.application-endpoint.json was ignored because '
          '${record.reason}.',
        );
      }
      final ServiceClient client;
      try {
        client = await ServiceClient.connect(serviceEndpoint(profile, record));
      } on SocketException {
        // An owner that died without a clean shutdown leaves its record but
        // nothing listening; it already stopped, so --stop succeeds. Only
        // this profile's valid record says so: an invalid one, such as one
        // naming another profile, says nothing about this profile's owner,
        // and its next start sets it aside (M2).
        if (mode != '--stop' ||
            record is! EndpointValid ||
            !_leftUnclean(profile)) {
          rethrow;
        }
        stderr.writeln(
          'The application service is not running; it stopped without a '
          'clean shutdown, its endpoint record remains, and the next start '
          'recovers its runtime.',
        );
        return;
      }
      try {
        final Map state;
        try {
          // A stalled owner must not hold an administrator forever (L1).
          state =
              await client
                      .call('status')
                      .timeout(
                        _statusProbeLimit,
                        onTimeout: () => throw TimeoutException(
                          'Application service at ${client.endpoint} '
                          'accepted the connection but did not answer '
                          'status within ${_statusProbeLimit.inSeconds} s; '
                          'it may be busy or hung.',
                        ),
                      )
                  as Map;
        } on RpcError catch (error) {
          // An owner that is already stopping refuses the probe. Nothing
          // is signalled; --stop waits for it like for one it stopped.
          if (mode != '--stop' || !closingOwnerEndedProbe(error)) rethrow;
          stderr.writeln('The application service is already stopping.');
          await _awaitStopped(
            profile,
            client.events.stream.drain<void>(),
            null,
            // Only owners with profile identity send the reason.
            current: error.reason != null,
          );
          return;
        }
        // Never report on, stop or signal another profile's owner (SL-7).
        if (servesAnotherProfile(state, profile, client.endpoint)) {
          final owner = state['pid'];
          throw AnotherProfileServing(
            anotherProfileMessage(
              profile,
              client.endpoint,
              fromRecord: record is EndpointValid,
              pid: owner is int ? owner : null,
            ),
          );
        }
        if (mode == '--stop-if-idle') {
          final result =
              await client
                      .call('service.stop_if_idle', {
                        if (expectedPid != null) 'expected_pid': expectedPid,
                        if (configuredInstallationRoot != null)
                          'installation_root': configuredInstallationRoot,
                        if (runtimeConfiguration['FORESIGHT_RUNTIME_REVISION'] !=
                            null)
                          'runtime_revision':
                              runtimeConfiguration['FORESIGHT_RUNTIME_REVISION'],
                      })
                      .timeout(const Duration(minutes: 30))
                  as Map?;
          if (result?['stopped'] != true ||
              result?['shutdown_verified'] != true) {
            throw StateError(
              'The service did not acknowledge a verified idle shutdown.',
            );
          }
          stdout.writeln(jsonEncode(result));
          return;
        }
        if (args.single == '--status') {
          stdout.writeln(jsonEncode(state));
        } else {
          final owner = state['pid'] as int;
          final stopped = client.events.stream.drain<void>();
          if (!Process.killPid(owner, ProcessSignal.sigterm)) {
            throw StateError('Could not stop application service');
          }
          await _awaitStopped(
            profile,
            stopped,
            owner,
            current: state['profile_id'] != null,
          );
        }
      } finally {
        await client.close();
      }
      return;
    }
    try {
      service = await IsolatedApplicationService.start(profile);
    } catch (error) {
      // A detached launch has no stderr; tell the launcher why (L3).
      recordServiceStartupFailure(profile, error);
      rethrow;
    }
    final done = Completer<void>();
    final signals = [
      ProcessSignal.sigterm.watch().listen((_) {
        if (!done.isCompleted) done.complete();
      }),
      ProcessSignal.sigint.watch().listen((_) {
        if (!done.isCompleted) done.complete();
      }),
    ];
    await Future.any([done.future, service.closed]);
    for (final signal in signals) {
      await signal.cancel();
    }
    await service.close();
  } catch (error, stack) {
    stderr.writeln('$error\n$stack');
    exitCode = 1;
  }
}

/// The bound on a status probe, as clients have.
const _statusProbeLimit = Duration(seconds: 30);

/// Wait until the stopping owner [owner] (null if it refused its status)
/// ended this connection ([ended]) and then released its profile, and warn
/// if it stopped without a clean shutdown. A [current] owner, one with
/// profile identity, ends its connections only after it finished its work,
/// recording finalization included. A released owner ends them at SIGTERM
/// and may finalize a recording for up to 30 minutes after.
Future<void> _awaitStopped(
  ProfilePaths profile,
  Future<void> ended,
  int? owner, {
  required bool current,
}) async {
  await ended.timeout(const Duration(minutes: 30));
  // The connection closes before the helper stops and the profile lock is
  // released; report success only after that (L6).
  stderr.writeln(
    'Waiting for the application service'
    '${owner == null ? '' : ' (pid $owner)'} to release its profile.',
  );
  final scaled = int.tryParse(
    runtimeConfiguration['FORESIGHT_TEST_STOP_RELEASE_MS'] ?? '',
  );
  final bound = scaled == null
      ? const Duration(seconds: 30)
      : Duration(milliseconds: scaled);
  // A test's shortened bound keeps the ratio between the two.
  await requireProfileRelease(
    profile,
    owner,
    timeout: current ? bound : bound * 60,
  );
  // The service stopped; tell the user its next start recovers.
  if (_leftUnclean(profile)) {
    stderr.writeln(
      'The application service stopped without a clean shutdown; its '
      'endpoint record remains, and the next start recovers its runtime.',
    );
  }
}

/// Whether the profile's last owner stopped without a clean shutdown. This
/// only chooses a warning, so a failed check never fails `--stop`.
bool _leftUnclean(ProfilePaths profile) {
  try {
    return profileLeftUnclean(profile);
  } catch (error) {
    stderr.writeln('Cannot check how the service stopped: $error');
    return false;
  }
}
