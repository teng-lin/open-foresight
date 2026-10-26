import 'package:foresight_core/src/model_acquisition.dart'
    show runModelTransportWorker;
import 'package:foresight_core/src/platform_services.dart';
import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:foresight_core/src/profile_paths.dart';
import 'package:foresight_core/src/rpc_error.dart';
import 'package:foresight_core/src/service.dart';
import 'package:foresight_core/src/operations.dart';
import 'package:foresight_core/src/persistence/restore_command.dart';
import 'package:foresight_core/src/service_compatibility.dart';
import 'package:foresight_core/src/service_socket.dart' show probeSocketPath;

import 'package:foresight_core/src/diagnostic_bootstrap.dart';
import 'package:foresight_core/src/diagnostics/startup.dart';
import 'package:foresight_core/src/diagnostics/session.dart';
import 'package:foresight_core/src/diagnostics/storage_worker_dispatch.dart';

Future<void> main(List<String> args) async {
  final internal = DiagnosticWorkerInvocation.parse(args);
  if (internal.kind != DiagnosticWorkerInvocationKind.absent) {
    if (internal.kind != DiagnosticWorkerInvocationKind.valid) {
      exitCode = 64;
      return;
    }
    try {
      final selected = loadDiagnosticChildStartup(internal);
      exitCode = await runDiagnosticStorageWorker(
        functions: selected.functions,
        expectedParentPid: selected.expectedParentPid,
        nativeId: selected.nativeId,
        dartId: selected.dartId,
        catalogId: selected.catalogId,
        verifyBeforeHello: selected.verifyBeforeHello,
      );
    } catch (_) {
      exitCode = 65;
    }
    return;
  }
  if (args.any((arg) => arg.startsWith('--model-transport-worker'))) {
    if (args.length != 1 || args.single != '--model-transport-worker') {
      exitCode = 64;
      return;
    }
    await runModelTransportWorker();
    return;
  }
  if (isRestoreInvocation(args)) {
    await _runRestoreUtility(args);
    return;
  }
  IsolatedApplicationService? service;
  LoggingSession? diagnostics;
  try {
    final runtime = ApplicationRuntimeBootstrap.prepare(DiagnosticHost.service);
    diagnostics = await runtime.startDiagnostics(transient: args.isNotEmpty);
    final profile = ProfilePaths.resolve(runtimeConfiguration.environment);
    diagnostics.selectProfile(profile.data);
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
      final endpoint = serviceEndpoint(profile, record);
      ServiceClient client;
      try {
        client = await ServiceClient.connect(endpoint);
      } on SocketException {
        // Only this profile's valid record says anything about its owner:
        // an invalid one, such as one naming another profile, does not, and
        // its next start sets it aside (M2).
        if (mode != '--stop' || record is! EndpointValid) rethrow;
        // An owner that died without a clean shutdown leaves its record but
        // nothing listening; it already stopped, so --stop succeeds.
        if (_leftUnclean(profile)) {
          stderr.writeln(
            'The application service is not running; it stopped without a '
            'clean shutdown, its endpoint record remains, and the next start '
            'recovers its runtime.',
          );
          return;
        }
        if (!await _awaitOwnerWithoutSocket(profile, endpoint)) return;
        client = await ServiceClient.connect(endpoint);
      }
      try {
        final Map state;
        try {
          // A stalled owner must not hold an administrator forever (L1).
          state =
              await client
                      .call(Operation.status.wire, {
                        applicationClientVersionField: applicationApiVersion,
                      })
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
        validateApplicationApiVersion(
          Map<String, dynamic>.from(state),
          endpoint: client.endpoint,
        );
        if (mode == '--stop-if-idle') {
          final result =
              await client
                      .call(Operation.serviceStopIfIdle.wire, {
                        'token': File(
                          '${profile.data}/.desktop-capability',
                        ).readAsStringSync(),
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
      service = await IsolatedApplicationService.start(
        profile,
        diagnostics: diagnostics,
      );
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
  } finally {
    // Application/native cleanup must finish before logger close can request
    // a process exit to retire a held diagnostic FFI/isolate owner.
    await service?.close();
    final result = await diagnostics?.close();
    if (result?.requiresExplicitExit == true) exit(exitCode);
  }
}

/// The offline restore utility: transient, never a profile owner or
/// candidate. Arguments and the data-loss confirmation are validated before
/// any bootstrap, SQLite or profile access.
Future<void> _runRestoreUtility(List<String> args) async {
  final command = RestoreCommand.parse(args, stderr);
  if (command == null) {
    exitCode = 64;
    return;
  }
  LoggingSession? diagnostics;
  try {
    final runtime = ApplicationRuntimeBootstrap.prepare(DiagnosticHost.service);
    diagnostics = await runtime.startDiagnostics(transient: true);
    final profile = ProfilePaths.resolve(runtimeConfiguration.environment);
    diagnostics.selectProfile(profile.data);
    exitCode = await runRestoreProfile(command, profile, stdout, stderr);
  } catch (error) {
    stderr.writeln('The restore command could not start: $error');
    exitCode = 1;
  } finally {
    // The session's own bounded close; a logging problem never replaces the
    // utility's result or output.
    var explicit = false;
    try {
      explicit = (await diagnostics?.close())?.requiresExplicitExit == true;
    } catch (error) {
      stderr.writeln('Diagnostic logging did not shut down cleanly: $error');
      explicit = true;
    }
    if (explicit) {
      await stdout.flush();
      await stderr.flush();
      exit(exitCode);
    }
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
  // An owner ends its connections after its helper stops, but before it
  // closes its store, removes its sockets and endpoint record, and releases
  // the profile lock; report success only after that (L6).
  stderr.writeln(
    'Waiting for the application service'
    '${owner == null ? '' : ' (pid $owner)'} to release its profile.',
  );
  await requireProfileRelease(
    profile,
    owner,
    timeout: _releaseBound(current: current),
  );
  _warnIfUnclean(profile);
}

/// How long --stop waits for an owner to release its profile once its
/// connection ended: 30 s for a [current] owner, and the 30-minute
/// finalization bound for a released one. A test's shortened bound keeps
/// the ratio between the two.
Duration _releaseBound({required bool current}) {
  final scaled = int.tryParse(
    runtimeConfiguration['FORESIGHT_TEST_STOP_RELEASE_MS'] ?? '',
  );
  final bound = scaled == null
      ? const Duration(seconds: 30)
      : Duration(milliseconds: scaled);
  return current ? bound : bound * 60;
}

/// How long an owner that holds the profile lock without listening may
/// still be starting before --stop takes it for one that is stopping.
const _startingGrace = Duration(seconds: 3);

/// --stop found this profile's endpoint record and its lock held, but
/// nothing listening. The owner removed its socket while it stops: a
/// released owner does so at SIGTERM and may then finalize a recording for
/// up to 30 minutes, a current one just before it releases its profile. Or
/// it is still starting, which a socket that begins to answer tells. Returns
/// true if the owner serves after all, false once it released the profile.
Future<bool> _awaitOwnerWithoutSocket(
  ProfilePaths profile,
  String endpoint,
) async {
  final waited = Stopwatch()..start();
  final bound = _releaseBound(current: false);
  var stopping = false;
  void report() {
    if (stopping) return;
    stopping = true;
    stderr.writeln('The application service is already stopping.');
  }

  while (true) {
    if ((await probeSocketPath(endpoint))?.live ?? false) return true;
    if (profileReleased(profile)) {
      report();
      _warnIfUnclean(profile);
      return false;
    }
    if (!stopping && waited.elapsed >= _startingGrace) {
      report();
      stderr.writeln(
        'Waiting for the application service to release its profile.',
      );
    }
    if (waited.elapsed >= bound) {
      throw StateError(
        'The application service removed its socket but did not release '
        'its profile within ${bound.inMinutes} minutes.',
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}

/// The service stopped; tell the user its next start recovers.
void _warnIfUnclean(ProfilePaths profile) {
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
