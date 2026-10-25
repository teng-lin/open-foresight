import 'dart:async';

import 'package:foresight_core/src/generation_runtime_slot.dart';
import 'package:foresight_core/src/rpc_error.dart';
import 'package:test/test.dart';

final class Owner {
  Owner({bool held = false}) {
    if (!held) released.complete();
  }
  final released = Completer<void>();
  int closes = 0;
  bool generating = false;
}

GenerationRuntimeSlot<Owner> slot({void Function()? changed}) =>
    GenerationRuntimeSlot(
      closeRuntime: (owner) => owner.closes++,
      runtimeClosed: (owner) => owner.released.future,
      runtimeBusy: (owner) => owner.generating,
      changed: changed ?? () {},
    );
final cancelled = isA<RpcError>().having(
  (error) => error.code,
  'code',
  RpcErrorCode.cancelled,
);

void main() {
  test(
    'close revokes immediately and joins both held producer and actual retirement',
    () async {
      final owner = Owner(held: true), gate = Completer<void>();
      final runtimes = slot();
      final entered = Completer<void>();
      final producer = runtimes.replace((attempt) async {
        attempt.own(owner);
        entered.complete();
        await gate.future;
        return owner;
      });
      final rejection = expectLater(producer, throwsA(cancelled));
      await entered.future;
      expect(runtimes.visible, same(owner));
      runtimes.stop();
      runtimes.stop();
      expect(runtimes.visible, isNull);
      expect(owner.closes, 1);
      var drained = false;
      final closed = runtimes.drain().then((_) => drained = true);
      await Future<void>.delayed(Duration.zero);
      expect(drained, isFalse);
      owner.released.complete();
      await Future<void>.delayed(Duration.zero);
      expect(
        drained,
        isFalse,
        reason: 'The producer still owns its continuation',
      );
      gate.complete();
      await rejection;
      await closed;
      expect(owner.closes, 1);
      expect(runtimes.busy, isFalse);
    },
  );

  test(
    'replacement joins old retirement and stale adoption cannot replace the winner',
    () async {
      final old = Owner(held: true), obsolete = Owner(), winner = Owner();
      final runtimes = slot();
      await runtimes.replace((_) async => old);
      final attempted = runtimes.replace((attempt) async {
        attempt.own(obsolete);
        return obsolete;
      });
      final rejected = expectLater(attempted, throwsA(cancelled));
      await Future<void>.delayed(Duration.zero);
      expect(old.closes, 1);
      expect(runtimes.installed, isNull);
      expect(runtimes.busy, isTrue);
      var adopted = false;
      final latest = runtimes.replace((_) async => winner).then((value) {
        adopted = true;
        return value;
      });
      await Future<void>.delayed(Duration.zero);
      expect(
        adopted,
        isFalse,
        reason: 'The previous generation still owns retirement',
      );
      old.released.complete();
      await rejected;
      expect(await latest, same(winner));
      expect(runtimes.installed, same(winner));
      expect(obsolete.closes, 1);
      expect(old.closes, 1);
      runtimes.stop();
      await runtimes.drain();
      expect(winner.closes, 1);
    },
  );

  test(
    'late discovery after close is owned before cancellation is reported',
    () async {
      final runtimes = slot(), late = Completer<Owner?>();
      final owner = Owner(held: true);
      final entered = Completer<void>();
      final work = runtimes.replace((_) {
        entered.complete();
        return late.future;
      });
      final rejected = expectLater(work, throwsA(cancelled));
      await entered.future;
      runtimes.stop();
      var drained = false;
      final drain = runtimes.drain().then((_) => drained = true);
      late.complete(owner);
      await Future<void>.delayed(Duration.zero);
      expect(owner.closes, 1);
      expect(drained, isFalse);
      owner.released.complete();
      await rejected;
      await drain;
      expect(runtimes.installed, isNull);
    },
  );

  test(
    'partial failure stays primary while its cleanup is joined once',
    () async {
      final runtimes = slot(), owner = Owner(held: true);
      final primary = StateError('controlled setup failure');
      final started = Completer<void>();
      final work = runtimes.replace((attempt) async {
        attempt.own(owner);
        started.complete();
        throw primary;
      });
      var settled = false;
      final rejected = expectLater(
        work,
        throwsA(same(primary)),
      ).then((_) => settled = true);
      await started.future;
      await Future<void>.delayed(Duration.zero);
      expect(owner.closes, 1);
      expect(settled, isFalse);
      owner.released.complete();
      await rejected;
      runtimes.stop();
      await runtimes.drain();
      expect(owner.closes, 1);
    },
  );

  test(
    'retirement failure remains observable after its original waiter settled',
    () async {
      final runtimes = slot(), owner = Owner(held: true);
      await runtimes.replace((_) async => owner);
      final reset = runtimes.reset();
      final failure = StateError('native completion unconfirmed');
      final rejected = expectLater(reset, throwsA(same(failure)));
      owner.released.completeError(failure);
      await rejected;
      expect(runtimes.busy, isTrue);
      runtimes.stop();
      await expectLater(runtimes.drain(), throwsA(same(failure)));
      expect(owner.closes, 1);
    },
  );

  test('observer failure cannot abandon an admitted retirement', () async {
    var fail = false;
    final failure = StateError('observer failed');
    final runtimes = slot(
      changed: () {
        if (fail) throw failure;
      },
    );
    final owner = Owner(held: true);
    await runtimes.replace((_) async => owner);
    fail = true;
    runtimes.stop();
    expect(owner.closes, 1);
    var complete = false;
    final failureObserved = expectLater(
      runtimes.drain(),
      throwsA(same(failure)),
    ).then((_) => complete = true);
    await Future<void>.delayed(Duration.zero);
    expect(complete, isFalse);
    owner.released.complete();
    await failureObserved;
    expect(owner.closes, 1);
  });
}
