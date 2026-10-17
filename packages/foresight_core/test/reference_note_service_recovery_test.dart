import 'dart:async';

import 'package:foresight_core/src/reference_note_service_recovery.dart';
import 'package:test/test.dart';

class Service {
  Service({required this.ready});
  final bool ready;
}

void main() {
  test(
    'ready first service returns without reset or unavailable-model lookup',
    () async {
      final service = Service(ready: true);
      final calls = <String>[];
      final result = await acquireNoteEnhancementService<Service>(
        getService: () async {
          calls.add('get');
          return service;
        },
        isReady: (value) => value.ready,
        abortAndReset: () async => calls.add('reset'),
        unavailableError: () async {
          calls.add('model');
          return StateError('unavailable');
        },
      );
      expect(result, same(service));
      expect(calls, ['get']);
    },
  );

  for (final first in [null, Service(ready: false)]) {
    test(
      '${first == null ? 'null' : 'unready'} first service recovers with one reset',
      () async {
        final recovered = Service(ready: true);
        var acquisitions = 0;
        final calls = <String>[];
        final result = await acquireNoteEnhancementService<Service>(
          getService: () async {
            calls.add('get');
            return acquisitions++ == 0 ? first : recovered;
          },
          isReady: (value) => value.ready,
          abortAndReset: () async {
            calls.add('reset');
          },
          unavailableError: () async {
            calls.add('model');
            return StateError('unavailable');
          },
        );
        expect(result, same(recovered));
        expect(calls, ['get', 'reset', 'get']);
      },
    );
  }

  for (final second in [null, Service(ready: false)]) {
    test(
      '${second == null ? 'null' : 'unready'} second service constructs caller error',
      () async {
        var acquisitions = 0;
        final calls = <String>[];
        final failure = StateError('installed-model-specific error');
        await expectLater(
          acquireNoteEnhancementService<Service>(
            getService: () async {
              calls.add('get');
              acquisitions++;
              return second;
            },
            isReady: (value) => value.ready,
            abortAndReset: () async => calls.add('reset'),
            unavailableError: () async {
              calls.add('model');
              return failure;
            },
          ),
          throwsA(same(failure)),
        );
        expect(acquisitions, 2);
        expect(calls, ['get', 'reset', 'get', 'model']);
      },
    );
  }

  test('reacquisition waits for reset completion', () async {
    final resetStarted = Completer<void>();
    final resetFinished = Completer<void>();
    var acquisitions = 0;
    final recovered = Service(ready: true);
    final result = acquireNoteEnhancementService<Service>(
      getService: () async => acquisitions++ == 0 ? null : recovered,
      isReady: (value) => value.ready,
      abortAndReset: () {
        resetStarted.complete();
        return resetFinished.future;
      },
      unavailableError: () async => StateError('unexpected'),
    );
    await resetStarted.future;
    expect(acquisitions, 1);
    resetFinished.complete();
    expect(await result, same(recovered));
    expect(acquisitions, 2);
  });

  test(
    'first acquisition exception propagates without reset or model lookup',
    () async {
      final failure = StateError('get threw');
      final calls = <String>[];
      await expectLater(
        acquireNoteEnhancementService<Service>(
          getService: () async {
            calls.add('get');
            throw failure;
          },
          isReady: (value) => value.ready,
          abortAndReset: () async => calls.add('reset'),
          unavailableError: () async {
            calls.add('model');
            return StateError('unavailable');
          },
        ),
        throwsA(same(failure)),
      );
      expect(calls, ['get']);
    },
  );

  test(
    'reset exception propagates without reacquisition or model lookup',
    () async {
      final failure = StateError('reset threw');
      final calls = <String>[];
      await expectLater(
        acquireNoteEnhancementService<Service>(
          getService: () async {
            calls.add('get');
            return null;
          },
          isReady: (value) => value.ready,
          abortAndReset: () async {
            calls.add('reset');
            throw failure;
          },
          unavailableError: () async {
            calls.add('model');
            return StateError('unavailable');
          },
        ),
        throwsA(same(failure)),
      );
      expect(calls, ['get', 'reset']);
    },
  );

  test(
    'second acquisition exception propagates without unavailable-model lookup',
    () async {
      final failure = StateError('second get threw');
      var acquisitions = 0;
      final calls = <String>[];
      await expectLater(
        acquireNoteEnhancementService<Service>(
          getService: () async {
            calls.add('get');
            if (acquisitions++ == 0) return null;
            throw failure;
          },
          isReady: (value) => value.ready,
          abortAndReset: () async => calls.add('reset'),
          unavailableError: () async {
            calls.add('model');
            return StateError('unavailable');
          },
        ),
        throwsA(same(failure)),
      );
      expect(calls, ['get', 'reset', 'get']);
    },
  );
}
