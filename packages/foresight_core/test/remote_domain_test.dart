import 'package:foresight_core/src/rpc_error.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:foresight_core/foresight_core.dart';
import 'package:foresight_core/src/remote_domain.dart';
import 'package:test/test.dart';
import 'package:foresight_core/src/generated/helper_control.pb.dart' as control;

import 'package:foresight_test_support/remote_service.dart';

void main() {
  late RemoteFixture f;
  setUp(() async {
    f = RemoteFixture();
    await f.start();
  });
  tearDown(() => f.close());

  test('closing a paused workspace cancels its pending source wait', () async {
    f.event({'sources_paused': true});
    await eventually(() => f.remote.sourcesPaused);
    final pending = f.remote.waitForSourceWork();
    final cancelled = expectLater(
      pending,
      throwsA(
        isA<RpcError>().having((e) => e.code, 'code', RpcErrorCode.cancelled),
      ),
    );
    f.remote.close();
    await cancelled;
  });

  test(
    'service snapshots update capture, model, Google and pause state together',
    () async {
      var changes = 0;
      f.remote.helper.changed = () => changes++;
      f.event({
        'capture': {'meeting_id': 17, 'active': true},
        'generation': {'state': 'ready', 'generating': true},
        'google': {
          'connected': true,
          'email': 'fixture@example.test',
          'account': 'account',
          'configured': true,
          'signingIn': true,
          'loadError': 'refresh needed',
          'lastRefresh': 45,
        },
        'sources_paused': true,
        'web_search_available': true,
      });
      await eventually(() => changes == 1);
      expect(f.remote.capture['meeting_id'], 17);
      expect(f.remote.sourcesPaused, isTrue);
      expect(f.remote.webSearchAvailable, isTrue);
      final runtime = f.remote.generator!;
      expect(runtime.effectiveState['state'], 'ready');
      expect(runtime.generating, isTrue);
      runtime.close();
      final auth = RemoteGoogleAuth(f.remote);
      expect(auth.connected, isTrue);
      expect(auth.email, 'fixture@example.test');
      expect(auth.account, 'account');
      expect(auth.client, isNotNull);
      expect(auth.signingIn, isTrue);
      expect(auth.loadError, 'refresh needed');
      expect(
        RemoteGoogleConnections(f.remote, auth).lastCompletedRefreshMs,
        45,
      );
      f.event({'capture': {}, 'generation': {}, 'google': {}});
      await eventually(() => f.remote.generator == null);
      expect(f.remote.webSearchAvailable, isFalse);
      expect(auth.client, isNull);
      expect(auth.email, isEmpty);
      expect(auth.account, isEmpty);
      expect(auth.loadError, isEmpty);
      expect(auth.signingIn, isFalse);
      await auth.close();
    },
  );

  test(
    'writes are delegated while committed WAL data stays readable through the facade',
    () async {
      final id = f.owner.importText(
        'Apollo',
        'committed body',
        'text/plain',
        'fixture',
      );
      f.handler = (socket, request) {
        final args = request['args'] as Map;
        switch (request['method']) {
          case 'sources.index':
            f.owner.state(args['id'] as String, 'indexed');
          case 'sources.delete':
            f.owner.tombstone(args['id'] as String);
          case 'graph.embeddings':
            f.reply(socket, request, {
              id: [1, 2.5],
            });
            return;
        }
        f.reply(socket, request, null);
      };
      expect(f.remote.store.sources.single['content'], 'committed body');
      await f.remote.index(id);
      expect(f.remote.store.sources.single['state'], 'indexed');
      expect(await f.remote.graphEmbeddings(f.remote.store.sources), {
        id: [1.0, 2.5],
      });
      await f.remote.resume();
      await f.remote.delete(id);
      expect(f.remote.store.sources, isEmpty);
      expect(
        f.requests.where((r) => r['method'] == 'application.resume'),
        hasLength(1),
      );
    },
  );

  test(
    'pause gates source work and disposal releases a paused waiter with an error',
    () async {
      f.handler = (socket, request) => f.reply(socket, request, null);
      f.remote.pauseSources();
      var finished = false;
      final waiting = f.remote.waitForSourceWork().then((_) => finished = true);
      await eventually(
        () => f.requests.any((r) => r['method'] == 'sources.pause'),
      );
      expect(finished, isFalse);
      f.remote.resumeSources();
      await waiting;
      expect(finished, isTrue);
      f.remote.pauseSources();
      final blocked = expectLater(
        f.remote.waitForSourceWork(),
        throwsStateError,
      );
      f.remote.close();
      await blocked;
    },
  );

  test(
    'cancelled commands cancel only their outstanding service request',
    () async {
      var current = true;
      final result = f.remote.commandCurrent(Operation.sourcesImportDirectory, {
        'path': '/fixture',
      }, () => current);
      final failure = expectLater(result, throwsStateError);
      await eventually(
        () => f.requests.any((r) => r['method'] == 'sources.import_directory'),
      );
      final request = f.requests.last;
      current = false;
      await failure;
      await eventually(
        () => f.requests.any((r) => r['cancel'] == request['id']),
      );
      f.handler = (socket, request) =>
          f.reply(socket, request, {'saved': true});
      expect(
        await f.remote.commandCurrent(Operation.notesSave, {}, () => true),
        {'saved': true},
      );
      f.handler = (socket, request) => socket.writeln(
        jsonEncode({'id': request['id'], 'error': 'rejected', 'done': true}),
      );
      await expectLater(
        f.remote.commandCurrent(Operation.notesSave, {}, () => true),
        throwsStateError,
      );
    },
  );

  test(
    'answer streams preserve meeting/web scope and cancellation suppresses late text',
    () async {
      for (final web in [false, true]) {
        var current = true;
        f.handler = (socket, request) {
          expect(request['args'], {
            'question': 'Apollo?',
            'conversation': 'meeting:8',
            'meeting_id': 8,
            if (web) 'web_search': true,
          });
          f.reply(socket, request, 'first', done: false);
        };
        final stream = web
            ? f.remote.askWithWebInConversation(
                'Apollo?',
                'meeting:8',
                meetingId: 8,
                current: () => current,
              )
            : f.remote.askInConversation(
                'Apollo?',
                'meeting:8',
                meetingId: 8,
                current: () => current,
              );
        final iterator = StreamIterator(stream);
        expect(await iterator.moveNext(), isTrue);
        expect(iterator.current, 'first');
        final request = f.requests.last;
        current = false;
        f.reply(f.sockets.last, request, 'late');
        await expectLater(iterator.moveNext(), throwsStateError);
        await iterator.cancel();
        final preCancelled = web
            ? f.remote.askWithWebInConversation(
                'ignored',
                'desktop',
                current: () => false,
              )
            : f.remote.askInConversation(
                'ignored',
                'desktop',
                current: () => false,
              );
        await expectLater(preCancelled.toList(), throwsStateError);
      }
    },
  );

  test(
    'remote model cancellation reaches the active answer without closing shared runtime',
    () async {
      f.handler = (socket, request) =>
          f.reply(socket, request, 'preview', done: false);
      final iterator = StreamIterator(
        f.remote.askInConversation('Question', 'desktop', requestId: 'owner'),
      );
      expect(await iterator.moveNext(), isTrue);
      final failure = expectLater(iterator.moveNext(), throwsStateError);
      expect(f.remote.runtime.cancel(requestId: 'owner'), isTrue);
      await failure;
      await iterator.cancel();
      expect(f.remote.runtime.cancel(), isFalse);
    },
  );

  test(
    'Google facade opens only the supplied authorization URL and updates final identity',
    () async {
      final auth = RemoteGoogleAuth(f.remote);
      f.handler = (socket, request) {
        if (request['method'] == 'google.sign_in') {
          f.reply(socket, request, {
            'authorization_url': 'https://example.invalid/authorize',
          }, done: false);
          f.reply(socket, request, {
            'connected': true,
            'email': 'fixture@example.test',
          });
        } else {
          f.reply(socket, request, {'connected': false});
        }
      };
      final urls = <Uri>[];
      await auth.signIn((uri) async {
        urls.add(uri);
      });
      expect(urls.single.host, 'example.invalid');
      expect(auth.connected, isTrue);
      await auth.configure(File('/fixture/client.json'));
      expect(auth.connected, isFalse);
      await auth.disconnect();
      auth.cancelSignIn();
      await eventually(
        () => f.requests.any((r) => r['method'] == 'google.cancel_sign_in'),
      );
      f.handler = (socket, request) {
        if (request['method'] == 'google.sign_in') {
          f.reply(socket, request, {
            'authorization_url': 'https://example.invalid/authorize',
          }, done: false);
        } else {
          f.reply(socket, request, {'connected': false});
        }
      };
      await expectLater(
        auth.signIn((_) async {
          throw StateError('browser unavailable');
        }),
        throwsStateError,
      );
      expect(
        f.requests.where((r) => r['method'] == 'google.cancel_sign_in').length,
        greaterThanOrEqualTo(2),
      );
    },
  );

  test(
    'Google connections preserve query dates and read saved meeting attachments',
    () async {
      final auth = RemoteGoogleAuth(f.remote),
          connection = RemoteGoogleConnections(
            f.remote,
            RemoteGoogleAuth(f.remote),
          );
      f.handler = (socket, request) => f.reply(
        socket,
        request,
        request['method'] == 'google.drive_files'
            ? [
                {'id': 'doc'},
              ]
            : null,
      );
      final date = DateTime.utc(2025);
      expect(
        (await connection.driveFiles(
          parent: 'folder',
          query: 'Apollo',
          modifiedAfter: date,
        )).single['id'],
        'doc',
      );
      expect(f.requests.last['args'], {
        'parent': 'folder',
        'query': 'Apollo',
        'modifiedAfter': date.toIso8601String(),
      });
      await connection.importDriveFile('doc');
      await connection.importDriveFolder('folder');
      await connection.importLastYear();
      await connection.syncCalendar();
      await connection.refresh();
      await connection.importAttachments(19);
      expect(f.requests.last['args'], {'id': 19});
      expect(connection.attachments(19), isEmpty);
      f.owner.db.execute(
        "INSERT INTO meetings(id,title,state) VALUES(19,'Fixture','ready')",
      );
      f.owner.db.execute(
        "INSERT INTO calendar_events(event_key,meeting_id,metadata,account,calendar_id,google_id,source_id,starts,ends,status,synced) VALUES('fixture',?,?,'fixture','fixture','fixture','fixture',0,0,'confirmed',0)",
        [
          19,
          jsonEncode({
            'attachments': [
              {'fileId': 'doc'},
            ],
          }),
        ],
      );
      expect(connection.attachments(19).single['fileId'], 'doc');
      await connection.reminders(DateTime.now(), (_) async {
        fail('Service owns reminders');
      });
      connection.close();
      await auth.close();
    },
  );

  test(
    'abrupt service loss reconnects and refreshes snapshots without replaying a write',
    () async {
      final pending = f.remote.command(Operation.notesSave, {
        'title': 'uncertain',
        'body': 'body',
      });
      final failed = expectLater(pending, throwsStateError);
      await eventually(
        () => f.requests.any((r) => r['method'] == 'notes.save'),
      );
      f.status = {
        ...f.status,
        'web_search_available': true,
        'capture': {'state': 'reconnected'},
      };
      f.sockets.last.destroy();
      await failed;
      await eventually(() => f.remote.webSearchAvailable);
      expect(f.remote.capture['state'], 'reconnected');
      expect(
        f.requests.where((r) => r['method'] == 'notes.save'),
        hasLength(1),
      );
    },
  );

  test('recording snapshots convert numeric levels and retain route state', () {
    final snapshot = RemoteRecording({
      'finishing': true,
      'paused': true,
      'samples': [100, 200],
      'peaks': [1, .5],
      'volumes': [0, .25],
      'last_audio': 1234,
      'echo_cancellation': {'requested': true, 'active': false},
    });
    expect(snapshot.finishing, isTrue);
    expect(snapshot.paused, isTrue);
    expect(snapshot.sampleCounts, [100, 200]);
    expect(snapshot.peakVolumes, [1.0, .5]);
    expect(snapshot.currentVolumes, [0.0, .25]);
    expect(snapshot.lastAudioActivity.millisecondsSinceEpoch, 1234);
    expect(snapshot.echoCancellationState, {
      'requested': true,
      'active': false,
    });
    snapshot.dispose();
    final empty = RemoteRecording({});
    expect(empty.finishing, isFalse);
    expect(empty.paused, isFalse);
    expect(empty.sampleCounts, isEmpty);
    expect(empty.peakVolumes, isEmpty);
    expect(empty.currentVolumes, isEmpty);
    expect(empty.echoCancellationState['requested'], isFalse);
    expect(empty.lastAudioActivity.isAfter(DateTime(2020)), isTrue);
  });
  for (final paused in [false, true]) {
    test(
      'rejected source control restores prior paused state $paused',
      () async {
        f.event({...f.status, 'sources_paused': paused});
        await eventually(() => f.remote.sourcesPaused == paused);
        var changes = 0;
        f.remote.helper.changed = () => changes++;
        f.handler = (socket, request) => socket.writeln(
          jsonEncode({
            'id': request['id'],
            'error': 'service rejected control',
            'done': true,
          }),
        );
        paused ? f.remote.resumeSources() : f.remote.pauseSources();
        expect(f.remote.sourcesPaused, !paused);
        await eventually(
          () => f.remote.helper.state.contains('service rejected control'),
        );
        expect(f.remote.sourcesPaused, paused);
        expect(changes, greaterThan(0));
      },
    );
  }

  test('late source control errors preserve newer service snapshots', () async {
    f.remote.pauseSources();
    await eventually(
      () => f.requests.any((r) => r['method'] == 'sources.pause'),
    );
    f.event({
      ...f.status,
      'sources_paused': true,
      'capture': {'state': 'fresh'},
    });
    await eventually(() => f.remote.capture['state'] == 'fresh');
    final request = f.requests.singleWhere(
      (r) => r['method'] == 'sources.pause',
    );
    f.sockets.last.writeln(
      jsonEncode({'id': request['id'], 'error': 'late failure', 'done': true}),
    );
    await eventually(() => f.remote.helper.state.contains('late failure'));
    expect(f.remote.sourcesPaused, isTrue);
  });

  test('late source control errors preserve a newer local command', () async {
    f.remote.pauseSources();
    f.remote.pauseSources();
    await eventually(
      () => f.requests.where((r) => r['method'] == 'sources.pause').length == 2,
    );
    final pauses = f.requests
        .where((r) => r['method'] == 'sources.pause')
        .toList();
    f.reply(f.sockets.last, pauses.last, null);
    f.sockets.last.writeln(
      jsonEncode({
        'id': pauses.first['id'],
        'error': 'late failure',
        'done': true,
      }),
    );
    await eventually(() => f.remote.helper.state.contains('late failure'));
    expect(f.remote.sourcesPaused, isTrue);
  });

  test(
    'disconnection remains observable when the service cannot reconnect',
    () async {
      final previous = runtimeConfiguration.environment['FORESIGHT_SERVICE'];
      runtimeConfiguration.environment['FORESIGHT_SERVICE'] =
          '/missing/fixture-service';
      try {
        await f.server.close();
        f.sockets.last.destroy();
        await eventually(
          () => f.remote.helper.state.contains('reconnect failed'),
        );
        f.remote.close();
      } finally {
        if (previous == null) {
          runtimeConfiguration.environment.remove('FORESIGHT_SERVICE');
        } else {
          runtimeConfiguration.environment['FORESIGHT_SERVICE'] = previous;
        }
      }
    },
  );
  test(
    'request-specific cancellation leaves another desktop generation active',
    () async {
      f.handler = (socket, request) =>
          f.reply(socket, request, 'preview', done: false);
      final first = StreamIterator(
        f.remote.askInConversation('First', 'desktop', requestId: 'first'),
      );
      final second = StreamIterator(
        f.remote.askWithWebInConversation(
          'Second',
          'desktop',
          requestId: 'second',
        ),
      );
      expect(await first.moveNext(), isTrue);
      expect(await second.moveNext(), isTrue);
      final failure = expectLater(first.moveNext(), throwsStateError);
      expect(f.remote.runtime.cancel(requestId: 'missing'), isFalse);
      expect(f.remote.runtime.cancel(requestId: 'first'), isTrue);
      await failure;
      final request = f.requests.singleWhere(
        (request) => (request['args'] as Map?)?['requestId'] == 'second',
      );
      f.reply(f.sockets.last, request, 'completed');
      expect(await second.moveNext(), isTrue);
      expect(second.current, 'completed');
      expect(await second.moveNext(), isFalse);
      await first.cancel();
      await second.cancel();
    },
  );

  test(
    'a cancelled predicate reaches the service while generation is silent',
    () async {
      var current = true;
      final pending = expectLater(
        f.remote
            .askInConversation('Silent', 'desktop', current: () => current)
            .last,
        throwsStateError,
      );
      await eventually(
        () => f.requests.any((request) => request['method'] == 'answer.stream'),
      );
      final request = f.requests.last;
      current = false;
      await pending;
      await eventually(
        () => f.requests.any((message) => message['cancel'] == request['id']),
      );
    },
  );

  test(
    'helper snapshots follow service events without opening a helper watcher',
    () async {
      var ready = 0;
      f.remote.helper.onReady = () async {
        ready++;
      };
      await f.remote.helper.start().timeout(const Duration(seconds: 1));
      expect(ready, 1);
      expect(f.remote.helper.watch, isNull);
      f.event({
        ...f.status,
        'helper_state': 'live in relocated runtime',
        'helper': control.State(
          pipeline: 'ready',
          buildId: 'relocated-build',
          instanceId: 'new-instance',
        ).toProto3Json(),
      });
      await eventually(
        () => f.remote.helper.snapshot?.buildId == 'relocated-build',
      );
      expect(f.remote.helper.state, 'live in relocated runtime');
      f.event({...f.status, 'helper': null, 'helper_state': 'helper exited'});
      await eventually(() => f.remote.helper.snapshot == null);
      expect(f.remote.helper.state, 'helper exited');
      expect(f.remote.helper.watch, isNull);
    },
  );
  test(
    'approval events preserve the current service helper snapshot',
    () async {
      File(
        '${f.profile.data}/.desktop-capability',
      ).writeAsStringSync('test-token');
      f.handler = (socket, request) => f.reply(socket, request, null);
      final approvals = <Map<String, dynamic>>[];
      await f.remote.enableDesktopApprovals(approvals.add);
      f.event({
        ...f.status,
        'helper': control.State(
          pipeline: 'ready',
          buildId: 'current-build',
        ).toProto3Json(),
      });
      await eventually(
        () => f.remote.helper.snapshot?.buildId == 'current-build',
      );
      f.event({
        'event': 'approval',
        'approval_id': 'test-approval',
        'method': 'sources.import_url',
        'args': {'allow_private_network': true},
      });
      await eventually(() => approvals.isNotEmpty);
      expect(f.remote.helper.snapshot?.buildId, 'current-build');
      expect(f.remote.helper.snapshot?.pipeline, 'ready');
    },
  );
}
