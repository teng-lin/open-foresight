import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:foresight_core/src/read_coordinator.dart';
import 'package:foresight_core/src/rpc_error.dart';
import 'package:test/test.dart';

final class GatedReadWorker implements ReadWorker {
  final requests = <ReadWorkerRequest>[];
  final pending = <Completer<ReadWorkerReply>>[];
  int closes = 0;
  Object? closeError;
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
  Future<void> close() async {
    closes++;
    if (closeError != null) throw closeError!;
  }
}

final class _Waiter {
  final void Function() notify;
  _Waiter(this.notify);
}

/// Bounded like SqliteReadWorker: the oldest reservation runs, later ones
/// queue, excess is refused before reserving, and only actual releases notify.
final class HeldAdmissionWorker
    implements ReadWorker, ReadQueueCancellation, ReadAdmissionAvailability {
  HeldAdmissionWorker(this.capacity, {this.claimsCapacity = false});
  final int capacity;
  // A contract violation: reports capacity while refusing admission.
  final bool claimsCapacity;
  final requests = <ReadWorkerRequest>[];
  final waiters = <_Waiter>[];
  final _held = <ReadWorkerRequest, Completer<ReadWorkerReply>>{};
  int refusals = 0, closes = 0;
  bool closed = false;
  // Registrations still held when an owner closes this worker.
  int? waitersAtClose;

  int get reserved => _held.length;

  @override
  bool get admitsRead => claimsCapacity || closed || _held.length < capacity;

  @override
  Future<ReadWorkerReply> read(ReadWorkerRequest request) {
    if (closed) {
      return Future.error(RpcError(RpcErrorCode.cancelled, 'Reader closed'));
    }
    if (_held.length >= capacity) {
      refusals++;
      return Future.error(ReadAdmissionRejected());
    }
    requests.add(request);
    return (_held[request] = Completer<ReadWorkerReply>()).future;
  }

  @override
  void Function() whenAdmissionAvailable(void Function() onAvailable) {
    final waiter = _Waiter(onAvailable);
    waiters.add(waiter);
    if (admitsRead) scheduleMicrotask(_drain);
    return () => waiters.remove(waiter);
  }

  void _drain() {
    while (waiters.isNotEmpty && admitsRead) {
      waiters.removeAt(0).notify();
    }
  }

  void complete(int index, String epoch, Object? value) {
    _held.remove(requests[index])!.complete(ReadWorkerReply(epoch, value));
    _drain();
  }

  /// Settles several reservations before one notification pass.
  void completeAll(List<int> indexes, String epoch, Object? value) {
    for (final index in indexes) {
      _held.remove(requests[index])!.complete(ReadWorkerReply(epoch, value));
    }
    _drain();
  }

  void fail(int index, Object error) {
    _held.remove(requests[index])!.completeError(error);
    _drain();
  }

  @override
  bool cancelQueued(ReadWorkerRequest request) {
    if (!_held.containsKey(request) || identical(_held.keys.first, request)) {
      return false;
    }
    _held
        .remove(request)!
        .completeError(
          RpcError(RpcErrorCode.cancelled, 'Queued read cancelled'),
        );
    scheduleMicrotask(_drain);
    return true;
  }

  @override
  Future<void> close() async {
    closes++;
    waitersAtClose ??= waiters.length;
    closed = true;
    _drain();
  }
}

/// A legacy worker that refuses with the typed error but offers no signal.
final class RefusingReadWorker implements ReadWorker {
  int reads = 0;
  @override
  Future<ReadWorkerReply> read(ReadWorkerRequest request) {
    reads++;
    return Future.error(ReadAdmissionRejected());
  }

  @override
  Future<void> close() async {}
}

ReadQuery<String> _numbered(Object name) => ReadQuery<String>(
  projection: 'fixture',
  arguments: {'n': name},
  decode: (value) => value as String,
);

Object? _number(ReadWorkerRequest request) => request.arguments['n'];

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

  test('failed worker teardown still retires the reader exactly once', () {
    fakeAsync((clock) {
      final worker = GatedReadWorker();
      var closedOwners = 0, activityClosed = false;
      final coordinator = ReadCoordinator(
        identity: _identity,
        worker: worker,
        onClosed: () => closedOwners++,
      );
      final activity = coordinator.activityChanges.listen(
        (_) {},
        onDone: () => activityClosed = true,
      );
      final received = <ReadResult<String>>[];
      var readerClosed = false;
      final subscription = coordinator
          .watch(query)
          .listen(received.add, onDone: () => readerClosed = true);
      clock.flushMicrotasks();
      worker.complete(0, 'epoch', 'accepted before shutdown');
      clock.flushMicrotasks();
      expect(received.single.value, 'accepted before shutdown');
      expect(coordinator.trackedQueries, 1);

      final failure = StateError('worker teardown failed');
      worker.closeError = failure;
      Object? reported;
      final closing = coordinator.close();
      unawaited(
        closing.then<void>(
          (_) => fail('Worker teardown failure must reach the owner'),
          onError: (Object error) {
            reported = error;
          },
        ),
      );
      expect(coordinator.close(), same(closing));
      clock.flushMicrotasks();
      expect(reported, same(failure));
      expect(worker.closes, 1);
      expect(closedOwners, 1);
      expect(activityClosed, isTrue);
      expect(readerClosed, isTrue);
      expect(received.map((value) => value.freshness), [
        ReadFreshness.current,
        ReadFreshness.cancelled,
      ]);
      expect(received.last.value, isNull);
      expect(coordinator.trackedQueries, 0);
      expect(coordinator.activeReads, 0);

      ReadResult<String>? retired;
      unawaited(coordinator.read(query).then((value) => retired = value));
      clock.flushMicrotasks();
      expect(retired!.freshness, ReadFreshness.cancelled);
      expect(retired!.value, isNull);
      expect(retired!.error!.code, RpcErrorCode.cancelled);
      expect(worker.requests, hasLength(1));
      expect(coordinator.close(), same(closing));
      expect(worker.closes, 1);
      expect(closedOwners, 1);
      expect(clock.nonPeriodicTimerCount, 0);
      unawaited(subscription.cancel());
      unawaited(activity.cancel());
      clock.flushMicrotasks();
    });
  });

  test('watches beyond held capacity wait for actual releases, not timers', () {
    fakeAsync((clock) {
      final worker = HeldAdmissionWorker(2);
      final coordinator = ReadCoordinator(identity: _identity, worker: worker);
      final received = {for (var i = 0; i < 5; i++) i: <ReadResult<String>>[]};
      final subscriptions = [
        for (var i = 0; i < 5; i++)
          coordinator.watch(_numbered(i)).listen(received[i]!.add),
      ];
      clock.flushMicrotasks();
      expect(worker.requests.map(_number), [0, 1]);
      expect(coordinator.awaitingAdmission, 3);
      expect(worker.waiters, hasLength(1));
      clock.elapse(const Duration(seconds: 10));
      expect(worker.requests, hasLength(2));
      expect(worker.refusals, 0);
      expect(clock.periodicTimerCount, 0);
      expect(received.values.expand((events) => events), isEmpty);
      worker.complete(0, 'epoch', 'value-0');
      clock.flushMicrotasks();
      expect(worker.requests.map(_number), [0, 1, 2]);
      expect(received[0]!.single.value, 'value-0');
      for (var i = 1; i < 5; i++) {
        worker.complete(i, 'epoch', 'value-$i');
        clock.flushMicrotasks();
      }
      expect(worker.requests.map(_number), [0, 1, 2, 3, 4]);
      for (var i = 0; i < 5; i++) {
        expect(received[i]!.single.current, isTrue);
        expect(received[i]!.single.value, 'value-$i');
      }
      expect(worker.refusals, 0);
      expect(coordinator.awaitingAdmission, 0);
      expect(worker.waiters, isEmpty);
      for (final subscription in subscriptions) {
        unawaited(subscription.cancel());
      }
      unawaited(coordinator.close());
      clock.flushMicrotasks();
      expect(clock.nonPeriodicTimerCount, 0);
    });
  });

  test('cancelled waiters never dispatch; queued cancellation readmits', () {
    fakeAsync((clock) {
      final worker = HeldAdmissionWorker(2);
      final coordinator = ReadCoordinator(identity: _identity, worker: worker);
      final values = <int, String?>{};
      final subscriptions = {
        for (var i = 0; i < 4; i++)
          i: coordinator
              .watch(_numbered(i))
              .listen((result) => values[i] = result.value),
      };
      clock.flushMicrotasks();
      expect(worker.requests.map(_number), [0, 1]);
      unawaited(subscriptions[2]!.cancel());
      // Leaving withdraws the waiting entry at once, not at entry release.
      expect(coordinator.awaitingAdmission, 1);
      clock.flushMicrotasks();
      expect(coordinator.awaitingAdmission, 1);
      expect(worker.requests, hasLength(2));
      // The undispatched worker reservation is withdrawn, which is an actual
      // release; the running reservation is not interrupted.
      unawaited(subscriptions[1]!.cancel());
      unawaited(subscriptions[0]!.cancel());
      clock.flushMicrotasks();
      expect(worker.requests.map(_number), [0, 1, 3]);
      expect(worker.reserved, 2);
      expect(coordinator.activeReads, 2);
      worker.complete(0, 'epoch', 'unused');
      worker.complete(2, 'epoch', 'value-3');
      clock.flushMicrotasks();
      expect(values, {3: 'value-3'});
      expect(worker.requests.map(_number), [0, 1, 3]);
      expect(coordinator.trackedQueries, 1);
      unawaited(subscriptions[3]!.cancel());
      unawaited(coordinator.close());
      clock.flushMicrotasks();
      expect(worker.waiters, isEmpty);
    });
  });

  test('the last waiting subscriber withdraws the worker registration', () {
    fakeAsync((clock) {
      final worker = HeldAdmissionWorker(1);
      final coordinator = ReadCoordinator(identity: _identity, worker: worker);
      final running = coordinator.watch(_numbered(0)).listen((_) {});
      final waiting = coordinator.watch(_numbered(1)).listen((_) {});
      clock.flushMicrotasks();
      expect(worker.waiters, hasLength(1));
      unawaited(waiting.cancel());
      expect(worker.waiters, isEmpty);
      worker.complete(0, 'epoch', 'value');
      clock.flushMicrotasks();
      expect(worker.requests, hasLength(1));
      unawaited(running.cancel());
      unawaited(coordinator.close());
      clock.flushMicrotasks();
    });
  });

  test('new work cannot pass waiters while a deferred release is pending', () {
    fakeAsync((clock) {
      final worker = HeldAdmissionWorker(2);
      final coordinator = ReadCoordinator(identity: _identity, worker: worker);
      final idle = coordinator.watch(_numbered(0)).listen((_) {});
      clock.flushMicrotasks();
      worker.complete(0, 'epoch', 'value-0');
      clock.flushMicrotasks();
      final running = coordinator.watch(_numbered(1)).listen((_) {});
      final queued = coordinator.watch(_numbered(2)).listen((_) {});
      final waiting = coordinator.watch(_numbered(3)).listen((_) {});
      clock.flushMicrotasks();
      expect(worker.requests.map(_number), [0, 1, 2]);
      // Queued cancellation frees a slot now but notifies from a microtask;
      // an invalidation in between must still queue behind the waiter.
      unawaited(queued.cancel());
      expect(worker.admitsRead, isTrue);
      coordinator.invalidate();
      clock.flushMicrotasks();
      expect(worker.requests.map(_number), [0, 1, 2, 3]);
      worker.complete(1, 'epoch', 'value-1');
      clock.flushMicrotasks();
      expect(worker.requests.map(_number), [0, 1, 2, 3, 0]);
      unawaited(idle.cancel());
      unawaited(running.cancel());
      unawaited(waiting.cancel());
      unawaited(coordinator.close());
      clock.flushMicrotasks();
    });
  });

  test(
    'waiting subscribers keep their deadline; retained entries their turn',
    () {
      fakeAsync((clock) {
        final worker = HeldAdmissionWorker(1);
        final coordinator = ReadCoordinator(
          identity: _identity,
          worker: worker,
        );
        final first = <ReadResult<String>>[];
        final waiting = <ReadResult<String>>[];
        final held = coordinator.watch(_numbered(0)).listen(first.add);
        final retained = coordinator.watch(_numbered(1)).listen(waiting.add);
        ReadResult<String>? oneShot;
        unawaited(
          coordinator.read(_numbered(2)).then((value) => oneShot = value),
        );
        clock.flushMicrotasks();
        expect(worker.requests.map(_number), [0]);
        expect(coordinator.awaitingAdmission, 2);
        clock.elapse(const Duration(seconds: 30));
        expect(first.single.freshness, ReadFreshness.busy);
        expect(waiting.single.freshness, ReadFreshness.busy);
        expect(waiting.single.error!.code, RpcErrorCode.busy);
        expect(oneShot!.freshness, ReadFreshness.busy);
        expect(oneShot!.value, isNull);
        // The settled one-shot leaves; the still-subscribed watch is retained.
        expect(coordinator.awaitingAdmission, 1);
        expect(worker.requests, hasLength(1));
        worker.complete(0, 'epoch', 'expired');
        clock.flushMicrotasks();
        // The waiting key keeps its turn ahead of the expired key's refresh.
        expect(worker.requests.map(_number), [0, 1]);
        worker.complete(1, 'epoch', 'value-1');
        clock.flushMicrotasks();
        expect(waiting.last.current, isTrue);
        expect(waiting.last.value, 'value-1');
        expect(worker.requests.map(_number), [0, 1, 0]);
        worker.complete(2, 'epoch', 'fresh');
        clock.flushMicrotasks();
        expect(first.last.value, 'fresh');
        expect(worker.requests.map(_number), isNot(contains(2)));
        unawaited(held.cancel());
        unawaited(retained.cancel());
        unawaited(coordinator.close());
        clock.flushMicrotasks();
        expect(clock.nonPeriodicTimerCount, 0);
      });
    },
  );

  test('a waiting request samples owner identity at actual admission', () {
    fakeAsync((clock) {
      var epoch = 'old';
      final worker = HeldAdmissionWorker(1);
      final coordinator = ReadCoordinator(
        identity: () => _identity(epoch: epoch),
        worker: worker,
      );
      final first = <ReadResult<String>>[];
      final second = <ReadResult<String>>[];
      final a = coordinator.watch(_numbered(0)).listen(first.add);
      final b = coordinator.watch(_numbered(1)).listen(second.add);
      clock.flushMicrotasks();
      expect(worker.requests.single.identity.epoch, 'old');
      epoch = 'new';
      coordinator.invalidate();
      worker.complete(0, 'old', 'retired workspace');
      clock.flushMicrotasks();
      expect(first, isEmpty);
      expect(worker.requests.map(_number), [0, 1]);
      expect(worker.requests[1].identity.epoch, 'new');
      worker.complete(1, 'new', 'value-1');
      clock.flushMicrotasks();
      expect(second.single.current, isTrue);
      expect(second.single.value, 'value-1');
      expect(worker.requests.map(_number), [0, 1, 0]);
      expect(worker.requests[2].identity.epoch, 'new');
      worker.complete(2, 'new', 'value-0');
      clock.flushMicrotasks();
      expect(first.single.value, 'value-0');
      unawaited(a.cancel());
      unawaited(b.cancel());
      unawaited(coordinator.close());
      clock.flushMicrotasks();
    });
  });

  test('a continuously invalidated key cannot starve waiting keys', () {
    fakeAsync((clock) {
      final worker = HeldAdmissionWorker(1);
      final coordinator = ReadCoordinator(identity: _identity, worker: worker);
      final subscriptions = [
        for (var i = 0; i < 3; i++)
          coordinator.watch(_numbered(i)).listen((_) {}),
      ];
      clock.flushMicrotasks();
      for (var index = 0; index < 5; index++) {
        for (var i = 0; i < 10; i++) {
          coordinator.invalidate();
        }
        worker.complete(index, 'epoch', 'value');
        clock.flushMicrotasks();
      }
      expect(worker.requests.map(_number), [0, 1, 2, 0, 1, 2]);
      expect(worker.refusals, 0);
      for (final subscription in subscriptions) {
        unawaited(subscription.cancel());
      }
      unawaited(coordinator.close());
      clock.flushMicrotasks();
    });
  });

  test('coordinators and direct reads sharing capacity rotate fairly', () {
    fakeAsync((clock) {
      final worker = HeldAdmissionWorker(2);
      final x = ReadCoordinator(identity: _identity, worker: worker);
      final y = ReadCoordinator(identity: _identity, worker: worker);
      // Direct reservations hold the shared capacity before either reader.
      for (final name in ['e0', 'e1']) {
        unawaited(
          worker.read(
            ReadWorkerRequest(
              projection: 'fixture',
              arguments: {'n': name},
              identity: _identity(),
              sequence: 0,
            ),
          ),
        );
      }
      final subscriptions = [
        for (var i = 0; i < 3; i++) x.watch(_numbered('x$i')).listen((_) {}),
      ];
      clock.flushMicrotasks();
      subscriptions.addAll([
        for (var i = 0; i < 3; i++) y.watch(_numbered('y$i')).listen((_) {}),
      ]);
      clock.flushMicrotasks();
      expect(worker.waiters, hasLength(2));
      expect(x.awaitingAdmission + y.awaitingAdmission, 6);
      // Two slots released in one notification pass go one to each reader.
      worker.completeAll([0, 1], 'epoch', 'value');
      clock.flushMicrotasks();
      expect(worker.requests.map(_number), ['e0', 'e1', 'x0', 'y0']);
      for (var i = 2; i < 6; i++) {
        worker.complete(i, 'epoch', 'value');
        clock.flushMicrotasks();
      }
      expect(worker.requests.map(_number), [
        'e0',
        'e1',
        'x0',
        'y0',
        'x1',
        'y1',
        'x2',
        'y2',
      ]);
      worker.completeAll([6, 7], 'epoch', 'value');
      clock.flushMicrotasks();
      expect(worker.waiters, isEmpty);
      expect(worker.refusals, 0);
      for (final subscription in subscriptions) {
        unawaited(subscription.cancel());
      }
      unawaited(x.close());
      unawaited(y.close());
      clock.flushMicrotasks();
    });
  });

  test(
    'reentrant invalidation from a dispatch failure keeps one registration',
    () {
      fakeAsync((clock) {
        final worker = HeldAdmissionWorker(1);
        final x = ReadCoordinator(identity: _identity, worker: worker);
        final y = ReadCoordinator(identity: _identity, worker: worker);
        // Dispatch sampling fails synchronously inside admission; its failure
        // listener invalidates while that admission is still on the stack.
        final failing = ReadQuery<String>(
          projection: 'fixture',
          arguments: {'n': 'b'},
          decode: (value) => value as String,
          dispatchArguments: () => throw StateError('dispatch moved'),
        );
        var invalidated = false;
        final failures = <ReadResult<String>>[];
        final subscriptions = [
          x.watch(_numbered('a')).listen((_) {}),
          x.watch(failing).listen((event) {
            failures.add(event);
            if (!invalidated) {
              invalidated = true;
              x.invalidate();
            }
          }),
          x.watch(_numbered('c')).listen((_) {}),
          x.watch(_numbered('d')).listen((_) {}),
        ];
        clock.flushMicrotasks();
        final ySubscriptions = [
          y.watch(_numbered('y0')).listen((_) {}),
          y.watch(_numbered('y1')).listen((_) {}),
        ];
        clock.flushMicrotasks();
        expect(worker.requests.map(_number), ['a']);
        expect(worker.waiters, hasLength(2));
        worker.complete(0, 'epoch', 'value');
        clock.flushMicrotasks();
        expect(failures.single.freshness, ReadFreshness.failed);
        expect(invalidated, isTrue);
        // One registration per waiting coordinator, never an orphaned second.
        expect(worker.waiters, hasLength(2));
        for (var i = 1; i < 3; i++) {
          worker.complete(i, 'epoch', 'value');
          clock.flushMicrotasks();
        }
        // The reentrant failure gives x no extra turn ahead of y.
        expect(worker.requests.map(_number), ['a', 'y0', 'c', 'y1']);
        expect(worker.waiters, hasLength(1));
        // d, plus a and b, which the reentrant invalidation marked pending.
        expect(x.awaitingAdmission, 3);
        unawaited(x.close());
        clock.flushMicrotasks();
        // The closing owner withdrew its only registration before disposal;
        // no callback into the closed coordinator remains with the worker.
        expect(worker.waitersAtClose, 0);
        worker.complete(3, 'epoch', 'value');
        clock.flushMicrotasks();
        expect(worker.requests, hasLength(4));
        for (final subscription in [...subscriptions, ...ySubscriptions]) {
          unawaited(subscription.cancel());
        }
        unawaited(y.close());
        clock.flushMicrotasks();
      });
    },
  );

  test('close withdraws waiting admission and joins only actual reads', () {
    fakeAsync((clock) {
      final worker = HeldAdmissionWorker(1);
      final coordinator = ReadCoordinator(identity: _identity, worker: worker);
      final waiting = <ReadResult<String>>[];
      coordinator.watch(_numbered(0)).listen((_) {});
      coordinator.watch(_numbered(1)).listen(waiting.add);
      clock.flushMicrotasks();
      expect(worker.waiters, hasLength(1));
      var closed = false;
      unawaited(coordinator.close().then((_) => closed = true));
      clock.flushMicrotasks();
      expect(waiting.single.freshness, ReadFreshness.cancelled);
      expect(worker.waiters, isEmpty);
      expect(coordinator.awaitingAdmission, 0);
      expect(worker.closes, 0);
      expect(closed, isFalse);
      worker.complete(0, 'epoch', 'late ignored');
      clock.flushMicrotasks();
      expect(worker.closes, 1);
      expect(closed, isTrue);
      expect(worker.requests, hasLength(1));
      expect(clock.nonPeriodicTimerCount, 0);
    });
  });

  test(
    'refusal without an exact capacity signal is published, not retried',
    () {
      fakeAsync((clock) {
        final legacy = RefusingReadWorker();
        final claiming = HeldAdmissionWorker(1, claimsCapacity: true);
        final legacyReader = ReadCoordinator(
          identity: _identity,
          worker: legacy,
        );
        final claimingReader = ReadCoordinator(
          identity: _identity,
          worker: claiming,
        );
        final legacyEvents = <ReadResult<String>>[];
        final claimingEvents = <ReadResult<String>>[];
        final subscriptions = [
          legacyReader.watch(query).listen(legacyEvents.add),
          claimingReader.watch(_numbered(0)).listen((_) {}),
          claimingReader.watch(_numbered(1)).listen(claimingEvents.add),
        ];
        clock.flushMicrotasks();
        clock.elapse(const Duration(seconds: 60));
        for (final events in [legacyEvents, claimingEvents]) {
          expect(events.single.freshness, ReadFreshness.failed);
          expect(events.single.error, isA<ReadAdmissionRejected>());
          expect(events.single.error!.code, RpcErrorCode.busy);
          expect(events.single.error!.message, 'Read queue is full');
        }
        expect(legacy.reads, 1);
        expect(claiming.refusals, 1);
        for (final subscription in subscriptions) {
          unawaited(subscription.cancel());
        }
        claiming.complete(0, 'epoch', 'value');
        unawaited(legacyReader.close());
        unawaited(claimingReader.close());
        clock.flushMicrotasks();
      });
    },
  );

  test('busy SQL execution is a published failure, not an admission wait', () {
    fakeAsync((clock) {
      final worker = HeldAdmissionWorker(2);
      final coordinator = ReadCoordinator(identity: _identity, worker: worker);
      final slow = <ReadResult<String>>[];
      final waiting = <ReadResult<String>>[];
      final subscriptions = [
        coordinator.watch(_numbered(0)).listen((_) {}),
        coordinator.watch(_numbered(1)).listen(slow.add),
        coordinator.watch(_numbered(2)).listen(waiting.add),
      ];
      clock.flushMicrotasks();
      final budget = RpcError(RpcErrorCode.busy, 'Read exceeded its budget');
      worker.fail(1, budget);
      clock.flushMicrotasks();
      // Capacity is held again by the readmitted waiter when the SQL failure
      // is observed; only the type distinguishes admission from execution.
      expect(worker.admitsRead, isFalse);
      expect(slow.single.freshness, ReadFreshness.failed);
      expect(slow.single.error, same(budget));
      expect(worker.requests.map(_number), [0, 1, 2]);
      worker.complete(2, 'epoch', 'value-2');
      clock.flushMicrotasks();
      expect(waiting.single.value, 'value-2');
      expect(worker.requests, hasLength(3));
      for (final subscription in subscriptions) {
        unawaited(subscription.cancel());
      }
      worker.complete(0, 'epoch', 'unused');
      unawaited(coordinator.close());
      clock.flushMicrotasks();
    });
  });

  test('typed admission refusal keeps the generic busy wire shape', () {
    final refusal = ReadAdmissionRejected();
    expect(refusal, isA<RpcError>());
    expect(refusal.toJson(), {'code': 'busy', 'message': 'Read queue is full'});
    expect(RpcError.from(refusal), same(refusal));
    final decoded = RpcError.from(refusal.toJson());
    expect(decoded.code, RpcErrorCode.busy);
    expect(decoded.message, 'Read queue is full');
  });
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
