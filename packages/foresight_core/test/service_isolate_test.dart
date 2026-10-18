import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:foresight_test_support/poll.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:foresight_core/foresight_core.dart';
import 'package:foresight_core/src/service.dart';
import 'package:test/test.dart';

void main() {
  test(
    'isolated domain preserves multiplexing, committed writes and idle shutdown acknowledgement',
    () async {
      final saved = Map<String, String>.from(runtimeConfiguration.environment);
      for (final key in [
        'FORESIGHT_HELPER',
        'FORESIGHT_NATIVE',
        'FORESIGHT_INSTALL_ROOT',
        'FORESIGHT_RUNTIME_REVISION',
        'FORESIGHT_MODEL_MANIFEST',
      ]) {
        runtimeConfiguration.environment.remove(key);
      }
      runtimeConfiguration.environment['FORESIGHT_SERVICE_TRACE'] = '1';
      final directory = Directory.systemTemp.createTempSync(
        'isolated-service-',
      );
      final profile = ProfilePaths(
        '${directory.path}/data',
        '${directory.path}/run',
      );
      final host = await IsolatedApplicationService.start(profile);
      ServiceClient? client;
      try {
        client = await ServiceClient.connect(serviceEndpoint(profile));
        final status = await client.call('status') as Map;
        expect(status['pid'], pid);
        final events = <Map<String, dynamic>>[];
        final subscription = client.events.stream.listen(events.add);
        final first = await client.call('notes.save', {
          'title': 'Worker-owned note',
          'body': 'Saved on the domain isolate',
        });
        expect(first, isA<Map>());
        final results = await Future.wait([
          client.call('notes.list'),
          client.call('status'),
        ]);
        expect(
          (results.first as List).single['body'],
          'Saved on the domain isolate',
        );
        final stopped = await client.call('service.stop_if_idle');
        expect(stopped, {'stopped': true, 'shutdown_verified': true});
        await host.closed.timeout(const Duration(seconds: 10));
        expect(File('${profile.runtime}/application.sock').existsSync(), false);
        expect(
          File('${profile.runtime}/application-worker.sock').existsSync(),
          false,
        );
        await subscription.cancel();
      } finally {
        await client?.close();
        await host.close();
        directory.deleteSync(recursive: true);
        runtimeConfiguration.environment
          ..clear()
          ..addAll(saved);
      }
    },
  );
  test(
    'explicit shutdown disconnects clients before the worker finishes cleanup',
    () async {
      final saved = Map<String, String>.from(runtimeConfiguration.environment);
      for (final key in [
        'FORESIGHT_NATIVE',
        'FORESIGHT_INSTALL_ROOT',
        'FORESIGHT_RUNTIME_REVISION',
        'FORESIGHT_MODEL_MANIFEST',
      ]) {
        runtimeConfiguration.environment.remove(key);
      }
      final directory = shortTestTempRoot.createTempSync('of-shutdown-');
      final started = File('${directory.path}/started');
      final stopping = File('${directory.path}/stopping');
      final release = File('${directory.path}/release');
      final helper = File('${directory.path}/helper-fixture');
      helper.writeAsStringSync('''#!/usr/bin/env python3
import os,pathlib,signal,time
started=pathlib.Path(${jsonEncode(started.path)})
stopping=pathlib.Path(${jsonEncode(stopping.path)})
release=pathlib.Path(${jsonEncode(release.path)})
def shutdown(signum, frame):
 stopping.touch()
 while not release.exists(): time.sleep(.005)
 raise SystemExit(0)
signal.signal(signal.SIGTERM,shutdown)
started.write_text(str(os.getpid()))
while True: signal.pause()
''');
      await Process.run('/bin/chmod', ['700', helper.path]);
      runtimeConfiguration.environment['FORESIGHT_HELPER'] = helper.path;
      final profile = ProfilePaths(
        '${directory.path}/data',
        '${directory.path}/run',
      );
      IsolatedApplicationService? host;
      ServiceClient? client;
      try {
        host = await IsolatedApplicationService.start(profile);
        client = await ServiceClient.connect(serviceEndpoint(profile));
        expect(await client.call('status'), isA<Map>());
        await eventually(() => started.existsSync());
        final disconnected = client.events.stream.drain<void>();
        var workerClosed = false;
        unawaited(host.closed.then((_) => workerClosed = true));
        final shutdown = host.close();
        await eventually(() => stopping.existsSync());
        expect(
          workerClosed,
          isFalse,
          reason: 'The helper still holds worker cleanup',
        );
        await disconnected.timeout(const Duration(seconds: 1));
        expect(client.isClosed, isTrue);
        final rejected = await ServiceClient.connect(serviceEndpoint(profile));
        try {
          await rejected.events.stream.drain<void>().timeout(
            const Duration(seconds: 1),
          );
          expect(rejected.isClosed, isTrue);
        } finally {
          await rejected.close();
        }
        release.writeAsStringSync('release');
        await shutdown.timeout(const Duration(seconds: 10));
      } finally {
        release.writeAsStringSync('release');
        await client?.close();
        await host?.close();
        directory.deleteSync(recursive: true);
        runtimeConfiguration.environment
          ..clear()
          ..addAll(saved);
      }
    },
  );
}
