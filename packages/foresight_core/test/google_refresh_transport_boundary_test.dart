import 'sql_support_test_bootstrap.dart';
import 'dart:convert';
import 'dart:io';

import 'package:foresight_core/src/google_auth.dart';
import 'package:foresight_core/src/google_connections.dart';
import 'package:foresight_core/src/helper.dart';
import 'package:foresight_core/src/rpc_error.dart';
import 'package:foresight_core/src/store.dart';
import 'package:foresight_test_support/google_connections.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';

void main() {
  bootstrapSqlSupportFixture();
  test(
    'refresh aggregates independent failures, preserves content, and later reconciles remote trash',
    () async {
      final root = createTestTempDirectorySync('google-refresh-boundaries-');
      final fixture = GoogleFixture();
      await fixture.start();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var failRefresh = false,
          trashed = false,
          listDocument = false,
          cancelExport = false,
          current = true;
      final metadata = fixture.file(
        'doc',
        'Owned document',
        'application/vnd.google-apps.document',
      );
      server.listen((request) async {
        expect(
          request.headers.value('authorization'),
          startsWith('Bearer fixture-access'),
        );
        request.response.headers.contentType = ContentType.json;
        Object response;
        if (failRefresh) {
          request.response.statusCode = 503;
          response = {
            'error': {'message': 'local ${request.uri.path} unavailable'},
          };
        } else if (request.uri.path.endsWith('/export')) {
          if (cancelExport) {
            current = false;
            request.response.statusCode = 403;
            response = {
              'error': {'message': 'local export refused'},
            };
          } else {
            request.response.headers.contentType = ContentType.text;
            request.response.write('Previously committed import');
            await request.response.close();
            return;
          }
        } else if (request.uri.path == '/drive/files') {
          response = {
            'files': [if (listDocument) metadata],
          };
        } else if (request.uri.path.startsWith('/drive/files/')) {
          response = {...metadata, 'trashed': trashed};
        } else {
          response = {'items': []};
        }
        request.response.write(jsonEncode(response));
        await request.response.close();
      });
      final base = Uri.parse('http://127.0.0.1:${server.port}/');
      final auth = GoogleAuth(
        Directory('${root.path}/google'),
        secretStore: const UnavailableSecretStore(),
        endpoints: GoogleEndpoints(
          authorize: fixture.endpoints.authorize,
          token: fixture.endpoints.token,
          userinfo: fixture.endpoints.userinfo,
          revoke: fixture.endpoints.revoke,
          drive: base.resolve('drive/'),
          calendar: base.resolve('calendar/'),
        ),
      )..client = GoogleClient('fixture.apps.googleusercontent.com', '');
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
        await fixture.close();
        store.close();
        root.deleteSync(recursive: true);
      });
      await auth.signIn(fixture.consent);
      await connection.importDriveFile('doc', metadata: metadata);
      await connection.importDriveFolder('folder');
      final before = Map.of(store.sources.single);
      failRefresh = true;
      await expectLater(
        connection.refresh(),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'failures',
            allOf(
              contains('Drive refresh:'),
              contains('Drive folder refresh:'),
              contains('Calendar refresh:'),
            ),
          ),
        ),
      );
      expect(connection.syncing, isFalse);
      expect(store.sources.single['content'], before['content']);
      expect(store.sources.single['deleted'], 0);
      expect(connection.lastCompletedRefreshMs, 0);
      failRefresh = false;
      listDocument = true;
      metadata['modifiedTime'] = 'changed';
      cancelExport = true;
      await expectLater(
        connection.importDriveFolder('folder', current: () => current),
        throwsA(
          isA<RpcError>().having((e) => e.code, 'code', RpcErrorCode.cancelled),
        ),
      );
      expect(store.sources.single['content'], before['content']);
      current = true;
      cancelExport = false;
      listDocument = false;
      trashed = true;
      await connection.refresh();
      expect(store.sources, isEmpty);
      expect(
        store.rows('SELECT deleted FROM sources WHERE id=?', [
          before['id'],
        ]).single['deleted'],
        1,
      );
      expect(connection.lastCompletedRefreshMs, greaterThan(0));
    },
  );
}
