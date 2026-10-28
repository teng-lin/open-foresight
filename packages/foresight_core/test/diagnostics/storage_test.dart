import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:foresight_core/src/diagnostics/events.dart';
import 'package:foresight_core/src/diagnostics/storage.dart';
import 'package:foresight_core/src/persistence/backup_files.dart';
import 'package:foresight_test_support/poll.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';

String _profile() {
  final parent = BackupDirectory(
    createTestTempDirectorySync('log-profile-').path,
    private: false,
  );
  try {
    final profile = parent.child('profile');
    final path = profile.path;
    profile.close();
    return path;
  } finally {
    parent.close();
  }
}

final _libc = DynamicLibrary.process();
final _dup = _libc.lookupFunction<Int32 Function(Int32), int Function(int)>(
  'dup',
);
final _close = _libc.lookupFunction<Int32 Function(Int32), int Function(int)>(
  'close',
);
final _kill = _libc
    .lookupFunction<Int32 Function(Int32, Int32), int Function(int, int)>(
      'kill',
    );
final _fcntl = _libc
    .lookupFunction<
      Int32 Function(Int32, Int32, VarArgs<()>),
      int Function(int, int)
    >('fcntl');
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

final _duplicateAtLeast = _libc
    .lookupFunction<
      Int32 Function(Int32, Int32, VarArgs<(Int32,)>),
      int Function(int, int, int)
    >('fcntl');

bool _isOpen(int descriptor) => _fcntl(descriptor, 1) >= 0;

// Other test isolates may reuse a closed number. A surviving handle to this
// private directory, rather than any later user of that number, is a leak.
bool _targetsDirectory(int descriptor, BackupDirectory directory) =>
    BackupFile.inspectDescriptorIdentity(descriptor) == directory.identity;

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

Uint8List _record([int count = 1]) => Uint8List.fromList(
  utf8.encode(
    '${jsonEncode({
      'schema': 1,
      'event': 'service.ready',
      'fields': {'count': count},
    })}\n',
  ),
);

void _admissionFailureWitness(String profile, String stage) {
  final evidence = <String, Object>{'stage': stage};
  BackupDirectory? logs;
  BackupFile? admission;
  try {
    logs = BackupDirectory('$profile/logs');
    admission = logs.open('admission.lock');
    evidence['admission_bytes'] = admission.size;
    evidence['admission_probe_busy'] = !admission.tryExclusiveLease();
    var manifests = 0, samePid = 0, busyLeases = 0;
    for (var i = 0; i < DiagnosticStorage.slotCount; i++) {
      final directory = BackupDirectory('$profile/logs/slot-$i', create: false);
      try {
        final manifest = File('${directory.path}/manifest.json');
        if (manifest.existsSync() && manifest.lengthSync() <= 4096) {
          final value = jsonDecode(manifest.readAsStringSync()) as Map;
          manifests++;
          if (value['pid'] == pid) samePid++;
        }
        if (directory.containsEntry('lease')) {
          final lease = directory.open('lease');
          try {
            if (!lease.tryExclusiveLease()) busyLeases++;
          } finally {
            lease.close();
          }
        }
      } finally {
        directory.close();
      }
    }
    evidence.addAll({
      'manifest_count': manifests,
      'same_pid_manifest_count': samePid,
      'busy_slot_lease_count': busyLeases,
    });
  } catch (error) {
    evidence['witness_error_type'] = error.runtimeType.toString();
  } finally {
    admission?.close();
    logs?.close();
  }
  print('STORAGE_ADMISSION_FAILURE ${jsonEncode(evidence)}');
}

Future<bool> _runAdmissionProcess(
  String name,
  Map<String, Object> expected,
) async {
  if (Platform.environment['FORESIGHT_STORAGE_ADMISSION_CASE'] == name) {
    return false;
  }
  // Other suites can fork while an admission description is briefly locked.
  // CLOEXEC releases it at exec, but cannot prevent that pre-exec inheritance.
  // This child executes the complete case without unrelated process launches.
  final package = await Isolate.resolvePackageUri(
    Uri.parse('package:foresight_core/foresight_core.dart'),
  );
  expect(package, isNotNull);
  final root = File.fromUri(package!).parent.parent;
  final evidence = shortTestTempRoot.createTempSync('sa-');
  final temporary = evidence.createTempSync('t-');
  final report = File('${evidence.path}/events.jsonl');
  final stdout = File('${evidence.path}/stdout.log');
  final stderr = File('${evidence.path}/stderr.log');
  final group = File('${evidence.path}/group.json');
  final elapsed = Stopwatch()..start();
  Duration remaining() {
    final left = const Duration(seconds: 20) - elapsed.elapsed;
    if (left <= Duration.zero) {
      throw TimeoutException('Owned admission child exceeded its total budget');
    }
    return left;
  }

  final output = stdout.openSync(mode: FileMode.write);
  late final RandomAccessFile errors;
  try {
    errors = stderr.openSync(mode: FileMode.write);
  } catch (_) {
    output.closeSync();
    rethrow;
  }
  late final Process process;
  try {
    process = await Process.start(
      Platform.environment['FORESIGHT_PYTHON'] ?? 'python3',
      [
        '-c',
        'import json,os,sys\n'
            'os.setsid()\n'
            'path=sys.argv[1]\n'
            'with open(path+".next","x") as output:\n'
            ' os.chmod(path+".next",0o600)\n'
            ' json.dump({"pid":os.getpid(),"pgid":os.getpgrp(),"sid":os.getsid(0)},output)\n'
            'os.replace(path+".next",path)\n'
            'os.execv(sys.argv[2],sys.argv[2:])\n',
        group.path,
        Platform.resolvedExecutable,
        'test',
        'test/diagnostics/storage_test.dart',
        '--plain-name',
        name,
        '--concurrency=1',
        '--reporter=expanded',
        '--file-reporter=json:${report.path}',
      ],
      workingDirectory: root.path,
      environment: {
        ...Platform.environment,
        'FORESIGHT_STORAGE_ADMISSION_CASE': name,
        'TMPDIR': temporary.path,
        'FORESIGHT_TEST_TEMP_ROOT': temporary.path,
      },
    );
  } catch (_) {
    output.closeSync();
    errors.closeSync();
    rethrow;
  }
  final outputDone = Completer<void>(), errorsDone = Completer<void>();
  Object? pipeError;
  void complete(Completer<void> done) {
    if (!done.isCompleted) done.complete();
  }

  StreamSubscription<List<int>> capture(
    Stream<List<int>> stream,
    RandomAccessFile sink,
    Completer<void> done,
  ) => stream.listen(
    (bytes) {
      try {
        sink.writeFromSync(bytes);
      } catch (error) {
        pipeError ??= error;
        complete(done);
      }
    },
    onDone: () => complete(done),
    onError: (Object error) {
      pipeError ??= error;
      complete(done);
    },
    cancelOnError: true,
  );

  final outputSubscription = capture(process.stdout, output, outputDone);
  final errorsSubscription = capture(process.stderr, errors, errorsDone);
  var reaped = false, success = false, cleanupComplete = false;
  var drainComplete = false;
  final drained = Future.wait([outputDone.future, errorsDone.future]).then((_) {
    drainComplete = true;
  });
  var ownsGroup = false;
  int? earlyExit;
  final exitCode = process.exitCode.then((code) {
    earlyExit = code;
    reaped = true;
    return code;
  });
  bool recordedOwnedGroup() {
    try {
      if (FileSystemEntity.typeSync(group.path, followLinks: false) !=
              FileSystemEntityType.file ||
          group.lengthSync() > 256) {
        return false;
      }
      final identity = jsonDecode(group.readAsStringSync());
      return identity is Map &&
          identity.length == 3 &&
          identity.values.every((value) => value is int) &&
          identity['pid'] == process.pid &&
          identity['pgid'] == process.pid &&
          identity['sid'] == process.pid;
    } catch (_) {
      return false;
    }
  }

  void verifyGroup() {
    expect(
      recordedOwnedGroup(),
      true,
      reason: 'Child did not record its own session',
    );
    ownsGroup = true;
  }

  Future<void>? reaping;
  Future<void> reap() => reaping ??= () async {
    final cleanup = Stopwatch()..start();
    Duration cleanupRemaining() {
      final left = const Duration(seconds: 3) - cleanup.elapsed;
      if (left <= Duration.zero) {
        throw TimeoutException(
          'Owned admission child cleanup exceeded its budget',
        );
      }
      return left;
    }

    try {
      ownsGroup = ownsGroup || recordedOwnedGroup();
      // Skip once exit and EOF are observed: recorded numbers may be reused.
      // OS reap may precede Dart's exit notification; this guard is observational.
      if (ownsGroup && !(earlyExit != null && drainComplete)) {
        _kill(-process.pid, ProcessSignal.sigkill.signalNumber);
      }
      if (!reaped) process.kill(ProcessSignal.sigkill);
      final cancelled = Future.wait([
        outputSubscription.cancel(),
        errorsSubscription.cancel(),
      ]);
      complete(outputDone);
      complete(errorsDone);
      await exitCode.timeout(cleanupRemaining());
      reaped = true;
      await cancelled.timeout(cleanupRemaining());
      cleanupComplete = true;
    } finally {
      output.closeSync();
      errors.closeSync();
    }
  }();

  addTearDown(reap);
  try {
    await process.stdin.close().timeout(remaining());
    while (!group.existsSync()) {
      if (earlyExit != null) {
        throw StateError(
          'Owned child exited before recording its session: $earlyExit',
        );
      }
      await Future<void>.delayed(
        const Duration(milliseconds: 1),
      ).timeout(remaining());
    }
    verifyGroup();
    final exit = await exitCode.timeout(remaining());
    reaped = true;
    await drained.timeout(remaining());
    expect(pipeError, isNull, reason: 'Owned child output capture failed');
    expect(exit, 0, reason: 'Owned admission child failed');
    final events = report
        .readAsLinesSync()
        .map(jsonDecode)
        .cast<Map>()
        .toList();
    expect(
      events.where((event) => event['type'] == 'done').single['success'],
      true,
    );
    final tests = events.where(
      (event) => event['type'] == 'testDone' && event['hidden'] != true,
    );
    expect(tests, hasLength(1));
    expect(tests.single['result'], 'success');
    expect(tests.single['skipped'], false);
    final started = events.singleWhere(
      (event) =>
          event['type'] == 'testStart' &&
          (event['test'] as Map)['id'] == tests.single['testID'],
    );
    expect((started['test'] as Map)['name'], name);
    const prefix = 'STORAGE_ADMISSION_COMPLETE ';
    final completion = events.singleWhere(
      (event) =>
          event['type'] == 'print' &&
          (event['message'] as String).startsWith(prefix),
    );
    expect(
      jsonDecode((completion['message'] as String).substring(prefix.length)),
      expected,
    );
    success = true;
  } finally {
    try {
      await reap();
    } finally {
      if (success && cleanupComplete) {
        evidence.deleteSync(recursive: true);
      } else {
        print('STORAGE_ADMISSION_CHILD_FAILURE evidence=${evidence.path}');
        print(utf8.decode(stdout.readAsBytesSync(), allowMalformed: true));
        print(utf8.decode(stderr.readAsBytesSync(), allowMalformed: true));
      }
    }
  }
  return true;
}

void _seedSlot(
  String profile,
  int index, {
  required int opened,
  bool error = true,
  int order = 0,
  int failed = 0,
}) {
  final directory = BackupDirectory('$profile/logs/slot-$index');
  final file = directory.openOrCreate('manifest.json');
  file.truncate();
  file.writeOnce(
    Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'schema': 1,
          'session': DiagnosticIdentity.random().value,
          'pid': 1,
          'role': DiagnosticRole.service.name,
          'opened': opened,
          'has_error': error,
          'failure_order': order,
          'failed': failed,
        }),
      ),
    ),
  );
  file.close();
  directory.close();
}

void main() {
  test(
    'real admission and classification contention retain bytes and health',
    () async {
      const name =
          'real admission and classification contention retain bytes and health';
      if (await _runAdmissionProcess(name, {
        'case': 'classification-contention',
        'busy_verified': true,
        'classification_reads': 2,
        'idempotent_classification_succeeded': true,
        'identity_checks': 1,
      })) {
        return;
      }
      final profile = _profile();
      final identity = DiagnosticIdentity.random();
      var reads = 0;
      var observedBusy = false;
      var firstSuccessReads = 0;
      final storage = DiagnosticStorage.admit(
        profile,
        identity,
        DiagnosticRole.desktop,
        directoryReader: (descriptor, names, capacity) {
          reads++;
          return _streamReader(descriptor, names, capacity);
        },
      )!;
      addTearDown(storage.close);
      expect(storage.session, identity.value);
      expect(storage.role, DiagnosticRole.desktop);
      final manifest = File('$profile/logs/slot-${storage.slot}/manifest.json');
      final before = manifest.readAsBytesSync();
      final root = BackupDirectory('$profile/logs');
      final admission = root.open('admission.lock');
      try {
        expect(admission.tryExclusiveLeaseChecked(), isTrue);
        expect(
          DiagnosticStorage.admit(
            profile,
            DiagnosticIdentity.random(),
            DiagnosticRole.desktop,
            directoryReader: _streamReader,
          ),
          isNull,
        );
        for (var attempt = 0; attempt < 2; attempt++) {
          reads = 0;
          expect(
            storage.classify(DiagnosticRole.desktop, error: true),
            isFalse,
          );
          expect(storage.failed, isFalse);
          expect(reads, 0, reason: 'Busy precedes directory validation');
          expect(manifest.readAsBytesSync(), before);
        }
        final probe = root.open('admission.lock');
        try {
          expect(probe.size, 0);
          expect(probe.tryExclusiveLeaseChecked(), isFalse);
        } finally {
          probe.close();
        }
        observedBusy = true;
        admission.close();
        // The owned child cannot inherit this lock into unrelated suite forks.
        // After explicit release, any failed positive result is a test failure.
        reads = 0;
        expect(storage.classify(DiagnosticRole.desktop, error: true), isTrue);
        expect(reads, 2, reason: 'Successful root and slot validation');
        firstSuccessReads = reads;
        expect(storage.failed, isFalse);
      } finally {
        admission.close();
        root.close();
      }
      final idempotent = storage.classify(DiagnosticRole.desktop, error: true);
      expect(idempotent, isTrue);
      print(
        'STORAGE_ADMISSION_COMPLETE ${jsonEncode({'case': 'classification-contention', 'busy_verified': observedBusy, 'classification_reads': firstSuccessReads, 'idempotent_classification_succeeded': idempotent, 'identity_checks': 1})}',
      );
    },
  );
  test(
    'retention rank precedes reserved preference and newest failure survives rollback',
    () async {
      const name =
          'retention rank precedes reserved preference and newest failure survives rollback';
      final expected = <String, Object>{
        'case': 'retention',
        'scenarios': [
          'empty',
          'expired',
          'healthy',
          'reserved',
          'protected',
          'rollback',
        ],
        'slots': [5, 5, 5, 0, 1, 1],
        'identity_checks': 6,
      };
      if (await _runAdmissionProcess(name, expected)) {
        return;
      }
      final completed = <String>[];
      final slots = <int>[];
      Future<DiagnosticStorage> admit(
        String profile, {
        DateTime Function()? clock,
        DiagnosticIdentity? session,
        String stage = 'retention-admission',
        void Function()? onBusy,
      }) async {
        final identity = session ?? DiagnosticIdentity.random();
        DiagnosticStorage? selected;
        try {
          await eventually(() {
            var reads = 0;
            selected = DiagnosticStorage.admit(
              profile,
              identity,
              DiagnosticRole.service,
              clock: clock,
              directoryReader: (descriptor, names, capacity) {
                reads++;
                return _streamReader(descriptor, names, capacity);
              },
            );
            if (selected != null) return true;
            // Admission is nonblocking. Only an actual busy admission flock,
            // before any slot reads, may defer this retention-order assertion.
            expect(reads, 1, reason: 'Do not retry unavailable eligible slots');
            final root = BackupDirectory('$profile/logs');
            final probe = root.open('admission.lock');
            try {
              expect(probe.size, 0);
              expect(probe.tryExclusiveLeaseChecked(), isFalse);
            } finally {
              probe.close();
              root.close();
            }
            onBusy?.call();
            return false;
          });
        } catch (_) {
          _admissionFailureWitness(profile, stage);
          rethrow;
        }
        return selected!;
      }

      // A fork in another suite can retain a close-on-exec flock until exec.
      // Prove that only this exact real-kernel contention is allowed to defer.
      final busyProfile = _profile();
      (await admit(busyProfile)).close();
      final root = BackupDirectory('$busyProfile/logs');
      final owner = root.open('admission.lock');
      try {
        await eventually(owner.tryExclusiveLeaseChecked);
        final manifest = File('$busyProfile/logs/slot-0/manifest.json');
        final before = manifest.readAsBytesSync();
        var observedBusy = false;
        final admitted = await admit(
          busyProfile,
          onBusy: () {
            observedBusy = true;
            expect(manifest.readAsBytesSync(), before);
            owner.close();
          },
        );
        admitted.close();
        expect(observedBusy, isTrue);
      } finally {
        owner.close();
        root.close();
      }

      final now = DateTime.utc(2026, 10, 24);
      for (final scenario in [
        'empty',
        'expired',
        'healthy',
        'reserved',
        'protected',
        'rollback',
      ]) {
        final profile = _profile();
        (await admit(profile, stage: 'retention-initial-$scenario')).close();
        for (var i = 0; i < 10; i++) {
          _seedSlot(profile, i, opened: now.millisecondsSinceEpoch - 1000);
        }
        if (scenario == 'empty' || scenario == 'reserved') {
          File('$profile/logs/slot-5/manifest.json').deleteSync();
        }
        if (scenario == 'reserved') {
          File('$profile/logs/slot-0/manifest.json').deleteSync();
        }
        if (scenario == 'expired') {
          _seedSlot(
            profile,
            5,
            opened: now
                .subtract(const Duration(days: 8))
                .millisecondsSinceEpoch,
          );
        }
        if (scenario == 'healthy') {
          _seedSlot(
            profile,
            5,
            opened: now.millisecondsSinceEpoch - 1000,
            error: false,
          );
        }
        if (scenario == 'protected' || scenario == 'rollback') {
          _seedSlot(
            profile,
            0,
            opened: now
                .subtract(const Duration(days: 8))
                .millisecondsSinceEpoch,
            order: 1,
            failed: now.millisecondsSinceEpoch,
          );
        }
        final session = DiagnosticIdentity.random();
        final selected = await admit(
          profile,
          session: session,
          stage: 'retention-$scenario',
          clock: () => scenario == 'rollback'
              ? now.subtract(const Duration(days: 1))
              : now,
        );
        try {
          expect(selected.session, session.value);
          expect(selected.role, DiagnosticRole.service);
          expect(
            selected.slot,
            scenario == 'reserved'
                ? 0
                : scenario == 'protected' || scenario == 'rollback'
                ? 1
                : 5,
            reason: scenario,
          );
          completed.add(scenario);
          slots.add(selected.slot);
        } finally {
          selected.close();
        }
      }
      print(
        'STORAGE_ADMISSION_COMPLETE ${jsonEncode({'case': 'retention', 'scenarios': completed, 'slots': slots, 'identity_checks': completed.length})}',
      );
    },
  );
  test(
    'orphan manifest.next is reclaimable but orphan payload stays occupied',
    () async {
      const name =
          'orphan manifest.next is reclaimable but orphan payload stays occupied';
      if (await _runAdmissionProcess(name, {
        'case': 'orphan',
        'scenarios': ['manifest-next-reclaimed', 'payload-retained'],
        'identity_checks': 1,
      })) {
        return;
      }
      for (final payload in [false, true]) {
        final profile = _profile();
        final first = DiagnosticStorage.admit(
          profile,
          DiagnosticIdentity.random(),
          DiagnosticRole.desktop,
        )!;
        final slot = first.slot;
        first.close();
        File('$profile/logs/slot-$slot/manifest.json').deleteSync();
        final dir = BackupDirectory('$profile/logs/slot-$slot');
        final orphan = dir.open('manifest.next', create: true);
        orphan.writeOnce(Uint8List.fromList(utf8.encode('{partial')));
        orphan.close();
        if (payload) {
          final segment = dir.open('0.jsonl', create: true);
          segment.writeOnce(_record());
          segment.close();
        }
        dir.close();
        final recoveryIdentity = DiagnosticIdentity.random();
        DiagnosticStorage? recover() => DiagnosticStorage.admit(
          profile,
          recoveryIdentity,
          DiagnosticRole.desktop,
          ownedSlots: {
            for (var i = 0; i < 10; i++)
              if (i != slot) i,
          },
        );
        final recovered = recover();
        if (recovered != null) addTearDown(recovered.close);
        if (payload) {
          expect(recovered, isNull);
          expect(
            File('$profile/logs/slot-$slot/0.jsonl').readAsBytesSync(),
            _record(),
          );
        } else {
          // This owned child does not launch unrelated processes after admission.
          // A positive reclaim is immediate; no failed admission is retried.
          expect(recovered, isNotNull);
          expect(recovered!.slot, slot);
          expect(recovered.session, recoveryIdentity.value);
          expect(recovered.role, DiagnosticRole.desktop);
          expect(
            File('$profile/logs/slot-$slot/manifest.next').existsSync(),
            isFalse,
          );
          recovered.close();
        }
      }
      print(
        'STORAGE_ADMISSION_COMPLETE ${jsonEncode({
          'case': 'orphan',
          'scenarios': ['manifest-next-reclaimed', 'payload-retained'],
          'identity_checks': 1,
        })}',
      );
    },
  );
  test('manifest records explicit application PID and rejects invalid PID', () {
    final profile = _profile();
    final applicationPid = pid + 100000;
    final storage = DiagnosticStorage.admit(
      profile,
      DiagnosticIdentity.random(),
      DiagnosticRole.desktop,
      applicationPid: applicationPid,
    )!;
    final value =
        jsonDecode(
              File(
                '$profile/logs/slot-${storage.slot}/manifest.json',
              ).readAsStringSync(),
            )
            as Map;
    expect(value['pid'], applicationPid);
    storage.close();
    expect(
      () => DiagnosticStorage.admit(
        profile,
        DiagnosticIdentity.random(),
        DiagnosticRole.desktop,
        applicationPid: 0,
      ),
      throwsA(isA<DiagnosticStorageUnavailable>()),
    );
  });
  test('tampered other slot cannot prevent genuine failure classification', () {
    final profile = _profile();
    final storage = DiagnosticStorage.admit(
      profile,
      DiagnosticIdentity.random(),
      DiagnosticRole.service,
    )!;
    addTearDown(storage.close);
    final other = storage.slot == 0 ? 1 : 0;
    Directory('$profile/logs/slot-$other').deleteSync(recursive: true);
    Link('$profile/logs/slot-$other').createSync(_profile());
    expect(
      storage.classify(
        DiagnosticRole.service,
        error: true,
        genuineFailure: true,
      ),
      isTrue,
    );
    expect(storage.failed, isFalse);
    final value =
        jsonDecode(
              File(
                '$profile/logs/slot-${storage.slot}/manifest.json',
              ).readAsStringSync(),
            )
            as Map;
    expect(value['has_error'], isTrue);
    expect(value['failure_order'], 1);
  });
  test(
    'fixed storage rotates three segments with private modes and no inherited descriptors',
    () {
      final profile = _profile();
      final storage = DiagnosticStorage.admit(
        profile,
        DiagnosticIdentity.random(),
        DiagnosticRole.desktop,
      )!;
      addTearDown(storage.close);
      final record = Uint8List.fromList(
        utf8.encode(
          '${jsonEncode({
            'schema': 1,
            'fields': {'count': 1},
            'fixture': 'x' * 4000,
          })}\n',
        ),
      );
      expect(record.length, lessThanOrEqualTo(4096));
      expect(
        record.length * 2100,
        greaterThan(4 * DiagnosticStorage.segmentBytes),
      );
      for (var i = 0; i < 2100; i++) {
        expect(storage.append(record), isTrue);
      }
      final segments = Directory('$profile/logs/slot-${storage.slot}')
          .listSync()
          .whereType<File>()
          .where((file) => file.path.endsWith('.jsonl'))
          .toList();
      expect(segments, hasLength(3));
      expect(
        segments.every(
          (file) => file.lengthSync() <= DiagnosticStorage.segmentBytes,
        ),
        isTrue,
      );
      expect(
        segments.fold<int>(0, (sum, file) => sum + file.lengthSync()),
        lessThanOrEqualTo(3 * DiagnosticStorage.segmentBytes),
      );
      for (final fd in storage.descriptorProof) {
        expect(fd.descriptor, greaterThanOrEqualTo(10));
        expect(fd.closeOnExec, isTrue);
      }
      expect(Directory('$profile/logs').statSync().mode & 0x1ff, 0x1c0);
      for (final entry in Directory(
        '$profile/logs',
      ).listSync(recursive: true, followLinks: false)) {
        expect(
          entry.statSync().mode & 0x1ff,
          entry is Directory ? 0x1c0 : 0x180,
        );
      }
    },
  );
  test(
    'independent flock probe cannot release active lease and same-process sessions do not reclaim it',
    () async {
      const name =
          'independent flock probe cannot release active lease and same-process sessions do not reclaim it';
      if (await _runAdmissionProcess(name, {
        'case': 'same-process',
        'sessions': 2,
        'independent_probe_refusals': 3,
        'distinct_slots': true,
        'identity_checks': 2,
      })) {
        return;
      }
      final profile = _profile();
      final session = DiagnosticIdentity.random();
      final storage = DiagnosticStorage.admit(
        profile,
        session,
        DiagnosticRole.mcp,
      );
      if (storage == null) {
        _admissionFailureWitness(profile, 'same-process-first');
      }
      expect(storage, isNotNull);
      expect(storage!.session, session.value);
      addTearDown(storage.close);
      var probeRefusals = 0;
      final directory = BackupDirectory('$profile/logs/slot-${storage.slot}');
      final probe = directory.open('lease');
      expect(probe.tryExclusiveLease(), isFalse);
      probeRefusals++;
      probe.close();
      final second = directory.open('lease');
      expect(second.tryExclusiveLease(), isFalse);
      probeRefusals++;
      second.close();
      directory.close();
      final otherSession = DiagnosticIdentity.random();
      final other = DiagnosticStorage.admit(
        profile,
        otherSession,
        DiagnosticRole.mcp,
      );
      if (other == null) {
        _admissionFailureWitness(profile, 'same-process-second');
      }
      expect(other, isNotNull);
      addTearDown(other!.close);
      expect(other.session, otherSession.value);
      expect(other.slot, isNot(storage.slot));
      final original = BackupDirectory('$profile/logs/slot-${storage.slot}');
      try {
        final stillHeld = original.open('lease');
        try {
          expect(stillHeld.tryExclusiveLease(), isFalse);
          probeRefusals++;
        } finally {
          stillHeld.close();
        }
      } finally {
        original.close();
      }
      print(
        'STORAGE_ADMISSION_COMPLETE ${jsonEncode({'case': 'same-process', 'sessions': 2, 'independent_probe_refusals': probeRefusals, 'distinct_slots': other.slot != storage.slot, 'identity_checks': 2})}',
      );
    },
  );
  test(
    'unexpected entries unsafe aliases and tampered slots fail closed',
    () async {
      const name =
          'unexpected entries unsafe aliases and tampered slots fail closed';
      const completion = <String, Object>{
        'case': 'tampered',
        'scenarios': [
          'owner-held-through-probe',
          'owner-released-before-probe',
        ],
        'busy_admissions': 2,
        'busy_probes': 1,
        'resolved_probes': 1,
        'distinct_replacements': 2,
        'negative_oracles': 4,
        'identity_checks': 2,
      };
      if (await _runAdmissionProcess(name, completion)) return;
      for (final releaseBeforeProbe in [false, true]) {
        final profile = _profile();
        final storage = DiagnosticStorage.admit(
          profile,
          DiagnosticIdentity.random(),
          DiagnosticRole.service,
        )!;
        final slot = storage.slot;
        storage.close();
        final manifest = File('$profile/logs/slot-$slot/manifest.json');
        manifest.writeAsStringSync('invalid');
        final root = BackupDirectory('$profile/logs');
        BackupFile? owner;
        try {
          owner = root.open('admission.lock');
          expect(owner.size, 0);
          expect(owner.tryExclusiveLeaseChecked(), isTrue);
          var reads = 0;
          final busy = DiagnosticStorage.admit(
            profile,
            DiagnosticIdentity.random(),
            DiagnosticRole.service,
            directoryReader: (descriptor, names, capacity) {
              reads++;
              return _streamReader(descriptor, names, capacity);
            },
          );
          expect(busy, isNull);
          expect(
            reads,
            1,
            reason: 'Real busy admission precedes slot validation',
          );
          expect(manifest.readAsStringSync(), 'invalid');
          if (releaseBeforeProbe) owner.close();
          final probe = root.open('admission.lock');
          try {
            expect(probe.size, 0);
            expect(probe.tryExclusiveLeaseChecked(), releaseBeforeProbe);
          } finally {
            probe.close();
          }
          // A later free probe does not disprove the actual earlier refusal.
          // Both phases explicitly release the controlled owner before success.
          owner.close();
        } finally {
          owner?.close();
          root.close();
        }
        final identity = DiagnosticIdentity.random();
        final next = DiagnosticStorage.admit(
          profile,
          identity,
          DiagnosticRole.service,
        )!;
        addTearDown(next.close);
        expect(next.session, identity.value);
        expect(next.role, DiagnosticRole.service);
        expect(next.slot, isNot(slot));
        expect(manifest.readAsStringSync(), 'invalid');
        next.close();
        File('$profile/logs/unexpected').writeAsStringSync('untouched');
        expect(
          () => DiagnosticStorage.admit(
            profile,
            DiagnosticIdentity.random(),
            DiagnosticRole.mcp,
          ),
          throwsA(isA<DiagnosticStorageUnavailable>()),
        );
        final alias = '${createTestTempDirectorySync('log-alias-').path}/alias';
        Link(alias).createSync(profile);
        expect(
          () => DiagnosticStorage.admit(
            alias,
            DiagnosticIdentity.random(),
            DiagnosticRole.mcp,
          ),
          throwsA(isA<DiagnosticStorageUnavailable>()),
        );
        expect(
          File('$profile/logs/unexpected').readAsStringSync(),
          'untouched',
        );
      }
      print('STORAGE_ADMISSION_COMPLETE ${jsonEncode(completion)}');
    },
  );
  test(
    'older missing and unsupported metadata never become empty reclaimable slots',
    () {
      for (final variant in ['missing', 'older', 'unknown']) {
        final profile = _profile();
        final storage = DiagnosticStorage.admit(
          profile,
          DiagnosticIdentity.random(),
          DiagnosticRole.mcp,
        )!;
        storage.append(_record());
        final slot = storage.slot;
        storage.close();
        final manifest = File('$profile/logs/slot-$slot/manifest.json');
        final data =
            jsonDecode(manifest.readAsStringSync()) as Map<String, dynamic>;
        data['pid'] = pid + 100000;
        if (variant == 'missing') {
          manifest.deleteSync();
        } else {
          if (variant == 'older') {
            data['schema'] = 0;
          } else {
            data['unknown'] = true;
          }
          manifest.writeAsStringSync(jsonEncode(data));
        }
        final payload = File('$profile/logs/slot-$slot/0.jsonl');
        final before = payload.readAsBytesSync();
        expect(
          DiagnosticStorage.admit(
            profile,
            DiagnosticIdentity.random(),
            DiagnosticRole.mcp,
            ownedSlots: {
              for (var i = 0; i < 10; i++)
                if (i != slot) i,
            },
          ),
          isNull,
        );
        expect(payload.readAsBytesSync(), before);
      }
    },
  );
  test(
    'hardlinked admission files and unwritable profiles refuse without repair',
    () {
      final profile = _profile();
      final storage = DiagnosticStorage.admit(
        profile,
        DiagnosticIdentity.random(),
        DiagnosticRole.mcp,
      )!;
      storage.close();
      final lock = '$profile/logs/admission.lock';
      final alias = '$profile/admission-alias';
      expect(Process.runSync('/bin/ln', [lock, alias]).exitCode, 0);
      expect(
        () => DiagnosticStorage.admit(
          profile,
          DiagnosticIdentity.random(),
          DiagnosticRole.mcp,
        ),
        throwsA(isA<DiagnosticStorageUnavailable>()),
      );
      expect(File(alias).lengthSync(), 0);
      final unwritable = _profile();
      expect(Process.runSync('/bin/chmod', ['500', unwritable]).exitCode, 0);
      try {
        expect(
          () => DiagnosticStorage.admit(
            unwritable,
            DiagnosticIdentity.random(),
            DiagnosticRole.mcp,
          ),
          throwsA(isA<DiagnosticStorageUnavailable>()),
        );
        expect(Directory(unwritable).statSync().mode & 0x1ff, 0x140);
      } finally {
        Process.runSync('/bin/chmod', ['700', unwritable]);
      }
    },
  );
  test(
    'post-admission segment hardlinks disable writes without touching aliases',
    () {
      final profile = _profile();
      final storage = DiagnosticStorage.admit(
        profile,
        DiagnosticIdentity.random(),
        DiagnosticRole.desktop,
      )!;
      addTearDown(storage.close);
      expect(storage.append(_record()), isTrue);
      final path = '$profile/logs/slot-${storage.slot}/0.jsonl';
      final alias = '$profile/segment-alias';
      expect(Process.runSync('/bin/ln', [path, alias]).exitCode, 0);
      final before = File(alias).readAsBytesSync();
      expect(storage.append(_record(2)), isFalse);
      expect(storage.failed, isTrue);
      expect(File(alias).readAsBytesSync(), before);
    },
  );
  test('short/oversized or broken writes cannot append an invalid record', () {
    final storage = DiagnosticStorage.admit(
      _profile(),
      DiagnosticIdentity.random(),
      DiagnosticRole.desktop,
    )!;
    addTearDown(storage.close);
    expect(storage.append(Uint8List(0)), isFalse);
    expect(
      storage.append(Uint8List(DiagnosticRecord.maximumRecordBytes + 1)),
      isFalse,
    );
    expect(storage.append(Uint8List.fromList([123])), isFalse);
    expect(storage.append(_record()), isTrue);
  });

  group('per-instance directory reader', () {
    List<int> pack(List<List<int>> names) => [
      for (final name in names) ...[name.length, ...name],
    ];
    BackupDirectoryReader fixed(List<int> packed, [List<int>? seen]) =>
        (descriptor, names, capacity) {
          seen?.add(descriptor);
          expect(_isOpen(descriptor), isTrue);
          expect(capacity, backupDirectoryNameBytes);
          names.asTypedList(packed.length).setAll(0, packed);
          return packed.length;
        };

    test('lists only reader output for a verified, closed duplicate', () {
      final directory = BackupDirectory(_profile());
      addTearDown(directory.close);
      directory.openOrCreate('real').close();
      final seen = <int>[];
      final listed = BackupDirectory(
        directory.path,
        create: false,
        reader: fixed(pack([utf8.encode('alpha'), utf8.encode('beta')]), seen),
      );
      addTearDown(listed.close);
      // A libc stream would have listed "real"; only the reader is used.
      expect(listed.entries(), ['alpha', 'beta']);
      expect(seen.single, isNot(listed.descriptor));
      expect(_targetsDirectory(seen.single, listed), isFalse);
      expect(listed.containsEntry('beta'), isTrue);
      expect(listed.containsEntry('real'), isFalse);
      expect(seen, hasLength(3));
      // Without a reader the same directory keeps the libc enumeration.
      expect(directory.entries(), ['real']);
      expect(seen, hasLength(3));
    });

    test(
      'closed reader targets stay closed when descriptor numbers are reused',
      () {
        final seen = <int>[];
        final listed = BackupDirectory(_profile(), reader: fixed([], seen));
        addTearDown(listed.close);
        expect(listed.entries(), isEmpty);
        expect(seen, hasLength(1));
        expect(_targetsDirectory(seen.single, listed), isFalse);

        final other = BackupDirectory(_profile());
        addTearDown(other.close);
        // F_DUPFD_CLOEXEC never replaces a live descriptor: if another isolate
        // already reused this number it selects the next available one.
        final reused = _duplicateAtLeast(
          other.descriptor,
          Platform.isMacOS ? 67 : 1030,
          seen.single,
        );
        try {
          expect(reused, greaterThanOrEqualTo(seen.single));
          expect(_isOpen(reused), isTrue);
          expect(_targetsDirectory(reused, other), isTrue);
          expect(other.identity, isNot(listed.identity));
          expect(_targetsDirectory(seen.single, listed), isFalse);
        } finally {
          if (reused >= 0) _close(reused);
        }
      },
    );

    test('children inherit the reader; other instances do not', () {
      final parent = BackupDirectory(
        _profile(),
        reader: fixed(pack([utf8.encode('listed')])),
      );
      addTearDown(parent.close);
      final child = parent.child('nested');
      addTearDown(child.close);
      expect(child.entries(), ['listed']);
      final plain = BackupDirectory(child.path, create: false);
      addTearDown(plain.close);
      expect(plain.entries(), isEmpty);
    });

    test('malformed or refused reader output never yields names', () {
      final directory = BackupDirectory(_profile());
      addTearDown(directory.close);
      final cases = <String, (int, List<int>)>{
        'refusal': (-2, []),
        'length past capacity': (backupDirectoryNameBytes + 1, []),
        'zero-length name': (2, [0, 0]),
        'name past length': (3, [5, 97, 98]),
        'dot': (2, pack([utf8.encode('.')])),
        'dot dot': (3, pack([utf8.encode('..')])),
        'slash': (4, pack([utf8.encode('a/b')])),
        'NUL': (4, pack([utf8.encode('a\u0000b')])),
        'over 256 names': (
          257 * 2,
          pack([for (var i = 0; i < 257; i++) utf8.encode('n')]),
        ),
      };
      for (final MapEntry(key: what, value: (length, bytes)) in cases.entries) {
        final seen = <int>[];
        final reader = BackupDirectory(
          directory.path,
          create: false,
          reader: (descriptor, names, capacity) {
            seen.add(descriptor);
            expect(_isOpen(descriptor), isTrue, reason: what);
            expect(
              _targetsDirectory(descriptor, directory),
              isTrue,
              reason: what,
            );
            names.asTypedList(bytes.length).setAll(0, bytes);
            return length;
          },
        );
        try {
          // containsEntry has no list cap of its own; the reader parse does.
          expect(reader.entries, throwsStateError, reason: what);
          expect(
            () => reader.containsEntry('absent'),
            throwsStateError,
            reason: what,
          );
          expect(seen, hasLength(2), reason: what);
          expect(
            seen.any((descriptor) => _targetsDirectory(descriptor, directory)),
            isFalse,
            reason: what,
          );
        } finally {
          reader.close();
        }
      }
      final invalid = BackupDirectory(
        directory.path,
        create: false,
        reader: fixed([2, 0xc3, 0x28]),
      );
      addTearDown(invalid.close);
      expect(invalid.entries, throwsFormatException);
      // Exactly 256 names, as entries() itself allows, are accepted.
      final full = BackupDirectory(
        directory.path,
        create: false,
        reader: fixed(pack([for (var i = 0; i < 256; i++) utf8.encode('n')])),
      );
      addTearDown(full.close);
      expect(full.entries(), hasLength(256));
    });

    test('every root and slot enumeration in admission uses the reader', () async {
      const name =
          'per-instance directory reader every root and slot enumeration in admission uses the reader';
      if (await _runAdmissionProcess(name, {
        'case': 'reader-classification',
        'admission_reads': 1 + 2 * DiagnosticStorage.slotCount + 1 + 5,
        'classification_reads': [2, 2 + 2 * DiagnosticStorage.slotCount],
        'busy_verified': true,
        'identity_checks': 1,
      })) {
        return;
      }
      final profile = _profile();
      final identity = DiagnosticIdentity.random();
      var observedBusy = false;
      var seen = <int>[];
      final storage = DiagnosticStorage.admit(
        profile,
        identity,
        DiagnosticRole.service,
        directoryReader: (descriptor, names, capacity) {
          seen.add(descriptor);
          return _streamReader(descriptor, names, capacity);
        },
      )!;
      addTearDown(storage.close);
      expect(storage.session, identity.value);
      expect(storage.role, DiagnosticRole.service);
      final admissionReads = seen.length;
      // Root once; validation and manifest read per slot; the selected slot's
      // revalidation and five cleanup containsEntry calls. Manifest replacement
      // uses descriptor-relative entryExists, without enumerating a directory.
      expect(seen, hasLength(1 + 2 * DiagnosticStorage.slotCount + 1 + 5));
      expect(seen.every((descriptor) => descriptor >= 10), isTrue);
      seen.clear();
      expect(storage.append(_record()), isTrue);
      expect(seen, isEmpty);
      final root = BackupDirectory('$profile/logs');
      final admission = root.open('admission.lock');
      try {
        expect(admission.tryExclusiveLeaseChecked(), isTrue);
        final manifest = File(
          '$profile/logs/slot-${storage.slot}/manifest.json',
        );
        final before = manifest.readAsBytesSync();
        for (var attempt = 0; attempt < 2; attempt++) {
          seen = <int>[];
          expect(
            storage.classify(DiagnosticRole.service, error: true),
            isFalse,
          );
          expect(storage.failed, isFalse);
          expect(seen, isEmpty);
          expect(manifest.readAsBytesSync(), before);
        }
        final probe = root.open('admission.lock');
        try {
          expect(probe.size, 0);
          expect(probe.tryExclusiveLeaseChecked(), isFalse);
        } finally {
          probe.close();
        }
        observedBusy = true;
        admission.close();
      } finally {
        admission.close();
        root.close();
      }
      // Positive phases are immediate; no false result is retried.
      seen = <int>[];
      expect(storage.classify(DiagnosticRole.service, error: true), isTrue);
      // Root and slot validation; replacement still performs no enumeration.
      expect(seen, hasLength(2));
      final firstSuccessReads = seen.length;
      seen = <int>[];
      expect(
        storage.classify(
          DiagnosticRole.service,
          error: true,
          genuineFailure: true,
        ),
        isTrue,
      );
      // Plus validation and manifest read of every slot, through children.
      expect(seen, hasLength(2 + 2 * DiagnosticStorage.slotCount));
      print(
        'STORAGE_ADMISSION_COMPLETE ${jsonEncode({
          'case': 'reader-classification',
          'admission_reads': admissionReads,
          'classification_reads': [firstSuccessReads, seen.length],
          'busy_verified': observedBusy,
          'identity_checks': 1,
        })}',
      );
    });

    test('a refused root listing precedes admission IO', () {
      final profile = _profile();
      final seen = <int>[];
      expect(
        () => DiagnosticStorage.admit(
          profile,
          DiagnosticIdentity.random(),
          DiagnosticRole.service,
          directoryReader: (descriptor, names, capacity) {
            seen.add(descriptor);
            return -2;
          },
        ),
        throwsA(isA<DiagnosticStorageUnavailable>()),
      );
      expect(seen, hasLength(1));
      expect(Directory('$profile/logs').listSync(), isEmpty);
    });

    test('refused slot listings are never leased', () {
      final profile = _profile();
      var calls = 0;
      final storage = DiagnosticStorage.admit(
        profile,
        DiagnosticIdentity.random(),
        DiagnosticRole.service,
        directoryReader: (descriptor, names, capacity) =>
            ++calls == 1 ? _streamReader(descriptor, names, capacity) : -2,
      );
      expect(storage, isNull);
      expect(calls, 1 + DiagnosticStorage.slotCount);
      for (var index = 0; index < DiagnosticStorage.slotCount; index++) {
        expect(Directory('$profile/logs/slot-$index').listSync(), isEmpty);
      }
    });
  });
}
