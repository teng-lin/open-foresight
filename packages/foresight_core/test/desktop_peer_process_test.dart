import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:foresight_core/foresight_core.dart';
import 'package:foresight_core/src/service.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';

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
  late Directory installation;
  late String executable, impostor;
  late Directory directory;
  late ProfilePaths profile;
  late IsolatedApplicationService service;
  late Map<String, String> environment;

  setUpAll(() async {
    installation = createTestTempDirectorySync('desktop-executable-');
    final parent = Directory(
      Platform.isMacOS
          ? '${installation.path}/Contents/MacOS'
          : '${installation.path}/app',
    )..createSync(recursive: true);
    executable = '${parent.path}/open_foresight';
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
    directory = createTestTempDirectorySync('desktop-process-');
    profile = ProfilePaths('${directory.path}/d', '${directory.path}/r');
    environment = Map.of(runtimeConfiguration.environment);
    runtimeConfiguration.environment.removeWhere(
      (key, _) =>
          key.startsWith('FORESIGHT_') && key != 'FORESIGHT_SQLITE_LIBRARY',
    );
    runtimeConfiguration.environment.addAll({
      'FORESIGHT_HELPER': '',
      'FORESIGHT_INSTALL_ROOT': installation.path,
    });
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

  test(
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

  test(
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

  test(
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

  test(
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
      });
      expect((result['error'] as Map)['code'], 'denied');
      expect((result['error'] as Map)['message'], contains('bundled runtime'));
    },
  );

  test(
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

  test(
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

  test(
    'developer allowlists cannot substitute a generic interpreter or script',
    () async {
      await service.close();
      runtimeConfiguration.environment.remove('FORESIGHT_INSTALL_ROOT');
      final script = File('${directory.path}/script.dart')
        ..writeAsStringSync(r'''
import 'dart:io';
import 'dart:convert';
Future<void> main(List<String> args) async {
  final peer = await Socket.connect(InternetAddress(args[0], type: InternetAddressType.unix), 0);
  peer.writeln(jsonEncode({'id':1,'method':'security.attach_desktop','args':{'token':args[1],'visible':true}}));
  final reply = await peer.cast<List<int>>().transform(utf8.decoder).transform(const LineSplitter()).first;
  print(reply);
  peer.destroy();
}
''');
      runtimeConfiguration
              .environment['FORESIGHT_DEVELOPMENT_DESKTOP_EXECUTABLES'] =
          jsonEncode([Platform.resolvedExecutable, script.path]);
      service = await IsolatedApplicationService.start(profile);
      final result = await Process.run(Platform.resolvedExecutable, [
        script.path,
        serviceEndpoint(profile),
        token(),
      ]);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      expect((jsonDecode(result.stdout.toString()) as Map)['error'], isNotNull);
    },
  );
}
