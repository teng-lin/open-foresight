import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:foresight_core/src/cancellation.dart';
import 'package:foresight_core/src/rpc_error.dart';
import 'package:test/test.dart';

void main() {
  test(
    'watch preserves cancellation classification and removes only itself',
    () async {
      late CancellationWatch watch;
      final removed = <CancellationWatch>[];
      watch = CancellationWatch(() => false, removed.add);
      final observed = expectLater(
        watch.future,
        throwsA(
          isA<RpcError>()
              .having((error) => error.code, 'code', RpcErrorCode.cancelled)
              .having(
                (error) => error.message,
                'message',
                'Operation cancelled',
              ),
        ),
      );
      watch.check();
      watch.check();
      await observed;
      watch.dispose();
      expect(removed, [same(watch)]);
      expect(
        operationCancelled('Answer cancelled').message,
        'Answer cancelled',
      );
    },
  );

  test(
    'native cancellation keeps the original reason and observes late work',
    () {
      fakeAsync((clock) {
        final work = Completer<String>();
        final failure = operationCancelled(
          'Workspace was cleared; retry the operation',
        );
        Object? result;
        var current = true, cancellations = 0;
        unawaited(
          awaitCancellable(
            work.future,
            ensureCurrent: () {
              if (!current) throw failure;
            },
            cancel: () async {
              cancellations++;
            },
          ).then<void>(
            (_) {},
            onError: (Object error) {
              result = error;
            },
          ),
        );
        current = false;
        clock.elapse(const Duration(milliseconds: 20));
        clock.flushMicrotasks();
        expect(result, same(failure));
        expect(cancellations, 1);
        work.completeError(StateError('late native failure'));
        clock.flushMicrotasks();
        expect(clock.periodicTimerCount, 0);
      });
    },
  );

  test('normal completion and operation failure dispose their monitor', () {
    fakeAsync((clock) {
      String? value;
      Object? error;
      var cancels = 0;
      unawaited(
        awaitCancellable(
          Future.value('done'),
          ensureCurrent: () {},
          cancel: () async {
            cancels++;
          },
        ).then((result) {
          value = result;
        }),
      );
      final original = StateError('original operation failure');
      unawaited(
        awaitCancellable(
          Future<String>.error(original),
          ensureCurrent: () {},
          cancel: () async {
            cancels++;
          },
        ).then<void>(
          (_) {},
          onError: (Object failure) {
            error = failure;
          },
        ),
      );
      clock.flushMicrotasks();
      expect(value, 'done');
      expect(error, same(original));
      expect(cancels, 0);
      expect(clock.periodicTimerCount, 0);
    });
  });
}
