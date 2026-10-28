import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:foresight_core/src/diagnostics/events.dart';
import 'package:foresight_core/src/diagnostics/bounded_json.dart';
import 'package:foresight_core/src/diagnostics/storage.dart';
import 'package:foresight_core/src/diagnostics/storage_worker_dispatch.dart';
import 'package:foresight_core/src/diagnostics/storage_worker_protocol.dart';
import 'package:foresight_core/src/persistence/backup_files.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:foresight_test_support/poll.dart';
import 'package:test/test.dart';
import 'package:path/path.dart' as p;

import '../support/admission_lock_evidence.dart';

const build =
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
final session = DiagnosticIdentity.parse('0123456789abcdef0123456789abcdef')!;
final empty = Uint8List(0);

/// Positive filesystem operations may encounter transient kernel contention. A retry
/// alone is insufficient: require an independent checked kernel refusal, then
/// wait for release without spending further protocol admission attempts.
Future<DiagnosticWorkerReply> _withFilesystemContention(
  String profile,
  DiagnosticWorkerReply Function() request, {
  required DiagnosticHealthReason retryReason,
  void Function()? contended,
}) async {
  final elapsed = Stopwatch()..start();
  const budget = Duration(seconds: 3);
  for (var attempt = 1; attempt <= 5; attempt++) {
    final reply = request();
    if (reply.result == DiagnosticWorkerResult.ok) return reply;
    if (reply.result != DiagnosticWorkerResult.retry ||
        reply.reason != retryReason) {
      throw TestFailure(
        'Filesystem operation failed: attempt=$attempt '
        'result=${reply.result.name} reason=${reply.reason.name}',
      );
    }
    final root = BackupDirectory('$profile/logs', create: false);
    try {
      final lock = root.open('admission.lock');
      try {
        if (lock.size != 0 || lock.tryExclusiveLeaseChecked()) {
          throw TestFailure(
            'Filesystem operation retry lacks kernel contention: '
            'attempt=$attempt reason=${reply.reason.name}',
          );
        }
        contended?.call();
        await eventually(
          lock.tryExclusiveLeaseChecked,
          timeout: budget - elapsed.elapsed,
          label: 'admission contention released (attempt $attempt)',
          describe: () => admissionLockEvidence(profile),
        );
      } finally {
        lock.close();
      }
    } finally {
      root.close();
    }
  }
  throw TestFailure(
    'Filesystem operation exhausted its five attempts; '
    '${admissionLockEvidence(profile)}',
  );
}

Future<DiagnosticWorkerReply> _admitFilesystem(
  DiagnosticStorageWorkerState worker,
  String profile, {
  void Function()? contended,
}) => _withFilesystemContention(
  profile,
  () => worker.handle(DiagnosticWorkerFrame.admit, empty),
  retryReason: DiagnosticHealthReason.storageUnavailable,
  contended: contended,
);

final _libc = DynamicLibrary.process();
final _dup = _libc.lookupFunction<Int32 Function(Int32), int Function(int)>(
  'dup',
);
final _close = _libc.lookupFunction<Int32 Function(Int32), int Function(int)>(
  'close',
);
final _fdopendir = _libc
    .lookupFunction<Pointer<Void> Function(Int32), Pointer<Void> Function(int)>(
      'fdopendir',
    );
final _readdir = _libc
    .lookupFunction<
      Pointer<Uint8> Function(Pointer<Void>),
      Pointer<Uint8> Function(Pointer<Void>)
    >('readdir');
final _closedir = _libc
    .lookupFunction<Int32 Function(Pointer<Void>), int Function(Pointer<Void>)>(
      'closedir',
    );

/// Test double for the native reader with real listings: a libc stream on its
/// own dup of [descriptor], packed as [BackupDirectoryReader] requires.
int _streamReader(int descriptor, Pointer<Uint8> names, int capacity) {
  final duplicate = _dup(descriptor);
  final directory = duplicate < 0 ? nullptr : _fdopendir(duplicate);
  if (directory == nullptr) {
    if (duplicate >= 0) _close(duplicate);
    return -1;
  }
  try {
    var length = 0;
    for (var entry = _readdir(directory); entry != nullptr;) {
      final name = entry + (Platform.isMacOS ? 21 : 19);
      var size = 0;
      while (name[size] != 0) {
        size++;
      }
      final dot = size == 1 && name[0] == 46;
      final dots = size == 2 && name[0] == 46 && name[1] == 46;
      if (!dot && !dots) {
        if (length + 1 + size > capacity) return -2;
        names[length] = size;
        (names + length + 1)
            .asTypedList(size)
            .setAll(0, name.asTypedList(size));
        length += 1 + size;
      }
      entry = _readdir(directory);
    }
    return length;
  } finally {
    _closedir(directory);
  }
}

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
  test('INIT canonical path scan preserves POSIX normalization acceptance', () {
    final segments = ['', '.', '..', 'a', '...', 'aa', '界', 'a b', r'a\b'];
    final profiles = <String>[
      '/',
      '',
      'relative',
      '/a\u0000b',
      '/${'a/' * 2046}aaa',
      '/${'aa/' * 1363}./aaaa',
      '/${'a/' * 2045}./aaa',
      '/${'界/' * 2046}界',
    ];
    for (final a in segments) {
      for (final b in segments) {
        for (final c in segments) {
          profiles.add('/$a/$b/$c');
          profiles.add('$a/$b/$c');
        }
      }
    }
    for (final profile in profiles) {
      final accepted =
          profile.length > 1 &&
          profile.length <= 4096 &&
          !profile.contains('\u0000') &&
          p.posix.isAbsolute(profile) &&
          p.posix.normalize(profile) == profile &&
          !profile.endsWith('/') &&
          utf8.encode(profile).length <= 4096;
      if (accepted) {
        final bytes = init(profile).encode();
        expect(DiagnosticWorkerInit.decode(bytes).profile, profile);
      } else {
        expect(
          () => init(profile).encode(),
          throwsFormatException,
          reason: 'POSIX canonical acceptance must match',
        );
      }
    }
  });

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
    () async {
      final parent = BackupDirectory(
        createTestTempDirectorySync('diag-manifest-').path,
        private: false,
      );
      final profile = parent.child('profile');
      final path = profile.path;
      profile.close();
      parent.close();
      final listed = <int>[];
      final worker = DiagnosticStorageWorkerState.authenticated(
        parentPid: pid,
        buildId: build,
        directoryReader: (descriptor, names, capacity) {
          listed.add(descriptor);
          return _streamReader(descriptor, names, capacity);
        },
      );
      addTearDown(() {
        if (!worker.retired) worker.handle(8, empty);
      });
      expect(
        worker.handle(2, init(path).encode()).result,
        DiagnosticWorkerResult.ok,
      );
      final first = await _admitFilesystem(worker, path);
      expect(first.result, DiagnosticWorkerResult.ok);
      expect(listed, isNotEmpty);
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
      final successor = DiagnosticStorageWorkerState.authenticated(
        parentPid: pid,
        buildId: build,
        directoryReader: _streamReader,
      );
      addTearDown(() {
        if (!successor.retired) successor.handle(8, empty);
      });
      expect(
        successor.handle(2, init(path).encode()).result,
        DiagnosticWorkerResult.ok,
      );
      final next = await _admitFilesystem(successor, path);
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
  String workerProfile() {
    final parent = BackupDirectory(
      createTestTempDirectorySync('diag-reader-').path,
      private: false,
    );
    final profile = parent.child('profile');
    final path = profile.path;
    profile.close();
    parent.close();
    return path;
  }

  test(
    'admission-lock evidence separates held, free, refused and absent',
    () async {
      final path = workerProfile();
      final profile = BackupDirectory(path);
      final root = profile.child('logs');
      profile.close();
      addTearDown(root.close);
      final lock = root.open('admission.lock', create: true);
      var open = true;
      addTearDown(() {
        if (open) lock.close();
      });
      // Own descriptors are read from /proc on Linux only; elsewhere unknown.
      final own = ownAdmissionDescriptors(path);
      expect(own == null, !Platform.isLinux);
      expect(own, anyOf(isNull, 1));
      expect(lock.tryExclusiveLeaseChecked(), isTrue);
      // A separate open description contends with the kernel, deterministically.
      expect(probeAdmissionLock(path), AdmissionLockProbe.held);
      expect(
        admissionLockEvidence(path),
        contains('kernel EWOULDBLOCK confirmed'),
      );
      open = false;
      lock.close();
      // A closed descriptor is a non-contention failure, never "held".
      expect(probeLease(lock), AdmissionLockProbe.refused);
      expect(ownAdmissionDescriptors(path), anyOf(isNull, 0));
      // A fork elsewhere may keep the closed description alive until exec.
      await eventually(
        () => probeAdmissionLock(path) == AdmissionLockProbe.free,
        label: 'closed admission description released',
        describe: () => admissionLockEvidence(path),
      );
      expect(
        probeAdmissionLock('$path/missing'),
        AdmissionLockProbe.unopenable,
      );
      expect(admissionLockEvidence('$path/missing'), contains('unopenable'));
    },
  );

  test('an image without the bounded reader disables logging only', () {
    final path = workerProfile();
    final worker = DiagnosticStorageWorkerState.authenticated(
      parentPid: pid,
      buildId: build,
      directoryReader: null,
    );
    expect(
      worker.handle(2, init(path).encode()).result,
      DiagnosticWorkerResult.ok,
    );
    final reply = worker.handle(4, empty);
    expect(reply.result, DiagnosticWorkerResult.retry);
    expect(reply.reason, DiagnosticHealthReason.unsupportedFilesystem);
    expect(reply.slot, isNull);
    // No libc listing fallback: admission never touched the profile.
    expect(Directory('$path/logs').existsSync(), isFalse);
    expect(worker.handle(8, empty).reason, DiagnosticHealthReason.closed);
  });
  test('worker admission stops at a refused directory listing', () {
    final path = workerProfile();
    final listed = <int>[];
    final worker = DiagnosticStorageWorkerState.authenticated(
      parentPid: pid,
      buildId: build,
      directoryReader: (descriptor, names, capacity) {
        listed.add(descriptor);
        return -2;
      },
    );
    expect(
      worker.handle(2, init(path).encode()).result,
      DiagnosticWorkerResult.ok,
    );
    final reply = worker.handle(4, empty);
    expect(reply.result, DiagnosticWorkerResult.retry);
    expect(reply.reason, DiagnosticHealthReason.storageUnavailable);
    expect(reply.slot, isNull);
    expect(listed, hasLength(1));
    expect(Directory('$path/logs').listSync(), isEmpty);
    expect(worker.handle(8, empty).reason, DiagnosticHealthReason.closed);
  });
  for (final classification in [false, true]) {
    test(
      'positive fixture refuses retries without kernel contention (classification=$classification)',
      () async {
        final path = workerProfile();
        final profile = BackupDirectory(path);
        final root = profile.child('logs');
        profile.close();
        final lock = root.open('admission.lock', create: true);
        addTearDown(() {
          lock.close();
          root.close();
        });
        var calls = 0;
        final sink = Sink()..contend = true;
        final worker = DiagnosticStorageWorkerState.forTesting(
          parentPid: pid,
          buildId: build,
          factory: (_, _, _) {
            calls++;
            return classification ? sink : null;
          },
        );
        addTearDown(() => worker.handle(8, empty));
        expect(
          worker.handle(2, init(path).encode()).result,
          DiagnosticWorkerResult.ok,
        );
        if (classification) {
          expect(worker.handle(4, empty).result, DiagnosticWorkerResult.ok);
          calls = 0;
        }
        await expectLater(
          classification
              ? _withFilesystemContention(
                  path,
                  () => classify(worker),
                  retryReason: DiagnosticHealthReason.healthy,
                )
              : _admitFilesystem(worker, path),
          throwsA(
            isA<TestFailure>().having(
              (error) => error.message,
              'message',
              contains('lacks kernel contention'),
            ),
          ),
        );
        expect(calls, classification ? 0 : 1);
        expect(sink.classifications, classification ? 1 : 0);
      },
    );
  }
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
  for (final contend in [false, true]) {
    test(
      'filesystem fixture writes only validated schema2 and closes before retirement (contended=$contend)',
      () async {
        final parent = BackupDirectory(
          createTestTempDirectorySync('diag-dispatch-').path,
          private: false,
        );
        final profile = parent.child('profile');
        final path = profile.path;
        profile.close();
        parent.close();
        final listed = <int>[];
        final worker = DiagnosticStorageWorkerState.authenticated(
          parentPid: pid,
          buildId: build,
          directoryReader: (descriptor, names, capacity) {
            listed.add(descriptor);
            return _streamReader(descriptor, names, capacity);
          },
        );
        addTearDown(() {
          if (!worker.retired) worker.handle(8, empty);
        });
        expect(
          worker.handle(2, init(path).encode()).result,
          DiagnosticWorkerResult.ok,
        );
        BackupFile? heldLock;
        BackupDirectory? logs;
        if (contend) {
          final profile = BackupDirectory(path);
          logs = profile.child('logs');
          profile.close();
          heldLock = logs.open('admission.lock', create: true);
          addTearDown(() {
            heldLock?.close();
            logs?.close();
          });
          await eventually(heldLock.tryExclusiveLeaseChecked);
        }
        var sawContention = false;
        final admitted = await _admitFilesystem(
          worker,
          path,
          contended: () {
            sawContention = true;
            expect(Directory('$path/logs').listSync(), hasLength(1));
            heldLock?.close();
          },
        );
        expect(admitted.result, DiagnosticWorkerResult.ok);
        if (contend) expect(sawContention, isTrue);
        expect(listed, isNotEmpty);
        final manifest = File('$path/logs/slot-${admitted.slot}/manifest.json');
        final beforeClassification = manifest.readAsBytesSync();
        if (contend) {
          heldLock = logs!.open('admission.lock');
          await eventually(heldLock.tryExclusiveLeaseChecked);
        }
        var classificationContended = false;
        final classified = await _withFilesystemContention(
          path,
          () => classify(worker),
          retryReason: DiagnosticHealthReason.healthy,
          contended: () {
            classificationContended = true;
            expect(manifest.readAsBytesSync(), beforeClassification);
            heldLock?.close();
          },
        );
        expect(classified.result, DiagnosticWorkerResult.ok);
        if (contend) expect(classificationContended, isTrue);
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
          final acquired = lease.tryExclusiveLease();
          expect(
            acquired,
            isTrue,
            reason: acquired
                ? null
                : 'slot lease not released after RETIRED; a second checked '
                      'attempt on it observed ${probeLease(lease).name}',
          );
        } finally {
          lease.close();
          slot.close();
        }
      },
    );
  }
}
