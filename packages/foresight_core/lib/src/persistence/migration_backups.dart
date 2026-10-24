import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

import 'backup_files.dart';
import 'sqlite_runtime.dart';
import 'snapshot_vfs.dart';

/// A candidate exists only after its bounded manifest was atomically published.
/// Its hash, schema, source identity and SQLite integrity are rechecked at use.
final class MigrationSnapshot {
  const MigrationSnapshot({
    required this.name,
    required this.schema,
    required this.created,
    required this.sha256,
    required this.sourceIdentity,
  });
  final String name;
  final int schema;
  final DateTime created;
  final String sha256;
  final String sourceIdentity;
}

/// Private snapshots are application content, not diagnostics. The service
/// holds its profile ownership before calling Store, and SQLite's exclusive
/// connection lock covers snapshot plus migration. This class never repairs
/// permissions on an untrusted entry or deletes content to make backup space.
final class MigrationBackups {
  MigrationBackups(this.databasePath, {DateTime Function()? now})
    : _now = now ?? DateTime.now;
  final String databasePath;
  final DateTime Function() _now;
  static const maximumSnapshots = 2;
  static const maximumRestoredCopies = 1;
  static const maximumAge = Duration(days: 7);
  static final _namePattern = RegExp(
    r'^snapshot-[0-9]{1,16}-[a-f0-9]{32}\.db$',
  );
  static final _restorePattern = RegExp(r'^restore-[a-f0-9]{32}\.db$');
  String get directoryPath => '$databasePath.backups';

  static String _nonce() {
    final random = Random.secure();
    return List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  BackupDirectory _directory({bool create = false}) =>
      BackupDirectory(directoryPath, create: create);

  bool get exists =>
      FileSystemEntity.typeSync(directoryPath, followLinks: false) !=
      FileSystemEntityType.notFound;

  MigrationSnapshot create(Database source, int schema) {
    if (!source.autocommit) {
      throw StateError('A migration backup requires an autocommit boundary.');
    }
    final parent = BackupDirectory(
      p.dirname(p.absolute(databasePath)),
      create: false,
      private: false,
    );
    late final BackupDirectory directory;
    try {
      directory = _directory(create: true);
    } catch (_) {
      parent.close();
      rethrow;
    }
    final name = 'snapshot-${_now().millisecondsSinceEpoch}-${_nonce()}.db';
    final temporary = '$name.partial';
    BackupFile? output, journal;
    var published = false;
    try {
      // Metadata lookup must not open/close the live database: POSIX close on
      // a second FD would silently release SQLite's process-associated locks.
      final sourceIdentity = parent
          .metadata(p.basename(databasePath), private: false)
          .identity;
      output = directory.open(temporary, create: true);
      journal = directory.open('$name.json.partial', create: true);
      final destination = SnapshotVfs(output, writable: true, journal: journal);
      destination.registered(
        () => source.execute('VACUUM INTO ?', [destination.uri]),
      );
      journal.close();
      journal = null;
      directory.remove('$name.json.partial');
      output.sync();
      _verifyDatabase(output, schema);
      final snapshot = MigrationSnapshot(
        name: name,
        schema: schema,
        created: _now().toUtc(),
        sha256: output.digest(),
        sourceIdentity: sourceIdentity,
      );
      output.close();
      output = null;
      directory.publish(temporary, name);
      published = true;
      final manifest = directory.open('$name.json.partial', create: true);
      try {
        manifest.write(
          utf8.encode(
            jsonEncode({
              'format': 1,
              'schema': schema,
              'created': snapshot.created.millisecondsSinceEpoch,
              'sha256': snapshot.sha256,
              'source': sourceIdentity,
            }),
          ),
        );
        manifest.sync();
      } finally {
        manifest.close();
      }
      directory.publish('$name.json.partial', '$name.json');
      directory.verifyAnchor();
      if (parent.metadata(p.basename(databasePath), private: false).identity !=
          sourceIdentity) {
        throw StateError(
          'Application database changed during migration backup.',
        );
      }
      // Do not evict an existing good backup until its replacement is complete.
      _prune(directory, preserve: name);
      return snapshot;
    } catch (_) {
      output?.close();
      journal?.close();
      try {
        directory.remove('$name.json.partial');
      } catch (_) {}
      // An unpublished/partial file can never be offered as a restore candidate.
      // Keep it if cleanup fails; the next successful admission removes it.
      try {
        directory.remove(published ? name : temporary);
      } catch (_) {}
      rethrow;
    } finally {
      directory.close();
      parent.close();
    }
  }

  List<MigrationSnapshot> snapshots({required int supportedVersion}) {
    if (!exists) return [];
    final directory = _directory();
    try {
      return _snapshots(directory, supportedVersion: supportedVersion);
    } finally {
      directory.close();
    }
  }

  String _sourceIdentity() {
    final parent = BackupDirectory(
      p.dirname(p.absolute(databasePath)),
      create: false,
      private: false,
    );
    try {
      return parent.metadata(p.basename(databasePath), private: false).identity;
    } finally {
      parent.close();
    }
  }

  void _validateDirectory(BackupDirectory directory) {
    directory.visitEntries((name) {
      _validateEntries([name]);
      // Reject unsafe paths before opening any manifest/snapshot. Safe corrupt
      // payloads are non-candidates; links/foreign/public/special files refuse.
      directory.metadata(name);
      return true;
    });
  }

  void _visitSnapshotMetadata(
    BackupDirectory directory,
    int supportedVersion,
    void Function(MigrationSnapshot) visit,
  ) {
    final sourceIdentity = _sourceIdentity();
    directory.visitEntries((name) {
      if (!_namePattern.hasMatch(name) ||
          !directory.containsEntry('$name.json')) {
        return true;
      }
      final metadata = directory.metadata('$name.json');
      if (metadata.size > 4096) return true;
      final file = directory.open('$name.json');
      MigrationSnapshot? snapshot;
      try {
        final value = jsonDecode(utf8.decode(file.readSmall(4096)));
        if (value is! Map || value['created'] is! int) return true;
        final created = DateTime.fromMillisecondsSinceEpoch(
          value['created'] as int,
          isUtc: true,
        );
        // Expiry precedes source/checksum processing. A moved/replaced profile
        // or safe corrupt old copy must not make its retention immortal.
        if (_now().toUtc().difference(created) > maximumAge) return true;
        if (value.length != 5 ||
            value['format'] != 1 ||
            value['schema'] is! int ||
            (value['schema'] as int) < 0 ||
            (value['schema'] as int) > supportedVersion ||
            value['source'] != sourceIdentity ||
            value['sha256'] is! String ||
            !RegExp(r'^[a-f0-9]{64}$').hasMatch(value['sha256'] as String)) {
          return true;
        }
        snapshot = MigrationSnapshot(
          name: name,
          schema: value['schema'] as int,
          created: created,
          sha256: value['sha256'] as String,
          sourceIdentity: sourceIdentity,
        );
      } on FormatException {
        return true;
      } on RangeError {
        return true;
      } finally {
        file.close();
      }
      visit(snapshot);
      return true;
    });
  }

  List<MigrationSnapshot> _snapshots(
    BackupDirectory directory, {
    required int supportedVersion,
  }) {
    _validateDirectory(directory);
    final result = <MigrationSnapshot>[];
    _visitSnapshotMetadata(directory, supportedVersion, (snapshot) {
      // Listing is explicit inspection. Periodic/admission pruning below never
      // hashes or integrity-scans payloads. A requested restore verifies again.
      final file = directory.open(snapshot.name);
      try {
        try {
          if (file.digest() != snapshot.sha256) return;
          _verifyDatabase(file, snapshot.schema);
          result.add(snapshot);
        } on SqliteException {
          return;
        } on StateError {
          return;
        }
      } finally {
        file.close();
      }
    });
    result.sort((a, b) => b.created.compareTo(a.created));
    return result;
  }

  static void _verifyDatabase(BackupFile file, int schema) {
    final vfs = SnapshotVfs(file, writable: false);
    vfs.registered(() {
      final db = sqlite3.open(
        '/snapshot',
        vfs: vfs.name,
        mode: OpenMode.readOnly,
      );
      try {
        db.execute(
          'PRAGMA busy_timeout=${applicationSqliteBusyTimeout.inMilliseconds}',
        );
        if (db.select('PRAGMA user_version').single.values.single != schema ||
            db.select('PRAGMA integrity_check').single.values.single != 'ok') {
          throw StateError(
            'Migration backup integrity or schema verification failed.',
          );
        }
      } finally {
        db.dispose();
      }
    });
  }

  static void _validateEntries(List<String> entries) {
    for (final entry in entries) {
      var name = entry;
      if (name.endsWith('.partial')) name = name.substring(0, name.length - 8);
      if (name.endsWith('.json')) name = name.substring(0, name.length - 5);
      if (!_namePattern.hasMatch(name) && !_restorePattern.hasMatch(name)) {
        throw StateError(
          'Unexpected entry in migration backup storage; cleanup remains pending.',
        );
      }
    }
  }

  void _prune(
    BackupDirectory directory, {
    String? preserve,
    String? preserveRestore,
  }) {
    _validateDirectory(directory);
    final kept = <MigrationSnapshot>[];
    _visitSnapshotMetadata(directory, 0x7fffffff, (snapshot) {
      kept.add(snapshot);
      kept.sort((a, b) {
        if (a.name == preserve) return -1;
        if (b.name == preserve) return 1;
        return b.created.compareTo(a.created);
      });
      if (kept.length > maximumSnapshots) kept.removeLast();
    });
    final keep = kept.map((snapshot) => snapshot.name).toSet();
    final restored = <({String name, int modified})>[];
    directory.visitEntries((name) {
      if (_restorePattern.hasMatch(name)) {
        final metadata = directory.metadata(name);
        if (_now().millisecondsSinceEpoch - metadata.modifiedMillis <=
                maximumAge.inMilliseconds ||
            name == preserveRestore) {
          restored.add((name: name, modified: metadata.modifiedMillis));
          restored.sort(
            (a, b) => a.name == preserveRestore
                ? -1
                : b.name == preserveRestore
                ? 1
                : b.modified.compareTo(a.modified),
          );
          if (restored.length > maximumRestoredCopies) restored.removeLast();
        }
      }
      return true;
    });
    final keepRestored = restored.map((entry) => entry.name).toSet();
    // Unlink in fixed batches; old versions could accumulate >256 prepared
    // copies. Memory use and descriptor count must not scale with that debt.
    while (true) {
      final remove = <String>[];
      directory.visitEntries((name) {
        if (!keep.contains(name) &&
            !keep.any((snapshot) => name == '$snapshot.json') &&
            !keepRestored.contains(name)) {
          remove.add(name);
        }
        return remove.length < 128;
      });
      if (remove.isEmpty) break;
      for (final name in remove) {
        directory.remove(name);
      }
    }
    directory.sync();
  }

  /// Builds a separate verified copy. It never swaps an application's live
  /// database. The offline activation owner must stop all service/read owners,
  /// check binary/helper compatibility, and retain the newer profile separately.
  /// The confirmation concerns the snapshot's explicit data-loss point.
  String restoreCopy(
    String name, {
    required int supportedVersion,
    required bool confirmDataLoss,
  }) {
    if (!confirmDataLoss) {
      throw StateError('Confirm the backup data-loss point before restoring.');
    }
    if (!_namePattern.hasMatch(name)) {
      throw ArgumentError('Invalid migration snapshot name.');
    }
    final directory = _directory();
    try {
      _validateDirectory(directory);
      MigrationSnapshot? selected;
      _visitSnapshotMetadata(directory, supportedVersion, (snapshot) {
        if (snapshot.name == name) selected = snapshot;
      });
      final snapshot = selected;
      if (snapshot == null) {
        throw StateError(
          'No verified schema-compatible migration snapshot is available.',
        );
      }
      final restored = 'restore-${_nonce()}.db';
      final temporary = '$restored.partial';
      final source = directory.open(name);
      BackupFile? destination;
      try {
        if (source.digest() != snapshot.sha256) {
          throw StateError('Migration backup checksum verification failed.');
        }
        _verifyDatabase(source, snapshot.schema);
        destination = directory.open(temporary, create: true);
        source.copyTo(destination);
        if (destination.digest() != snapshot.sha256) {
          throw StateError('Restored backup checksum verification failed.');
        }
        _verifyDatabase(destination, snapshot.schema);
      } catch (_) {
        if (destination != null) {
          destination.close();
          try {
            directory.remove(temporary);
          } catch (_) {}
        }
        rethrow;
      } finally {
        source.close();
        destination?.close();
      }
      directory.publish(temporary, restored);
      _prune(directory, preserveRestore: restored);
      return p.join(directory.path, restored);
    } finally {
      directory.close();
    }
  }

  /// Opportunistic age/count cleanup while the application is running.
  void prune() {
    if (!exists) return;
    final directory = _directory();
    try {
      _prune(directory);
    } finally {
      directory.close();
    }
  }

  /// A clear or any content deletion invalidates every snapshot, because each
  /// SQLite snapshot may contain the deleted data. Failure leaves the caller's
  /// durable privacy marker in place; untrusted entries are never followed.
  void erase() {
    if (!exists) return;
    final directory = _directory();
    try {
      _validateDirectory(directory);
      while (true) {
        final entries = directory.entries(allowTruncated: true);
        if (entries.isEmpty) break;
        for (final entry in entries) {
          directory.remove(entry);
        }
      }
      directory.sync();
      directory.verifyAnchor();
    } finally {
      directory.close();
    }
  }
}
