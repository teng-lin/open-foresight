import 'package:foresight_core/src/rpc_error.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:foresight_core/foresight_core.dart';
import 'package:foresight_core/src/remote_domain.dart';
import 'package:test/test.dart';
import 'package:foresight_core/src/generated/helper_control.pb.dart' as control;

import 'package:foresight_test_support/remote_service.dart';
import 'package:foresight_test_support/service_fault_proxy.dart';

void main() {
  late RemoteFixture f;
  setUp(() async {
    f = RemoteFixture();
    await f.start();
  });
  tearDown(() => f.close());

  test('acknowledged clear survives a failed status refresh', () async {
    f.handler = (socket, request) {
      expect(request['method'], Operation.workspaceClear.wire);
      f.reply(socket, request, {'cleared': true});
      f.rejectStatus = true;
    };
    expect(await f.remote.command(Operation.workspaceClear), {'cleared': true});
    expect(f.remote.client.isClosed, isTrue);
  });

  test('a failed clear still reports its error', () async {
    f.handler = (socket, request) => socket.destroy();
    await expectLater(
      f.remote.command(Operation.workspaceClear),
      throwsA(isA<RpcError>()),
    );
  });

  test(
    'capture telemetry updates only level listeners and preserves workspace state',
    () async {
      var changes = 0;
      f.remote.helper.changed = () => changes++;
      f.event({
        'capture': {'meeting_id': 17, 'active': true},
        'google': {'connected': true},
      });
      await eventually(() => changes == 1);
      final received = <List<double>>[];
      final subscription = f.remote.captureLevels.listen(received.add);
      addTearDown(subscription.cancel);
      for (var i = 0; i < 10; i++) {
        f.event({
          'event': 'capture_levels',
          'volumes': [i / 10, 0],
        });
      }
      await eventually(() => received.length == 10);
      expect(changes, 1);
      expect(received.last, [0.9, 0.0]);
      expect(f.remote.capture['volumes'], [0.9, 0.0]);
      expect(f.remote.capture['meeting_id'], 17);
      expect(f.remote.googleStatus['connected'], isTrue);
    },
  );

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
          'displayName': 'Fixture Person',
          'photoUrl': 'https://lh3.googleusercontent.com/fixture',
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
      expect(auth.displayName, 'Fixture Person');
      expect(auth.photoUrl, 'https://lh3.googleusercontent.com/fixture');
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
      expect(auth.displayName, isEmpty);
      expect(auth.photoUrl, isEmpty);
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
    'Google account facade streams additions and selects or signs out only requested id',
    () async {
      final auth = RemoteGoogleAuth(f.remote);
      f.handler = (socket, request) {
        if (request['method'] == 'google.add_account') {
          f.reply(socket, request, {
            'authorization_url': 'https://example.invalid/add',
          }, done: false);
          f.reply(socket, request, {
            'connected': true,
            'account': 'second',
            'accounts': [
              {'id': 'second', 'email': 'second@example.test', 'current': true},
              {'id': 'first', 'email': 'first@example.test', 'current': false},
            ],
          });
        } else if (request['method'] == 'google.switch_account') {
          expect((request['args'] as Map)['id'], 'first');
          f.reply(socket, request, {'connected': true, 'account': 'first'});
        } else if (request['method'] == 'google.sign_out_account') {
          expect((request['args'] as Map)['id'], 'second');
          f.reply(socket, request, {'connected': true, 'account': 'first'});
        }
      };
      final opened = <Uri>[];
      await auth.addAccount((uri) async => opened.add(uri));
      expect(opened.single.path, '/add');
      expect(auth.accounts.map((account) => account['id']), [
        'second',
        'first',
      ]);
      await auth.switchAccount('first');
      expect(auth.account, 'first');
      await auth.signOutAccount('second');
      expect(auth.connected, isTrue);
      expect(auth.account, 'first');
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
      expect(f.requests.last['args'], {
        'id': 19,
        'workspace_epoch': f.owner.workspaceEpoch,
      });
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

  test('a command refused by a closing owner is sent once more after the '
      'reconnect reattaches approvals (SL-9)', () async {
    File(
      '${f.profile.data}/.desktop-capability',
    ).writeAsStringSync('test-token');
    var refusals = 1;
    f.handler = (socket, request) {
      if (request['method'] == 'notes.list' && refusals-- > 0) {
        // An owner older than the reason field sends only the text.
        socket.writeln(
          jsonEncode({
            'id': request['id'],
            'error': {
              'code': 'unavailable',
              'message':
                  'Application service is shutting down; retry after it exits.',
            },
            'done': true,
          }),
        );
      } else {
        f.reply(socket, request, request['method'] == 'notes.list' ? [] : null);
      }
    };
    await f.remote.enableDesktopApprovals((_) {});
    final before = f.requests.length;
    final previous = f.remote.client;
    expect(await f.remote.command(Operation.notesList), isEmpty);
    expect(f.remote.client, isNot(same(previous)));
    expect(previous.isClosed, isTrue);
    // Refused, then the reconnect's probe and reserving snapshot, its one
    // approval attach, and the request once more.
    expect(f.requests.skip(before).map((r) => r['method']), [
      'notes.list',
      'status',
      'status',
      'security.attach_desktop',
      'notes.list',
    ]);
  });

  test('a closing refusal leaves the other requests on its connection to '
      'the owner\'s own answers: a refused one is sent once more, a '
      'dispatched one is outcomeUnknown (SL-9)', () async {
    const closingText =
        'Application service is shutting down; retry after it exits.';
    const ownerUnknown =
        'Application service stopped before this request finished; it may '
        'or may not have completed.';
    final closing = f.sockets.last;
    final previous = f.remote.client;
    final held = <Map<String, dynamic>>[];
    void answer(Map<String, dynamic> request, Map<String, Object?> error) =>
        closing.writeln(
          jsonEncode({'id': request['id'], 'error': error, 'done': true}),
        );
    f.handler = (socket, request) {
      final method = request['method'] as String;
      if (!identical(socket, closing)) {
        // The next owner answers everything.
        f.reply(socket, request, 'next owner: $method');
        // The closing owner's other answers arrive only after the first
        // refused request reached the next owner.
        if (method == 'notes.list') {
          for (final request in held) {
            answer(
              request,
              request['method'] == 'meetings.list'
                  ? {
                      'code': 'unavailable',
                      'message': closingText,
                      'reason': 'closing',
                    }
                  : {
                      'code': 'unavailable',
                      'message': ownerUnknown,
                      'reason': 'outcomeUnknown',
                    },
            );
          }
        }
        return;
      }
      if (method == 'notes.list') {
        answer(request, {
          'code': 'unavailable',
          'message': closingText,
          'reason': 'closing',
        });
      } else {
        held.add(request);
      }
    };
    final first = f.remote.command(Operation.notesList);
    final second = f.remote.command(Operation.meetingsList);
    final dispatched = f.remote
        .command(Operation.notesSave, {'title': 'T', 'body': 'B'})
        .then<Object?>(
          (value) => fail('Expected a failure, got $value'),
          onError: (Object error) => error,
        );
    expect(await first, 'next owner: notes.list');
    expect(await second, 'next owner: meetings.list');
    expect(
      await dispatched,
      isA<RpcError>()
          .having((error) => error.message, 'message', ownerUnknown)
          .having(
            (error) => error.toJson()['reason'],
            'reason',
            'outcomeUnknown',
          ),
    );
    for (final (method, count) in [
      ('notes.list', 2),
      ('meetings.list', 2),
      ('notes.save', 1),
    ]) {
      expect(f.requests.where((r) => r['method'] == method), hasLength(count));
    }
    // With nothing left pending, the retired connection closed.
    expect(previous.isClosed, isTrue);
    await expectLater(
      previous.call('after.handoff'),
      throwsA(
        isA<RpcError>().having(
          (error) => error.toJson()['reason'],
          'reason',
          'notSent',
        ),
      ),
    );
  });

  // The desktop cancels with no request ID (generator.cancel()).
  for (final cancelled in <String?>['gen-3', null, 'another-answer']) {
    test('a cancel during the handoff stops only that answer\'s resend '
        '(cancel $cancelled)', () async {
      final proxy = ServiceFaultProxy();
      try {
        var refusals = 1;
        f.handler = (socket, request) {
          if (request['method'] != 'meetings.generate') return;
          if (refusals-- > 0) {
            socket.writeln(
              jsonEncode({
                'id': request['id'],
                'error': {
                  'code': 'unavailable',
                  'message':
                      'Application service is shutting down; retry after it exits.',
                  'reason': 'closing',
                },
                'done': true,
              }),
            );
          } else {
            f.reply(socket, request, {'generated': true});
          }
        };
        // Hold the handoff's startup probe for the next owner.
        final probe = proxy.hold(ProxyDirection.toService, method: 'status');
        final pending = proxy.run(
          () => f.remote.command(Operation.meetingsGenerate, {
            'id': 3,
            'requestId': 'gen-3',
          }),
        );
        await probe.reached;
        // The refused request is on no connection, so nothing is sent.
        expect(f.remote.runtime.cancel(requestId: cancelled), isFalse);
        probe.release();
        final generates = f.requests.where(
          (r) => r['method'] == 'meetings.generate',
        );
        if (cancelled != 'another-answer') {
          await expectLater(
            pending,
            throwsA(
              isA<RpcError>().having(
                (error) => error.code,
                'code',
                RpcErrorCode.cancelled,
              ),
            ),
          );
          expect(generates, hasLength(1));
        } else {
          expect(await pending, {'generated': true});
          expect(generates, hasLength(2));
        }
      } finally {
        await proxy.close();
      }
    });
  }

  test(
    'a failed connect closes its connection and leaves nothing running',
    () async {
      final proxy = ServiceFaultProxy();
      try {
        // connect's own status call, after ensureService's probe.
        var statuses = 0;
        final second = proxy.hold(
          ProxyDirection.toClient,
          where: (frame) => frame.method == 'status' && ++statuses == 2,
        );
        final connecting = proxy.run(() => RemoteDomain.connect(f.profile));
        final reply = await second.reached;
        proxy.inject(ProxyDirection.toClient, {
          'id': reply.id,
          'error': {'code': 'internal', 'message': 'status failed'},
          'done': true,
        }, connection: reply.connection);
        second.release();
        await expectLater(
          connecting,
          throwsA(
            isA<RpcError>().having(
              (error) => error.message,
              'message',
              'status failed',
            ),
          ),
        );
        // No caller holds the domain, so it closed its own connection.
        await reply.connection
            .ended(ProxyDirection.toService)
            .timeout(const Duration(seconds: 30));
        expect(proxy.connections, hasLength(1));
      } finally {
        await proxy.close();
      }
    },
  );

  test('a connect that fails after building its domain closes its '
      'connection, read-only store and helper (T2)', () async {
    // The snapshot reaches the domain, which rejects it.
    f.status = {...f.status, 'capture': 'not a map'};
    final connections = f.sockets.length;
    RemoteDomain? created;
    await expectLater(
      RemoteDomain.connect(
        f.profile,
        createdForTesting: (domain) => created = domain,
      ),
      throwsA(isA<TypeError>()),
    );
    expect(created, isNotNull);
    expect(() => created!.store.rows('SELECT 1'), throwsA(anything));
    expect(created!.helper.stopping, isTrue);
    expect(created!.client.isClosed, isTrue);
    expect(f.sockets.length, greaterThan(connections));
  });

  test('a command whose outcome is unknown is never resent', () async {
    f.handler = (socket, request) => socket.writeln(
      jsonEncode({
        'id': request['id'],
        'error': {
          'code': 'unavailable',
          'message': 'stopped',
          'reason': 'outcomeUnknown',
        },
        'done': true,
      }),
    );
    await expectLater(
      f.remote.command(Operation.notesSave, {'title': 'once'}),
      throwsA(
        isA<RpcError>().having(
          (error) => error.toJson()['reason'],
          'reason',
          'outcomeUnknown',
        ),
      ),
    );
    expect(f.requests.where((r) => r['method'] == 'notes.save'), hasLength(1));
  });

  test(
    'a command on a connection that already closed is sent once, on the next',
    () async {
      final lost = f.remote.client;
      final closed = lost.events.stream.drain<void>();
      f.sockets.last.destroy();
      await closed;
      // The reconnect has begun but not finished: the request is not sent.
      expect(identical(f.remote.client, lost), isTrue);
      f.handler = (socket, request) => f.reply(socket, request, ['listed']);
      expect(await f.remote.command(Operation.notesList), ['listed']);
      expect(
        f.requests.where((r) => r['method'] == 'notes.list'),
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
  test('a reconnect whose launches keep failing backs off from 1 s to 30 s, '
      'and a success starts over', () async {
    final previous = runtimeConfiguration.environment['FORESIGHT_SERVICE'];
    addTearDown(() {
      if (previous == null) {
        runtimeConfiguration.environment.remove('FORESIGHT_SERVICE');
      } else {
        runtimeConfiguration.environment['FORESIGHT_SERVICE'] = previous;
      }
    });
    // Each launch fails at once and says why, as a start with a corrupt
    // database or a failed migration does.
    final launches = File('${f.root.path}/launches');
    final service = File('${f.root.path}/failing-service')
      ..writeAsStringSync(
        '#!/bin/sh\n'
        "echo launched >> '${launches.path}'\n"
        'printf \'{"state":"failed","error":"database disk image is '
        'malformed"}\' > "\$FORESIGHT_STARTUP_STATUS"\n',
      );
    expect(
      (await Process.run('/bin/chmod', ['700', service.path])).exitCode,
      0,
    );
    runtimeConfiguration.environment['FORESIGHT_SERVICE'] = service.path;
    int launched() =>
        launches.existsSync() ? launches.readAsLinesSync().length : 0;
    final pauses = <Duration>[];
    final served = Completer<void>();
    f.remote.reconnectPause = (pause) async {
      pauses.add(pause);
      if (pauses.length == 7) await served.future;
      // Hold the loop after the restart's first failure.
      if (pauses.length == 8) await Completer<void>().future;
    };
    await f.stopListening();
    f.sockets.last.destroy();
    await eventually(
      () => pauses.length == 7,
      timeout: const Duration(seconds: 60),
    );
    expect(pauses, [
      for (final seconds in [1, 2, 4, 8, 16, 30, 30])
        Duration(seconds: seconds),
    ]);
    // One launch per failed attempt.
    expect(launched(), 7);
    expect(f.remote.helper.state, contains('database disk image is malformed'));
    // An owner serves again; the next attempt reconnects.
    await f.listen();
    final connections = f.sockets.length;
    served.complete();
    await eventually(
      () => f.sockets.length > connections && !f.remote.client.isClosed,
    );
    // The next run of failures starts again at 1 s.
    await f.stopListening();
    f.sockets.last.destroy();
    await eventually(
      () => pauses.length == 8,
      timeout: const Duration(seconds: 30),
    );
    expect(pauses.last, const Duration(seconds: 1));
    expect(launched(), 8);
  });

  test('a reconnect whose desktop attach is never answered fails, closes '
      'that connection and tries again after the backoff', () async {
    var answerAttach = true;
    f.handler = (socket, request) {
      // An owner that answers status but never the attach.
      if (request['method'] == Operation.securityAttachDesktop.wire &&
          !answerAttach) {
        return;
      }
      f.reply(socket, request, null);
    };
    final approvals = <Map<String, dynamic>>[];
    await f.remote.enableDesktopApprovals(approvals.add);
    f.remote.attachLimit = const Duration(milliseconds: 200);
    final pauses = <Duration>[];
    final paused = Completer<void>();
    f.remote.reconnectPause = (pause) async {
      pauses.add(pause);
      await paused.future;
    };
    int attaches() => f.requests
        .where((r) => r['method'] == Operation.securityAttachDesktop.wire)
        .length;
    answerAttach = false;
    f.sockets.last.destroy();
    await eventually(() => pauses.isNotEmpty);
    expect(pauses, [const Duration(seconds: 1)]);
    expect(attaches(), 2);
    expect(f.remote.helper.state, contains('did not attach'));
    // The connection whose attach hung is closed, not kept.
    expect(f.remote.client.isClosed, isTrue);
    answerAttach = true;
    paused.complete();
    await eventually(() => attaches() == 3 && !f.remote.client.isClosed);
    // The reattached desktop still receives approvals.
    f.event({
      'event': 'approval',
      'approval_id': 'after-reconnect',
      'method': 'sources.delete',
      'args': {'id': 'source'},
    });
    await eventually(() => approvals.isNotEmpty);
  });

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
    'by-ID edits carry the workspace the desktop views were read in',
    () async {
      var changes = 0;
      f.remote.helper.changed = () => changes++;
      f.handler = (socket, request) => f.reply(socket, request, {'id': 3});
      // The desktop starts in the profile's workspace.
      final before = f.owner.workspaceEpoch;
      f.event({...f.status, 'workspace_epoch': before});
      await eventually(() => changes == 1);
      Future<Map> sent(Operation operation, Map<String, dynamic> args) async {
        await f.remote.command(operation, args);
        return f.requests.last['args'] as Map;
      }

      expect(
        await sent(Operation.notesSave, {'id': 3, 'title': 'T', 'body': 'B'}),
        containsPair('workspace_epoch', before),
      );
      await f.remote.commandCurrent(Operation.meetingsEnhance, {
        'id': 3,
      }, () => true);
      expect(f.requests.last['args'], containsPair('workspace_epoch', before));
      // Creates and calls without an ID name no existing row.
      expect(
        await sent(Operation.notesSave, {'title': 'T', 'body': 'B'}),
        isNot(contains('workspace_epoch')),
      );
      expect(
        await sent(Operation.meetingsCreate, {'title': 'T'}),
        isNot(contains('workspace_epoch')),
      );
      // A keyed create must not be replayed into a workspace cleared since.
      expect(
        await sent(Operation.meetingsCreate, {
          'title': 'T',
          'idempotency_key': 'k',
        }),
        containsPair('workspace_epoch', before),
      );
      // A dialog that read its ID earlier names that workspace itself.
      expect(
        await sent(Operation.artifactsEdit, {
          'id': 3,
          'text': 'T',
          'workspace_epoch': 'dialog',
        }),
        containsPair('workspace_epoch', 'dialog'),
      );
      // Another client clears the workspace; the open views still predate it.
      f.event({...f.status, 'workspace_epoch': 'after-clear'});
      await eventually(() => changes == 2);
      expect(
        await sent(Operation.meetingsNotes, {'id': 3, 'body': 'stale'}),
        containsPair('workspace_epoch', before),
      );
    },
  );

  test('a cleared workspace is adopted only after the views reset', () async {
    f.handler = (socket, request) => f.reply(socket, request, null);
    final before = f.owner.workspaceEpoch;
    expect(f.remote.workspaceEpoch, before);
    expect(f.remote.workspaceReplaced, isFalse);
    f.event({...f.status, 'workspace_epoch': 'after-clear'});
    await eventually(() => f.remote.workspaceReplaced);
    expect(f.remote.workspaceEpoch, before);
    f.remote.adoptWorkspace();
    expect(f.remote.workspaceReplaced, isFalse);
    await f.remote.command(Operation.labelsSet, {'id': 'source', 'labels': []});
    expect(
      f.requests.last['args'],
      containsPair('workspace_epoch', 'after-clear'),
    );
  });

  test('approvals open on a lost connection close when it drops', () async {
    f.handler = (socket, request) => f.reply(socket, request, null);
    final approvals = <Map<String, dynamic>>[];
    await f.remote.enableDesktopApprovals(approvals.add);
    for (final id in ['pending', 'decided']) {
      f.event({
        'event': 'approval',
        'approval_id': id,
        'method': 'sources.delete',
        'args': {'id': 'source'},
      });
    }
    f.event({'event': 'approval_closed', 'approval_id': 'decided'});
    await eventually(() => approvals.length == 3);
    f.sockets.last.destroy();
    await eventually(() => approvals.length == 4);
    expect(approvals.last, {
      'event': 'approval_closed',
      'approval_id': 'pending',
    });
    // The reconnected desktop attaches for new approvals again.
    await eventually(
      () =>
          f.requests
              .where(
                (request) =>
                    request['method'] == Operation.securityAttachDesktop.wire,
              )
              .length ==
          2,
    );
    expect(approvals, hasLength(4));
  });

  group('a clear whose reply is lost', () {
    setUp(() {
      f.status['workspace_epoch'] = f.owner.workspaceEpoch;
    });
    void loseClear({required bool committed}) {
      f.handler = (socket, request) {
        if (request['method'] != Operation.workspaceClear.wire) {
          f.reply(socket, request, null);
          return;
        }
        if (committed) {
          f.owner.renewWorkspaceEpoch();
          f.status['workspace_epoch'] = f.owner.workspaceEpoch;
        }
        socket.destroy();
      };
    }

    test('is reported cleared when the next owner has a new epoch', () async {
      loseClear(committed: true);
      expect(await f.remote.command(Operation.workspaceClear), isNull);
      expect(f.remote.workspaceReplaced, isTrue);
    });

    test('is reported not cleared when the epoch is unchanged', () async {
      loseClear(committed: false);
      await expectLater(
        f.remote.command(Operation.workspaceClear),
        throwsA(
          isA<RpcError>().having(
            (error) => error.message,
            'message',
            contains('nothing was cleared'),
          ),
        ),
      );
      expect(f.remote.workspaceReplaced, isFalse);
    });
  });

  test(
    'a clear missed before a new connection is listened to is seen',
    () async {
      f.handler = (socket, request) => f.reply(socket, request, null);
      // The replacement's startup status predates a clear whose event the
      // desktop never receives.
      f.status['workspace_epoch'] = f.owner.workspaceEpoch;
      expect(f.remote.workspaceReplaced, isFalse);
      f.owner.renewWorkspaceEpoch();
      int statuses() =>
          f.requests.where((request) => request['method'] == 'status').length;
      final before = statuses();
      f.sockets.last.destroy();
      await eventually(() => statuses() > before);
      await eventually(() => f.remote.workspaceReplaced);
    },
  );

  test('a late event with a replaced epoch does not reset again', () async {
    f.handler = (socket, request) => f.reply(socket, request, null);
    final replaced = f.owner.workspaceEpoch;
    f.status['workspace_epoch'] = replaced;
    f.owner.renewWorkspaceEpoch();
    final current = f.owner.workspaceEpoch;
    // A reconnect reads the clear from the profile; the views reset.
    f.sockets.last.destroy();
    await eventually(() => f.remote.workspaceReplaced);
    f.remote.adoptWorkspace();
    var resets = 0;
    f.remote.helper.changed = () {
      if (f.remote.workspaceReplaced) resets++;
    };
    // The old connection's event for the epoch it replaced arrives late.
    f.sockets.last.writeln(
      jsonEncode({'event': 'changed', 'workspace_epoch': replaced}),
    );
    f.sockets.last.writeln(
      jsonEncode({'event': 'changed', 'sources_paused': true}),
    );
    await eventually(() => f.remote.sourcesPaused);
    expect(resets, 0);
    expect(f.remote.workspaceReplaced, isFalse);
    expect(f.remote.workspaceEpoch, current);
  });

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
