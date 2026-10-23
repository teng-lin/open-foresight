import 'package:foresight_test_support/desktop_identity.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:foresight_core/foresight_core.dart';
import 'package:foresight_core/src/generated/helper_control.pb.dart' as control;
import 'package:foresight_core/src/service.dart';
import 'package:foresight_core/src/rpc_error.dart';
import 'package:foresight_test_support/helper_adoption.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:grpc/grpc.dart';
import 'package:test/test.dart';

// Synchronize a real competing socket publication at the filesystem commit
// boundary, as the existing endpoint-record fixtures synchronize I/O faults.
class _RecordPublication extends IOOverrides {
  _RecordPublication(this.temporary, this.publishOther);
  final String temporary;
  final void Function() publishOther;

  @override
  File createFile(String path) => path == temporary
      ? _AfterRecordRename(super.createFile(path), publishOther)
      : super.createFile(path);
}

class _AfterRecordRename implements File {
  _AfterRecordRename(this.delegate, this.afterRename);
  final File delegate;
  final void Function() afterRename;

  @override
  String get path => delegate.path;

  @override
  void writeAsStringSync(
    String contents, {
    FileMode mode = FileMode.write,
    Encoding encoding = utf8,
    bool flush = false,
  }) => delegate.writeAsStringSync(
    contents,
    mode: mode,
    encoding: encoding,
    flush: flush,
  );

  @override
  File renameSync(String newPath) {
    final result = delegate.renameSync(newPath);
    afterRename();
    return result;
  }

  @override
  void deleteSync({bool recursive = false}) =>
      delegate.deleteSync(recursive: recursive);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late Directory root;
  late ProfilePaths profile;
  setUp(() async {
    root = createTestTempDirectorySync('shutdown-boundary-');
    profile = ProfilePaths('${root.path}/data', '${root.path}/run');
    privateDirectory(profile.data);
    privateDirectory(profile.runtime);
    final saved = Map.of(runtimeConfiguration.environment);
    runtimeConfiguration.environment.removeWhere(
      (key, _) =>
          key.startsWith('FORESIGHT_') &&
          key != 'FORESIGHT_NATIVE' &&
          key != 'FORESIGHT_SQLITE_LIBRARY',
    );
    addTearDown(() {
      runtimeConfiguration.environment
        ..clear()
        ..addAll(saved);
    });
    final helper = Server.create(
      services: [
        AdoptionRag(),
        // This controlled peer has no owned OS process. The real native
        // ownership check must classify this absent PID as gone, not signal it.
        AdoptionControl(control.State(instanceId: '999999999-1')),
      ],
    );
    await helper.serve(
      address: InternetAddress(
        '${profile.runtime}/helper.sock',
        type: InternetAddressType.unix,
      ),
      port: 0,
    );
    addTearDown(helper.shutdown);
  });

  test(
    'failed frontend release settles clients and unlocks the recoverable profile exactly once',
    () async {
      final reached = Completer<void>(), release = Completer<void>();
      var releases = 0;
      final service = await ApplicationService.start(
        profile,
        desktopPeerVerifier: trustInProcessDesktop,
        beforeReleaseOwnership: () async {
          releases++;
          reached.complete();
          await release.future;
          throw StateError('frontend cleanup rejected');
        },
      );
      addTearDown(() async {
        if (!release.isCompleted) release.complete();
        await expectLater(
          service.close(),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'cleanup failure',
              contains('frontend cleanup rejected'),
            ),
          ),
        );
      });
      await service.ready;
      final client = await ServiceClient.connect(service.path);
      addTearDown(client.close);
      final status = await client.call('status') as Map;
      expect(status['profile_id'], profile.identity);
      final record = File('${profile.data}/.application-endpoint.json');
      expect(record.existsSync(), isTrue);
      final failure = isA<StateError>().having(
        (error) => error.message,
        'failure',
        contains('frontend cleanup rejected'),
      );
      final first = expectLater(service.close(), throwsA(failure));
      final second = expectLater(service.close(), throwsA(failure));
      try {
        await reached.future.timeout(const Duration(seconds: 10));
        await client.closed.timeout(const Duration(seconds: 5));
        expect(record.existsSync(), isTrue);
        expect(File(service.path).existsSync(), isFalse);
      } finally {
        if (!release.isCompleted) release.complete();
      }
      await Future.wait([first, second]);
      await service.closed;
      expect(releases, 1);
      expect(
        record.existsSync(),
        isTrue,
        reason: 'Failed cleanup must retain the recovery record',
      );
      // A new real owner can acquire the released lock and adopt that record.
      final replacement = await ApplicationService.start(
        profile,
        desktopPeerVerifier: trustInProcessDesktop,
      );
      addTearDown(replacement.close);
      await replacement.ready;
      final next = await ServiceClient.connect(replacement.path);
      addTearDown(next.close);
      expect(
        (await next.call('status') as Map)['profile_id'],
        profile.identity,
      );
    },
  );

  test(
    'a competing live socket survives failed startup and the profile can retry',
    () async {
      final endpoint = '${profile.runtime}/application.sock';
      final rivalPath = '${profile.runtime}/rival.sock';
      final rival = await ServerSocket.bind(
        InternetAddress(rivalPath, type: InternetAddressType.unix),
        0,
      );
      addTearDown(rival.close);
      rival.listen((client) async {
        client.write('competing owner');
        await client.flush();
        client.destroy();
      });
      final rivalFile = File(rivalPath);
      var publications = 0;
      final race = _RecordPublication(
        '${profile.data}/.application-endpoint.json.$pid',
        () {
          publications++;
          rivalFile.renameSync(endpoint);
        },
      );
      await expectLater(
        IOOverrides.runWithIOOverrides(
          () => ApplicationService.start(
            profile,
            desktopPeerVerifier: trustInProcessDesktop,
          ),
          race,
        ),
        throwsA(isA<AnotherProfileServing>()),
      );
      expect(publications, 1);
      final peer = await Socket.connect(
        InternetAddress(endpoint, type: InternetAddressType.unix),
        0,
      );
      addTearDown(peer.destroy);
      expect(
        await peer.cast<List<int>>().transform(utf8.decoder).join(),
        'competing owner',
      );
      expect(
        File('${profile.data}/.application-endpoint.json').existsSync(),
        isFalse,
      );
      expect(
        Directory(profile.runtime).listSync().where(
          (entry) => entry.uri.pathSegments.last.startsWith('.s'),
        ),
        isEmpty,
      );
      await rival.close();
      File(endpoint).deleteSync();
      final replacement = await ApplicationService.start(
        profile,
        desktopPeerVerifier: trustInProcessDesktop,
      );
      addTearDown(replacement.close);
      await replacement.ready;
      final client = await ServiceClient.connect(replacement.path);
      addTearDown(client.close);
      expect(
        (await client.call('status') as Map)['profile_id'],
        profile.identity,
      );
    },
  );

  test(
    'idle policy retires schema reads and retains the last verified policy',
    () async {
      void Function()? reevaluate;
      final service = await ApplicationService.start(
        profile,
        desktopPeerVerifier: trustInProcessDesktop,
        createTimer: (_, callback) {
          reevaluate = callback;
          return Timer(const Duration(days: 1), callback);
        },
      );
      addTearDown(service.close);
      await service.ready;
      final client = await ServiceClient.connect(service.path);
      addTearDown(client.close);
      final store = service.domain.store;
      store.setPreference('serviceIdleMinutes', '7');
      expect(
        ((await client.call('status') as Map)['lifetime']
            as Map)['idle_minutes'],
        7.0,
      );
      store.db.execute('PRAGMA user_version=${Store.schemaVersion + 1}');
      store.db.execute('ALTER TABLE preferences RENAME TO future_preferences');
      try {
        // Drive the existing lifetime callback directly; no sleep/heartbeat or
        // unrelated RPC is allowed to retire the reads before this evaluation.
        reevaluate!();
      } finally {
        store.db.execute(
          'ALTER TABLE future_preferences RENAME TO preferences',
        );
        store.db.execute('PRAGMA user_version=${Store.schemaVersion}');
      }
      store.setPreference('serviceIdleMinutes', '11');
      final status = await client.call('status') as Map;
      expect((status['lifetime'] as Map)['idle_minutes'], 7.0);
      expect(File(service.path).existsSync(), isTrue);
      expect(service.dispatchedCount, 0);
    },
  );

  test(
    'streamed setup failure settles the service lease before the next request',
    () async {
      final service = await ApplicationService.start(
        profile,
        desktopPeerVerifier: trustInProcessDesktop,
      );
      addTearDown(service.close);
      await service.ready;
      expect(service.application.googleAuth.client, isNull);
      final client = await ServiceClient.connect(service.path);
      addTearDown(client.close);
      await client.call('security.attach_desktop', {
        'visible': true,
        'token': File('${profile.data}/.desktop-capability').readAsStringSync(),
      });
      for (final method in ['google.sign_in', 'google.add_account']) {
        await expectLater(
          client.stream(method),
          emitsInOrder([
            emitsError(
              isA<RpcError>()
                  .having(
                    (error) => error.code,
                    'classification',
                    RpcErrorCode.internal,
                  )
                  .having(
                    (error) => error.message,
                    'actionable setup failure',
                    contains('Desktop OAuth client configuration'),
                  ),
            ),
            emitsDone,
          ]),
        );
        expect(service.dispatchedCount, 0);
        final status = await client.call('status') as Map;
        expect((status['lifetime'] as Map)['busy'], isFalse);
        expect(service.application.googleAuth.signingIn, isFalse);
      }
    },
  );
}
