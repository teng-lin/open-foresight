import 'dart:convert';
import 'dart:io';

import 'package:foresight_core/src/operations.dart';
import 'package:foresight_core/src/platform_services.dart';
import 'package:foresight_core/src/profile_paths.dart';
import 'package:foresight_core/src/rpc_error.dart';
import 'package:foresight_core/src/service.dart';
import 'package:foresight_core/src/service_compatibility.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:foresight_test_support/poll.dart';
import 'package:test/test.dart';

Matcher get unavailable => isA<RpcError>()
    .having((error) => error.code, 'code', RpcErrorCode.unavailable)
    .having((error) => error.reason, 'reason', isNull)
    .having((error) => error.message, 'action', contains('restart'));

void main() {
  test(
    'released v1 advertisement is accepted without requiring new fields',
    () {
      validateApplicationApiVersion({'application_api_version': 1});
      validateApplicationClientVersion(null);
      validateApplicationClientVersion(1);
      expect(applicationApiVersion, 1);
    },
  );

  test(
    'new clients reject missing, unsupported and malformed advertised versions',
    () {
      for (final version in [null, 0, 2, '1', 1.0, true]) {
        expect(
          () => validateApplicationApiVersion({
            if (version != null) 'application_api_version': version,
          }, endpoint: '/profile/service.sock'),
          throwsA(unavailable),
        );
      }
    },
  );

  test(
    'new server accepts absent legacy v1 and refuses explicit incompatibility',
    () {
      for (final version in [0, 2, -1]) {
        expect(
          () => validateApplicationClientVersion(version),
          throwsA(
            isA<RpcError>()
                .having((error) => error.code, 'code', RpcErrorCode.unavailable)
                .having((error) => error.reason, 'reason', isNull),
          ),
        );
      }
      for (final version in ['1', 1.0, true]) {
        expect(
          () => validateApplicationClientVersion(version),
          throwsA(
            isA<RpcError>().having(
              (error) => error.code,
              'code',
              RpcErrorCode.invalidArgument,
            ),
          ),
        );
      }
    },
  );

  test(
    'status probe preserves desktop capability and advertises v1 additively',
    () async {
      final arguments = {
        'desktop': true,
        'token': 'capability',
        'other': 'additive',
      };
      final original = Map<String, dynamic>.of(arguments);
      final result = await probeApplicationApiVersion((args) async {
        expect(args, {...original, 'client_api_version': 1});
        return {
          'application_api_version': 1,
          'profile_id': 'profile',
          'runtime_revision': 'revision',
        };
      }, arguments: arguments);
      expect(arguments, original);
      expect(result['profile_id'], 'profile');
      expect(result['runtime_revision'], 'revision');
    },
  );

  test(
    'invalid status shapes fail actionably rather than exposing decoder TypeErrors',
    () async {
      for (final response in [
        null,
        1,
        <Object, Object>{1: 'bad'},
        <Object>[],
      ]) {
        await expectLater(
          probeApplicationApiVersion((_) async => response),
          throwsA(unavailable),
        );
      }
    },
  );

  test(
    'negotiation never rewrites transport reason or retries an ambiguous request',
    () async {
      var probes = 0;
      final error = RpcError(
        RpcErrorCode.unavailable,
        'lost reply',
        reason: RpcErrorReason.outcomeUnknown,
      );
      await expectLater(
        probeApplicationApiVersion((_) async {
          probes++;
          throw error;
        }),
        throwsA(same(error)),
      );
      expect(probes, 1);
    },
  );

  test(
    'each replacement transport is independently checked before a business call',
    () async {
      final root = createTestTempDirectorySync('api-peer-');
      final path = '${root.path}/service.sock';
      final listener = await ServerSocket.bind(
        InternetAddress(path, type: InternetAddressType.unix),
        0,
      );
      final sockets = <Socket>[];
      final received = <Map>[];
      var peers = 0;
      listener.listen((socket) {
        sockets.add(socket);
        final peer = ++peers;
        socket
            .cast<List<int>>()
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .listen((line) {
              final request = jsonDecode(line) as Map;
              received.add({'peer': peer, ...request});
              socket.writeln(
                jsonEncode({
                  'id': request['id'],
                  'done': true,
                  'result': request['method'] == Operation.status.wire
                      ? {'application_api_version': peer == 2 ? 2 : 1}
                      : ['source'],
                }),
              );
            });
      });
      try {
        for (var attempt = 1; attempt <= 3; attempt++) {
          final client = await ServiceClient.connect(path);
          try {
            final negotiated = probeApplicationApiVersion(
              (args) => client.call(Operation.status.wire, args),
              endpoint: path,
            );
            if (attempt == 2) {
              await expectLater(negotiated, throwsA(unavailable));
            } else {
              await negotiated;
              expect(await client.call(Operation.sourcesList.wire), ['source']);
            }
          } finally {
            await client.close();
          }
        }
        expect(
          received
              .where((request) => request['peer'] == 2)
              .map((request) => request['method']),
          [Operation.status.wire],
        );
        for (final status in received.where(
          (request) => request['method'] == Operation.status.wire,
        )) {
          expect(status['args']['client_api_version'], 1);
        }
        expect(peers, 3);
      } finally {
        for (final socket in sockets) {
          socket.destroy();
        }
        await listener.close();
        root.deleteSync(recursive: true);
      }
    },
  );
  test(
    'production startup and reconnect validate each advertised peer before business calls',
    () async {
      final saved = Map<String, String>.of(runtimeConfiguration.environment);
      runtimeConfiguration.environment.remove('FORESIGHT_RUNTIME_REVISION');
      runtimeConfiguration.environment.remove('FORESIGHT_INSTALL_ROOT');
      final root = createTestTempDirectorySync('api-start-');
      final profile = ProfilePaths('${root.path}/d', '${root.path}/r');
      privateDirectory(profile.data);
      privateDirectory(profile.runtime);
      File(
        '${profile.data}/.desktop-capability',
      ).writeAsStringSync('capability');
      final listener = await ServerSocket.bind(
        InternetAddress(
          '${profile.runtime}/application.sock',
          type: InternetAddressType.unix,
        ),
        0,
      );
      final peers = <Socket>[];
      final requests = <Map>[];
      Object? advertised = 1;
      var foreign = false;
      listener.listen((socket) {
        peers.add(socket);
        socket
            .cast<List<int>>()
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .listen((line) {
              final request = jsonDecode(line) as Map;
              requests.add(request);
              socket.writeln(
                jsonEncode({
                  'id': request['id'],
                  'done': true,
                  'result': request['method'] == Operation.status.wire
                      ? {
                          'pid': pid,
                          'profile_id': foreign ? 'foreign' : profile.identity,
                          if (advertised != null)
                            'application_api_version': advertised,
                        }
                      : ['source'],
                }),
              );
            });
      });
      final connection = ServiceConnection(profile);
      try {
        for (final version in [null, 2, '1', 1]) {
          advertised = version;
          requests.clear();
          if (version == 1) {
            final startup = await ensureServiceSnapshot(profile);
            await startup.client.close();
            expect(requests, hasLength(2));
            expect(requests.first['args']['desktop'], isNull);
            expect(requests.last['args']['desktop'], isTrue);
            expect(requests.last['args']['token'], 'capability');
          } else {
            await expectLater(
              ensureServiceSnapshot(profile),
              throwsA(unavailable),
            );
            expect(requests, hasLength(1));
            expect(requests.single['args']['desktop'], isNull);
          }
          for (final request in requests) {
            expect(request['args']['client_api_version'], 1);
          }
        }
        advertised = 1;
        requests.clear();
        final first = await connection.connect();
        expect(await connection.stream(Operation.sourcesList.wire).last, [
          'source',
        ]);
        expect(requests.map((r) => r['method']), [
          Operation.status.wire,
          Operation.sourcesList.wire,
        ]);
        advertised = 2;
        peers.last.destroy();
        await eventually(() => first.isClosed);
        requests.clear();
        await expectLater(
          connection.stream(Operation.sourcesList.wire).last,
          throwsA(unavailable),
        );
        expect(requests.map((r) => r['method']), [Operation.status.wire]);
        // Profile refusal precedes interpreting a foreign owner's version and
        // sending this profile's desktop capability.
        foreign = true;
        requests.clear();
        await expectLater(
          ensureServiceSnapshot(profile),
          throwsA(isA<AnotherProfileServing>()),
        );
        expect(requests, hasLength(1));
        expect(requests.single['args']['token'], isNull);
      } finally {
        await connection.close();
        for (final peer in peers) {
          peer.destroy();
        }
        await listener.close();
        runtimeConfiguration.environment
          ..clear()
          ..addAll(saved);
      }
    },
  );
}
