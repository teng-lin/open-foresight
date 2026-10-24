import 'dart:convert';
import 'dart:io';

import 'package:foresight_core/src/diagnostics/code_locations.g.dart';
import 'package:foresight_core/src/diagnostics/events.dart';
import 'package:test/test.dart';

void main() {
  test(
    'generated diagnostic catalogs match the current operation and source inventory',
    () async {
      final child = await Process.start(Platform.resolvedExecutable, [
        'tool/generate_diagnostics_catalog.dart',
        '--check',
      ]);
      final output = child.stdout.transform(utf8.decoder).join();
      final errors = child.stderr.transform(utf8.decoder).join();
      int? status;
      try {
        status = await child.exitCode.timeout(const Duration(seconds: 15));
        expect(status, 0, reason: '${await output}${await errors}');
      } finally {
        if (status == null) {
          child.kill(ProcessSignal.sigkill);
          await child.exitCode.timeout(const Duration(seconds: 2));
        }
      }
    },
  );
  test('stack formatting failure yields safe empty projection', () {
    final stack = SafeDiagnosticStack.encode(
      _ThrowingStack(),
      DiagnosticCategory.internal,
    );
    expect(stack.frames, isEmpty);
    expect(jsonEncode(stack.toWire()), isNot(contains('private stack canary')));
    expect(DiagnosticOperation.parse('private payload canary'), isNull);
  });

  test(
    'configuration resolves explicit off invalid and transport-only legacy precedence',
    () {
      expect(
        DiagnosticConfiguration.fromEnvironment({}).level,
        DiagnosticLevel.info,
      );
      final trace = DiagnosticConfiguration.fromEnvironment({
        'FORESIGHT_SERVICE_TRACE': '1',
      });
      expect(trace.level, DiagnosticLevel.info);
      expect(trace.permits(DiagnosticLevel.trace, transport: true), isTrue);
      expect(trace.permits(DiagnosticLevel.trace), isFalse);
      for (final level in DiagnosticLevel.values) {
        final explicit = DiagnosticConfiguration.fromEnvironment({
          'FORESIGHT_LOG_LEVEL': level.name,
          'FORESIGHT_SERVICE_TRACE': '1',
        });
        expect(explicit.level, level);
        expect(explicit.transportTrace, isFalse);
      }
      final invalid = DiagnosticConfiguration.fromEnvironment({
        'FORESIGHT_LOG_LEVEL': 'secret/path',
      });
      expect(invalid.level, DiagnosticLevel.info);
      expect(invalid.invalidLevel, isTrue);
    },
  );
  test('records accept only registered per-event scalar fields', () {
    final record = DiagnosticRecord(
      DiagnosticEvent.rpcCompleted,
      DiagnosticComponent.service,
      fields: {
        DiagnosticField.operation: DiagnosticOperation.parse('status')!,
        DiagnosticField.durationUs: 123,
        DiagnosticField.outcome: DiagnosticOutcome.completed,
      },
    );
    expect(DiagnosticRecord.validWire(record.toWire()), isTrue);
    for (final content in [
      'secret content',
      'status',
      'https://private.test/account',
      Exception('secret'),
    ]) {
      expect(
        DiagnosticRecord(
          DiagnosticEvent.rpcCompleted,
          DiagnosticComponent.service,
          fields: {DiagnosticField.operation: content},
        ).toWire(),
        isNull,
      );
    }
    expect(
      DiagnosticRecord(
        DiagnosticEvent.rpcCompleted,
        DiagnosticComponent.service,
        fields: {DiagnosticField.bytes: 1},
      ).toWire(),
      isNull,
    );
    expect(
      DiagnosticRecord(
        DiagnosticEvent.invalidFrame,
        DiagnosticComponent.service,
        fields: {DiagnosticField.bytes: -1},
      ).toWire(),
      isNull,
    );
    final wire = record.toWire()!..['body'] = 'CANARY';
    expect(DiagnosticRecord.validWire(wire), isFalse);
  });
  test('stack encoder omits messages symbols and every unregistered path', () {
    final stack = SafeDiagnosticStack.encode(
      StackTrace.fromString(
        '#0 secret.function (package:foresight_core/src/store.dart:42:3)\n#1 leak (/home/secret/user/data.dart:1:2)\n#2 forged (package:foresight_core/src/secret-canary.dart:3:4)',
      ),
      DiagnosticCategory.internal,
    );
    expect(stack.frames, [
      [diagnosticCodeLocations.indexOf('src/store.dart'), 42, 3],
    ]);
    final record = DiagnosticRecord(
      DiagnosticEvent.runtimeFailed,
      DiagnosticComponent.service,
      fields: {DiagnosticField.category: DiagnosticCategory.internal},
      stack: stack,
    );
    final wire = record.toWire()!;
    expect(DiagnosticRecord.validWire(wire), isTrue);
    final json = jsonEncode(wire);
    for (final value in ['secret', '/home', 'store.dart', 'function']) {
      expect(json.contains(value), isFalse, reason: value);
    }
    final forged = jsonDecode(json) as Map<String, dynamic>;
    (forged['stack'] as Map)['fingerprint'] = '0' * 64;
    expect(DiagnosticRecord.validWire(forged), isFalse);
  });
  test(
    'diagnostic identities are random shape-bound and never business strings',
    () {
      final first = DiagnosticIdentity.random(),
          second = DiagnosticIdentity.random();
      expect(first.value, isNot(second.value));
      expect(DiagnosticIdentity.parse(first.value)!.value, first.value);
      for (final value in ['meeting-1', 'request-secret', 'X' * 32, '0' * 33]) {
        expect(DiagnosticIdentity.parse(value), isNull);
      }
    },
  );
}

final class _ThrowingStack implements StackTrace {
  @override
  String toString() => throw StateError('private stack canary');
}
