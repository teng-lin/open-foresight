import 'rpc_error.dart';
import 'desktop_connection.dart';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'application_services/service_workspace_ports.dart';
import 'google_auth.dart';
import 'store.dart' hide Parser;
import 'document_parser.dart';
import 'persistence/google_connection_queries.dart';
import 'google_calendar_event.dart';
import 'desktop_google_sources.dart';
export 'google_calendar_event.dart' show calendarDescriptionText;

class GoogleConnections implements ConnectedSources {
  final SourceIndexPort domain;
  final GoogleAuth auth;
  bool _closed = false;
  Future<void>? _refreshing;
  bool get syncing => _refreshing != null;
  Store get store => domain.store;
  late final _queries = GoogleConnectionQueries(store);

  /// A different account must refresh immediately and cannot inherit a status.
  @override
  int get lastCompletedRefreshMs =>
      _queries.lastCompletedRefreshMs(auth.connected ? auth.account : null);

  GoogleConnections(this.domain, this.auth);

  static int _modifiedTime(Object? value) => value is String
      ? DateTime.tryParse(value)?.millisecondsSinceEpoch ?? 0
      : 0;

  void _check(String account) {
    if (_closed || !auth.connected || auth.account != account) {
      throw RpcError(
        RpcErrorCode.cancelled,
        'Google connection changed. Retry after signing in.',
      );
    }
  }

  void _requireDrive() {
    if (auth.viaGranola) {
      throw StateError(
        'Drive is unavailable through the Granola calendar connection.',
      );
    }
  }

  Future<void> _checkpoint(String account, {bool Function()? current}) async {
    _check(account);
    await domain.waitForSourceWork(current: current);
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
  @override
  Future<List<Map<String, dynamic>>> driveFiles({
    String? parent,
    String query = '',
    DateTime? modifiedAfter,
  }) async {
    final account = auth.account;
    _check(account);
    _requireDrive();
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
              'nextPageToken,files(id,name,mimeType,modifiedTime,parents,size,webViewLink,capabilities(canDownload))',
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
      if (files.length > 10000) {
        throw StateError(
          'More than 10,000 files match. Choose a smaller folder or search.',
        );
      }
    } while (page.isNotEmpty);
    return files;
  }

  static bool supported(String mime) => supportsGoogleDriveMime(mime);
  static bool canDownload(Map<String, dynamic> file) =>
      canDownloadGoogleDriveFile(file);

  Future<void> _publish(
    String id,
    String title,
    String text,
    String mime,
    String provenance, {
    int modifiedAtMs = 0,
    bool preserveDeleted = false,
    bool Function()? current,
    String? sourceUri,
  }) async {
    await _checkpoint(auth.account, current: current);
    if (text.trim().isEmpty) throw StateError('No readable text in $title.');
    final old = _queries.source(id);
    if (preserveDeleted &&
        (old?.deleted == true ||
            (old?.locallyEdited == true ||
                (old?.provenance ?? '').startsWith('user edit; ')))) {
      return;
    }
    final contentChanged =
        old == null || old.deleted || old.content != text || old.title != title;
    final locallyEdited =
        old?.locallyEdited == true ||
        (old?.provenance ?? '').startsWith('user edit; ');
    if (contentChanged) {
      store.importText(
        title,
        text,
        mime,
        provenance,
        id: id,
        modifiedAtMs: modifiedAtMs,
        sourceUri: sourceUri,
      );
    }
    _queries.setSourceUri(id, sourceUri);
    if (contentChanged || !locallyEdited) {
      _queries.setSourceModified(id, modifiedAtMs);
    }
    if (contentChanged || old.state != 'indexed') {
      await domain.index(id, current: current);
    }
  }

  @override
  Future<void> importDriveFile(
    String fileId, {
    Map<String, dynamic>? metadata,
    bool preserveDeleted = false,
    bool Function()? current,
  }) async {
    final account = auth.account;
    await _checkpoint(account, current: current);
    final file =
        metadata ??
        await auth.apiJson(
          _drive('files/${Uri.encodeComponent(fileId)}', {
            'fields':
                'id,name,mimeType,modifiedTime,trashed,webViewLink,capabilities(canDownload)',
            'supportsAllDrives': 'true',
          }),
        );
    _check(account);
    if (file['trashed'] == true) {
      throw StateError('${file['name'] ?? 'File'} is in the Drive trash.');
    }
    final mime = file['mimeType'] as String, name = file['name'] as String;
    if (!supported(mime)) {
      throw StateError('$name uses an unsupported file type ($mime).');
    }
    if (!canDownload(file)) {
      throw StateError(
        '$name: Google Drive does not allow downloading this file.',
      );
    }
    final native = mime.startsWith('application/vnd.google-apps.');
    final export = mime == 'application/vnd.google-apps.spreadsheet'
        ? 'text/csv'
        : 'text/plain';
    late final Uint8ListResponse response;
    try {
      response = await auth.api(
        _drive(
          'files/${Uri.encodeComponent(fileId)}${native ? '/export' : ''}',
          native
              ? {'mimeType': export}
              : {'alt': 'media', 'supportsAllDrives': 'true'},
        ),
      );
    } on RpcError catch (error) {
      // Preserve the filename and internal-error contract when RpcError no
      // longer inherits StateError.
      throw StateError('$name: ${error.message}');
    } on StateError catch (error) {
      throw StateError('$name: ${error.message}');
    }
    _check(account);
    String text;
    if (mime == 'application/pdf' || mime == 'application/rtf') {
      final cache = Directory('${auth.directory.path}/downloads');
      await cache.create(recursive: true);
      final protection = await Process.run('/bin/chmod', ['700', cache.path]);
      if (protection.exitCode != 0) {
        throw StateError('Cannot protect Google import cache');
      }
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
      current: current,
      sourceUri: file['webViewLink'] as String?,
    );
    _check(account);
    _queries.recordDriveSource(
      id,
      account,
      fileId,
      file['modifiedTime'] as String? ?? '',
      mime,
    );
  }

  @override
  Future<void> importDriveFolder(
    String folderId, {
    bool refreshing = false,
    bool Function()? current,
  }) async {
    final account = auth.account;
    _check(account);
    final seen = <String>{}, queue = [folderId], failures = <String>[];
    final examined = <String>{};
    var count = 0;
    while (queue.isNotEmpty) {
      await _checkpoint(account, current: current);
      final folder = queue.removeLast();
      if (!seen.add(folder)) continue;
      final files = await driveFiles(parent: folder);
      _check(account);
      // Keep the selected root subscribed even if an individual export fails.
      if (folder == folderId) {
        _queries.subscribeFolder(account, folderId);
      }
      for (final file in files) {
        if (file['mimeType'] == 'application/vnd.google-apps.folder') {
          queue.add(file['id'] as String);
        } else if (supported(file['mimeType'] as String)) {
          if (!examined.add(file['id'] as String)) continue;
          if (examined.length > 10000) {
            throw StateError('Choose a smaller Drive folder.');
          }
          final existing = _queries.driveSource(account, file['id'] as String);
          // A user deletion stays deleted during automatic folder refresh.
          if (refreshing && existing?.source.deleted == true) continue;
          if (existing != null) {
            _queries.setSourceUri(existing.source.id, file['webViewLink']);
          }
          if (existing?.source.state == 'indexed' &&
              existing?.source.deleted == false &&
              existing?.modified == file['modifiedTime'] &&
              existing?.source.title == file['name']) {
            continue;
          }
          try {
            await importDriveFile(
              file['id'] as String,
              metadata: file,
              preserveDeleted: refreshing,
              current: current,
            );
            count++;
          } catch (error) {
            if (current != null && !current()) {
              throw RpcError(RpcErrorCode.cancelled, 'Operation cancelled');
            }
            failures.add(googleImportFailure('${file['name']}', error));
          }
        }
      }
      if (seen.length > 1000 || count > 10000) {
        throw StateError('Choose a smaller Drive folder.');
      }
    }
    if (failures.isNotEmpty) {
      throw StateError('Imported $count files; ${failures.join('\n')}');
    }
  }

  @override
  Future<void> importLastYear({bool Function()? current}) async {
    final files = await driveFiles(
      modifiedAfter: DateTime.now().subtract(const Duration(days: 365)),
    );
    final failures = <String>[];
    for (final file in files.where(
      (row) => supported(row['mimeType'] as String),
    )) {
      try {
        await importDriveFile(
          file['id'] as String,
          metadata: file,
          current: current,
        );
      } catch (error) {
        if (current != null && !current()) {
          throw RpcError(RpcErrorCode.cancelled, 'Operation cancelled');
        }
        failures.add(googleImportFailure('${file['name']}', error));
      }
    }
    if (failures.isNotEmpty) throw StateError(failures.join('\n'));
  }

  static DateTime? eventTime(Object? value) => googleCalendarEventTime(value);

  GoogleCalendarUpdate _calendarUpdate(
    String account,
    String calendarId,
    Map<String, dynamic> event,
  ) => GoogleCalendarUpdate.fromEvent(
    _id('google-calendar', '$calendarId:${event['id']}'),
    account,
    calendarId,
    event,
  );

  void _storeCalendarEvent(
    String account,
    String calendarId,
    Map<String, dynamic> event,
  ) {
    final update = _calendarUpdate(account, calendarId, event);
    _queries.storeCalendarEvent(update);
    if (update.status != 'cancelled' &&
        update.starts != null &&
        update.ends != null) {
      _check(account);
    }
  }

  @override
  Future<void> syncCalendar({
    String calendarId = 'primary',
    DateTime? now,
    bool preserveLocal = false,
  }) async {
    final account = auth.account;
    _check(account);
    if (auth.viaGranola) {
      await _syncGranolaCalendar(account);
      return;
    }
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
        _storeCalendarEvent(account, calendarId, event);
      }
      page = response['nextPageToken'] as String? ?? '';
    } while (page.isNotEmpty);
    store.setPreference(
      'googleCalendarLastSync',
      DateTime.now().millisecondsSinceEpoch.toString(),
    );
  }

  Future<void> _syncGranolaCalendar(String account) async {
    final response = await auth.granolaCalendarEvents();
    _check(account);
    final results = response['results'];
    if (results is! Map || results['events'] is! List) {
      throw StateError('Granola did not return a calendar snapshot.');
    }
    if (results['error'] != null && results['error'] != false) {
      throw StateError(
        'Granola could not refresh Calendar. Check Google Calendar access in Granola and retry.',
      );
    }
    final events = <(String, Map<String, dynamic>)>[];
    final keys = <String>{};
    // Validate the entire snapshot before marking any missing events cancelled.
    for (final raw in results['events'] as List) {
      if (raw is! Map || raw['id'] is! String || raw['calendarId'] is! String) {
        throw StateError('Granola returned an invalid calendar event.');
      }
      final event = Map<String, dynamic>.from(raw);
      final calendar = event['calendarId'] as String;
      if (event['status'] == 'cancelled' ||
          (event['attendees'] as List? ?? []).any(
            (a) =>
                a is Map &&
                a['self'] == true &&
                a['responseStatus'] == 'declined',
          )) {
        continue;
      }
      if (eventTime(event['start']) == null ||
          eventTime(event['end']) == null ||
          event['summary'] is! String) {
        continue;
      }
      keys.add(_id('google-calendar', '$calendar:${event['id']}'));
      events.add((calendar, event));
    }
    _queries.replaceCalendarSnapshot(
      account,
      [
        for (final (calendar, event) in events)
          _calendarUpdate(account, calendar, event),
      ],
      keys,
      () => _check(account),
    );
  }

  @override
  Future<void> refresh({bool Function()? current}) {
    final shared = _refreshing ??= _refresh().whenComplete(
      () => _refreshing = null,
    );
    return domain.awaitCurrent(shared, current);
  }

  Future<void> _refresh() async {
    final account = auth.account;
    _check(account);
    final failures = <String>[];
    if (auth.viaGranola) {
      await syncCalendar(preserveLocal: true);
      store.setPreference(
        'googleLastSync',
        DateTime.now().millisecondsSinceEpoch.toString(),
      );
      store.setPreference('googleLastSyncAccount', account);
      return;
    }
    for (final source in _queries.refreshSources(account)) {
      try {
        await _checkpoint(account);
        if (!_queries.sourceExists(source.id)) {
          continue;
        }
        final file = await auth.apiJson(
          _drive('files/${Uri.encodeComponent(source.fileId)}', {
            'fields':
                'id,name,mimeType,modifiedTime,trashed,webViewLink,capabilities(canDownload)',
            'supportsAllDrives': 'true',
          }),
        );
        _check(account);
        if (!_queries.refreshStillCurrent(source.id, source.revision)) {
          continue;
        }
        _queries.setSourceUri(source.id, file['webViewLink']);
        if (file['trashed'] == true) {
          await domain.delete(source.id);
        } else if (file['modifiedTime'] != source.modified) {
          await importDriveFile(
            source.fileId,
            metadata: file,
            preserveDeleted: true,
          );
        }
      } catch (error) {
        failures.add('Drive refresh: $error');
      }
    }
    for (final folder in _queries.folders(account)) {
      try {
        await importDriveFolder(folder, refreshing: true);
      } catch (error) {
        failures.add('Drive folder refresh: $error');
      }
    }
    try {
      await syncCalendar(preserveLocal: true);
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

  List<Map<String, dynamic>> _attachments(int meeting) =>
      _queries.attachments(meeting);

  @override
  Future<void> importAttachments(
    int meeting, {
    bool Function()? current,
  }) async {
    final failures = <String>[];
    for (final attachment in _attachments(meeting)) {
      final id = attachment['fileId'] as String?;
      if (id == null) {
        failures.add('${attachment['title']}: no Drive file identifier');
        continue;
      }
      try {
        await importDriveFile(id, current: current);
      } catch (error) {
        if (current != null && !current()) {
          throw RpcError(RpcErrorCode.cancelled, 'Operation cancelled');
        }
        failures.add(googleImportFailure('${attachment['title']}', error));
      }
    }
    if (failures.isNotEmpty) throw StateError(failures.join('\n'));
  }

  Future<void> reminders(
    DateTime now,
    Future<void> Function(String) deliver,
  ) async {
    if (!auth.connected || store.preference('googleReminders') != 'true') {
      return;
    }
    final account = auth.account;
    _check(account);
    final events = _queries.reminders(account, now);
    for (final row in events) {
      _check(account);
      final event = jsonDecode(row.metadata) as Map;
      if ((event['start'] as Map)['date'] != null) continue;
      await deliver(
        'Upcoming meeting: ${event['summary'] ?? 'Untitled meeting'}',
      );
      _check(account);
      _queries.markReminderDelivered(row.meeting);
    }
  }

  void close() {
    _closed = true;
  }
}
