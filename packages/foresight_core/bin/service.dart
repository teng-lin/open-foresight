import 'package:foresight_core/src/platform_services.dart';
import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:foresight_core/src/profile_paths.dart';
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
      final client = await ServiceClient.connect(
        serviceEndpoint(profile, record),
      );
      try {
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
        final state = await client.call('status') as Map;
        if (args.single == '--status') {
          stdout.writeln(jsonEncode(state));
        } else {
          final stopped = client.events.stream.drain<void>();
          if (!Process.killPid(state['pid'] as int, ProcessSignal.sigterm)) {
            throw StateError('Could not stop application service');
          }
          await stopped.timeout(const Duration(minutes: 30));
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
