import 'package:foresight_test_support/desktop_identity.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:foresight_core/foresight_core.dart';
import 'package:foresight_core/src/application.dart';
import 'package:foresight_core/src/rpc_error.dart';
import 'package:foresight_core/src/service.dart';
import 'package:foresight_core/src/generated/rag_service.pbgrpc.dart';
import 'package:foresight_test_support/poll.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:grpc/grpc.dart';
import 'package:test/test.dart';
import 'package:crypto/crypto.dart';

import 'package:foresight_test_support/helper_adoption.dart';
import 'package:foresight_core/src/generated/helper_control.pb.dart' as control;

class _FailedIndex extends AdoptionRag {
  @override
  Future<IndexResponse> indexDocument(
    ServiceCall call,
    IndexRequest request,
  ) async =>
      IndexResponse(success: false, errorMessage: 'fixture index unavailable');
}

void main() {
  late Directory root;
  late ProfilePaths profile;
  late Map<String, String> environment;
  setUp(() {
    root = createTestTempDirectorySync('sf-');
    profile = ProfilePaths('${root.path}/data', '${root.path}/run');
    environment = Map.of(runtimeConfiguration.environment);
    runtimeConfiguration.environment.removeWhere(
      (key, _) =>
          key.startsWith('FORESIGHT_') && key != 'FORESIGHT_SQLITE_LIBRARY',
    );
    addTearDown(() {
      runtimeConfiguration.environment
        ..clear()
        ..addAll(environment);
    });
  });

  test(
    'startup replaces a stale endpoint and retains interrupted work after indexing fails',
    () async {
      privateDirectory(profile.data);
      privateDirectory(profile.runtime);
      final store = Store('${profile.data}/application.db');
      final meeting = store.meeting('Interrupted planning');
      store.transcript(
        meeting,
        'Committed transcript',
        true,
        0,
        1000,
        'imported',
      );
      store.db.execute("UPDATE meetings SET state='recording' WHERE id=?", [
        meeting,
      ]);
      store.close();
      File(
        '${profile.runtime}/application.sock',
      ).writeAsStringSync('stale endpoint');
      final model = File('${root.path}/speech.bin')
        ..writeAsStringSync('verified fixture');
      final digest = sha256.convert(model.readAsBytesSync()).toString();
      final manifest = File('${root.path}/models.json')
        ..writeAsStringSync(
          jsonEncode({
            'speech': {
              'model': model.path,
              'runtime': '/usr/bin/true',
              'sha256': digest,
            },
          }),
        );
      runtimeConfiguration.environment['FORESIGHT_MODEL_MANIFEST'] =
          manifest.path;
      final server = Server.create(
        services: [_FailedIndex(), AdoptionControl(control.State())],
      );
      await server.serve(
        address: InternetAddress(
          '${profile.runtime}/helper.sock',
          type: InternetAddressType.unix,
        ),
        port: 0,
      );
      addTearDown(server.shutdown);
      final service = await ApplicationService.start(
        profile,
        desktopPeerVerifier: trustInProcessDesktop,
      );
      addTearDown(service.close);
      final client = await ServiceClient.connect(service.path);
      addTearDown(client.close);
      // Socket publication precedes background model restoration and the
      // interrupted-meeting recovery loop. Join that work before inspecting
      // its durable failure, rather than racing a fixed polling deadline.
      await service.ready;
      expect(
        service.domain.store.sources.any(
          (source) => source['state'] == 'failed',
        ),
        isTrue,
      );
      expect(service.domain.store.model('speech')!['digest'], digest);
      expect(
        service.domain.store.meetingTranscript(meeting).single['text'],
        'Committed transcript',
      );
      expect(
        service.domain.store.rows('SELECT state FROM meetings').single['state'],
        'interrupted',
      );
      expect(
        service.domain.store.sources.single['error'],
        'Transcript indexing could not complete; saved for retry.',
      );
      await client.call('notes.save', {
        'title': 'Still available',
        'body': 'Saved after recovery failure',
      });
      expect(await client.call('notes.list'), hasLength(1));
      expect((await client.call('status') as Map)['models_busy'], isFalse);
    },
  );

  test(
    'failed capability publication releases ownership so startup can retry',
    () async {
      privateDirectory(profile.data);
      privateDirectory(profile.runtime);
      final target = File('${root.path}/protected')
        ..writeAsStringSync('retained');
      final capability = Link('${profile.data}/.desktop-capability')
        ..createSync(target.path);
      await expectLater(
        ApplicationService.start(
          profile,
          desktopPeerVerifier: trustInProcessDesktop,
        ),
        throwsStateError,
      );
      expect(target.readAsStringSync(), 'retained');
      expect(File('${profile.runtime}/application.sock').existsSync(), isFalse);
      capability.deleteSync();
      final server = Server.create(
        services: [AdoptionRag(), AdoptionControl(control.State())],
      );
      await server.serve(
        address: InternetAddress(
          '${profile.runtime}/helper.sock',
          type: InternetAddressType.unix,
        ),
        port: 0,
      );
      addTearDown(server.shutdown);
      final service = await ApplicationService.start(
        profile,
        desktopPeerVerifier: trustInProcessDesktop,
      );
      addTearDown(service.close);
      final client = await ServiceClient.connect(service.path);
      addTearDown(client.close);
      final note =
          await client.call('notes.save', {'title': 'Retry', 'body': 'Durable'})
              as Map;
      expect(note['id'], isA<int>());
      expect(await client.call('notes.list'), hasLength(1));
      await eventually(() => service.domain.helper.snapshot != null);
      await service.domain.resume();
    },
  );

  test(
    'malformed requests and security errors are scoped to one frame',
    () async {
      final service = await ApplicationService.start(
        profile,
        desktopPeerVerifier: trustInProcessDesktop,
      );
      addTearDown(service.close);
      final socket = await Socket.connect(
        InternetAddress(service.path, type: InternetAddressType.unix),
        0,
      );
      addTearDown(socket.destroy);
      final replies = StreamIterator(
        socket
            .cast<List<int>>()
            .transform(utf8.decoder)
            .transform(const LineSplitter()),
      );
      addTearDown(replies.cancel);
      Future<Map> response() async {
        while (await replies.moveNext()) {
          final value = jsonDecode(replies.current) as Map;
          if (!value.containsKey('event')) return value;
        }
        throw StateError('service closed');
      }

      for (final frame in [
        '{broken',
        '[]',
        '{"id":1,"method":"notes.save","args":null}',
      ]) {
        socket.writeln(frame);
        final error = await response();
        expect(error['done'], isTrue);
        expect((error['error'] as Map)['code'], 'invalidArgument');
      }
      for (final method in ['security.unknown', 'security.detach_desktop']) {
        socket.writeln(jsonEncode({'id': 2, 'method': method, 'args': {}}));
        expect((await response())['error'], isA<Map>());
      }
      socket.writeln(
        jsonEncode({
          'id': 3,
          'method': 'notes.save',
          'args': {'title': 'Survived', 'body': 'Saved'},
        }),
      );
      expect((await response())['result'], isA<Map>());
      expect((await response())['done'], isTrue);
      expect(service.domain.store.notes().single['title'], 'Survived');
    },
  );

  test(
    'request saturation and cancellation leave another client responsive',
    () async {
      privateDirectory(profile.runtime);
      final ping = HeldPing();
      final server = Server.create(
        services: [ping, AdoptionControl(control.State())],
      );
      await server.serve(
        address: InternetAddress(
          '${profile.runtime}/helper.sock',
          type: InternetAddressType.unix,
        ),
        port: 0,
      );
      addTearDown(server.shutdown);
      final service = await ApplicationService.start(
        profile,
        desktopPeerVerifier: trustInProcessDesktop,
      );
      addTearDown(service.close);
      final entered = Completer<void>(), release = Completer<void>();
      service.domain.helper.onReady = () async {
        entered.complete();
        await release.future;
      };
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      // Hold the first RPC until readiness interception is installed; scheduling
      // speed must not decide whether the test fills the pending-request slots.
      ping.release.complete();
      final busy = await ServiceClient.connect(service.path);
      final other = await ServiceClient.connect(service.path);
      addTearDown(busy.close);
      addTearDown(other.close);
      await entered.future.timeout(const Duration(seconds: 3));
      final requests = <StreamSubscription<Object?>>[];
      final failures = <RpcError>[];
      for (var i = 0; i < 32; i++) {
        requests.add(
          busy
              .stream('answer.stream', {
                'question': 'Pending $i',
                'requestId': 'q-$i',
              })
              .listen(
                (_) {},
                onError: (Object e) => failures.add(RpcError.from(e)),
              ),
        );
      }
      await expectLater(
        busy.call('status'),
        throwsA(
          isA<RpcError>().having((e) => e.code, 'code', RpcErrorCode.busy),
        ),
      );
      expect((await other.call('status') as Map)['pid'], pid);
      expect(busy.cancelAnswers(requestId: 'q-7'), isTrue);
      // This round trip proves the freed slot can serve a new request immediately.
      expect((await busy.call('status') as Map)['pid'], pid);
      expect(busy.cancelAnswers(requestId: 'q-7'), isFalse);
      expect(busy.cancelAnswers(), isTrue);
      await eventually(() => failures.length == 32);
      expect(failures.map((e) => e.code), everyElement(RpcErrorCode.cancelled));
      // A same-connection reply orders the server's cancellation handling
      // before releasing readiness; local cancellation errors alone do not.
      expect((await busy.call('status') as Map)['pid'], pid);
      release.complete();
      for (final request in requests) {
        await request.cancel();
      }
      expect(service.domain.store.rows('SELECT * FROM answers'), isEmpty);
      expect(
        (await other.call('notes.save', {
              'title': 'After cancellation',
              'body': 'Committed',
            })
            as Map)['id'],
        isA<int>(),
      );
      expect(await other.call('notes.list'), hasLength(1));
    },
  );

  test(
    'capture-level events reach clients independently of pending calls',
    () async {
      final service = await ApplicationService.start(
        profile,
        desktopPeerVerifier: trustInProcessDesktop,
      );
      addTearDown(service.close);
      final client = await ServiceClient.connect(service.path);
      addTearDown(client.close);
      await client.call('status');
      final event = client.events.stream.firstWhere(
        (event) => event['event'] == 'capture_levels',
      );
      service.application.captureLevelChanges.add(null);
      expect(
        (await event.timeout(const Duration(seconds: 3)))['volumes'],
        isEmpty,
      );
      expect((await client.call('status') as Map)['pid'], pid);
    },
  );

  test(
    'service-only operations fail explicitly in direct application dispatch',
    () async {
      final store = Store('${root.path}/app.db');
      addTearDown(store.close);
      final helper = Helper(
        '${root.path}/unused.sock',
        root.path,
        manageProcess: false,
      );
      addTearDown(helper.close);
      final domain = Domain(store, helper);
      final application = Application(domain);
      addTearDown(domain.close);
      addTearDown(application.close);
      for (final method in [
        'answer.stream',
        'google.sign_in',
        'security.attach_desktop',
        'security.detach_desktop',
        'security.decide',
        'security.allow_import_root',
        'service.stop_if_idle',
      ]) {
        await expectLater(
          application.call(method, {}),
          throwsA(
            isA<RpcError>().having(
              (e) => e.code,
              'code',
              RpcErrorCode.invalidArgument,
            ),
          ),
        );
      }
    },
  );
}
