import 'package:foresight_test_support/test_paths.dart';
import 'dart:async';
import 'dart:io';
import 'package:foresight_core/foresight_core.dart';
import 'package:foresight_core/src/service.dart';
import 'package:foresight_core/src/rpc_error.dart';
import 'package:foresight_core/src/application.dart';
import 'package:test/test.dart';

class FailingDetachRecording extends Recording {
  FailingDetachRecording()
    : super(
        Platform.isMacOS ? '/usr/lib/libSystem.B.dylib' : 'libc.so.6',
        (_) {},
        (_, __, ___, ____) {},
      );
  @override
  Future<void> stop() async => throw StateError('capture stop failed');
  @override
  void dispose() => throw StateError('capture cleanup failed');
}

void main() {
  late Directory temp;
  late ApplicationService service;
  late ServiceClient agent, desktop;
  late Map<String, String> original;
  setUp(() async {
    original = Map.of(runtimeConfiguration.environment);
    for (final key in [
      'FORESIGHT_HELPER',
      'FORESIGHT_NATIVE',
      'FORESIGHT_RUNTIME_REVISION',
      'FORESIGHT_INSTALL_ROOT',
    ]) {
      runtimeConfiguration.environment.remove(key);
    }
    temp = createTestTempDirectorySync('of-access-');
    service = await ApplicationService.start(
      ProfilePaths('${temp.path}/profile', '${temp.path}/run'),
    );
    agent = await ServiceClient.connect(service.path);
    desktop = await ServiceClient.connect(service.path);
  });
  setUp(() {
    addTearDown(() async {
      await agent.close();
      await desktop.close();
      await service.close();
      temp.deleteSync(recursive: true);
      runtimeConfiguration.environment
        ..clear()
        ..addAll(original);
    });
  });
  Future<void> attach() async => desktop.call('security.attach_desktop', {
    'token': File(
      '${temp.path}/profile/.desktop-capability',
    ).readAsStringSync(),
  });
  test(
    'desktop socket closure shuts down service and persists committed data',
    () async {
      await attach();
      await desktop.call('notes.save', {'title': 'Retained', 'body': 'Saved'});
      await desktop.close();
      await service.closed.timeout(const Duration(seconds: 10));
      expect(File(service.path).existsSync(), isFalse);
      final store = Store('${temp.path}/profile/application.db');
      try {
        expect(
          store.rows('SELECT title FROM notes').single['title'],
          'Retained',
        );
      } finally {
        store.close();
      }
    },
  );
  test('desktop reconnect during grace period keeps service alive', () async {
    await attach();
    await desktop.close();
    // Client.close destroys the local socket; the service observes EOF later.
    // Reconnect after that transition, while its one-second grace is active.
    final disconnect = Stopwatch()..start();
    while (service.access.hasHost &&
        disconnect.elapsed < const Duration(milliseconds: 750)) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(service.access.hasHost, isFalse);
    desktop = await ServiceClient.connect(service.path);
    await attach();
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    expect((await desktop.call('status') as Map)['pid'], pid);
  });
  test(
    'startup snapshot reserves desktop lifetime before visible approvals attach',
    () async {
      await attach();
      await desktop.close();
      final disconnect = Stopwatch()..start();
      while (service.access.hasHost &&
          disconnect.elapsed < const Duration(milliseconds: 750)) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(service.access.hasHost, isFalse);
      final startup = await ensureServiceSnapshot(
        ProfilePaths('${temp.path}/profile', '${temp.path}/run'),
      );
      desktop = startup.client;
      expect(
        service.access.hasHost,
        isFalse,
        reason: 'Startup liveness is not an approval-host grant',
      );
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      expect((await desktop.call('status') as Map)['pid'], pid);
      await expectLater(
        desktop.call('meetings.start', {'id': 1}),
        throwsA(
          isA<RpcError>().having(
            (error) => error.code,
            'code',
            RpcErrorCode.denied,
          ),
        ),
      );
      await attach();
      expect(service.access.hasHost, isTrue);
      await desktop.close();
      await service.closed.timeout(const Duration(seconds: 10));
    },
  );

  test('closing one desktop leaves another reserved desktop alive', () async {
    await attach();
    final startup = await ensureServiceSnapshot(
      ProfilePaths('${temp.path}/profile', '${temp.path}/run'),
    );
    final next = startup.client;
    try {
      await desktop.close();
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      expect(service.access.hasHost, isFalse);
      expect((await next.call('status') as Map)['pid'], pid);
    } finally {
      await next.close();
    }
    await service.closed.timeout(const Duration(seconds: 10));
  });

  test('ordinary startup status does not reserve desktop lifetime', () async {
    await attach();
    await desktop.close();
    await agent.close();
    agent = await ensureService(
      ProfilePaths('${temp.path}/profile', '${temp.path}/run'),
    );
    await service.closed.timeout(const Duration(seconds: 10));
    expect(agent.isClosed, isTrue);
  });

  test(
    'invalid desktop startup capability cannot reserve lifetime or approval rights',
    () async {
      await expectLater(
        agent.call('status', {'desktop': true, 'token': 'invalid'}),
        throwsA(
          isA<RpcError>().having(
            (error) => error.code,
            'code',
            RpcErrorCode.denied,
          ),
        ),
      );
      expect(service.access.hasHost, isFalse);
      await attach();
      await desktop.close();
      await service.closed.timeout(const Duration(seconds: 10));
      expect(agent.isClosed, isTrue);
    },
  );

  test(
    'explicit detach followed by desktop closure still shuts down',
    () async {
      await attach();
      await desktop.call('security.detach_desktop');
      await desktop.close();
      await service.closed.timeout(const Duration(seconds: 10));
      expect(File(service.path).existsSync(), isFalse);
    },
  );
  test(
    'headless agent connections do not acquire the desktop lifetime',
    () async {
      await desktop.close();
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      expect((await agent.call('status') as Map)['pid'], pid);
    },
  );
  test(
    'desktop detach observes a failing stop and leaves service responsive',
    () async {
      await attach();
      final app = service.domain.application;
      final id = service.domain.store.meeting('Recording');
      app.recording = FailingDetachRecording();
      app.recordingMeeting = id;
      await desktop.call('security.detach_desktop');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect((await agent.call('status') as Map)['pid'], pid);
      expect(app.recording, isNull);
    },
  );

  test(
    'raw socket cannot self-declare desktop or mutate without visible host',
    () async {
      await agent.call('notes.save', {
        'title': 'safe note',
        'body': 'readable',
      });
      expect(await agent.call('notes.list'), hasLength(1));
      for (final method in [
        'workspace.clear',
        'google.sign_in',
        'google.add_account',
        'google.switch_account',
        'google.sign_out_account',
        'meetings.start',
        'sources.import_file',
      ]) {
        await expectLater(
          agent.call(method, {'path': '/dev/zero', 'id': 1}),
          throwsStateError,
        );
      }
      await expectLater(
        agent.call('security.attach_desktop', {'token': 'forged'}),
        throwsStateError,
      );
      await expectLater(
        agent.call('security.allow_import_root', {'path': '/'}),
        throwsStateError,
      );
      expect(await agent.call('notes.list'), hasLength(1));
    },
  );
  test(
    'socket request waits for desktop denial; closing desktop cancels pending operation',
    () async {
      await attach();
      final approval = desktop.events.stream.firstWhere(
        (e) => e['event'] == 'approval',
      );
      final pending = agent.call('workspace.clear');
      final denied = expectLater(pending, throwsStateError);
      final event = await approval;
      await expectLater(
        agent.call('security.decide', {
          'approval_id': event['approval_id'],
          'allow': true,
        }),
        throwsStateError,
      );
      await desktop.call('security.decide', {
        'approval_id': event['approval_id'],
        'allow': false,
      });
      await denied;
      final next = desktop.events.stream.firstWhere(
        (e) => e['event'] == 'approval',
      );
      final cancelled = expectLater(
        agent.call('google.sign_in'),
        throwsStateError,
      );
      await next;
      await desktop.close();
      await cancelled;
    },
  );
  test(
    'approved file import still enforces roots, profile exclusion and special-file refusal',
    () async {
      await attach();
      final subscription = desktop.events.stream.listen((event) {
        if (event['event'] == 'approval') {
          unawaited(
            desktop.call('security.decide', {
              'approval_id': event['approval_id'],
              'allow': true,
            }),
          );
        }
      });
      addTearDown(subscription.cancel);
      final outside = File('${temp.path}/outside.txt')
        ..writeAsStringSync('secret');
      await expectLater(
        agent.call('sources.import_file', {'path': outside.path}),
        throwsStateError,
      );
      await desktop.call('security.allow_import_root', {'path': temp.path});
      await expectLater(
        agent.call('sources.import_file', {
          'path': '${temp.path}/profile/.desktop-capability',
        }),
        throwsStateError,
      );
      await expectLater(
        agent.call('sources.import_file', {'path': '/dev/zero'}),
        throwsStateError,
      );
      expect(service.domain.store.sources, isEmpty);
    },
  );
}
