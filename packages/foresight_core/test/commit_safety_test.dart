import 'package:foresight_test_support/test_paths.dart';
import 'package:foresight_test_support/google_connections.dart'
    show AdapterDomain;
import 'dart:io';

import 'package:foresight_core/foresight_core.dart';
import 'package:foresight_core/src/application.dart';
import 'package:foresight_core/src/rpc_error.dart';
import 'package:test/test.dart';

Matcher throwsRpc(RpcErrorCode code, [Object? message]) => throwsA(
  isA<RpcError>()
      .having((error) => error.code, 'code', code)
      .having((error) => error.message, 'message', message ?? anything),
);

void main() {
  group('application', () {
    late Directory directory;
    late Store store;
    late Helper helper;
    late AdapterDomain domain;
    late Application app;
    setUp(() {
      directory = createTestTempDirectorySync('commit-safety-');
      store = Store('${directory.path}/app.db');
      helper = Helper(
        '${directory.path}/unused.sock',
        '${directory.path}/helper',
        manageProcess: false,
      );
      domain = AdapterDomain(store, helper);
      app = Application(
        domain,
        auth: GoogleAuth(
          Directory('${directory.path}/google'),
          secretStore: const UnavailableSecretStore(),
        ),
      );
    });
    tearDown(() async {
      await app.close();
      domain.close();
      await helper.close();
      store.close();
    });

    Future<Map> call(String method, [Map<String, dynamic> args = const {}]) =>
        app.call(method, args).then((value) => value as Map);
    int changes() =>
        store.rows('SELECT total_changes() AS n').single['n'] as int;

    test(
      'saving a note that no longer exists fails and writes nothing',
      () async {
        final id = (await call('notes.save', {
          'title': 'Kept',
          'body': 'v1',
        }))['id'];
        store.db.execute('DELETE FROM notes WHERE id=?', [id]);
        final before = changes();
        await expectLater(
          app.call('notes.save', {'id': id, 'title': 'Lost', 'body': 'v2'}),
          throwsRpc(RpcErrorCode.notFound, 'This note no longer exists.'),
        );
        expect(changes(), before);
        expect(store.rows('SELECT * FROM notes'), isEmpty);
      },
    );

    test(
      'mutations of rows that no longer exist fail instead of writing nothing',
      () async {
        final meeting = (await call('meetings.create', {
          'title': 'Kept',
        }))['id'];
        for (final (method, args) in <(String, Map<String, dynamic>)>[
          ('artifacts.edit', {'id': 99, 'text': 'Lost'}),
          (
            'labels.set',
            {
              'id': 'gone',
              'labels': ['Lost'],
            },
          ),
          (
            'labels.put',
            {'id': 'gone', 'name': 'Lost', 'source': 'user_defined'},
          ),
          ('meetings.link_answer', {'id': 99, 'answer': 1}),
          ('meetings.link_answer', {'id': meeting, 'answer': 99}),
          ('sources.index', {'id': 'gone'}),
          ('meetings.enhance', {'id': 99}),
          ('meetings.generate', {'id': 99, 'kind': 'enhanced_notes'}),
        ]) {
          final before = changes();
          await expectLater(
            app.call(method, args),
            throwsRpc(RpcErrorCode.notFound),
            reason: '$method $args',
          );
          expect(changes(), before, reason: method);
        }
      },
    );
  });
}
