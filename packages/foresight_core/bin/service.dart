import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:foresight_core/src/profile_paths.dart';
import 'package:foresight_core/src/service.dart';

Future<void> main(List<String> args) async {
  ApplicationService? service;
  try {
    if (args.isNotEmpty) {
      if (args.length != 1 || !['--status', '--stop'].contains(args.single))
        throw ArgumentError('Usage: foresight-service [--status|--stop]');
      final profile = ProfilePaths.resolve(Platform.environment);
      final client = await ServiceClient.connect(serviceEndpoint(profile));
      try {
        final state = await client.call('status') as Map;
        if (args.single == '--status') {
          stdout.writeln(jsonEncode(state));
        } else {
          final stopped = client.events.stream.drain<void>();
          if (!Process.killPid(state['pid'] as int, ProcessSignal.sigterm))
            throw StateError('Could not stop application service');
          await stopped.timeout(const Duration(minutes: 30));
        }
      } finally {
        await client.close();
      }
      return;
    }
    service = await ApplicationService.start(
      ProfilePaths.resolve(Platform.environment),
    );
    final done = Completer<void>();
    final signals = [
      ProcessSignal.sigterm.watch().listen((_) {
        if (!done.isCompleted) done.complete();
      }),
      ProcessSignal.sigint.watch().listen((_) {
        if (!done.isCompleted) done.complete();
      }),
    ];
    await done.future;
    for (final signal in signals) {
      await signal.cancel();
    }
    await service.close();
  } catch (error, stack) {
    stderr.writeln('$error\n$stack');
    exitCode = 1;
  }
}
