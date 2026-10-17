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
  Future<void> forget() =>
      throw FileSystemException('Credential deletion failed');
}

void main() {
  late Directory directory;
  late Store store;
  late Helper helper;
  late Domain domain;
  late Application app;
  late ToolRuntime runtime;
  setUp(() {
    directory = Directory.systemTemp.createTempSync('workspace-clear-');
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
  tearDown(() async {
    await app.close();
    domain.close();
    runtime.close();
    await helper.close();
    store.close();
    directory.deleteSync(recursive: true);
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
      final auth = GoogleAuth(
        authDirectory,
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
            .timeout(const Duration(seconds: 2));
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
          await rag.deleted.future.timeout(const Duration(seconds: 2));
          await revoked.future.timeout(const Duration(seconds: 2));
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
      final auth = GoogleAuth(
        authDirectory,
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
    'credential deletion failure does not leave workspace commands gated',
    () async {
      await app.close();
      app = Application(
        domain,
        auth: FailingForgetAuth(Directory('${directory.path}/google')),
      );
      await expectLater(
        app.call('workspace.clear', {}),
        throwsA(isA<FileSystemException>()),
      );
      expect(await app.call('notes.list', {}), isEmpty);
    },
  );
}
