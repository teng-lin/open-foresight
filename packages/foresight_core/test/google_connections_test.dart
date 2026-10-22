import 'package:foresight_test_support/test_paths.dart';
import 'package:foresight_core/src/rpc_error.dart';
import 'package:foresight_core/src/application.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:foresight_core/src/google_auth.dart';
import 'package:foresight_core/src/google_connections.dart';
import 'package:foresight_core/src/helper.dart';
import 'package:foresight_core/src/store.dart';

import 'package:foresight_test_support/google_connections.dart';

class FailingImportDomain extends AdapterDomain {
  FailingImportDomain(super.store, super.helper);
  bool rejectIndex = false;
  @override
  Future<void> index(String id, {bool Function()? current}) async {
    if (rejectIndex) throw StateError('Indexing unavailable');
    await super.index(id);
  }
}

class RpcFailingExportAuth extends GoogleAuth {
  RpcFailingExportAuth(super.directory, {required super.endpoints})
    : super(secretStore: const UnavailableSecretStore());

  @override
  Future<Uint8ListResponse> api(
    Uri uri, {
    int maximumBytes = 32 * 1024 * 1024,
  }) {
    if (uri.path.endsWith('/export')) {
      throw RpcError(RpcErrorCode.unavailable, 'fixture export unavailable');
    }
    return super.api(uri, maximumBytes: maximumBytes);
  }
}

void main() {
  test(
    'Drive RPC export errors retain filename and internal wire code',
    () async {
      final directory = createTestTempDirectorySync('drive-rpc-error-');
      final fixture = GoogleFixture();
      await fixture.start();
      final auth = RpcFailingExportAuth(
        Directory('${directory.path}/google'),
        endpoints: fixture.endpoints,
      )..client = GoogleClient('fixture.apps.googleusercontent.com', '');
      final store = Store('${directory.path}/app.db');
      final helper = Helper(
        '${directory.path}/socket',
        '${directory.path}/helper',
      );
      final connection = GoogleConnections(
        FailingImportDomain(store, helper),
        auth,
      );
      try {
        await auth.signIn(fixture.consent);
        await expectLater(
          connection.importDriveFile('doc'),
          throwsA(
            isA<StateError>().having(
              (error) {
                final wire = RpcError.from(error);
                return (wire.code, wire.message);
              },
              'wire error',
              (RpcErrorCode.internal, 'Apollo: fixture export unavailable'),
            ),
          ),
        );
        expect(store.sources, isEmpty);
      } finally {
        connection.close();
        await auth.close();
        await helper.close();
        store.close();
        await fixture.close();
        directory.deleteSync(recursive: true);
      }
    },
  );
  test(
    'Drive rejects restricted downloads and names each file once across batch imports',
    () async {
      final directory = createTestTempDirectorySync('drive-restrictions-');
      final fixture = GoogleFixture()
        ..restrictedFiles.add('sheet')
        ..exportDeniedFiles.add('slides');
      await fixture.start();
      final auth = GoogleAuth(
        Directory('${directory.path}/google'),
        secretStore: const UnavailableSecretStore(),
        endpoints: fixture.endpoints,
      )..client = GoogleClient('fixture.apps.googleusercontent.com', '');
      final store = Store('${directory.path}/app.db');
      final helper = Helper(
        '${directory.path}/socket',
        '${directory.path}/helper',
      );
      final domain = FailingImportDomain(store, helper);
      final connection = GoogleConnections(domain, auth);
      try {
        await auth.signIn(fixture.consent);
        final files = await connection.driveFiles(parent: 'nested');
        expect(GoogleConnections.canDownload(files.single), false);
        expect(
          fixture.fieldQueries.last,
          contains('capabilities(canDownload)'),
        );
        await expectLater(
          connection.importDriveFile('sheet'),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              'Sheet: Google Drive does not allow downloading this file.',
            ),
          ),
        );
        expect(fixture.exports, isEmpty);
        await expectLater(
          connection.importDriveFile('slides'),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              'Slides: This file cannot be downloaded by the user.',
            ),
          ),
        );
        await connection.importDriveFile('doc');
        expect(store.sources.single['title'], 'Apollo');
        expect(domain.indexed, hasLength(1));
        await expectLater(
          connection.importDriveFolder('folder'),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'summary',
              'Imported 0 files; Sheet: Google Drive does not allow downloading this file.',
            ),
          ),
        );
        await expectLater(
          connection.importLastYear(),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'summary',
              'Slides: This file cannot be downloaded by the user.',
            ),
          ),
        );
        await connection.syncCalendar();
        fixture.exportDeniedFiles.add('doc');
        final meeting =
            store
                    .rows('SELECT meeting_id FROM calendar_events')
                    .single['meeting_id']
                as int;
        await expectLater(
          connection.importAttachments(meeting),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'summary',
              'Apollo: This file cannot be downloaded by the user.',
            ),
          ),
        );
        fixture.exportDeniedFiles.clear();
        fixture.document = 'Changed upstream';
        domain.rejectIndex = true;
        await expectLater(
          connection.importAttachments(meeting),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'summary',
              'Apollo: Indexing unavailable',
            ),
          ),
        );
      } finally {
        connection.close();
        await auth.close();
        await helper.close();
        store.close();
        await fixture.close();
        directory.deleteSync(recursive: true);
      }
    },
  );
  test(
    'sign-in reentry is busy and owned cancellation returns cancelled',
    () async {
      final directory = createTestTempDirectorySync('google-cancel-');
      addTearDown(() {
        if (directory.existsSync()) directory.deleteSync(recursive: true);
      });
      final auth = GoogleAuth(
        Directory('${directory.path}/google'),
        secretStore: const UnavailableSecretStore(),
      )..client = GoogleClient('fixture.apps.googleusercontent.com', '');
      addTearDown(auth.close);
      final opened = Completer<void>();
      final pending = auth.signIn((_) async => opened.complete());
      final rejected = expectLater(
        pending,
        throwsA(
          isA<RpcError>().having((e) => e.code, 'code', RpcErrorCode.cancelled),
        ),
      );
      await opened.future;
      await expectLater(
        auth.signIn((_) async => fail('must not open a second browser')),
        throwsA(
          isA<RpcError>().having((e) => e.code, 'code', RpcErrorCode.busy),
        ),
      );
      auth.cancelSignIn();
      await rejected;
      expect(auth.signingIn, isFalse);
      expect(auth.connected, isFalse);
    },
  );

  test(
    'forgetting an account during sign-in prevents late credential adoption',
    () async {
      final directory = createTestTempDirectorySync('google-late-signin-');
      addTearDown(() {
        if (directory.existsSync()) directory.deleteSync(recursive: true);
      });
      final fixture = GoogleFixture();
      await fixture.start();
      addTearDown(fixture.close);
      final auth = GoogleAuth(
        Directory('${directory.path}/google'),
        endpoints: fixture.endpoints,
        secretStore: const UnavailableSecretStore(),
      )..client = GoogleClient('fixture.apps.googleusercontent.com', '');
      addTearDown(auth.close);
      fixture.beforeUserInfo = auth.forget;
      await expectLater(
        auth.signIn(fixture.consent),
        throwsA(
          isA<RpcError>()
              .having((e) => e.code, 'code', RpcErrorCode.cancelled)
              .having((e) => e.message, 'message', 'Google connection changed'),
        ),
      );
      expect(auth.connected, isFalse);
      expect(
        File('${directory.path}/google/tokens.json').existsSync(),
        isFalse,
      );
    },
  );

  test(
    'Drive pause retains an active export and resumes the folder queue',
    () async {
      final directory = createTestTempDirectorySync('foresight-drive-pause-');
      addTearDown(() {
        if (directory.existsSync()) directory.deleteSync(recursive: true);
      });
      final fixture = GoogleFixture();
      await fixture.start();
      final auth = GoogleAuth(
        Directory('${directory.path}/google'),
        secretStore: const UnavailableSecretStore(),
        endpoints: fixture.endpoints,
      );
      final store = Store('${directory.path}/app.db');
      final helper = Helper(
        '${directory.path}/socket',
        '${directory.path}/helper',
      );
      final domain = PausedAdapterDomain(store, helper);
      final connection = GoogleConnections(domain, auth);
      final config = File('${directory.path}/client.json')
        ..writeAsStringSync(
          jsonEncode({
            'installed': {
              'client_id': '123-fixture.apps.googleusercontent.com',
            },
          }),
        );
      try {
        await auth.configure(config);
        await auth.signIn(fixture.consent);
        fixture.onExport = () {
          fixture.onExport = null;
          domain.pauseSources();
        };
        final importing = connection.importDriveFolder('folder');
        await domain.pausedCheckpoint.future.timeout(
          const Duration(seconds: 5),
        );
        expect(fixture.exports, ['text/plain']);
        expect(domain.indexed, isEmpty);
        expect(store.sources, isEmpty);
        domain.resumeSources();
        await importing.timeout(const Duration(seconds: 5));
        expect(fixture.exports, ['text/plain', 'text/csv']);
        expect(store.sources.length, 2);
        expect(domain.indexed.length, 2);
        final doc = store.sources.singleWhere((s) => s['title'] == 'Apollo');
        domain.pausedCheckpoint = Completer<void>();
        fixture.modified = 'v2';
        fixture.onExport = () {
          fixture.onExport = null;
          domain.pauseSources();
        };
        final refreshing = connection.importDriveFolder(
          'folder',
          refreshing: true,
        );
        await domain.pausedCheckpoint.future.timeout(
          const Duration(seconds: 5),
        );
        await domain.delete(doc['id'] as String);
        domain.resumeSources();
        await refreshing.timeout(const Duration(seconds: 5));
        expect(
          store.sources.any((s) => s['id'] == doc['id']),
          false,
          reason:
              'A deletion during paused refresh must not resurrect the source',
        );
      } finally {
        connection.close();
        domain.close();
        await auth.close();
        await helper.close();
        store.close();
        await fixture.close();
        directory.deleteSync(recursive: true);
      }
    },
  );

  test(
    'packaged sign-in configuration works without user setup and private override wins',
    () async {
      final root = createTestTempDirectorySync('foresight-google-default-');
      addTearDown(() {
        if (root.existsSync()) root.deleteSync(recursive: true);
      });
      final profile = Directory('${root.path}/profile');
      final bundled = File('${root.path}/application-client.json')
        ..writeAsStringSync(
          jsonEncode({
            'installed': {
              'client_id': '123-bundled.apps.googleusercontent.com',
              'client_secret': 'fixture-application-configuration',
            },
          }),
        );
      final initial = GoogleAuth(profile, defaultClient: bundled);
      expect(initial.client!.id, '123-bundled.apps.googleusercontent.com');
      expect(initial.client!.secret, 'fixture-application-configuration');
      expect(
        profile.existsSync(),
        false,
        reason:
            'Reading application configuration must not create account state',
      );
      final override = File('${root.path}/override.json')
        ..writeAsStringSync(
          jsonEncode({
            'installed': {
              'client_id': '123-override.apps.googleusercontent.com',
              'client_secret': 'fixture-override',
            },
          }),
        );
      await initial.configure(override);
      await initial.close();
      final reopened = GoogleAuth(profile, defaultClient: bundled);
      expect(reopened.client!.id, '123-override.apps.googleusercontent.com');
      expect(reopened.connected, false);
      await reopened.close();
      root.deleteSync(recursive: true);
    },
  );
  test(
    'PKCE, state validation, private persistence, refresh serialization and revocation',
    () async {
      final directory = createTestTempDirectorySync('foresight-google-auth-');
      addTearDown(() {
        if (directory.existsSync()) directory.deleteSync(recursive: true);
      });
      final fixture = GoogleFixture();
      await fixture.start();
      var auth = GoogleAuth(
        Directory('${directory.path}/google'),
        secretStore: const UnavailableSecretStore(),
        endpoints: fixture.endpoints,
      );
      final config = File('${directory.path}/client.json')
        ..writeAsStringSync(
          jsonEncode({
            'installed': {
              'client_id': '123-fixture.apps.googleusercontent.com',
              'client_secret': 'fixture-desktop-secret',
            },
          }),
        );
      try {
        await auth.configure(config);
        await auth.signIn(fixture.consent);
        expect(auth.connected, true);
        expect(auth.email, 'fixture@example.test');
        final saved = File('${directory.path}/google/tokens.json');
        expect(saved.statSync().mode & 0x3f, 0);
        await auth.close();
        auth = GoogleAuth(
          Directory('${directory.path}/google'),
          secretStore: const UnavailableSecretStore(),
          endpoints: fixture.endpoints,
        );
        expect(auth.connected, true);
        await Future.wait(
          List.generate(4, (_) => auth.accessToken(forceRefresh: true)),
        );
        expect(fixture.refreshes, 1);
        fixture.denyDriveOnce = true;
        await auth.apiJson(
          fixture.endpoints.drive
              .resolve('files')
              .replace(queryParameters: {'q': 'trashed = false'}),
        );
        expect(fixture.refreshes, 2);
        await auth.disconnect();
        expect(auth.connected, false);
        expect(saved.existsSync(), false);
        expect(
          await auth
              .signIn((uri) => fixture.consent(uri, deny: true))
              .then((_) => 'unexpected', onError: (Object e) => e.toString()),
          contains('denied'),
        );
        expect(auth.connected, false);
      } finally {
        await auth.close();
        await fixture.close();
        directory.deleteSync(recursive: true);
      }
    },
  );

  test(
    'Drive retains modification time and Calendar metadata stays out of sources',
    () async {
      final directory = createTestTempDirectorySync('foresight-source-dates-');
      addTearDown(() {
        if (directory.existsSync()) directory.deleteSync(recursive: true);
      });
      final fixture = GoogleFixture()..modified = '2019-01-01T00:00:00Z';
      await fixture.start();
      final auth = GoogleAuth(
        Directory('${directory.path}/google'),
        secretStore: const UnavailableSecretStore(),
        endpoints: fixture.endpoints,
      );
      final store = Store('${directory.path}/app.db');
      final helper = Helper(
        '${directory.path}/socket',
        '${directory.path}/helper',
      );
      var connection = GoogleConnections(AdapterDomain(store, helper), auth);
      final config = File('${directory.path}/client.json')
        ..writeAsStringSync(
          jsonEncode({
            'installed': {
              'client_id': '123-fixture.apps.googleusercontent.com',
            },
          }),
        );
      try {
        await auth.configure(config);
        await auth.signIn(fixture.consent);
        await connection.importDriveFile('doc');
        await connection.syncCalendar();
        Map<String, Object?> document() =>
            store.sources.singleWhere((row) => row['title'] == 'Apollo');
        final initial = document();
        expect(fixture.fieldQueries, isNotEmpty);
        expect(
          fixture.fieldQueries.every(
            (fields) => fields.contains('webViewLink'),
          ),
          true,
        );
        expect(initial['source_uri'], 'https://drive.example.test/doc');
        expect(store.sources, hasLength(1));
        final event =
            jsonDecode(
                  store
                          .rows('SELECT metadata FROM calendar_events')
                          .single['metadata']
                      as String,
                )
                as Map;
        expect(event['htmlLink'], 'https://calendar.example.test/event-1');
        expect(
          initial['changed'],
          DateTime.parse(fixture.modified).millisecondsSinceEpoch,
        );
        expect(
          initial['imported'] as int,
          greaterThan(initial['changed'] as int),
        );
        expect(event['updated'], fixture.eventUpdated);
        fixture.modified = '2021-01-01T00:00:00Z';
        await connection.importDriveFile('doc');
        expect(
          document()['revision'],
          initial['revision'],
          reason: 'Metadata-only refresh must not invalidate citations',
        );
        expect(document()['imported'], initial['imported']);
        expect(
          document()['changed'],
          DateTime.parse(fixture.modified).millisecondsSinceEpoch,
        );
        final indexedBeforeLinkChange =
            (connection.domain as AdapterDomain).indexed.length;
        fixture.linkSuffix = '?viewer=v2';
        await connection.refresh();
        expect(
          document()['source_uri'],
          'https://drive.example.test/doc?viewer=v2',
        );
        expect(document()['revision'], initial['revision']);
        expect(
          (connection.domain as AdapterDomain).indexed.length,
          indexedBeforeLinkChange,
          reason:
              'Refreshing only an original link must not reindex source content',
        );
        // Repair belongs to schema16; constructing the adapter does not write.
        store.db.execute('UPDATE source_details SET changed=123');
        connection.close();
        connection = GoogleConnections(AdapterDomain(store, helper), auth);
        expect(document()['changed'], 123);
        expect(document()['revision'], initial['revision']);
        expect(document()['imported'], initial['imported']);
        expect(store.sources, hasLength(1));
        final id = document()['id'] as String;
        store.importText(
          'Apollo',
          'My edited copy.',
          'text/plain',
          'user edit; google-drive:fixture-account:doc',
          id: id,
        );
        final edited = document()['changed'];
        connection.close();
        connection = GoogleConnections(AdapterDomain(store, helper), auth);
        expect(
          document()['changed'],
          edited,
          reason: 'Cached external metadata must not overwrite local edit time',
        );
        fixture.document = 'My edited copy.';
        await connection.importDriveFile('doc');
        expect(
          document()['changed'],
          edited,
          reason: 'Metadata-only refresh must also preserve local edit time',
        );
        fixture.document = 'Remote replacement';
        fixture.modified = '2022-01-01T00:00:00Z';
        await connection.refresh();
        expect(document()['content'], 'My edited copy.');
        expect(document()['revision'], 2);
        fixture.modified = '';
        await connection.importDriveFile('sheet');
        expect(
          store.sources.singleWhere(
            (row) => row['title'] == 'Sheet',
          )['changed'],
          0,
          reason:
              'Missing external metadata must not invent a modification time',
        );
      } finally {
        connection.close();
        await auth.close();
        await helper.close();
        store.close();
        await fixture.close();
        directory.deleteSync(recursive: true);
      }
    },
  );

  test(
    'Reminder delivery rejects a Google account switch while awaiting notification',
    () async {
      final directory = createTestTempDirectorySync(
        'foresight-reminder-account-',
      );
      addTearDown(() {
        if (directory.existsSync()) directory.deleteSync(recursive: true);
      });
      final fixture = GoogleFixture();
      await fixture.start();
      final auth = GoogleAuth(
        Directory('${directory.path}/google'),
        secretStore: const UnavailableSecretStore(),
        endpoints: fixture.endpoints,
      );
      final store = Store('${directory.path}/app.db');
      final helper = Helper(
        '${directory.path}/socket',
        '${directory.path}/helper',
      );
      final connection = GoogleConnections(AdapterDomain(store, helper), auth);
      final config = File('${directory.path}/client.json')
        ..writeAsStringSync(
          jsonEncode({
            'installed': {
              'client_id': '123-fixture.apps.googleusercontent.com',
            },
          }),
        );
      try {
        await auth.configure(config);
        await auth.signIn(fixture.consent);
        // Legacy timestamps without an account must not defer the first sync.
        store.setPreference(
          'googleLastSync',
          DateTime.now().millisecondsSinceEpoch.toString(),
        );
        expect(connection.lastCompletedRefreshMs, 0);
        await connection.refresh();
        expect(connection.lastCompletedRefreshMs, greaterThan(0));
        store.setPreference('googleReminders', 'true');
        await expectLater(
          connection.reminders(DateTime.parse('2026-10-16T14:57:00Z'), (
            message,
          ) async {
            await auth.disconnect();
            expect(connection.lastCompletedRefreshMs, 0);
            fixture.accountSub = 'replacement-account';
            await auth.signIn(fixture.consent);
          }),
          throwsA(
            isA<RpcError>()
                .having((error) => error.code, 'code', RpcErrorCode.cancelled)
                .having(
                  (error) => error.message,
                  'message',
                  contains('connection changed'),
                ),
          ),
        );
        expect(auth.account, 'replacement-account');
        expect(
          connection.lastCompletedRefreshMs,
          0,
          reason: 'A new account cannot inherit the previous refresh status',
        );
        expect(
          store.rows('SELECT reminder FROM meeting_details').single['reminder'],
          0,
        );
        var leaked = false;
        await connection.reminders(
          DateTime.parse('2026-10-16T14:58:00Z'),
          (_) async => leaked = true,
        );
        expect(
          leaked,
          false,
          reason:
              'Old-account reminders must not be sent under the new account',
        );
      } finally {
        connection.close();
        await auth.close();
        await helper.close();
        store.close();
        await fixture.close();
        directory.deleteSync(recursive: true);
      }
    },
  );

  test(
    'Drive paging/folders/exports and Calendar context, attachments, refresh, reminders and cancellation',
    () async {
      final directory = createTestTempDirectorySync(
        'foresight-google-adapter-',
      );
      addTearDown(() {
        if (directory.existsSync()) directory.deleteSync(recursive: true);
      });
      final fixture = GoogleFixture();
      await fixture.start();
      final auth = GoogleAuth(
        Directory('${directory.path}/google'),
        secretStore: const UnavailableSecretStore(),
        endpoints: fixture.endpoints,
      );
      final config = File('${directory.path}/client.json')
        ..writeAsStringSync(
          jsonEncode({
            'installed': {
              'client_id': '123-fixture.apps.googleusercontent.com',
            },
          }),
        );
      final store = Store('${directory.path}/app.db'),
          helper = Helper(
            '${directory.path}/socket',
            '${directory.path}/helper',
          );
      final domain = AdapterDomain(store, helper),
          connection = GoogleConnections(domain, auth);
      try {
        await auth.configure(config);
        await auth.signIn(fixture.consent);
        final listed = await connection.driveFiles();
        expect(listed.length, 3);
        await connection.importDriveFolder('folder');
        expect(store.sources.length, 2);
        expect(fixture.exports, containsAll(['text/plain', 'text/csv']));
        final doc = store.sources
            .where((row) => row['title'] == 'Apollo')
            .single;
        await connection.syncCalendar();
        expect(store.rows('SELECT * FROM meetings').length, 1);
        expect(
          store.sources.any((row) => row['title'] == '[Calendar] Planning'),
          false,
        );
        final indexedBeforeCalendarRefresh = domain.indexed.length;
        expect(
          store
              .rows('SELECT source_id FROM calendar_events')
              .single['source_id'],
          isEmpty,
        );
        fixture.eventDescription = 'Changed upstream';
        await connection.syncCalendar(preserveLocal: true);
        expect(
          (jsonDecode(
                store
                        .rows('SELECT metadata FROM calendar_events')
                        .single['metadata']
                    as String,
              )
              as Map)['description'],
          contains('Changed upstream'),
        );
        fixture.eventDescription = '<a' * 40000;
        final application = Application(domain, auth: auth);
        final watch = Stopwatch()..start();
        final sync = connection.syncCalendar(preserveLocal: true);
        await application
            .call('status', {})
            .timeout(const Duration(milliseconds: 200));
        await sync;
        expect(watch.elapsed, lessThan(const Duration(seconds: 1)));
        fixture.eventDescription = 'Review Apollo.';
        await connection.syncCalendar(preserveLocal: true);
        await connection.syncCalendar();
        expect(store.sources, hasLength(2));
        expect(domain.indexed, hasLength(indexedBeforeCalendarRefresh));
        final meeting =
            store.rows('SELECT * FROM meetings').single['id'] as int;
        expect(connection.attachments(meeting).single['fileId'], 'doc');
        await connection.importAttachments(meeting);
        expect(
          store.sources
              .where((row) => row['id'] == doc['id'])
              .single['revision'],
          1,
        );
        fixture.modified = 'v2';
        fixture.newFolderFile = true;
        fixture.document = 'Apollo launches Monday.';
        await connection.refresh();
        final changed = store.sources
            .where((row) => row['id'] == doc['id'])
            .single;
        expect(changed['revision'], 2);
        expect(changed['content'], contains('Monday'));
        final added = store.sources
            .where((row) => row['title'] == 'Slides')
            .single;
        expect(domain.indexed, contains(added['id']));
        expect(
          store.rows('SELECT * FROM google_folders').single['folder_id'],
          'folder',
        );
        await domain.delete(added['id'] as String);
        await connection.refresh();
        expect(
          store.sources.any((row) => row['id'] == added['id']),
          false,
          reason: 'Automatic folder refresh must preserve user deletions',
        );
        store.setPreference('googleReminders', 'true');
        final notices = <String>[];
        await connection.reminders(DateTime.parse('2026-10-16T14:57:00Z'), (
          text,
        ) async {
          notices.add(text);
        });
        await connection.reminders(DateTime.parse('2026-10-16T14:58:00Z'), (
          text,
        ) async {
          notices.add(text);
        });
        expect(notices.length, 1);
        fixture.eventStart = '2026-10-16T15:10:00Z';
        await connection.syncCalendar();
        expect(store.rows('SELECT * FROM meetings').length, 1);
        await connection.reminders(DateTime.parse('2026-10-16T15:07:00Z'), (
          text,
        ) async {
          notices.add(text);
        });
        expect(
          notices.length,
          2,
          reason: 'Rescheduling rearms the reminder on the existing meeting',
        );
        // Calendar sync must leave existing documents alone, including ones
        // whose identifiers match a calendar event from an older profile.
        final calendarId =
            store
                    .rows('SELECT event_key FROM calendar_events')
                    .single['event_key']
                as String;
        final indexedBeforeCancellation = domain.indexed.length;
        store.importText(
          '[Calendar] Planning',
          'MY CANCELLED MEETING EDIT',
          'text/plain',
          'calendar',
          id: calendarId,
          locallyEdited: true,
        );
        fixture.cancelledEvent = true;
        await connection.syncCalendar(preserveLocal: true);
        expect(
          store.sources.firstWhere((row) => row['id'] == calendarId)['content'],
          'MY CANCELLED MEETING EDIT',
        );
        expect(
          store.rows('SELECT status FROM calendar_events').single['status'],
          'cancelled',
        );
        // Manual sync also updates metadata without deleting documents.
        await connection.syncCalendar();
        expect(
          store.sources.firstWhere((row) => row['id'] == calendarId)['content'],
          'MY CANCELLED MEETING EDIT',
        );
        // The same holds for existing documents without local edits.
        store.importText(
          '[Calendar] Planning',
          'Existing meeting document',
          'text/plain',
          'calendar',
          id: calendarId,
        );
        fixture.cancelledEvent = false;
        await connection.syncCalendar();
        fixture.cancelledEvent = true;
        await connection.syncCalendar(preserveLocal: true);
        expect(
          store.rows('SELECT status FROM calendar_events').single['status'],
          'cancelled',
        );
        expect(
          store.sources.firstWhere((row) => row['id'] == calendarId)['content'],
          'Existing meeting document',
        );
        expect(domain.indexed, hasLength(indexedBeforeCancellation));
        expect(
          domain.indexed,
          contains(doc['id']),
        ); // Explicit adapter seam; this test does not claim real embedding execution.
      } finally {
        connection.close();
        await auth.close();
        await helper.close();
        store.close();
        await fixture.close();
        directory.deleteSync(recursive: true);
      }
    },
  );
}
