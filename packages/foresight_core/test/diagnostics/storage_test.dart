import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:foresight_core/src/diagnostics/events.dart';
import 'package:foresight_core/src/diagnostics/storage.dart';
import 'package:foresight_core/src/persistence/backup_files.dart';
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
    () {
      final profile = _profile();
      final storage = DiagnosticStorage.admit(
        profile,
        DiagnosticIdentity.random(),
        DiagnosticRole.desktop,
      )!;
      addTearDown(storage.close);
      final manifest = File('$profile/logs/slot-${storage.slot}/manifest.json');
      final before = manifest.readAsBytesSync();
      final root = BackupDirectory('$profile/logs');
      final admission = root.open('admission.lock');
      try {
        expect(admission.tryExclusiveLease(), isTrue);
        expect(
          DiagnosticStorage.admit(
            profile,
            DiagnosticIdentity.random(),
            DiagnosticRole.desktop,
          ),
          isNull,
        );
        expect(storage.classify(DiagnosticRole.desktop, error: true), isFalse);
        expect(storage.failed, isFalse);
        expect(manifest.readAsBytesSync(), before);
      } finally {
        admission.close();
        root.close();
      }
      expect(storage.classify(DiagnosticRole.desktop, error: true), isTrue);
    },
  );
  test(
    'retention rank precedes reserved preference and newest failure survives rollback',
    () {
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
        DiagnosticStorage.admit(
          profile,
          DiagnosticIdentity.random(),
          DiagnosticRole.service,
        )!.close();
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
        final selected = DiagnosticStorage.admit(
          profile,
          DiagnosticIdentity.random(),
          DiagnosticRole.service,
          clock: () => scenario == 'rollback'
              ? now.subtract(const Duration(days: 1))
              : now,
        )!;
        try {
          expect(
            selected.slot,
            scenario == 'reserved'
                ? 0
                : scenario == 'protected' || scenario == 'rollback'
                ? 1
                : 5,
            reason: scenario,
          );
        } finally {
          selected.close();
        }
      }
    },
  );
  test(
    'orphan manifest.next is reclaimable but orphan payload stays occupied',
    () {
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
        final recovered = DiagnosticStorage.admit(
          profile,
          DiagnosticIdentity.random(),
          DiagnosticRole.desktop,
          ownedSlots: {
            for (var i = 0; i < 10; i++)
              if (i != slot) i,
          },
        );
        if (payload) {
          expect(recovered, isNull);
          expect(
            File('$profile/logs/slot-$slot/0.jsonl').readAsBytesSync(),
            _record(),
          );
        } else {
          expect(recovered?.slot, slot);
          expect(
            File('$profile/logs/slot-$slot/manifest.next').existsSync(),
            isFalse,
          );
          recovered?.close();
        }
      }
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
    () {
      final profile = _profile();
      final storage = DiagnosticStorage.admit(
        profile,
        DiagnosticIdentity.random(),
        DiagnosticRole.mcp,
      )!;
      addTearDown(storage.close);
      final directory = BackupDirectory('$profile/logs/slot-${storage.slot}');
      final probe = directory.open('lease');
      expect(probe.tryExclusiveLease(), isFalse);
      probe.close();
      final second = directory.open('lease');
      expect(second.tryExclusiveLease(), isFalse);
      second.close();
      directory.close();
      final other = DiagnosticStorage.admit(
        profile,
        DiagnosticIdentity.random(),
        DiagnosticRole.mcp,
      )!;
      addTearDown(other.close);
      expect(other.slot, isNot(storage.slot));
    },
  );
  test('unexpected entries unsafe aliases and tampered slots fail closed', () {
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
    final next = DiagnosticStorage.admit(
      profile,
      DiagnosticIdentity.random(),
      DiagnosticRole.service,
    )!;
    expect(next.slot, isNot(slot));
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
    expect(File('$profile/logs/unexpected').readAsStringSync(), 'untouched');
  });
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

    test('every root and slot enumeration in admission uses the reader', () {
      final profile = _profile();
      final seen = <int>[];
      final storage = DiagnosticStorage.admit(
        profile,
        DiagnosticIdentity.random(),
        DiagnosticRole.service,
        directoryReader: (descriptor, names, capacity) {
          seen.add(descriptor);
          return _streamReader(descriptor, names, capacity);
        },
      )!;
      addTearDown(storage.close);
      // Root once; validation and manifest read per slot; the selected slot's
      // revalidation, five cleanup containsEntry calls and manifest replace.
      expect(seen, hasLength(1 + 2 * DiagnosticStorage.slotCount + 1 + 5 + 1));
      expect(seen.every((descriptor) => descriptor >= 10), isTrue);
      seen.clear();
      expect(storage.append(_record()), isTrue);
      expect(seen, isEmpty);
      expect(storage.classify(DiagnosticRole.service, error: true), isTrue);
      // Root validation, slot validation and the manifest replace.
      expect(seen, hasLength(3));
      seen.clear();
      expect(
        storage.classify(
          DiagnosticRole.service,
          error: true,
          genuineFailure: true,
        ),
        isTrue,
      );
      // Plus validation and manifest read of every slot, through children.
      expect(seen, hasLength(3 + 2 * DiagnosticStorage.slotCount));
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
