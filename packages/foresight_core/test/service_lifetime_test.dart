import 'dart:async';
import 'dart:io';
import 'package:clock/clock.dart';
import 'package:foresight_core/foresight_core.dart';
import 'package:foresight_core/src/service.dart';
import 'package:foresight_test_support/poll.dart';
import 'package:foresight_test_support/hooked_service.dart';
import 'package:foresight_core/src/rpc_error.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:foresight_test_support/test_recording.dart';
import 'package:foresight_test_support/delayed_index_service.dart';
import 'package:foresight_test_support/helper_adoption.dart';
import 'package:foresight_core/src/generated/helper_control.pb.dart' as control;
import 'package:foresight_core/src/generated/rag_service.pbgrpc.dart';
import 'package:grpc/grpc.dart';
import 'application_operations_test.dart' show ArtifactGenerator;
import 'note_transcript_cache_application_test.dart'
    show EmbeddingService, PromptRuntime;
import 'package:test/test.dart';

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
  final retrieving = Completer<void>(), retrieved = Completer<void>();
  @override
  Future<RetrieveResponse> retrieveContext(
    ServiceCall call,
    RetrieveRequest request,
  ) async {
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

void main() {
  late Directory root;
  late ProfilePaths profile;
  late ApplicationService service;
  late ServiceClient agent;
  late Map<String, String> environment;
  var now = DateTime.utc(2026, 10, 20);
  setUp(() async {
    environment = Map.of(runtimeConfiguration.environment);
    runtimeConfiguration.environment.removeWhere(
      (key, _) => key.startsWith('FORESIGHT_'),
    );
    runtimeConfiguration.environment['FORESIGHT_HELPER'] = '';
    root = createTestTempDirectorySync('lifetime-');
    profile = ProfilePaths('${root.path}/d', '${root.path}/r');
    now = DateTime.utc(2026, 10, 20);
    service = await ApplicationService.start(profile, clock: Clock(() => now));
    await service.ready;
    service.domain.store.setPreference('serviceIdleMinutes', '30');
    agent = await ServiceClient.connect('${profile.runtime}/application.sock');
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
      'desktop': true,
      'token': File('${profile.data}/.desktop-capability').readAsStringSync(),
    });
    return client;
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

  Future<void> exited() => service.closed.timeout(const Duration(seconds: 10));
  Future<T> withAdoptableHelper<T>(
    Future<T> Function(ResumeRag) body, {
    bool model = false,
  }) async {
    await agent.close();
    await service.close();
    runtimeConfiguration.environment.removeWhere(
      (key, _) => key.startsWith('FORESIGHT_'),
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
    service = await ApplicationService.start(profile, clock: Clock(() => now));
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
        agent.call('service.stop_if_idle'),
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
    'status-only service exits from service start without activity',
    () async {
      now = now.add(const Duration(minutes: 30));
      await lifetime();
      await service.closed.timeout(const Duration(seconds: 10));
      expect(service.lastAgentActivity, null);
    },
  );

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
    final d = await desktop();
    now = now.add(const Duration(minutes: 31));
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
      final server = Server.create(services: [rag]);
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
      rag.release.complete();
      await work;
      await exited();
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
      final server = Server.create(services: [rag]);
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
      rag.configured.complete();
      await work;
      await exited();
    },
  );
  test(
    'unleased note enhancement and its transcript drain hold idle exit',
    () async {
      final rag = EmbeddingService()..embeddingGate = Completer<void>();
      final server = Server.create(services: [rag]);
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
      rag.embeddingGate!.complete();
      await work;
      await exited();
    },
  );
  test(
    'cancelled proactive answer remains busy after its coordinator has stopped',
    () async {
      final rag = ProactiveRag()..release.complete();
      final server = Server.create(services: [rag]);
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
      final work = service.application.proactive.answer(
        id,
        'Who owns it?',
        'background-answer',
      );
      final cancelled = expectLater(work, throwsA(isA<RpcError>()));
      await rag.retrieving.future;
      service.application.proactive.cancel('background-answer');
      await cancelled;
      expect(service.application.proactive.running, false);
      expect(service.application.proactiveWork, 1);
      now = now.add(const Duration(minutes: 30));
      expect((await lifetime())['exit_after'], null);
      rag.retrieved.complete();
      await exited();
    },
  );
  test(
    'missing desktop approval fails before dispatch and never stamps agent activity',
    () async {
      final host = await desktop(host: true);
      await host.call('security.detach_desktop');
      await expectLater(
        agent.call('sources.import', {'title': 'denied', 'content': 'body'}),
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
      final server = Server.create(services: [rag]);
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
      rag.configured.complete();
      await exited();
      await eventually(() => !service.domain.resumeInProgress);
    }, model: true);
  });
}
