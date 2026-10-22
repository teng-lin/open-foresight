import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:foresight_core/src/read_coordinator.dart';
import 'package:foresight_core/src/rpc_error.dart';
import 'package:test/test.dart';

final class GatedReadWorker implements ReadWorker {
  final requests = <ReadWorkerRequest>[];
  final pending = <Completer<ReadWorkerReply>>[];
  int closes = 0;
  @override
  Future<ReadWorkerReply> read(ReadWorkerRequest request) {
    requests.add(request);
    final result = Completer<ReadWorkerReply>();
    pending.add(result);
    return result.future;
  }

  void complete(int index, String epoch, Object? value) =>
      pending[index].complete(ReadWorkerReply(epoch, value));

  @override
  Future<void> close() async => closes++;
}

void main() {
  final query = ReadQuery<String>(
    projection: 'fixture',
    decode: (value) => value as String,
  );

  test('late watchers and reads refresh an idle active key without replay', () {
    fakeAsync((clock) {
      final worker = GatedReadWorker();
      var revision = 'one';
      final coordinator = ReadCoordinator(
        identity: () => _identity(revision: revision),
        worker: worker,
      );
      final first = <ReadResult<String>>[];
      final second = <ReadResult<String>>[];
      final subscription = coordinator.watch(query).listen(first.add);
      clock.flushMicrotasks();
      worker.complete(0, 'epoch', 'old');
      clock.flushMicrotasks();
      revision = 'two';
      final late = coordinator.watch(query).listen(second.add);
      ReadResult<String>? read;
      unawaited(coordinator.read(query).then((value) => read = value));
      clock.flushMicrotasks();
      expect(second, isEmpty);
      expect(read, isNull);
      expect(worker.requests, hasLength(2));
      expect(coordinator.activeReads, 1);
      expect(coordinator.pendingRefreshes, 0);
      worker.complete(1, 'epoch', 'new');
      clock.flushMicrotasks();
      expect(second.single.value, 'new');
      expect(second.single.current, isTrue);
      expect(second.single.requestTag, 'two');
      expect(read!.value, 'new');
      expect(read!.current, isTrue);
      unawaited(subscription.cancel());
      unawaited(late.cancel());
      unawaited(coordinator.close());
      clock.flushMicrotasks();
    });
  });

  test('late in-flight listeners share work and one pending refresh', () {
    fakeAsync((clock) {
      final worker = GatedReadWorker();
      final coordinator = ReadCoordinator(identity: _identity, worker: worker);
      final stream = coordinator.watch(query);
      final first = <ReadResult<String>>[];
      final second = <ReadResult<String>>[];
      final initial = stream.listen(first.add);
      clock.flushMicrotasks();
      final late = stream.listen(second.add);
      ReadResult<String>? result;
      unawaited(coordinator.read(query).then((value) => result = value));
      clock.flushMicrotasks();
      expect(worker.requests, hasLength(1));
      expect(coordinator.pendingRefreshes, 1);
      worker.complete(0, 'epoch', 'shared');
      clock.flushMicrotasks();
      expect(first.single.value, 'shared');
      expect(second.single.value, 'shared');
      expect(result!.value, 'shared');
      expect(worker.requests, hasLength(2));
      unawaited(initial.cancel());
      unawaited(late.cancel());
      worker.complete(1, 'epoch', 'unused refresh');
      clock.flushMicrotasks();
      final revisited = <ReadResult<String>>[];
      final revisit = stream.listen(revisited.add);
      clock.flushMicrotasks();
      expect(worker.requests, hasLength(3));
      worker.complete(2, 'epoch', 'revisited');
      clock.flushMicrotasks();
      expect(revisited.single.value, 'revisited');
      unawaited(revisit.cancel());
      unawaited(coordinator.close());
      clock.flushMicrotasks();
    });
  });

  test('late subscribers to timed-out work have their own bounded wait', () {
    fakeAsync((clock) {
      final worker = GatedReadWorker();
      final coordinator = ReadCoordinator(identity: _identity, worker: worker);
      final first = <ReadResult<String>>[];
      final subscription = coordinator.watch(query).listen(first.add);
      clock.flushMicrotasks();
      clock.elapse(const Duration(seconds: 30));
      expect(first.single.freshness, ReadFreshness.busy);
      ReadResult<String>? result;
      unawaited(coordinator.read(query).then((value) => result = value));
      final cancelledEvents = <ReadResult<String>>[];
      final cancelled = coordinator.watch(query).listen(cancelledEvents.add);
      clock.flushMicrotasks();
      unawaited(cancelled.cancel());
      clock.elapse(const Duration(seconds: 29));
      expect(result, isNull);
      expect(coordinator.activeReads, 1);
      expect(coordinator.pendingRefreshes, 1);
      clock.elapse(const Duration(seconds: 1));
      expect(result!.freshness, ReadFreshness.busy);
      expect(result!.value, isNull);
      expect(result!.error!.code, RpcErrorCode.busy);
      expect(cancelledEvents, isEmpty);
      expect(worker.requests, hasLength(1));
      worker.complete(0, 'epoch', 'expired');
      clock.flushMicrotasks();
      worker.complete(1, 'epoch', 'fresh');
      clock.flushMicrotasks();
      expect(first.last.value, 'fresh');
      unawaited(subscription.cancel());
      unawaited(coordinator.close());
      clock.flushMicrotasks();
      expect(clock.nonPeriodicTimerCount, 0);
    });
  });

  test('a subscriber deadline bounds repeated discarded owner results', () {
    fakeAsync((clock) {
      var epoch = 'epoch';
      final worker = GatedReadWorker();
      final coordinator = ReadCoordinator(
        identity: () => _identity(epoch: epoch),
        worker: worker,
      );
      ReadResult<String>? result;
      unawaited(coordinator.read(query).then((value) => result = value));
      clock.flushMicrotasks();
      for (var index = 0; index < 3; index++) {
        clock.elapse(const Duration(seconds: 9));
        epoch = 'epoch-$index';
        worker.complete(index, 'retired', 'private body');
        clock.flushMicrotasks();
        expect(result, isNull);
      }
      clock.elapse(const Duration(seconds: 3));
      expect(result!.freshness, ReadFreshness.busy);
      expect(result!.value, isNull);
      worker.complete(3, epoch, 'ignored after cancellation');
      clock.flushMicrotasks();
      unawaited(coordinator.close());
      clock.flushMicrotasks();
    });
  });

  test(
    'retired query entries release cached projections after actual settlement',
    () {
      fakeAsync((clock) {
        final worker = GatedReadWorker();
        final coordinator = ReadCoordinator(
          identity: _identity,
          worker: worker,
        );
        final subscription = coordinator.watch(query).listen((_) {});
        clock.flushMicrotasks();
        unawaited(subscription.cancel());
        clock.flushMicrotasks();
        expect(coordinator.trackedQueries, 1);
        expect(coordinator.activeReads, 1);
        worker.complete(0, 'epoch', 'retired document body');
        clock.flushMicrotasks();
        expect(coordinator.trackedQueries, 0);
        expect(coordinator.activeReads, 0);
        unawaited(coordinator.close());
        clock.flushMicrotasks();
      });
    },
  );

  test('a synchronous result listener can close its owning reader', () {
    fakeAsync((clock) {
      final worker = GatedReadWorker();
      final coordinator = ReadCoordinator(identity: _identity, worker: worker);
      Future<void>? closing;
      final received = <ReadResult<String>>[];
      coordinator.watch(query).listen((event) {
        received.add(event);
        closing ??= coordinator.close();
      });
      clock.flushMicrotasks();
      worker.complete(0, 'epoch', 'snapshot');
      clock.flushMicrotasks();
      expect(received.map((event) => event.freshness), [
        ReadFreshness.current,
        ReadFreshness.cancelled,
      ]);
      expect(worker.closes, 1);
      expect(coordinator.trackedQueries, 0);
    });
  });

  test(
    'query scheduling identity includes scope and normalized parameters',
    () {
      ReadQuery<String> make(String scope, Map<String, Object?> args) =>
          ReadQuery(
            projection: 'fixture',
            scope: scope,
            arguments: args,
            decode: (value) => value as String,
          );
      final args = <String, Object?>{
        'z': <String>['one'],
        'a': 1,
      };
      final first = make('meeting', args);
      (args['z'] as List<String>).add('two');
      expect(first.arguments['z'], ['one']);
      expect(
        first.key,
        make('meeting', {
          'a': 1,
          'z': ['one'],
        }).key,
      );
      expect(first.key, isNot(make('workspace', first.arguments).key));
      expect(() => first.arguments['new'] = 1, throwsUnsupportedError);
    },
  );

  test('unchanged owner accepts a current projection with its request tag', () {
    fakeAsync((clock) {
      final worker = GatedReadWorker();
      final coordinator = ReadCoordinator(identity: _identity, worker: worker);
      final received = <ReadResult<String>>[];
      final subscription = coordinator.watch(query).listen(received.add);
      clock.flushMicrotasks();
      expect(coordinator.activeReads, 1);
      worker.complete(0, 'epoch', 'committed');
      clock.flushMicrotasks();
      expect(received.single.freshness, ReadFreshness.current);
      expect(received.single.value, 'committed');
      expect(received.single.requestTag, 'local-token');
      expect(coordinator.busy, isFalse);
      unawaited(subscription.cancel());
      unawaited(coordinator.close());
      clock.flushMicrotasks();
      expect(worker.closes, 1);
    });
  });

  test('sustained writes publish previews with one active and one refresh', () {
    fakeAsync((clock) {
      var revision = 'one';
      final worker = GatedReadWorker();
      final coordinator = ReadCoordinator(
        identity: () => _identity(revision: revision),
        worker: worker,
      );
      final received = <ReadResult<String>>[];
      final subscription = coordinator.watch(query).listen(received.add);
      clock.flushMicrotasks();
      revision = 'two';
      for (var i = 0; i < 100; i++) {
        coordinator.invalidate();
      }
      expect(worker.requests, hasLength(1));
      expect(coordinator.pendingRefreshes, 1);
      worker.complete(0, 'epoch', 'first snapshot');
      clock.flushMicrotasks();
      expect(received.single.freshness, ReadFreshness.preview);
      expect(received.single.requestTag, 'one');
      expect(worker.requests, hasLength(2));
      revision = 'three';
      coordinator.invalidate();
      worker.complete(1, 'epoch', 'second snapshot');
      clock.flushMicrotasks();
      expect(received.last.freshness, ReadFreshness.preview);
      expect(worker.requests, hasLength(3));
      worker.complete(2, 'epoch', 'final commit');
      clock.flushMicrotasks();
      expect(received.last.current, isTrue);
      expect(received.last.value, 'final commit');
      expect(received.map((r) => r.sequence), [1, 2, 3]);
      expect(coordinator.activeReads, 0);
      unawaited(subscription.cancel());
      unawaited(coordinator.close());
      clock.flushMicrotasks();
    });
  });

  for (final replacement in ['owner', 'profile', 'connection', 'epoch']) {
    test('$replacement replacement rejects a coincident local token', () {
      fakeAsync((clock) {
        var replaced = false;
        ReadIdentity identity() => ReadIdentity(
          owner: replaced && replacement == 'owner' ? 'next' : 'owner',
          profile: replaced && replacement == 'profile' ? 'next' : 'profile',
          connection: replaced && replacement == 'connection'
              ? 'next'
              : 'connection',
          epoch: replaced && replacement == 'epoch' ? 'next' : 'epoch',
          revision: 'coincident-local-token',
        );
        final worker = GatedReadWorker();
        final coordinator = ReadCoordinator(identity: identity, worker: worker);
        final received = <ReadResult<String>>[];
        final subscription = coordinator.watch(query).listen(received.add);
        clock.flushMicrotasks();
        replaced = true;
        worker.complete(0, 'epoch', 'retired');
        clock.flushMicrotasks();
        expect(received, isEmpty);
        expect(worker.requests, hasLength(2));
        worker.complete(1, identity().epoch, 'replacement');
        clock.flushMicrotasks();
        expect(received.single.value, 'replacement');
        expect(received.single.current, isTrue);
        unawaited(subscription.cancel());
        unawaited(coordinator.close());
        clock.flushMicrotasks();
      });
    });
  }

  test('actual snapshot epoch must match even when the owner token agrees', () {
    fakeAsync((clock) {
      final worker = GatedReadWorker();
      final coordinator = ReadCoordinator(identity: _identity, worker: worker);
      final received = <ReadResult<String>>[];
      final subscription = coordinator.watch(query).listen(received.add);
      clock.flushMicrotasks();
      worker.complete(0, 'a different workspace', 'wrong');
      clock.flushMicrotasks();
      expect(received, isEmpty);
      worker.complete(1, 'epoch', 'right');
      clock.flushMicrotasks();
      expect(received.single.value, 'right');
      unawaited(subscription.cancel());
      unawaited(coordinator.close());
      clock.flushMicrotasks();
    });
  });

  test('leaving and revisiting the same query retires the old request', () {
    fakeAsync((clock) {
      final worker = GatedReadWorker();
      final coordinator = ReadCoordinator(identity: _identity, worker: worker);
      final first = coordinator
          .watch(query)
          .listen((_) => fail('Retired view'));
      clock.flushMicrotasks();
      unawaited(first.cancel());
      clock.flushMicrotasks();
      final received = <ReadResult<String>>[];
      final second = coordinator.watch(query).listen(received.add);
      clock.flushMicrotasks();
      expect(worker.requests, hasLength(1));
      worker.complete(0, 'epoch', 'old completion');
      clock.flushMicrotasks();
      expect(received, isEmpty);
      expect(worker.requests, hasLength(2));
      worker.complete(1, 'epoch', 'revisited view');
      clock.flushMicrotasks();
      expect(received.single.value, 'revisited view');
      unawaited(second.cancel());
      unawaited(coordinator.close());
      clock.flushMicrotasks();
    });
  });

  test(
    'deadline retains the view while underlying work settles without overlap',
    () {
      fakeAsync((clock) {
        final worker = GatedReadWorker();
        final coordinator = ReadCoordinator(
          identity: _identity,
          worker: worker,
        );
        final received = <ReadResult<String>>[];
        final subscription = coordinator.watch(query).listen(received.add);
        clock.flushMicrotasks();
        worker.complete(0, 'epoch', 'accepted view');
        clock.flushMicrotasks();
        coordinator.invalidate();
        clock.flushMicrotasks();
        clock.elapse(const Duration(seconds: 30));
        expect(received.last.freshness, ReadFreshness.busy);
        expect(received.last.error?.code, RpcErrorCode.busy);
        expect(received.last.retryable, isTrue);
        expect(received.last.value, 'accepted view');
        expect(coordinator.activeReads, 1);
        for (var i = 0; i < 30; i++) {
          coordinator.invalidate();
        }
        expect(worker.requests, hasLength(2));
        worker.complete(1, 'epoch', 'late ignored');
        clock.flushMicrotasks();
        expect(received, hasLength(2));
        expect(worker.requests, hasLength(3));
        worker.complete(2, 'epoch', 'fresh result');
        clock.flushMicrotasks();
        expect(received.last.value, 'fresh result');
        expect(received.last.current, isTrue);
        unawaited(subscription.cancel());
        unawaited(coordinator.close());
        clock.flushMicrotasks();
      });
    },
  );

  test('a deadline cannot retain a value from a replaced workspace', () {
    fakeAsync((clock) {
      var epoch = 'epoch';
      final worker = GatedReadWorker();
      final coordinator = ReadCoordinator(
        identity: () => _identity(epoch: epoch),
        worker: worker,
      );
      final received = <ReadResult<String>>[];
      final subscription = coordinator.watch(query).listen(received.add);
      clock.flushMicrotasks();
      worker.complete(0, 'epoch', 'private old workspace');
      clock.flushMicrotasks();
      coordinator.invalidate();
      clock.flushMicrotasks();
      epoch = 'cleared';
      clock.elapse(const Duration(seconds: 30));
      expect(received.last.freshness, ReadFreshness.busy);
      expect(received.last.value, isNull);
      worker.complete(1, 'epoch', 'late private old workspace');
      clock.flushMicrotasks();
      worker.complete(2, 'cleared', 'new workspace');
      clock.flushMicrotasks();
      expect(received.last.value, 'new workspace');
      unawaited(subscription.cancel());
      unawaited(coordinator.close());
      clock.flushMicrotasks();
    });
  });

  test(
    'close settles callers but joins the underlying read before worker disposal',
    () {
      fakeAsync((clock) {
        final worker = GatedReadWorker();
        final coordinator = ReadCoordinator(
          identity: _identity,
          worker: worker,
        );
        final received = <ReadResult<String>>[];
        var streamClosed = false, cleanupDone = false;
        coordinator
            .watch(query)
            .listen(received.add, onDone: () => streamClosed = true);
        clock.flushMicrotasks();
        unawaited(coordinator.close().then((_) => cleanupDone = true));
        clock.flushMicrotasks();
        expect(received.single.freshness, ReadFreshness.cancelled);
        expect(received.single.error?.code, RpcErrorCode.cancelled);
        expect(streamClosed, isTrue);
        expect(worker.closes, 0);
        expect(cleanupDone, isFalse);
        worker.complete(0, 'epoch', 'late ignored');
        clock.flushMicrotasks();
        expect(received, hasLength(1));
        expect(worker.closes, 1);
        expect(cleanupDone, isTrue);
        unawaited(coordinator.close());
        clock.flushMicrotasks();
        expect(worker.closes, 1);
      });
    },
  );
}

ReadIdentity _identity({
  String epoch = 'epoch',
  String revision = 'local-token',
}) => ReadIdentity(
  owner: 'owner',
  profile: 'profile',
  connection: 'connection',
  epoch: epoch,
  revision: revision,
);
