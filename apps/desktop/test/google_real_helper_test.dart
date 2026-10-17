import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_foresight/domain.dart';
import 'package:open_foresight/google_auth.dart';
import 'package:open_foresight/google_connections.dart';
import 'package:open_foresight/helper.dart';
import 'package:open_foresight/store.dart';
import 'package:open_foresight/generated/rag_service.pbgrpc.dart';
import '../../../packages/foresight_core/test/fixtures/google_connections.dart'
    show GoogleFixture;

void main() {
  test(
    'OAuth Drive and Calendar adapter feed real helper retrieval and remove canceled context',
    () async {
      final directory = Directory.systemTemp.createTempSync(
        'foresight-google-real-',
      );
      Process.runSync('chmod', ['700', directory.path]);
      final fixture = GoogleFixture();
      await fixture.start();
      final auth = GoogleAuth(
        Directory('${directory.path}/google'),
        endpoints: fixture.endpoints,
      );
      final store = Store('${directory.path}/app.db'),
          helper = Helper(
            '${directory.path}/helper.sock',
            '${directory.path}/helper',
          );
      final domain = Domain(store, helper),
          connection = GoogleConnections(domain, auth);
      try {
        final config = File('${directory.path}/client.json')
          ..writeAsStringSync(
            jsonEncode({
              'installed': {
                'client_id': '123-fixture.apps.googleusercontent.com',
              },
            }),
          );
        await store.register(
          'embedding',
          Platform.environment['FORESIGHT_EMBEDDING']!,
          '',
        );
        helper.onReady = domain.resume;
        await helper.start();
        await auth.configure(config);
        await auth.signIn(fixture.consent);
        await connection.importDriveFolder('folder');
        await connection.syncCalendar();
        expect(store.sources.every((row) => row['state'] == 'indexed'), true);
        final doc = store.sources
            .where((row) => row['title'] == 'Apollo')
            .single;
        final result = await helper.client.retrieveContext(
          RetrieveRequest(
            query: Query(textQuery: 'When does Apollo launch?'),
            userId: 'local_user',
            allowedDocumentIds: [doc['id'] as String],
            maxResults: 3,
          ),
        );

        expect(result.chunks, isNotEmpty);
        expect(result.chunks.first.text.toLowerCase(), contains('friday'));
        fixture.document = 'Apollo launches Monday.';
        fixture.modified = 'v2';
        fixture.newFolderFile = true;
        await connection.refresh();
        final added = store.sources
            .where((row) => row['title'] == 'Slides')
            .single;
        final addedResult = await helper.client.retrieveContext(
          RetrieveRequest(
            query: Query(textQuery: 'Slides about Apollo'),
            userId: 'local_user',
            allowedDocumentIds: [added['id'] as String],
            maxResults: 3,
          ),
        );
        expect(addedResult.chunks, isNotEmpty);
        await domain.delete(added['id'] as String);
        await connection.refresh();
        final deletedResult = await helper.client.retrieveContext(
          RetrieveRequest(
            query: Query(textQuery: 'Slides about Apollo'),
            userId: 'local_user',
            allowedDocumentIds: [added['id'] as String],
            maxResults: 3,
          ),
        );
        expect(deletedResult.chunks, isEmpty);
        final refreshed = await helper.client.retrieveContext(
          RetrieveRequest(
            query: Query(textQuery: 'When does Apollo launch?'),
            userId: 'local_user',
            allowedDocumentIds: [doc['id'] as String],
            maxResults: 3,
          ),
        );
        expect(refreshed.chunks.first.text.toLowerCase(), contains('monday'));
        expect(
          refreshed.chunks.first.text.toLowerCase(),
          isNot(contains('friday')),
        );
        final calendar = store.sources
            .where((row) => row['title'] == '[Calendar] Planning')
            .single;
        fixture.cancelledEvent = true;
        await connection.syncCalendar();
        final removed = await helper.client.retrieveContext(
          RetrieveRequest(
            query: Query(textQuery: 'Planning meeting'),
            userId: 'local_user',
            allowedDocumentIds: [calendar['id'] as String],
            maxResults: 3,
          ),
        );
        expect(removed.chunks, isEmpty);
        final report = Platform.environment['FORESIGHT_GOOGLE_REPORT'];
        if (report != null)
          File(report).writeAsStringSync(
            const JsonEncoder.withIndent('  ').convert({
              'workflow':
                  'Loopback OAuth/Drive/Calendar protocol fixtures -> actual EmbeddingGemma helper -> filtered retrieval',
              'drive_and_calendar_sources_indexed': true,
              'remote_edit_replaced_old_retrieval': true,
              'cancelled_calendar_context_removed': true,
              'folder_refresh_discovered_new_file_and_indexed_it': true,
              'folder_refresh_preserved_user_deletion_and_excluded_retrieval':
                  true,
              'identity': 'fixture@example.test',
              'limitation':
                  'This test uses protocol fixtures; live Google account acceptance is recorded separately in google-live-account.json.',
            }),
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
    skip: Platform.environment['FORESIGHT_GOOGLE_REAL_HELPER'] != '1',
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
