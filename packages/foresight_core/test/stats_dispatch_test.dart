import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:foresight_core/src/read_models.dart';
import 'package:foresight_core/src/read_coordinator.dart';
import 'package:foresight_core/src/persistence/read_schema_guard.dart';
import 'package:foresight_core/src/rpc_error.dart';
import 'package:foresight_core/src/sqlite_store_reader.dart';
import 'package:foresight_core/src/store.dart';
import 'package:foresight_core/src/store_read_queries.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';

import 'read_coordinator_test.dart' show GatedReadWorker;

ReadIdentity identity([String revision = 'first']) => ReadIdentity(
  owner: 'owner',
  profile: 'profile',
  connection: 'connection',
  epoch: 'epoch',
  revision: revision,
);

OutputStats stats(OutputStatsPeriod period) => OutputStats(
  words: 1,
  weekly: [0, 0, 0, 0, 1],
  recordedMeetings: 0,
  sources: 0,
  completedAnswers: 1,
  period: period,
);

void main() {
  test(
    'Stats identity captures immutable calendar labels, not exact cutoff',
    () {
      final morning = DateTime(2026, 10, 21, 8);
      final afternoon = DateTime(2026, 10, 21, 17);
      final period = OutputStatsPeriod.capture(morning);
      final query = StoreReadQueries.outputStatsForPeriod(period: period);
      expect(query.arguments.containsKey('now'), isFalse);
      expect(
        query.key,
        StoreReadQueries.outputStatsForPeriod(
          period: OutputStatsPeriod.capture(afternoon),
        ).key,
      );
      expect(
        query.key,
        isNot(
          StoreReadQueries.outputStatsForPeriod(
            period: OutputStatsPeriod.capture(DateTime(2026, 10, 26)),
          ).key,
        ),
      );
      expect(period.weeks.last.year, 2026);
      expect(period.weeks.last.month, 10);
      expect(period.weeks.last.day, 19);
      expect(() => period.weeks.clear(), throwsUnsupportedError);
      final serialized = period.toArguments();
      (serialized['weeks'] as List).clear();
      expect(period.weeks, hasLength(5));
    },
  );

  test(
    'held Stats reads coalesce and freeze fresh cutoffs on actual dispatch',
    () {
      fakeAsync((time) {
        var now = DateTime(2026, 10, 21, 8), calls = 0;
        var revision = 'first';
        final period = OutputStatsPeriod.capture(now);
        final worker = GatedReadWorker();
        final coordinator = ReadCoordinator(
          identity: () => identity(revision),
          worker: worker,
        );
        final query = StoreReadQueries.outputStatsForPeriod(
          period: period,
          clock: () {
            calls++;
            return now;
          },
        );
        final received = <ReadResult<OutputStats>>[];
        final first = coordinator.watch(query).listen(received.add);
        final second = coordinator.watch(query).listen((_) {});
        expect(calls, 0);
        now = DateTime(2026, 10, 21, 9);
        time.flushMicrotasks();
        final originalCutoff = now.millisecondsSinceEpoch;
        expect(calls, 1);
        expect(coordinator.trackedQueries, 1);
        for (var i = 0; i < 100; i++) {
          now = now.add(const Duration(seconds: 1));
          revision = 'next';
          coordinator.invalidate();
        }
        expect(calls, 1);
        expect(worker.requests, hasLength(1));
        expect(coordinator.pendingRefreshes, 1);
        expect(worker.requests.single.arguments['now'], originalCutoff);
        expect(
          () => worker.requests.single.arguments['now'] = 0,
          throwsUnsupportedError,
        );
        final captured = worker.requests.single.arguments['period'] as Map;
        expect(
          () => (captured['weeks'] as List).clear(),
          throwsUnsupportedError,
        );
        worker.complete(0, 'epoch', stats(period));
        time.flushMicrotasks();
        expect(received.single.freshness, ReadFreshness.preview);
        expect(calls, 2);
        expect(worker.requests, hasLength(2));
        expect(
          worker.requests.last.arguments['now'],
          now.millisecondsSinceEpoch,
        );
        expect(worker.requests.first.arguments['now'], originalCutoff);
        expect(worker.requests.last.arguments['period'], captured);
        worker.complete(1, 'epoch', stats(period));
        time.flushMicrotasks();
        expect(received.last.current, isTrue);
        expect(coordinator.activeReads, 0);
        unawaited(first.cancel());
        unawaited(second.cancel());
        unawaited(coordinator.close());
        time.flushMicrotasks();
        expect(worker.closes, 1);
      });
    },
  );

  test(
    'dispatch factory failure settles with no worker call and can retry',
    () {
      fakeAsync((time) {
        var fail = true, calls = 0;
        final args = <String, Object?>{
          'nested': <String, Object?>{'cutoff': 1},
        };
        final query = ReadQuery<String>(
          projection: 'fixture',
          arguments: {'stable': true},
          dispatchArguments: () {
            calls++;
            if (fail) throw StateError('clock unavailable');
            return args;
          },
          decode: (value) => value as String,
        );
        final worker = GatedReadWorker();
        final coordinator = ReadCoordinator(identity: identity, worker: worker);
        final received = <ReadResult<String>>[];
        final subscription = coordinator.watch(query).listen(received.add);
        time.flushMicrotasks();
        expect(received.single.freshness, ReadFreshness.failed);
        expect(received.single.error!.code, RpcErrorCode.internal);
        expect(worker.requests, isEmpty);
        expect(coordinator.activeReads, 0);
        fail = false;
        coordinator.invalidate();
        time.flushMicrotasks();
        expect(calls, 2);
        (args['nested'] as Map)['cutoff'] = 2;
        expect(
          (worker.requests.single.arguments['nested'] as Map)['cutoff'],
          1,
        );
        worker.complete(0, 'epoch', 'recovered');
        time.flushMicrotasks();
        expect(received.last.value, 'recovered');
        unawaited(subscription.cancel());
        unawaited(coordinator.close());
        time.flushMicrotasks();
        expect(worker.closes, 1);
        expect(time.nonPeriodicTimerCount, 0);
      });
    },
  );

  test('period replacement rejects held reply and close joins actual work', () {
    fakeAsync((time) {
      var now = DateTime(2026, 10, 25, 23, 59);
      final period = OutputStatsPeriod.capture(now);
      final worker = GatedReadWorker();
      final coordinator = ReadCoordinator(identity: identity, worker: worker);
      final oldReceived = <ReadResult<OutputStats>>[];
      final old = coordinator
          .watch(
            StoreReadQueries.outputStatsForPeriod(
              period: period,
              clock: () => now,
            ),
          )
          .listen(oldReceived.add);
      time.flushMicrotasks();
      now = DateTime(2026, 10, 26);
      coordinator.invalidate();
      // Cancel the old calendar identity before adopting the new one.
      unawaited(old.cancel());
      time.flushMicrotasks();
      final received = <ReadResult<OutputStats>>[];
      coordinator
          .watch(
            StoreReadQueries.outputStatsForPeriod(
              period: OutputStatsPeriod.capture(now),
              clock: () => now,
            ),
          )
          .listen(received.add);
      time.flushMicrotasks();
      worker.complete(0, 'epoch', stats(period));
      time.flushMicrotasks();
      expect(oldReceived, isEmpty);
      expect(received, isEmpty);
      expect(coordinator.trackedQueries, 1);
      expect(worker.requests, hasLength(2));
      var closed = false;
      unawaited(coordinator.close().then((_) => closed = true));
      time.flushMicrotasks();
      expect(closed, isFalse);
      expect(worker.closes, 0);
      worker.complete(1, 'epoch', stats(OutputStatsPeriod.capture(now)));
      time.flushMicrotasks();
      expect(closed, isTrue);
      expect(worker.closes, 1);
      expect(received.single.freshness, ReadFreshness.cancelled);
    });
  });

  test('schema admission happens before the dispatch factory', () async {
    var calls = 0;
    final worker = GatedReadWorker();
    final coordinator = ReadCoordinator(
      identity: () => throw const IncompatibleReadSchema(999, 17),
      worker: worker,
    );
    final result = await coordinator.read(
      ReadQuery<String>(
        projection: 'fixture',
        dispatchArguments: () {
          calls++;
          return {};
        },
        decode: (value) => value as String,
      ),
    );
    expect(result.freshness, ReadFreshness.failed);
    expect(result.error!.code, RpcErrorCode.unavailable);
    expect(calls, 0);
    expect(worker.requests, isEmpty);
    await coordinator.close();
    expect(worker.closes, 1);
  });

  test('changed period dispatch fails actionably without a worker', () async {
    final now = DateTime(2026, 10, 26);
    final worker = GatedReadWorker();
    final coordinator = ReadCoordinator(identity: identity, worker: worker);
    final result = await coordinator.read(
      StoreReadQueries.outputStatsForPeriod(
        period: OutputStatsPeriod.capture(DateTime(2026, 10, 25)),
        clock: () => now,
      ),
    );
    expect(result.freshness, ReadFreshness.failed);
    expect(result.error!.message, contains('replace the query'));
    expect(result.value, isNull);
    expect(worker.requests, isEmpty);
    await coordinator.close();
    expect(worker.closes, 1);
  });

  test(
    'calendar capture preserves DST boundaries and detects awake zone change',
    () async {
      final compiled = createTestTempDirectorySync('stats-calendar-');
      final kernel = '${compiled.path}/stats_calendar.dill';
      // Compile once; each fresh VM still initializes its own TZ below.
      final compilation = await Process.run(Platform.resolvedExecutable, [
        'compile',
        'kernel',
        '--packages=.dart_tool/package_config.json',
        'test/fixtures/stats_calendar.dart',
        '-o',
        kernel,
      ]);
      expect(
        compilation.exitCode,
        0,
        reason:
            'Stats calendar fixture compilation:\n'
            '${compilation.stdout}\n${compilation.stderr}',
      );
      Future<Map<String, dynamic>> capture(String zone, String instant) async {
        final result = await Process.run(
          Platform.resolvedExecutable,
          [kernel, instant],
          environment: {'TZ': zone},
        );
        expect(
          result.exitCode,
          0,
          reason:
              'Stats calendar capture for $zone at $instant:\n'
              '${result.stdout}\n${result.stderr}',
        );
        return jsonDecode(result.stdout as String) as Map<String, dynamic>;
      }

      for (final fixture in [
        ('2026-03-11T12:00:00Z', 167),
        ('2026-11-04T12:00:00Z', 169),
      ]) {
        final period = await capture('America/New_York', fixture.$1);
        final weeks = period['weeks'] as List;
        final hours =
            ((weeks[4]['start'] as int) - (weeks[3]['start'] as int)) ~/
            Duration.millisecondsPerHour;
        expect(hours, fixture.$2);
        expect(
          DateTime(
            weeks[4]['year'] as int,
            weeks[4]['month'] as int,
            weeks[4]['day'] as int,
          ).weekday,
          DateTime.monday,
        );
      }
      final eastern = await capture('America/New_York', '2026-10-21T12:00:00Z');
      final pacific = await capture(
        'America/Los_Angeles',
        '2026-10-21T12:00:00Z',
      );
      expect(eastern['key'], isNot(pacific['key']));
      expect(
        (eastern['weeks'] as List).last['day'],
        (pacific['weeks'] as List).last['day'],
      );
      expect(
        (eastern['weeks'] as List).last['start'],
        isNot((pacific['weeks'] as List).last['start']),
      );
    },
  );

  test('default queries keep immutable fixed dispatch arguments', () {
    final now = DateTime(2026, 10, 21, 12);
    final query = StoreReadQueries.outputStats(now: now);
    expect(query.argumentsForDispatch(), {'now': now.millisecondsSinceEpoch});
    expect(identical(query.argumentsForDispatch(), query.arguments), isTrue);
    expect(StoreReadQueries.sources().argumentsForDispatch(), isEmpty);
  });

  test('real worker uses captured boundaries and exact future cutoff', () async {
    final directory = createTestTempDirectorySync('stats-dispatch-');
    final writer = Store('${directory.path}/application.db');
    final reader = SqliteStoreReader.open(
      writer.path,
      profile: 'fixture',
      connection: 'first',
    );
    addTearDown(() async {
      await reader.close();
      writer.close();
      directory.deleteSync(recursive: true);
    });
    var now = DateTime(2026, 10, 21, 12);
    final period = OutputStatsPeriod.capture(now);
    void answer(int id, int created, String body) => writer.db.execute(
      "INSERT INTO answers(id,question,body,citations,model,status,created,conversation) VALUES(?,'Q',?,'[]','fixture','completed',?,'desktop')",
      [id, body, created],
    );
    answer(1, now.millisecondsSinceEpoch, 'at cutoff');
    answer(2, now.millisecondsSinceEpoch + 1, 'future three words');
    answer(3, period.weeks.first.startMilliseconds - 1, 'too old');
    final query = StoreReadQueries.outputStatsForPeriod(
      period: period,
      clock: () => now,
    );
    final first = await reader.read(query);
    expect(first.error, isNull);
    expect(first.value!.weekly, [0, 0, 0, 0, 2]);
    expect(first.value!.words, 7);
    expect(first.value!.completedAnswers, 3);
    expect(first.value!.period!.key, period.key);
    expect(() => first.value!.weekly.clear(), throwsUnsupportedError);
    now = now.add(const Duration(milliseconds: 1));
    final second = await reader.read(query);
    expect(second.value!.weekly, [0, 0, 0, 0, 5]);
    expect(second.value!.period!.weeks.last.day, 19);
    expect(
      (await reader.read(StoreReadQueries.outputStats(now: now))).value!.weekly,
      second.value!.weekly,
    );
  });
}
