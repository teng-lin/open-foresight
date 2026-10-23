import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foresight_core/desktop.dart';
import 'package:open_foresight/features/settings/stats_read_model.dart';

class _Reader implements StoreReader {
  final queries = <ReadQuery<OutputStats>>[];
  final replies = <StreamController<ReadResult<OutputStats>>>[];
  int active = 0;
  @override
  String workspaceEpoch = 'epoch';
  @override
  String dataRevision = '1';
  @override
  Stream<ReadResult<T>> watch<T>(ReadQuery<T> query) {
    queries.add(query as ReadQuery<OutputStats>);
    final reply = StreamController<ReadResult<OutputStats>>.broadcast(
      sync: true,
      onListen: () => active++,
      onCancel: () => active--,
    );
    replies.add(reply);
    return reply.stream.map((value) => value.asType<T>());
  }

  void succeed(int index, int words, {OutputStatsPeriod? period}) =>
      replies[index].add(
        ReadResult(
          freshness: ReadFreshness.current,
          value: OutputStats(
            words: words,
            weekly: [0, 0, 0, 0, words],
            recordedMeetings: 2,
            sources: 3,
            completedAnswers: 4,
            period: period,
          ),
          requestTag: 'stats',
          sequence: index,
        ),
      );
  void fail(int index) => replies[index].add(
    ReadResult(
      freshness: ReadFreshness.failed,
      value: null,
      error: RpcError(RpcErrorCode.unavailable, 'ordinary dispatch failure'),
      requestTag: 'stats',
      sequence: index,
    ),
  );
  Future<void> close() async {
    for (final reply in replies) {
      await reply.close();
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected synchronous read ${invocation.memberName}');
}

class _Connection implements DesktopConnection {
  _Connection(this.store);
  @override
  final _Reader store;
  @override
  String? workspaceEpoch = 'epoch';
  @override
  Object clientSessionGeneration = Object();
  // Closed by the fixture.
  // ignore: close_sinks
  final events = StreamController<void>.broadcast(sync: true);
  @override
  Stream<void> get changes => events.stream;
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

void main() {
  test(
    'Stats keeps one watch, samples exact dispatch cutoffs, and cancels timers and reads',
    () {
      fakeAsync((async) {
        final reader = _Reader();
        final connection = _Connection(reader);
        final origin = DateTime(2026, 10, 21, 12);
        var publications = 0;
        final model = SettingsStatsModel(
          connection: () => connection,
          changed: () => publications++,
          clock: () => origin.add(async.elapsed),
        );
        model.start();
        async.flushMicrotasks();
        expect(reader.active, 1);
        expect(reader.queries, hasLength(1));
        expect(async.nonPeriodicTimerCount, 2);
        final query = reader.queries.single;
        expect(
          query.argumentsForDispatch()['now'],
          origin.millisecondsSinceEpoch,
        );
        reader.succeed(0, 17);
        async.flushMicrotasks();
        final weekly = model.value!.weekly;
        final publishedBeforeEqual = publications;
        reader.succeed(0, 17);
        async.flushMicrotasks();
        expect(publications, publishedBeforeEqual);
        expect(model.value!.weekly, same(weekly));
        for (var i = 0; i < 20; i++) connection.events.add(null);
        reader.dataRevision = '2';
        connection.events.add(null);
        async.elapse(const Duration(seconds: 31));
        expect(reader.queries, hasLength(1));
        expect(model.value!.weekly, same(weekly));
        expect(
          query.argumentsForDispatch()['now'],
          origin.add(async.elapsed).millisecondsSinceEpoch,
        );
        reader.fail(0);
        async.flushMicrotasks();
        final afterFailure = publications;
        async.elapse(const Duration(minutes: 1));
        async.flushMicrotasks();
        expect(publications, afterFailure);
        expect(model.value!.words, 17);
        expect(reader.queries, hasLength(1));
        reader.succeed(0, 23);
        async.flushMicrotasks();
        expect(model.value!.words, 23);
        unawaited(model.dispose());
        async.flushMicrotasks();
        expect(reader.active, 0);
        expect(async.nonPeriodicTimerCount, 0);
        final published = publications;
        reader.succeed(0, 999);
        async.flushMicrotasks();
        expect(publications, published);
        unawaited(reader.close());
        unawaited(connection.events.close());
        async.flushMicrotasks();
      });
    },
  );

  test(
    'Monday rollover rejects held prior-period replies and keeps labels with displayed values',
    () {
      fakeAsync((async) {
        final reader = _Reader();
        final connection = _Connection(reader);
        final origin = DateTime(2026, 11, 1, 23, 59, 59);
        final model = SettingsStatsModel(
          connection: () => connection,
          changed: () {},
          clock: () => origin.add(async.elapsed),
        );
        model.start();
        reader.succeed(0, 17);
        async.flushMicrotasks();
        final oldPeriod = model.displayPeriod!;
        expect(oldPeriod.weeks.last.day, 26);
        async.elapse(const Duration(seconds: 1));
        async.flushMicrotasks();
        expect(reader.queries, hasLength(2));
        expect(reader.active, 1);
        expect(model.displayPeriod, same(oldPeriod));
        expect(model.value!.words, 17);
        reader.succeed(0, 999);
        async.flushMicrotasks();
        expect(model.value!.words, 17);
        reader.succeed(1, 999, period: oldPeriod);
        async.flushMicrotasks();
        expect(model.value!.words, 17);
        reader.succeed(1, 23);
        async.flushMicrotasks();
        expect(model.value!.words, 23);
        expect(model.displayPeriod!.weeks.last.day, 2);
        final starts = model.displayPeriod!.weeks;
        // Calendar Monday distance includes the zone's actual DST offset change.
        final previous = DateTime(2026, 10, 26),
            current = DateTime(2026, 11, 2);
        expect(
          starts.last.startMilliseconds - starts[3].startMilliseconds,
          current.difference(previous).inMilliseconds,
        );
        unawaited(model.dispose());
        unawaited(reader.close());
        unawaited(connection.events.close());
        async.flushMicrotasks();
      });
    },
  );

  test(
    'midweek zone change without events replaces the query on the bounded clock check',
    () {
      fakeAsync((async) {
        final reader = _Reader();
        final connection = _Connection(reader);
        var zone = 'initial';
        final now = DateTime(2026, 10, 21, 12);
        OutputStatsPeriod capture(DateTime now) =>
            OutputStatsPeriod.fromArguments({
              ...OutputStatsPeriod.capture(now).toArguments(),
              'zone': zone,
            });
        final model = SettingsStatsModel(
          connection: () => connection,
          changed: () {},
          clock: () => now,
          capture: capture,
        );
        model.start();
        reader.succeed(0, 17);
        async.flushMicrotasks();
        zone = 'replacement';
        async.elapse(SettingsStatsModel.clockRecheck);
        async.flushMicrotasks();
        expect(reader.queries, hasLength(2));
        expect(reader.active, 1);
        reader.succeed(0, 999);
        async.flushMicrotasks();
        expect(model.value!.words, 17);
        reader.succeed(1, 23);
        async.flushMicrotasks();
        expect(model.displayPeriod!.zoneIdentity, 'replacement');
        unawaited(model.dispose());
        unawaited(reader.close());
        unawaited(connection.events.close());
        async.flushMicrotasks();
      });
    },
  );

  test(
    'a held reply after a clock jump is rejected before either timer fires',
    () {
      fakeAsync((async) {
        final reader = _Reader();
        final connection = _Connection(reader);
        var now = DateTime(2026, 10, 25, 23, 59, 59);
        final model = SettingsStatsModel(
          connection: () => connection,
          changed: () {},
          clock: () => now,
        );
        model.start();
        reader.succeed(0, 17);
        async.flushMicrotasks();
        now = DateTime(2026, 10, 26);
        reader.succeed(0, 999);
        async.flushMicrotasks();
        expect(reader.queries, hasLength(2));
        expect(model.value!.words, 17);
        reader.succeed(1, 23);
        async.flushMicrotasks();
        expect(model.value!.words, 23);
        unawaited(model.dispose());
        unawaited(reader.close());
        unawaited(connection.events.close());
        async.flushMicrotasks();
      });
    },
  );

  test(
    'period dispatch failure recaptures without matching error text; owner replacement resets values',
    () {
      fakeAsync((async) {
        final reader = _Reader();
        final connection = _Connection(reader);
        var now = DateTime(2026, 10, 25, 23, 59, 59);
        final model = SettingsStatsModel(
          connection: () => connection,
          changed: () {},
          clock: () => now,
        );
        model.start();
        reader.succeed(0, 17);
        async.flushMicrotasks();
        now = DateTime(2026, 10, 26);
        expect(
          () => reader.queries.first.argumentsForDispatch(),
          throwsStateError,
        );
        reader.fail(0);
        async.flushMicrotasks();
        expect(reader.queries, hasLength(2));
        reader.succeed(1, 23);
        async.flushMicrotasks();
        connection.clientSessionGeneration = Object();
        connection.events.add(null);
        async.flushMicrotasks();
        expect(reader.queries, hasLength(3));
        expect(reader.active, 1);
        expect(model.value, isNull);
        reader.succeed(1, 999);
        reader.fail(1);
        async.flushMicrotasks();
        expect(model.value, isNull);
        expect(reader.queries, hasLength(3));
        reader.succeed(2, 31);
        async.flushMicrotasks();
        expect(model.value!.words, 31);
        unawaited(model.dispose());
        unawaited(reader.close());
        unawaited(connection.events.close());
        async.flushMicrotasks();
      });
    },
  );
}
