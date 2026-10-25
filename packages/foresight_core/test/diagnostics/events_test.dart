import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:foresight_core/src/diagnostics/code_locations.g.dart';
import 'package:foresight_core/src/diagnostics/events.dart';
import 'package:test/test.dart';

void main() {
  test('allocation-free wire byte count matches the standard UTF8 encoder', () {
    final cases = <String>[
      '',
      'registered.ascii',
      for (final unit in [
        0x7f,
        0x80,
        0x7ff,
        0x800,
        0xd7ff,
        0xd800,
        0xdbff,
        0xdc00,
        0xdfff,
        0xe000,
        0xffff,
      ])
        String.fromCharCode(unit),
      String.fromCharCodes([0xd800, 0xdc00, 0xdbff, 0xdfff]),
      String.fromCharCodes([0xd800, 0xd800, 0xdc00, 0xdc00]),
    ];
    final random = Random(47941);
    for (var sample = 0; sample < 1000; sample++) {
      cases.add(
        String.fromCharCodes(
          List.generate(random.nextInt(128), (i) => random.nextInt(65536)),
        ),
      );
    }
    for (final text in cases) {
      expect(DiagnosticRecord.utf8Length(text), utf8.encode(text).length);
      final json = jsonEncode({'value': text});
      expect(DiagnosticRecord.utf8Length(json), utf8.encode(json).length);
    }
  });
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
  test('raw hostile stack is omitted without formatting', () {
    final hostile = _ThrowingStack();
    final stack = SafeDiagnosticStack.encode(
      hostile,
      DiagnosticCategory.internal,
    );
    expect(stack.frames, isEmpty);
    expect(hostile.called, isFalse);
    expect(jsonEncode(stack.toWire()), isNot(contains('private stack canary')));
    expect(DiagnosticOperation.parse('private payload canary'), isNull);
  });

  test(
    'bounded stack inputs reject oversized text and unregistered numeric frames',
    () {
      final code = diagnosticCodeLocations.indexOf('src/store.dart');
      final valid = SafeDiagnosticStack.fromRegisteredLocations([
        [code, 42, 3],
      ], DiagnosticCategory.internal);
      expect(valid.frames, [
        [code, 42, 3],
      ]);
      expect(
        DiagnosticRecord.validWire(
          DiagnosticRecord(
            DiagnosticEvent.runtimeFailed,
            DiagnosticComponent.service,
            fields: {DiagnosticField.category: DiagnosticCategory.internal},
            stack: valid,
          ).toWire(),
        ),
        isTrue,
      );
      final oversized = SafeDiagnosticStack.fromBoundedText(
        'x' * (SafeDiagnosticStack.maximumInputCharacters + 1),
        DiagnosticCategory.internal,
      );
      expect(oversized.frames, isEmpty);
      final invalid = SafeDiagnosticStack.fromRegisteredLocations([
        [-1, 1, 1],
        [diagnosticCodeLocations.length, 1, 1],
        [code, -1, 1],
        [code, 10000000, 1],
        [code, 1, 100000],
        [code, 1],
      ], DiagnosticCategory.internal);
      expect(invalid.frames, isEmpty);
      expect(
        SafeDiagnosticStack.fromRegisteredLocations(
          List.generate(9, (_) => [code, 1, 1]),
          DiagnosticCategory.internal,
        ).frames,
        isEmpty,
      );
      expect(
        SafeDiagnosticStack.encode(
          StackTrace.fromString(
            '#0 secret (package:foresight_core/src/store.dart:42:3)',
          ),
          DiagnosticCategory.internal,
        ).frames,
        isEmpty,
      );
    },
  );
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
  test(
    'bounded stack scanner rejects prefixes and malformed coordinates without losing later frames',
    () {
      final projection = SafeDiagnosticStack.fromBoundedText(
        '(package:foresight_core/src/store.dart.evil:1:1)\n'
        '(package:foresight_core/src/store.dart:99999999:1)\n'
        '(package:foresight_core/src/store.dart:1:999999)\n'
        '(package:foresight_core/src/store.dart::1)\n'
        '(package:foresight_core/src/store.dart:1:-1)\n'
        '(package:foresight_core/src/store.dart:1234567:12345)',
        DiagnosticCategory.internal,
      );
      expect(projection.frames, [
        [diagnosticCodeLocations.indexOf('src/store.dart'), 1234567, 12345],
      ]);
      final unknown = '(package:foresight_core/unknown.dart:1:1)\n';
      final bounded =
          unknown *
          (SafeDiagnosticStack.maximumInputCharacters ~/ unknown.length);
      expect(
        bounded.length,
        lessThanOrEqualTo(SafeDiagnosticStack.maximumInputCharacters),
      );
      expect(
        SafeDiagnosticStack.fromBoundedText(
          bounded,
          DiagnosticCategory.internal,
        ).frames,
        isEmpty,
      );
    },
  );
  test('stack encoder omits messages symbols and every unregistered path', () {
    final stack = SafeDiagnosticStack.fromBoundedText(
      '#0 secret.function (package:foresight_core/src/store.dart:42:3)\n#1 leak (/home/secret/user/data.dart:1:2)\n#2 forged (package:foresight_core/src/secret-canary.dart:3:4)',
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
    for (final invalid in [
      'a' * 63,
      'a' * 65,
      'A' * 64,
      '${'a' * 63}\n',
      '${'a' * 64}\n',
      'ａ' * 64,
      '${'a' * 63}g',
    ]) {
      (forged['stack'] as Map)['fingerprint'] = invalid;
      expect(DiagnosticRecord.validWire(forged), isFalse);
    }
  });
  test(
    'diagnostic identities are random shape-bound and never business strings',
    () {
      final first = DiagnosticIdentity.random(),
          second = DiagnosticIdentity.random();
      expect(first.value, isNot(second.value));
      expect(DiagnosticIdentity.parse(first.value)!.value, first.value);
      for (final value in ['0' * 32, 'abcdef0123456789' * 2]) {
        expect(DiagnosticIdentity.parse(value)!.value, value);
      }
      for (final value in [
        '',
        'meeting-1',
        'request-secret',
        'X' * 32,
        '0' * 31,
        '0' * 33,
        '${'a' * 31}\n',
        '${'a' * 32}\n',
        'ａ' * 32,
        '0' * 31 + 'g',
      ]) {
        expect(DiagnosticIdentity.parse(value), isNull);
      }
    },
  );
}

final class _ThrowingStack implements StackTrace {
  bool called = false;
  @override
  String toString() {
    called = true;
    throw StateError('private stack canary');
  }
}
