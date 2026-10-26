import 'dart:convert';

import 'package:foresight_core/src/diagnostics/bounded_json.dart';
import 'package:foresight_core/src/diagnostics/code_locations.g.dart';
import 'package:foresight_core/src/diagnostics/events.dart';
import 'package:foresight_core/src/diagnostics/operations.g.dart';
import 'package:test/test.dart';

void main() {
  test('all event field subsets match standard JSON in both wire schemas', () {
    final operation =
        (diagnosticOperations.toList()
              ..sort((a, b) => b.length.compareTo(a.length)))
            .first;
    final identity = DiagnosticIdentity.parse('f' * 32)!;
    var cases = 0;
    for (final event in DiagnosticEvent.values) {
      final fields = event.fields.toList();
      for (var mask = 0; mask < 1 << fields.length; ++mask) {
        final values = <DiagnosticField, Object>{
          for (var bit = 0; bit < fields.length; ++bit)
            if (mask & (1 << bit) != 0)
              fields[bit]: switch (fields[bit]) {
                DiagnosticField.operation => DiagnosticOperation.parse(
                  operation,
                )!,
                DiagnosticField.call => identity,
                DiagnosticField.category => DiagnosticCategory.unavailable,
                DiagnosticField.outcome => DiagnosticOutcome.completed,
                DiagnosticField.provider => DiagnosticProvider.unknown,
                DiagnosticField.event => DiagnosticEvent.invalidConfiguration,
                DiagnosticField.active ||
                DiagnosticField.enabled ||
                DiagnosticField.precisionLost => false,
                DiagnosticField.status || DiagnosticField.signal => -0x7fffffff,
                _ => 0x7fffffff,
              },
        };
        final wire = DiagnosticRecord(
          event,
          DiagnosticComponent.desktop,
          fields: values,
          connection: identity,
          job: identity,
          request: 0x7fffffff,
          attempt: 0x7fffffff,
          stack: SafeDiagnosticStack.fromRegisteredLocations(
            List.generate(
              8,
              (_) => [diagnosticCodeLocations.length - 1, 9999999, 99999],
            ),
            values[DiagnosticField.category] as DiagnosticCategory? ??
                DiagnosticCategory.unknown,
          ),
        ).toWire()!;
        expect(
          DiagnosticRecord.validWire(jsonDecode(jsonEncode(wire))),
          isTrue,
        );
        expect(
          diagnosticAsciiJsonString(
            wire,
            maximumBytes: DiagnosticRecord.maximumProducerRecordBytes,
          ),
          jsonEncode(wire),
        );
        final stored = <String, Object?>{
          'schema': 2,
          'timestamp': '2026-10-25T23:59:59.999999Z',
          'sequence': 0x7fffffffffffffff,
          'level': event.severity.name,
          'version': '${'9' * 23}.1.1+${'a' * 20}',
          'revision': 'f' * 40,
          'session': identity.value,
          'pid': 0x7fffffff,
          'producer': 'entrypoint:15:9223372036854775807',
          'build_id': 'f' * 64,
          ...wire,
        };
        expect(
          diagnosticAsciiJsonBytes(
            stored,
            maximumBytes: DiagnosticRecord.maximumRecordBytes,
          ),
          utf8.encode('${jsonEncode(stored)}\n'),
        );
        ++cases;
      }
    }
    expect(cases, greaterThan(400));
  });

  test('typed call identity normalizes to canonical JSON', () {
    const canonical = '0123456789abcdef0123456789abcdef';
    final identity = DiagnosticIdentity.parse(canonical)!;
    final wire = DiagnosticRecord(
      DiagnosticEvent.rpcCompleted,
      DiagnosticComponent.desktop,
      fields: {DiagnosticField.call: identity},
    ).toWire()!;
    final expected = jsonEncode({
      'event': 'rpc.completed',
      'component': 'desktop',
      'fields': {'call': canonical},
    });
    expect(diagnosticAsciiJsonString(wire, maximumBytes: 4096), expected);
    expect(
      diagnosticAsciiJsonBytes(wire, maximumBytes: 4096),
      utf8.encode('$expected\n'),
    );
    expect(
      DiagnosticRecord(
        DiagnosticEvent.rpcCompleted,
        DiagnosticComponent.desktop,
        fields: {DiagnosticField.call: canonical},
      ).toWire(),
      isNull,
    );
  });

  test('capacity includes newline and returns independent exact bytes', () {
    const value = <String, Object?>{'a': 0};
    expect(diagnosticAsciiJsonString(value, maximumBytes: 7), '{"a":0}');
    final bytes = diagnosticAsciiJsonBytes(value, maximumBytes: 8);
    expect(bytes, utf8.encode('{"a":0}\n'));
    expect(bytes.buffer.lengthInBytes, 8);
    expect(
      () => diagnosticAsciiJsonString(value, maximumBytes: 6),
      throwsFormatException,
    );
    expect(
      () => diagnosticAsciiJsonBytes(value, maximumBytes: 7),
      throwsFormatException,
    );
  });

  test(
    'rejects input outside the closed ASCII schema and structural bounds',
    () {
      for (final value in <Object?>[
        '\u0000',
        '\n',
        '"',
        r'\',
        'é',
        'x' * 129,
        1.5,
        Object(),
        List.filled(257, null),
        {
          'a': {
            'b': {
              'c': {'d': <Object?>[]},
            },
          },
        },
        {for (var i = 0; i < 65; ++i) '$i': 0},
        {1: 0},
      ]) {
        expect(
          () => diagnosticAsciiJsonString({'value': value}, maximumBytes: 4096),
          throwsFormatException,
        );
      }
      for (final capacity in [0, 4097]) {
        expect(
          () => diagnosticAsciiJsonString({}, maximumBytes: capacity),
          throwsFormatException,
        );
      }
      expect(
        diagnosticAsciiJsonString({
          'null': null,
          'true': true,
          'false': false,
          'minimum': -0x8000000000000000,
          'maximum': 0x7fffffffffffffff,
        }, maximumBytes: 4096),
        jsonEncode({
          'null': null,
          'true': true,
          'false': false,
          'minimum': -0x8000000000000000,
          'maximum': 0x7fffffffffffffff,
        }),
      );
    },
  );
}
