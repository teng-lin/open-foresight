import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'domain.dart';
import 'google_auth.dart';
import 'store.dart';

class GoogleConnections {
  final Domain domain;
  final GoogleAuth auth;
  bool _closed = false;
  Future<void>? _refreshing;
  bool get syncing => _refreshing != null;
  Store get store => domain.store;

  /// A different account must refresh immediately and cannot inherit a status.
  int get lastCompletedRefreshMs {
    if (!auth.connected ||
        store.preference('googleLastSyncAccount') != auth.account)
      return 0;
    final timestamp =
        int.tryParse(store.preference('googleLastSync', '0')) ?? 0;
    return timestamp > 0 && timestamp <= DateTime.now().millisecondsSinceEpoch
        ? timestamp
        : 0;
  }

  GoogleConnections(this.domain, this.auth) {
    _restoreModificationTimes();
    for (final row in store.rows(
      "SELECT calendar_events.source_id,calendar_events.metadata FROM calendar_events JOIN source_details ON source_details.source_id=calendar_events.source_id WHERE source_details.source_uri=''",
    )) {
      try {
        final metadata = jsonDecode(row['metadata'] as String);
        if (metadata is Map)
          _setSourceUri(row['source_id'] as String, metadata['htmlLink']);
      } on FormatException {
        // Invalid cached metadata cannot recover an original link.
      }
    }
  }

  void _setSourceUri(String source, Object? uri) {
    if (uri is String && uri.isNotEmpty) {
      store.db.execute(
        'UPDATE source_details SET source_uri=? WHERE source_id=?',
        [uri, source],
      );
    }
  }

  static int _modifiedTime(Object? value) => value is String
      ? DateTime.tryParse(value)?.millisecondsSinceEpoch ?? 0
      : 0;

  void _restoreModificationTimes() {
    // Older profiles recorded local import time. Restore cached metadata only
    // for unedited external sources; source content/revisions stay unchanged.
    for (final row in store.rows(
      "SELECT sources.id,google_sources.modified FROM google_sources JOIN sources ON sources.id=google_sources.source_id WHERE sources.deleted=0 AND sources.provenance NOT LIKE 'user edit; %'",
    )) {
      store.db.execute(
        'UPDATE source_details SET changed=? WHERE source_id=?',
        [_modifiedTime(row['modified']), row['id']],
      );
    }
    for (final row in store.rows(
      "SELECT sources.id,calendar_events.metadata FROM calendar_events JOIN sources ON sources.id=calendar_events.source_id WHERE sources.deleted=0 AND sources.provenance NOT LIKE 'user edit; %'",
    )) {
      Object? updated;
      try {
        final metadata = jsonDecode(row['metadata'] as String);
        if (metadata is Map) updated = metadata['updated'];
      } on FormatException {
        // Unknown cached metadata is displayed as unknown rather than now.
      }
      store.db.execute(
        'UPDATE source_details SET changed=? WHERE source_id=?',
        [_modifiedTime(updated), row['id']],
      );
    }
  }

  void _check(String account) {
    if (_closed || !auth.connected || auth.account != account)
      throw StateError('Google connection changed. Retry after signing in.');
  }

  Future<void> _checkpoint(String account) async {
    _check(account);
    await domain.waitForSourceWork();
    _check(account);
  }

  String _id(String kind, String remote) =>
      '$kind-${sha256.convert(utf8.encode('${auth.account}:$remote'))}';
  Uri _drive(String path, [Map<String, String>? query]) =>
      auth.endpoints.drive.resolve(path).replace(queryParameters: query);
  Uri _calendar(String path, [Map<String, String>? query]) =>
      auth.endpoints.calendar.resolve(path).replace(queryParameters: query);
  String _literal(String value) =>
      value.replaceAll('\\', '\\\\').replaceAll("'", "\\'");
  Future<List<Map<String, dynamic>>> driveFiles({
    String? parent,
    String query = '',
    DateTime? modifiedAfter,
  }) async {
    final account = auth.account;
    _check(account);
    final filters = [
      'trashed = false',
      if (parent != null) "'${_literal(parent)}' in parents",
      if (query.trim().isNotEmpty) "name contains '${_literal(query.trim())}'",
      if (modifiedAfter != null)
        "modifiedTime > '${modifiedAfter.toUtc().toIso8601String()}'",
    ];
    final files = <Map<String, dynamic>>[];
    var page = '';
    do {
      final response = await auth.apiJson(
        _drive('files', {
          'q': filters.join(' and '),
          'fields':
              'nextPageToken,files(id,name,mimeType,modifiedTime,parents,size,webViewLink)',
          'pageSize': '1000',
          'orderBy': 'folder,name',
          'supportsAllDrives': 'true',
          'includeItemsFromAllDrives': 'true',
          if (page.isNotEmpty) 'pageToken': page,
        }),
      );
      _check(account);
      files.addAll(
        (response['files'] as List? ?? []).cast<Map<String, dynamic>>(),
      );
      page = response['nextPageToken'] as String? ?? '';
      if (files.length > 10000)
        throw StateError(
          'More than 10,000 files match. Choose a smaller folder or search.',
        );
    } while (page.isNotEmpty);
    return files;
  }

  static bool supported(String mime) =>
      mime.startsWith('text/') ||
      [
        'application/pdf',
        'application/rtf',
        'application/vnd.google-apps.document',
        'application/vnd.google-apps.spreadsheet',
        'application/vnd.google-apps.presentation',
      ].contains(mime);
  Future<void> _publish(
    String id,
    String title,
    String text,
    String mime,
    String provenance, {
    int modifiedAtMs = 0,
    bool preserveDeleted = false,
    String? sourceUri,
  }) async {
    await _checkpoint(auth.account);
    if (text.trim().isEmpty) throw StateError('No readable text in $title.');
    final old = store.rows('SELECT * FROM sources WHERE id=?', [
      id,
    ]).firstOrNull;
    if (preserveDeleted &&
        (old?['deleted'] == 1 ||
            (old?['provenance'] as String? ?? '').startsWith('user edit; ')))
      return;
    final contentChanged =
        old == null ||
        old['deleted'] == 1 ||
        old['content'] != text ||
        old['title'] != title;
    final locallyEdited = (old?['provenance'] as String? ?? '').startsWith(
      'user edit; ',
    );
    if (contentChanged)
      store.importText(
        title,
        text,
        mime,
        provenance,
        id: id,
        modifiedAtMs: modifiedAtMs,
        sourceUri: sourceUri,
      );
    _setSourceUri(id, sourceUri);
    if (contentChanged || !locallyEdited)
      store.db.execute(
        'UPDATE source_details SET changed=? WHERE source_id=?',
        [modifiedAtMs, id],
      );
    if (contentChanged || old['state'] != 'indexed') await domain.index(id);
  }

  Future<void> importDriveFile(
    String fileId, {
    Map<String, dynamic>? metadata,
    bool preserveDeleted = false,
  }) async {
    final account = auth.account;
    await _checkpoint(account);
    final file =
        metadata ??
        await auth.apiJson(
          _drive('files/${Uri.encodeComponent(fileId)}', {
            'fields': 'id,name,mimeType,modifiedTime,trashed,webViewLink',
            'supportsAllDrives': 'true',
          }),
        );
    _check(account);
    if (file['trashed'] == true)
      throw StateError('${file['name'] ?? 'File'} is in the Drive trash.');
    final mime = file['mimeType'] as String, name = file['name'] as String;
    if (!supported(mime))
      throw StateError('$name uses an unsupported file type ($mime).');
    final native = mime.startsWith('application/vnd.google-apps.');
    final export = mime == 'application/vnd.google-apps.spreadsheet'
        ? 'text/csv'
        : 'text/plain';
    final response = await auth.api(
      _drive(
        'files/${Uri.encodeComponent(fileId)}${native ? '/export' : ''}',
        native
            ? {'mimeType': export}
            : {'alt': 'media', 'supportsAllDrives': 'true'},
      ),
    );
    _check(account);
    String text;
    if (mime == 'application/pdf' || mime == 'application/rtf') {
      final cache = Directory('${auth.directory.path}/downloads');
      await cache.create(recursive: true);
      await Process.run('chmod', ['700', cache.path]);
      final path =
          '${cache.path}/${sha256.convert(utf8.encode(fileId))}-${DateTime.now().microsecondsSinceEpoch}.${mime == 'application/pdf' ? 'pdf' : 'rtf'}';
      final downloaded = File(path);
      try {
        await downloaded.writeAsBytes(response.bytes);
        text = (await Parser().extract(path)).$1;
      } finally {
        if (downloaded.existsSync()) await downloaded.delete();
      }
    } else {
      text = utf8.decode(response.bytes);
    }
    _check(account);
    final id = _id('google-drive', fileId);
    await _publish(
      id,
      name,
      text,
      native ? export : mime,
      'google-drive:$account:$fileId',
      modifiedAtMs: _modifiedTime(file['modifiedTime']),
      preserveDeleted: preserveDeleted,
      sourceUri: file['webViewLink'] as String?,
    );
    _check(account);
    store.db.execute(
      'INSERT INTO google_sources VALUES(?,?,?,?,?) ON CONFLICT(source_id) DO UPDATE SET modified=excluded.modified,mime=excluded.mime',
      [id, account, fileId, file['modifiedTime'] as String? ?? '', mime],
    );
  }

  Future<void> importDriveFolder(
    String folderId, {
    bool refreshing = false,
  }) async {
    final account = auth.account;
    _check(account);
    final seen = <String>{}, queue = [folderId], failures = <String>[];
    final examined = <String>{};
    var count = 0;
    while (queue.isNotEmpty) {
      await _checkpoint(account);
      final folder = queue.removeLast();
      if (!seen.add(folder)) continue;
      final files = await driveFiles(parent: folder);
      _check(account);
      // Keep the selected root subscribed even if an individual export fails.
      if (folder == folderId)
        store.db.execute('INSERT OR IGNORE INTO google_folders VALUES(?,?)', [
          account,
          folderId,
        ]);
      for (final file in files) {
        if (file['mimeType'] == 'application/vnd.google-apps.folder') {
          queue.add(file['id'] as String);
        } else if (supported(file['mimeType'] as String)) {
          if (!examined.add(file['id'] as String)) continue;
          if (examined.length > 10000)
            throw StateError('Choose a smaller Drive folder.');
          final existing = store.rows(
            'SELECT sources.*,google_sources.modified FROM sources JOIN google_sources ON google_sources.source_id=sources.id WHERE google_sources.account=? AND google_sources.file_id=?',
            [account, file['id']],
          ).firstOrNull;
          // A user deletion stays deleted during automatic folder refresh.
          if (refreshing && existing?['deleted'] == 1) continue;
          if (existing != null)
            _setSourceUri(existing['id'] as String, file['webViewLink']);
          if (existing?['state'] == 'indexed' &&
              existing?['deleted'] == 0 &&
              existing?['modified'] == file['modifiedTime'] &&
              existing?['title'] == file['name'])
            continue;
          try {
            await importDriveFile(
              file['id'] as String,
              metadata: file,
              preserveDeleted: refreshing,
            );
            count++;
          } catch (error) {
            failures.add('${file['name']}: $error');
          }
        }
      }
      if (seen.length > 1000 || count > 10000)
        throw StateError('Choose a smaller Drive folder.');
    }
    if (failures.isNotEmpty)
      throw StateError('Imported $count files; ${failures.join('\n')}');
  }

  Future<void> importLastYear() async {
    final files = await driveFiles(
      modifiedAfter: DateTime.now().subtract(const Duration(days: 365)),
    );
    final failures = <String>[];
    for (final file in files.where(
      (row) => supported(row['mimeType'] as String),
    )) {
      try {
        await importDriveFile(file['id'] as String, metadata: file);
      } catch (error) {
        failures.add('${file['name']}: $error');
      }
    }
    if (failures.isNotEmpty) throw StateError(failures.join('\n'));
  }

  static DateTime? eventTime(Object? value) {
    if (value is! Map) return null;
    return DateTime.tryParse(
      (value['dateTime'] ?? value['date'])?.toString() ?? '',
    );
  }

  Future<void> syncCalendar({
    String calendarId = 'primary',
    DateTime? now,
  }) async {
    final account = auth.account;
    _check(account);
    now ??= DateTime.now();
    var page = '';
    do {
      final response = await auth.apiJson(
        _calendar('calendars/${Uri.encodeComponent(calendarId)}/events', {
          'timeMin': now
              .subtract(const Duration(days: 30))
              .toUtc()
              .toIso8601String(),
          'timeMax': now
              .add(const Duration(days: 90))
              .toUtc()
              .toIso8601String(),
          'singleEvents': 'true',
          'showDeleted': 'true',
          'orderBy': 'startTime',
          'maxResults': '2500',
          if (page.isNotEmpty) 'pageToken': page,
        }),
      );
      _check(account);
      for (final event
          in (response['items'] as List? ?? []).cast<Map<String, dynamic>>()) {
        final key = _id('google-calendar', '$calendarId:${event['id']}');
        final old = store.rows(
          'SELECT * FROM calendar_events WHERE event_key=?',
          [key],
        ).firstOrNull;
        final cancelled = event['status'] == 'cancelled';
        if (cancelled) {
          if (old != null) {
            store.db.execute(
              "UPDATE calendar_events SET status='cancelled',synced=? WHERE event_key=?",
              [DateTime.now().millisecondsSinceEpoch, key],
            );
            if (store.rows('SELECT id FROM sources WHERE id=? AND deleted=0', [
              key,
            ]).isNotEmpty)
              await domain.delete(key);
          }
          continue;
        }
        final start = eventTime(event['start']), end = eventTime(event['end']);
        if (start == null || end == null) continue;
        final title = event['summary'] as String? ?? '[Untitled meeting]';
        final meeting = old?['meeting_id'] as int? ?? store.meeting(title);
        if (old != null && old['starts'] != start.millisecondsSinceEpoch)
          store.db.execute(
            'UPDATE meeting_details SET reminder=0 WHERE meeting_id=?',
            [meeting],
          );
        store.db.execute('UPDATE meetings SET title=? WHERE id=?', [
          title,
          meeting,
        ]);
        store.db.execute(
          'INSERT INTO calendar_events VALUES(?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(event_key) DO UPDATE SET starts=excluded.starts,ends=excluded.ends,status=excluded.status,metadata=excluded.metadata,synced=excluded.synced',
          [
            key,
            account,
            calendarId,
            event['id'],
            meeting,
            key,
            start.millisecondsSinceEpoch,
            end.millisecondsSinceEpoch,
            event['status'] as String? ?? 'confirmed',
            jsonEncode(event),
            DateTime.now().millisecondsSinceEpoch,
          ],
        );
        final weekday = [
          'Monday',
          'Tuesday',
          'Wednesday',
          'Thursday',
          'Friday',
          'Saturday',
          'Sunday',
        ][start.toLocal().weekday - 1];
        final description = (event['description'] as String? ?? '').replaceAll(
          RegExp(r'<[^>]+>'),
          ' ',
        );
        final attendees = (event['attendees'] as List? ?? [])
            .map((row) => (row as Map)['displayName'] ?? row['email'])
            .whereType<String>()
            .join(', ');
        final text =
            '$title\nStarts: $weekday ${start.toLocal().toIso8601String()}\nEnds: ${end.toLocal().toIso8601String()}\n$description\n${attendees.isEmpty ? '' : 'Participants: $attendees'}';
        await _publish(
          key,
          '[Calendar] $title',
          text,
          'text/plain',
          'google-calendar:$account:$calendarId:${event['id']}',
          modifiedAtMs: _modifiedTime(event['updated']),
          sourceUri: event['htmlLink'] as String?,
        );
        _check(account);
      }
      page = response['nextPageToken'] as String? ?? '';
    } while (page.isNotEmpty);
    store.setPreference(
      'googleCalendarLastSync',
      DateTime.now().millisecondsSinceEpoch.toString(),
    );
  }

  Future<void> refresh() =>
      _refreshing ??= _refresh().whenComplete(() => _refreshing = null);
  Future<void> _refresh() async {
    final account = auth.account;
    _check(account);
    final failures = <String>[];
    for (final source in store.rows(
      'SELECT google_sources.*,sources.revision AS source_revision FROM google_sources JOIN sources ON sources.id=google_sources.source_id WHERE account=? AND deleted=0',
      [account],
    )) {
      try {
        await _checkpoint(account);
        if (store.rows('SELECT id FROM sources WHERE id=? AND deleted=0', [
          source['source_id'],
        ]).isEmpty)
          continue;
        final file = await auth.apiJson(
          _drive('files/${Uri.encodeComponent(source['file_id'] as String)}', {
            'fields': 'id,name,mimeType,modifiedTime,trashed,webViewLink',
            'supportsAllDrives': 'true',
          }),
        );
        _check(account);
        if (store.rows(
          "SELECT id FROM sources WHERE id=? AND revision=? AND deleted=0 AND provenance NOT LIKE 'user edit; %'",
          [source['source_id'], source['source_revision']],
        ).isEmpty)
          continue;
        _setSourceUri(source['source_id'] as String, file['webViewLink']);
        if (file['trashed'] == true) {
          await domain.delete(source['source_id'] as String);
        } else if (file['modifiedTime'] != source['modified']) {
          await importDriveFile(
            source['file_id'] as String,
            metadata: file,
            preserveDeleted: true,
          );
        }
      } catch (error) {
        failures.add('Drive refresh: $error');
      }
    }
    for (final folder in store.rows(
      'SELECT folder_id FROM google_folders WHERE account=?',
      [account],
    )) {
      try {
        await importDriveFolder(
          folder['folder_id'] as String,
          refreshing: true,
        );
      } catch (error) {
        failures.add('Drive folder refresh: $error');
      }
    }
    try {
      await syncCalendar();
    } catch (error) {
      failures.add('Calendar refresh: $error');
    }
    _check(account);
    if (failures.isNotEmpty) throw StateError(failures.join('\n'));
    store.setPreference(
      'googleLastSync',
      DateTime.now().millisecondsSinceEpoch.toString(),
    );
    store.setPreference('googleLastSyncAccount', account);
  }

  List<Map<String, dynamic>> attachments(int meeting) {
    final row = store.rows(
      'SELECT metadata FROM calendar_events WHERE meeting_id=?',
      [meeting],
    ).firstOrNull;
    if (row == null) return [];
    return ((jsonDecode(row['metadata'] as String) as Map)['attachments']
                as List? ??
            [])
        .cast<Map<String, dynamic>>();
  }

  Future<void> importAttachments(int meeting) async {
    final failures = <String>[];
    for (final attachment in attachments(meeting)) {
      final id = attachment['fileId'] as String?;
      if (id == null) {
        failures.add('${attachment['title']}: no Drive file identifier');
        continue;
      }
      try {
        await importDriveFile(id);
      } catch (error) {
        failures.add('${attachment['title']}: $error');
      }
    }
    if (failures.isNotEmpty) throw StateError(failures.join('\n'));
  }

  Future<void> reminders(
    DateTime now,
    Future<void> Function(String) deliver,
  ) async {
    if (!auth.connected || store.preference('googleReminders') != 'true')
      return;
    final account = auth.account;
    _check(account);
    final events = store.rows(
      "SELECT calendar_events.*,meeting_details.reminder FROM calendar_events JOIN meeting_details ON meeting_details.meeting_id=calendar_events.meeting_id WHERE account=? AND status!='cancelled' AND starts>? AND starts<=? AND reminder=0",
      [
        account,
        now.millisecondsSinceEpoch,
        now.add(const Duration(minutes: 5)).millisecondsSinceEpoch,
      ],
    );
    for (final row in events) {
      _check(account);
      final event = jsonDecode(row['metadata'] as String) as Map;
      if ((event['start'] as Map)['date'] != null) continue;
      await deliver(
        'Upcoming meeting: ${event['summary'] ?? 'Untitled meeting'}',
      );
      _check(account);
      store.db.execute(
        'UPDATE meeting_details SET reminder=1 WHERE meeting_id=?',
        [row['meeting_id']],
      );
    }
  }

  void close() {
    _closed = true;
  }
}
