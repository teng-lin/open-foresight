import 'dart:io';
import 'package:test/test.dart';
import 'package:foresight_core/foresight_core.dart';
import 'package:foresight_core/src/service.dart';
import 'package:foresight_core/src/generated/helper_control.pb.dart' as control;

class TestRecording extends Recording {
  TestRecording()
    : super(
        Platform.isMacOS ? '/usr/lib/libSystem.B.dylib' : 'libc.so.6',
        (_) {},
        (_, _, _, _) {},
      );
}

void main() {
  late Directory directory;
  late ProfilePaths profile;
  late ApplicationService service;
  late ServiceClient client;
  late Map<String, String?> original;
  setUp(() async {
    original = {
      for (final key in [
        'FORESIGHT_HELPER',
        'FORESIGHT_NATIVE',
        'FORESIGHT_RUNTIME_REVISION',
        'FORESIGHT_INSTALL_ROOT',
      ])
        key: runtimeConfiguration.environment.remove(key),
    };
    directory = Directory('/tmp').createTempSync('of-idle-');
    profile = ProfilePaths('${directory.path}/data', '${directory.path}/run');
    service = await ApplicationService.start(profile);
    client = await ServiceClient.connect('${profile.runtime}/application.sock');
  });
  tearDown(() async {
    await client.close();
    try {
      await service.close();
    } catch (_) {
      /* Failure-path tests deliberately close invalid resources. */
    }
    directory.deleteSync(recursive: true);
    for (final entry in original.entries) {
      if (entry.value == null) {
        runtimeConfiguration.environment.remove(entry.key);
      } else {
        runtimeConfiguration.environment[entry.key] = entry.value!;
      }
    }
  });

  test(
    'idle shutdown acknowledges only after cleanup and rejects a following mutation',
    () async {
      final stopped = client.call('service.stop_if_idle');
      final rejected = expectLater(
        client.call('meetings.create', {'title': 'must not commit'}),
        throwsA(isA<StateError>()),
      );
      expect(await stopped, {'stopped': true, 'shutdown_verified': true});
      await rejected;
      expect(
        FileSystemEntity.typeSync('${profile.runtime}/application.sock'),
        FileSystemEntityType.notFound,
      );
      final store = Store.readOnly('${profile.data}/application.db');
      try {
        expect(store.rows('SELECT * FROM meetings'), isEmpty);
      } finally {
        store.close();
      }
      await service.closed;
    },
  );

  test(
    'active or finishing capture is never stopped by idle shutdown',
    () async {
      final recording = TestRecording();
      service.domain.application.recording = recording;
      try {
        for (final finishing in [false, true]) {
          recording.finishing = finishing;
          await expectLater(
            client.call('service.stop_if_idle'),
            throwsA(
              isA<StateError>().having(
                (error) => error.message,
                'message',
                contains('final transcript'),
              ),
            ),
          );
          expect(service.domain.application.recording, same(recording));
          expect(
            (await client.call('status') as Map)['capture']['active'],
            true,
          );
        }
      } finally {
        service.domain.application.recording = null;
      }
      expect(
        (await client.call('service.stop_if_idle') as Map)['stopped'],
        true,
      );
    },
  );

  test(
    'a recording request awaiting readiness prevents idle shutdown acceptance',
    () async {
      final id = service.domain.store.meeting('competing start');
      final recording = client
          .stream('meetings.start', {'id': id})
          .listen((_) {}, onError: (Object _) {});
      try {
        await expectLater(
          client.call('service.stop_if_idle'),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              contains('operations are in progress'),
            ),
          ),
        );
        expect((await client.call('status') as Map)['pid'], pid);
      } finally {
        await recording.cancel();
      }
    },
  );

  test(
    'shutdown errors are explicit failure responses rather than successful EOF',
    () async {
      File('${profile.runtime}/application.sock').deleteSync();
      Directory('${profile.runtime}/application.sock').createSync();
      File(
        '${profile.runtime}/application.sock/blocked',
      ).writeAsStringSync('cleanup fault');
      await expectLater(
        client.call('service.stop_if_idle'),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('shutdown failed'),
          ),
        ),
      );
      await service.closed;
    },
  );

  test(
    'idle shutdown pins authenticated service ownership without closing a replacement',
    () async {
      await expectLater(
        client.call('service.stop_if_idle', {'expected_pid': pid + 1}),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('ownership changed'),
          ),
        ),
      );
      expect((await client.call('status') as Map)['pid'], pid);
    },
  );

  test(
    'unverified adopted helper shutdown cannot certify an upgrade',
    () async {
      service.domain.helper.snapshot = control.State(instanceId: '0-1');
      await expectLater(
        client.call('service.stop_if_idle'),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('could not be verified'),
          ),
        ),
      );
      expect(
        File('${profile.data}/.application-endpoint.json').existsSync(),
        true,
      );
    },
  );
}
