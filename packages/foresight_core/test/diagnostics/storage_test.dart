import 'dart:convert';
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
}
