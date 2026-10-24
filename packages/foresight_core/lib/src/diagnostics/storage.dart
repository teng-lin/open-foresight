import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:meta/meta.dart';

import '../persistence/backup_files.dart';
import 'events.dart';

/// Roles are diagnostic classification only; they grant no application lease.
enum DiagnosticRole { candidate, service, desktop, mcp, transient }

enum OwnershipDecision {
  acquired,
  contended,
  withdrawn,
  failedBeforeLock,
  unknown,
}

enum DiagnosticHealthReason {
  healthy,
  bootstrapOnly,
  off,
  storageUnavailable,
  unsupportedFilesystem,
  sinkFailed,
  writerFailed,
  closed,
}

final class DiagnosticStorageUnavailable implements Exception {
  const DiagnosticStorageUnavailable(this.reason);
  final DiagnosticHealthReason reason;
}

final class _Manifest {
  _Manifest({
    required this.session,
    required this.pid,
    required this.role,
    required this.opened,
    this.hasError = false,
    this.failureOrder = 0,
    this.failed = 0,
  });
  final String session;
  final int pid, opened;
  DiagnosticRole role;
  bool hasError;
  int failureOrder, failed;
  Map<String, Object> toJson() => {
    'schema': 1,
    'session': session,
    'pid': pid,
    'role': role.name,
    'opened': opened,
    'has_error': hasError,
    'failure_order': failureOrder,
    'failed': failed,
  };
  static _Manifest parse(Uint8List bytes) {
    final value = jsonDecode(utf8.decode(bytes));
    if (value is! Map ||
        value.length != 8 ||
        value['schema'] != 1 ||
        value['session'] is! String ||
        DiagnosticIdentity.parse(value['session'] as String) == null ||
        value['pid'] is! int ||
        (value['pid'] as int) <= 0 ||
        value['opened'] is! int ||
        (value['opened'] as int) < 0 ||
        value['has_error'] is! bool ||
        value['failure_order'] is! int ||
        (value['failure_order'] as int) < 0 ||
        (value['failure_order'] as int) > 0x7fffffff ||
        value['failed'] is! int ||
        (value['failed'] as int) < 0) {
      throw const DiagnosticStorageUnavailable(
        DiagnosticHealthReason.storageUnavailable,
      );
    }
    final role = DiagnosticRole.values
        .where((role) => role.name == value['role'])
        .firstOrNull;
    if (role == null ||
        ((value['failure_order'] as int) > 0 &&
            (role != DiagnosticRole.service || value['has_error'] != true))) {
      throw const DiagnosticStorageUnavailable(
        DiagnosticHealthReason.storageUnavailable,
      );
    }
    return _Manifest(
      session: value['session'] as String,
      pid: value['pid'] as int,
      role: role,
      opened: value['opened'] as int,
      hasError: value['has_error'] as bool,
      failureOrder: value['failure_order'] as int,
      failed: value['failed'] as int,
    );
  }
}

final class _InactiveSlot {
  _InactiveSlot(this.index, this.directory, this.lease, this.manifest);
  final int index;
  final BackupDirectory directory;
  final BackupFile lease;
  final _Manifest? manifest;
  void close() {
    lease.close();
    directory.close();
  }
}

/// One writer owns its admitted slot for its complete lifetime. All operations
/// are synchronous libc calls on the writer isolate. No application code awaits
/// these calls; short writes disable persistence, preserving incomplete tails.
abstract interface class DiagnosticSink {
  int? get slot;
  bool get failed;
  bool classify(
    DiagnosticRole role, {
    required bool error,
    bool genuineFailure = false,
  });
  bool append(Uint8List record);
  void close();
}

typedef DiagnosticSinkFactory =
    DiagnosticSink? Function(
      String profile,
      DiagnosticIdentity session,
      DiagnosticRole role,
    );

final class DiagnosticStorage implements DiagnosticSink {
  DiagnosticStorage._(
    this._root,
    this._directory,
    this._lease,
    this.slot,
    this._manifest,
    this._clock,
  );
  static const slotCount = 10;
  static const segmentCount = 3;
  static const segmentBytes = 2 * 1024 * 1024;
  static const maximumPayloadBytes = slotCount * segmentCount * segmentBytes;
  static const maximumMetadataBytes = 1024 * 1024;
  static const manifestBytes = 4096;
  static const failureRetention = Duration(days: 7);
  static const _slotEntries = {
    'lease',
    'manifest.json',
    'manifest.next',
    '0.jsonl',
    '1.jsonl',
    '2.jsonl',
  };
  final BackupDirectory _root, _directory;
  final BackupFile _lease;
  @override
  final int slot;
  final _Manifest _manifest;
  final DateTime Function() _clock;
  BackupFile? _segment;
  int _segmentIndex = 0, _segmentSize = 0;
  bool _closed = false, _failed = false;
  @override
  bool get failed => _failed;
  @visibleForTesting
  List<({int descriptor, bool closeOnExec, String identity})>
  get descriptorProof => [
    (
      descriptor: _root.descriptor,
      closeOnExec: _root.closeOnExec,
      identity: _root.identity,
    ),
    (
      descriptor: _directory.descriptor,
      closeOnExec: _directory.closeOnExec,
      identity: _directory.identity,
    ),
    (
      descriptor: _lease.descriptor,
      closeOnExec: _lease.closeOnExec,
      identity: _lease.identity,
    ),
    if (_segment != null)
      (
        descriptor: _segment!.descriptor,
        closeOnExec: _segment!.closeOnExec,
        identity: _segment!.identity,
      ),
  ];
  String get session => _manifest.session;
  DiagnosticRole get role => _manifest.role;

  static DiagnosticStorage? admit(
    String profile,
    DiagnosticIdentity session,
    DiagnosticRole role, {
    DateTime Function()? clock,
    Set<int> ownedSlots = const {},
  }) {
    if (role == DiagnosticRole.transient) return null;
    final now = clock ?? DateTime.now;
    BackupDirectory? root;
    BackupFile? admission;
    final inactive = <_InactiveSlot>[];
    _InactiveSlot? chosen;
    try {
      // profile is canonical/private and already selected by application code.
      // This utility cannot invent a profile or change its access permissions.
      final parent = BackupDirectory(
        profile,
        create: false,
        minimumDescriptor: 10,
      );
      try {
        root = parent.child('logs');
      } finally {
        parent.close();
      }
      if (root.localFileSystem == ScopedLocalFileSystem.unsupported) {
        throw const DiagnosticStorageUnavailable(
          DiagnosticHealthReason.unsupportedFilesystem,
        );
      }
      _validateRoot(root);
      admission = root.openOrCreate('admission.lock');
      if (admission.size != 0 || !admission.tryExclusiveLease()) return null;
      final manifests = <int, _Manifest>{};
      final directories = <int, BackupDirectory>{};
      try {
        for (var index = 0; index < slotCount; index++) {
          final directory = root.child('slot-$index');
          directories[index] = directory;
          try {
            _validateSlot(directory);
            final manifest = _readManifest(directory);
            if (manifest != null) manifests[index] = manifest;
          } catch (_) {
            // A corrupt slot remains occupied; never classify it as empty.
            directory.close();
            directories.remove(index);
          }
        }
        final failures =
            manifests.entries
                .where((entry) => entry.value.failureOrder > 0)
                .toList()
              ..sort(
                (a, b) => b.value.failureOrder.compareTo(a.value.failureOrder),
              );
        final newestFailure = failures.firstOrNull;
        for (final entry in directories.entries) {
          final index = entry.key, directory = entry.value;
          final manifest = manifests[index];
          // Explicit shared registry plus this conservative same-process guard
          // prevents probing our own active lease from a second isolate.
          if (ownedSlots.contains(index) ||
              manifest?.pid == pid ||
              !_eligible(index, role)) {
            continue;
          }
          if (newestFailure?.key == index &&
              now().millisecondsSinceEpoch - newestFailure!.value.failed <=
                  failureRetention.inMilliseconds) {
            continue;
          }
          final lease = directory.openOrCreate('lease');
          if (lease.size != 0 || !lease.tryExclusiveLease()) {
            lease.close();
            continue;
          }
          inactive.add(_InactiveSlot(index, directory, lease, manifest));
        }
        inactive.sort((a, b) {
          int rank(_InactiveSlot value) => value.manifest == null
              ? 0
              : now().millisecondsSinceEpoch - value.manifest!.opened >
                    failureRetention.inMilliseconds
              ? 1
              : value.manifest!.hasError
              ? 3
              : 2;
          final byClass = rank(a).compareTo(rank(b));
          if (byClass != 0) return byClass;
          // Reserved preference applies within retention class, not as an
          // excuse to overwrite a more useful inactive failed session.
          final byReserved = _reserved(
            a.index,
            role,
          ).compareTo(_reserved(b.index, role));
          return byReserved != 0
              ? byReserved
              : (a.manifest?.opened ?? 0).compareTo(b.manifest?.opened ?? 0);
        });
        if (inactive.isEmpty) return null;
        chosen = inactive.first;
        final selected = chosen;
        _validateSlot(selected.directory);
        for (final name in selected.directory.entries()) {
          if (name != 'lease') selected.directory.remove(name);
        }
        final manifest = _Manifest(
          session: session.value,
          pid: pid,
          role: role,
          opened: now().toUtc().millisecondsSinceEpoch,
        );
        _writeManifest(selected.directory, manifest);
        root.verifyAnchor();
        final storage = DiagnosticStorage._(
          root,
          selected.directory,
          selected.lease,
          selected.index,
          manifest,
          now,
        );
        root = null;
        return storage;
      } finally {
        for (final candidate in inactive) {
          if (!identical(candidate, chosen)) candidate.close();
        }
        for (final directory in directories.values) {
          if (!identical(directory, chosen?.directory) &&
              !inactive.any((slot) => identical(slot.directory, directory))) {
            directory.close();
          }
        }
      }
    } catch (error) {
      chosen?.close();
      if (error is DiagnosticStorageUnavailable) rethrow;
      throw const DiagnosticStorageUnavailable(
        DiagnosticHealthReason.storageUnavailable,
      );
    } finally {
      admission?.close();
      root?.close();
    }
  }

  static bool _eligible(int index, DiagnosticRole role) =>
      index >= 5 ||
      (role == DiagnosticRole.service && index < 3) ||
      (role == DiagnosticRole.desktop && index >= 3 && index < 5);
  static int _reserved(int index, DiagnosticRole role) =>
      index < 5 && _eligible(index, role) ? 0 : 1;
  static void _validateRoot(BackupDirectory root) {
    final allowed = {
      'admission.lock',
      for (var i = 0; i < slotCount; i++) 'slot-$i',
    };
    if (root.entries().any((name) => !allowed.contains(name))) {
      throw const DiagnosticStorageUnavailable(
        DiagnosticHealthReason.storageUnavailable,
      );
    }
  }

  static void _validateSlot(BackupDirectory directory) {
    final entries = directory.entries();
    if (entries.any((name) => !_slotEntries.contains(name))) {
      throw const DiagnosticStorageUnavailable(
        DiagnosticHealthReason.storageUnavailable,
      );
    }
    for (final name in entries) {
      final file = directory.open(name);
      try {
        final maximum = name == 'lease'
            ? 0
            : name.endsWith('.jsonl')
            ? segmentBytes
            : manifestBytes;
        if (file.size > maximum) {
          throw const DiagnosticStorageUnavailable(
            DiagnosticHealthReason.storageUnavailable,
          );
        }
      } finally {
        file.close();
      }
    }
    if (!entries.contains('manifest.json') &&
        entries.any((name) => name != 'lease')) {
      throw const DiagnosticStorageUnavailable(
        DiagnosticHealthReason.storageUnavailable,
      );
    }
  }

  static _Manifest? _readManifest(BackupDirectory directory) {
    if (!directory.entries().contains('manifest.json')) return null;
    final file = directory.open('manifest.json');
    try {
      return _Manifest.parse(file.readSmall(manifestBytes));
    } finally {
      file.close();
    }
  }

  static void _writeManifest(BackupDirectory directory, _Manifest manifest) {
    final file = directory.openOrCreate('manifest.next');
    try {
      final bytes = Uint8List.fromList(
        utf8.encode(jsonEncode(manifest.toJson())),
      );
      if (bytes.length > manifestBytes) {
        throw const DiagnosticStorageUnavailable(
          DiagnosticHealthReason.storageUnavailable,
        );
      }
      file.truncate();
      if (!file.writeOnce(bytes)) {
        throw const DiagnosticStorageUnavailable(
          DiagnosticHealthReason.sinkFailed,
        );
      }
      file.sync();
    } finally {
      file.close();
    }
    directory.replace('manifest.next', 'manifest.json');
    directory.sync();
  }

  /// Role changes and first owner failure are serialized under admission. A busy
  /// lock defers the first error flush; it never blocks a producer/application.
  @override
  bool classify(
    DiagnosticRole role, {
    required bool error,
    bool genuineFailure = false,
  }) {
    if (_closed || _failed) return false;
    if (_manifest.role == role &&
        (!error || _manifest.hasError) &&
        (!genuineFailure || _manifest.failureOrder > 0)) {
      return true;
    }
    BackupFile? admission;
    try {
      admission = _root.open('admission.lock');
      if (!admission.tryExclusiveLease()) return false;
      _validateRoot(_root);
      _validateSlot(_directory);
      _manifest.role = role;
      if (error) _manifest.hasError = true;
      if (role == DiagnosticRole.service &&
          genuineFailure &&
          _manifest.failureOrder == 0) {
        var maximum = 0;
        for (var i = 0; i < slotCount; i++) {
          final directory = _root.child('slot-$i', create: false);
          try {
            try {
              final manifest = _readManifest(directory);
              if (manifest != null && manifest.failureOrder > maximum) {
                maximum = manifest.failureOrder;
              }
            } catch (_) {
              /* Preserve corrupt occupied slots. */
            }
          } finally {
            directory.close();
          }
        }
        if (maximum == 0x7fffffff) {
          throw const DiagnosticStorageUnavailable(
            DiagnosticHealthReason.storageUnavailable,
          );
        }
        _manifest.failureOrder = maximum + 1;
        _manifest.failed = _clock().toUtc().millisecondsSinceEpoch;
      }
      _writeManifest(_directory, _manifest);
      return true;
    } catch (_) {
      _failed = true;
      return false;
    } finally {
      admission?.close();
    }
  }

  @override
  bool append(Uint8List record) {
    if (_closed ||
        _failed ||
        record.length > DiagnosticRecord.maximumRecordBytes ||
        record.isEmpty ||
        record.last != 10) {
      return false;
    }
    try {
      _root.verifyAnchor();
      _directory.verifyAnchor();
      if (_segment != null && _segmentSize + record.length > segmentBytes) {
        _segment!.close();
        _segment = null;
        _segmentIndex = (_segmentIndex + 1) % segmentCount;
        _segmentSize = 0;
      }
      if (_segment == null) {
        _segment = _directory.openOrCreate('$_segmentIndex.jsonl');
        _segment!.truncate();
      }
      // An already-open descriptor must still be the validated private entry;
      // mode/link/path substitution after admission disables further writes.
      if (_directory.metadata('$_segmentIndex.jsonl').identity !=
          _segment!.identity) {
        throw const DiagnosticStorageUnavailable(
          DiagnosticHealthReason.sinkFailed,
        );
      }
      if (!_segment!.writeOnce(record)) {
        _failed = true;
        return false;
      }
      _segmentSize += record.length;
      return true;
    } catch (_) {
      _failed = true;
      return false;
    }
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _segment?.close();
    _lease.close();
    _directory.close();
    _root.close();
  }
}
