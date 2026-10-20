import 'package:foresight_test_support/test_paths.dart';
import 'package:foresight_test_support/poll.dart';
import 'dart:async';
import 'dart:convert';
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

/// A desktop connection every write to fails, as one whose peer has gone
/// before the service saw its end.
class UnwritableSocket implements Socket {
  var destroyed = false;
  @override
  void add(List<int> data) =>
      throw const SocketException('Broken pipe', osError: OSError('', 32));
  @override
  void destroy() => destroyed = true;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  // The production grace, for tests that need the shutdown to happen.
  const shortGrace = Duration(seconds: 1);
  // Long enough that no reconnect or reservation has to race the shutdown.
  const longGrace = Duration(seconds: 5);
  late Directory temp;
  late ApplicationService service;
  late ServiceClient agent, desktop;
  late Map<String, String> original;
  Future<void> startService(Duration grace) async {
    service = await ApplicationService.start(
      ProfilePaths('${temp.path}/profile', '${temp.path}/run'),
      desktopDetachGrace: grace,
    );
    agent = await ServiceClient.connect(service.path);
    desktop = await ServiceClient.connect(service.path);
  }

  /// Restart the service with [grace], for a test whose reconnect or
  /// reservation must land while a shutdown is pending.
  Future<void> restartService(Duration grace) async {
    await agent.close();
    await desktop.close();
    await service.close();
    await startService(grace);
  }

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
    await startService(shortGrace);
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

  /// Wait until the service has seen the desktop's connection end.
  Future<void> hostGone() => eventually(
    () => !service.access.hasHost,
    timeout: const Duration(seconds: 30),
  );
  Future<void> attach() async => desktop.call('security.attach_desktop', {
    'token': File(
      '${temp.path}/profile/.desktop-capability',
    ).readAsStringSync(),
  });
  // Store one note so that the notes.list reply to request [id], with its
  // newline, is exactly [bytes] long.
  void sizeNotesReply(int bytes, {int id = 1}) {
    final store = service.domain.store;
    store.saveNote(null, 'Sized', '');
    final note = store.db.lastInsertRowId;
    int frame() =>
        utf8
            .encode(
              jsonEncode({
                'id': id,
                'result': store.rows('SELECT * FROM notes ORDER BY id'),
                'done': false,
              }),
            )
            .length +
        1;
    var body = 0;
    for (var i = 0; i < 3 && frame() != bytes; i++) {
      body += bytes - frame();
      store.saveNote(note, 'Sized', 'x' * body);
    }
    expect(frame(), bytes);
  }

  test(
    'a reply of exactly the client limit fails its request, not the connection',
    () async {
      // Its completion frame follows in the same socket read. Clients count
      // bytes per read, so delivering this reply would exceed their limit.
      sizeNotesReply(maxServiceMessage);
      final client = await ServiceClient.connect(service.path);
      try {
        await expectLater(
          client.call('notes.list'),
          throwsA(
            isA<RpcError>()
                .having((error) => error.code, 'code', RpcErrorCode.internal)
                .having(
                  (error) => error.message,
                  'message',
                  'Reply exceeds 15 MiB; request fewer items.',
                ),
          ),
        );
        expect(client.isClosed, isFalse);
        expect((await client.call('status') as Map)['pid'], pid);
      } finally {
        await client.close();
      }
    },
  );
  test('a reply at the frame cap reaches the client intact', () async {
    sizeNotesReply(maxServiceMessage - 1024 * 1024);
    final client = await ServiceClient.connect(service.path);
    try {
      final notes = await client.call('notes.list') as List;
      expect(notes.single['title'], 'Sized');
      expect(client.isClosed, isFalse);
      expect((await client.call('status') as Map)['pid'], pid);
    } finally {
      await client.close();
    }
  });
  // 'é' is two UTF-8 bytes but one UTF-16 code unit, so these replies tell a
  // byte cap from one that counts characters.
  String notesReply() => jsonEncode({
    'id': 1,
    'result': service.domain.store.rows('SELECT * FROM notes ORDER BY id'),
    'done': false,
  });
  test('the reply cap counts UTF-8 bytes, not characters', () async {
    const cap = maxServiceMessage - 1024 * 1024;
    service.domain.store.saveNote(null, 'Wide', 'é' * (cap ~/ 2 + 64 * 1024));
    final reply = notesReply();
    expect(reply.length, lessThan(cap));
    expect(utf8.encode(reply).length, greaterThan(cap));
    final client = await ServiceClient.connect(service.path);
    try {
      await expectLater(
        client.call('notes.list'),
        throwsA(
          isA<RpcError>()
              .having((error) => error.code, 'code', RpcErrorCode.internal)
              .having(
                (error) => error.message,
                'message',
                'Reply exceeds 15 MiB; request fewer items.',
              ),
        ),
      );
      expect(client.isClosed, isFalse);
      expect((await client.call('status') as Map)['pid'], pid);
    } finally {
      await client.close();
    }
  });
  test('a multibyte reply under the byte cap arrives intact', () async {
    const cap = maxServiceMessage - 1024 * 1024;
    final body = 'é' * (cap ~/ 2 - 64 * 1024);
    service.domain.store.saveNote(null, 'Wide', body);
    expect(utf8.encode(notesReply()).length, lessThan(cap));
    final client = await ServiceClient.connect(service.path);
    try {
      final notes = await client.call('notes.list') as List;
      expect(notes.single['body'], body);
      expect(client.isClosed, isFalse);
    } finally {
      await client.close();
    }
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
    await restartService(longGrace);
    await attach();
    await desktop.close();
    // Client.close destroys the local socket; the service observes EOF later.
    // Reconnect after that transition, while its grace is active.
    await hostGone();
    expect(service.desktopShutdownScheduled, isTrue);
    desktop = await ServiceClient.connect(service.path);
    await attach();
    expect(service.desktopShutdownScheduled, isFalse);
    expect((await desktop.call('status') as Map)['pid'], pid);
  });
  test(
    'startup snapshot reserves desktop lifetime before visible approvals attach',
    () async {
      await restartService(longGrace);
      await attach();
      await desktop.close();
      await hostGone();
      expect(service.desktopShutdownScheduled, isTrue);
      final startup = await ensureServiceSnapshot(
        ProfilePaths('${temp.path}/profile', '${temp.path}/run'),
      );
      desktop = startup.client;
      expect(
        service.access.hasHost,
        isFalse,
        reason: 'Startup liveness is not an approval-host grant',
      );
      // The reservation cancelled the pending shutdown.
      expect(service.desktopShutdownScheduled, isFalse);
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
      await service.closed.timeout(longGrace + const Duration(seconds: 10));
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
      await hostGone();
      // The other reservation keeps the service from scheduling shutdown.
      expect(service.desktopShutdownScheduled, isFalse);
      expect((await next.call('status') as Map)['pid'], pid);
    } finally {
      await next.close();
    }
    await service.closed.timeout(const Duration(seconds: 10));
  });

  test('ordinary startup status does not reserve desktop lifetime', () async {
    await attach();
    await agent.close();
    // Probe before the desktop leaves, so nothing has to beat the grace.
    agent = await ensureService(
      ProfilePaths('${temp.path}/profile', '${temp.path}/run'),
    );
    await desktop.close();
    await hostGone();
    // The open probe connection did not keep the shutdown from scheduling.
    expect(service.desktopShutdownScheduled, isTrue);
    await service.closed.timeout(const Duration(seconds: 10));
    // Server cleanup can finish before this client's EOF callback runs.
    await agent.socket.done.timeout(const Duration(seconds: 3));
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
      await agent.socket.done.timeout(const Duration(seconds: 3));
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
      // Past a grace that would have ended, had a desktop been attached.
      await Future<void>.delayed(
        shortGrace + const Duration(milliseconds: 200),
      );
      expect(service.desktopShutdownScheduled, isFalse);
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
      // Together these notes exceed one reply frame.
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
                  'Reply exceeds 15 MiB; request fewer items.',
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
          'message': 'Reply exceeds 15 MiB; request fewer items.',
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
  test('an approval too large to show fails its request at once', () async {
    await attach();
    final approvals = <Map<String, dynamic>>[];
    final subscription = desktop.events.stream
        .where((event) => event['event'] == 'approval')
        .listen(approvals.add);
    // The service still accepts this request, but its approval event, which
    // carries the arguments, exceeds the frame cap.
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
      raw.writeln(
        jsonEncode({
          'id': 1,
          'method': 'sources.import',
          'args': {
            'title': 'Large',
            'content': 'x' * (maxServiceMessage - 1024 * 1024),
          },
        }),
      );
      // Without a delivered approval this would wait for the two-minute
      // approval timeout; bound it well below that.
      expect(
        await frames.moveNext().timeout(const Duration(seconds: 10)),
        isTrue,
      );
      expect(frames.current, {
        'id': 1,
        'error': {
          'code': 'invalidArgument',
          'message': 'Request is too large to show for approval',
        },
        'done': true,
      });
      expect(approvals, isEmpty);
      expect(await desktop.call('notes.list'), isEmpty);
      expect(service.domain.store.sources, isEmpty);
    } finally {
      await subscription.cancel();
      await frames.cancel();
      raw.destroy();
    }
  });
  test('an approval the desktop connection cannot be written to fails its '
      'request as unavailable, not as too large', () async {
    final host = UnwritableSocket();
    service.access.attach(
      host,
      File('${temp.path}/profile/.desktop-capability').readAsStringSync(),
    );
    await expectLater(
      agent.call('sources.delete', {'id': 'source'}),
      throwsA(
        isA<RpcError>()
            .having((error) => error.code, 'code', RpcErrorCode.unavailable)
            .having(
              (error) => error.message,
              'message',
              'The desktop approval window could not be reached; retry once '
                  'the desktop app is open',
            ),
      ),
    );
    // The failed connection is closed.
    expect(host.destroyed, isTrue);
  });
  test('frames JSON cannot encode fail alone, not the desktop', () async {
    await attach();
    final app = service.domain.application;
    final recording = CountingRecording();
    app.recording = recording;
    app.recordingMeeting = service.domain.store.meeting('Recording');
    try {
      // Status replies and level events both carry these levels.
      recording.currentVolumes.add(double.nan);
      app.captureLevelChanges.add(null);
      await expectLater(
        desktop.call('status'),
        throwsA(
          isA<RpcError>()
              .having((error) => error.code, 'code', RpcErrorCode.internal)
              .having(
                (error) => error.message,
                'message',
                contains('JSON cannot represent'),
              ),
        ),
      );
      expect(desktop.isClosed, isFalse);
      expect(await desktop.call('notes.list'), isEmpty);
      expect(service.access.hasHost, isTrue);
      expect(recording.stops, 0);
    } finally {
      app.recording = null;
      app.recordingMeeting = null;
    }
  });
  test(
    'an oversized request is refused locally without dropping the desktop',
    () async {
      await attach();
      final app = service.domain.application;
      final recording = CountingRecording();
      app.recording = recording;
      app.recordingMeeting = service.domain.store.meeting('Recording');
      try {
        // Sent, this would exceed the service's request limit, and the
        // service would close the connection.
        await expectLater(
          desktop.call('notes.save', {
            'title': 'Large',
            'body': 'x' * maxServiceMessage,
          }),
          throwsA(
            isA<RpcError>()
                .having(
                  (error) => error.code,
                  'code',
                  RpcErrorCode.invalidArgument,
                )
                .having(
                  (error) => error.message,
                  'message',
                  'Request exceeds 15 MiB; send less data.',
                ),
          ),
        );
        expect(desktop.isClosed, isFalse);
        expect(await desktop.call('notes.list'), isEmpty);
        expect(service.access.hasHost, isTrue);
        expect(recording.stops, 0);
      } finally {
        app.recording = null;
        app.recordingMeeting = null;
      }
    },
  );
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
