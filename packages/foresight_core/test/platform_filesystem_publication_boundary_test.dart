import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:foresight_core/src/platform_services.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';

class _CreatedDirectory extends IOOverrides {
  _CreatedDirectory(this.prefix, this.afterCreate);
  final String prefix;
  final void Function(Directory) afterCreate;
  String? admitted;

  @override
  Directory createDirectory(String path) {
    final directory = super.createDirectory(path);
    if (admitted == null && path.startsWith(prefix) && directory.existsSync()) {
      admitted = path;
      afterCreate(directory);
    }
    return directory;
  }
}

class _LostDirectory extends IOOverrides {
  _LostDirectory(this.path);
  final String path;

  @override
  Directory createDirectory(String value) => value == path
      ? _DisappearingDirectory(super.createDirectory(value))
      : super.createDirectory(value);
}

class _DisappearingDirectory implements Directory {
  _DisappearingDirectory(this.delegate);
  final Directory delegate;

  @override
  String get path => delegate.path;
  @override
  Directory get parent => delegate.parent;
  @override
  bool existsSync() => delegate.existsSync();
  @override
  FileStat statSync() {
    // Model a directory disappearing while creation restores restrictive umask
    // permissions. The OS chmod must fail rather than admit the lost endpoint.
    expect(Process.runSync('/bin/chmod', ['000', path]).exitCode, 0);
    final identity = delegate.statSync();
    delegate.deleteSync();
    return identity;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _LostExportStage extends IOOverrides {
  final removed = <String>[];

  @override
  File createFile(String path) {
    final file = super.createFile(path);
    return path.endsWith('/content') &&
            file.parent.path.contains('/.foresight-export-')
        ? _RemovedFile(file, removed)
        : file;
  }
}

class _RemovedFile implements File {
  _RemovedFile(this.delegate, this.removed);
  final File delegate;
  final List<String> removed;

  @override
  String get path => delegate.path;
  @override
  Future<File> create({bool recursive = false, bool exclusive = false}) async {
    await delegate.create(recursive: recursive, exclusive: exclusive);
    removed.add(path);
    await delegate.delete();
    return this;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late Directory root;
  setUp(() {
    root = createTestTempDirectorySync('platform-publication-');
  });

  test('private directory rejects NUL without adopting the truncated path', () {
    final target = Directory('${root.path}/not-created');
    expect(
      () => privateDirectory('${target.path}\u0000other'),
      throwsA(
        isA<StateError>().having((e) => e.message, 'reason', contains('NUL')),
      ),
    );
    expect(target.existsSync(), isFalse);
    expect(root.listSync(), isEmpty);
  });

  test('directory lost during permission restoration is never admitted', () {
    final path = '${root.path}/private';
    expect(
      () => IOOverrides.runWithIOOverrides(
        () => privateDirectory(path),
        _LostDirectory(path),
      ),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'reason',
          contains('Cannot protect'),
        ),
      ),
    );
    expect(Directory(path).existsSync(), isFalse);
    expect(root.listSync(), isEmpty);
  });

  test(
    'private temporary creation repairs changed permissions before admission',
    () async {
      final race = _CreatedDirectory('${root.path}/lease-', (directory) {
        expect(
          Process.runSync('/bin/chmod', ['755', directory.path]).exitCode,
          0,
        );
      });
      final result = await IOOverrides.runWithIOOverrides(
        () => createPrivateTempDirectory(root, 'lease-'),
        race,
      );
      expect(race.admitted, result.path);
      expect(result.statSync().mode & 0x1ff, 0x1c0);
      expect(result.listSync(), isEmpty);
      await result.delete();
      expect(root.listSync(), isEmpty);
    },
  );

  test(
    'an unexpected staging occupant refuses admission and removes the owned lease',
    () async {
      final race = _CreatedDirectory('${root.path}/lease-', (directory) {
        File(
          '${directory.path}/unexpected',
        ).writeAsStringSync('not an empty lease');
      });
      await expectLater(
        IOOverrides.runWithIOOverrides(
          () => createPrivateTempDirectory(root, 'lease-'),
          race,
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'reason',
            contains('must be empty'),
          ),
        ),
      );
      expect(race.admitted, isNotNull);
      expect(Directory(race.admitted!).existsSync(), isFalse);
      expect(root.listSync(), isEmpty);
    },
  );

  test(
    'failed export protection never writes private text or changes its destination',
    () async {
      final destination = File('${root.path}/selected.txt')
        ..writeAsStringSync('previous export');
      final previousMode = destination.statSync().mode;
      final race = _LostExportStage();
      await expectLater(
        IOOverrides.runWithIOOverrides(
          () => writePrivateTextFile(destination, 'must stay private'),
          race,
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'reason',
            'Cannot protect export file',
          ),
        ),
      );
      expect(race.removed, hasLength(1));
      expect(destination.readAsStringSync(), 'previous export');
      expect(destination.statSync().mode, previousMode);
      expect(root.listSync().map((entry) => entry.path), [destination.path]);
    },
  );

  test(
    'closing one same-process installation owner preserves the other lease',
    () {
      final saved = Map.of(runtimeConfiguration.environment);
      addTearDown(
        () => runtimeConfiguration.environment
          ..clear()
          ..addAll(saved),
      );
      final app = Directory('${root.path}/multiple-profiles')..createSync();
      runtimeConfiguration.environment['FORESIGHT_INSTALL_ROOT'] = app.path;
      final path = installationLockPath(app.path);
      addTearDown(() => File(path).parent.deleteSync(recursive: true));
      final first = acquireInstallationLock()!;
      final second = acquireInstallationLock()!;
      addTearDown(first.closeSync);
      addTearDown(second.closeSync);
      final code =
          'import fcntl,os,sys\nf=os.open(sys.argv[1],os.O_RDWR)\ntry: fcntl.flock(f,fcntl.LOCK_EX|fcntl.LOCK_NB)\nexcept BlockingIOError: sys.exit(3)\n';
      int probe() => Process.runSync(
        Platform.environment['FORESIGHT_PYTHON'] ?? 'python3',
        ['-c', code, path],
      ).exitCode;
      first.closeSync();
      expect(probe(), 3);
      final unrelated = File(path).openSync();
      unrelated.closeSync();
      expect(probe(), 3);
      second.closeSync();
      expect(probe(), 0);
    },
  );

  test(
    'installer exclusive lock refuses new clients then admits them after release',
    () async {
      final saved = Map.of(runtimeConfiguration.environment);
      addTearDown(
        () => runtimeConfiguration.environment
          ..clear()
          ..addAll(saved),
      );
      final application = Directory('${root.path}/installation')..createSync();
      runtimeConfiguration.environment['FORESIGHT_INSTALL_ROOT'] =
          application.path;
      final path = installationLockPath(application.path);
      final lockRoot = File(path).parent;
      privateDirectory(lockRoot.path);
      addTearDown(() => lockRoot.deleteSync(recursive: true));
      final process = await Process.start(
        Platform.environment['FORESIGHT_PYTHON'] ?? 'python3',
        [
          '-u',
          '-c',
          'import fcntl,os,sys\nf=os.fdopen(os.open(sys.argv[1],os.O_CREAT|os.O_RDWR,0o600),"a")\nfcntl.flock(f,fcntl.LOCK_EX)\nprint("locked",flush=True)\nsys.stdin.readline()\nf.close()\n',
          path,
        ],
      ).timeout(const Duration(seconds: 10));
      final errors = process.stderr.transform(utf8.decoder).join();
      final output = StreamIterator(
        process.stdout.transform(utf8.decoder).transform(const LineSplitter()),
      );
      var released = false;
      Future<void> release() async {
        if (released) return;
        released = true;
        process.stdin.writeln('release');
        await process.stdin.flush();
        await process.stdin.close();
        expect(
          await process.exitCode.timeout(const Duration(seconds: 10)),
          0,
          reason: await errors,
        );
        await output.cancel();
      }

      addTearDown(release);
      expect(
        await output.moveNext().timeout(const Duration(seconds: 10)),
        isTrue,
      );
      expect(output.current, 'locked');
      expect(
        acquireInstallationLock,
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'reason',
            contains('update is in progress'),
          ),
        ),
      );
      expect(File(path).statSync().mode & 0x1ff, 0x180);
      await release();
      final lock = acquireInstallationLock()!;
      try {
        expect(lock.lengthSync(), 0);
        expect(
          configuredInstallationRoot,
          application.resolveSymbolicLinksSync(),
        );
      } finally {
        lock.unlockSync();
        lock.closeSync();
      }
    },
  );
}
