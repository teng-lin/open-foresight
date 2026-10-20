import 'package:foresight_test_support/test_recording.dart';
import 'package:foresight_core/src/rpc_error.dart';
import 'package:foresight_core/src/application.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'dart:io';
import 'package:test/test.dart';
import 'package:foresight_core/foresight_core.dart';
import 'package:foresight_core/src/service.dart';
import 'package:foresight_core/src/generated/helper_control.pb.dart' as control;

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
        'FORESIGHT_MODEL_MANIFEST',
      ])
        key: runtimeConfiguration.environment.remove(key),
    };
    directory = createTestTempDirectorySync('of-idle-');
    profile = ProfilePaths('${directory.path}/data', '${directory.path}/run');
    service = await ApplicationService.start(profile);
    client = await ServiceClient.connect('${profile.runtime}/application.sock');
  });
  setUp(() {
    addTearDown(() async {
      await client.close();
      try {
        await service.close();
      } catch (_) {}
      directory.deleteSync(recursive: true);
      for (final entry in original.entries) {
        if (entry.value == null) {
          runtimeConfiguration.environment.remove(entry.key);
        } else {
          runtimeConfiguration.environment[entry.key] = entry.value!;
        }
      }
    });
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
      await client.call('security.attach_desktop', {
        'token': File('${profile.data}/.desktop-capability').readAsStringSync(),
      });
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
      if (Process.runSync('/usr/bin/id', ['-u']).stdout.toString().trim() ==
          '0') {
        markTestSkipped('root may remove the socket anyway');
        return;
      }
      // A cleanup fault: the owner can no longer remove its own socket.
      expect(
        Process.runSync('/bin/chmod', ['500', profile.runtime]).exitCode,
        0,
      );
      addTearDown(
        () => Process.runSync('/bin/chmod', ['700', profile.runtime]),
      );
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
          isA<RpcError>()
              .having((error) => error.code, 'code', RpcErrorCode.cancelled)
              .having(
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
          isA<RpcError>()
              .having((error) => error.code, 'code', RpcErrorCode.busy)
              .having(
                (error) => error.message,
                'message',
                contains('could not be verified'),
              ),
        ),
      );
      expect((await client.call('status') as Map)['pid'], pid);
      expect(
        FileSystemEntity.typeSync(service.path),
        isNot(FileSystemEntityType.notFound),
      );
      expect(
        File('${profile.data}/.application-endpoint.json').existsSync(),
        true,
      );
    },
  );
}
