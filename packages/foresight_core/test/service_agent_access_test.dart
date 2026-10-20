import 'package:foresight_test_support/test_paths.dart';
import 'package:foresight_test_support/poll.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:foresight_core/foresight_core.dart';
import 'package:foresight_core/src/service.dart';
import 'package:foresight_core/src/application.dart';
import 'package:foresight_core/src/rpc_error.dart';
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

class CountingRecording extends Recording {
  int stops = 0;
  CountingRecording()
    : super(
        Platform.isMacOS ? '/usr/lib/libSystem.B.dylib' : 'libc.so.6',
        (_) {},
        (_, __, ___, ____) {},
      );
  @override
  Future<void> stop() async => stops++;
  @override
  void dispose() {}
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
    'an oversized reply fails its request without dropping the desktop or its recording',
    () async {
      await attach();
      final app = service.domain.application;
      final recording = CountingRecording();
      app.recording = recording;
      app.recordingMeeting = service.domain.store.meeting('Recording');
      // Together these notes exceed one 16 MiB reply frame.
      final body = 'x' * (6 * 1024 * 1024);
      for (var i = 0; i < 3; i++) {
        service.domain.store.saveNote(null, 'Large $i', body);
      }
      try {
        await expectLater(
          desktop.call('notes.list'),
          throwsA(
            isA<RpcError>()
                .having((error) => error.code, 'code', RpcErrorCode.internal)
                .having(
                  (error) => error.message,
                  'message',
                  'Reply exceeds 16 MiB; request fewer items.',
                ),
          ),
        );
        // The same connection still answers, so the service never saw its
        // host leave and never stopped the recording.
        expect(desktop.isClosed, isFalse);
        expect((await desktop.call('status') as Map)['pid'], pid);
        expect(service.access.hasHost, isTrue);
        expect(recording.stops, 0);
        expect(app.recording, same(recording));
      } finally {
        app.recording = null;
        app.recordingMeeting = null;
      }
    },
  );
  test('an oversized reply is the last frame of its request', () async {
    final body = 'x' * (6 * 1024 * 1024);
    for (var i = 0; i < 3; i++) {
      service.domain.store.saveNote(null, 'Large $i', body);
    }
    // A raw socket sees every frame; ServiceClient ignores finished requests.
    final raw = await Socket.connect(
      InternetAddress(service.path, type: InternetAddressType.unix),
      0,
    );
    final frames = StreamIterator(
      raw
          .cast<List<int>>()
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .map((line) => jsonDecode(line) as Map)
          .where((frame) => frame['event'] == null),
    );
    try {
      raw.writeln(jsonEncode({'id': 1, 'method': 'notes.list', 'args': {}}));
      expect(await frames.moveNext(), isTrue);
      expect(frames.current, {
        'id': 1,
        'error': {
          'code': 'internal',
          'message': 'Reply exceeds 16 MiB; request fewer items.',
        },
        'done': true,
      });
      // Its own completion frame would have been written before this reply.
      raw.writeln(jsonEncode({'id': 2, 'method': 'status', 'args': {}}));
      expect(await frames.moveNext(), isTrue);
      expect(frames.current['id'], 2);
      expect((frames.current['result'] as Map)['pid'], pid);
    } finally {
      await frames.cancel();
      raw.destroy();
    }
  });
  test('an oversized event is dropped without dropping the desktop', () async {
    await attach();
    final app = service.domain.application;
    final recording = CountingRecording();
    app.recording = recording;
    app.recordingMeeting = service.domain.store.meeting('Recording');
    final levels = <List<Object?>>[];
    final subscription = desktop.events.stream
        .where((event) => event['event'] == 'capture_levels')
        .listen((event) => levels.add(event['volumes'] as List<Object?>));
    try {
      // About 24 MB of levels exceed one frame.
      recording.currentVolumes.addAll(List.filled(2000000, 0.123456789));
      app.captureLevelChanges.add(null);
      // The service handles the level change before this request arrives,
      // and writes frames in order, so a sent event would arrive first.
      // Status would carry the same levels, so use a reply without them.
      expect(await desktop.call('notes.list'), isEmpty);
      expect(levels, isEmpty);
      recording.currentVolumes
        ..clear()
        ..add(0.5);
      app.captureLevelChanges.add(null);
      await eventually(() => levels.isNotEmpty);
      expect(levels.single, [0.5]);
      expect(desktop.isClosed, isFalse);
      expect(recording.stops, 0);
    } finally {
      await subscription.cancel();
      app.recording = null;
      app.recordingMeeting = null;
    }
  });

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
