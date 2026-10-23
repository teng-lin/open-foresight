import 'package:foresight_test_support/test_paths.dart';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import '../test_support/core_fixture.dart';

import 'package:foresight_test_support/google_connections.dart'
    show GoogleFixture;

void main() {
  test(
    'OAuth Drive retrieval excludes calendar metadata',
    () async {
      final directory = createTestTempDirectorySync('foresight-google-real-');
      addTearDown(() {
        if (directory.existsSync()) directory.deleteSync(recursive: true);
      });
      Process.runSync('chmod', ['700', directory.path]);
      final fixture = GoogleFixture();
      await fixture.start();
      final auth = GoogleAuth(
        Directory('${directory.path}/google'),
        secretStore: const UnavailableSecretStore(),
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
        // Exercise explicit multi-selection, including a failed second download
        // and retry, through HTTP export and the actual embedding helper.
        await connection.importDriveFile('doc');
        fixture.exportDeniedFiles.add('sheet');
        await expectLater(
          connection.importDriveFile('sheet'),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'file error',
              contains('Sheet: This file cannot be downloaded'),
            ),
          ),
        );
        expect(store.sources.single['state'], 'indexed');
        fixture.exportDeniedFiles.clear();
        await connection.importDriveFile('sheet');
        expect(store.sources, hasLength(2));
        expect(store.sources.every((row) => row['state'] == 'indexed'), isTrue);
        fixture.restrictedFiles.add('sheet');
        await expectLater(
          connection.importDriveFile('sheet'),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'restriction',
              contains('Google Drive does not allow downloading'),
            ),
          ),
        );
        fixture.restrictedFiles.clear();
        for (final row in store.sources) {
          final retrieved = await helper.client.retrieveContext(
            RetrieveRequest(
              query: Query(
                textQuery: row['title'] == 'Sheet'
                    ? 'Who owns Review?'
                    : 'When does Apollo launch?',
              ),
              userId: 'local_user',
              allowedDocumentIds: [row['id'] as String],
              maxResults: 3,
            ),
          );
          expect(retrieved.chunks, isNotEmpty);
          expect(
            retrieved.chunks.first.text,
            contains(row['title'] == 'Sheet' ? 'Ravi' : 'Friday'),
          );
        }
        await connection.importDriveFolder('folder');
        await connection.syncCalendar();
        expect(store.sources.every((row) => row['state'] == 'indexed'), true);
        expect(
          store.sources.any(
            (row) =>
                row['provenance'].toString().startsWith('google-calendar:'),
          ),
          isFalse,
        );
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
        fixture.cancelledEvent = true;
        await connection.syncCalendar();
        expect(
          store.sources.map((source) => source['title']),
          unorderedEquals(['Apollo', 'Sheet']),
        );
        expect(
          store.rows('SELECT status FROM calendar_events').single['status'],
          'cancelled',
        );
        final report = Platform.environment['FORESIGHT_GOOGLE_REPORT'];
        if (report != null)
          File(report).writeAsStringSync(
            const JsonEncoder.withIndent('  ').convert({
              'workflow':
                  'Loopback OAuth/Drive/Calendar protocol fixtures -> actual EmbeddingGemma helper -> filtered retrieval',
              'drive_sources_indexed_calendar_metadata_excluded': true,
              'two_selected_exports_indexed_partial_failure_and_retry': true,
              'remote_edit_replaced_old_retrieval': true,
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
