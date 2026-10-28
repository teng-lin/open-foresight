import 'persistence/preference_entities.dart';
import 'persistence/audio_store.dart';
import 'persistence/application_schema.dart';
import 'persistence/sqlite_snapshot_source.dart';
import 'label_organization.dart';
import 'read_models.dart';
import 'persistence/label_organization_store.dart';
export 'persistence/output_statistics.dart' show outputWeekStart;
import 'persistence/output_statistics.dart';
import 'persistence/request_key_store.dart';
import 'persistence/source_store.dart';
import 'persistence/source_queries.dart';
import 'persistence/read_schema_guard.dart';
import 'persistence/meeting_store.dart';
import 'meeting_attribution.dart';
export 'document_parser.dart' show Parser;
export 'persistence/model_store.dart' show requireEmbeddingBundle;
import 'persistence/model_store.dart';
import 'persistence/meeting_queries.dart';
import 'persistence/label_store.dart';
import 'persistence/schema_migrations.dart';
import 'persistence/content_history.dart';
import 'persistence/sqlite_preflight.dart';
import 'persistence/migration_backups.dart';
import 'persistence/restore_pending.dart';
import 'rpc_error.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'graph_labels.dart';
import 'dart:math' show Random;
import 'persistence/sqlite_runtime.dart';
import 'platform_services.dart'
    show RuntimeConfiguration, currentOwnerRuntimeSnapshot;

/// Linux application schema, independently versioned from helper databases.
class Store implements SqliteSnapshotSource {
  @override
  final Database db;
  @override
  final String path;
  static const schemaVersion = applicationSchemaVersion;
  AudioStore get audioStore => AudioStore.forStore(this);
  ContentHistory get contentHistory =>
      ContentHistory(db, supportedVersion: schemaVersion);

  /// Names one workspace between clears. SQLite reuses INTEGER PRIMARY KEY
  /// values after a clear, so a caller holding an ID sends this back with it.
  static const workspaceEpochKey = 'workspaceEpoch';

  /// How long a request key keeps a retry after a lost reply from writing
  /// twice. Keys hold digests of content, so they are kept only this long.
  static const requestKeyLifetime = Duration(hours: 24);
  static const _privacyMaintenanceKey = 'internal.privacyMaintenancePending';
  static const _backupErasureKey = 'internal.backupErasurePending';
  Timer? _privacyMaintenanceRetry;
  var _privacyRetrySeconds = 1;
  var _privacyMaintenancePending = false;
  var _closed = false;

  /// Local deletion is committed even while a reader prevents WAL erasure.
  bool get privacyMaintenancePending =>
      _privacyMaintenancePending || _hasAnyPrivacyMarker();
  MigrationBackups get migrationBackups => MigrationBackups(path);
  StreamSubscription<SqliteUpdate>? _privacyUpdates;
  Timer? _privacyProbe;
  Timer? _historyExpiry;

  /// An explicit or bound owner snapshot, fixed at construction; null for a
  /// store built outside any owner scope, whose model queries read the
  /// boundary at use as before.
  final RuntimeConfiguration? configuration;

  // An interrupted offline restore refuses before any SQLite file is opened.
  Store.readOnly(this.path, {RuntimeConfiguration? configuration})
    : configuration = configuration?.snapshot() ?? currentOwnerRuntimeSnapshot,
      db = openApplicationDatabase(
        requireNoPendingRestore(path),
        mode: OpenMode.readOnly,
      ) {
    try {
      _checkVersion();
      _privacyMaintenancePending = readSnapshot(
        db,
        () =>
            rows(
              "SELECT 1 FROM sqlite_master WHERE type='table' AND name='preferences'",
            ).isNotEmpty &&
            _hasAnyPrivacyMarker(),
        supportedVersion: schemaVersion,
      );
    } catch (_) {
      db.dispose();
      rethrow;
    }
  }

  Store(this.path, {RuntimeConfiguration? configuration})
    : configuration = configuration?.snapshot() ?? currentOwnerRuntimeSnapshot,
      db = _openForMigrations(requireNoPendingRestore(path)) {
    try {
      // Refuse newer profiles before even changing their journal mode.
      final originalVersion = _checkVersion();
      final migratingExisting =
          path != ':memory:' &&
          originalVersion < schemaVersion &&
          db
              .select(
                "SELECT 1 FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' LIMIT 1",
              )
              .isNotEmpty;
      // Establish the shared-memory WAL index under NORMAL before taking
      // exclusive migration ownership. First WAL access under EXCLUSIVE uses
      // a heap index whose locking mode cannot return to NORMAL until close.
      db.execute('PRAGMA secure_delete=ON');
      db.execute('PRAGMA locking_mode=NORMAL');
      db.execute('PRAGMA journal_mode=WAL');
      db.select('SELECT COUNT(*) FROM sqlite_master');
      if (migratingExisting) {
        // The service already owns the profile. Retain SQLite's exclusive lock
        // over the autocommit VACUUM INTO and following migration transaction;
        // another active writer makes startup fail before migration begins.
        db.execute('PRAGMA locking_mode=EXCLUSIVE');
        db.execute('BEGIN EXCLUSIVE');
        db.execute('COMMIT');
        // Finish durable deletion debt before a fresh rollback point exists.
        // Refuse the upgrade if readers or unsafe backup storage prevent it;
        // retaining the intent must never erase our new snapshot on a timer.
        if (_hasPreferencesTable() && !_completePrivacyMaintenance()) {
          throw StateError('Privacy maintenance must finish before migration.');
        }
        migrationBackups.create(db, originalVersion);
      }
      // Migrations populate the WAL before readers open the fresh profile.
      // Switching only after COMMIT leaves no WAL for macOS read-only clients.
      db.execute('PRAGMA foreign_keys=ON');
      db.execute('BEGIN IMMEDIATE');
      try {
        // Re-read while holding the writer lock: another opener may have migrated.
        var version = _checkVersion();
        while (version < schemaVersion) {
          _migrateTo(++version);
          db.execute('PRAGMA user_version=$version');
        }
        // The first start creates the epoch; later starts keep it.
        db.execute('INSERT OR IGNORE INTO preferences(key,value) VALUES(?,?)', [
          workspaceEpochKey,
          _newWorkspaceEpoch(),
        ]);
        _pruneRequestKeys();
        db.execute('COMMIT');
        if (migratingExisting) {
          if (db.select('PRAGMA locking_mode=NORMAL').single.values.single !=
              'normal') {
            throw StateError('Migration ownership could not be released.');
          }
          db.execute('BEGIN');
          db.select('SELECT 1 FROM preferences LIMIT 1');
          db.execute('COMMIT');
        }
      } catch (_) {
        // SQLITE_FULL/IOERR can already roll back the transaction.
        if (!db.autocommit) db.execute('ROLLBACK');
        rethrow;
      }
    } catch (_) {
      db.dispose();
      rethrow;
    }
    _privacyMaintenancePending = _hasAnyPrivacyMarker();
    if (_privacyMaintenancePending) _schedulePrivacyMaintenance();
    // Synchronous notifications allocate only one deferred probe, regardless
    // of row count. Never execute SQL reentrantly inside SQLite's update hook.
    _privacyUpdates = db.updatesSync.listen((update) {
      if (update.tableName != 'preferences' ||
          _privacyProbe != null ||
          _closed) {
        return;
      }
      _privacyProbe = Timer(Duration.zero, _probePrivacyMaintenance);
    });
    _expireHistory();
  }

  void _probePrivacyMaintenance() {
    _privacyProbe = null;
    if (_closed) return;
    if (!db.autocommit) {
      _privacyProbe = Timer(
        const Duration(seconds: 1),
        _probePrivacyMaintenance,
      );
      return;
    }
    if (_hasAnyPrivacyMarker()) {
      _privacyMaintenancePending = true;
      _schedulePrivacyMaintenance();
    }
  }

  void _expireHistory() {
    if (_closed) return;
    // The timestamp index limits each pass. Old inactive entities need no full
    // rescan, and reads exclude expired revisions even before this batch runs.
    var delay = const Duration(hours: 1);
    try {
      db.execute(
        'DELETE FROM content_revisions WHERE id IN (SELECT id FROM content_revisions WHERE created<? ORDER BY created LIMIT 256)',
        [
          DateTime.now()
              .subtract(ContentHistory.maximumAge)
              .millisecondsSinceEpoch,
        ],
      );
      if (db.updatedRows == 256) delay = const Duration(milliseconds: 10);
      if (PreferenceEntities(db).pruneLegacy()) {
        delay = const Duration(milliseconds: 10);
      }
      if (path != ':memory:') migrationBackups.prune();
    } catch (_) {
      // Reads already exclude expired records. Retry physical retention without
      // turning a busy/full maintenance write into application failure.
      delay = const Duration(seconds: 30);
    }
    _historyExpiry = Timer(delay, _expireHistory);
  }

  bool _hasPreferencesTable() => rows(
    "SELECT 1 FROM sqlite_master WHERE type='table' AND name='preferences'",
  ).isNotEmpty;

  bool _hasPrivacyMaintenanceMarker() => rows(
    'SELECT 1 FROM preferences WHERE key=?',
    [_privacyMaintenanceKey],
  ).isNotEmpty;

  bool _hasBackupErasureMarker() => rows(
    'SELECT 1 FROM preferences WHERE key=?',
    [_backupErasureKey],
  ).isNotEmpty;
  bool _hasAnyPrivacyMarker() =>
      _hasPrivacyMaintenanceMarker() || _hasBackupErasureMarker();

  /// Persist the cleanup intent in the same transaction as the content deletion.
  /// Scheduling starts only after that transaction commits, via compactAfterClear.
  void markPrivacyMaintenancePending() {
    db.execute('INSERT OR IGNORE INTO preferences(key,value) VALUES(?,?)', [
      _privacyMaintenanceKey,
      '1',
    ]);
  }

  /// Erase freed pages after a committed workspace clear. Live readers can keep
  /// a checkpoint busy, so maintenance failure must not undo the local clear.
  void compactAfterClear() {
    markPrivacyMaintenancePending();
    _privacyMaintenancePending = true;
    _privacyRetrySeconds = 1;
    _retryPrivacyMaintenance();
  }

  void _schedulePrivacyMaintenance() {
    if (_closed || _privacyMaintenanceRetry != null) return;
    _privacyMaintenanceRetry = Timer(
      Duration(seconds: _privacyRetrySeconds),
      () {
        _privacyMaintenanceRetry = null;
        _retryPrivacyMaintenance();
      },
    );
    _privacyRetrySeconds = (_privacyRetrySeconds * 2).clamp(1, 30);
  }

  void _retryPrivacyMaintenance() {
    if (_closed || !_privacyMaintenancePending) return;
    if (!db.autocommit) {
      _schedulePrivacyMaintenance();
      return;
    }
    try {
      if (!_completePrivacyMaintenance()) {
        _schedulePrivacyMaintenance();
        return;
      }
      _privacyMaintenancePending = false;
      _privacyMaintenanceRetry?.cancel();
      _privacyMaintenanceRetry = null;
      _privacyRetrySeconds = 1;
    } catch (error) {
      // This runs after the clear committed: maintenance must not turn an
      // erased workspace into a failed transaction or discard its retry.
      stderr.writeln('Workspace privacy maintenance deferred: $error');
      _schedulePrivacyMaintenance();
    }
  }

  /// Complete existing debt before snapshotting, or retain it in full on any
  /// failure. This requires autocommit and may run under migration ownership.
  bool _completePrivacyMaintenance() {
    final compact = _hasPrivacyMaintenanceMarker();
    if (!compact && !_hasBackupErasureMarker()) return true;
    if (!db.autocommit) {
      throw StateError('Privacy cleanup requires autocommit.');
    }
    if (path != ':memory:') migrationBackups.erase();
    for (final statement in [
      'PRAGMA wal_checkpoint(TRUNCATE)',
      if (compact) 'VACUUM',
      if (compact) 'PRAGMA wal_checkpoint(TRUNCATE)',
    ]) {
      final result = db.select(statement);
      if (statement.startsWith('PRAGMA wal_checkpoint') &&
          result.isNotEmpty &&
          result.first.values.first != 0) {
        return false;
      }
    }
    db.execute('DELETE FROM preferences WHERE key IN (?,?)', [
      _privacyMaintenanceKey,
      _backupErasureKey,
    ]);
    return true;
  }

  // Even opening and closing a writable connection can checkpoint a WAL.
  // Refuse future profiles through a separate read-only connection first.
  static Database _openForMigrations(String path) {
    if (path != ':memory:') {
      final canonical = File(path).existsSync()
          ? File(path).resolveSymbolicLinksSync()
          : path;
      final preflight = SqlitePreflight(
        canonical,
        supportedVersion: schemaVersion,
      );
      preflight.qualify();
      preflight.verifyUnchanged();
    }
    return openApplicationDatabase(path);
  }

  int _checkVersion() => _supportedVersion(db);

  static int _supportedVersion(Database database) {
    final version =
        database.select('PRAGMA user_version').single.values.single as int;
    if (version > schemaVersion) {
      throw StateError(
        'Unsupported newer application database version $version '
        '(maximum $schemaVersion)',
      );
    }
    return version;
  }

  void _migrateTo(int version) => ApplicationMigrations(db).run(version);

  LabelStore get _labelStore => LabelStore(db, supportedVersion: schemaVersion);
  List<DocumentLabel> get documentLabels => _labelStore.documentLabels;

  List<Map<String, Object?>> rows(
    String sql, [
    List<Object?> args = const [],
  ]) => db.select(sql, args).map((r) => Map<String, Object?>.from(r)).toList();
  SourceQueries get sourceQueries => SourceQueries(
    db,
    supportedVersion: schemaVersion,
    configuration: configuration,
  );
  List<Map<String, Object?>> get sources => sourceQueries
      .sources()
      .map((source) => Map<String, Object?>.from(source.toRow()))
      .toList();
  // Browsing needs metadata, not every document body. Load content only for
  // search, graph embeddings, or the selected source detail.
  int _transactionReads = 0;
  @override
  String get dataRevision {
    // Never reuse an uncommitted snapshot after rollback or across transactions.
    if (!db.autocommit) return 'transaction:${++_transactionReads}';
    return '${db.select('SELECT total_changes()').single.values.single}:${db.select('PRAGMA data_version').single.values.single}';
  }

  String? _summaryRevision;
  List<Map<String, Object?>> _sourceSummaries = [];
  List<Map<String, Object?>> get sourceSummaries {
    final revision = dataRevision;
    return readSnapshot(db, () {
      if (_summaryRevision != revision) {
        _sourceSummaries = sourceQueries
            .summaries()
            .map((source) => Map<String, Object?>.from(source.toRow()))
            .toList();
        _summaryRevision = revision;
      }
      return _sourceSummaries;
    }, supportedVersion: schemaVersion);
  }

  SourceStore get _sourceStore =>
      SourceStore(db, supportedVersion: schemaVersion);
  String importText(
    String title,
    String text,
    String mime,
    String provenance, {
    String? id,
    int? modifiedAtMs,
    String? sourceUri,
    bool locallyEdited = false,
    bool generated = false,
  }) => _sourceStore.importText(
    title,
    text,
    mime,
    provenance,
    id: id,
    modifiedAtMs: modifiedAtMs,
    sourceUri: sourceUri,
    locallyEdited: locallyEdited,
    generated: generated,
  );
  void state(String id, String state, [String error = '']) =>
      _sourceStore.state(id, state, error);
  void tombstone(String id) {
    _sourceStore.tombstone(id);
    if (db.autocommit && _hasAnyPrivacyMarker()) {
      _privacyMaintenancePending = true;
      _schedulePrivacyMaintenance();
    }
  }

  void answer(
    String question,
    String body,
    String status,
    List<Map<String, Object?>> citations,
    String model, {
    String conversation = 'desktop',
    String? requestId,
    Map<String, dynamic>? modelResponse,
  }) => db.execute(
    'INSERT INTO answers(question,body,status,citations,model,created,conversation,request_id,model_response) VALUES(?,?,?,?,?,?,?,?,?)',
    [
      question,
      body,
      status,
      jsonEncode(citations),
      model,
      DateTime.now().millisecondsSinceEpoch,
      conversation,
      requestId,
      modelResponse == null ? null : jsonEncode(modelResponse),
    ],
  );

  /// Returns the note's ID. An update that finds no note fails rather than
  /// reporting a save that wrote nothing. Notes leave no tombstone, so a
  /// missing note may never have existed.
  int saveNote(int? id, String title, String body) {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    if (id == null) {
      db.execute('INSERT INTO notes(title,body,timestamp) VALUES(?,?,?)', [
        title,
        body,
        timestamp,
      ]);
      return db.lastInsertRowId;
    }
    db.execute(
      'UPDATE notes SET title=?,body=?,revision=revision+1,timestamp=? WHERE id=?',
      [title, body, timestamp, id],
    );
    if (db.updatedRows != 1) {
      throw RpcError(
        RpcErrorCode.notFound,
        'No note has this ID; omit id to create one.',
      );
    }
    return id;
  }

  String get workspaceEpoch => preference(workspaceEpochKey);

  /// Called inside the clear transaction, so IDs from before it never match.
  void renewWorkspaceEpoch() =>
      setPreference(workspaceEpochKey, _newWorkspaceEpoch());

  static String _newWorkspaceEpoch() {
    final random = Random.secure();
    return [
      for (var i = 0; i < 16; i++)
        random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ].join();
  }

  RequestKeyStore get _requestKeys =>
      RequestKeyStore(db, requestKeyLifetime: requestKeyLifetime);
  ({Object? result, bool replayed}) writeOnce(
    String? key,
    String operation,
    Object? Function() write, {
    String arguments = '',
  }) => _requestKeys.writeOnce(key, operation, write, arguments: arguments);
  void _pruneRequestKeys() => _requestKeys.prune();

  ModelStore get _modelStore => ModelStore(
    db,
    supportedVersion: schemaVersion,
    configuration: configuration,
  );
  Map<String, Object?> resolveModelRuntime(Map<String, Object?> model) =>
      _modelStore.resolveModelRuntime(model);
  Map<String, Object?>? model(String kind) => _modelStore.model(kind);
  List<Map<String, Object?>> get models => _modelStore.models;
  Future<List<String>> verifyRegisteredModels({
    bool rejectInvalidRegistrations = false,
  }) => _modelStore.verifyRegisteredModels(
    rejectInvalidRegistrations: rejectInvalidRegistrations,
  );
  Future<void> register(
    String kind,
    String path,
    String runtime, {
    String? backend,
    String? expectedDigest,
    int? modelType,
    bool Function()? current,
  }) => _modelStore.register(
    kind,
    path,
    runtime,
    backend: backend,
    expectedDigest: expectedDigest,
    modelType: modelType,
    current: current,
  );

  MeetingStore get meetingStore => MeetingStore(
    db,
    supportedVersion: schemaVersion,
    writeSource: importText,
    workspaceEpoch: () => workspaceEpoch,
  );
  int meeting(String title) => meetingStore.meeting(title);
  void saveMeetingNotes(int meetingId, String body, {int? lastManualEdit}) =>
      meetingStore.saveMeetingNotes(
        meetingId,
        body,
        lastManualEdit: lastManualEdit,
      );
  void transcript(
    int meeting,
    String text,
    bool finalText,
    int start,
    int end,
    String source,
  ) => meetingStore.transcript(meeting, text, finalText, start, end, source);
  TranscriptWrite transcriptWithAttribution(
    int meeting,
    String text,
    bool finalText,
    int start,
    int end,
    String source, {
    TranscriptAttribution? attribution,
  }) => meetingStore.transcriptWithAttribution(
    meeting,
    text,
    finalText,
    start,
    end,
    source,
    attribution: attribution,
  );
  List<MeetingParticipant> saveMeetingParticipants(
    int meeting,
    List<MeetingParticipant> participants,
  ) => meetingStore.saveParticipants(meeting, participants);
  AttributionWriteOutcome saveAutomaticAttribution(
    int transcriptId,
    TranscriptAttribution attribution,
  ) => meetingStore.saveAutomaticAttribution(transcriptId, attribution);
  void setManualAttribution(
    int transcriptId,
    TranscriptAttribution attribution,
  ) => meetingStore.setManualAttribution(transcriptId, attribution);
  bool resetAttribution(int transcriptId) =>
      meetingStore.resetAttribution(transcriptId);
  int renameMeetingParticipant(int participantId, String displayName) =>
      meetingStore.renameParticipant(participantId, displayName);
  void artifact(
    int meeting,
    String kind,
    String generated,
    String model, {
    int? inputRevision,
    String promptVersion = 'meeting-v1',
    Map<String, Object?>? manifest,
  }) => meetingStore.artifact(
    meeting,
    kind,
    generated,
    model,
    inputRevision: inputRevision,
    promptVersion: promptVersion,
    manifest: manifest,
  );
  Map<String, Object?>? summaryCheckpoint(int meeting) =>
      meetingStore.summaryCheckpoint(meeting);
  String saveSummary(
    int meeting,
    String body,
    String model, {
    required int revision,
    required int inputLength,
    required String inputDigest,
    required String identity,
    required Map<String, Object?> manifest,
  }) => meetingStore.saveSummary(
    meeting,
    body,
    model,
    revision: revision,
    inputLength: inputLength,
    inputDigest: inputDigest,
    identity: identity,
    manifest: manifest,
  );
  void editArtifact(int id, String text, {int? lastManualEdit}) =>
      meetingStore.editArtifact(id, text, lastManualEdit: lastManualEdit);
  String meetingEnhancedNotes(int meeting) =>
      meetingQueries.enhancedNotes(meeting);
  void restoreMeetingEnhancedDraft(int meeting, String body) =>
      meetingStore.restoreMeetingEnhancedDraft(meeting, body);
  void saveMeetingEnhancedDraft(int meeting, String body) =>
      meetingStore.saveMeetingEnhancedDraft(meeting, body);

  @override
  String preference(String key, [String fallback = '']) =>
      sourceQueries.preference(key, fallback);
  void setPreference(String key, String value) {
    if (PreferenceEntities(db).write(key, value)) return;
    db.execute(
      'INSERT INTO preferences VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value',
      [key, value],
    );
  }

  void putDocumentLabel(DocumentLabel label) {
    requireSource(label.documentId);
    _labelStore.put(label);
  }

  int autoAssignLabel(
    String name,
    List<Map<String, Object?>> expectedSources,
    Map<String, List<double>> vectors,
  ) =>
      LabelOrganizationService(
        LabelOrganizationStore(db, supportedVersion: schemaVersion),
      ).organize(
        name,
        expectedSources.map(SourceDocument.fromRow).toList(),
        vectors,
      );
  void saveLabelCluster(
    String label, {
    double x = 0,
    double y = 0,
    double radius = 90,
  }) => _labelStore.saveLabelCluster(label, x: x, y: y, radius: radius);

  String graphLabelSet() => _labelStore.graphLabelSet();
  void invalidateGraphOrganization() =>
      _labelStore.invalidateGraphOrganization();
  void acknowledgeGraphLabelRemoval() =>
      _labelStore.acknowledgeGraphLabelRemoval();
  void deleteOrganizationLabel(String name) =>
      _labelStore.deleteOrganizationLabel(name);

  /// Fails unless [id] names a live source. Only a deleted source's
  /// tombstone shows that it existed; [forImport] adds how to create one.
  void requireSource(String id, {bool forImport = false}) =>
      _sourceStore.requireSource(id, forImport: forImport);

  void labels(String id, List<String> labels) {
    requireSource(id);
    _labelStore.replaceNames(id, labels);
  }

  late final _outputStatistics = OutputStatistics(
    db,
    supportedVersion: schemaVersion,
    dataRevision: () => dataRevision,
  );
  int get localOutputWords => _outputStatistics.localOutputWords;
  List<int> weeklyOutputWords(DateTime now, {List<int>? weekStarts}) =>
      _outputStatistics.weeklyOutputWords(now, weekStarts: weekStarts);
  List<int> weeklyAnswerWords(DateTime now) => weeklyOutputWords(now);

  // Typed desktop queries keep SQL and snapshot policy in core.
  List<Map<String, Object?>> registeredEmbedding() => sourceQueries
      .registeredEmbedding()
      .map((row) => Map<String, Object?>.from(row.toRow()))
      .toList();
  List<Map<String, Object?>> sourceById(
    String id, {
    bool includeDeleted = false,
  }) {
    final row = sourceQueries.source(id, includeDeleted: includeDeleted);
    return row == null ? [] : [Map<String, Object?>.from(row.toRow())];
  }

  List<Map<String, Object?>> notes() => sourceQueries
      .notes()
      .map((row) => Map<String, Object?>.from(row.toRow()))
      .toList();
  List<Map<String, Object?>> noteSummaries() => sourceQueries
      .noteSummaries()
      .map((row) => Map<String, Object?>.from(row.toRow()))
      .toList();
  String noteBody(int id) => sourceQueries.noteBody(id);
  List<Map<String, Object?>> completedAnswerBodies() => [
    for (final body in sourceQueries.completedAnswerBodies()) {'body': body},
  ];
  List<Map<String, Object?>> artifactBodies() => [
    for (final body in sourceQueries.artifactBodies()) {'generated': body},
  ];
  List<Map<String, Object?>> googleSourceMimes() => [
    for (final row in sourceQueries.googleSourceMimes().entries)
      {'source_id': row.key, 'mime': row.value},
  ];
  List<Map<String, Object?>> documentClusters() => sourceQueries
      .clusters()
      .map((row) => Map<String, Object?>.from(row.toRow()))
      .toList();
  List<Map<String, Object?>> documentClusterNames() => [
    for (final name in sourceQueries.clusterNames()) {'label': name},
  ];
  MeetingQueries get meetingQueries =>
      MeetingQueries(db, supportedVersion: schemaVersion);
  List<Map<String, Object?>> conversationAnswers(int? meetingId) =>
      meetingQueries
          .conversationAnswers(meetingId)
          .map((row) => Map<String, Object?>.from(row.toRow()))
          .toList();
  List<Map<String, Object?>> meetingCollection() => meetingQueries
      .collection()
      .map((row) => Map<String, Object?>.from(row.toRow()))
      .toList();
  List<Map<String, Object?>> recordedMeetingCountRows() => [
    {'n': meetingQueries.recordedMeetingCount()},
  ];
  List<Map<String, Object?>> completedAnswerCountRows() => [
    {'n': meetingQueries.completedAnswerCount()},
  ];
  List<Map<String, Object?>> completedAnswerHistory() => [
    for (final row in meetingQueries.completedAnswerHistory())
      {'body': row.body, 'created': row.created},
  ];
  List<Map<String, Object?>> meetingNoteRows(int id) => meetingQueries
      .notes(id)
      .map((row) => Map<String, Object?>.from(row.toRow()))
      .toList();
  List<Map<String, Object?>> meetingPreviewRows(int id) => meetingQueries
      .previews(id)
      .map((row) => Map<String, Object?>.from(row.toRow()))
      .toList();
  List<Map<String, Object?>> meetingWorkspaceRows(int id) => meetingQueries
      .workspaces(id)
      .map((row) => Map<String, Object?>.from(row.toRow()))
      .toList();
  List<Map<String, Object?>> enhancedNoteArtifacts(int id) => meetingQueries
      .enhancedNoteArtifacts(id)
      .map((row) => Map<String, Object?>.from(row.toRow()))
      .toList();
  List<Map<String, Object?>> meetingQuestions(int id) => meetingQueries
      .questions(id)
      .map((row) => Map<String, Object?>.from(row.toRow()))
      .toList();
  List<Map<String, Object?>> finalTranscript(int id) => [
    for (final text in meetingQueries.finalTranscriptText(id)) {'text': text},
  ];
  List<Map<String, Object?>> meetingTranscript(int id) => meetingQueries
      .transcript(id)
      .map((row) => Map<String, Object?>.from(row.toRow()))
      .toList();
  List<Map<String, Object?>> meetingArtifacts(int id, String kind) =>
      meetingQueries
          .artifacts(id, kind)
          .map((row) => Map<String, Object?>.from(row.toRow()))
          .toList();
  List<Map<String, Object?>> exportNotes() => meetingQueries
      .exportNotes()
      .map((row) => Map<String, Object?>.from(row.toRow()))
      .toList();
  List<Map<String, Object?>> registeredSpeech() =>
      rows("SELECT digest FROM models WHERE kind='speech'");
  void close() {
    if (_closed) return;
    _closed = true;
    _privacyMaintenanceRetry?.cancel();
    _privacyMaintenanceRetry = null;
    _privacyProbe?.cancel();
    _historyExpiry?.cancel();
    unawaited(_privacyUpdates?.cancel());
    db.dispose();
  }
}
