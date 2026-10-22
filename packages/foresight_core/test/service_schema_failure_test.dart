import 'dart:async';
import 'dart:io';

import 'package:clock/clock.dart';
import 'package:foresight_core/foresight_core.dart';
import 'package:foresight_core/src/generated/helper_control.pb.dart' as control;
import 'package:foresight_core/src/rpc_error.dart';
import 'package:foresight_core/src/service.dart';
import 'package:foresight_test_support/helper_adoption.dart';
import 'package:foresight_test_support/poll.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:grpc/grpc.dart';
import 'package:test/test.dart';

void main() {
  for (final withEpoch in [false, true]) {
    test('streamed future schema is actionable ($withEpoch)', () async {
      final root = createTestTempDirectorySync('stream-schema-');
      final profile = ProfilePaths('${root.path}/data', '${root.path}/run');
      privateDirectory(profile.data);
      privateDirectory(profile.runtime);
      final environment = Map.of(runtimeConfiguration.environment);
      runtimeConfiguration.environment.removeWhere(
        (key, _) =>
            key.startsWith('FORESIGHT_') && key != 'FORESIGHT_SQLITE_LIBRARY',
      );
      final server = Server.create(
        services: [AdoptionRag(), AdoptionControl(control.State())],
      );
      ApplicationService? service;
      ServiceClient? client;
      StreamSubscription<Map<String, dynamic>>? events;
      final snapshots = <Map<String, dynamic>>[];
      var now = DateTime.utc(2026, 10, 21);
      void Function()? reevaluate;
      try {
        await server.serve(
          address: InternetAddress(
            '${profile.runtime}/helper.sock',
            type: InternetAddressType.unix,
          ),
          port: 0,
        );
        service = await ApplicationService.start(
          profile,
          clock: Clock(() => now),
          createTimer: (delay, callback) {
            reevaluate = callback;
            return Timer(const Duration(days: 1), callback);
          },
        );
        await service.ready;
        client = await ServiceClient.connect(service.path);
        await client.call('security.attach_desktop', {
          'token': File(
            '${profile.data}/.desktop-capability',
          ).readAsStringSync(),
        });
        for (final minutes in ['7', '9', '7']) {
          await client.call('preferences.set', {
            'key': 'serviceIdleMinutes',
            'value': minutes,
          });
          final status = await client.call('status') as Map;
          expect(
            (status['lifetime'] as Map)['idle_minutes'],
            double.parse(minutes),
          );
        }
        events = client.events.stream.listen((event) {
          if (event['event'] == 'changed') snapshots.add(event);
        });
        await Future<void>.delayed(Duration.zero);
        snapshots.clear();
        final store = service.domain.store;
        final epoch = store.workspaceEpoch;
        store.db.execute('PRAGMA user_version=${Store.schemaVersion + 1}');
        store.db.execute(
          'ALTER TABLE preferences RENAME TO future_preferences',
        );
        try {
          if (withEpoch) {
            // Exercise the real heartbeat independently of request settlement.
            await Future<void>.delayed(const Duration(milliseconds: 1100));
          } else {
            service.application.changed();
            await Future<void>.delayed(Duration.zero);
          }
          expect(snapshots, isEmpty);
          // No epoch bypasses the admission read and reaches the streamed
          // answer path. Both paths must preserve the schema failure code.
          await expectLater(
            client.stream('answer.stream', {
              'question': 'What changed?',
              if (withEpoch) 'workspace_epoch': epoch,
            }),
            emitsError(
              isA<RpcError>()
                  .having(
                    (error) => error.code,
                    'code',
                    RpcErrorCode.unavailable,
                  )
                  .having(
                    (error) => error.message,
                    'message',
                    contains('Update Open Foresight'),
                  ),
            ),
          );
          expect(service.dispatchedCount, 0);
          reevaluate!();
        } finally {
          store.db.execute(
            'ALTER TABLE future_preferences RENAME TO preferences',
          );
          store.db.execute('PRAGMA user_version=${Store.schemaVersion}');
        }
        // Retirement lasts for this owner, even if the database is restored.
        store.setPreference('serviceIdleMinutes', '11');
        final status = await client.call('status') as Map;
        expect((status['lifetime'] as Map)['idle_minutes'], 7.0);
        service.application.changed();
        await Future<void>.delayed(Duration.zero);
        expect(snapshots, isEmpty);
        store.db.execute('PRAGMA user_version=${Store.schemaVersion + 1}');
        store.db.execute(
          'ALTER TABLE preferences RENAME TO future_preferences',
        );
        await client.close();
        await eventually(() => service!.desktopShutdownScheduled);
        final departure = service.lastDesktopDeparture;
        now = now.add(const Duration(milliseconds: 500));
        reevaluate!();
        expect(service.lastDesktopDeparture, departure);
        expect(File(service.path).existsSync(), isTrue);
        now = now.add(const Duration(milliseconds: 501));
        reevaluate!();
        await service.closed.timeout(const Duration(seconds: 3));
        expect(File(service.path).existsSync(), isFalse);
      } finally {
        await events?.cancel();
        await client?.close();
        await service?.close();
        await server.shutdown();
        runtimeConfiguration.environment
          ..clear()
          ..addAll(environment);
      }
    });
  }
}
