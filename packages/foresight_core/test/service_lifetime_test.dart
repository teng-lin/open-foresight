import 'sql_support_test_bootstrap.dart';
import 'package:foresight_test_support/transcript_index_service.dart';
import 'package:foresight_test_support/desktop_identity.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:io';
import 'package:clock/clock.dart';
import 'package:foresight_core/foresight_core.dart';
import 'package:foresight_core/src/service.dart';
import 'package:foresight_test_support/poll.dart';
import 'package:foresight_test_support/capture_process.dart';
import 'package:foresight_test_support/hooked_service.dart';
import 'package:foresight_core/src/rpc_error.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:foresight_test_support/test_recording.dart';
import 'package:foresight_test_support/delayed_index_service.dart';
import 'package:foresight_test_support/helper_adoption.dart';
import 'package:foresight_core/src/generated/helper_control.pb.dart' as control;
import 'package:foresight_core/src/generated/rag_service.pbgrpc.dart';
import 'package:grpc/grpc.dart';
import 'package:http2/transport.dart' show ServerTransportConnection;
import 'application_operations_test.dart' show ArtifactGenerator;
import 'note_transcript_cache_application_test.dart'
    show EmbeddingService, PromptRuntime;
import 'package:test/test.dart';

class RecordedTimer implements Timer {
  RecordedTimer(this.delay, this.callback) {
    timer = Timer(delay, () {
      fired = true;
      callback();
    });
  }
  final Duration delay;
  final void Function() callback;
  late final Timer timer;
  bool cancelled = false, fired = false;
  @override
  bool get isActive => timer.isActive;
  @override
  int get tick => timer.tick;
  @override
  void cancel() {
    cancelled = true;
    timer.cancel();
  }

  @override
  String toString() =>
      '$delay (active: $isActive, cancelled: $cancelled, fired: $fired)';
}

class ResumeRag extends HeldPing {
  final configuring = Completer<void>(), configured = Completer<void>();
  @override
  Future<UpdateModelPathsResponse> updateModelPaths(
    ServiceCall call,
    UpdateModelPathsRequest request,
  ) async {
    if (!configuring.isCompleted) configuring.complete();
    await configured.future;
    return UpdateModelPathsResponse(success: true);
  }

  @override
  Future<DeleteResponse> deleteDocument(
    ServiceCall call,
    DeleteRequest request,
  ) async => DeleteResponse(success: true);
}

class ProactiveRag extends DelayedIndexService {
  ServiceCall? retrievalCall;
  final retrieving = Completer<void>(), retrieved = Completer<void>();
  @override
  Future<RetrieveResponse> retrieveContext(
    ServiceCall call,
    RetrieveRequest request,
  ) async {
    retrievalCall = call;
    if (!retrieving.isCompleted) retrieving.complete();
    await retrieved.future;
    return RetrieveResponse();
  }
}

class GeneratingRuntime extends ArtifactGenerator {
  bool active = true;
  @override
  bool get generating => active;
}

class StreamRag extends DelayedIndexService {
  String document = '';
  @override
  Future<RetrieveResponse> retrieveContext(
    ServiceCall call,
    RetrieveRequest request,
  ) async => RetrieveResponse(
    chunks: [
      RetrievedChunk(
        documentId: document,
        text: 'Mira owns the draft.',
        relevanceScore: 0.9,
      ),
    ],
  );
}

class CleanupRuntime extends ArtifactGenerator {
  final bodyEntered = Completer<void>(), bodyRelease = Completer<void>();
  final cleanupEntered = Completer<void>(), cleanupRelease = Completer<void>();
  bool failCleanup = false;
  @override
  Stream<Map<String, dynamic>> generate(
    String id,
    String prompt, {
    String systemPrompt = '',
    Map<String, dynamic>? responseSchema,
    Duration timeout = const Duration(minutes: 5),
    int maxOutputTokens = 256,
  }) async* {
    try {
      yield {
        'type': 'delta',
        'text':
            '{"status":"answered","answer":"Mira owns the draft.","citations":["S1"]}',
      };
      bodyEntered.complete();
      await bodyRelease.future;
      yield {'type': 'done', 'status': 'completed'};
    } finally {
      cleanupEntered.complete();
      await cleanupRelease.future;
      if (failCleanup) throw StateError('fixture stream cleanup failed');
    }
  }
}

void main() {
  bootstrapSqlSupportFixture();
  late Directory root;
  late ProfilePaths profile;
  late ApplicationService service;
  late ServiceClient agent;
  late Map<String, String> environment;
  var now = DateTime.utc(2026, 10, 20);
  DateTime Function()? readClock;
  final timers = <RecordedTimer>[];
  bool editingNotes = false;
  Timer? enhancementTimer;
  void Function()? fireEnhancement;
  setUp(() async {
    environment = Map.of(runtimeConfiguration.environment);
    runtimeConfiguration.environment.removeWhere(
      (key, _) =>
          key.startsWith('FORESIGHT_') && key != 'FORESIGHT_SQLITE_LIBRARY',
    );
    runtimeConfiguration.environment['FORESIGHT_HELPER'] = '';
    root = createTestTempDirectorySync('lifetime-');
    profile = ProfilePaths('${root.path}/d', '${root.path}/r');
    now = DateTime.utc(2026, 10, 20);
    readClock = null;
    timers.clear();
    editingNotes = false;
    enhancementTimer = null;
    fireEnhancement = null;
    print('LIFETIME_SETUP_PROGRESS phase=0');
    service = await ApplicationService.start(
      profile,
      desktopPeerVerifier: trustInProcessDesktop,
      clock: Clock(() => readClock?.call() ?? now),
      createTimer: (delay, callback) {
        final timer = RecordedTimer(delay, callback);
        timers.add(timer);
        if (editingNotes &&
            enhancementTimer == null &&
            delay == const Duration(seconds: 30)) {
          enhancementTimer = timer;
          fireEnhancement = callback;
        }
        return timer;
      },
    );
    print('LIFETIME_SETUP_PROGRESS phase=1');
    await service.ready;
    print('LIFETIME_SETUP_PROGRESS phase=2');
    service.domain.store.setPreference('serviceIdleMinutes', '30');
    agent = await ServiceClient.connect('${profile.runtime}/application.sock');
    print('LIFETIME_SETUP_PROGRESS phase=3');
    addTearDown(() async {
      await agent.close();
      await service.close();
      await eventually(() => service.dispatchedCount == 0);
      expect(service.application.activeEnhancements, 0);
      expect(service.application.proactiveWork, 0);
      expect(service.application.transcriptComputing, 0);
      expect(service.domain.mutating, 0);
      await eventually(() => !service.application.backgroundBusy);
      runtimeConfiguration.environment
        ..clear()
        ..addAll(environment);
    });
  });
  Future<Map> lifetime() async =>
      (await agent.call('status') as Map)['lifetime'] as Map;
  Future<ServiceClient> desktop({bool host = false}) async {
    final client = await ServiceClient.connect(service.path);
    addTearDown(client.close);
    await client.call(host ? 'security.attach_desktop' : 'status', {
      'visible': true,
      'desktop': true,
      'token': File('${profile.data}/.desktop-capability').readAsStringSync(),
    });
    return client;
  }

  List<RecordedTimer> activeLifetimeTimers() => timers
      .where(
        (timer) =>
            timer.isActive && timer.delay != const Duration(milliseconds: 100),
      )
      .toList();

  void expectPeriodicLifetimeCheck() {
    expect(activeLifetimeTimers().map((timer) => timer.delay), [
      const Duration(seconds: 30),
    ], reason: '$timers');
    expect(
      timers.where((timer) => timer.delay <= Duration.zero),
      isEmpty,
      reason:
          'Gated work must not schedule a zero-delay lifetime spin: $timers',
    );
  }

  void interleaveStatusTimer() {
    // Interleave the 100 ms timer used by heartbeat broadcasts after the
    // lifetime check. The shared factory's last call cannot identify its owner.
    final timer = service.domain.createTimer(
      const Duration(milliseconds: 100),
      () {},
    );
    addTearDown(timer.cancel);
  }

  Future<void> departed() =>
      eventually(() async => !(await lifetime())['pinned_by_desktop']);
  Future<void> tick() async {
    try {
      await lifetime();
    } on RpcError catch (e) {
      if (e.code != RpcErrorCode.unavailable) rethrow;
    }
  }

  Future<void> backgroundRefusal({bool desktopPinned = false}) async {
    await expectLater(
      agent.call('service.stop_if_idle', {
        'token': File('${profile.data}/.desktop-capability').readAsStringSync(),
      }),
      throwsA(
        isA<RpcError>()
            .having((e) => e.code, 'code', RpcErrorCode.busy)
            .having(
              (e) => e.message,
              'message',
              contains(
                desktopPinned ? 'Close the desktop' : 'Background model work',
              ),
            ),
      ),
    );
  }

  Future<void> exited() => service.closed.timeout(const Duration(seconds: 10));
  Future<T> withAdoptableHelper<T>(
    Future<T> Function(ResumeRag) body, {
    bool model = false,
  }) async {
    await agent.close();
    await service.close();
    runtimeConfiguration.environment.removeWhere(
      (key, _) =>
          key.startsWith('FORESIGHT_') && key != 'FORESIGHT_SQLITE_LIBRARY',
    );
    if (model) {
      final store = Store('${profile.data}/application.db');
      final file = File('${root.path}/fixture.litertlm')
        ..writeAsStringSync('embedding registration fixture');
      await store.register('embedding', file.path, '');
      store.close();
    }
    final rag = ResumeRag();
    final server = Server.create(
      services: [rag, AdoptionControl(control.State())],
    );
    await server.serve(
      address: InternetAddress(
        '${profile.runtime}/helper.sock',
        type: InternetAddressType.unix,
      ),
      port: 0,
    );
    addTearDown(server.shutdown);
    addTearDown(() {
      if (!rag.release.isCompleted) rag.release.complete();
      if (!rag.configured.isCompleted) rag.configured.complete();
    });
    service = await ApplicationService.start(
      profile,
      desktopPeerVerifier: trustInProcessDesktop,
      clock: Clock(() => now),
    );
    agent = await ServiceClient.connect(service.path);
    return body(rag);
  }

  test(
    'status lifetime numbers preserve fractional preferences without stamping',
    () async {
      service.domain.store.setPreference('serviceIdleMinutes', '0.05');
      final state = await lifetime();
      expect(state['idle_minutes'], 0.05);
      expect(state['last_agent_activity'], null);
      expect(state['pinned_by_desktop'], false);
      expect(state['busy'], false);
    },
  );
  test(
    'cancelled committed future remains busy until its work settles',
    () async {
      final gates = await ServiceGates.create(root);
      runtimeConfiguration.environment['FORESIGHT_SERVICE_GATES'] =
          gates.directory.path;
      gates.hold('request.committed.notes.save');
      addTearDown(gates.releaseAll);
      final subscription = agent
          .stream('notes.save', {'title': 'held', 'body': 'committed'})
          .listen((_) {});
      await gates.reached('request.committed.notes.save');
      expect((await lifetime())['busy'], true);
      await subscription.cancel();
      now = now.add(const Duration(minutes: 31));
      expect((await lifetime())['busy'], true);
      expect((await lifetime())['exit_after'], null);
      await expectLater(
        agent.call('service.stop_if_idle', {
          'token': File(
            '${profile.data}/.desktop-capability',
          ).readAsStringSync(),
        }),
        throwsA(
          isA<RpcError>().having(
            (e) => e.message,
            'message',
            contains('operations are in progress'),
          ),
        ),
      );
      gates.release('request.committed.notes.save');
      await eventually(() => service.dispatchedCount == 0);
      expect((await lifetime())['busy'], false);
    },
  );

  test(
    'agent-only service exits after the period and releases ownership',
    () async {
      await agent.call('notes.list');
      final stamp = service.lastAgentActivity!;
      expect(
        (await lifetime())['exit_after'],
        stamp.add(const Duration(minutes: 30)).millisecondsSinceEpoch,
      );
      now = now.add(const Duration(minutes: 30));
      await lifetime();
      await service.closed.timeout(const Duration(seconds: 10));
      expect(
        File('${profile.data}/.application-endpoint.json').existsSync(),
        false,
      );
      expect(
        FileSystemEntity.typeSync(service.path),
        FileSystemEntityType.notFound,
      );
      final lock = File(
        '${profile.data}/.application.lock',
      ).openSync(mode: FileMode.append);
      try {
        lock.lockSync(FileLock.exclusive);
        lock.unlockSync();
      } finally {
        lock.closeSync();
      }
    },
  );
  test(
    'malformed agent arguments never dispatch or stamp at rejection and settlement',
    () async {
      // Complete structural decoding rejects before work starts, including
      // the settlement path that formerly stamped malformed agent calls.
      expect(service.lastAgentActivity, isNull);
      final start = now.add(const Duration(seconds: 1));
      final settled = start.add(const Duration(seconds: 1));
      var enteredDispatch = false;
      readClock = () {
        if (service.dispatchedCount > 0) {
          enteredDispatch = true;
          return start;
        }
        return enteredDispatch ? settled : now;
      };
      await expectLater(
        agent.call('notes.save', {'title': 12, 'body': 'malformed'}),
        throwsA(
          isA<RpcError>().having(
            (error) => error.code,
            'code',
            RpcErrorCode.invalidArgument,
          ),
        ),
      );
      await eventually(() => service.dispatchedCount == 0);
      expect(enteredDispatch, isFalse);
      expect(service.lastAgentActivity, isNull);
      expect(service.domain.store.rows('SELECT * FROM notes'), isEmpty);
    },
  );
  test(
    'malformed agent input preserves armed desktop departure and deadline',
    () async {
      final d = await desktop();
      await d.close();
      await departed();
      expect(service.desktopShutdownScheduled, isTrue);
      final departure = service.lastDesktopDeparture;
      final deadline = departure!.add(const Duration(seconds: 1));
      final scheduled = activeLifetimeTimers().single.delay;
      now = now.add(const Duration(milliseconds: 200));
      await expectLater(
        agent.call('notes.save', {'title': 12, 'body': 'bad'}),
        throwsA(
          isA<RpcError>().having(
            (error) => error.code,
            'code',
            RpcErrorCode.invalidArgument,
          ),
        ),
      );
      expect(service.dispatchedCount, 0);
      expect(service.lastAgentActivity, isNull);
      expect(service.lastDesktopDeparture, departure);
      expect(service.desktopShutdownScheduled, isTrue);
      expect(activeLifetimeTimers().map((timer) => timer.delay), [scheduled]);
      expect((await lifetime())['exit_after'], deadline.millisecondsSinceEpoch);
      now = deadline;
      await tick();
      await exited();
    },
  );

  test(
    'valid changed-key argument refusal still stamps dispatch and settlement',
    () async {
      await agent.call('notes.save', {
        'title': 'first',
        'body': 'body',
        'idempotency_key': 'key',
      });
      final start = now.add(const Duration(seconds: 1));
      final settled = start.add(const Duration(seconds: 1));
      var enteredDispatch = false;
      readClock = () {
        if (service.dispatchedCount > 0) {
          enteredDispatch = true;
          return start;
        }
        return enteredDispatch ? settled : now;
      };
      await expectLater(
        agent.call('notes.save', {
          'title': 'changed',
          'body': 'body',
          'idempotency_key': 'key',
        }),
        throwsA(
          isA<RpcError>().having(
            (error) => error.code,
            'code',
            RpcErrorCode.invalidArgument,
          ),
        ),
      );
      await eventually(() => service.dispatchedCount == 0);
      expect(enteredDispatch, isTrue);
      expect(service.lastAgentActivity, settled);
      expect(service.domain.store.rows('SELECT title FROM notes'), [
        {'title': 'first'},
      ]);
    },
  );

  test(
    'status-only service exits from service start without activity',
    () async {
      now = now.add(const Duration(minutes: 30));
      await lifetime();
      await service.closed.timeout(const Duration(seconds: 10));
      expect(service.lastAgentActivity, null);
    },
  );

  for (final desktopBranch in [false, true]) {
    test(
      '${desktopBranch ? 'desktop grace' : 'idle period'} uses one clock snapshot when evaluation straddles its deadline',
      () async {
        if (desktopBranch) {
          final d = await desktop();
          await d.close();
          await departed();
          expect(service.desktopShutdownScheduled, true);
        }
        final deadline = now.add(
          desktopBranch
              ? const Duration(seconds: 1)
              : const Duration(minutes: 30),
        );
        var reads = 0;
        readClock = () => reads++ == 0
            ? deadline.subtract(const Duration(microseconds: 1))
            : deadline.add(const Duration(microseconds: 1));
        // The first evaluation is just before the deadline; only its real
        // sub-millisecond timer may trigger the next evaluation. Polling again
        // would hide a mistaken fallback to the 30-second periodic check.
        await lifetime();
        await service.closed.timeout(const Duration(seconds: 3));
        expect(reads, greaterThanOrEqualTo(2));
      },
    );
  }

  test(
    'a disconnected one-shot agent can reconnect warm before the period',
    () async {
      await agent.call('notes.list');
      await agent.close();
      now = now.add(const Duration(minutes: 29));
      agent = await ServiceClient.connect(service.path);
      expect((await agent.call('status') as Map)['pid'], pid);
      expect(service.lastAgentActivity, DateTime.utc(2026, 10, 20));
      now = now.add(const Duration(minutes: 1));
      await tick();
      await exited();
    },
  );
  test('old completed agent work keeps the desktop departure grace', () async {
    await agent.call('notes.list');
    final stamp = service.lastAgentActivity;
    final d = await desktop();
    now = now.add(const Duration(minutes: 31));
    await d.call('notes.list');
    expect(service.lastAgentActivity, stamp);
    await d.close();
    await departed();
    expect(service.desktopShutdownScheduled, true);
    expect(
      (await lifetime())['exit_after'],
      now.add(const Duration(seconds: 1)).millisecondsSinceEpoch,
    );
    now = now.add(const Duration(seconds: 1));
    await tick();
    await exited();
  });
  for (final host in [false, true]) {
    test(
      '${host ? 'attached' : 'reserved'} desktop business requests preserve an unset agent stamp and departure grace',
      () async {
        final d = await desktop(host: host);
        expect((await lifetime())['pinned_by_desktop'], true);
        now = now.add(const Duration(minutes: 1));
        await d.call('notes.list');
        expect((await lifetime())['last_agent_activity'], null);
        await d.close();
        await departed();
        expect(service.desktopShutdownScheduled, true);
        expect(
          (await lifetime())['exit_after'],
          now.add(const Duration(seconds: 1)).millisecondsSinceEpoch,
        );
        now = now.add(const Duration(seconds: 1));
        await tick();
        await exited();
      },
    );
  }
  test(
    'recent completed agent work selects the idle branch at departure',
    () async {
      final d = await desktop();
      await agent.call('notes.list');
      await d.close();
      await departed();
      expect(service.desktopShutdownScheduled, false);
      now = now.add(const Duration(minutes: 29));
      expect((await lifetime())['busy'], false);
      now = now.add(const Duration(minutes: 1));
      await tick();
      await exited();
    },
  );
  test(
    'activity ageing out never re-arms a desktop departure shortcut',
    () async {
      final d = await desktop();
      await agent.call('notes.list');
      now = now.add(const Duration(minutes: 29));
      await d.close();
      await departed();
      expect(service.desktopShutdownScheduled, false);
      expect(
        (await lifetime())['exit_after'],
        DateTime.utc(2026, 10, 20, 0, 30).millisecondsSinceEpoch,
      );
      now = now.add(const Duration(seconds: 59));
      await lifetime();
      expect(service.desktopShutdownScheduled, false);
      now = now.add(const Duration(seconds: 1));
      await tick();
      await exited();
    },
  );
  test('agent dispatch during grace disarms the desktop shortcut', () async {
    final d = await desktop();
    await d.close();
    await departed();
    expect(service.desktopShutdownScheduled, true);
    await agent.call('notes.list');
    expect(service.desktopShutdownScheduled, false);
    now = now.add(const Duration(seconds: 2));
    await lifetime();
    expect(
      (await lifetime())['exit_after'],
      DateTime.utc(2026, 10, 20, 0, 30).millisecondsSinceEpoch,
    );
    now = now.add(const Duration(minutes: 30));
    await tick();
    await exited();
  });
  for (final value in ['0', '-1', 'Infinity', 'NaN']) {
    test(
      'idle preference $value disables idle exit but leaves a fresh desktop grace',
      () async {
        service.domain.store.setPreference('serviceIdleMinutes', value);
        now = now.add(const Duration(days: 1));
        final state = await lifetime();
        expect(state['idle_minutes'], 0.0);
        expect(state['exit_after'], null);
        final d = await desktop();
        await d.close();
        await departed();
        expect(service.desktopShutdownScheduled, true);
        now = now.add(const Duration(seconds: 1));
        await tick();
        await exited();
      },
    );
  }
  test(
    'disabled idle period with past agent work keeps the service after desktop departure',
    () async {
      service.domain.store.setPreference('serviceIdleMinutes', '0');
      await agent.call('notes.list');
      final d = await desktop();
      await d.close();
      await departed();
      now = now.add(const Duration(days: 1));
      expect((await lifetime())['exit_after'], null);
      expect(service.desktopShutdownScheduled, false);
    },
  );
  for (final duration in [
    const Duration(minutes: 1),
    const Duration(minutes: 31),
  ]) {
    test(
      'desktop departure preserves an agent generation running for ${duration.inMinutes} minutes',
      () async {
        final generator = ArtifactGenerator()
          ..entered = Completer<void>()
          ..release = Completer<void>();
        service.domain.generator = generator;
        addTearDown(() {
          if (!generator.release!.isCompleted) generator.release!.complete();
        });
        final meeting = service.domain.store.meeting('Agent work');
        service.domain.store.transcript(
          meeting,
          'Captured text',
          true,
          0,
          1,
          'imported',
        );
        final work = agent.call('meetings.generate', {
          'id': meeting,
          'kind': 'summary',
        });
        await generator.entered!.future;
        final d = await desktop();
        now = now.add(duration);
        await d.close();
        await departed();
        expect(service.desktopShutdownScheduled, false);
        expect((await lifetime())['exit_after'], null);
        generator.release!.complete();
        await work;
        expect(
          service.domain.store.rows('SELECT * FROM artifacts'),
          isNotEmpty,
        );
        final settled = now;
        expect(service.lastAgentActivity, settled);
        expect(
          (await lifetime())['exit_after'],
          settled.add(const Duration(minutes: 30)).millisecondsSinceEpoch,
        );
        now = settled.add(const Duration(minutes: 30));
        await tick();
        await exited();
      },
    );
  }
  for (final finishing in [false, true]) {
    test(
      '${finishing ? 'finishing' : 'active'} recording holds the idle branch',
      () async {
        final recording = TestRecording()..finishing = finishing;
        service.application.recording = recording;
        now = now.add(const Duration(hours: 1));
        expect((await lifetime())['busy'], true);
        expect((await lifetime())['exit_after'], null);
        service.application.recording = null;
        recording.dispose();
        service.application.changed();
        await exited();
      },
    );
  }
  test(
    'desktop branch finishes a reserved desktop recording before cleanup',
    () async {
      final d = await desktop();
      final recording = TestRecording();
      service.application.recording = recording;
      service.application.recordingMeeting = service.domain.store.meeting(
        'Closing recording',
      );
      await d.close();
      await departed();
      now = now.add(const Duration(seconds: 1));
      await tick();
      await exited();
      expect(recording.stopped, true);
    },
  );
  test('paused durable source work does not hold the idle branch', () async {
    final id = service.domain.store.importText(
      'durable',
      'pending content',
      'text/plain',
      'fixture',
    );
    service.domain.pauseSources();
    final work = service.domain.index(id);
    final cancelled = expectLater(work, throwsA(isA<RpcError>()));
    expect(service.domain.mutating, 0);
    now = now.add(const Duration(minutes: 30));
    await tick();
    await exited();
    await cancelled;
  });
  test(
    'desktop departure waits for an executing serialized mutation',
    () async {
      final rag = DelayedIndexService();
      final server = Server.create(
        services: [rag, TranscriptIndexService(rag)],
      );
      await server.serve(
        address: InternetAddress(
          service.domain.helper.socket,
          type: InternetAddressType.unix,
        ),
        port: 0,
      );
      addTearDown(server.shutdown);
      addTearDown(() {
        if (!rag.release.isCompleted) rag.release.complete();
      });
      final d = await desktop();
      final id = service.domain.store.importText(
        'serialized',
        'text',
        'text/plain',
        'fixture',
      );
      final work = service.domain.index(id);
      await rag.started.future;
      await d.close();
      await departed();
      now = now.add(const Duration(seconds: 1));
      await lifetime();
      expect(service.domain.mutating, 1);
      await backgroundRefusal();
      // A passed grace with executing work retains the periodic check instead
      // of repeatedly scheduling a zero-delay timer while that work is gated.
      interleaveStatusTimer();
      expectPeriodicLifetimeCheck();
      rag.release.complete();
      await work;
      await exited();
    },
  );
  test(
    'desktop departure cancels and joins leased import indexing before idle exit',
    () async {
      final rag = DelayedIndexService();
      final server = Server.create(
        services: [rag, TranscriptIndexService(rag)],
      );
      await server.serve(
        address: InternetAddress(
          service.domain.helper.socket,
          type: InternetAddressType.unix,
        ),
        port: 0,
      );
      addTearDown(server.shutdown);
      addTearDown(() {
        if (!rag.release.isCompleted) rag.release.complete();
      });
      final d = await desktop(host: true);
      final work = d.call('sources.import', {
        'title': 'Desktop import',
        'text': 'Committed desktop content',
      });
      final disconnected = expectLater(work, throwsA(isA<RpcError>()));
      await rag.started.future;
      final id = service.domain.store.sources.single['id'];
      expect(service.lastAgentActivity, null);
      await d.close();
      await disconnected;
      await departed();
      await eventually(
        () =>
            rag.indexCall?.isCanceled == true &&
            service.dispatchedCount == 0 &&
            service.domain.mutating == 0,
      );
      expect(service.desktopShutdownScheduled, true);
      expect(service.domain.store.sources.single['state'], 'pending');
      // Actual request cancellation and transport cleanup retire the lease.
      // The native helper need not send an acknowledgement to a dead client.
      expect(rag.release.isCompleted, false);
      now = now.add(const Duration(seconds: 1));
      await lifetime();
      await exited();
      expect(rag.release.isCompleted, false);
      final store = Store('${profile.data}/application.db');
      try {
        expect(store.sources.single['id'], id);
        expect(store.sources.single['state'], 'pending');
        rag.release.complete();
        await Future<void>.delayed(Duration.zero);
        expect(
          store.sources.single['state'],
          'pending',
          reason: 'A canceled RPC cannot publish a late acknowledgement',
        );
        expect(store.sources.single['content'], 'Committed desktop content');
      } finally {
        store.close();
      }
      expect(service.lastAgentActivity, null);
    },
  );
  test(
    'a request arriving after an idle close begins receives closing',
    () async {
      final gates = await ServiceGates.create(root);
      runtimeConfiguration.environment['FORESIGHT_SERVICE_GATES'] =
          gates.directory.path;
      gates.hold('close.begin');
      addTearDown(gates.releaseAll);
      now = now.add(const Duration(minutes: 30));
      await tick();
      await gates.reached('close.begin');
      await expectLater(
        agent.call('notes.list'),
        throwsA(
          isA<RpcError>().having(
            (e) => e.reason,
            'reason',
            RpcErrorReason.closing,
          ),
        ),
      );
      gates.release('close.begin');
      await exited();
    },
  );

  test(
    'desktop departure closes during resume while cancelling future readiness callbacks',
    () async {
      await withAdoptableHelper((rag) async {
        final gates = await ServiceGates.create(root);
        runtimeConfiguration.environment['FORESIGHT_SERVICE_GATES'] =
            gates.directory.path;
        gates.hold('close.begin');
        addTearDown(gates.releaseAll);
        final d = await desktop();
        rag.release.complete();
        await rag.configuring.future;
        expect(service.domain.resumeInProgress, true);
        await backgroundRefusal(desktopPinned: true);
        expect((await lifetime())['busy'], true);
        await d.close();
        await departed();
        now = now.add(const Duration(seconds: 1));
        await tick();
        await gates.reached('close.begin');
        expect(service.domain.resumeInProgress, true);
        expect(service.domain.helper.onReady, null);
        rag.configured.complete();
        gates.release('close.begin');
        await exited();
        await eventually(() => !service.domain.resumeInProgress);
      }, model: true);
    },
  );
  test(
    'agent waiting for helper readiness holds the desktop branch without stamping',
    () async {
      await withAdoptableHelper((rag) async {
        final entered = Completer<void>(), release = Completer<void>();
        service.domain.helper.onReady = () async {
          entered.complete();
          await release.future;
        };
        addTearDown(() {
          if (!release.isCompleted) release.complete();
        });
        rag.release.complete();
        await entered.future;
        final generator = ArtifactGenerator();
        service.domain.generator = generator;
        final meeting = service.domain.store.meeting('Waiting agent');
        service.domain.store.transcript(
          meeting,
          'Captured text',
          true,
          0,
          1,
          'imported',
        );
        final d = await desktop();
        final work = agent.call('meetings.generate', {
          'id': meeting,
          'kind': 'summary',
        });
        await eventually(() async => (await lifetime())['busy'] == true);
        expect(service.lastAgentActivity, null);
        await d.close();
        await departed();
        expect(service.desktopShutdownScheduled, false);
        now = now.add(const Duration(minutes: 31));
        expect((await lifetime())['exit_after'], null);
        release.complete();
        await work;
        expect(service.lastAgentActivity, now);
        now = now.add(const Duration(minutes: 30));
        await tick();
        await exited();
      });
    },
  );
  test(
    'pending helper ping cannot start resume after automatic close begins',
    () async {
      await withAdoptableHelper((rag) async {
        final gates = await ServiceGates.create(root);
        runtimeConfiguration.environment['FORESIGHT_SERVICE_GATES'] =
            gates.directory.path;
        gates.hold('close.begin');
        addTearDown(gates.releaseAll);
        var readinessCalls = 0;
        service.domain.helper.onReady = () async {
          readinessCalls++;
        };
        final d = await desktop();
        await rag.entered.future;
        await d.close();
        await departed();
        now = now.add(const Duration(seconds: 1));
        await tick();
        await gates.reached('close.begin');
        rag.release.complete();
        await service.ready;
        expect(readinessCalls, 0);
        gates.release('close.begin');
        await exited();
      });
    },
  );

  test('status polling at 100 ms never postpones the exit deadline', () async {
    service.domain.store.setPreference('serviceIdleMinutes', '0.05');
    await agent.call('notes.list');
    final deadline = service.lastAgentActivity!.add(const Duration(seconds: 3));
    for (var n = 0; n < 29; n++) {
      now = now.add(const Duration(milliseconds: 100));
      expect((await lifetime())['exit_after'], deadline.millisecondsSinceEpoch);
    }
    now = now.add(const Duration(milliseconds: 100));
    await tick();
    await exited();
  });
  test(
    'cancelled leased parked source indexing leaves no watcher or activity at readiness cancellation',
    () async {
      service.domain.pauseSources();
      final id = service.domain.store.importText(
        'parked',
        'body',
        'text/plain',
        'fixture',
      );
      final subscription = agent
          .stream('sources.index', {'id': id})
          .listen((_) {});
      await eventually(() => service.domain.cancellationWatchCount == 1);
      await subscription.cancel();
      await eventually(
        () =>
            service.domain.cancellationWatchCount == 0 &&
            service.dispatchedCount == 0,
      );
      expect(service.domain.store.sources.single['state'], 'pending');
      now = now.add(const Duration(minutes: 30));
      await tick();
      await exited();
    },
  );
  test(
    'unleased generator work holds the idle branch until its settle notification',
    () async {
      final generator = GeneratingRuntime();
      service.domain.generator = generator;
      now = now.add(const Duration(minutes: 30));
      expect((await lifetime())['busy'], true);
      expect((await lifetime())['exit_after'], null);
      await backgroundRefusal();
      generator.active = false;
      service.application.changed();
      await exited();
    },
  );
  test(
    'initialization holds idle exit until completion despite a restoring latch',
    () async {
      final initialized = Completer<void>();
      service.domain.initialize(initialized.future);
      now = now.add(const Duration(minutes: 30));
      expect((await lifetime())['exit_after'], null);
      await backgroundRefusal();
      initialized.complete();
      await exited();
      expect(service.domain.initializationPending, false);
      expect(service.domain.restoring, true);
    },
  );
  test(
    'unleased model configuration holds idle exit until the helper operation settles',
    () async {
      final rag = ResumeRag();
      final server = Server.create(
        services: [rag, TranscriptIndexService(rag)],
      );
      await server.serve(
        address: InternetAddress(
          service.domain.helper.socket,
          type: InternetAddressType.unix,
        ),
        port: 0,
      );
      addTearDown(server.shutdown);
      addTearDown(() {
        if (!rag.configured.isCompleted) rag.configured.complete();
      });
      final file = File('${root.path}/model.litertlm')
        ..writeAsStringSync('embedding fixture');
      final work = service.application.call('models.embedding', {
        'path': file.path,
      });
      await rag.configuring.future;
      now = now.add(const Duration(minutes: 30));
      expect((await lifetime())['exit_after'], null);
      expect(service.application.backgroundBusy, true);
      await backgroundRefusal();
      rag.configured.complete();
      await work;
      await exited();
    },
  );
  test(
    'unleased note enhancement and its transcript drain hold idle exit',
    () async {
      final rag = EmbeddingService()..embeddingGate = Completer<void>();
      final server = Server.create(
        services: [rag, TranscriptIndexService(rag)],
      );
      await server.serve(
        address: InternetAddress(
          service.domain.helper.socket,
          type: InternetAddressType.unix,
        ),
        port: 0,
      );
      addTearDown(server.shutdown);
      addTearDown(() {
        if (!rag.embeddingGate!.isCompleted) rag.embeddingGate!.complete();
      });
      service.domain.helper.snapshot = control.State(pipeline: 'ready');
      service.domain.generator = PromptRuntime();
      final id = service.domain.store.meeting('Enhancing');
      service.domain.store.saveMeetingNotes(id, 'Raw note');
      service.domain.store.transcript(
        id,
        'Saved evidence',
        true,
        0,
        20,
        'imported',
      );
      final work = service.application.enhanceNotes(id);
      await rag.embeddingEntered.future;
      now = now.add(const Duration(minutes: 30));
      expect((await lifetime())['busy'], true);
      expect((await lifetime())['exit_after'], null);
      expect(service.application.activeEnhancements, 1);
      expect(service.application.transcriptComputing, 1);
      await backgroundRefusal();
      rag.embeddingGate!.complete();
      await work;
      await exited();
    },
  );
  test(
    'cancelled proactive retrieval drains without waiting for its server response',
    () async {
      final rag = ProactiveRag()..release.complete();
      final server = Server.create(
        services: [rag, TranscriptIndexService(rag)],
      );
      await server.serve(
        address: InternetAddress(
          service.domain.helper.socket,
          type: InternetAddressType.unix,
        ),
        port: 0,
      );
      addTearDown(server.shutdown);
      addTearDown(() {
        if (!rag.retrieved.isCompleted) rag.retrieved.complete();
      });
      final id = service.domain.store.meeting('Proactive answer');
      service.domain.store.transcript(
        id,
        'Captured evidence',
        true,
        0,
        20,
        'imported',
      );
      service.domain.generator = ArtifactGenerator();
      final queue = service.application.proactive;
      queue.begin(id);
      service.domain.store.db.execute(
        'INSERT INTO meeting_questions(meeting_id,question,normalized,created) '
        'VALUES(?,?,?,?)',
        [id, 'Who owns it?', 'who owns it', 0],
      );
      queue.notify(id);
      final work = queue.process();
      await rag.retrieving.future;
      expect(queue.running, true);
      await backgroundRefusal();
      await queue.close();
      await work;
      expect(service.application.proactive.running, false);
      // Cancellation now interrupts the client RPC. Its server may still be
      // blocked, but no answer producer remains to pin the application owner.
      await eventually(() => rag.retrievalCall!.isCanceled);
      await eventually(() => service.application.proactiveWork == 0);
      expect(rag.retrieved.isCompleted, false);
      now = now.add(const Duration(minutes: 30));
      await tick();
      await exited();
    },
  );
  test(
    'cancelled proactive generation stays busy until native cleanup settles',
    () async {
      final rag = StreamRag()..release.complete();
      final server = Server.create(
        services: [rag, TranscriptIndexService(rag)],
      );
      await server.serve(
        address: InternetAddress(
          service.domain.helper.socket,
          type: InternetAddressType.unix,
        ),
        port: 0,
      );
      addTearDown(server.shutdown);
      final generator = CleanupRuntime();
      addTearDown(() {
        if (!generator.bodyRelease.isCompleted) {
          generator.bodyRelease.complete();
        }
        if (!generator.cleanupRelease.isCompleted) {
          generator.cleanupRelease.complete();
        }
      });
      final id = service.domain.store.meeting('Proactive generation cleanup');
      service.domain.store.transcript(
        id,
        'Mira owns the draft.',
        true,
        0,
        20,
        'imported',
      );
      rag.document = 'meeting-$id';
      service.domain.generator = generator;
      final queue = service.application.proactive;
      queue.begin(id);
      service.domain.store.db.execute(
        'INSERT INTO meeting_questions(meeting_id,question,normalized,created) '
        'VALUES(?,?,?,?)',
        [id, 'Who owns it?', 'who owns it', 0],
      );
      queue.notify(id);
      final work = queue.process();
      await generator.bodyEntered.future;
      await backgroundRefusal();
      await queue.close();
      await work;
      expect(queue.running, false);
      generator.bodyRelease.complete();
      await generator.cleanupEntered.future;
      expect(service.application.proactiveWork, 1);
      now = now.add(const Duration(minutes: 30));
      expect((await lifetime())['exit_after'], null);
      await backgroundRefusal();
      generator.cleanupRelease.complete();
      await exited();
      expect(service.application.proactiveWork, 0);
    },
  );
  test(
    'missing desktop approval fails before dispatch and never stamps agent activity',
    () async {
      final host = await desktop(host: true);
      await host.call('security.detach_desktop');
      await expectLater(
        agent.call('sources.import', {'title': 'denied', 'text': 'body'}),
        throwsA(
          isA<RpcError>()
              .having((e) => e.code, 'code', RpcErrorCode.denied)
              .having((e) => e.reason, 'reason', RpcErrorReason.needsDesktop),
        ),
      );
      expect((await lifetime())['last_agent_activity'], null);
      expect(service.dispatchedCount, 0);
    },
  );
  test(
    'unleased meeting indexing holds idle exit only while its helper mutation executes',
    () async {
      final rag = DelayedIndexService();
      final server = Server.create(
        services: [rag, TranscriptIndexService(rag)],
      );
      await server.serve(
        address: InternetAddress(
          service.domain.helper.socket,
          type: InternetAddressType.unix,
        ),
        port: 0,
      );
      addTearDown(server.shutdown);
      addTearDown(() {
        if (!rag.release.isCompleted) rag.release.complete();
      });
      final id = service.domain.store.meeting('Indexing meeting');
      service.domain.store.transcript(
        id,
        'Captured evidence',
        true,
        0,
        20,
        'imported',
      );
      final work = service.application.indexMeeting(id);
      await rag.started.future;
      now = now.add(const Duration(minutes: 30));
      expect(service.domain.mutating, 1);
      await backgroundRefusal();
      expect((await lifetime())['exit_after'], null);
      rag.release.complete();
      await work;
      await exited();
    },
  );
  test('resume holds idle exit until its model load completes', () async {
    await withAdoptableHelper((rag) async {
      rag.release.complete();
      await rag.configuring.future;
      now = now.add(const Duration(minutes: 30));
      expect((await lifetime())['exit_after'], null);
      expect(service.domain.resumeInProgress, true);
      await backgroundRefusal();
      rag.configured.complete();
      await exited();
      await eventually(() => !service.domain.resumeInProgress);
    }, model: true);
  });
  for (final mode in ['complete', 'error', 'cancel-cleanup-error']) {
    test(
      'streamed answer $mode stays dispatched until its cleanup settles',
      () async {
        final rag = StreamRag()..release.complete();
        final server = Server.create(
          services: [rag, TranscriptIndexService(rag)],
        );
        await server.serve(
          address: InternetAddress(
            service.domain.helper.socket,
            type: InternetAddressType.unix,
          ),
          port: 0,
        );
        addTearDown(server.shutdown);
        final generator = CleanupRuntime()..failCleanup = mode != 'complete';
        service.domain.generator = generator;
        addTearDown(() {
          if (!generator.bodyRelease.isCompleted) {
            generator.bodyRelease.complete();
          }
          if (!generator.cleanupRelease.isCompleted) {
            generator.cleanupRelease.complete();
          }
        });
        rag.document = service.domain.store.importText(
          'Draft',
          'Mira owns the draft.',
          'text/plain',
          'fixture',
        );
        service.domain.store.state(rag.document, 'indexed');
        final d = await desktop();
        final values = <Object?>[];
        final done = Completer<void>();
        final subscription = agent
            .stream('answer.stream', {'question': 'Who owns the draft?'})
            .listen(
              values.add,
              onError: (Object error) {
                if (!done.isCompleted) done.completeError(error);
              },
              onDone: () {
                if (!done.isCompleted) done.complete();
              },
            );
        final Future<void>? failed = mode == 'error'
            ? expectLater(done.future, throwsA(isA<RpcError>()))
            : null;
        await generator.bodyEntered.future;
        now = now.add(const Duration(minutes: 31));
        await d.close();
        await departed();
        expect(service.desktopShutdownScheduled, false);
        if (mode == 'cancel-cleanup-error') await subscription.cancel();
        expect((await lifetime())['busy'], true);
        generator.bodyRelease.complete();
        await generator.cleanupEntered.future;
        expect(service.dispatchedCount, 1);
        expect((await lifetime())['exit_after'], null);
        await expectLater(
          agent.call('service.stop_if_idle', {
            'token': File(
              '${profile.data}/.desktop-capability',
            ).readAsStringSync(),
          }),
          throwsA(
            isA<RpcError>().having(
              (e) => e.message,
              'message',
              contains('operations are in progress'),
            ),
          ),
        );
        generator.cleanupRelease.complete();
        if (mode == 'complete') await done.future;
        if (failed != null) await failed;
        await eventually(() => service.dispatchedCount == 0);
        expect(service.lastAgentActivity, now);
        expect((await lifetime())['busy'], false);
        expect(values, isNotEmpty);
        now = now.add(const Duration(minutes: 30));
        await tick();
        await exited();
      },
    );
  }
  test(
    'production query acquisition refuses idle shutdown until cancellation settles',
    () async {
      final executable = File('${root.path}/unused-worker')
        ..writeAsStringSync('never launched');
      runtimeConfiguration.environment.addAll({
        'FORESIGHT_WEB_CONTENT_API_KEY': 'cancelled-fixture-key',
        'FORESIGHT_QUERY_WORKER': executable.path,
        'FORESIGHT_MODEL_CRYPTO': executable.path,
        'FORESIGHT_QUERY_RUNTIME': executable.path,
        'FORESIGHT_QUERY_TERMS_URL': 'https://example.invalid/terms',
      });
      service.domain.store.setPreference(dedicatedQueryTermsKey, 'accepted');
      final metadata = await ServerSocket.bind(
        InternetAddress(
          '${root.path}/metadata.sock',
          type: InternetAddressType.unix,
        ),
        0,
      );
      final started = Completer<Map<String, dynamic>>();
      final retired = Completer<void>();
      final header = BytesBuilder(copy: false);
      Socket? metadataPeer;
      var accepted = 0;
      final subscription = metadata.listen((peer) {
        accepted++;
        metadataPeer = peer;
        peer.listen(
          (chunk) {
            if (started.isCompleted || header.length + chunk.length > 256) {
              fail('Invalid metadata worker fixture handoff');
            }
            header.add(chunk);
            if (!chunk.contains(10)) return;
            started.complete(
              Map<String, dynamic>.from(
                jsonDecode(utf8.decode(header.takeBytes())) as Map,
              ),
            );
          },
          onDone: () {
            if (!retired.isCompleted) retired.complete();
            peer.destroy();
          },
          onError: (Object error) {
            expect(error, isA<SocketException>());
            if (!retired.isCompleted) retired.complete();
            peer.destroy();
          },
        );
      });
      addTearDown(() async {
        await service.application.call('models.cancel_query_acquisition', {});
        metadataPeer?.destroy();
        await subscription.cancel();
        await metadata.close();
      });
      final python =
          Platform.environment['FORESIGHT_PYTHON'] ?? '/usr/bin/python3';
      expect(File(python).existsSync(), true);
      final transport = File('${root.path}/metadata-peer')
        ..writeAsStringSync('''#!$python
import json, os, signal, socket, sys
raw = sys.stdin.buffer.read(16385)
if len(raw) > 16384:
    sys.exit(91)
try:
    config = json.loads(raw)
except Exception:
    sys.exit(92)
if config.get('kind') != 'metadata' or config.get('appVersion') != '1.0.0':
    sys.exit(93)
peer = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
peer.connect(${jsonEncode(metadata.address.address)})
peer.sendall((json.dumps({'kind': 'metadata', 'version': '1.0.0', 'pid': os.getpid()}) + '\\n').encode())
while True:
    signal.pause()
''');
      final executableMode = await runCaptureProcess('/bin/chmod', [
        '700',
        transport.path,
      ], timeout: const Duration(seconds: 5));
      expect(executableMode.exitCode, 0);
      runtimeConfiguration.environment['FORESIGHT_SERVICE'] = transport.path;
      // Hold the actual owned metadata child after its bounded stdin handoff.
      // This keeps the real distribution acquisition owner, without contacting
      // the metadata service, inspecting credentials or fabricating model data.
      final work = service.application.call('models.acquire_query', {});
      final cancelled = expectLater(
        work,
        throwsA(
          isA<RpcError>().having((e) => e.code, 'code', RpcErrorCode.cancelled),
        ),
      );
      cancelled.ignore();
      final handoff = await started.future.timeout(const Duration(seconds: 5));
      expect(accepted, 1);
      expect(handoff.keys.toSet(), {'kind', 'version', 'pid'});
      expect(handoff['kind'], 'metadata');
      expect(handoff['version'], '1.0.0');
      final childPid = handoff['pid'] as int;
      expect(childPid, greaterThan(1));
      expect(childPid, isNot(pid));
      final alive = await runCaptureProcess('/bin/kill', [
        '-0',
        '$childPid',
      ], timeout: const Duration(seconds: 5));
      expect(alive.exitCode, 0);
      expect(service.application.queryAcquiring, true);
      expect(service.application.backgroundBusy, true);
      await backgroundRefusal();
      final cancellation = service.application.call(
        'models.cancel_query_acquisition',
        {},
      );
      await cancellation.timeout(const Duration(seconds: 5));
      await cancelled;
      await retired.future.timeout(const Duration(seconds: 2));
      final reaped = await runCaptureProcess('/bin/kill', [
        '-0',
        '$childPid',
      ], timeout: const Duration(seconds: 5));
      expect(
        reaped.exitCode,
        isNot(0),
        reason: 'owned metadata child must be reaped',
      );
      expect(accepted, 1);
      expect(service.application.queryAcquiring, false);
      expect((await lifetime())['busy'], false);
    },
    skip: Platform.isMacOS
        ? false
        : 'Production acquisition factory requires macOS',
  );
  test(
    'orphaned live transcript embedding alone refuses idle shutdown until settled',
    () async {
      final rag = EmbeddingService()..embeddingGate = Completer<void>();
      final server = Server.create(
        services: [rag, TranscriptIndexService(rag)],
      );
      await server.serve(
        address: InternetAddress(
          service.domain.helper.socket,
          type: InternetAddressType.unix,
        ),
        port: 0,
      );
      addTearDown(server.shutdown);
      addTearDown(() {
        if (!rag.embeddingGate!.isCompleted) rag.embeddingGate!.complete();
      });
      service.domain.helper.snapshot = control.State(pipeline: 'ready');
      service.domain.pauseSources();
      final id = service.domain.store.meeting('Embedding only');
      final recording = TestRecording();
      service.application.recording = recording;
      service.application.recordingMeeting = id;
      await service.application.call('meetings.transcript', {
        'id': id,
        'text': 'Captured evidence',
      });
      await rag.embeddingEntered.future;
      service.domain.resumeSources();
      await service.application.indexMeeting(id);
      expect(service.domain.store.sources.single['state'], 'indexed');
      expect(service.domain.mutating, 0);
      service.application.recording = null;
      service.application.recordingMeeting = null;
      recording.dispose();
      expect(service.application.activeEnhancements, 0);
      expect(service.application.transcriptComputing, 1);
      now = now.add(const Duration(minutes: 30));
      expect((await lifetime())['exit_after'], null);
      await backgroundRefusal();
      rag.embeddingGate!.complete();
      await exited();
    },
  );
  test(
    'a notes edit schedules its production 30 second enhancement timer without busy work until it fires',
    () async {
      print('NOTES_TIMER_PROGRESS phase=0 elapsed_us=0');
      final rag = EmbeddingService()..embeddingGate = Completer<void>();
      var phase = 0;
      final phaseClock = Stopwatch()..start();
      final phaseMicros = <int>[];
      void mark(int value) {
        phase = value;
        phaseMicros.add(phaseClock.elapsedMicroseconds);
        print(
          'NOTES_TIMER_PROGRESS phase=$phase elapsed_us=${phaseMicros.last}',
        );
      }

      addTearDown(() {
        final diagnostics = {
          'phase': phase,
          'micros': phaseMicros,
          'embedding_entered': rag.embeddingEntered.isCompleted,
          'embedding_gate_completed': rag.embeddingGate!.isCompleted,
          'embedding_calls': rag.texts.length,
          'active_enhancements': service.application.activeEnhancements,
          'mutating': service.domain.mutating,
        };
        print('NOTES_TIMER_PHASE ${jsonEncode(diagnostics)}');
      });
      mark(1);
      final server = Server.create(
        services: [rag, TranscriptIndexService(rag)],
      );
      final acceptedSockets = <Socket>[];
      final servingConnections = <Future<void>>[];
      final listener = await ServerSocket.bind(
        InternetAddress(
          service.domain.helper.socket,
          type: InternetAddressType.unix,
        ),
        0,
      );
      addTearDown(listener.close);
      final accepts = listener.listen(
        (socket) {
          acceptedSockets.add(socket);
          servingConnections.add(
            server.serveConnection(
              connection: ServerTransportConnection.viaSocket(socket),
            ),
          );
        },
        onError: (Object error, StackTrace stack) {
          Zone.current.handleUncaughtError(error, stack);
        },
      );
      mark(2);
      addTearDown(() async {
        // The body already awaits service.closed. Destroy only this fixture's
        // accepted sockets so transport cleanup cannot wait for remote IO.
        print(
          'NOTES_TIMER_LISTENER phase=0 elapsed_us=${phaseClock.elapsedMicroseconds}',
        );
        await listener.close();
        await accepts.cancel();
        print(
          'NOTES_TIMER_LISTENER phase=1 elapsed_us=${phaseClock.elapsedMicroseconds}',
        );
        final connections = server.handlers.keys.toList();
        print(
          'NOTES_TIMER_TEARDOWN phase=2 connections=${connections.length} sockets=${acceptedSockets.length} elapsed_us=${phaseClock.elapsedMicroseconds}',
        );
        for (final socket in acceptedSockets) {
          socket.destroy();
        }
        await Future.wait([
          ...servingConnections,
          for (final connection in connections) connection.terminate(),
        ]);
        print(
          'NOTES_TIMER_TEARDOWN phase=3 elapsed_us=${phaseClock.elapsedMicroseconds}',
        );
        await server.shutdown();
        print(
          'NOTES_TIMER_TEARDOWN phase=4 elapsed_us=${phaseClock.elapsedMicroseconds}',
        );
      });
      addTearDown(() {
        print(
          'NOTES_TIMER_TEARDOWN phase=0 elapsed_us=${phaseClock.elapsedMicroseconds}',
        );
        if (!rag.embeddingGate!.isCompleted) rag.embeddingGate!.complete();
        print(
          'NOTES_TIMER_TEARDOWN phase=1 elapsed_us=${phaseClock.elapsedMicroseconds}',
        );
      });
      service.domain.helper.snapshot = control.State(pipeline: 'ready');
      service.domain.generator = PromptRuntime();
      final id = service.domain.store.meeting('Automatic enhancement');
      service.domain.store.saveMeetingNotes(id, 'Previous note');
      service.domain.store.transcript(
        id,
        'Saved evidence',
        true,
        0,
        20,
        'imported',
      );
      // Settle this fixture's cold HTTP/2 connection before firing the timer.
      // The five-second production embedding deadline remains unchanged.
      final savedNotes = service.domain.store.meetingNoteRows(id);
      final savedTranscript = service.domain.store.meetingTranscript(id);
      mark(3);
      final ready = await service.domain.helper.client.indexDocument(
        IndexRequest(),
      );
      mark(4);
      expect(ready.success, isTrue);
      expect(rag.embeddingEntered.isCompleted, isFalse);
      expect(rag.texts, isEmpty);
      expect(service.domain.store.meetingNoteRows(id), savedNotes);
      expect(service.domain.store.meetingTranscript(id), savedTranscript);
      expect(service.domain.store.sources, isEmpty);
      editingNotes = true;
      await service.application.call('meetings.notes', {
        'id': id,
        'body': '- Draft shorthand',
      });
      editingNotes = false;
      expect(enhancementTimer?.isActive, true);
      expect(service.application.backgroundBusy, false);
      expect((await lifetime())['busy'], false);
      mark(5);
      enhancementTimer!.cancel();
      fireEnhancement!();
      expect(service.application.activeEnhancements, 1);
      mark(6);
      await rag.embeddingEntered.future;
      mark(7);
      expect(service.application.activeEnhancements, 1);
      now = now.add(const Duration(minutes: 31));
      expect((await lifetime())['exit_after'], null);
      await backgroundRefusal();
      mark(8);
      rag.embeddingGate!.complete();
      await exited();
      mark(9);
    },
  );
  test(
    'workspace clear leaves an orphaned enhancement producer busy until embedding settles',
    () async {
      final rag = EmbeddingService()..embeddingGate = Completer<void>();
      final server = Server.create(
        services: [rag, TranscriptIndexService(rag)],
      );
      await server.serve(
        address: InternetAddress(
          service.domain.helper.socket,
          type: InternetAddressType.unix,
        ),
        port: 0,
      );
      addTearDown(server.shutdown);
      addTearDown(() {
        if (!rag.embeddingGate!.isCompleted) rag.embeddingGate!.complete();
      });
      service.domain.helper.snapshot = control.State(pipeline: 'ready');
      service.domain.generator = PromptRuntime();
      final id = service.domain.store.meeting('Orphaned producer');
      service.domain.store.saveMeetingNotes(id, 'Raw note');
      service.domain.store.transcript(
        id,
        'Saved evidence',
        true,
        0,
        20,
        'imported',
      );
      final work = service.application.enhanceNotes(id);
      await rag.embeddingEntered.future;
      await service.application.call('workspace.clear', {});
      expect(service.application.captureState['note_enhancements'], isEmpty);
      expect(service.application.activeEnhancements, 1);
      expect(service.application.transcriptComputing, 1);
      now = now.add(const Duration(minutes: 31));
      expect((await lifetime())['exit_after'], null);
      await backgroundRefusal();
      rag.embeddingGate!.complete();
      await work;
      await exited();
    },
  );
}
