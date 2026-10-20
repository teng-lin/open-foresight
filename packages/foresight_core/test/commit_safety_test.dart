import 'package:foresight_test_support/test_paths.dart';
import 'package:foresight_test_support/google_connections.dart'
    show AdapterDomain;
import 'dart:io';

import 'package:foresight_core/foresight_core.dart';
import 'package:foresight_core/src/application.dart';
import 'package:foresight_core/src/rpc_error.dart';
import 'package:foresight_core/src/service.dart';
import 'package:test/test.dart';

const clearedMessage = 'This item was removed when the workspace was cleared.';

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
    Future<Object?> epoch() async => (await call('status'))['workspace_epoch'];
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
      'a stale editor cannot overwrite a new note that reuses its ID',
      () async {
        final staleEpoch = await epoch();
        final stale = (await call('notes.save', {
          'title': 'Before',
          'body': 'old',
        }))['id'];
        await app.call('workspace.clear', {});
        final fresh = (await call('notes.save', {
          'title': 'After',
          'body': 'new',
        }))['id'];
        expect(fresh, stale, reason: 'SQLite reuses the ID after a clear');
        await expectLater(
          app.call('notes.save', {
            'id': stale,
            'title': 'Before',
            'body': 'stale edit',
            'workspace_epoch': staleEpoch,
          }),
          throwsRpc(RpcErrorCode.notFound, clearedMessage),
        );
        expect(store.rows('SELECT title,body,revision FROM notes').single, {
          'title': 'After',
          'body': 'new',
          'revision': 1,
        });
        await app.call('notes.save', {
          'id': fresh,
          'title': 'After',
          'body': 'edited',
          'workspace_epoch': await epoch(),
        });
        expect(store.rows('SELECT body FROM notes').single['body'], 'edited');
      },
    );

    test(
      'the epoch is stable, persistent and renewed only by a clear',
      () async {
        final first = await epoch();
        expect(first, matches(RegExp(r'^[0-9a-f]{32}$')));
        expect(await epoch(), first);
        final reopened = Store(store.path);
        try {
          expect(
            reopened
                .rows(
                  "SELECT value FROM preferences WHERE key='workspaceEpoch'",
                )
                .single['value'],
            first,
          );
        } finally {
          reopened.close();
        }
        await app.call('workspace.clear', {});
        final second = await epoch();
        expect(second, matches(RegExp(r'^[0-9a-f]{32}$')));
        expect(second, isNot(first));
        await expectLater(
          app.call('notes.list', {'workspace_epoch': 42}),
          throwsRpc(RpcErrorCode.invalidArgument),
        );
      },
    );

    test('ID-based mutations reject a stale epoch before writing', () async {
      final staleEpoch = await epoch();
      await app.call('workspace.clear', {});
      final meeting = (await call('meetings.create', {'title': 'New'}))['id'];
      final note = (await call('notes.save', {
        'title': 'New',
        'body': '',
      }))['id'];
      final source = (await call('sources.import', {
        'title': 'New',
        'text': 'Body',
        'index': false,
      }))['id'];
      store.artifact(meeting as int, 'summary', 'Generated', 'fixture');
      final artifact = store.db.lastInsertRowId;
      store.answer('Question', 'Answer', 'completed', [], 'fixture');
      final answer = store.db.lastInsertRowId;
      for (final (method, args) in <(String, Map<String, dynamic>)>[
        ('notes.save', {'id': note, 'title': 'Stale', 'body': 'Stale'}),
        ('meetings.notes', {'id': meeting, 'body': 'Stale'}),
        ('meetings.transcript', {'id': meeting, 'text': 'Stale'}),
        ('artifacts.edit', {'id': artifact, 'text': 'Stale'}),
        ('meetings.link_answer', {'id': meeting, 'answer': answer}),
        (
          'labels.set',
          {
            'id': source,
            'labels': ['Stale'],
          },
        ),
        (
          'labels.put',
          {'id': source, 'name': 'Stale', 'source': 'user_defined'},
        ),
        ('sources.import', {'id': source, 'title': 'Stale', 'text': 'Stale'}),
        ('sources.delete', {'id': source}),
      ]) {
        final before = changes();
        await expectLater(
          app.call(method, {...args, 'workspace_epoch': staleEpoch}),
          throwsRpc(RpcErrorCode.notFound, clearedMessage),
          reason: method,
        );
        expect(changes(), before, reason: method);
      }
      expect(store.rows('SELECT body FROM notes').single['body'], '');
      expect(store.sources.single['title'], 'New');
    });

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

  group('service', () {
    late Directory temp;
    late ProfilePaths profile;
    late Map<String, String> original;
    setUp(() {
      original = Map.of(runtimeConfiguration.environment);
      for (final key in [
        'FORESIGHT_HELPER',
        'FORESIGHT_NATIVE',
        'FORESIGHT_RUNTIME_REVISION',
        'FORESIGHT_INSTALL_ROOT',
      ]) {
        runtimeConfiguration.environment.remove(key);
      }
      temp = createTestTempDirectorySync('of-commit-');
      profile = ProfilePaths('${temp.path}/profile', '${temp.path}/run');
    });
    tearDown(() {
      runtimeConfiguration.environment
        ..clear()
        ..addAll(original);
    });

    Future<T> serve<T>(Future<T> Function(ServiceClient) body) async {
      final service = await ApplicationService.start(profile);
      try {
        final client = await ServiceClient.connect(service.path);
        try {
          return await body(client);
        } finally {
          await client.close();
        }
      } finally {
        await service.close();
      }
    }

    test('a stale workspace epoch is still rejected after a restart', () async {
      final (stale, note, cleared) = await serve((client) async {
        await client.call('security.attach_desktop', {
          'token': File(
            '${profile.data}/.desktop-capability',
          ).readAsStringSync(),
        });
        final stale = (await client.call('status') as Map)['workspace_epoch'];
        final note =
            (await client.call('notes.save', {'title': 'Before', 'body': 'old'})
                as Map)['id'];
        await client.call('workspace.clear');
        final cleared = (await client.call('status') as Map)['workspace_epoch'];
        return (stale, note, cleared);
      });
      await serve((client) async {
        final fresh =
            (await client.call('notes.save', {'title': 'After', 'body': 'new'})
                as Map)['id'];
        expect(fresh, note);
        await expectLater(
          client.call('notes.save', {
            'id': note,
            'title': 'Before',
            'body': 'stale edit',
            'workspace_epoch': stale,
          }),
          throwsRpc(RpcErrorCode.notFound, clearedMessage),
        );
        expect(
          (await client.call('notes.list') as List).map((n) => n['body']),
          ['new'],
        );
        expect(
          (await client.call('status') as Map)['workspace_epoch'],
          cleared,
        );
      });
      expect(stale, isA<String>());
      expect(cleared, isNot(stale));
    });
  });
}
