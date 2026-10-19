import 'package:foresight_test_support/test_paths.dart';
import 'package:foresight_test_support/poll.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:foresight_core/foresight_core.dart';
import 'package:foresight_core/src/application.dart';
import 'package:foresight_core/src/generated/rag_service.pbgrpc.dart';
import 'package:grpc/grpc.dart';
import 'package:test/test.dart';
import 'package:sqlite3/sqlite3.dart';

import 'web_answer_test.dart' show ToolRuntime, fixtureSearch;

class ClearRag extends RagServiceBase {
  final Store store;
  final deleted = Completer<void>();
  ClearRag(this.store);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
  @override
  Future<DeleteResponse> deleteDocument(
    ServiceCall call,
    DeleteRequest request,
  ) async {
    expect(store.sources, isEmpty);
    expect(store.rows('SELECT * FROM conversation_memory'), isEmpty);
    if (!deleted.isCompleted) deleted.complete();
    return DeleteResponse(success: true);
  }
}

class FailingForgetAuth extends GoogleAuth {
  FailingForgetAuth(super.directory);
  @override
  Future<void> forget() async {
    await Future<void>.delayed(Duration.zero);
    throw FileSystemException('Credential deletion failed');
  }
}

class RejectingDeleteSecretStore implements SecretStore {
  final deleted = Completer<void>();
  @override
  Future<bool> write(String key, String value) async => true;
  @override
  Future<String?> read(String key) async => 'fixture-refresh-token';
  @override
  Future<void> delete(String key) async {
    await Future<void>.delayed(Duration.zero);
    deleted.complete();
    throw FileSystemException('Platform credential deletion failed');
  }
}

void main() {
  late Directory directory;
  late Store store;
  late Helper helper;
  late Domain domain;
  late Application app;
  late ToolRuntime runtime;
  setUp(() {
    directory = createTestTempDirectorySync('workspace-clear-');
    store = Store('${directory.path}/app.db');
    helper = Helper(
      '${directory.path}/unused.sock',
      '${directory.path}/helper',
      manageProcess: false,
    );
    runtime = ToolRuntime()..answer = (_) async => 'DELETED SECRET';
    domain = Domain(store, helper, webSearch: fixtureSearch())
      ..generator = runtime;
    app = Application(domain);
  });
  setUp(() {
    addTearDown(() async {
      await app.close();
      domain.close();
      runtime.close();
      await helper.close();
      store.close();
      directory.deleteSync(recursive: true);
    });
  });

  test(
    'clear removes planted private bytes from the database and WAL',
    () async {
      const marker = 'PRIVATE_CLEAR_MARKER_7bb6cec7_';
      store.importText('Secret', marker * 200, 'text/plain', 'fixture');
      store.saveNote(null, 'Secret', marker * 200);
      await app.call('workspace.clear', {});
      expect(store.rows('PRAGMA secure_delete').single.values.single, 1);
      for (final path in [store.path, '${store.path}-wal']) {
        final file = File(path);
        if (file.existsSync()) {
          expect(
            latin1.decode(file.readAsBytesSync()),
            isNot(contains(marker)),
            reason: path,
          );
        }
      }
    },
  );

  test(
    'clear retries WAL erasure after a real reader releases its snapshot',
    () async {
      const marker = 'PRIVATE_PINNED_WAL_MARKER_38c1_';
      store.saveNote(null, 'Private', marker * 200);
      final reader = sqlite3.open(store.path, mode: OpenMode.readOnly);
      try {
        reader.execute('BEGIN');
        expect(
          reader.select('SELECT body FROM notes').single['body'],
          marker * 200,
        );
        await app.call('workspace.clear', {});
        expect(store.notes(), isEmpty);
        expect(store.privacyMaintenancePending, isTrue);
        expect(
          store
              .rows(
                "SELECT value FROM preferences WHERE key='internal.privacyMaintenancePending'",
              )
              .single['value'],
          '1',
        );
        // The old snapshot is still usable and keeps the private WAL frames live.
        expect(
          reader.select('SELECT body FROM notes').single['body'],
          marker * 200,
        );
        expect(
          latin1.decode(File('${store.path}-wal').readAsBytesSync()),
          contains(marker),
        );
        reader.execute('COMMIT');
        await eventually(() => !store.privacyMaintenancePending);
        expect(
          store.rows(
            "SELECT 1 FROM preferences WHERE key='internal.privacyMaintenancePending'",
          ),
          isEmpty,
        );
        for (final path in [store.path, '${store.path}-wal']) {
          final file = File(path);
          if (file.existsSync()) {
            expect(
              latin1.decode(file.readAsBytesSync()),
              isNot(contains(marker)),
              reason: path,
            );
          }
        }
      } finally {
        if (!reader.autocommit) reader.execute('ROLLBACK');
        reader.dispose();
      }
    },
  );

  test('every schema table is cleared or explicitly retained', () async {
    final cleared = Application.workspaceContentTables.toSet();
    const exemptions = {
      'models', // Installed model configuration survives workspace clear.
      'preferences', // Non-content settings survive; content preference keys are removed.
      'pending_helper_deletes', // Durable cleanup queue must outlive the clear.
    };
    final tables = store
        .rows(
          "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'",
        )
        .map((row) => row['name'])
        .toSet();
    expect(tables, {...cleared, ...exemptions});
    await app.call('workspace.clear', {});
    for (final table in cleared) {
      expect(store.rows('SELECT * FROM $table'), isEmpty, reason: table);
    }
  });

  for (final online in [true, false]) {
    test('clear removes checkpoints across reopen, online=$online', () async {
      await domain.askWithWebInConversation('Secret question', 'desktop').last;
      await domain.askWithWebInConversation('Remember it', 'desktop').last;
      final meeting = store.meeting('Private meeting');
      store.transcript(meeting, 'DELETED SECRET', true, 0, 1, 'imported');
      store.saveMeetingNotes(meeting, 'DELETED SECRET');
      store.importText(
        'Private source',
        'DELETED SECRET',
        'text/plain',
        'test',
      );
      expect(store.rows('SELECT * FROM conversation_memory'), hasLength(1));
      final google = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final revoke = Uri.parse('http://127.0.0.1:${google.port}/revoke');
      final revoked = Completer<void>(), releaseRevoke = Completer<void>();
      if (online) {
        google.listen((request) async {
          expect(store.sources, isEmpty);
          expect(store.rows('SELECT * FROM conversation_memory'), isEmpty);
          expect(
            File('${directory.path}/google/tokens.json').existsSync(),
            isFalse,
          );
          revoked.complete();
          await releaseRevoke.future;
          request.response.statusCode = 503;
          await request.response.close();
        });
      } else {
        await google.close(force: true);
      }
      final authDirectory = Directory('${directory.path}/google')..createSync();
      File('${authDirectory.path}/tokens.json').writeAsStringSync(
        jsonEncode({
          'access_token': 'test-access',
          'refresh_token': 'test-refresh',
          'account_sub': 'test-account',
          'expires_at': 1,
        }),
      );
      await Process.run('/bin/chmod', ['700', authDirectory.path]);
      await Process.run('/bin/chmod', [
        '600',
        '${authDirectory.path}/tokens.json',
      ]);
      final auth = GoogleAuth(
        authDirectory,
        secretStore: const UnavailableSecretStore(),
        endpoints: GoogleEndpoints(revoke: revoke),
      );
      await app.close();
      app = Application(domain, auth: auth);
      final rag = ClearRag(store);
      final server = Server.create(services: [rag]);
      if (online) {
        await server.serve(
          address: InternetAddress(
            helper.socket,
            type: InternetAddressType.unix,
          ),
          port: 0,
        );
      }
      try {
        await app
            .call('workspace.clear', {})
            .timeout(const Duration(seconds: 10));
        expect(auth.connected, isFalse);
        expect(File('${authDirectory.path}/tokens.json').existsSync(), isFalse);
        for (final table in [
          'sources',
          'answers',
          'conversation_memory',
          'meetings',
          'transcript',
          'meeting_notes',
        ]) {
          expect(store.rows('SELECT * FROM $table'), isEmpty, reason: table);
        }
        if (online) {
          await rag.deleted.future.timeout(const Duration(seconds: 10));
          await revoked.future.timeout(const Duration(seconds: 10));
          releaseRevoke.complete();
        }
        await app.close();
        domain.close();
        store.close();
        store = Store('${directory.path}/app.db');
        domain = Domain(store, helper, webSearch: fixtureSearch())
          ..generator = runtime;
        app = Application(domain);
        runtime.histories.clear();
        runtime.answer = (_) async => 'New answer';
        await domain.askWithWebInConversation('New first', 'desktop').last;
        await domain.askWithWebInConversation('New second', 'desktop').last;
        expect(runtime.histories.first, isEmpty);
        final replay = jsonEncode(runtime.histories.last);
        expect(replay, contains('New first'));
        expect(replay, isNot(contains('DELETED SECRET')));
        final checkpoint = store
            .rows('SELECT * FROM conversation_memory')
            .single;
        expect(checkpoint['through_answer_id'], 2);
        expect(checkpoint['messages'], isNot(contains('DELETED SECRET')));
        final reopenedAuth = GoogleAuth(authDirectory);
        expect(reopenedAuth.connected, isFalse);
        await reopenedAuth.close();
      } finally {
        if (!releaseRevoke.isCompleted) releaseRevoke.complete();
        await server.shutdown();
        if (online) await google.close(force: true);
      }
    });
  }

  test(
    'clearing removes safe-web markers before local answer IDs can be reused',
    () async {
      await domain.askWithWebInConversation('Old web question', 'desktop').last;
      expect(store.preference('webAnswer.v1.1'), 'true');
      await app.call('workspace.clear', {});
      expect(
        store.rows(
          "SELECT key FROM preferences WHERE key GLOB 'webAnswer.v1.*'",
        ),
        isEmpty,
      );
      store.answer(
        'Local question',
        'LOCAL_REUSED_ID_SECRET',
        'completed',
        [],
        'local',
        conversation: 'desktop',
      );
      expect(store.db.lastInsertRowId, 1);
      runtime.answer = (_) async => 'Safe fresh answer';
      await domain
          .askWithWebInConversation('Fresh explicit web query', 'desktop')
          .last;
      expect(runtime.histories.last, isEmpty);
    },
  );

  test(
    'an in-flight answer cannot recreate cleared answers or checkpoints',
    () async {
      await domain.askWithWebInConversation('Old question', 'desktop').last;
      final entered = Completer<void>(), release = Completer<void>();
      runtime.answer = (_) async {
        entered.complete();
        await release.future;
        return 'DELETED SECRET';
      };
      final pending = expectLater(
        domain.askWithWebInConversation('Old follow-up', 'desktop').last,
        throwsStateError,
      );
      await entered.future;
      await app.call('workspace.clear', {});
      release.complete();
      await pending;
      expect(store.rows('SELECT * FROM answers'), isEmpty);
      expect(store.rows('SELECT * FROM conversation_memory'), isEmpty);
      runtime.answer = (_) async => 'Fresh answer';
      await domain.askWithWebInConversation('Fresh question', 'desktop').last;
      expect(runtime.histories.last, isEmpty);
    },
  );

  test('an in-flight URL import cannot restore a cleared source', () async {
    final entered = Completer<void>(), release = Completer<void>();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      entered.complete();
      await release.future;
      request.response.headers.contentType = ContentType.text;
      request.response.write('DELETED SECRET');
      await request.response.close();
    });
    try {
      final pending = expectLater(
        app.importUrl(
          'http://127.0.0.1:${server.port}/private',
          allowPrivateNetwork: true,
        ),
        throwsStateError,
      );
      await entered.future;
      await app.call('workspace.clear', {});
      release.complete();
      await pending;
      expect(store.sources, isEmpty);
    } finally {
      if (!release.isCompleted) release.complete();
      await server.close(force: true);
    }
  });
  test('a locked database does not leave workspace commands gated', () async {
    final other = sqlite3.open(store.path);
    other.execute('BEGIN IMMEDIATE');
    try {
      await expectLater(
        app.call('workspace.clear', {}),
        throwsA(isA<SqliteException>()),
      );
      expect(await app.call('notes.list', {}), isEmpty);
    } finally {
      other.execute('ROLLBACK');
      other.dispose();
    }
    await app.call('workspace.clear', {});
  });

  test(
    'a delayed Google refresh cannot restore forgotten credentials',
    () async {
      final entered = Completer<void>(), release = Completer<void>();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        if (request.uri.path == '/token') {
          await request.drain<void>();
          entered.complete();
          await release.future;
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode({'access_token': 'late-secret', 'expires_in': 3600}),
          );
        }
        await request.response.close();
      });
      final authDirectory = Directory('${directory.path}/google')..createSync();
      File('${authDirectory.path}/client.json').writeAsStringSync(
        jsonEncode({
          'installed': {'client_id': 'test.apps.googleusercontent.com'},
        }),
      );
      final tokens = File('${authDirectory.path}/tokens.json')
        ..writeAsStringSync(
          jsonEncode({
            'access_token': 'old-secret',
            'refresh_token': 'refresh-secret',
            'account_sub': 'test-account',
            'expires_at': 1,
          }),
        );
      final base = Uri.parse('http://127.0.0.1:${server.port}/');
      await Process.run('/bin/chmod', ['700', authDirectory.path]);
      await Process.run('/bin/chmod', [
        '600',
        '${authDirectory.path}/tokens.json',
      ]);
      final auth = GoogleAuth(
        authDirectory,
        secretStore: const UnavailableSecretStore(),
        endpoints: GoogleEndpoints(
          token: base.resolve('token'),
          revoke: base.resolve('revoke'),
        ),
      );
      await app.close();
      app = Application(domain, auth: auth);
      try {
        final pending = expectLater(
          auth.accessToken(forceRefresh: true),
          throwsStateError,
        );
        await entered.future;
        await app.call('workspace.clear', {});
        release.complete();
        await pending;
        expect(auth.connected, isFalse);
        expect(tokens.existsSync(), isFalse);
      } finally {
        if (!release.isCompleted) release.complete();
        await server.close(force: true);
      }
    },
  );
  test(
    'asynchronous secret-store deletion failure is observed after local clear',
    () async {
      await app.close();
      final authDirectory = Directory('${directory.path}/google');
      privateDirectory(authDirectory.path);
      final tokens = File('${authDirectory.path}/tokens.json')
        ..writeAsStringSync(
          jsonEncode({
            'access_token': 'fixture-access',
            'refresh_token_store': 'platform',
            'account_sub': 'fixture-account',
            'expires_at': 1,
          }),
        );
      expect(Process.runSync('/bin/chmod', ['600', tokens.path]).exitCode, 0);
      final secrets = RejectingDeleteSecretStore();
      final auth = GoogleAuth(authDirectory, secretStore: secrets);
      expect(auth.connected, isTrue);
      app = Application(domain, auth: auth);
      store.importText(
        'Secret source',
        'private content',
        'text/plain',
        'fixture',
      );
      final uncaught = <Object>[];
      await runZonedGuarded<Future<void>>(
        () async {
          await app.call('workspace.clear', {});
          await secrets.deleted.future;
          await Future<void>.delayed(Duration.zero);
        },
        (error, stack) {
          uncaught.add(error);
        },
      );
      expect(store.sources, isEmpty);
      expect(auth.connected, isFalse);
      expect(tokens.existsSync(), isFalse);
      expect(
        app.googleState['loadError'],
        contains('Google credential cleanup failed; disconnect again'),
      );
      expect(await app.call('notes.list', {}), isEmpty);
      expect(uncaught, isEmpty);
    },
  );

  test(
    'credential deletion failure does not leave workspace commands gated',
    () async {
      await app.close();
      app = Application(
        domain,
        auth: FailingForgetAuth(Directory('${directory.path}/google')),
      );
      await app.call('workspace.clear', {});
      await eventually(
        () => (app.googleState['loadError'] as String? ?? '').contains(
          'cleanup failed',
        ),
      );
      expect(app.googleState['loadError'], contains('cleanup failed'));
      expect(await app.call('notes.list', {}), isEmpty);
    },
  );
}
