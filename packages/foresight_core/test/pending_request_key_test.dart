import 'dart:math';

import 'package:clock/clock.dart';
import 'package:foresight_core/remote.dart';
import 'package:foresight_core/src/request_errors.dart';
import 'package:foresight_core/src/rpc_error.dart';
import 'package:test/test.dart';

void main() {
  late PendingRequestKey pending;
  late List<Map<String, dynamic>> sent;
  setUp(() {
    pending = PendingRequestKey(random: Random(7));
    sent = [];
  });
  Future<Object?> attempt(
    Map<String, dynamic> arguments, [
    Object? failure,
    Future<Object?> Function(Object?, Map<String, dynamic>)? amend,
  ]) => pending.run(arguments, (keyed) async {
    sent.add(keyed);
    if (failure != null) throw failure;
    return {'id': sent.length};
  }, amend: amend);
  Object? key(int index) => sent[index]['idempotency_key'];

  test('a retry after an unconfirmed failure reuses the key', () async {
    for (final failure in [
      RpcError(
        RpcErrorCode.internal,
        'Application service sent an invalid reply',
        reason: RpcErrorReason.outcomeUnknown,
      ),
      RpcError(
        RpcErrorCode.unavailable,
        'Application service disconnected',
        reason: RpcErrorReason.outcomeUnknown,
      ),
      RpcError(RpcErrorCode.unavailable, 'Application service disconnected'),
      RpcError(RpcErrorCode.cancelled, 'Operation cancelled'),
      const FormatException('truncated reply'),
    ]) {
      await expectLater(
        attempt({'title': 'T'}, failure),
        throwsA(same(failure)),
      );
    }
    expect(await attempt({'title': 'T'}), {'id': 6});
    expect(sent.map((args) => args['idempotency_key']).toSet(), hasLength(1));
    expect(pending.pending, isNull, reason: 'success releases the key');
    await attempt({'title': 'T'});
    expect(key(6), isNot(key(0)), reason: 'a new action, a new key');
  });

  test('a definite failure or a new action releases the key', () async {
    for (final failure in [
      RpcError(RpcErrorCode.invalidArgument, 'rejected'),
      RpcError(
        RpcErrorCode.unavailable,
        serviceClosingMessage,
        reason: RpcErrorReason.closing,
      ),
      RpcError(
        RpcErrorCode.unavailable,
        'Application service disconnected',
        reason: RpcErrorReason.notSent,
      ),
    ]) {
      await expectLater(attempt({'title': 'T'}, failure), throwsA(failure));
      expect(pending.pending, isNull, reason: '$failure');
    }
    await expectLater(
      attempt({'title': 'T'}, RpcError(RpcErrorCode.unavailable, 'lost')),
      throwsA(isA<RpcError>()),
    );
    expect(pending.pending, key(3));
    pending.reset();
    await attempt({'title': 'T'});
    expect(sent.map((args) => args['idempotency_key']).toSet(), hasLength(5));
    expect(
      sent.map((args) => args['idempotency_key']),
      everyElement(matches(RegExp(r'^[0-9a-f]{32}$'))),
    );
  });

  test(
    'changed arguments resend the original, then amend its result',
    () async {
      await expectLater(
        attempt({'title': 'Draft'}, RpcError(RpcErrorCode.unavailable, 'lost')),
        throwsA(isA<RpcError>()),
      );
      final amended = <(Object?, Map<String, dynamic>)>[];
      final result = await attempt({'title': 'Edited'}, null, (
        first,
        args,
      ) async {
        amended.add((first, args));
        return {'edited': first};
      });
      // The key never carries the edited arguments.
      expect(sent, [
        {'title': 'Draft', 'idempotency_key': key(0)},
        {'title': 'Draft', 'idempotency_key': key(0)},
      ]);
      expect(amended.single.$1, {'id': 2});
      expect(amended.single.$2, {'title': 'Edited'});
      expect(result, {
        'edited': {'id': 2},
      });
      expect(pending.pending, isNull);
    },
  );

  test('a key lapses after its retry window', () async {
    final start = DateTime.utc(2026, 10, 20, 9);
    await withClock(
      Clock.fixed(start),
      () => expectLater(
        attempt({'title': 'T'}, RpcError(RpcErrorCode.unavailable, 'lost')),
        throwsA(isA<RpcError>()),
      ),
    );
    await withClock(
      Clock.fixed(start.add(const Duration(minutes: 5))),
      () => expectLater(
        attempt({'title': 'T'}, RpcError(RpcErrorCode.unavailable, 'lost')),
        throwsA(isA<RpcError>()),
      ),
    );
    expect(key(1), key(0));
    await withClock(
      Clock.fixed(start.add(const Duration(minutes: 5, seconds: 1))),
      () => attempt({'title': 'T'}),
    );
    expect(key(2), isNot(key(0)));
  });

  test(
    'after a lost reply only success or an answer about the key releases it',
    () async {
      final lost = RpcError(
        RpcErrorCode.unavailable,
        'Application service disconnected',
        reason: RpcErrorReason.outcomeUnknown,
      );
      await expectLater(attempt({'title': 'T'}, lost), throwsA(lost));
      // Each of these says nothing about the attempt that may have committed.
      for (final failure in [
        RpcError(
          RpcErrorCode.unavailable,
          'Application service disconnected',
          reason: RpcErrorReason.notSent,
        ),
        RpcError(
          RpcErrorCode.unavailable,
          serviceClosingMessage,
          reason: RpcErrorReason.closing,
        ),
        RpcError(RpcErrorCode.busy, 'Workspace is being cleared'),
        RpcError(RpcErrorCode.internal, 'database or disk is full'),
      ]) {
        await expectLater(attempt({'title': 'T'}, failure), throwsA(failure));
        expect(pending.pending, key(0), reason: '$failure');
      }
      await attempt({'title': 'T'});
      expect(sent.map((args) => args['idempotency_key']).toSet(), hasLength(1));
      // An answer about the key itself settles an uncertain key too.
      for (final answer in [
        RpcError(RpcErrorCode.notFound, workspaceClearedChangeMessage),
        RpcError(
          RpcErrorCode.invalidArgument,
          keyReusedWithOtherArgumentsMessage,
        ),
        RpcError(
          RpcErrorCode.invalidArgument,
          keyReusedForMessage('notes.save'),
        ),
      ]) {
        await expectLater(attempt({'title': 'T'}, lost), throwsA(lost));
        await expectLater(attempt({'title': 'T'}, answer), throwsA(answer));
        expect(pending.pending, isNull, reason: '$answer');
      }
      expect(sent.map((args) => args['idempotency_key']).toSet(), hasLength(4));
    },
  );

  test('changed arguments without amend are refused, not sent anew', () async {
    await expectLater(
      attempt({'title': 'Draft'}, RpcError(RpcErrorCode.unavailable, 'lost')),
      throwsA(isA<RpcError>()),
    );
    await expectLater(attempt({'title': 'Edited'}), throwsArgumentError);
    expect(sent, hasLength(1));
    expect(pending.pending, key(0));
  });
}
