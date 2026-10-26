import 'sql_support_test_bootstrap.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:foresight_core/src/client_diagnostics.dart';
import 'package:foresight_core/src/diagnostics/session.dart';
import 'package:foresight_core/src/diagnostics/storage.dart';
import 'package:foresight_core/src/rpc_error.dart';
import 'package:foresight_core/src/service_client.dart';
import 'package:foresight_core/src/service_connection.dart';
import 'package:foresight_core/src/service_diagnostics.dart';
import 'package:foresight_core/src/platform_services.dart';
import 'package:foresight_test_support/remote_service.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';

const canary = 'PRIVATE-CALLER-REQUEST-ID-ARGUMENT-RESULT-ERROR';

class _Sink implements DiagnosticSink {
  _Sink(this.port);
  final SendPort port;
  @override
  int get slot => 0;
  @override
  bool get failed => false;
  @override
  bool classify(
    DiagnosticRole role, {
    required bool error,
    bool genuineFailure = false,
  }) => true;
  @override
  bool append(Uint8List bytes) {
    port.send(bytes);
    return true;
  }

  @override
  void close() => port.send(null);
}

DiagnosticSinkFactory _sink(SendPort port) =>
    (_, _, _) => _Sink(port);

void main() {
  bootstrapSqlSupportFixture();
  late RemoteFixture fixture;
  late Map<String, String> environment;
  late LoggingSession session;
  late ReceivePort messages;
  late StreamSubscription<Object?> listener;
  late List<Map<String, dynamic>> records;
  late Completer<void> closed;
  late Completer<void> failedConnectionRecorded;

  setUp(() async {
    environment = Map.of(runtimeConfiguration.environment);
    fixture = RemoteFixture();
    await fixture.start();
    messages = ReceivePort();
    records = [];
    closed = Completer<void>();
    failedConnectionRecorded = Completer<void>();
    listener = messages.listen((value) {
      if (value == null) {
        closed.complete();
      } else {
        records.add(
          jsonDecode(utf8.decode(value as Uint8List)) as Map<String, dynamic>,
        );
        final record = records.last;
        if (!failedConnectionRecorded.isCompleted &&
            record['event'] == 'rpc.connection_changed' &&
            record['fields']['outcome'] == 'failed') {
          failedConnectionRecorded.complete();
        }
      }
    });
    session = await LoggingSession.startForTesting(
      // Cancellation is intentionally debug severity in the frozen policy.
      configuration: const DiagnosticConfiguration(
        level: DiagnosticLevel.debug,
      ),
      profilePath: createTestTempDirectorySync('client-records-').path,
      sinkFactory: _sink(messages.sendPort),
    );
    await session.producer.ready;
  });
  tearDown(() async {
    await fixture.close();
    final result = await session.close();
    expect(result.writerExited, true);
    expect(result.flushed, true);
    if (records.isNotEmpty) {
      await closed.future.timeout(const Duration(seconds: 2));
    }
    await listener.cancel();
    messages.close();
    runtimeConfiguration.environment
      ..clear()
      ..addAll(environment);
    expect(clientDiagnosticObservation()['calls'], 0);
    expect(clientDiagnosticObservation()['connections'], 0);
    expect(jsonEncode(records), isNot(contains(canary)));
  });

  Future<void> observe(Future<void> Function() action) =>
      runWithServiceDiagnostics(
        session.producer,
        action,
        component: DiagnosticComponent.desktop,
      );

  Future<void> flush({bool hasRecords = true}) async {
    final result = await session.close();
    expect(result.writerExited, true);
    expect(result.flushed, true);
    if (hasRecords) await closed.future.timeout(const Duration(seconds: 2));
  }

  List<Map<String, dynamic>> calls(String operation) => records
      .where(
        (r) =>
            r['fields']['operation'] == operation &&
            r['fields']['call'] != null,
      )
      .toList();

  test(
    'one call ID follows exactly the existing closing retry and wire IDs',
    () async {
      await observe(() async {
        final connection = ServiceConnection(fixture.profile);
        var first = true;
        fixture.handler = (socket, request) {
          if (request['method'] != 'notes.list') return;
          if (first) {
            first = false;
            socket.writeln(
              jsonEncode({
                'id': request['id'],
                'done': true,
                'error': {
                  'code': 'unavailable',
                  'message': canary,
                  'reason': 'closing',
                },
              }),
            );
          } else {
            fixture.reply(socket, request, canary);
          }
        };
        expect(
          await connection.stream('notes.list', {'requestId': canary}).single,
          canary,
        );
        await connection.close();
      });
      await flush();
      final attempts = calls('notes.list');
      expect(attempts, hasLength(2));
      expect(attempts.map((r) => r['attempt']), [1, 2]);
      expect(attempts.map((r) => r['fields']['outcome']), [
        'refused',
        'completed',
      ]);
      expect(attempts[0]['fields']['call'], attempts[1]['fields']['call']);
      expect(
        DiagnosticIdentity.parse(attempts[0]['fields']['call'] as String),
        isNotNull,
      );
      expect(attempts[0]['connection'], isNot(attempts[1]['connection']));
      final requests = fixture.requests
          .where((r) => r['method'] == 'notes.list')
          .toList();
      expect(requests, hasLength(2));
      expect(attempts.map((r) => r['request']), requests.map((r) => r['id']));
      expect(
        records.where((r) => r['event'] == 'rpc.connection_changed'),
        isNotEmpty,
      );
    },
  );

  test('unknown outcome is recorded as unknown and never resent', () async {
    await observe(() async {
      final connection = ServiceConnection(fixture.profile);
      fixture.handler = (socket, request) {
        if (request['method'] == 'notes.save') socket.destroy();
      };
      await expectLater(
        connection.stream('notes.save', {'title': canary}).toList(),
        throwsA(
          isA<RpcError>().having(
            (e) => e.reason,
            'reason',
            RpcErrorReason.outcomeUnknown,
          ),
        ),
      );
      await connection.close();
    });
    await flush();
    final observed = calls('notes.save');
    expect(observed, hasLength(1));
    expect(observed.single['fields']['outcome'], 'unknown');
    expect(observed.single['attempt'], 1);
    expect(
      fixture.requests.where((r) => r['method'] == 'notes.save'),
      hasLength(1),
    );
  });

  test(
    'cancellation releases correlation and keeps the actual cancel frame',
    () async {
      await observe(() async {
        final connection = ServiceConnection(fixture.profile);
        fixture.handler = (socket, request) {
          if (request['method'] == 'answer.stream') {
            fixture.reply(socket, request, canary, done: false);
          } else if (request['method'] == 'notes.save') {
            socket.writeln(
              jsonEncode({
                'id': request['id'],
                'done': true,
                'error': {'code': 'denied', 'message': canary},
              }),
            );
          }
        };
        // DEBUG cancellation alone does not admit the cold bootstrap ring.
        // A typed permission error is the explicit persistence positive control.
        await expectLater(
          connection.stream('notes.save').toList(),
          throwsA(
            isA<RpcError>().having((e) => e.code, 'code', RpcErrorCode.denied),
          ),
        );
        final arrived = Completer<void>();
        final subscription = connection
            .stream('answer.stream', {'requestId': canary})
            .listen((value) {
              if (!arrived.isCompleted) arrived.complete();
            });
        await arrived.future;
        final wire = fixture.requests.lastWhere(
          (r) => r['method'] == 'answer.stream',
        )['id'];
        expect(clientDiagnosticObservation()['calls'], 1);
        await subscription.cancel();
        await eventually(
          () => fixture.requests.any((r) => r['cancel'] == wire),
        );
        expect(clientDiagnosticObservation()['calls'], 0);
        await connection.close();
      });
      await flush();
      expect(calls('notes.save'), hasLength(1));
      final observed = calls('answer.stream');
      expect(observed, hasLength(1));
      expect(observed.single['fields']['outcome'], 'cancelled');
      expect(
        fixture.requests.where((r) => r['method'] == 'answer.stream'),
        hasLength(1),
      );
    },
  );

  test(
    'diagnostic saturation counts refusal while both business calls complete',
    () async {
      await observe(() async {
        final client = await ServiceClient.connect(
          '${fixture.profile.runtime}/application.sock',
        );
        final entered = Completer<void>();
        Map<String, dynamic>? held;
        Socket? owner;
        fixture.handler = (socket, request) {
          if (request['method'] != 'notes.list') return;
          if (held == null) {
            held = request;
            owner = socket;
            entered.complete();
          } else {
            fixture.reply(socket, request, 'second');
          }
        };
        final first = client.call('notes.list');
        await entered.future;
        final before = session.producer.correlationRefused;
        expect(await client.call('notes.list'), 'second');
        expect(session.producer.correlationRefused, before + 1);
        expect(clientDiagnosticObservation()['calls'], 1);
        fixture.reply(owner!, held!, 'first');
        expect(await first, 'first');
        expect(clientDiagnosticObservation()['calls'], 0);
        await client.close();
      });
    },
  );

  test(
    'connection observation saturation never refuses a business connection',
    () async {
      await observe(() async {
        final first = await ServiceClient.connect(
          '${fixture.profile.runtime}/application.sock',
        );
        final before = clientDiagnosticObservation();
        final second = await ServiceClient.connect(
          '${fixture.profile.runtime}/application.sock',
        );
        expect(clientDiagnosticObservation()['connections'], 1);
        expect(
          clientDiagnosticObservation()['connectionRefusals'],
          before['connectionRefusals']! + 1,
        );
        fixture.handler = (socket, request) =>
            fixture.reply(socket, request, canary);
        expect(await second.call('notes.list'), canary);
        await second.close();
        expect(clientDiagnosticObservation()['connections'], 1);
        await first.close();
        expect(clientDiagnosticObservation()['connections'], 0);
      });
    },
  );

  test(
    'failed connection records a closed outcome without its private path',
    () async {
      await observe(() async {
        await expectLater(
          ServiceClient.connect('${fixture.root.path}/missing'),
          throwsA(isA<SocketException>()),
        );
      });
      // Two INFO-only records remain in the existing cold bootstrap ring.
      // Exercise its actual five-second admission gate, without changing the
      // product gate or this test's existing delivery deadline.
      expect((await session.inspectBudgetForTesting()).queuedRecords, 2);
      expect(records, isEmpty);
      await Future<void>.delayed(const Duration(seconds: 5));
      await failedConnectionRecorded.future.timeout(const Duration(seconds: 2));
      await flush();
      final events = records
          .where((r) => r['event'] == 'rpc.connection_changed')
          .toList();
      expect(events.map((r) => r['fields']['outcome']), ['started', 'failed']);
      expect(events.last['fields']['category'], 'transport');
      expect(jsonEncode(records), isNot(contains(fixture.root.path)));
      expect(events.first['connection'], events.last['connection']);
      expect(clientDiagnosticObservation()['connections'], 0);
    },
  );

  test('a connection opener counts one capacity refusal', () async {
    await observe(() async {
      final first = await ServiceClient.connect(
        '${fixture.profile.runtime}/application.sock',
      );
      final second = ServiceConnection(fixture.profile);
      try {
        final before = clientDiagnosticObservation()['connectionRefusals']!;
        await second.connect();
        expect(clientDiagnosticObservation()['connectionRefusals'], before + 1);
        fixture.handler = (socket, request) =>
            fixture.reply(socket, request, canary);
        expect(await second.stream('notes.list').single, canary);
      } finally {
        await second.close();
        await first.close();
      }
    });
  });

  test(
    'a bound client keeps its diagnostic owner for later unbound callbacks',
    () async {
      late ServiceClient client;
      await observe(() async {
        client = await ServiceClient.connect(
          '${fixture.profile.runtime}/application.sock',
        );
        fixture.handler = (socket, request) {
          if (request['method'] == 'notes.save') {
            socket.writeln(
              jsonEncode({
                'id': request['id'],
                'done': true,
                'error': {'code': 'denied', 'message': canary},
              }),
            );
          } else {
            fixture.reply(socket, request, canary);
          }
        };
        // A real typed error is the positive persistence admission control.
        await expectLater(
          client.call('notes.save'),
          throwsA(
            isA<RpcError>().having((e) => e.code, 'code', RpcErrorCode.denied),
          ),
        );
      });
      expect(serviceDiagnosticsEnabled, false);
      expect(await client.call('notes.list', {'requestId': canary}), canary);
      expect(
        await runWithServiceDiagnostics(
          session.producer,
          () => client.call('notes.list'),
          component: DiagnosticComponent.mcp,
        ),
        canary,
      );
      await client.close();
      await flush();
      expect(calls('notes.save'), hasLength(1));
      final later = calls('notes.list');
      expect(later, hasLength(2));
      expect(later.every((record) => record['component'] == 'desktop'), true);
      expect(
        records.where(
          (r) =>
              r['event'] == 'rpc.connection_changed' &&
              r['fields']['outcome'] == 'completed',
        ),
        hasLength(1),
      );
    },
  );

  for (final differentOwner in [false, true]) {
    test(
      'a later retry retains construction owner (different owner: $differentOwner)',
      () async {
        late ServiceConnection connection;
        await observe(() async {
          connection = ServiceConnection(fixture.profile);
          await connection.connect();
          fixture.handler = (socket, request) => socket.writeln(
            jsonEncode({
              'id': request['id'],
              'done': true,
              'error': {'code': 'denied', 'message': canary},
            }),
          );
          await expectLater(
            connection.stream('notes.save').toList(),
            throwsA(isA<RpcError>()),
          );
        });
        var refused = false;
        fixture.handler = (socket, request) {
          if (!refused) {
            refused = true;
            socket.writeln(
              jsonEncode({
                'id': request['id'],
                'done': true,
                'error': {
                  'code': 'unavailable',
                  'message': canary,
                  'reason': 'closing',
                },
              }),
            );
          } else {
            fixture.reply(socket, request, canary);
          }
        };
        expect(serviceDiagnosticsEnabled, false);
        expect(
          await (differentOwner
              ? runWithServiceDiagnostics(
                  session.producer,
                  () => connection.stream('notes.list').single,
                  component: DiagnosticComponent.mcp,
                )
              : connection.stream('notes.list').single),
          canary,
        );
        await connection.close();
        await flush();
        expect(
          records
              .where(
                (record) =>
                    record['event'] == 'rpc.connection_changed' ||
                    record['fields']['call'] != null,
              )
              .every((record) => record['component'] == 'desktop'),
          true,
        );
        final attempts = calls('notes.list');
        expect(attempts, hasLength(2));
        expect(attempts.map((record) => record['attempt']), [1, 2]);
        expect(attempts[0]['fields']['call'], attempts[1]['fields']['call']);
        expect(
          attempts.every((record) => record['component'] == 'desktop'),
          true,
        );
        expect(
          fixture.requests.where(
            (request) => request['method'] == 'notes.list',
          ),
          hasLength(2),
        );
      },
    );
  }

  test('an unbound connection does not borrow a later caller owner', () async {
    final before = clientDiagnosticObservation();
    final connection = ServiceConnection(fixture.profile);
    fixture.handler = (socket, request) =>
        fixture.reply(socket, request, canary);
    await observe(() async {
      expect(await connection.stream('notes.list').single, canary);
      await connection.close();
    });
    expect(clientDiagnosticObservation(), before);
    await flush(hasRecords: false);
  });

  test(
    'unbound and canonical off skip identities, timing and call observation',
    () async {
      final before = clientDiagnosticObservation();
      fixture.handler = (socket, request) =>
          fixture.reply(socket, request, canary);
      final client = await ServiceClient.connect(
        '${fixture.profile.runtime}/application.sock',
      );
      expect(await client.call('notes.list', {'requestId': canary}), canary);
      await client.close();
      expect(clientDiagnosticObservation(), before);
      // One logger owner per VM: retire the enabled fixture before testing off.
      await flush(hasRecords: false);
      final endpoints = DiagnosticProducer.localEndpointCount;
      final timers = DiagnosticProducer.localRegistrationTimerCount;
      final off = await LoggingSession.startForTesting(
        configuration: const DiagnosticConfiguration(
          level: DiagnosticLevel.off,
        ),
        profilePath: createTestTempDirectorySync('client-off-').path,
      );
      try {
        await runWithServiceDiagnostics(off.producer, () async {
          expect(serviceDiagnosticsEnabled, false);
          expect(serviceDiagnosticClockMicros(), isNull);
          final disabled = await ServiceClient.connect(
            '${fixture.profile.runtime}/application.sock',
          );
          expect(await disabled.call('notes.list'), canary);
          await disabled.close();
        });
        expect(clientDiagnosticObservation(), before);
        expect(DiagnosticProducer.localEndpointCount, endpoints);
        expect(DiagnosticProducer.localRegistrationTimerCount, timers);
      } finally {
        await off.close();
      }
    },
  );

  test(
    'invalid frame content and unregistered operation never enter records',
    () async {
      await observe(() async {
        final client = await ServiceClient.connect(
          '${fixture.profile.runtime}/application.sock',
        );
        fixture.handler = (socket, request) =>
            socket.writeln('invalid-$canary');
        await expectLater(
          client.call('private.$canary', {'requestId': canary}),
          throwsA(isA<RpcError>()),
        );
        await client.close();
      });
      await flush();
      expect(
        records.where((r) => r['event'] == 'transport.invalid_frame'),
        hasLength(1),
      );
      expect(records.any((r) => r['fields']['call'] != null), false);
    },
  );
}
