import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:foresight_core/desktop.dart';

import '../test_support/current_read.dart';

class _Reader implements StoreReader {
  ReadFreshness freshness = ReadFreshness.current;
  RpcError? error;
  Object? value;
  final queries = <ReadQuery<Object?>>[];
  @override
  Future<ReadResult<T>> read<T>(ReadQuery<T> query) async {
    queries.add(query);
    return ReadResult<T>(
      freshness: freshness,
      value: value as T?,
      error: error,
      requestTag: 'fixture',
      sequence: 0,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected synchronous read ${invocation.memberName}');
}

void main() {
  test(
    'current nullable reads preserve absence and factory identity',
    () async {
      final reader = _Reader();
      expect(
        await currentRead(reader, StoreReadQueries.model('speech')),
        isNull,
      );
      expect(reader.queries.single.key, StoreReadQueries.model('speech').key);
      reader.value = 'accepted';
      expect(
        await currentRead(reader, StoreReadQueries.preference('terms')),
        'accepted',
      );
    },
  );
  for (final freshness in [
    ReadFreshness.preview,
    ReadFreshness.busy,
    ReadFreshness.cancelled,
  ]) {
    test(
      'polling rejects $freshness rather than accepting its retained value',
      () async {
        final reader = _Reader()
          ..freshness = freshness
          ..value = 'retained';
        Future<bool> predicate() async =>
            await currentRead(reader, StoreReadQueries.preference('fixture')) ==
            'retained';
        await expectLater(
          currentRead(reader, StoreReadQueries.preference('fixture')),
          throwsA(isA<IntegrationReadPending>()),
        );
        expect(await currentReadCondition(predicate), false);
        reader.freshness = ReadFreshness.current;
        expect(await currentReadCondition(predicate), true);
      },
    );
  }
  test('polling propagates read and predicate failures', () async {
    final error = RpcError(RpcErrorCode.unavailable, 'unavailable');
    final reader = _Reader()
      ..freshness = ReadFreshness.failed
      ..error = error;
    await expectLater(
      currentReadCondition(() async {
        await currentRead(reader, StoreReadQueries.model('speech'));
        return true;
      }),
      throwsA(same(error)),
    );
    await expectLater(
      currentReadCondition(() => throw StateError('predicate failed')),
      throwsStateError,
    );
  });
  testWidgets(
    'a held async predicate cannot extend the existing polling deadline',
    (tester) async {
      final held = Completer<bool>();
      final result = currentReadCondition(
        () => held.future,
        deadline: DateTime.now().add(const Duration(milliseconds: 100)),
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(await result, isFalse);
      held.complete(true);
      await tester.pump();
      var calls = 0;
      expect(
        await currentReadCondition(() {
          calls++;
          return true;
        }, deadline: DateTime.now().subtract(const Duration(seconds: 1))),
        isFalse,
      );
      expect(calls, 0);
    },
  );
}
