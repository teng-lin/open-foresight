import 'dart:convert';
import '../desktop_read_models.dart';
import '../google_calendar_event.dart';
import '../store.dart';
import 'read_schema_guard.dart';

typedef GoogleDriveSource = ({SourceDocument source, String modified});
typedef GoogleRefreshSource = ({
  String id,
  String fileId,
  String modified,
  int revision,
});
typedef GoogleReminder = ({int meeting, String metadata});

/// Named Google persistence operations on the existing workspace connection.
class GoogleConnectionQueries {
  final Store _store;
  GoogleConnectionQueries(this._store);
  T _read<T>(T Function() read) =>
      readSnapshot(_store.db, read, supportedVersion: Store.schemaVersion);

  int lastCompletedRefreshMs(String? account) {
    if (account == null ||
        _store.preference('googleLastSyncAccount') != account) {
      return 0;
    }
    final timestamp =
        int.tryParse(_store.preference('googleLastSync', '0')) ?? 0;
    return timestamp > 0 && timestamp <= DateTime.now().millisecondsSinceEpoch
        ? timestamp
        : 0;
  }

  SourceDocument? source(String id) => _read(() {
    final row = _store.rows('SELECT * FROM sources WHERE id=?', [
      id,
    ]).firstOrNull;
    return row == null ? null : SourceDocument.fromRow(row);
  });

  void setSourceUri(String source, Object? uri) {
    if (uri is String && uri.isNotEmpty) {
      _store.db.execute(
        'UPDATE source_details SET source_uri=? WHERE source_id=?',
        [uri, source],
      );
    }
  }

  void setSourceModified(String id, int modified) => _store.db.execute(
    'UPDATE source_details SET changed=? WHERE source_id=?',
    [modified, id],
  );
  void recordDriveSource(
    String id,
    String account,
    String fileId,
    String modified,
    String mime,
  ) => _store.db.execute(
    'INSERT INTO google_sources VALUES(?,?,?,?,?) ON CONFLICT(source_id) DO UPDATE SET modified=excluded.modified,mime=excluded.mime',
    [id, account, fileId, modified, mime],
  );
  void subscribeFolder(String account, String folder) => _store.db.execute(
    'INSERT OR IGNORE INTO google_folders VALUES(?,?)',
    [account, folder],
  );
  GoogleDriveSource? driveSource(String account, String fileId) => _read(() {
    final row = _store.rows(
      'SELECT sources.*,google_sources.modified FROM sources JOIN google_sources ON google_sources.source_id=sources.id WHERE google_sources.account=? AND google_sources.file_id=?',
      [account, fileId],
    ).firstOrNull;
    return row == null
        ? null
        : (
            source: SourceDocument.fromRow(row),
            modified: row['modified'] as String,
          );
  });
  List<GoogleRefreshSource> refreshSources(String account) => _read(
    () => _store
        .rows(
          'SELECT google_sources.*,sources.revision AS source_revision FROM google_sources JOIN sources ON sources.id=google_sources.source_id WHERE account=? AND deleted=0',
          [account],
        )
        .map(
          (row) => (
            id: row['source_id'] as String,
            fileId: row['file_id'] as String,
            modified: row['modified'] as String,
            revision: row['source_revision'] as int,
          ),
        )
        .toList(),
  );
  bool sourceExists(String id) => _read(
    () => _store.rows('SELECT id FROM sources WHERE id=? AND deleted=0', [
      id,
    ]).isNotEmpty,
  );
  bool refreshStillCurrent(String id, int revision) => _read(
    () => _store.rows(
      "SELECT id FROM sources WHERE id=? AND revision=? AND deleted=0 AND locally_edited=0 AND provenance NOT LIKE 'user edit; %'",
      [id, revision],
    ).isNotEmpty,
  );
  List<String> folders(String account) => _read(
    () => _store
        .rows('SELECT folder_id FROM google_folders WHERE account=?', [account])
        .map((row) => row['folder_id'] as String)
        .toList(),
  );

  void storeCalendarEvent(GoogleCalendarUpdate event) {
    final old = _read(
      () => _store.rows('SELECT * FROM calendar_events WHERE event_key=?', [
        event.key,
      ]).firstOrNull,
    );
    if (event.status == 'cancelled') {
      if (old != null) _cancelEvent(event.key);
      return;
    }
    if (event.starts == null || event.ends == null) return;
    final meeting = old?['meeting_id'] as int? ?? _store.meeting(event.title);
    if (old != null && old['starts'] != event.starts) {
      _store.db.execute(
        'UPDATE meeting_details SET reminder=0 WHERE meeting_id=?',
        [meeting],
      );
    }
    _store.db.execute('UPDATE meetings SET title=? WHERE id=?', [
      event.title,
      meeting,
    ]);
    _store.db.execute(
      'INSERT INTO calendar_events VALUES(?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(event_key) DO UPDATE SET starts=excluded.starts,ends=excluded.ends,status=excluded.status,metadata=excluded.metadata,synced=excluded.synced',
      [
        event.key,
        event.account,
        event.calendar,
        event.eventId,
        meeting,
        '',
        event.starts,
        event.ends,
        event.status,
        event.metadata,
        DateTime.now().millisecondsSinceEpoch,
      ],
    );
  }

  void _cancelEvent(String key) => _store.db.execute(
    "UPDATE calendar_events SET status='cancelled',synced=? WHERE event_key=?",
    [DateTime.now().millisecondsSinceEpoch, key],
  );

  /// Snapshot cancellation and the completion watermark commit atomically.
  void replaceCalendarSnapshot(
    String account,
    List<GoogleCalendarUpdate> events,
    Set<String> keys,
    void Function() ensureCurrent,
  ) {
    _store.db.execute('BEGIN');
    try {
      for (final event in events) {
        storeCalendarEvent(event);
        if (event.status != 'cancelled' &&
            event.starts != null &&
            event.ends != null) {
          ensureCurrent();
        }
      }
      final existing = _read(
        () => _store
            .rows(
              "SELECT event_key FROM calendar_events WHERE account=? AND event_key LIKE 'google-calendar-%'",
              [account],
            )
            .map((row) => row['event_key'] as String)
            .toList(),
      );
      for (final key in existing) {
        if (!keys.contains(key)) _cancelEvent(key);
      }
      ensureCurrent();
      _store.setPreference(
        'googleCalendarLastSync',
        DateTime.now().millisecondsSinceEpoch.toString(),
      );
      _store.db.execute('COMMIT');
    } catch (_) {
      _store.db.execute('ROLLBACK');
      rethrow;
    }
  }

  List<Map<String, dynamic>> attachments(int meeting) => _read(() {
    final row = _store.rows(
      'SELECT metadata FROM calendar_events WHERE meeting_id=?',
      [meeting],
    ).firstOrNull;
    if (row == null) return [];
    return ((jsonDecode(row['metadata'] as String) as Map)['attachments']
                as List? ??
            [])
        .cast<Map<String, dynamic>>();
  });
  List<GoogleReminder> reminders(String account, DateTime now) => _read(
    () => _store
        .rows(
          "SELECT calendar_events.*,meeting_details.reminder FROM calendar_events JOIN meeting_details ON meeting_details.meeting_id=calendar_events.meeting_id WHERE account=? AND status!='cancelled' AND starts>? AND starts<=? AND reminder=0",
          [
            account,
            now.millisecondsSinceEpoch,
            now.add(const Duration(minutes: 5)).millisecondsSinceEpoch,
          ],
        )
        .map(
          (row) => (
            meeting: row['meeting_id'] as int,
            metadata: row['metadata'] as String,
          ),
        )
        .toList(),
  );
  void markReminderDelivered(int meeting) => _store.db.execute(
    'UPDATE meeting_details SET reminder=1 WHERE meeting_id=?',
    [meeting],
  );
}
