import 'dart:async';
import 'dart:io';
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
}
