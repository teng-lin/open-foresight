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

void main() {
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
            'fixture': 'x' * 15000,
          })}\n',
        ),
      );
      for (var i = 0; i < 500; i++) {
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
