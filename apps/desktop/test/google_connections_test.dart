import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foresight/domain.dart';
import 'package:foresight/google_auth.dart';
import 'package:foresight/google_connections.dart';
import 'package:foresight/helper.dart';
import 'package:foresight/store.dart';

class GoogleFixture {
  late HttpServer server;
  String challenge = '', redirect = '';
  int refreshes = 0;
  bool denyDriveOnce = false, cancelledEvent = false;
  bool newFolderFile = false;
  String accountSub = 'fixture-account';
  String eventUpdated = '2020-01-01T00:00:00Z';
  String eventStart = '2026-10-16T15:00:00Z';
  String modified = 'v1', document = 'Apollo launches Friday.';
  String linkSuffix = '';
  final queries = <String>[], exports = <String>[];
  final fieldQueries = <String>[];
  void Function()? onExport;
  late GoogleEndpoints endpoints;
  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final base = Uri.parse('http://127.0.0.1:${server.port}/');
    endpoints = GoogleEndpoints(
      authorize: base.resolve('authorize'),
      token: base.resolve('token'),
      revoke: base.resolve('revoke'),
      userinfo: base.resolve('userinfo'),
      drive: base.resolve('drive/'),
      calendar: base.resolve('calendar/'),
    );
    server.listen((request) async {
      try {
        dynamic response;
        final path = request.uri.path;
        if (path == '/token') {
          final form = Uri.splitQueryString(
            await utf8.decoder.bind(request).join(),
          );
          if (form['grant_type'] == 'authorization_code') {
            expect(form['redirect_uri'], redirect);
            expect(
              base64UrlEncode(
                sha256.convert(utf8.encode(form['code_verifier']!)).bytes,
              ).replaceAll('=', ''),
              challenge,
            );
            expect(form['code_verifier']!.length, inInclusiveRange(43, 128));
          } else {
            refreshes++;
            expect(form['refresh_token'], 'fixture-refresh');
          }
          response = {
            'access_token': 'fixture-access-$refreshes',
            'refresh_token': 'fixture-refresh',
            'expires_in': 3600,
            'scope': GoogleAuth.scopes.join(' '),
          };
        } else if (path == '/userinfo') {
          expect(
            request.headers.value('authorization'),
            startsWith('Bearer fixture-access'),
          );
          response = {'sub': accountSub, 'email': 'fixture@example.test'};
        } else if (path == '/revoke') {
          response = {};
        } else {
          expect(
            request.headers.value('authorization'),
            startsWith('Bearer fixture-access'),
          );
          if (denyDriveOnce && path.startsWith('/drive/')) {
            denyDriveOnce = false;
            request.response.statusCode = 401;
            response = {
              'error': {'message': 'Fixture token expired'},
            };
          } else if (path == '/drive/files') {
            final fields = request.uri.queryParameters['fields'];
            if (fields != null) fieldQueries.add(fields);
            final query = request.uri.queryParameters['q']!;
            queries.add(query);
            if (query.contains("'nested' in parents"))
              response = {
                'files': [
                  file(
                    'sheet',
                    'Sheet',
                    'application/vnd.google-apps.spreadsheet',
                  ),
                ],
              };
            else if (query.contains("'folder' in parents"))
              response = {
                'files': [
                  file('doc', 'Apollo', 'application/vnd.google-apps.document'),
                  if (newFolderFile)
                    file(
                      'slides',
                      'Slides',
                      'application/vnd.google-apps.presentation',
                    ),
                  file(
                    'nested',
                    'Nested',
                    'application/vnd.google-apps.folder',
                  ),
                ],
              };
            else if (request.uri.queryParameters['pageToken'] == 'page2')
              response = {
                'files': [
                  file(
                    'slides',
                    'Slides',
                    'application/vnd.google-apps.presentation',
                  ),
                ],
              };
            else
              response = {
                'nextPageToken': 'page2',
                'files': [
                  file(
                    'folder',
                    'Folder',
                    'application/vnd.google-apps.folder',
                  ),
                  file('doc', 'Apollo', 'application/vnd.google-apps.document'),
                ],
              };
          } else if (path.endsWith('/export')) {
            final mime = request.uri.queryParameters['mimeType']!;
            exports.add(mime);
            onExport?.call();
            request.response.headers.contentType = ContentType.text;
            request.response.write(
              mime == 'text/csv'
                  ? 'Task,Owner\nReview,Ravi'
                  : path.contains('doc/')
                  ? document
                  : 'Slides about Apollo.',
            );
            return;
          } else if (path.startsWith('/drive/files/')) {
            final fields = request.uri.queryParameters['fields'];
            if (fields != null) fieldQueries.add(fields);
            final id = path.split('/').last;
            response = file(
              id,
              id == 'sheet'
                  ? 'Sheet'
                  : id == 'slides'
                  ? 'Slides'
                  : 'Apollo',
              id == 'sheet'
                  ? 'application/vnd.google-apps.spreadsheet'
                  : id == 'slides'
                  ? 'application/vnd.google-apps.presentation'
                  : 'application/vnd.google-apps.document',
            );
          } else if (path == '/calendar/calendars/primary/events') {
            expect(request.uri.queryParameters['singleEvents'], 'true');
            response = {
              'items': [
                cancelledEvent
                    ? {'id': 'event-1', 'status': 'cancelled'}
                    : {
                        'id': 'event-1',
                        'summary': 'Planning',
                        'updated': eventUpdated,
                        'htmlLink': 'https://calendar.example.test/event-1',
                        'description': 'Review Apollo.',
                        'status': 'confirmed',
                        'start': {'dateTime': eventStart},
                        'end': {'dateTime': '2026-10-16T15:30:00Z'},
                        'attendees': [
                          {'displayName': 'Ravi', 'email': 'ravi@example.test'},
                        ],
                        'attachments': [
                          {'fileId': 'doc', 'title': 'Apollo'},
                        ],
                      },
              ],
            };
          } else {
            request.response.statusCode = 404;
            response = {
              'error': {'message': 'Fixture endpoint not found: $path'},
            };
          }
        }
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode(response));
      } finally {
        await request.response.close();
      }
    });
  }

  Map<String, Object?> file(String id, String name, String mime) => {
    'id': id,
    'name': name,
    'mimeType': mime,
    'modifiedTime': modified,
    'trashed': false,
    'webViewLink': 'https://drive.example.test/$id$linkSuffix',
  };
  Future<void> consent(Uri uri, {bool deny = false}) async {
    final params = uri.queryParameters;
    expect(params['code_challenge_method'], 'S256');
    challenge = params['code_challenge']!;
    redirect = params['redirect_uri']!;
    final browser = HttpClient();
    try {
      final invalid = await (await browser.getUrl(
        Uri.parse(
          redirect,
        ).replace(queryParameters: {'state': 'wrong', 'code': 'fixture-code'}),
      )).close();
      expect(invalid.statusCode, 400);
      await invalid.drain<void>();
      final response = await (await browser.getUrl(
        Uri.parse(redirect).replace(
          queryParameters: {
            'state': params['state']!,
            if (deny) 'error': 'access_denied' else 'code': 'fixture-code',
          },
        ),
      )).close();
      await response.drain<void>();
    } finally {
      browser.close(force: true);
    }
  }

  Future<void> close() => server.close(force: true);
}

class AdapterDomain extends Domain {
  final indexed = <String>[];
  AdapterDomain(super.store, super.helper);
  @override
  Future<void> index(String id) async {
    indexed.add(id);
    store.state(id, 'indexed');
  }

  @override
  Future<void> delete(String id) async {
    store.tombstone(id);
  }
}

class PausedAdapterDomain extends AdapterDomain {
  PausedAdapterDomain(super.store, super.helper);
  var pausedCheckpoint = Completer<void>();
  @override
  Future<void> waitForSourceWork() {
    if (sourcesPaused && !pausedCheckpoint.isCompleted) {
      pausedCheckpoint.complete();
    }
    return super.waitForSourceWork();
  }
}

void main() {
  test(
    'Drive pause retains an active export and resumes the folder queue',
    () async {
      final directory = Directory.systemTemp.createTempSync(
        'foresight-drive-pause-',
      );
      final fixture = GoogleFixture();
      await fixture.start();
      final auth = GoogleAuth(
        Directory('${directory.path}/google'),
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
      final fixture = GoogleFixture();
      await fixture.start();
      var auth = GoogleAuth(
        Directory('${directory.path}/google'),
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
      final fixture = GoogleFixture()..modified = '2019-01-01T00:00:00Z';
      await fixture.start();
      final auth = GoogleAuth(
        Directory('${directory.path}/google'),
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
      final fixture = GoogleFixture();
      await fixture.start();
      final auth = GoogleAuth(
        Directory('${directory.path}/google'),
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
            isA<StateError>().having(
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
      final fixture = GoogleFixture();
      await fixture.start();
      final auth = GoogleAuth(
        Directory('${directory.path}/google'),
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
