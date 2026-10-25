import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:foresight_core/src/diagnostics/session.dart';
import 'package:foresight_core/src/native.dart';
import 'package:foresight_core/src/native_diagnostics.dart';
import 'package:foresight_core/src/native_lifetime.dart';
import 'package:foresight_test_support/poll.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';

import '../native_diagnostics_test.dart' as fixture;
import 'test_sinks.dart';

Future<NativeRuntime> runtimeImage({bool legacy = false}) async {
  final root = createTestTempDirectorySync('native-adapter-');
  final path = '${root.path}/runtime.${Platform.isMacOS ? 'dylib' : 'so'}';
  await fixture.compile(path, legacy: legacy);
  return NativeRuntime(path);
}

int Function(int) emitter(NativeRuntime runtime) {
  runtime.lib.lookupFunction<Void Function(), void Function()>(
    'fs_test_configure',
  )();
  return runtime.lib.lookupFunction<Int32 Function(Int32), int Function(int)>(
    'fs_test_enqueue',
  );
}

void main() {
  test('fixed native fields fit the pre-drain writer credit envelope', () {
    for (final category in DiagnosticCategory.values) {
      for (final outcome in DiagnosticOutcome.values) {
        for (final priority in [false, true]) {
          final wire = DiagnosticRecord(
            priority
                ? DiagnosticEvent.nativeWorkerFailed
                : DiagnosticEvent.captureStateChanged,
            priority ? DiagnosticComponent.native : DiagnosticComponent.capture,
            fields: {
              DiagnosticField.category: category,
              DiagnosticField.outcome: outcome,
              DiagnosticField.precisionLost: true,
              if (priority) ...{
                DiagnosticField.status: -2147483647,
                DiagnosticField.signal: -2147483647,
                DiagnosticField.bytes: 2147483647,
                DiagnosticField.dropped: 2147483647,
              } else ...{
                DiagnosticField.queued: 2147483647,
                DiagnosticField.active: true,
                DiagnosticField.durationUs: 2147483647,
              },
            },
          ).toWire();
          expect(wire, isNotNull);
          expect(
            utf8.encode(jsonEncode(wire)).length,
            lessThanOrEqualTo(LoggingSession.maximumNativeProducerEventBytes),
          );
        }
      }
    }
  });

  test(
    'normal NativeRuntime load reaches the writer through shared credits',
    () async {
      final capture = SinkCapture();
      addTearDown(capture.dispose);
      final session = await LoggingSession.startForTesting(
        configuration: const DiagnosticConfiguration(),
        profilePath: 'selected-private-profile',
        sinkFactory: memorySink(capture.port.sendPort),
      );
      addTearDown(session.close);
      final runtime = await runtimeImage();
      final enqueue = emitter(runtime);
      expect(enqueue(0), 1);
      expect(enqueue(1), 1);
      await eventually(
        () => capture.records.any((r) => r['event'] == 'native.worker_failed'),
      );
      await eventually(
        () => capture.records.any((r) => r['event'] == 'capture.state_changed'),
      );
      final native = capture.records
          .where((r) => (r['producer'] as String).startsWith('nativeDrain:'))
          .toList();
      expect(native, hasLength(2));
      expect(
        native.first['sequence'] as int,
        lessThan(native.last['sequence'] as int),
      );
      final budget = await session.inspectBudgetForTesting();
      expect(
        budget.producerBytes,
        lessThanOrEqualTo(LoggingSession.maximumProducerEventBytes),
      );
      expect(
        budget.producerRecords,
        lessThanOrEqualTo(LoggingSession.maximumProducerEventRecords),
      );
      final closed = await session.close();
      expect(closed.writerExited, isTrue);
      expect(closed.flushed, isTrue);
      final reopened = NativeDiagnosticQueue.tryOpen(
        NativeLibrary(runtime.lib),
      )!;
      addTearDown(() => expect(reopened.close(), isTrue));
      expect(reopened.close(), isTrue);
    },
  );

  test(
    'wide native counters retain the event and explicitly mark approximation',
    () async {
      final capture = SinkCapture();
      addTearDown(capture.dispose);
      final session = await LoggingSession.startForTesting(
        configuration: const DiagnosticConfiguration(),
        profilePath: 'selected-private-profile',
        sinkFactory: memorySink(capture.port.sendPort),
      );
      addTearDown(session.close);
      final runtime = await runtimeImage();
      runtime.lib.lookupFunction<Void Function(), void Function()>(
        'fs_test_maximum_fields',
      )();
      await eventually(
        () => capture.records.any((r) => r['event'] == 'native.worker_failed'),
      );
      await eventually(
        () => capture.records.any((r) => r['event'] == 'capture.state_changed'),
      );
      final failed =
          capture.records.firstWhere(
                (r) => r['event'] == 'native.worker_failed',
              )['fields']
              as Map;
      expect(failed['bytes'], 2147483647);
      expect(failed['dropped'], 2147483647);
      expect(failed.containsKey('status'), isFalse);
      expect(failed.containsKey('signal'), isFalse);
      expect(failed['precisionLost'], isTrue);
      final state =
          capture.records.firstWhere(
                (r) => r['event'] == 'capture.state_changed',
              )['fields']
              as Map;
      expect(state['queued'], 2147483647);
      expect(state['durationUs'], 2147483647);
      expect(state['precisionLost'], isTrue);
      expect(session.health.nativeDropsExact, isFalse);
      expect(
        capture.records.any(
          (r) =>
              r['event'] == 'logging.records_dropped' &&
              (r['fields'] as Map)['precisionLost'] == true,
        ),
        isTrue,
      );
    },
  );

  test(
    'effective canonical native level preserves invalid and transport alias rules',
    () async {
      for (final raw in [
        {'FORESIGHT_LOG_LEVEL': 'invalid', 'FORESIGHT_SERVICE_TRACE': '1'},
        {'FORESIGHT_SERVICE_TRACE': '1'},
      ]) {
        final capture = SinkCapture();
        addTearDown(capture.dispose);
        final configuration = DiagnosticConfiguration.fromEnvironment(raw);
        final session = await LoggingSession.startForTesting(
          configuration: configuration,
          profilePath: 'selected-private-profile',
          sinkFactory: memorySink(capture.port.sendPort),
        );
        addTearDown(session.close);
        final runtime = await runtimeImage();
        await eventually(
          () => session.health.nativeReason == NativeDiagnosticHealth.healthy,
        );
        expect(
          runtime.lib.lookupFunction<Int32 Function(), int Function()>(
            'fs_test_level',
          )(),
          3,
        );
        expect(configuration.level, DiagnosticLevel.info);
        expect(
          configuration.transportTrace,
          !raw.containsKey('FORESIGHT_LOG_LEVEL'),
        );
        expect(
          raw['FORESIGHT_LOG_LEVEL'],
          raw.containsKey('FORESIGHT_LOG_LEVEL') ? 'invalid' : isNull,
        );
        final helperEnvironment = nativeHelperEnvironment(raw);
        expect(helperEnvironment['FORESIGHT_LOG_LEVEL'], 'info');
        expect(
          raw['FORESIGHT_LOG_LEVEL'],
          raw.containsKey('FORESIGHT_LOG_LEVEL') ? 'invalid' : isNull,
        );
        expect((await session.close()).writerExited, isTrue);
      }
    },
  );

  test(
    'off and old native images do not create a native drain producer',
    () async {
      for (final off in [true, false]) {
        final session = await LoggingSession.startForTesting(
          configuration: DiagnosticConfiguration(
            level: off ? DiagnosticLevel.off : DiagnosticLevel.info,
          ),
        );
        final runtime = await runtimeImage(legacy: !off);
        if (off) {
          expect(
            runtime.lib.lookupFunction<Int32 Function(), int Function()>(
              'fs_test_pin_calls',
            )(),
            0,
          );
        } else {
          await eventually(
            () =>
                session.health.nativeReason ==
                NativeDiagnosticHealth.unsupported,
          );
          expect(
            (await session.inspectBudgetForTesting()).producers,
            hasLength(1),
          );
        }
        final result = await session.close();
        expect(result.writerExited, isTrue);
      }
    },
  );

  test(
    'capacity never drains before native writer leases and recovers after retirement',
    () async {
      final capture = SinkCapture();
      addTearDown(capture.dispose);
      final session = await LoggingSession.startForTesting(
        configuration: const DiagnosticConfiguration(),
        profilePath: 'selected-private-profile',
        sinkFactory: memorySink(capture.port.sendPort),
      );
      final extras = [
        for (var at = 1; at < LoggingSession.maximumProducers; at++)
          session.reserveProducer(DiagnosticProducerKind.parser).connect(),
      ];
      addTearDown(() async {
        for (final producer in extras) {
          producer.close();
        }
        await session.close();
      });
      await Future.wait(extras.map((p) => p.ready));
      final runtime = await runtimeImage();
      final enqueue = emitter(runtime);
      expect(enqueue(1), 1);
      await eventually(
        () => session.health.nativeReason == NativeDiagnosticHealth.capacity,
      );
      final manual = NativeDiagnosticQueue.tryOpen(NativeLibrary(runtime.lib))!;
      var retained = 0;
      expect(
        manual
            .poll(
              capacity: 1,
              priorityOnly: true,
              onRecord: (_) {
                retained++;
                return true;
              },
            )!
            .count,
        1,
      );
      expect(retained, 1);
      expect(manual.close(), isTrue);
      extras.last.close();
      await extras.last.retired;
      expect(enqueue(1), 1);
      await eventually(
        () => capture.records.any((r) => r['event'] == 'native.worker_failed'),
      );
      for (final producer in extras) {
        producer.close();
      }
      await Future.wait(extras.map((p) => p.retired));
      expect((await session.close()).writerExited, isTrue);
    },
  );

  test(
    'busy native close retains the consumer until a later existing tick',
    () async {
      final session = await LoggingSession.startForTesting(
        configuration: const DiagnosticConfiguration(),
      );
      final runtime = await runtimeImage();
      await eventually(
        () => session.health.nativeReason == NativeDiagnosticHealth.healthy,
      );
      final gate = runtime.lib
          .lookupFunction<Void Function(Int32), void Function(int)>(
            'fs_test_gate',
          );
      addTearDown(() async {
        gate(0);
        await session.close();
      });
      gate(1);
      final closing = session.close();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(NativeDiagnosticQueue.tryOpen(NativeLibrary(runtime.lib)), isNull);
      gate(0);
      final result = await closing;
      expect(result.writerExited, isTrue);
      expect(result.flushed, isFalse);
      final reopened = NativeDiagnosticQueue.tryOpen(
        NativeLibrary(runtime.lib),
      )!;
      expect(reopened.close(), isTrue);
    },
  );
}
