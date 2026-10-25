import 'sql_support_test_bootstrap.dart';
import 'dart:convert';
import 'dart:io';

import 'package:foresight_core/src/google_auth.dart';
import 'package:foresight_core/src/google_connections.dart';
import 'package:foresight_core/src/helper.dart';
import 'package:foresight_core/src/store.dart';
import 'package:foresight_test_support/google_connections.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';

void main() {
  bootstrapSqlSupportFixture();
  test(
    'calendar snapshot validation is atomic and excludes self-declined events',
    () async {
      final root = createTestTempDirectorySync('calendar-snapshot-boundaries-');
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      Object snapshot = {
        'results': {'events': <Object>[]},
      };
      var snapshots = 0;
      server.listen((request) async {
        expect(request.method, 'POST');
        final operation = request.uri.path.split('/').last;
        final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
        Object response;
        switch (operation) {
          case 'workos-auth-complete':
            expect(body['code'], 'snapshot-fixture-code');
            expect(body['codeVerifier'], isNotEmpty);
            response = {
              'tokens': {
                'access_token': 'fixture-access',
                'refresh_token': 'fixture-refresh',
                'expires_in': 3600,
                'token_type': 'Bearer',
              },
              'config': {},
            };
          case 'get-user-info':
            expect(
              request.headers.value('authorization'),
              'Bearer fixture-access',
            );
            response = {
              'id': 'calendar-fixture',
              'email': 'fixture@example.test',
              'first_name': 'Fixture',
              'last_name': 'Calendar',
            };
          case 'refresh-calendar-events':
            expect(
              request.headers.value('authorization'),
              'Bearer fixture-access',
            );
            snapshots++;
            response = snapshot;
          default:
            fail('Unexpected local operation: $operation');
        }
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode(response));
        await request.response.close();
      });
      final auth = GoogleAuth(
        Directory('${root.path}/google'),
        granolaEndpoints: GranolaEndpoints(
          base: Uri.parse('http://127.0.0.1:${server.port}/v1/'),
        ),
        secretStore: const UnavailableSecretStore(),
      );
      final store = Store('${root.path}/app.db');
      final helper = Helper('${root.path}/unused.sock', '${root.path}/unused');
      final domain = AdapterDomain(store, helper);
      final connection = GoogleConnections(domain, auth);
      addTearDown(() async {
        connection.close();
        domain.close();
        await auth.close();
        await helper.close();
        await server.close(force: true);
        store.close();
        root.deleteSync(recursive: true);
      });
      await auth.configureGranola();
      await auth.signIn((authorization) async {
        final redirect = Uri.parse(authorization.queryParameters['redirect']!);
        auth.completeGranolaSignIn(
          redirect.replace(
            queryParameters: {
              ...redirect.queryParameters,
              'open-url': Uri(
                scheme: 'granola',
                host: 'login-complete',
                queryParameters: {'code': 'snapshot-fixture-code'},
              ).toString(),
            },
          ),
        );
      });
      Map<String, dynamic> event(String id) => {
        'id': id,
        'calendarId': 'work',
        'summary': 'Owned calendar $id',
        'start': {'dateTime': '2026-10-22T09:00:00Z'},
        'end': {'dateTime': '2026-10-22T10:00:00Z'},
      };
      snapshot = {
        'results': {
          'events': [event('kept')],
        },
      };
      await connection.syncCalendar();
      final before = store
          .rows('SELECT * FROM calendar_events')
          .map(Map.of)
          .toList();
      expect(before, hasLength(1));
      snapshot = {
        'results': {
          'events': [
            event('new'),
            {'calendarId': 'work'},
          ],
        },
      };
      await expectLater(
        connection.syncCalendar(),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'reason',
            contains('invalid calendar event'),
          ),
        ),
      );
      expect(store.rows('SELECT * FROM calendar_events'), before);
      snapshot = {'results': {}};
      await expectLater(
        connection.syncCalendar(),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'reason',
            contains('snapshot'),
          ),
        ),
      );
      expect(store.rows('SELECT * FROM calendar_events'), before);
      snapshot = {
        'results': {
          'events': [
            event('kept'),
            {
              ...event('declined'),
              'attendees': [
                {'self': false, 'responseStatus': 'declined'},
                {'self': true, 'responseStatus': 'declined'},
              ],
            },
          ],
        },
      };
      await connection.syncCalendar();
      expect(store.rows('SELECT * FROM calendar_events'), hasLength(1));
      expect(store.rows('SELECT * FROM meetings'), hasLength(1));
      expect(snapshots, 4);
    },
  );
}
