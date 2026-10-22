import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:foresight_core/desktop.dart';
import 'package:foresight_core/src/remote_domain.dart';
import 'package:foresight_test_support/remote_service.dart';
import 'package:test/test.dart';

void refuse(Socket socket, Map<String, dynamic> request) {
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
}

/// Models a feature's publication boundary, without changing RPC settlement.
/// A production feature also captures its own selection/request generation.
class Publication {
  Publication(this.connection)
    : session = connection.clientSessionGeneration,
      epoch = connection.workspaceEpoch;
  final DesktopConnection connection;
  final Object session;
  final String? epoch;
  bool alive = true;
  final values = <Object?>[];
  final errors = <Object>[];
  int completions = 0, finalizers = 0;
  bool get current =>
      alive &&
      identical(session, connection.clientSessionGeneration) &&
      epoch == connection.workspaceEpoch;

  Future<void> action(Future<Object?> pending) async {
    try {
      final value = await pending;
      if (current) values.add(value);
    } catch (error) {
      if (current) errors.add(error);
    } finally {
      if (current) finalizers++;
    }
  }

  Future<void> stream(Stream<Object?> pending) async {
    try {
      await for (final value in pending) {
        if (current) values.add(value);
      }
      if (current) completions++;
    } catch (error) {
      if (current) errors.add(error);
    } finally {
      if (current) finalizers++;
    }
  }
}

void main() {
  late RemoteFixture f;
  setUp(() async {
    f = RemoteFixture();
    await f.start();
  });
  tearDown(() => f.close());

  test(
    'same endpoint, epoch and byte-equal status replacement notifies before admission',
    () async {
      final DesktopConnection connection = f.remote;
      final oldToken = connection.clientSessionGeneration;
      final oldClient = f.remote.client;
      final oldEndpoint = oldClient.endpoint;
      final epoch = connection.workspaceEpoch;
      final revision = connection.store.dataRevision;
      final reader = connection.store;
      final statusBytes = jsonEncode(f.status);
      final approvalSessions = <Object>[];
      f.handler = (socket, request) => f.reply(socket, request, null);
      await f.remote.enableDesktopApprovals((_) {
        approvalSessions.add(connection.clientSessionGeneration);
      });
      final observations = <Object>[];
      final changes = connection.changes.listen((_) {
        if (!identical(connection.clientSessionGeneration, oldToken)) {
          expect(f.remote.client, isNot(same(oldClient)));
          expect(f.remote.runtime.client, same(f.remote.client));
          expect(connection.workspaceEpoch, epoch);
          expect(connection.store, same(reader));
          observations.add(connection.clientSessionGeneration);
        }
      });
      addTearDown(changes.cancel);
      final oldSocket = f.sockets.last;
      f.handler = (socket, request) {
        if (identical(socket, oldSocket)) {
          refuse(socket, request);
        } else {
          expect(
            observations,
            isNotEmpty,
            reason: 'Adoption notification precedes resend',
          );
          f.reply(socket, request, 'replacement');
          if (request['method'] == 'security.attach_desktop') {
            socket.writeln(
              jsonEncode({
                'event': 'approval',
                'approval_id': 'replacement-approval',
                'method': 'sources.delete',
                'args': {'id': 'source'},
              }),
            );
          }
        }
      };
      expect(await connection.command(Operation.notesList), 'replacement');
      expect(connection.clientSessionGeneration, isNot(same(oldToken)));
      expect(observations, [same(connection.clientSessionGeneration)]);
      expect(f.remote.client.endpoint, oldEndpoint);
      expect(
        connection.store.dataRevision,
        revision,
        reason: 'Client replacement must not fabricate a SQLite revision',
      );
      expect(jsonEncode(f.status), statusBytes);
      await eventually(() => approvalSessions.isNotEmpty);
      expect(approvalSessions, [same(connection.clientSessionGeneration)]);
      final methods = f.requests.where((r) => r['method'] == 'notes.list');
      expect(methods, hasLength(2));
      expect(methods.first['args'], methods.last['args']);
      await eventually(() => f.ended.contains(oldSocket));
    },
  );

  test(
    'ordinary snapshots, capture telemetry and clear/adopt retain the session',
    () async {
      final token = f.remote.clientSessionGeneration;
      var changes = 0;
      final subscription = f.remote.changes.listen((_) {
        changes++;
        expect(f.remote.clientSessionGeneration, same(token));
      });
      addTearDown(subscription.cancel);
      f.event({...f.status, 'helper_state': 'ordinary'});
      await eventually(() => changes == 1);
      // A later distinct snapshot is a socket-order fence for the duplicate.
      f.event({...f.status, 'helper_state': 'ordinary'});
      f.event({...f.status, 'helper_state': 'next'});
      await eventually(() => f.remote.helper.state == 'next');
      expect(changes, 2);
      final level = f.remote.captureLevels.first;
      f.event({
        'event': 'capture_levels',
        'volumes': [0.25, 0.5],
      });
      expect(await level, [0.25, 0.5]);
      expect(changes, 2);
      expect(f.remote.clientSessionGeneration, same(token));
      final oldEpoch = f.remote.workspaceEpoch;
      f.owner.renewWorkspaceEpoch();
      f.event({...f.status, 'workspace_epoch': f.owner.workspaceEpoch});
      await eventually(() => f.remote.workspaceReplaced);
      f.remote.adoptWorkspace();
      expect(f.remote.workspaceEpoch, isNot(oldEpoch));
      expect(f.remote.clientSessionGeneration, same(token));
      final other = await RemoteDomain.connect(f.profile);
      addTearDown(() async {
        other.close();
        await other.closed;
      });
      expect(other.clientSessionGeneration, isNot(same(token)));
    },
  );

  test(
    'failed probes retain the token; actual adoption before attach failure rotates it',
    () async {
      final original = f.remote.clientSessionGeneration;
      final profile = f.status['profile_id'];
      var paused = false;
      final release = Completer<void>();
      f.remote.reconnectPause = (_) {
        paused = true;
        return release.future;
      };
      f.status['profile_id'] = 'wrong-profile';
      f.sockets.last.destroy();
      await eventually(() => paused);
      expect(f.remote.clientSessionGeneration, same(original));
      f.status['profile_id'] = profile;
      var answerAttach = true;
      final atAttach = <Object>[];
      f.handler = (socket, request) {
        if (request['method'] == 'security.attach_desktop') {
          atAttach.add(f.remote.clientSessionGeneration);
          if (!answerAttach) return;
        }
        f.reply(socket, request, null);
      };
      release.complete();
      await eventually(
        () => !f.remote.client.isClosed && !f.remote.reconnecting,
      );
      await f.remote.enableDesktopApprovals((_) {});
      final beforeAttachFailure = f.remote.clientSessionGeneration;
      expect(beforeAttachFailure, isNot(same(original)));
      final notified = <Object>[];
      final subscription = f.remote.changes.listen((_) {
        notified.add(f.remote.clientSessionGeneration);
      });
      addTearDown(subscription.cancel);
      answerAttach = false;
      paused = false;
      final retry = Completer<void>();
      f.remote.reconnectPause = (_) {
        paused = true;
        return retry.future;
      };
      f.remote.attachLimit = const Duration(milliseconds: 200);
      f.sockets.last.destroy();
      await eventually(() => paused);
      final failedAttachToken = f.remote.clientSessionGeneration;
      expect(failedAttachToken, isNot(same(beforeAttachFailure)));
      expect(atAttach.last, same(failedAttachToken));
      expect(notified, contains(same(failedAttachToken)));
      expect(f.remote.client.isClosed, isTrue);
      answerAttach = true;
      f.remote.attachLimit = const Duration(seconds: 30);
      retry.complete();
      await eventually(
        () => !f.remote.client.isClosed && !f.remote.reconnecting,
      );
      expect(f.remote.clientSessionGeneration, isNot(same(failedAttachToken)));
      expect(atAttach.last, same(f.remote.clientSessionGeneration));
    },
  );

  test(
    'status decode failure retires and notifies the adopted session',
    () async {
      final original = f.remote.clientSessionGeneration;
      final reader = f.remote.store;
      final revision = reader.dataRevision;
      final generation = f.status['generation'];
      final retry = Completer<void>();
      var paused = false;
      f.remote.reconnectPause = (_) {
        paused = true;
        return retry.future;
      };
      addTearDown(() {
        f.status['generation'] = generation;
        if (!retry.isCompleted) retry.complete();
      });
      final failedNotifications = <Object>[];
      Socket? failedSocket;
      final changes = f.remote.changes.listen((_) {
        if (f.remote.helper.state.startsWith(
          'application service reconnect failed:',
        )) {
          failedNotifications.add(f.remote.clientSessionGeneration);
          // Changes are synchronous; capture this transport before the
          // reconnect pause opens a separate endpoint-liveness probe.
          failedSocket ??= f.sockets.last;
        }
      });
      addTearDown(changes.cancel);

      // The profile/API probe succeeds; decoding the newly adopted status fails.
      f.status['generation'] = 17;
      f.sockets.last.destroy();
      await eventually(() => paused && failedNotifications.isNotEmpty);
      final failedSession = f.remote.clientSessionGeneration;
      expect(failedSession, isNot(same(original)));
      expect(failedNotifications, everyElement(same(failedSession)));
      expect(f.remote.client.isClosed, isTrue);
      expect(f.remote.runtime.client, same(f.remote.client));
      expect(f.remote.store, same(reader));
      expect(reader.dataRevision, revision);
      expect(failedSocket, isNotNull);
      await eventually(() => f.ended.contains(failedSocket));

      f.status['generation'] = generation;
      retry.complete();
      await eventually(
        () => !f.remote.client.isClosed && !f.remote.reconnecting,
      );
      expect(f.remote.clientSessionGeneration, isNot(same(failedSession)));
      expect(f.remote.store, same(reader));
      expect(reader.dataRevision, revision);
    },
  );

  for (final fail in [false, true]) {
    test(
      'retired plain action ${fail ? 'error' : 'success'} settles but cannot publish',
      () async {
        final oldSocket = f.sockets.last;
        final held = Completer<Map<String, dynamic>>();
        f.handler = (socket, request) {
          if (identical(socket, oldSocket)) {
            if (request['method'] == 'notes.save') {
              held.complete(request);
            } else {
              refuse(socket, request);
            }
          } else {
            f.reply(socket, request, 'current');
          }
        };
        final old = Publication(f.remote);
        Object? settled;
        final request = f.remote.command(Operation.notesSave, {
          'title': 'T',
          'body': 'B',
        });
        final publication = old.action(
          request.then(
            (value) {
              settled = value;
              return value;
            },
            onError: (Object error, StackTrace stack) {
              settled = error;
              Error.throwWithStackTrace(error, stack);
            },
          ),
        );
        final pending = await held.future;
        await f.remote.command(Operation.notesList);
        expect(old.current, isFalse);
        expect(
          f.ended.contains(oldSocket),
          isFalse,
          reason: 'Owner still owes the original request',
        );
        if (fail) {
          oldSocket.writeln(
            jsonEncode({
              'id': pending['id'],
              'error': {'code': 'internal', 'message': 'late owner failure'},
              'done': true,
            }),
          );
        } else {
          f.reply(oldSocket, pending, 'late owner success');
        }
        await publication;
        expect(
          settled,
          fail
              ? isA<RpcError>().having(
                  (error) => error.message,
                  'owner error',
                  'late owner failure',
                )
              : 'late owner success',
        );
        expect(old.values, isEmpty);
        expect(old.errors, isEmpty);
        expect(old.finalizers, 0);
        expect(
          f.requests.where((r) => r['method'] == 'notes.save'),
          hasLength(1),
        );
        await eventually(() => f.ended.contains(oldSocket));
        final current = Publication(f.remote);
        await current.action(f.remote.command(Operation.notesList));
        expect(current.values, ['current']);
        expect(current.finalizers, 1);
        f.handler = (socket, request) => socket.writeln(
          jsonEncode({
            'id': request['id'],
            'error': {'code': 'internal', 'message': 'current failure'},
            'done': true,
          }),
        );
        await current.action(f.remote.command(Operation.notesList));
        expect(current.errors.single, isA<RpcError>());
        expect(current.finalizers, 2);
      },
    );
  }

  for (final failure in [false, true]) {
    test(
      'retired unfiltered answer ${failure ? 'error' : 'value'} settles at its owner without publication',
      () async {
        final socket = f.sockets.last;
        final held = Completer<Map<String, dynamic>>();
        f.handler = (on, request) {
          if (identical(on, socket)) {
            if (request['method'] == 'answer.stream') {
              held.complete(request);
            } else {
              refuse(on, request);
            }
          } else {
            f.reply(on, request, 'new owner');
          }
        };
        final old = Publication(f.remote);
        final settledValues = <String>[];
        final settledErrors = <Object>[];
        final stream = f.remote
            .askInConversation('Q', 'desktop')
            .map((value) {
              settledValues.add(value);
              return value;
            })
            .handleError((Object error) {
              settledErrors.add(error);
              throw error;
            });
        final publication = old.stream(stream);
        final pending = await held.future;
        await f.remote.command(Operation.notesList);
        expect(f.ended.contains(socket), isFalse);
        if (failure) {
          socket.writeln(
            jsonEncode({
              'id': pending['id'],
              'error': {'code': 'internal', 'message': 'late failure'},
              'done': true,
            }),
          );
        } else {
          f.reply(socket, pending, 'late value');
        }
        await publication;
        expect(settledValues, failure ? isEmpty : ['late value']);
        expect(
          settledErrors,
          failure
              ? [
                  isA<RpcError>().having(
                    (error) => error.message,
                    'owner error',
                    'late failure',
                  ),
                ]
              : isEmpty,
        );
        expect(old.values, isEmpty);
        expect(old.errors, isEmpty);
        expect(old.completions, 0);
        expect(old.finalizers, 0);
        expect(
          f.requests.where((r) => r['method'] == 'answer.stream'),
          hasLength(1),
        );
        await eventually(() => f.ended.contains(socket));
      },
    );
  }

  for (final kind in ['answer', 'commandCurrent']) {
    for (final failure in [false, true]) {
      test(
        'retired $kind ${failure ? 'error' : 'value'} cannot publish or resend',
        () async {
          final oldSocket = f.sockets.last;
          final held = Completer<Map<String, dynamic>>();
          final method = kind == 'answer'
              ? 'answer.stream'
              : 'meetings.enhance';
          f.handler = (socket, request) {
            if (identical(socket, oldSocket) && request['method'] == method) {
              held.complete(request);
            } else if (identical(socket, oldSocket)) {
              refuse(socket, request);
            } else {
              f.reply(socket, request, 'current value');
            }
          };
          final old = Publication(f.remote);
          final publication = kind == 'answer'
              ? old.stream(
                  f.remote.askInConversation(
                    'Q',
                    'desktop',
                    requestId: 'held',
                    current: () => old.current,
                  ),
                )
              : old.action(
                  f.remote.commandCurrent(Operation.meetingsEnhance, {
                    'id': 3,
                    'requestId': 'held',
                  }, () => old.current),
                );
          final pending = await held.future;
          await f.remote.command(Operation.notesList);
          if (failure) {
            oldSocket.writeln(
              jsonEncode({
                'id': pending['id'],
                'error': {'code': 'internal', 'message': 'late stream failure'},
                'done': true,
              }),
            );
          } else {
            f.reply(oldSocket, pending, 'late value');
          }
          await publication;
          expect(old.values, isEmpty);
          expect(old.errors, isEmpty);
          expect(old.completions, 0);
          expect(old.finalizers, 0);
          expect(f.requests.where((r) => r['method'] == method), hasLength(1));
          await eventually(() => f.ended.contains(oldSocket));
          final current = Publication(f.remote);
          if (kind == 'answer') {
            await current.stream(
              f.remote.askInConversation(
                'Q',
                'desktop',
                current: () => current.current,
              ),
            );
            expect(current.completions, 1);
          } else {
            await current.action(
              f.remote.commandCurrent(Operation.meetingsEnhance, {
                'id': 3,
              }, () => current.current),
            );
          }
          expect(current.values, ['current value']);
          expect(current.finalizers, 1);
          f.handler = (socket, request) => socket.writeln(
            jsonEncode({
              'id': request['id'],
              'error': {
                'code': 'internal',
                'message': 'current stream failure',
              },
              'done': true,
            }),
          );
          if (kind == 'answer') {
            await current.stream(
              f.remote.askInConversation(
                'Q',
                'desktop',
                current: () => current.current,
              ),
            );
          } else {
            await current.action(
              f.remote.commandCurrent(Operation.meetingsEnhance, {
                'id': 3,
              }, () => current.current),
            );
          }
          expect(current.errors.single, isA<RpcError>());
          expect(current.finalizers, 2);
        },
      );
    }
    test(
      'session-bound $kind closing refusal is not resent after replacement',
      () async {
        final oldSocket = f.sockets.last;
        f.handler = (socket, request) {
          if (identical(socket, oldSocket)) {
            refuse(socket, request);
          } else {
            f.reply(socket, request, 'unexpected replay');
          }
        };
        final publication = Publication(f.remote);
        if (kind == 'answer') {
          await publication.stream(
            f.remote.askInConversation(
              'Q',
              'desktop',
              current: () => publication.current,
            ),
          );
        } else {
          await publication.action(
            f.remote.commandCurrent(Operation.meetingsEnhance, {
              'id': 3,
            }, () => publication.current),
          );
        }
        expect(publication.current, isFalse);
        expect(publication.values, isEmpty);
        expect(publication.errors, isEmpty);
        expect(publication.finalizers, 0);
        final method = kind == 'answer' ? 'answer.stream' : 'meetings.enhance';
        expect(f.requests.where((r) => r['method'] == method), hasLength(1));
      },
    );
  }
}
