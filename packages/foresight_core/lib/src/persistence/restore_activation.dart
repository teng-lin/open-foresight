import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../profile_paths.dart';
import '../service_ownership.dart';
import 'backup_files.dart';
import 'migration_backups.dart';
import 'restore_pending.dart';
import 'sqlite_preflight.dart';
import 'sqlite_runtime.dart';

/// Activation stopped before completing; the message says what was retained.
class RestoreActivationRefused extends StateError {
  RestoreActivationRefused(super.message);
}

/// A service (or another owner) holds the profile lock. Nothing was changed.
final class ActiveProfileOwner extends RestoreActivationRefused {
  ActiveProfileOwner()
    : super(
        'An Open Foresight service owns this profile. Stop it with its own '
        '--stop, then retry; nothing was changed.',
      );
}

final class RestoreActivationResult {
  const RestoreActivationResult({
    required this.snapshot,
    required this.replacedSchema,
    required this.database,
    required this.displaced,
    this.recovered = const [],
  });

  /// The active profile now holds this snapshot. Its [MigrationSnapshot.created]
  /// time is the data-loss point: later changes exist only in [displaced].
  final MigrationSnapshot snapshot;
  final int replacedSchema;
  final String database;

  /// The previous live database, now a managed migration snapshot of the
  /// restored profile: listed, pruned and erased like every other snapshot.
  final MigrationSnapshot displaced;

  /// Previous profiles that recovery of an earlier interrupted activation
  /// retained as managed snapshots before this one started.
  final List<MigrationSnapshot> recovered;

  Map<String, Object> toJson() => {
    'snapshot': snapshot.name,
    'schema': snapshot.schema,
    'data_loss_point': snapshot.created.toIso8601String(),
    'replaced_schema': replacedSchema,
    'database': database,
    'displaced_snapshot': displaced.name,
    'displaced_retained_until': displaced.created
        .add(MigrationBackups.maximumAge)
        .toIso8601String(),
    'recovered_snapshots': [for (final snapshot in recovered) snapshot.name],
  };
}

/// What a durable marker records before any live name changes.
typedef _Marker = ({String sha256, String previous, int replacedSchema});

/// Offline activation of a verified migration snapshot as a profile's live
/// database. The caller must be a dedicated process that hosts no service
/// owner of this profile: it takes the real profile lock, which every released
/// service holds while serving (S4), and keeps it across the whole swap.
/// That cooperative lock is what makes the profile offline. SQLite's own
/// locks are a second check and prove less: they show a connection inside a
/// transaction, or a WAL connection that has read (it keeps its shared lock
/// until it closes), but not an idle rollback-journal connection. Such a
/// connection keeps the previous database's descriptor: after the exchange it
/// reads that database, and SQLite refuses its writes with
/// SQLITE_READONLY_DBMOVED because the name now holds another file.
///
/// Activation holds SQLite's EXCLUSIVE lock on the previous database from the
/// quiesce until after any reverse exchange, and on the restored copy from
/// before the exchange until its marker is resolved. A connection that ignores
/// the profile lock gets SQLITE_BUSY instead of writing to either database
/// while its name changes.
///
/// The live name is never absent. A prepared copy is staged beside the live
/// database, then one atomic exchange swaps the two names. A durable marker
/// records the snapshot digest and the previous database's identity before
/// staging, so recovery tells the staged backup copy (removable) from the
/// previous profile (always retained) without any other journal.
///
/// The previous profile is retained as a managed snapshot of the restored
/// profile, so it falls under the bounded migration-backup retention and is
/// erased by workspace clear and content deletion like every other snapshot.
/// Activation refuses while such an erasure is still pending.
///
/// [supportedVersion] must come from the schema authority of the code that
/// will open the profile next (Store.schemaVersion); neither a snapshot nor
/// a live profile newer than it is accepted, so a downgrade restores with the
/// newer installation first. Binary, helper and model compatibility are not
/// covered.
final class RestoreActivation {
  RestoreActivation({
    required this.profile,
    required String databasePath,
    required this.supportedVersion,
    DateTime Function()? now,
    void Function(String stage)? checkpoint,
  }) : databasePath = p.join(
         canonicalProfilePath(profile.data),
         p.basename(databasePath),
       ),
       _now = now ?? DateTime.now,
       _checkpoint = checkpoint ?? _ignore {
    if (canonicalProfilePath(p.dirname(p.absolute(databasePath))) !=
        canonicalProfilePath(profile.data)) {
      throw ArgumentError(
        'The database must be inside the owned profile directory.',
      );
    }
  }

  final ProfilePaths profile;
  final String databasePath;
  final int supportedVersion;
  final DateTime Function() _now;

  /// Tests only: called after each durable step, to inject a failure or crash.
  final void Function(String stage) _checkpoint;
  static void _ignore(String _) {}

  /// Store's durable deletion intents, written by the schema's triggers in the
  /// same transaction as a deletion and removed once backups are erased.
  static const _erasureIntents = [
    'internal.privacyMaintenancePending',
    'internal.backupErasurePending',
  ];

  String get _base => p.basename(databasePath);
  RegExp get _staged => restoringDatabase(_base);
  RegExp get _marker => restoringMarker(_base);
  RegExp get _partialMarker => restoringPartialMarker(_base);

  static String _nonce() {
    final random = Random.secure();
    return List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  /// Verified, schema-compatible candidates, newest first. Reads only.
  List<MigrationSnapshot> candidates() => MigrationBackups(
    databasePath,
    now: _now,
  ).snapshots(supportedVersion: supportedVersion);

  /// Replace the live database with snapshot [name]. [acceptDataLossOf] must
  /// name the same snapshot: changes after its creation leave the active
  /// profile and stay only in the displaced database.
  Future<RestoreActivationResult> activate(
    String name, {
    required String acceptDataLossOf,
  }) async {
    if (acceptDataLossOf != name) {
      throw RestoreActivationRefused(
        'Confirm the data-loss point by naming snapshot $name again; '
        'nothing was changed.',
      );
    }
    return _owned((data) {
      final recovered = _recover(data);
      final retainedNote = recovered.isEmpty
          ? ''
          : ' Recovery retained the previous profile as snapshot '
                '${recovered.map((s) => s.name).join(', ')}.';
      final backups = MigrationBackups(databasePath, now: _now);
      MigrationSnapshot? selected;
      for (final snapshot in backups.snapshots(
        supportedVersion: supportedVersion,
      )) {
        if (snapshot.name == name) selected = snapshot;
      }
      final snapshot = selected;
      if (snapshot == null) {
        throw RestoreActivationRefused(
          'No verified snapshot $name for this profile at schema '
          '$supportedVersion or older; nothing was replaced.$retainedNote',
        );
      }
      final staged = '$_base.restoring-${_nonce()}';
      final marker = '$staged.json';
      final quiesced = _quiesce();
      _Reservation? reserved;
      try {
        final _Marker record = (
          sha256: snapshot.sha256,
          previous: data.metadata(_base, private: false).identity,
          replacedSchema: quiesced.schema,
        );
        _checkpoint('quiesced');
        // Rechecks digest, schema, source identity and SQLite integrity.
        final prepared = backups.restoreCopy(
          name,
          supportedVersion: supportedVersion,
          confirmDataLoss: true,
        );
        _checkpoint('prepared');
        _writeMarker(data, marker, snapshot, record);
        _checkpoint('marked');
        String? copy;
        try {
          final directory = BackupDirectory(
            backups.directoryPath,
            create: false,
          );
          try {
            directory.renameInto(p.basename(prepared), data, staged);
          } finally {
            directory.close();
          }
          final file = data.open(staged);
          try {
            copy = file.identity;
            if (file.digest() != snapshot.sha256) {
              throw RestoreActivationRefused(
                'Staged restore copy checksum verification failed.',
              );
            }
            // A rollback-journal page 1 (bytes 18/19): reserving the copy
            // then creates no WAL named after the staged path.
            final header = Uint8List(100);
            if (file.readAt(header, 0) != 100 ||
                header[18] != 1 ||
                header[19] != 1) {
              throw RestoreActivationRefused(
                'The restore copy is not a rollback-journal database.',
              );
            }
          } finally {
            file.close();
          }
          _checkpoint('staged');
          // No descriptor of this process opens the copy from here on.
          reserved = _reserve(p.join(data.path, staged));
          _requireNoSidecars();
          if (data.metadata(_base, private: false).identity !=
              record.previous) {
            throw RestoreActivationRefused(
              'The profile database changed during activation.',
            );
          }
          _checkpoint('exchanging');
          data.renameInto(
            staged,
            data,
            _base,
            exchange: true,
            fromPrivate: true,
            toPrivate: false,
          );
          _checkpoint('exchanged');
          _confirm(data, reserved, copy, snapshot.schema);
          _checkpoint('confirmed');
        } catch (error) {
          _rollback(
            data,
            staged,
            marker,
            record,
            copy: copy,
            quiesced: quiesced,
            error: error,
          );
          rethrow;
        }
        // The previous database is at the staged name now. Release its lock
        // before a descriptor of this process opens it; the restored
        // database stays reserved until its marker is resolved.
        quiesced.release();
        final MigrationSnapshot displaced;
        try {
          displaced = _retain(data, staged, record);
          data.remove(marker);
          data.sync();
        } catch (error) {
          throw RestoreActivationRefused(
            'The restored profile is active, but the previous profile is '
            'still at ${p.join(data.path, staged)} ($error). Run '
            'foresight-service --restore-recover '
            'to retain it as a managed snapshot.',
          );
        }
        return RestoreActivationResult(
          snapshot: snapshot,
          replacedSchema: record.replacedSchema,
          database: databasePath,
          displaced: displaced,
          recovered: recovered,
        );
      } finally {
        reserved?.release();
        quiesced.release();
      }
    });
  }

  /// Resolve an interrupted activation. Returns the snapshots that now retain
  /// a previous profile.
  Future<List<MigrationSnapshot>> recover() => _owned(_recover);

  Future<T> _owned<T>(T Function(BackupDirectory data) use) async {
    // A second descriptor in an owner's process would drop its POSIX lock.
    if (hasLocalServiceOwner(canonicalProfilePath(profile.data))) {
      throw ActiveProfileOwner();
    }
    final RandomAccessFile lock;
    try {
      lock = await acquireServiceProfileLock(
        profile,
        launchWithdrawn: () => false,
      );
    } on ServiceOwnershipContended {
      throw ActiveProfileOwner();
    }
    try {
      final data = BackupDirectory(
        p.dirname(databasePath),
        create: false,
        private: false,
      );
      try {
        return use(data);
      } finally {
        data.close();
      }
    } finally {
      lock.closeSync();
    }
  }

  /// Refuse while another connection holds a SQLite lock on the live
  /// database, leave a self-contained rollback-journal file so no WAL can
  /// attach to the other database after the names swap, and keep an EXCLUSIVE
  /// transaction open so no connection can read or write it until
  /// [_Reservation.release]. The transaction writes nothing, so it creates no
  /// journal. The first service open re-establishes WAL.
  _Reservation _quiesce() {
    // Store's newer-profile policy first: page 1 and a private WAL copy are
    // read without any live writable connection, so an unsupported live
    // profile keeps its journal mode and bytes. Restore it with the
    // installation that supports it before choosing older binaries.
    try {
      final preflight = SqlitePreflight(
        databasePath,
        supportedVersion: supportedVersion,
      );
      preflight.qualify();
      preflight.verifyUnchanged();
    } on StateError catch (error) {
      throw RestoreActivationRefused(
        'This installation cannot replace the live profile '
        '(${error.message}). Run the restore from an installation that '
        'supports it; nothing was changed.',
      );
    }
    Database open() {
      try {
        return openApplicationDatabase(databasePath, mode: OpenMode.readWrite);
      } on SqliteException catch (error) {
        throw RestoreActivationRefused(
          'Cannot open the profile database for activation ($error); '
          'nothing was changed.',
        );
      }
    }

    // Read before the journal mode changes, so a refusal changes nothing.
    final early = open();
    try {
      _refuseErasureIntent(early, 'nothing was changed');
    } on SqliteException catch (error) {
      throw RestoreActivationRefused(
        'Another process has the profile database open ($error). Close every '
        'Open Foresight reader, then retry; nothing was changed.',
      );
    } finally {
      early.dispose();
    }
    _checkpoint('preflighted');
    // A connection that read in WAL mode keeps pages cached from before
    // another connection's later commit, even after it leaves WAL under an
    // EXCLUSIVE lock (observed with SQLite 3.45.1). Switch and recheck on a
    // connection that has cached nothing.
    final db = open();
    try {
      if (db.select('PRAGMA journal_mode=DELETE').single.values.single !=
          'delete') {
        throw RestoreActivationRefused(
          'Another process has the profile database open. Close every Open '
          'Foresight reader, then retry; the profile was not replaced.',
        );
      }
      db.execute('BEGIN EXCLUSIVE');
      // A writer that ignores the profile lock may have committed since the
      // checks above; repeat them under the lock. The journal mode has
      // changed by now, and Store re-establishes WAL.
      final schema =
          db.select('PRAGMA user_version').single.values.single as int;
      if (schema < 0 || schema > supportedVersion) {
        throw RestoreActivationRefused(
          'This installation cannot replace the live profile (Unsupported '
          'newer application database version $schema (maximum '
          '$supportedVersion)). Run the restore from an installation that '
          'supports it; the profile was not replaced.',
        );
      }
      _refuseErasureIntent(db, 'the profile was not replaced');
      _requireNoSidecars();
      return _Reservation(db, schema);
    } on SqliteException catch (error) {
      db.dispose();
      throw RestoreActivationRefused(
        'Another process has the profile database open ($error). Close every '
        'Open Foresight reader, then retry; the profile was not replaced.',
      );
    } catch (_) {
      db.dispose();
      rethrow;
    }
  }

  /// A -shm without -wal is reinitialized by the next WAL opener's DMS lock.
  void _requireNoSidecars() {
    for (final suffix in ['-wal', '-journal']) {
      if (FileSystemEntity.typeSync(
            '$databasePath$suffix',
            followLinks: false,
          ) !=
          FileSystemEntityType.notFound) {
        throw RestoreActivationRefused(
          'SQLite file $databasePath$suffix remains, so the database cannot '
          'be swapped safely.',
        );
      }
    }
  }

  void _refuseErasureIntent(Database db, String outcome) {
    if (db
            .select(
              "SELECT 1 FROM sqlite_master WHERE type='table' AND name='preferences'",
            )
            .isNotEmpty &&
        db
            .select(
              'SELECT 1 FROM preferences WHERE key IN (?,?) LIMIT 1',
              _erasureIntents,
            )
            .isNotEmpty) {
      throw RestoreActivationRefused(
        'A deletion or workspace clear in this profile has not finished '
        'erasing its backups, so snapshots may still hold deleted content. '
        'Start Open Foresight so privacy maintenance completes; $outcome.',
      );
    }
  }

  /// Take SQLite's EXCLUSIVE lock on the staged copy at [path] while it has
  /// its staged name. The descriptor follows the file through the exchange,
  /// so the restored database is never unreserved under the live name until
  /// [_Reservation.release].
  _Reservation _reserve(String path) {
    final db = openApplicationDatabase(path, mode: OpenMode.readWrite);
    try {
      db.execute('BEGIN EXCLUSIVE');
      return _Reservation(
        db,
        db.select('PRAGMA user_version').single.values.single as int,
      );
    } catch (_) {
      db.dispose();
      rethrow;
    }
  }

  /// Confirm through the reservation itself: another connection to the
  /// restored file could not read it, and a second descriptor would drop the
  /// reservation's POSIX locks when closed.
  void _confirm(
    BackupDirectory data,
    _Reservation reserved,
    String copy,
    int schema,
  ) {
    if (data.metadata(_base, private: false).identity != copy ||
        reserved.db.select('PRAGMA user_version').single.values.single !=
            schema ||
        reserved.db.select('PRAGMA integrity_check').single.values.single !=
            'ok') {
      throw RestoreActivationRefused(
        'The restored profile did not open with its snapshot schema.',
      );
    }
    _requireNoSidecars();
  }

  void _writeMarker(
    BackupDirectory data,
    String marker,
    MigrationSnapshot snapshot,
    _Marker record,
  ) {
    final file = data.open('$marker.partial', create: true);
    try {
      file.write(
        utf8.encode(
          jsonEncode({
            'format': 1,
            'snapshot': snapshot.name,
            'sha256': record.sha256,
            'previous': record.previous,
            'replaced_schema': record.replacedSchema,
          }),
        ),
      );
      file.sync();
    } finally {
      file.close();
    }
    data.publish('$marker.partial', marker);
  }

  _Marker _readMarker(BackupDirectory data, String marker) {
    final file = data.open(marker);
    try {
      final value = jsonDecode(utf8.decode(file.readSmall(4096)));
      if (value is Map &&
          value['format'] == 1 &&
          value['sha256'] is String &&
          RegExp(r'^[a-f0-9]{64}$').hasMatch(value['sha256'] as String) &&
          value['previous'] is String &&
          (value['previous'] as String).isNotEmpty &&
          value['replaced_schema'] is int &&
          (value['replaced_schema'] as int) >= 0) {
        return (
          sha256: value['sha256'] as String,
          previous: value['previous'] as String,
          replacedSchema: value['replaced_schema'] as int,
        );
      }
    } on FormatException {
      // Reported below.
    } finally {
      file.close();
    }
    throw RestoreActivationRefused(
      'Unreadable restore marker ${p.join(data.path, marker)}; inspect it. '
      'Nothing was changed.',
    );
  }

  void _rollback(
    BackupDirectory data,
    String staged,
    String marker,
    _Marker record, {
    required String? copy,
    required _Reservation quiesced,
    required Object error,
  }) {
    var swappedBack = true;
    try {
      // Probe the names: a rename can succeed before its check/fsync fails.
      // Both databases are still reserved, so neither can change meanwhile.
      if (copy != null &&
          data.containsEntry(staged) &&
          data.metadata(_base, private: false).identity == copy) {
        if (FileSystemEntity.typeSync(
                  '$databasePath-wal',
                  followLinks: false,
                ) ==
                FileSystemEntityType.notFound &&
            FileSystemEntity.typeSync(
                  '$databasePath-journal',
                  followLinks: false,
                ) ==
                FileSystemEntityType.notFound) {
          data.renameInto(
            staged,
            data,
            _base,
            exchange: true,
            fromPrivate: false,
            toPrivate: false,
          );
        } else {
          // Such files belong to the restored database and must not attach
          // to the previous one; keep the restored database active instead.
          swappedBack = false;
        }
      }
      // _resolve may open the previous database. The copy needs no digest:
      // it held the live name only while reserved.
      quiesced.release();
      final displaced = _resolve(data, staged, marker, record, copy: copy);
      if (!swappedBack) {
        throw RestoreActivationRefused(
          'Activation failed ($error). The restored profile stays active '
          'because its SQLite files exist; the previous profile is retained '
          'as snapshot ${displaced?.name}.',
        );
      }
    } on RestoreActivationRefused {
      rethrow;
    } catch (rollbackError) {
      quiesced.release();
      throw RestoreActivationRefused(
        'Activation failed ($error) and rollback did not complete '
        '($rollbackError). Run foresight-service --restore-recover; it never '
        'removes a profile.',
      );
    }
  }

  List<MigrationSnapshot> _recover(BackupDirectory data) {
    final markers = <String>[], staged = <String>[], partial = <String>[];
    data.visitEntries((name) {
      if (_marker.hasMatch(name)) {
        markers.add(name);
      } else if (_staged.hasMatch(name)) {
        staged.add(name);
      } else if (_partialMarker.hasMatch(name)) {
        partial.add(name);
      }
      return true;
    });
    for (final name in staged) {
      if (!markers.contains('$name.json')) {
        throw RestoreActivationRefused(
          'Unrecognized interrupted restore file ${p.join(data.path, name)}; '
          'inspect it. Nothing was changed.',
        );
      }
    }
    // A marker is published before its copy is staged, so a partial marker
    // never accompanies a staged database.
    for (final name in partial) {
      data.remove(name);
    }
    final displaced = <MigrationSnapshot>[];
    for (final marker in markers) {
      final result = _resolve(
        data,
        marker.substring(0, marker.length - 5),
        marker,
        _readMarker(data, marker),
      );
      if (result != null) displaced.add(result);
    }
    data.sync();
    return displaced;
  }

  /// The staged name holds the previous live database (the marker's
  /// identity), which is always retained, or the snapshot copy (this
  /// activation's [copy] or the marker digest), which is removed. With
  /// nothing staged, the previous database may already be retained.
  MigrationSnapshot? _resolve(
    BackupDirectory data,
    String staged,
    String marker,
    _Marker record, {
    String? copy,
  }) {
    MigrationSnapshot? displaced;
    if (data.containsEntry(staged)) {
      final identity = data.metadata(staged, private: false).identity;
      if (identity == record.previous) {
        displaced = _retain(data, staged, record);
      } else {
        if (identity != copy) {
          final file = data.open(staged, private: false);
          try {
            if (file.digest() != record.sha256) {
              throw RestoreActivationRefused(
                'Interrupted restore file ${p.join(data.path, staged)} is '
                'neither the previous profile nor the snapshot copy; inspect '
                'it. Nothing was removed.',
              );
            }
          } finally {
            file.close();
          }
        }
        data.remove(staged);
      }
    } else {
      displaced = _retainedAs(record.previous);
    }
    data.remove(marker);
    data.sync();
    return displaced;
  }

  /// The managed snapshot whose payload is the file [previous], if retained.
  MigrationSnapshot? _retainedAs(String previous) {
    final path = MigrationBackups(databasePath).directoryPath;
    if (FileSystemEntity.typeSync(path, followLinks: false) ==
        FileSystemEntityType.notFound) {
      return null;
    }
    final backups = BackupDirectory(path, create: false);
    try {
      String? found;
      backups.visitEntries((name) {
        if (_payload.hasMatch(name) &&
            backups.metadata(name).identity == previous) {
          found = name;
          return false;
        }
        return true;
      });
      final name = found;
      if (name == null) return null;
      // Published before the payload, by _retain.
      final manifest = backups.open('$name.json');
      try {
        final value = jsonDecode(utf8.decode(manifest.readSmall(4096))) as Map;
        return MigrationSnapshot(
          name: name,
          schema: value['schema'] as int,
          created: DateTime.fromMillisecondsSinceEpoch(
            value['created'] as int,
            isUtc: true,
          ),
          sha256: value['sha256'] as String,
          sourceIdentity: value['source'] as String,
        );
      } finally {
        manifest.close();
      }
    } finally {
      backups.close();
    }
  }

  static final _payload = RegExp(r'^snapshot-[0-9]{1,16}-[a-f0-9]{32}\.db$');

  /// Publish the previous live database at [staged] as a managed snapshot of
  /// the live profile. Its manifest is published first: an orphan manifest is
  /// never a candidate and is pruned, while the payload rename is atomic.
  MigrationSnapshot _retain(
    BackupDirectory data,
    String staged,
    _Marker record,
  ) {
    final created = DateTime.fromMillisecondsSinceEpoch(
      _now().toUtc().millisecondsSinceEpoch,
      isUtc: true,
    );
    final name = 'snapshot-${created.millisecondsSinceEpoch}-${_nonce()}.db';
    final source = data.metadata(_base, private: false).identity;
    final String digest;
    final file = data.open(staged, private: false);
    try {
      if (file.identity != record.previous) {
        throw RestoreActivationRefused(
          'The previous profile at ${p.join(data.path, staged)} changed; '
          'inspect it. Nothing was removed.',
        );
      }
      // Managed backup storage admits only owner-only files.
      file.restrictToOwner();
      file.sync();
      digest = file.digest();
    } finally {
      file.close();
    }
    final backups = BackupDirectory(
      MigrationBackups(databasePath).directoryPath,
    );
    try {
      final manifest = backups.open('$name.json.partial', create: true);
      try {
        manifest.write(
          utf8.encode(
            jsonEncode({
              'format': 1,
              'schema': record.replacedSchema,
              'created': created.millisecondsSinceEpoch,
              'sha256': digest,
              'source': source,
            }),
          ),
        );
        manifest.sync();
      } finally {
        manifest.close();
      }
      backups.publish('$name.json.partial', '$name.json');
      _checkpoint('retaining');
      data.renameInto(staged, backups, name);
      _checkpoint('retained');
    } finally {
      backups.close();
    }
    return MigrationSnapshot(
      name: name,
      schema: record.replacedSchema,
      created: created,
      sha256: digest,
      sourceIdentity: source,
    );
  }
}

/// A connection holding a write-free EXCLUSIVE transaction on one database
/// file: the previous live database (quiesce) or the restored copy.
final class _Reservation {
  _Reservation(this.db, this.schema);
  final Database db;
  final int schema;
  var _released = false;

  /// Idempotent. Ends the transaction without writing, then closes.
  void release() {
    if (_released) return;
    _released = true;
    try {
      if (!db.autocommit) db.execute('ROLLBACK');
    } finally {
      db.dispose();
    }
  }
}
