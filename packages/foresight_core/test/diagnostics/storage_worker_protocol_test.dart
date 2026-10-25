import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:foresight_core/src/diagnostics/events.dart';
import 'package:foresight_core/src/diagnostics/bounded_json.dart';
import 'package:foresight_core/src/diagnostics/storage.dart';
import 'package:foresight_core/src/diagnostics/storage_worker_dispatch.dart';
import 'package:foresight_core/src/diagnostics/storage_worker_protocol.dart';
import 'package:foresight_core/src/persistence/backup_files.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';

const build =
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
final session = DiagnosticIdentity.parse('0123456789abcdef0123456789abcdef')!;
final empty = Uint8List(0);

DiagnosticWorkerInit init([String profile = '/private/profile']) =>
    DiagnosticWorkerInit(
      profile: profile,
      session: session,
      role: DiagnosticRole.candidate,
    );

Map<String, Object?> record({
  int sequence = 1,
  DiagnosticEvent event = DiagnosticEvent.serviceReady,
}) => {
  'schema': 2,
  'timestamp': '2026-10-25T00:00:00.000Z',
  'sequence': sequence,
  'level': event.severity.name,
  'version': '0.1.3',
  'revision': 'unknown',
  'session': session.value,
  'pid': pid,
  'producer': 'entrypoint:0:1',
  'build_id': build,
  'event': event.wire,
  'component': DiagnosticComponent.service.name,
  'fields': <String, Object?>{},
};
Uint8List jsonBytes(Object? value) =>
    Uint8List.fromList(utf8.encode('${jsonEncode(value)}\n'));
Object? check(Uint8List bytes, {int after = 0}) => diagnosticStoredRecord(
  bytes,
  buildId: build,
  session: session.value,
  parentPid: pid,
  afterSequence: after,
);

final class Sink implements DiagnosticSink {
  @override
  int get slot => 3;
  @override
  bool failed = false;
  bool contend = false, closeThrows = false;
  int classifications = 0, closes = 0;
  final records = <Uint8List>[];
  @override
  bool classify(
    DiagnosticRole role, {
    required bool error,
    bool genuineFailure = false,
  }) {
    ++classifications;
    return !contend && !failed;
  }

  @override
  bool append(Uint8List record) {
    if (failed) return false;
    records.add(Uint8List.fromList(record));
    return true;
  }

  @override
  void close() {
    ++closes;
    if (closeThrows) throw StateError('fixture close failure');
  }
}

DiagnosticStorageWorkerState state(Sink sink) =>
    DiagnosticStorageWorkerState.forTesting(
      parentPid: pid,
      buildId: build,
      factory: (_, _, _) => sink,
    );
DiagnosticWorkerReply classify(
  DiagnosticStorageWorkerState state, {
  bool error = false,
  bool genuine = false,
  DiagnosticRole role = DiagnosticRole.service,
}) => state.handle(
  DiagnosticWorkerFrame.classify,
  DiagnosticWorkerClassification(
    role,
    error: error,
    genuineFailure: genuine,
  ).encode(),
);
void admitted(DiagnosticStorageWorkerState state) {
  expect(
    state.handle(DiagnosticWorkerFrame.init, init().encode()).result,
    DiagnosticWorkerResult.ok,
  );
  expect(
    state.handle(DiagnosticWorkerFrame.admit, empty).result,
    DiagnosticWorkerResult.ok,
  );
}

void main() {
  test('manifest preflight admits only bounded flat closed scalars', () {
    final text = jsonEncode({
      'schema': 1,
      'session': session.value,
      'pid': pid,
      'role': 'candidate',
      'opened': 1,
      'has_error': false,
      'failure_order': 0,
      'failed': 0,
    });
    bool shape(String text) =>
        diagnosticManifestJsonShape(Uint8List.fromList(utf8.encode(text)));
    expect(shape(text), isTrue);
    expect(
      shape(text.replaceFirst('"pid":$pid', '"pid":0,"pid":$pid')),
      isFalse,
    );
    expect(shape(text.replaceFirst('"opened":1', '"opened":[1]')), isFalse);
    expect(shape(text.replaceFirst('"opened":1', '"opened":1e0')), isFalse);
    expect(
      shape(
        text.replaceFirst('"role":"candidate"', '"role":"candi\\u0064ate"'),
      ),
      isFalse,
    );
    expect(shape('$text\n'), isFalse);
    expect(shape('[' * 2048 + ']' * 2048), isFalse);
  });
  test(
    'duplicate manifest fields stay occupied and preserve existing segment bytes',
    () {
      final parent = BackupDirectory(
        createTestTempDirectorySync('diag-manifest-').path,
        private: false,
      );
      final profile = parent.child('profile');
      final path = profile.path;
      profile.close();
      parent.close();
      final bounded = <int>[];
      final worker = DiagnosticStorageWorkerState.authenticated(
        parentPid: pid,
        buildId: build,
        directoryBound: (descriptor) {
          bounded.add(descriptor);
          return true;
        },
      );
      addTearDown(() {
        if (!worker.retired) worker.handle(8, empty);
      });
      expect(
        worker.handle(2, init(path).encode()).result,
        DiagnosticWorkerResult.ok,
      );
      final first = worker.handle(4, empty);
      expect(first.result, DiagnosticWorkerResult.ok);
      expect(bounded, isNotEmpty);
      expect(
        classify(worker, role: DiagnosticRole.candidate).result,
        DiagnosticWorkerResult.ok,
      );
      final bytes = jsonBytes(record());
      expect(worker.handle(6, bytes).result, DiagnosticWorkerResult.ok);
      expect(worker.handle(8, empty).result, DiagnosticWorkerResult.ok);
      final segment = File('$path/logs/slot-${first.slot}/0.jsonl');
      final manifest = File('$path/logs/slot-${first.slot}/manifest.json');
      final original = manifest.readAsStringSync();
      expect(original, contains('"role":"candidate"'));
      final malformed = original.replaceFirst(
        '"role":"candidate"',
        '"role":"arbitrary","role":"candidate"',
      );
      manifest.writeAsStringSync(malformed);
      final next = DiagnosticStorage.admit(
        path,
        DiagnosticIdentity.random(),
        DiagnosticRole.candidate,
      )!;
      addTearDown(next.close);
      expect(next.slot, isNot(first.slot));
      expect(segment.readAsBytesSync(), bytes);
      expect(manifest.readAsStringSync(), malformed);
    },
  );
  test('INIT represents all4096 raw profile bytes without JSON expansion', () {
    final value = init('/${'\u0001' * 4095}');
    final bytes = value.encode();
    expect(bytes.length, 4122);
    final decoded = DiagnosticWorkerInit.decode(bytes);
    expect(decoded.profile, value.profile);
    expect(decoded.session.value, session.value);
    expect(decoded.role, DiagnosticRole.candidate);
    expect(
      DiagnosticWorkerInit.decode(init('/${'é' * 2047}').encode()).profile,
      '/${'é' * 2047}',
    );
  });
  test('INIT rejects malformed framing before file authority', () {
    final bytes = init().encode();
    for (var count = 0; count < bytes.length; ++count) {
      expect(
        () =>
            DiagnosticWorkerInit.decode(Uint8List.sublistView(bytes, 0, count)),
        throwsFormatException,
      );
    }
    for (final index in [0, 1, 2, 3, 4, 5, 6, 7, 24, 25, bytes.length - 1]) {
      final changed = Uint8List.fromList(bytes)..[index] = 255;
      expect(() => DiagnosticWorkerInit.decode(changed), throwsFormatException);
    }
    expect(
      () => DiagnosticWorkerInit.decode(Uint8List.fromList([...bytes, 0])),
      throwsFormatException,
    );
    for (final profile in [
      'relative',
      '/',
      '/private/../profile',
      '/private/profile/',
      '/private/a\u0000b',
      '/${'é' * 2048}',
    ]) {
      expect(() => init(profile).encode(), throwsFormatException);
    }
  });
  test('control replies and classifications use only closed scalars', () {
    for (final slot in [null, 0, 9]) {
      final reply = DiagnosticWorkerReply(
        DiagnosticWorkerResult.retry,
        DiagnosticHealthReason.storageUnavailable,
        slot: slot,
      );
      expect(reply.encode().length, 4);
      expect(DiagnosticWorkerReply.decode(reply.encode()).slot, slot);
    }
    for (final bytes in [
      <int>[],
      [1, 0, 0],
      [2, 0, 0, 0],
      [1, 255, 0, 0],
      [1, 0, 255, 0],
      [1, 0, 0, 11],
      [1, 0, 0, 0, 0],
    ]) {
      expect(
        () => DiagnosticWorkerReply.decode(Uint8List.fromList(bytes)),
        throwsFormatException,
      );
    }
    for (final bytes in [
      [0, 0, 1],
      [4, 0, 0],
      [0, 2, 0],
      [0, 0, 2],
      [0, 0],
    ]) {
      expect(
        () => DiagnosticWorkerClassification.decode(Uint8List.fromList(bytes)),
        throwsFormatException,
      );
    }
  });
  test(
    'schema2 accepts all live producer snapshots and registered maximum stack',
    () {
      for (final kind in DiagnosticProducerKind.values.where(
        (kind) => kind != DiagnosticProducerKind.writer,
      )) {
        for (var slot = 0; slot < 16; ++slot) {
          for (final generation in [1, 0x7fffffffffffffff]) {
            expect(
              check(
                jsonBytes(
                  record()..['producer'] = '${kind.name}:$slot:$generation',
                ),
              ),
              isNotNull,
            );
          }
        }
      }
      final value = record(event: DiagnosticEvent.rpcFailed)
        ..['producer'] = 'writer:0:0'
        ..['connection'] = session.value
        ..['job'] = session.value
        ..['request'] = 0x7fffffff
        ..['attempt'] = 0x7fffffff
        ..['fields'] = {
          'category': 'internal',
          'status': -0x7fffffff,
          'durationUs': 0x7fffffff,
        }
        ..['stack'] = SafeDiagnosticStack.fromRegisteredLocations(
          List.generate(8, (_) => [0, 9999999, 99999]),
          DiagnosticCategory.internal,
        ).toWire();
      expect(check(jsonBytes(value)), isNotNull);
      expect(jsonBytes(value).length, lessThanOrEqualTo(4096));
    },
  );
  test(
    'schema2 rejects identity, producer, sequence, catalog and shape mutations',
    () {
      final changes = <String, List<Object?>>{
        'schema': [null, 1, 3],
        'sequence': [0, -1, true, '1'],
        'pid': [pid + 1, null],
        'build_id': ['0' * 64, 'unknown'],
        'session': ['f' * 32, null],
        'producer': [
          'writer:0',
          'writer:0:1',
          'entrypoint:16:1',
          'entrypoint:0:0',
          'entrypoint:00:1',
          'entrypoint:0:01',
          'entrypoint:0:-1',
          'arbitrary:0:1',
        ],
        'timestamp': [
          '2026-02-30T00:00:00.000Z',
          '2026-10-25',
          '2026-10-25T00:00:00.000+00:00',
        ],
        'level': ['off', 'error', null],
        'revision': ['invalid'],
        'version': ['invalid'],
        'component': ['arbitrary'],
        'event': ['arbitrary'],
        'fields': [
          {'unknown': 'private'},
        ],
        'stack': [
          null,
          {'frames': [], 'fingerprint': '0' * 64},
        ],
      };
      for (final entry in changes.entries) {
        for (final value in entry.value) {
          expect(
            check(jsonBytes(record()..[entry.key] = value)),
            isNull,
            reason: '${entry.key}:$value',
          );
        }
      }
      for (final key in record().keys) {
        expect(
          check(jsonBytes(record()..remove(key))),
          isNull,
          reason: 'missing$key',
        );
      }
      expect(check(jsonBytes(record()), after: 1), isNull);
      expect(check(jsonBytes(record(sequence: 2)), after: 1), isNotNull);
    },
  );
  test(
    'preflight rejects hidden duplicate keys, nesting and extra JSONL lines',
    () {
      final text = utf8.decode(jsonBytes(record()));
      for (final changed in [
        text.replaceFirst('"event":', '"event":"arbitrary","event":'),
        text.replaceFirst('"fields":{}', '"fields":{"count":1,"count":2}'),
        text.replaceFirst('"fields":{}', '"fields":{"count":[[[[[0]]]]]}'),
        text.replaceFirst('"service.ready"', '"service.\\u0072eady"'),
        text.replaceFirst('"service.ready"', '"é"'),
        text.replaceFirst('"fields":{}', '"fields":{"${'x' * 129}":1}'),
        '$text$text',
        '$text ',
        text.trimRight(),
        text.replaceFirst('"sequence":1', '"sequence":1e0'),
        text.replaceFirst('"sequence":1', '"sequence":1.0'),
      ]) {
        expect(check(Uint8List.fromList(utf8.encode(changed))), isNull);
      }
      expect(
        check(
          Uint8List.fromList([
            ...jsonBytes(record()),
            ...List.filled(4096, 32),
            10,
          ]),
        ),
        isNull,
      );
      for (var count = 0; count < text.length - 1; ++count) {
        expect(
          check(
            Uint8List.fromList(utf8.encode('${text.substring(0, count)}\n')),
          ),
          isNull,
        );
      }
    },
  );
  test('worker admission refuses an unbounded directory stream', () {
    final parent = BackupDirectory(
      createTestTempDirectorySync('diag-bound-').path,
      private: false,
    );
    final profile = parent.child('profile');
    final path = profile.path;
    profile.close();
    parent.close();
    final bounded = <int>[];
    final worker = DiagnosticStorageWorkerState.authenticated(
      parentPid: pid,
      buildId: build,
      directoryBound: (descriptor) {
        bounded.add(descriptor);
        return false;
      },
    );
    expect(
      worker.handle(2, init(path).encode()).result,
      DiagnosticWorkerResult.ok,
    );
    final reply = worker.handle(4, empty);
    expect(reply.result, DiagnosticWorkerResult.retry);
    expect(reply.reason, DiagnosticHealthReason.unsupportedFilesystem);
    expect(reply.slot, isNull);
    expect(bounded, hasLength(1));
    expect(Directory('$path/logs').listSync(), isEmpty);
    expect(worker.handle(8, empty).reason, DiagnosticHealthReason.closed);
  });
  test('INIT grants no files and admission retries stay at five', () {
    var calls = 0;
    final worker = DiagnosticStorageWorkerState.forTesting(
      parentPid: pid,
      buildId: build,
      factory: (_, _, _) {
        ++calls;
        return null;
      },
    );
    expect(worker.handle(2, init().encode()).result, DiagnosticWorkerResult.ok);
    expect(calls, 0);
    for (var i = 0; i < 5; ++i) {
      expect(
        worker.handle(4, empty).result,
        i == 4 ? DiagnosticWorkerResult.disabled : DiagnosticWorkerResult.retry,
      );
    }
    expect(worker.handle(4, empty).result, DiagnosticWorkerResult.disabled);
    expect(calls, 5);
    expect(worker.handle(8, empty).reason, DiagnosticHealthReason.closed);
    expect(worker.retired, isTrue);
  });
  test(
    'classification ACK protects warning and genuine owner failure before append',
    () {
      final sink = Sink();
      final worker = state(sink);
      admitted(worker);
      final bytes = jsonBytes(record(event: DiagnosticEvent.runtimeFailed));
      expect(worker.handle(6, bytes).result, DiagnosticWorkerResult.retry);
      expect(classify(worker).result, DiagnosticWorkerResult.ok);
      expect(worker.handle(6, bytes).result, DiagnosticWorkerResult.retry);
      expect(classify(worker, error: true).result, DiagnosticWorkerResult.ok);
      expect(worker.handle(6, bytes).result, DiagnosticWorkerResult.retry);
      expect(sink.records, isEmpty);
      sink.contend = true;
      expect(
        classify(worker, error: true, genuine: true).result,
        DiagnosticWorkerResult.retry,
      );
      expect(worker.handle(6, bytes).result, DiagnosticWorkerResult.retry);
      sink.contend = false;
      expect(
        classify(worker, error: true, genuine: true).result,
        DiagnosticWorkerResult.ok,
      );
      expect(worker.handle(6, bytes).result, DiagnosticWorkerResult.ok);
      expect(sink.records, [bytes]);
      expect(worker.handle(6, bytes).result, DiagnosticWorkerResult.disabled);
      expect(sink.records.length, 1);
      expect(worker.handle(8, empty).result, DiagnosticWorkerResult.ok);
      expect(sink.closes, 1);
    },
  );
  test('role downgrade and invalid records cannot reach the file sink', () {
    final sink = Sink(), worker = state(Sink());
    admitted(worker);
    expect(classify(worker).result, DiagnosticWorkerResult.ok);
    expect(
      classify(worker, role: DiagnosticRole.candidate).result,
      DiagnosticWorkerResult.disabled,
    );
    final second = state(sink);
    admitted(second);
    classify(second);
    expect(
      second
          .handle(6, jsonBytes(record()..['fields'] = {'private': 'arbitrary'}))
          .result,
      DiagnosticWorkerResult.disabled,
    );
    expect(sink.records, isEmpty);
    expect(second.handle(8, empty).result, DiagnosticWorkerResult.ok);
  });
  test(
    'failed file close never acknowledges retirement or retries an uncertain close',
    () {
      final sink = Sink()..closeThrows = true;
      final worker = state(sink);
      admitted(worker);
      expect(worker.handle(8, empty).result, DiagnosticWorkerResult.disabled);
      expect(worker.retired, isFalse);
      expect(worker.handle(8, empty).result, DiagnosticWorkerResult.disabled);
      expect(worker.retired, isFalse);
      expect(sink.closes, 1);
    },
  );
  test(
    'filesystem fixture writes only validated schema2 and closes before retirement',
    () {
      final parent = BackupDirectory(
        createTestTempDirectorySync('diag-dispatch-').path,
        private: false,
      );
      final profile = parent.child('profile');
      final path = profile.path;
      profile.close();
      parent.close();
      final bounded = <int>[];
      final worker = DiagnosticStorageWorkerState.authenticated(
        parentPid: pid,
        buildId: build,
        directoryBound: (descriptor) {
          bounded.add(descriptor);
          return true;
        },
      );
      addTearDown(() {
        if (!worker.retired) worker.handle(8, empty);
      });
      expect(
        worker.handle(2, init(path).encode()).result,
        DiagnosticWorkerResult.ok,
      );
      final admitted = worker.handle(4, empty);
      expect(admitted.result, DiagnosticWorkerResult.ok);
      expect(bounded, isNotEmpty);
      expect(classify(worker).result, DiagnosticWorkerResult.ok);
      final bytes = jsonBytes(record());
      expect(worker.handle(6, bytes).result, DiagnosticWorkerResult.ok);
      final segment = File('$path/logs/slot-${admitted.slot}/0.jsonl');
      expect(segment.readAsBytesSync(), bytes);
      expect(worker.handle(8, empty).result, DiagnosticWorkerResult.ok);
      expect(worker.retired, isTrue);
      expect(() => worker.handle(7, empty), throwsFormatException);
      // Actual scoped lease is available again after RETIRED is acknowledged.
      final slot = BackupDirectory('$path/logs/slot-${admitted.slot}');
      final lease = slot.open('lease');
      try {
        expect(lease.tryExclusiveLease(), isTrue);
      } finally {
        lease.close();
        slot.close();
      }
    },
  );
}
