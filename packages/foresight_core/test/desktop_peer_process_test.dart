import 'sql_support_test_bootstrap.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:foresight_core/foresight_core.dart';
import 'package:foresight_core/src/service.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:foresight_test_support/poll.dart';
import 'package:test/test.dart';
import 'fixtures/durable_capture_routes.dart';

const _interpreterProbe = r'''
import 'dart:io';
import 'dart:convert';
Future<void> main(List<String> args) async {
  final peer = await Socket.connect(InternetAddress(args[0], type: InternetAddressType.unix), 0);
  try {
    peer.writeln(jsonEncode({'id':1,'method':'security.attach_desktop','args':{'token':args[1],'visible':true}}));
    final reply = await peer.cast<List<int>>().transform(utf8.decoder).transform(const LineSplitter())
        .map((line) => jsonDecode(line) as Map)
        .firstWhere((frame) => frame['id'] == 1 && (frame.containsKey('error') || frame['done'] == true))
        .timeout(const Duration(seconds: 5));
    print(jsonEncode(reply));
  } finally {
    peer.destroy();
  }
}
''';

void _expectInterpreterDenied(ProcessResult result) {
  expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
  final reply = jsonDecode(result.stdout.toString()) as Map;
  expect(reply['id'], 1, reason: result.stdout.toString());
  expect(reply['error'], isNotNull, reason: result.stdout.toString());
  expect((reply['error'] as Map)['code'], 'denied');
  expect((reply['error'] as Map)['message'], contains('verified desktop'));
}

Future<void> _freshPeerProcess(String name) async {
  // Keep process proof and both pipes even after a failed parent test teardown.
  final output = shortTestTempRoot.createTempSync('desktop-peer-child-');
  final events = File('${output.path}/events.jsonl');
  final process = await Process.start(
    Platform.resolvedExecutable,
    [
      'test',
      'test/desktop_peer_process_test.dart',
      '--name',
      '^${RegExp.escape(name)}\$',
      '--reporter',
      'expanded',
      '--file-reporter=json:${events.path}',
    ],
    environment: {
      ...Platform.environment,
      'FORESIGHT_TEST_DESKTOP_PEER_CHILD': name,
      'FORESIGHT_TEST_DESKTOP_PEER_EVIDENCE': output.path,
    },
  );
  final stdout = StringBuffer(), stderr = StringBuffer();
  final outDone = Completer<void>(), errDone = Completer<void>();
  void finish(Completer<void> done) {
    if (!done.isCompleted) done.complete();
  }

  Object? pipeError;
  final outSubscription = process.stdout
      .transform(utf8.decoder)
      .listen(
        stdout.write,
        onDone: () => finish(outDone),
        onError: (Object error) {
          pipeError = error;
          finish(outDone);
        },
        cancelOnError: true,
      );
  final errSubscription = process.stderr
      .transform(utf8.decoder)
      .listen(
        stderr.write,
        onDone: () => finish(errDone),
        onError: (Object error) {
          pipeError = error;
          finish(errDone);
        },
        cancelOnError: true,
      );
  final elapsed = Stopwatch()..start();
  Duration remaining() {
    final budget = const Duration(seconds: 20) - elapsed.elapsed;
    return budget > Duration.zero ? budget : Duration.zero;
  }

  int? code;
  try {
    // This is inside the unchanged parent test budget. Reap before returning;
    // a native mapping's sealed environment cannot be reset by another isolate.
    code = await process.exitCode.timeout(remaining());
    await Future.wait([outDone.future, errDone.future]).timeout(remaining());
  } finally {
    try {
      if (code == null) process.kill(ProcessSignal.sigkill);
      await process.exitCode.timeout(const Duration(seconds: 2));
      await Future.wait([
        outSubscription.cancel(),
        errSubscription.cancel(),
      ]).timeout(const Duration(seconds: 2));
    } finally {
      await File('${output.path}/stdout.log').writeAsString(stdout.toString());
      await File('${output.path}/stderr.log').writeAsString(stderr.toString());
    }
  }
  final report = '$stdout\n$stderr\nEvidence: ${output.path}';
  expect(code, 0, reason: report);
  expect(pipeError, isNull, reason: report);
  final inputs =
      jsonDecode(File('${output.path}/inputs.json').readAsStringSync()) as Map;
  expect(
    inputs['pid'],
    isNot(pid),
    reason: 'Native globals require a fresh OS process',
  );
  for (final key in [
    'FORESIGHT_NATIVE_LIBRARY',
    'FORESIGHT_TEST_SQL_SUPPORT_LIBRARY',
    'FORESIGHT_SQLITE_LIBRARY',
    'FORESIGHT_HELPER',
    'FORESIGHT_TEST_HELPER',
  ]) {
    expect(inputs[key], Platform.environment[key], reason: report);
  }
  expect(
    inputs['selected_native'],
    Platform.environment['FORESIGHT_NATIVE_LIBRARY'],
  );
  expect(inputs['test_name'], name);
  expect(inputs['resolved_executable'], Platform.resolvedExecutable);
  final records = events
      .readAsLinesSync()
      .map((line) => jsonDecode(line) as Map<String, dynamic>)
      .toList();
  final completed = records.where(
    (event) => event['type'] == 'testDone' && event['hidden'] != true,
  );
  expect(completed, hasLength(1), reason: report);
  expect(completed.single['result'], 'success', reason: report);
  expect(completed.single['skipped'], false, reason: report);
  expect(records.last['type'], 'done', reason: report);
  expect(records.last['success'], true, reason: report);
  final started = records.where(
    (event) => event['type'] == 'testStart' && event['test']['name'] == name,
  );
  expect(started, hasLength(1), reason: report);
  expect(
    completed.single['testID'],
    started.single['test']['id'],
    reason: report,
  );
  print('Desktop peer: one child pass, zero skips; ${output.path}');
}

final class _DesktopProcess {
  _DesktopProcess._(this.process) {
    frames = StreamIterator(
      process.stdout.transform(utf8.decoder).transform(const LineSplitter()),
    );
    errors = process.stderr.transform(utf8.decoder).join();
  }
  final Process process;
  late final StreamIterator<String> frames;
  late final Future<String> errors;
  int _sequence = 0;

  static Future<_DesktopProcess> start(
    String executable,
    String socket,
  ) async => _DesktopProcess._(await Process.start(executable, [socket]));

  Future<Map> frame(
    String method, [
    Map<String, Object?> args = const {},
  ]) async {
    final id = ++_sequence;
    process.stdin.writeln(
      jsonEncode({'id': id, 'method': method, 'args': args}),
    );
    await process.stdin.flush();
    Object? result;
    while (await frames.moveNext().timeout(const Duration(seconds: 5))) {
      final value = jsonDecode(frames.current) as Map;
      if (value['id'] != id) continue;
      if (value.containsKey('error')) return value;
      if (value.containsKey('result')) result = value['result'];
      if (value['done'] == true) return {'result': result};
    }
    throw StateError('Peer connection closed: ${await errors}');
  }

  Future<void> close() async {
    try {
      await process.stdin.close();
      await process.exitCode.timeout(const Duration(seconds: 3));
    } finally {
      process.kill(ProcessSignal.sigkill);
      await process.exitCode;
      await frames.cancel();
      await errors;
    }
  }
}

void main() {
  bootstrapSqlSupportFixture();
  // Isolate service workers share the loaded native mapping's sealed cache
  // configuration. Give every real-native profile its own OS process; keep
  // compilation, setup, peer authentication and capture assertions in that child.
  final childCase = Platform.environment['FORESIGHT_TEST_DESKTOP_PEER_CHILD'];
  void peerTest(String name, Future<void> Function() body) {
    test(name, () async {
      if (childCase == null) {
        await _freshPeerProcess(name);
      } else {
        expect(childCase, name, reason: 'Only the selected peer case may run');
        await body();
      }
    });
  }

  late Directory installation;
  late String executable, impostor;
  late Directory directory;
  late ProfilePaths profile;
  late IsolatedApplicationService service;
  late Map<String, String> environment;

  setUpAll(() async {
    if (childCase == null) return;
    installation = createTestTempDirectorySync('desktop-executable-');
    final parent = Directory(
      Platform.isMacOS
          ? '${installation.path}/Contents/MacOS'
          : '${installation.path}/app',
    )..createSync(recursive: true);
    // Derive the expected desktop independently from the actual build input.
    // A verifier with a plausible but wrong synthetic filename must fail.
    final buildInput = File(
      Platform.isMacOS
          ? '../../apps/desktop/macos/Runner/Configs/AppInfo.xcconfig'
          : '../../apps/desktop/linux/CMakeLists.txt',
    ).readAsStringSync();
    final name =
        (Platform.isMacOS
                ? RegExp(r'^PRODUCT_NAME = (.+)$', multiLine: true)
                : RegExp(r'set\(BINARY_NAME "([^"]+)"\)'))
            .firstMatch(buildInput)!
            .group(1)!;
    executable = '${parent.path}/$name';
    final compile = await Process.run('c++', [
      '-std=c++17',
      'test/fixtures/desktop_peer.cpp',
      '-o',
      executable,
    ]);
    expect(compile.exitCode, 0, reason: '${compile.stdout}\n${compile.stderr}');
    impostor = '${installation.path}/untrusted-copy';
    File(executable).copySync(impostor);
  });

  setUp(() async {
    if (childCase == null) return;
    directory = createTestTempDirectorySync('desktop-process-');
    profile = ProfilePaths('${directory.path}/d', '${directory.path}/r');
    environment = Map.of(runtimeConfiguration.environment);
    runtimeConfiguration.environment.removeWhere(
      (key, _) =>
          key.startsWith('FORESIGHT_') && key != 'FORESIGHT_SQLITE_LIBRARY',
    );
    runtimeConfiguration.environment.addAll({
      'FORESIGHT_HELPER': '',
      // Service startup binds durable media before any recording request.
      'FORESIGHT_NATIVE': Platform.environment['FORESIGHT_NATIVE_LIBRARY']!,
      'FORESIGHT_INSTALL_ROOT': installation.path,
    });
    File(
      '${Platform.environment['FORESIGHT_TEST_DESKTOP_PEER_EVIDENCE']}/inputs.json',
    ).writeAsStringSync(
      jsonEncode({
        'pid': pid,
        'test_name': childCase,
        'resolved_executable': Platform.resolvedExecutable,
        'selected_native': runtimeConfiguration.environment['FORESIGHT_NATIVE'],
        for (final key in [
          'FORESIGHT_NATIVE_LIBRARY',
          'FORESIGHT_TEST_SQL_SUPPORT_LIBRARY',
          'FORESIGHT_SQLITE_LIBRARY',
          'FORESIGHT_HELPER',
          'FORESIGHT_TEST_HELPER',
        ])
          key: Platform.environment[key],
      }),
    );
    service = await IsolatedApplicationService.start(profile);
    addTearDown(() async {
      await service.close();
      runtimeConfiguration.environment
        ..clear()
        ..addAll(environment);
    });
  });

  String token() =>
      File('${profile.data}/.desktop-capability').readAsStringSync();
  Future<_DesktopProcess> peer([String? program, String? path]) async {
    final result = await _DesktopProcess.start(
      program ?? executable,
      path ?? serviceEndpoint(profile),
    );
    addTearDown(result.close);
    return result;
  }

  peerTest(
    'a hidden verified replacement preserves active capture and retains the host pin',
    () async {
      await service.close();
      late CapturePlatformFixture capture;
      final owner = await ApplicationService.start(
        profile,
        capturePlatform: (media) => capture = CapturePlatformFixture(
          media,
          onCreated: (route) {
            route.audio(0);
            capture.clock = 1100000;
          },
        ),
      );
      addTearDown(owner.close);
      owner.domain.store.setPreference('liveEnhance', 'false');
      final runner = File(
        '/usr/bin/true',
      ).copySync('${installation.path}/speech-runner');
      final model = File('${directory.path}/speech')
        ..writeAsStringSync('ABI fixture');
      await owner.domain.store.register('speech', model.path, runner.path);
      final meeting = owner.domain.store.meeting('Hidden replacement');
      final first = await peer();
      expect(
        await first.frame('security.attach_desktop', {
          'token': token(),
          'visible': true,
        }),
        {'result': true},
      );
      expect(
        (await first.frame('meetings.start', {'id': meeting}))['error'],
        isNull,
      );
      expect(owner.application.recording, isNotNull);
      final active = owner.application.recording!;
      expect(owner.application.captureState['capture_active'], true);
      expect(capture.routes, hasLength(2));
      final replacement = await peer();
      expect(
        await replacement.frame('security.attach_desktop', {
          'token': token(),
          'visible': false,
        }),
        {'result': true},
      );
      expect(owner.access.hasHost, true);
      expect(owner.access.hasVisibleHost, false);
      expect(owner.application.recording, same(active));
      expect(active.captureActive, true);
      expect(capture.routes.every((route) => !route.finished), true);
      final state = (await replacement.frame('status'))['result'] as Map;
      expect((state['lifetime'] as Map)['pinned_by_desktop'], true);
      expect(
        (await replacement.frame('meetings.start', {'id': meeting}))['error'],
        isNotNull,
      );
      expect(await replacement.frame('security.detach_desktop', {}), {
        'result': true,
      });
      await eventually(() => owner.application.recording == null);
      expect(owner.application.recordingMeeting, isNull);
      for (final route in capture.routes) {
        expect(route.finished, true);
        expect(route.retired, true);
        expect(
          route.log,
          containsAllInOrder(['finish-ack', 'poll-after-finish:0', 'retire']),
        );
      }
      expect(
        owner.domain.store.db
            .select(
              "SELECT COUNT(*) AS count FROM audio_chunks WHERE state='published'",
            )
            .single['count'],
        2,
      );
    },
  );

  peerTest(
    'a hidden replacement cancels pending durable capture admission',
    () async {
      await service.close();
      final entered = Completer<void>(), release = Completer<void>();
      late CapturePlatformFixture capture;
      final owner = await ApplicationService.start(
        profile,
        capturePlatform: (media) => capture = CapturePlatformFixture(
          media,
          prepared: (_) {
            if (!entered.isCompleted) entered.complete();
          },
        )..admission = release,
      );
      addTearDown(owner.close);
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      owner.domain.store.setPreference('liveEnhance', 'false');
      final runner = File(
        '/usr/bin/true',
      ).copySync('${installation.path}/pending-speech-runner');
      final model = File('${directory.path}/speech')
        ..writeAsStringSync('ABI fixture');
      await owner.domain.store.register('speech', model.path, runner.path);
      final meeting = owner.domain.store.meeting('Pending replacement');
      final first = await peer();
      expect(
        await first.frame('security.attach_desktop', {
          'token': token(),
          'visible': true,
        }),
        {'result': true},
      );
      final started = first.frame('meetings.start', {'id': meeting});
      started.ignore();
      await entered.future.timeout(const Duration(seconds: 5));
      final active = owner.application.recording!;
      expect(active.captureActive, false);
      final replacement = await peer();
      final attached = replacement.frame('security.attach_desktop', {
        'token': token(),
        'visible': false,
      });
      attached.ignore();
      await eventually(() => active.finishing);
      release.complete();
      expect(await attached, {'result': true});
      expect(((await started)['error'] as Map)['code'], 'cancelled');
      await eventually(() => owner.application.recording == null);
      expect(capture.routes, isEmpty);
      expect(owner.application.recordingMeeting, isNull);
      expect(owner.access.hasHost, true);
      expect(owner.access.hasVisibleHost, false);
      final state = (await replacement.frame('status'))['result'] as Map;
      expect((state['lifetime'] as Map)['pinned_by_desktop'], true);
    },
  );

  peerTest(
    'OS executable identity rejects a token thief and allows verified replacement',
    () async {
      final desktop = await peer();
      final initial = token();
      expect(
        await desktop.frame('security.attach_desktop', {
          'token': initial,
          'visible': true,
        }),
        {'result': true},
      );
      final rotated = token();
      expect(rotated, isNot(initial));
      runtimeConfiguration
              .environment['FORESIGHT_DEVELOPMENT_DESKTOP_EXECUTABLES'] =
          jsonEncode([impostor]);
      final thief = await peer(impostor);
      final stolen = await thief.frame('security.attach_desktop', {
        'token': rotated,
        'visible': true,
      });
      expect((stolen['error'] as Map)['message'], contains('verified desktop'));
      expect(token(), rotated);
      final replacement = await peer();
      expect(
        await replacement.frame('security.attach_desktop', {
          'token': rotated,
          'visible': true,
        }),
        {'result': true},
      );
      expect(token(), isNot(rotated));
      expect(
        (await desktop.frame('security.allow_import_root', {
          'path': directory.path,
        }))['error'],
        isNotNull,
      );
      expect(
        await replacement.frame('security.allow_import_root', {
          'path': directory.path,
        }),
        {'result': true},
      );
      expect(
        (await replacement.frame('security.attach_desktop', {
          'token': rotated,
          'visible': true,
        }))['error'],
        isNotNull,
      );
    },
  );

  peerTest(
    'hidden windows retain their host and refuse capture until visible again',
    () async {
      final desktop = await peer();
      expect(
        await desktop.frame('security.attach_desktop', {
          'token': token(),
          'visible': true,
        }),
        {'result': true},
      );
      expect(
        await desktop.frame('security.desktop_visibility', {'visible': false}),
        {'result': true},
      );
      final hidden = await desktop.frame('meetings.start', {'id': 999});
      expect((hidden['error'] as Map)['code'], 'denied');
      expect(
        await desktop.frame('security.allow_import_root', {
          'path': directory.path,
        }),
        {'result': true},
        reason: 'The hidden desktop still owns its slot',
      );
      final state = (await desktop.frame('status'))['result'] as Map;
      expect((state['lifetime'] as Map)['pinned_by_desktop'], true);
      expect(
        await desktop.frame('security.desktop_visibility', {'visible': true}),
        {'result': true},
      );
      final visible = await desktop.frame('meetings.start', {'id': 999});
      expect((visible['error'] as Map)['code'], 'notFound');
    },
  );

  peerTest(
    'a verified executable cannot bypass the frontend through worker.sock',
    () async {
      final bypass = await peer(executable, '${profile.runtime}/worker.sock');
      await expectLater(
        bypass.frame('security.attach_desktop', {
          'token': token(),
          'visible': true,
        }),
        throwsA(anything),
      );
      // The public frontend still accepts the same executable after the refusal.
      final desktop = await peer();
      expect(
        await desktop.frame('security.attach_desktop', {
          'token': token(),
          'visible': true,
        }),
        {'result': true},
      );
    },
  );

  peerTest(
    'packaged model requests cannot select executables outside the installation',
    () async {
      final desktop = await peer();
      await desktop.frame('security.attach_desktop', {
        'token': token(),
        'visible': true,
      });
      final result = await desktop.frame('models.generation', {
        'path': '/missing-model-fixture',
        'runtime': '/outside-installation',
        'backend': 'llama_cpp',
      });
      expect((result['error'] as Map)['code'], 'denied');
      expect((result['error'] as Map)['message'], contains('bundled runtime'));
    },
  );

  peerTest(
    'unbundled development accepts only its explicitly selected native peer',
    () async {
      await service.close();
      runtimeConfiguration.environment.remove('FORESIGHT_INSTALL_ROOT');
      runtimeConfiguration
              .environment['FORESIGHT_DEVELOPMENT_DESKTOP_EXECUTABLES'] =
          jsonEncode([executable]);
      service = await IsolatedApplicationService.start(profile);
      final desktop = await peer();
      expect(
        await desktop.frame('security.attach_desktop', {
          'token': token(),
          'visible': true,
        }),
        {'result': true},
      );
      final other = await peer(impostor);
      expect(
        (await other.frame('security.attach_desktop', {
          'token': token(),
          'visible': true,
        }))['error'],
        isNotNull,
      );
    },
  );

  peerTest(
    'a packaged revision without a root cannot enable the developer allowlist',
    () async {
      await service.close();
      runtimeConfiguration.environment.remove('FORESIGHT_INSTALL_ROOT');
      runtimeConfiguration.environment['FORESIGHT_RUNTIME_REVISION'] =
          'packaged-fixture';
      runtimeConfiguration
              .environment['FORESIGHT_DEVELOPMENT_DESKTOP_EXECUTABLES'] =
          jsonEncode([executable]);
      service = await IsolatedApplicationService.start(profile);
      final desktop = await peer();
      expect(
        (await desktop.frame('security.attach_desktop', {
          'token': token(),
          'visible': true,
        }))['error'],
        isNotNull,
      );
    },
  );

  peerTest(
    'interpreter probe ignores events and replies for another request',
    () async {
      final script = File('${directory.path}/correlated-probe.dart')
        ..writeAsStringSync(_interpreterProbe);
      final endpoint = '${directory.path}/probe.sock';
      final server = await ServerSocket.bind(
        InternetAddress(endpoint, type: InternetAddressType.unix),
        0,
      );
      addTearDown(server.close);
      final served = Completer<void>();
      final listener = server.listen((socket) async {
        try {
          final request =
              jsonDecode(
                    await socket
                        .cast<List<int>>()
                        .transform(utf8.decoder)
                        .transform(const LineSplitter())
                        .first
                        .timeout(const Duration(seconds: 5)),
                  )
                  as Map;
          expect(request['id'], 1);
          expect(request['method'], 'security.attach_desktop');
          for (final frame in [
            {'event': 'changed', 'workspace_epoch': 'fixture-epoch'},
            {'id': 999, 'result': true, 'done': true},
            {
              'id': 1,
              'error': {'code': 'denied', 'message': 'Verified peer required'},
              'done': true,
            },
          ]) {
            socket.writeln(jsonEncode(frame));
          }
          await socket.flush();
          served.complete();
        } catch (error, stack) {
          served.completeError(error, stack);
        } finally {
          socket.destroy();
        }
      });
      addTearDown(listener.cancel);
      final result = await Process.run(Platform.resolvedExecutable, [
        script.path,
        endpoint,
        'fixture-token',
      ]);
      await served.future;
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      final reply = jsonDecode(result.stdout.toString()) as Map;
      expect(reply['id'], 1, reason: result.stdout.toString());
      expect((reply['error'] as Map)['code'], 'denied');
    },
  );

  peerTest(
    'developer allowlists cannot substitute a generic interpreter or script',
    () async {
      await service.close();
      runtimeConfiguration.environment.remove('FORESIGHT_INSTALL_ROOT');
      final script = File('${directory.path}/script.dart')
        ..writeAsStringSync(_interpreterProbe);
      runtimeConfiguration
              .environment['FORESIGHT_DEVELOPMENT_DESKTOP_EXECUTABLES'] =
          jsonEncode([Platform.resolvedExecutable, script.path]);
      service = await IsolatedApplicationService.start(profile);
      final result = await Process.run(Platform.resolvedExecutable, [
        script.path,
        serviceEndpoint(profile),
        token(),
      ]);
      _expectInterpreterDenied(result);
      final kernel = '${directory.path}/script.dill';
      final compile = await Process.run(Platform.resolvedExecutable, [
        'compile',
        'kernel',
        script.path,
        '-o',
        kernel,
      ]);
      expect(
        compile.exitCode,
        0,
        reason: '${compile.stdout}\n${compile.stderr}',
      );
      final renamed = File(
        Platform.resolvedExecutable,
      ).copySync('${directory.path}/copied-interpreter');
      runtimeConfiguration
              .environment['FORESIGHT_DEVELOPMENT_DESKTOP_EXECUTABLES'] =
          jsonEncode([renamed.path]);
      final copied = await Process.run(renamed.path, [
        '--disable-dart-dev',
        kernel,
        serviceEndpoint(profile),
        token(),
      ]);
      _expectInterpreterDenied(copied);
    },
  );
}
