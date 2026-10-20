import 'dart:math';

import 'package:foresight_core/remote.dart';
import 'package:foresight_core/src/rpc_error.dart';
import 'package:test/test.dart';

void main() {
  late PendingRequestKey pending;
  late List<String> sent;
  setUp(() {
    pending = PendingRequestKey(Random(7));
    sent = [];
  });
  Future<String> attempt([Object? failure]) => pending.run((key) async {
    sent.add(key);
    if (failure != null) throw failure;
    return key;
  });

  test('a retry after an unconfirmed failure reuses the key', () async {
    for (final failure in [
      RpcError(RpcErrorCode.unavailable, 'Application service disconnected'),
      RpcError(RpcErrorCode.cancelled, 'Operation cancelled'),
      const FormatException('truncated reply'),
    ]) {
      await expectLater(attempt(failure), throwsA(same(failure)));
    }
    expect(await attempt(), sent.first);
    expect(sent.toSet(), hasLength(1));
    expect(pending.pending, isNull, reason: 'success releases the key');
    await attempt();
    expect(sent.last, isNot(sent.first), reason: 'a new action, a new key');
  });

  test('a definite rejection or a new action releases the key', () async {
    await expectLater(
      attempt(RpcError(RpcErrorCode.invalidArgument, 'used')),
      throwsA(isA<RpcError>()),
    );
    expect(pending.pending, isNull);
    await expectLater(
      attempt(RpcError(RpcErrorCode.unavailable, 'lost')),
      throwsA(isA<RpcError>()),
    );
    expect(pending.pending, sent.last);
    pending.reset();
    await attempt();
    expect(sent.toSet(), hasLength(3));
    expect(sent, everyElement(matches(RegExp(r'^[0-9a-f]{32}$'))));
  });
}
