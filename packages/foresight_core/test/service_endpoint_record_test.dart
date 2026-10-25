import 'package:foresight_test_support/hooked_service.dart'
    show sourceServiceCompileDefines;
import 'sql_support_test_bootstrap.dart';
import 'package:foresight_test_support/desktop_identity.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:foresight_core/src/platform_services.dart';
import 'package:foresight_core/src/profile_paths.dart';
import 'package:foresight_core/src/service.dart';
import 'package:foresight_test_support/poll.dart';
import 'package:foresight_test_support/service_fault_proxy.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';

import 'service_shutdown_handoff_test.dart'
    show
        expireDeadlineDuring,
        ladderTimeout,
        localOwnerDeadlines,
        startupFailure;

// A separate owner holds the real profile lock and serves status on its own
// runtime. It never reads or replaces the endpoint record, so a client reaches
// it only by treating an invalid record as absent.
const ownerSource = r'''#!/usr/bin/env python3
import fcntl, json, os, socket, sys
data = os.environ['FORESIGHT_DATA']
runtime = os.environ['FORESIGHT_RUNTIME']
sys.stderr = open(os.path.join(data, 'owner.log'), 'a')
with open(os.path.join(data, 'launches'), 'a') as launches:
    launches.write('launch\n')
lock = open(os.path.join(data, '.application.lock'), 'a')
fcntl.lockf(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
with open(os.path.join(data, 'owner.pid'), 'w') as marker:
    marker.write(str(os.getpid()))
path = os.path.join(runtime, 'application.sock')
if os.path.lexists(path):
    os.unlink(path)
server = socket.socket(socket.AF_UNIX)
server.bind(path)
server.listen()
stopped = False
while not stopped:
    peer, _ = server.accept()
    with peer, peer.makefile('rb') as requests:
        for line in requests:
            request = json.loads(line)
            reply = {'id': request['id'], 'result': {'pid': os.getpid(), 'application_api_version': 1}, 'done': True}
            peer.sendall((json.dumps(reply) + '\n').encode())
            if request['method'] == 'fixture.stop':
                stopped = True
                break
server.close()
os.unlink(path)
lock.close()
with open(os.path.join(data, 'owner.closed'), 'w') as marker:
    marker.write(str(os.getpid()))
''';

// Hold the profile lock from another process, as a live owner does.
const lockHolderSource = '''
import fcntl, sys
lock = open(sys.argv[1], 'a')
fcntl.lockf(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
print('locked', flush=True)
sys.stdin.read()
''';

// Fail only the rename that publishes the temporary record.
class RenameFailureOverrides extends IOOverrides {
  final String path;
  RenameFailureOverrides(this.path);

  @override
  File createFile(String path) => path == this.path
      ? RenameFailingFile(super.createFile(path))
      : super.createFile(path);
}

class RenameFailingFile implements File {
  final File delegate;
  RenameFailingFile(this.delegate);
  @override
  String get path => delegate.path;
  @override
  void writeAsStringSync(
    String contents, {
    FileMode mode = FileMode.write,
    Encoding encoding = utf8,
    bool flush = false,
  }) => delegate.writeAsStringSync(
    contents,
    mode: mode,
    encoding: encoding,
    flush: flush,
  );
  @override
  File renameSync(String newPath) =>
      throw FileSystemException('Injected rename failure', path);
  @override
  void deleteSync({bool recursive = false}) =>
      delegate.deleteSync(recursive: recursive);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  bootstrapSqlSupportFixture();
  late Map<String, String> environment;
  late Directory root;
  late ProfilePaths profile;
  File record() => File('${profile.data}/.application-endpoint.json');
  List<String> entries(String suffix) =>
      Directory(profile.data)
          .listSync(followLinks: false)
          .map((entry) => entry.path.substring(entry.path.lastIndexOf('/') + 1))
          .where(
            (name) =>
                name.startsWith('.application-endpoint.json.$suffix') &&
                RegExp(r'\d$').hasMatch(name),
          )
          .toList()
        ..sort();
  List<String> quarantined() => entries('invalid-');

  setUp(() async {
    environment = Map.of(runtimeConfiguration.environment);
    for (final key in [
      'FORESIGHT_HELPER',
      'FORESIGHT_NATIVE',
      'FORESIGHT_RUNTIME_REVISION',
      'FORESIGHT_INSTALL_ROOT',
      'FORESIGHT_MODEL_MANIFEST',
    ]) {
      runtimeConfiguration.environment.remove(key);
    }
    root = await createPrivateTempDirectory(shortTestTempRoot, 'of-record-');
    profile = ProfilePaths('${root.path}/data', '${root.path}/run');
    privateDirectory(profile.data);
    privateDirectory(profile.runtime);
    final launcher = File('${root.path}/launch')
      ..writeAsStringSync(ownerSource);
    expect(Process.runSync('/bin/chmod', ['700', launcher.path]).exitCode, 0);
    runtimeConfiguration.environment['FORESIGHT_SERVICE'] = launcher.path;
  });
  tearDown(() async {
    runtimeConfiguration.environment
      ..clear()
      ..addAll(environment);
    // Never leave a fixture owner holding a lock in a deleted profile.
    final owner = File('${profile.data}/owner.pid');
    if (owner.existsSync() &&
        !File('${profile.data}/owner.closed').existsSync()) {
      Process.killPid(int.parse(owner.readAsStringSync()));
    }
    for (final entry in root.listSync(recursive: true, followLinks: false)) {
      if (entry is Directory) {
        Process.runSync('/bin/chmod', ['700', entry.path]);
      }
    }
    root.deleteSync(recursive: true);
  });

  final privileged =
      Process.runSync('/usr/bin/id', ['-u']).stdout.toString().trim() == '0';
  final invalidRecords = <String, void Function()>{
    'empty': () => record().writeAsStringSync(''),
    'truncated JSON': () =>
        record().writeAsStringSync('{"data":"${profile.data}","run'),
    'a JSON array': () => record().writeAsStringSync('[]'),
    'JSON null': () => record().writeAsStringSync('null'),
    'mistyped': () => record().writeAsStringSync(
      jsonEncode({'data': profile.data, 'runtime': 42}),
    ),
    'a directory': () {
      Directory(record().path).createSync();
      File('${record().path}/child').writeAsStringSync('kept for diagnosis');
    },
    // The superuser can read a mode 000 file, so the record would be valid.
    if (!privileged)
      'unreadable': () {
        record().writeAsStringSync(
          jsonEncode({'data': profile.data, 'runtime': profile.runtime}),
        );
        expect(
          Process.runSync('/bin/chmod', ['000', record().path]).exitCode,
          0,
        );
      },
    'for a moved profile': () => record().writeAsStringSync(
      jsonEncode({
        'data': '/old/home/open-foresight',
        'runtime': profile.runtime,
      }),
    ),
    'naming an uncreatable runtime': () {
      // A regular file as the parent: nobody, not even root (as in the CI
      // containers), can create a directory under it.
      final gone = File('${root.path}/gone')..writeAsStringSync('');
      record().writeAsStringSync(
        jsonEncode({'data': profile.data, 'runtime': '${gone.path}/run'}),
      );
    },
    'naming a non-private runtime': () {
      final public = Directory('${root.path}/public')..createSync();
      expect(Process.runSync('/bin/chmod', ['755', public.path]).exitCode, 0);
      record().writeAsStringSync(
        jsonEncode({'data': profile.data, 'runtime': public.path}),
      );
    },
    'a symbolic link': () {
      final other = '${root.path}/other';
      privateDirectory(other);
      File(
        '${root.path}/target.json',
      ).writeAsStringSync(jsonEncode({'data': profile.data, 'runtime': other}));
      Link(record().path).createSync('${root.path}/target.json');
    },
  };

  for (final entry in invalidRecords.entries) {
    test(
      'an endpoint record that is ${entry.key} lets clients attach and a new owner start',
      () async {
        entry.value();
        // Clients treat the record as absent and use their own runtime.
        final client = await ensureService(
          profile,
          startupTimeout: const Duration(seconds: 30),
        );
        try {
          expect(
            (await client.call('status') as Map)['pid'],
            int.parse(File('${profile.data}/owner.pid').readAsStringSync()),
          );
          expect(File('${profile.data}/launches').readAsLinesSync(), [
            'launch',
          ]);
          expect(
            serviceEndpoint(profile),
            '${profile.runtime}/application.sock',
          );
          // Only an owner holding the profile lock moves the record aside.
          expect(quarantined(), isEmpty);
          await client.call('fixture.stop');
        } finally {
          await client.close();
        }
        await eventually(
          File('${profile.data}/owner.closed').existsSync,
          timeout: const Duration(seconds: 10),
        );
        final service = await ApplicationService.start(
          profile,
          desktopPeerVerifier: trustInProcessDesktop,
        );
        try {
          expect(service.path, '${profile.runtime}/application.sock');
          expect(jsonDecode(record().readAsStringSync()), {
            'data': profile.data,
            'runtime': profile.runtime,
          });
          expect(serviceEndpoint(profile), service.path);
          final moved = quarantined();
          expect(moved, hasLength(1));
          final kept = '${profile.data}/${moved.single}';
          if (entry.key == 'a directory') {
            expect(
              File('$kept/child').readAsStringSync(),
              'kept for diagnosis',
            );
          }
          if (entry.key == 'a symbolic link') {
            expect(FileSystemEntity.isLinkSync(kept), isTrue);
            expect(
              jsonDecode(File('${root.path}/target.json').readAsStringSync()),
              {'data': profile.data, 'runtime': '${root.path}/other'},
            );
          }
        } finally {
          await service.close();
        }
      },
    );
  }

  test('a recorded runtime containing NUL is ignored and never created', () {
    record().writeAsStringSync(
      jsonEncode({
        'data': profile.data,
        'runtime': '${root.path}/truncated\u0000rest',
      }),
    );
    expect(
      readEndpointRecord(profile),
      isA<EndpointInvalid>().having(
        (record) => record.reason,
        'reason',
        contains('NUL'),
      ),
    );
    expect(serviceEndpoint(profile), '${profile.runtime}/application.sock');
    expect(Directory('${root.path}/truncated').existsSync(), isFalse);
  });

  test(
    'the service command line names an ignored record',
    () async {
      record().writeAsStringSync('[]');
      final result = await Process.run(
        Platform.resolvedExecutable,
        [
          ...await sourceServiceCompileDefines(),
          'bin/service.dart',
          '--status',
        ],
        environment: {
          'HOME': root.path,
          'FORESIGHT_DATA': profile.data,
          'FORESIGHT_RUNTIME': profile.runtime,
        },
      );
      // No owner serves this profile, so the status request itself fails.
      expect(result.exitCode, 1, reason: '${result.stderr}');
      expect(
        result.stderr,
        contains(
          '.application-endpoint.json was ignored because it is not an '
          'object with string data and runtime fields.',
        ),
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'a client names the ignored record when another owner holds the lock',
    () async {
      record().writeAsStringSync('{"data":');
      final holder = await Process.start('python3', [
        '-c',
        lockHolderSource,
        '${profile.data}/.application.lock',
      ]);
      final lines = StreamIterator(
        holder.stdout.transform(utf8.decoder).transform(const LineSplitter()),
      );
      try {
        expect(
          await lines.moveNext().timeout(const Duration(seconds: 10)),
          isTrue,
        );
        expect(lines.current, 'locked');
        await expireDeadlineDuring('a lock probe that found the lock held', (
          deadline,
        ) async {
          final proxy = ServiceFaultProxy();
          try {
            final failure = await startupFailure(
              proxy.run(() => ensureService(profile, startupTimeout: deadline)),
            );
            // The deadline names a held lock whenever nothing launched, even
            // before any lock probe. A second connect follows only a probe
            // that found the lock held; a free lock would have launched.
            if (proxy.attempts.length < 2) return false;
            expect(
              failure,
              isA<TimeoutException>().having(
                (error) => error.message,
                'message',
                allOf(
                  startsWith(
                    'Application service profile lock is still held; its '
                    'owner is not serving the endpoint. The endpoint record '
                    '${record().path} was ignored because it is not valid '
                    'JSON (',
                  ),
                  endsWith(').'),
                ),
              ),
            );
            return true;
          } finally {
            await proxy.close();
          }
        }, deadlines: localOwnerDeadlines);
        expect(File('${profile.data}/launches').existsSync(), isFalse);
        expect(record().readAsStringSync(), '{"data":');
      } finally {
        await holder.stdin.close();
        await holder.exitCode;
        await lines.cancel();
      }
    },
    timeout: ladderTimeout(localOwnerDeadlines),
  );

  test(
    'an owner keeps only the three newest invalid records, never link targets',
    () async {
      final target = File('${root.path}/target')..writeAsStringSync('keep');
      final base = record().path;
      Directory('$base.invalid-1').createSync();
      File('$base.invalid-1/child').writeAsStringSync('old');
      Link('$base.invalid-2').createSync(target.path);
      File('$base.invalid-3').writeAsStringSync('');
      File('$base.invalid-4').writeAsStringSync('');
      record().writeAsStringSync('null');
      final service = await ApplicationService.start(
        profile,
        desktopPeerVerifier: trustInProcessDesktop,
      );
      try {
        final older = {
          '.application-endpoint.json.invalid-3',
          '.application-endpoint.json.invalid-4',
        };
        final moved = quarantined();
        expect(moved, hasLength(3));
        expect(moved, containsAll(older));
        final newest = moved.where((name) => !older.contains(name)).single;
        expect(File('${profile.data}/$newest').readAsStringSync(), 'null');
        expect(target.readAsStringSync(), 'keep');
      } finally {
        await service.close();
      }
    },
  );

  test('an owner sweeps temporary records left by earlier owners', () async {
    final base = record().path;
    File('$base.1').writeAsStringSync('{');
    File('$base.4194305').writeAsStringSync('');
    Directory('$base.12').createSync();
    File('$base.invalid-7').writeAsStringSync('');
    final service = await ApplicationService.start(
      profile,
      desktopPeerVerifier: trustInProcessDesktop,
    );
    try {
      expect(entries(''), ['.application-endpoint.json.invalid-7']);
      expect(jsonDecode(record().readAsStringSync()), {
        'data': profile.data,
        'runtime': profile.runtime,
      });
    } finally {
      await service.close();
    }
  });

  test('a leftover the owner cannot delete does not block startup', () async {
    final leftover = Directory('${record().path}.5');
    final locked = Directory('${leftover.path}/locked')
      ..createSync(recursive: true);
    File('${locked.path}/child').writeAsStringSync('');
    expect(Process.runSync('/bin/chmod', ['500', locked.path]).exitCode, 0);
    final service = await ApplicationService.start(
      profile,
      desktopPeerVerifier: trustInProcessDesktop,
    );
    try {
      expect(jsonDecode(record().readAsStringSync()), {
        'data': profile.data,
        'runtime': profile.runtime,
      });
      // The superuser can delete it anyway.
      if (!privileged) expect(leftover.existsSync(), isTrue);
    } finally {
      await service.close();
    }
  });

  test(
    'a failed start removes its temporary record before releasing ownership',
    () async {
      final temporary = '${record().path}.$pid';
      await expectLater(
        IOOverrides.runWithIOOverrides(
          () => ApplicationService.start(
            profile,
            desktopPeerVerifier: trustInProcessDesktop,
          ),
          RenameFailureOverrides(temporary),
        ),
        throwsA(
          isA<FileSystemException>().having(
            (error) => error.message,
            'message',
            'Injected rename failure',
          ),
        ),
      );
      expect(File(temporary).existsSync(), isFalse);
      expect(record().existsSync(), isFalse);
      final service = await ApplicationService.start(
        profile,
        desktopPeerVerifier: trustInProcessDesktop,
      );
      await service.close();
    },
  );

  test(
    'a failed start after setting an invalid record aside leaves no record',
    () async {
      record().writeAsStringSync('[]');
      // The desktop capability check fails after the record is published.
      final capability = Link('${profile.data}/.desktop-capability')
        ..createSync('${root.path}/elsewhere');
      await expectLater(
        ApplicationService.start(
          profile,
          desktopPeerVerifier: trustInProcessDesktop,
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('Desktop capability must not be a symbolic link'),
          ),
        ),
      );
      // The invalid record was never adopted, so this attempt removed its own.
      expect(
        FileSystemEntity.typeSync(record().path, followLinks: false),
        FileSystemEntityType.notFound,
      );
      expect(quarantined(), hasLength(1));
      capability.deleteSync();
      final service = await ApplicationService.start(
        profile,
        desktopPeerVerifier: trustInProcessDesktop,
      );
      await service.close();
    },
  );
}
