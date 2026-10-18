import 'package:foresight_core/src/rpc_error.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:foresight_core/src/google_auth.dart';
import 'package:foresight_core/src/google_connections.dart';
import 'package:foresight_core/src/helper.dart';
import 'package:foresight_core/src/store.dart';

import 'package:foresight_test_support/google_connections.dart';

void main() {
  test(
    'sign-in reentry is busy and owned cancellation returns cancelled',
    () async {
      final directory = Directory.systemTemp.createTempSync('google-cancel-');
      addTearDown(() {
        if (directory.existsSync()) directory.deleteSync(recursive: true);
      });
      final auth = GoogleAuth(Directory('${directory.path}/google'))
        ..client = GoogleClient('fixture.apps.googleusercontent.com', '');
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
      final directory = Directory.systemTemp.createTempSync(
        'google-late-signin-',
      );
      addTearDown(() {
        if (directory.existsSync()) directory.deleteSync(recursive: true);
      });
      final fixture = GoogleFixture();
      await fixture.start();
      addTearDown(fixture.close);
      final auth = GoogleAuth(
        Directory('${directory.path}/google'),
        endpoints: fixture.endpoints,
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
      final directory = Directory.systemTemp.createTempSync(
        'foresight-drive-pause-',
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
      final root = Directory.systemTemp.createTempSync(
        'foresight-google-default-',
      );
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
      final directory = Directory.systemTemp.createTempSync(
        'foresight-google-auth-',
      );
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
    'Drive and Calendar retain original modification time separately from import time',
    () async {
      final directory = Directory.systemTemp.createTempSync(
        'foresight-source-dates-',
      );
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
        expect(
          store.sources.singleWhere(
            (row) => row['title'] == '[Calendar] Planning',
          )['source_uri'],
          'https://calendar.example.test/event-1',
        );
        expect(
          initial['changed'],
          DateTime.parse(fixture.modified).millisecondsSinceEpoch,
        );
        expect(
          initial['imported'] as int,
          greaterThan(initial['changed'] as int),
        );
        expect(
          store.sources.singleWhere(
            (row) => row['title'] == '[Calendar] Planning',
          )['changed'],
          DateTime.parse(fixture.eventUpdated).millisecondsSinceEpoch,
        );
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
        // Repair previously imported profiles without modifying their content/revisions.
        store.db.execute('UPDATE source_details SET changed=123');
        store.db.execute(
          "UPDATE source_details SET source_uri='' WHERE source_id IN (SELECT source_id FROM calendar_events)",
        );
        connection.close();
        connection = GoogleConnections(AdapterDomain(store, helper), auth);
        expect(
          document()['changed'],
          DateTime.parse(fixture.modified).millisecondsSinceEpoch,
        );
        expect(document()['revision'], initial['revision']);
        expect(document()['imported'], initial['imported']);
        expect(
          store.sources.singleWhere(
            (row) => row['title'] == '[Calendar] Planning',
          )['source_uri'],
          'https://calendar.example.test/event-1',
        );
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
      final directory = Directory.systemTemp.createTempSync(
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
      final directory = Directory.systemTemp.createTempSync(
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
          true,
        );
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
        fixture.cancelledEvent = true;
        await connection.syncCalendar();
        expect(
          store.rows('SELECT status FROM calendar_events').single['status'],
          'cancelled',
        );
        expect(
          store.sources.any((row) => row['title'] == '[Calendar] Planning'),
          false,
        );
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
