import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:foresight_core/src/diagnostics/session.dart';
import 'package:foresight_core/src/diagnostics/storage.dart';
import 'package:foresight_core/src/rpc_error.dart';
import 'package:foresight_core/src/service_diagnostics.dart';
import 'package:foresight_core/src/operation_descriptor.dart';
import 'package:foresight_core/src/operation_registry.dart';
import 'package:foresight_core/src/operation_requests.dart';
import 'package:foresight_core/src/operations.dart';
import 'package:foresight_core/src/profile_paths.dart';
import 'package:foresight_core/src/service_ownership.dart';
import 'package:foresight_test_support/native_fixture.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';
import 'diagnostics/test_sinks.dart';

class _Sink implements DiagnosticSink {
  _Sink(this.output, [this.blocker]);
  final SendPort output;
  final String? blocker;
  bool entered = false;
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
  bool append(Uint8List record) {
    if (blocker != null && !entered) {
      entered = true;
      output.send('entered');
      DynamicLibrary.open(
        blocker!,
      ).lookupFunction<Void Function(), void Function()>('hold_writer')();
    }
    output.send(record);
    return true;
  }

  @override
  void close() => output.send(null);
}

DiagnosticSinkFactory _factory(SendPort port, [String? blocker]) =>
    (_, _, _) => _Sink(port, blocker);

class _PrivateFailure implements Exception {
  @override
  String toString() => throw StateError('diagnostics must not format failures');
}

void main() {
  test(
    'emitter opener scope keeps the construction owner and caller context',
    () async {
      final capture = SinkCapture();
      final session = await LoggingSession.startForTesting(
        configuration: const DiagnosticConfiguration(),
        profilePath: createTestTempDirectorySync('emitter-owner-').path,
        sinkFactory: memorySink(capture.port.sendPort),
      );
      final producerA = session.producer;
      final producerB = session.registerProducer(DiagnosticProducerKind.domain);
      await producerB.ready;
      try {
        final emitterA = runWithServiceDiagnostics(
          producerA,
          captureServiceDiagnosticEmitter,
          component: DiagnosticComponent.desktop,
        )!;
        final emitterB = runWithServiceDiagnostics(
          producerB,
          captureServiceDiagnosticEmitter,
          component: DiagnosticComponent.mcp,
        )!;
        final callerKey = Object();
        final callerValue = Object();
        final endpoints = DiagnosticProducer.localEndpointCount;
        final timers = DiagnosticProducer.localRegistrationTimerCount;
        await runZoned(
          () => runWithServiceDiagnostics(producerB, () async {
            final callerEmitter = captureServiceDiagnosticEmitter();
            expect(callerEmitter, isNot(same(emitterA)));
            await runWithServiceDiagnosticEmitter(emitterA, () async {
              expect(Zone.current[callerKey], same(callerValue));
              expect(captureServiceDiagnosticEmitter(), same(emitterA));
              await runWithServiceDiagnosticEmitter(null, () async {
                await Future<void>.value();
                expect(captureServiceDiagnosticEmitter(), isNull);
                runWithServiceDiagnosticEmitter(emitterB, () {
                  expect(captureServiceDiagnosticEmitter(), same(emitterB));
                });
                expect(captureServiceDiagnosticEmitter(), isNull);
              });
              expect(captureServiceDiagnosticEmitter(), same(emitterA));
              expect(
                captureServiceDiagnosticEmitter()!.emit(
                  DiagnosticEvent.rpcFailed,
                ),
                isTrue,
              );
              // Producer/component bindings remain the caller's; only capture changes.
              expect(emitServiceDiagnostic(DiagnosticEvent.rpcFailed), isTrue);
            });
            expect(captureServiceDiagnosticEmitter(), same(callerEmitter));
            expect(emitterB.emit(DiagnosticEvent.rpcFailed), isTrue);
          }),
          zoneValues: {callerKey: callerValue},
        );
        expect(DiagnosticProducer.localEndpointCount, endpoints);
        expect(DiagnosticProducer.localRegistrationTimerCount, timers);
        producerA.close();
        runWithServiceDiagnostics(producerB, () {
          expect(captureServiceDiagnosticEmitter(), isNotNull);
          runWithServiceDiagnosticEmitter(emitterA, () {
            expect(captureServiceDiagnosticEmitter(), isNull);
          });
        });
        await session.close();
        await capture.closed.future.timeout(const Duration(seconds: 2));
        final events = capture.records.where((r) => r['event'] == 'rpc.failed');
        expect(events, hasLength(3));
        expect(events.map((r) => r['component']).toSet(), {
          'desktop',
          'service',
          'mcp',
        });
      } finally {
        await session.close();
        capture.dispose();
      }
    },
  );

  test(
    'emitter opener scope preserves result Future error and stack identity',
    () async {
      final marker = Object();
      expect(runWithServiceDiagnosticEmitter(null, () => marker), same(marker));
      final future = Future<Object>.value(marker);
      expect(runWithServiceDiagnosticEmitter(null, () => future), same(future));
      final failure = StateError('opener failure');
      final stack = StackTrace.fromString('original opener stack');
      try {
        runWithServiceDiagnosticEmitter<void>(null, () {
          Error.throwWithStackTrace(failure, stack);
        });
        fail('synchronous error was swallowed');
      } catch (error, caughtStack) {
        expect(error, same(failure));
        expect(caughtStack, same(stack));
      }
      final failed = Future<Object>.error(failure, stack);
      final returned = runWithServiceDiagnosticEmitter(null, () => failed);
      expect(returned, same(failed));
      try {
        await returned;
        fail('asynchronous error was swallowed');
      } catch (error, caughtStack) {
        expect(error, same(failure));
        expect(caughtStack, same(stack));
      }
    },
  );

  test(
    'off emitter opener scope allocates no endpoint or registration timer',
    () async {
      final off = await LoggingSession.startForTesting(
        configuration: DiagnosticConfiguration.fromEnvironment({
          'FORESIGHT_LOG_LEVEL': 'off',
        }),
        profilePath: createTestTempDirectorySync('emitter-owner-off-').path,
      );
      try {
        final captured = runWithServiceDiagnostics(
          off.producer,
          captureServiceDiagnosticEmitter,
        );
        expect(captured, isNull);
        await runWithServiceDiagnosticEmitter(captured, () async {
          await Future<void>.value();
          expect(captureServiceDiagnosticEmitter(), isNull);
        });
        expect(DiagnosticProducer.localEndpointCount, 0);
        expect(DiagnosticProducer.localRegistrationTimerCount, 0);
      } finally {
        await off.close();
      }
    },
  );

  test(
    'captured emitter retains owner across unbound callbacks and retires',
    () async {
      final capture = SinkCapture();
      final session = await LoggingSession.startForTesting(
        configuration: const DiagnosticConfiguration(),
        profilePath: createTestTempDirectorySync('captured-emitter-').path,
        sinkFactory: memorySink(capture.port.sendPort),
      );
      try {
        final emitter = runWithServiceDiagnostics(session.producer, () {
          final owner = captureServiceDiagnosticEmitter();
          expect(captureServiceDiagnosticEmitter(), same(owner));
          return owner!;
        }, component: DiagnosticComponent.mcp);
        expect(captureServiceDiagnosticEmitter(), isNull);
        expect(emitter.active, isTrue);
        expect(emitter.clockMicros(), isNotNull);
        expect(emitter.emit(DiagnosticEvent.rpcFailed), isTrue);
        await session.close();
        await capture.closed.future.timeout(const Duration(seconds: 2));
        expect(
          capture.records
              .where((r) => r['event'] == 'rpc.failed')
              .single['component'],
          'mcp',
        );
        expect(emitter.active, isFalse);
        expect(emitter.clockMicros(), isNull);
        var evaluated = false;
        expect(
          emitter.emit(
            DiagnosticEvent.rpcFailed,
            fields: () {
              evaluated = true;
              return {};
            },
          ),
          isFalse,
        );
        expect(evaluated, isFalse);
        final refused = session.producer.correlationRefused;
        emitter.noteCorrelationRefused();
        expect(session.producer.correlationRefused, refused);
      } finally {
        await session.close();
        capture.dispose();
      }
    },
  );
  for (final scenario in [
    'acquired',
    'contended',
    'withdrawn',
    'prelock',
    'unbound',
  ]) {
    test('actual profile lock reports causal $scenario ownership only', () async {
      final root = createTestTempDirectorySync('typed-lock-');
      final profile = ProfilePaths('${root.path}/data', '${root.path}/run');
      Process? holder;
      Future<String>? holderErrors;
      if (scenario == 'contended') {
        Directory(profile.data).createSync();
        final script = File('${root.path}/hold.dart')
          ..writeAsStringSync('''
import 'dart:io';
Future<void> main(List<String> args) async {
  final lock = File(args.single).openSync(mode: FileMode.append);
  lock.lockSync(FileLock.exclusive);
  stdout.writeln('locked');
  await stdin.first;
  lock.closeSync();
}
''');
        holder = await Process.start(Platform.resolvedExecutable, [
          script.path,
          '${profile.data}/.application.lock',
        ]);
        holderErrors = holder.stderr.transform(utf8.decoder).join();
        expect(
          await holder.stdout
              .transform(utf8.decoder)
              .transform(const LineSplitter())
              .first
              .timeout(const Duration(seconds: 3)),
          'locked',
        );
      } else if (scenario == 'prelock') {
        File(profile.data).writeAsStringSync('not a directory');
      }
      final capture = SinkCapture();
      final session = await LoggingSession.startForTesting(
        configuration: const DiagnosticConfiguration(),
        profilePath: '${root.path}/diagnostic-profile',
        role: DiagnosticRole.candidate,
        sinkFactory: memorySink(capture.port.sendPort),
      );
      final reporter = session.expectOwnershipDecision();
      RandomAccessFile? lock;
      Object? failure;
      Future<void> acquire() async {
        try {
          lock = await acquireServiceProfileLock(
            profile,
            launchWithdrawn: () => scenario == 'withdrawn',
          );
        } catch (error) {
          failure = error;
        }
      }

      try {
        if (scenario == 'unbound') {
          await acquire();
        } else {
          await runWithServiceDiagnostics<Future<void>>(
            session.producer,
            acquire,
            ownership: reporter,
          );
        }
        if (scenario == 'acquired' || scenario == 'unbound') {
          expect(failure, isNull);
          expect(lock, isNotNull);
        } else if (scenario == 'contended') {
          expect(failure, isA<ServiceOwnershipContended>());
        } else if (scenario == 'withdrawn') {
          expect(failure, isA<ServiceLaunchWithdrawn>());
        } else {
          expect(failure, isA<FileSystemException>());
        }
        // A conflicting late explicit/private report cannot replace the real
        // guard's one-shot decision. Outside the bound Zone, the hook is inert.
        reporter.report(
          scenario == 'acquired' || scenario == 'unbound'
              ? OwnershipDecision.contended
              : OwnershipDecision.acquired,
        );
        session.producer.emit(
          DiagnosticEvent.runtimeFailed,
          DiagnosticComponent.service,
        );
        await session.close();
        await capture.closed.future.timeout(const Duration(seconds: 2));
        final roles = capture.messages
            .whereType<Map>()
            .where((m) => m.containsKey('classified'))
            .map((m) => m['classified']);
        expect(
          roles,
          contains(scenario == 'acquired' ? 'service' : 'candidate'),
        );
        if (scenario != 'acquired') expect(roles, isNot(contains('service')));
      } finally {
        lock?.closeSync();
        if (holder != null) {
          holder.stdin.writeln('release');
          try {
            expect(
              await holder.exitCode.timeout(const Duration(seconds: 3)),
              0,
              reason: await holderErrors,
            );
          } finally {
            holder.kill();
          }
        }
        await session.close();
        capture.dispose();
      }
    });
  }

  test('client call identity is typed, bounded and event-specific', () {
    final call = DiagnosticIdentity.random();
    final record = DiagnosticRecord(
      DiagnosticEvent.rpcCompleted,
      DiagnosticComponent.mcp,
      fields: {
        DiagnosticField.call: call,
        DiagnosticField.outcome: DiagnosticOutcome.completed,
      },
      request: 17,
      attempt: 2,
    );
    final wire = record.toWire()!;
    expect((wire['fields'] as Map)['call'], call.value);
    expect(DiagnosticRecord.validWire(jsonDecode(jsonEncode(wire))), isTrue);
    for (final malformed in ['a' * 31, 'A' * 32, 'https://private.invalid']) {
      final invalid = jsonDecode(jsonEncode(wire)) as Map<String, dynamic>;
      (invalid['fields'] as Map)['call'] = malformed;
      expect(DiagnosticRecord.validWire(invalid), isFalse);
    }
    expect(
      DiagnosticRecord(
        DiagnosticEvent.rpcCompleted,
        DiagnosticComponent.mcp,
        fields: {DiagnosticField.call: call.value},
      ).toWire(),
      isNull,
    );
    expect(
      DiagnosticRecord(
        DiagnosticEvent.rpcConnectionChanged,
        DiagnosticComponent.mcp,
        fields: {DiagnosticField.call: call},
      ).toWire(),
      isNull,
    );
  });
  test('unbound public diagnostic status remains unknown', () {
    final snapshot = serviceDiagnosticHealth();
    expect(snapshot.known, isFalse);
    expect(snapshot.state, DiagnosticHealthState.unknown);
  });
  test(
    'registry observes settled results without changing handler ownership',
    () async {
      final messages = ReceivePort();
      final closed = Completer<void>();
      final records = <Map<String, dynamic>>[];
      final initialRecords = Completer<void>();
      final listener = messages.listen((value) {
        if (value == null) {
          closed.complete();
        } else {
          records.add(
            jsonDecode(utf8.decode(value as Uint8List)) as Map<String, dynamic>,
          );
          if (!initialRecords.isCompleted &&
              records.where((r) => r['event'] == 'rpc.completed').length == 2 &&
              records.where((r) => r['event'] == 'rpc.failed').length == 2) {
            initialRecords.complete();
          }
        }
      });
      final session = await LoggingSession.startForTesting(
        configuration: const DiagnosticConfiguration(
          level: DiagnosticLevel.debug,
        ),
        profilePath: createTestTempDirectorySync('typed-registry-').path,
        sinkFactory: _factory(messages.sendPort),
      );
      FutureOr<Object?> Function() action = () => null;
      bool Function()? observedCurrent;
      final registry = OperationRegistry(OperationScope.application, [
        for (final operation in Operation.values)
          if (operation.descriptor.scope == OperationScope.application)
            TypedOperationHandler<OperationRequest>(operation, (
              request, {
              current,
            }) {
              observedCurrent = current;
              return action();
            }),
      ]);
      final request = decodeOperationRequest(Operation.status, {});
      final sentinel = Object();
      bool current() => true;
      try {
        await runWithServiceDiagnostics<
          Future<void>
        >(session.producer, () async {
          action = () => sentinel;
          // Synchronous admission and returned object remain synchronous/identical.
          expect(registry.invoke(request, current: current), same(sentinel));
          expect(observedCurrent, same(current));
          final pending = Completer<Object?>();
          action = () => pending.future;
          final result = registry.invoke(request);
          expect(pending.isCompleted, isFalse);
          pending.complete(sentinel);
          expect(await result, same(sentinel));
          final cancelled = RpcError(
            RpcErrorCode.cancelled,
            'private request content',
          );
          action = () => throw cancelled;
          expect(() => registry.invoke(request), throwsA(same(cancelled)));
          final failure = _PrivateFailure();
          action = () => Future<Object?>.error(failure);
          await expectLater(registry.invoke(request), throwsA(same(failure)));
          final controller = StreamController<Object?>();
          final stream = controller.stream;
          action = () => stream;
          // A returned stream has not completed the RPC. It stays unwrapped and
          // unlistened; the existing service still owns subscription/cancellation.
          expect(registry.invoke(request), same(stream));
          expect(controller.hasListener, isFalse);
          unawaited(controller.close());

          await initialRecords.future.timeout(const Duration(seconds: 2));
          // Exact positive controls precede the intentional saturation burst.
          // Normal delivery during that burst remains lossy by contract.
          expect(
            records.where((r) => r['event'] == 'rpc.completed'),
            hasLength(2),
          );
          expect(
            records.where((r) => r['event'] == 'rpc.failed'),
            hasLength(2),
          );
          final pendingOperations = [Completer<Object?>()];
          final observed = <Future<Object?>>[];
          for (final pending in pendingOperations) {
            action = () => pending.future;
            observed.add(registry.invoke(request) as Future<Object?>);
          }
          final excess = Completer<Object?>();
          action = () => excess.future;
          final refusedBefore = session.producer.correlationRefused;
          final observationBefore = serviceDiagnosticObservation();
          expect(observationBefore['capacity'], 1);
          expect(observationBefore['active'], 1);
          // Saturation affects diagnostics only: preserve the application future.
          expect(registry.invoke(request), same(excess.future));
          expect(session.producer.correlationRefused, refusedBefore + 1);
          expect(
            serviceDiagnosticObservation()['refused'],
            (observationBefore['refused'] as int) + 1,
          );
          for (final pending in pendingOperations) {
            pending.complete(sentinel);
          }
          expect(await Future.wait(observed), everyElement(same(sentinel)));
          excess.complete(sentinel);
          await excess.future;
          action = () => sentinel;
          expect(registry.invoke(request), same(sentinel));
          expect(session.producer.correlationRefused, refusedBefore + 1);
          expect(serviceDiagnosticObservation()['active'], 0);
          expect(
            serviceDiagnosticObservation()['admitted'],
            (observationBefore['admitted'] as int) + 1,
          );
        });
        await session.close();
        await closed.future.timeout(const Duration(seconds: 2));
        final completed = records
            .where((r) => r['event'] == 'rpc.completed')
            .toList();
        final failed = records
            .where((r) => r['event'] == 'rpc.failed')
            .toList();
        expect(completed.length, greaterThanOrEqualTo(2));
        expect(failed, hasLength(2));
        expect(
          [
            ...completed,
            ...failed,
          ].every((r) => (r['fields'] as Map)['operation'] == 'status'),
          isTrue,
        );
        expect(jsonEncode(records), isNot(contains('private')));
      } finally {
        await session.close();
        await listener.cancel();
        messages.close();
      }
    },
  );

  test('MCP startup and transport use their own closed component', () async {
    final messages = ReceivePort();
    final closed = Completer<void>();
    final records = <Map<String, dynamic>>[];
    final listener = messages.listen((value) {
      if (value == null) {
        closed.complete();
      } else {
        records.add(
          jsonDecode(utf8.decode(value as Uint8List)) as Map<String, dynamic>,
        );
      }
    });
    final session = await LoggingSession.startForTesting(
      configuration: const DiagnosticConfiguration(
        level: DiagnosticLevel.trace,
      ),
      profilePath: createTestTempDirectorySync('typed-mcp-').path,
      sinkFactory: _factory(messages.sendPort),
    );
    try {
      await startServiceDiagnostics(
        session.producer,
        component: DiagnosticComponent.mcp,
      );
      runWithServiceDiagnostics(session.producer, () {
        final call = DiagnosticIdentity.random();
        expect(
          emitServiceDiagnostic(
            DiagnosticEvent.rpcCompleted,
            request: 17,
            attempt: 2,
            fields: () => {
              DiagnosticField.call: call,
              DiagnosticField.outcome: DiagnosticOutcome.completed,
            },
          ),
          isTrue,
        );
        traceServiceTransport(() => throw StateError('private callback'));
        requestFailure(
          RpcError(RpcErrorCode.internal, 'private'),
          StackTrace.empty,
        );
      }, component: DiagnosticComponent.mcp);
      final off = await LoggingSession.startForTesting(
        configuration: const DiagnosticConfiguration(
          level: DiagnosticLevel.off,
        ),
      );
      runWithServiceDiagnostics(session.producer, () {
        runWithServiceDiagnostics(off.producer, () {
          expect(captureServiceDiagnosticEmitter(), isNull);
          expect(serviceDiagnosticClockMicros(), isNull);
        });
      });
      await off.close();
      await session.close();
      await closed.future.timeout(const Duration(seconds: 2));
      expect(records.where((r) => r['event'] == 'mcp.starting'), hasLength(1));
      expect(records.where((r) => r['event'] == 'service.starting'), isEmpty);
      expect(
        records.where((r) => r['event'] == 'transport.activity'),
        hasLength(1),
      );
      expect(
        records.every(
          (r) => r['component'] == 'mcp' || r['component'] == 'logging',
        ),
        isTrue,
      );
    } finally {
      await session.close();
      await listener.cancel();
      messages.close();
    }
  });

  for (final level in [
    'off',
    'error',
    'warn',
    'info',
    'debug',
    'invalid',
    'trace',
    null,
  ]) {
    test(
      'typed transport respects canonical level $level without formatting',
      () async {
        final messages = ReceivePort();
        final closed = Completer<void>();
        final records = <Map<String, dynamic>>[];
        final listener = messages.listen((value) {
          if (value == null) {
            if (!closed.isCompleted) closed.complete();
          } else {
            records.add(
              jsonDecode(utf8.decode(value as Uint8List))
                  as Map<String, dynamic>,
            );
          }
        });
        final configuration = DiagnosticConfiguration.fromEnvironment({
          'FORESIGHT_SERVICE_TRACE': '1',
          if (level != null) 'FORESIGHT_LOG_LEVEL': level,
        });
        final port = messages.sendPort;
        final session = await LoggingSession.startForTesting(
          configuration: configuration,
          profilePath: createTestTempDirectorySync('typed-trace-').path,
          sinkFactory: _factory(port),
        );
        try {
          await startServiceDiagnostics(session.producer);
          runWithServiceDiagnostics(session.producer, () {
            expect(serviceDiagnosticHealth().level, configuration.level);
            if (!configuration.enabled) {
              expect(
                serviceDiagnosticHealth().state,
                DiagnosticHealthState.off,
              );
              expect(serviceDiagnosticHealth().known, isTrue);
            }
          });
          var evaluated = false;
          final failure = RpcError(
            RpcErrorCode.internal,
            'private-token https://private.invalid /private/path',
          );
          runWithServiceDiagnostics(session.producer, () {
            traceServiceTransport(() {
              evaluated = true;
              throw StateError('private callback');
            });
            expect(
              requestFailure(failure, StackTrace.fromString('private-stack')),
              same(failure),
            );
          });
          expect(evaluated, isFalse);
          if (!configuration.enabled) {
            runWithServiceDiagnostics(session.producer, () {
              expect(captureServiceDiagnosticEmitter(), isNull);
              expect(serviceDiagnosticClockMicros(), isNull);
              expect(
                emitServiceDiagnostic(
                  DiagnosticEvent.rpcCompleted,
                  fields: () => throw StateError('off builder evaluated'),
                ),
                isFalse,
              );
              noteServiceDiagnosticCorrelationRefused();
            });
            expect(DiagnosticProducer.localEndpointCount, 0);
            expect(DiagnosticProducer.localRegistrationTimerCount, 0);
          }
          await session.close();
          if (configuration.enabled) {
            await closed.future.timeout(const Duration(seconds: 2));
          }
          final transport = records
              .where(
                (r) => r['event'] == DiagnosticEvent.transportActivity.wire,
              )
              .toList();
          expect(
            transport,
            hasLength(
              configuration.permits(DiagnosticLevel.trace, transport: true)
                  ? 1
                  : 0,
            ),
          );
          expect(
            records.where((r) => r['event'] == DiagnosticEvent.rpcFailed.wire),
            hasLength(configuration.enabled ? 1 : 0),
          );
          expect(
            records.where((r) => r['event'] == 'service.starting'),
            hasLength(configuration.permits(DiagnosticLevel.info) ? 1 : 0),
          );
          expect(
            records.every(
              (r) => r['component'] == 'service' || r['component'] == 'logging',
            ),
            isTrue,
          );
          expect(jsonEncode(records), isNot(contains('private')));
        } finally {
          await session.close();
          await listener.cancel();
          messages.close();
        }
      },
    );
  }

  test(
    'held real writer does not block service readiness beyond its logging bound',
    () async {
      final root = createTestTempDirectorySync('trace-ready-');
      final source = File('${root.path}/hold.cpp')
        ..writeAsStringSync(r"""
#include <atomic>
#include <unistd.h>
static std::atomic<bool> released{false};
extern "C" void hold_writer() { while (!released.load()) usleep(1000); }
extern "C" void release_writer() { released.store(true); }
""");
      final path = '${root.path}/hold.${Platform.isMacOS ? 'dylib' : 'so'}';
      await buildCachedNativeFixture(source: source.path, output: path);
      final release = DynamicLibrary.open(
        path,
      ).lookupFunction<Void Function(), void Function()>('release_writer');
      final messages = ReceivePort();
      final entered = Completer<void>();
      final records = <Map<String, dynamic>>[];
      final listener = messages.listen((value) {
        if (value == 'entered' && !entered.isCompleted) entered.complete();
        if (value is Uint8List) {
          records.add(jsonDecode(utf8.decode(value)) as Map<String, dynamic>);
        }
      });
      final port = messages.sendPort;
      final session = await LoggingSession.startForTesting(
        configuration: const DiagnosticConfiguration(),
        profilePath: root.path,
        sinkFactory: _factory(port, path),
      );
      try {
        session.producer.emit(
          DiagnosticEvent.rpcFailed,
          DiagnosticComponent.service,
        );
        await entered.future.timeout(const Duration(seconds: 2));
        final producer = session.registerProducer(
          DiagnosticProducerKind.domain,
        );
        final elapsed = Stopwatch()..start();
        await waitForServiceDiagnostics(producer);
        expect(elapsed.elapsed, lessThan(const Duration(milliseconds: 500)));
        // The application continuation is reached while the actual writer is held.
        var continued = false;
        runWithServiceDiagnostics(producer, () => continued = true);
        expect(continued, isTrue);
        // The one pending startup continuation must tolerate late registration
        // after its producer has closed, without reviving or emitting.
        await startServiceDiagnostics(producer);
        producer.close();
        release();
        await producer.ready.timeout(const Duration(seconds: 2));
        expect(producer.active, isFalse);
      } finally {
        release();
        await session.close();
        await Future<void>.delayed(Duration.zero);
        expect(records.where((r) => r['event'] == 'service.starting'), isEmpty);
        // A late startup continuation cannot revive a retired producer.
        await startServiceDiagnostics(session.producer);
        expect(session.producer.active, isFalse);
        await listener.cancel();
        messages.close();
      }
    },
  );
}
