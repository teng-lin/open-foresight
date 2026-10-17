import 'dart:async';
import 'dart:io';

import 'package:foresight_core/src/model_vault.dart';
import 'package:test/test.dart';

void main() {
  late Directory fixture;
  late Directory models;
  late Directory leases;
  late File input;

  Future<File> helper(String body) async {
    final file = File('${fixture.path}/helper');
    await file.writeAsString('#!/bin/sh\nset -eu\numask 077\n$body\n');
    expect((await Process.run('/bin/chmod', ['700', file.path])).exitCode, 0);
    return file;
  }

  Future<MacModelVault> vault(String body, {Duration? timeout}) async =>
      MacModelVault(
        root: models,
        tempRoot: leases,
        helperPath: (await helper(body)).path,
        helperTimeout: timeout ?? const Duration(seconds: 5),
      );

  setUp(() async {
    fixture = await Directory.systemTemp.createTemp('model-vault-test-');
    models = Directory('${fixture.path}/models');
    leases = await Directory('${fixture.path}/leases').create();
    input = await File(
      '${fixture.path}/source',
    ).writeAsString('fixture model bytes');
  });
  tearDown(() async {
    await fixture.delete(recursive: true);
  });

  // This helper copies bytes; these tests exercise vault ownership and process
  // handling, not the separate Swift helper's cryptographic implementation.
  const copyingHelper = r'''
test "$2" = --input
test "$4" = --output
test ! -e "$5"
set -C
/bin/cat "$3" > "$5"
''';

  test(
    'persist uses unique versioned private candidates without replacing an old file',
    () async {
      final store = await vault(copyingHelper);
      final first = await store.persist(input, version: '1.0.0');
      final second = await store.persist(input, version: '1.0.0');
      expect(first.path, isNot(second.path));
      expect(first.parent.path, contains('model-1.0.0-'));
      expect(await first.readAsString(), 'fixture model bytes');
      expect(first.statSync().mode & 0x1ff, 0x180);
      expect(first.parent.statSync().mode & 0x1ff, 0x1c0);
      expect(await second.readAsString(), 'fixture model bytes');
      expect(await input.readAsString(), 'fixture model bytes');
    },
  );

  test(
    'concurrent leases are private and close removes only its own directory',
    () async {
      final store = await vault(copyingHelper);
      final encrypted = await store.persist(input, version: '4');
      final foreign = await File(
        '${leases.path}/keep',
      ).writeAsString('unrelated');
      final first = await store.openLease(encrypted);
      final second = await store.openLease(encrypted);
      expect(first.path, isNot(second.path));
      expect(File(first.path).parent.statSync().mode & 0x1ff, 0x1c0);
      expect(File(first.path).statSync().mode & 0x1ff, 0x180);
      expect(await File(first.path).readAsString(), 'fixture model bytes');
      await Future.wait([first.close(), first.close()]);
      expect(File(first.path).existsSync(), isFalse);
      expect(File(second.path).existsSync(), isTrue);
      expect(encrypted.existsSync(), isTrue);
      expect(await foreign.readAsString(), 'unrelated');
      await second.close();
      expect(await leases.list().toList(), [isA<File>()]);
    },
  );

  test(
    'helper failures remove partial candidates and leases, preserving inputs',
    () async {
      final store = await vault(
        r'printf partial > "$5"; echo private-error >&2; exit 7',
      );
      await expectLater(
        store.persist(input, version: '4'),
        throwsA(
          predicate(
            (e) =>
                e.toString().contains('exit 7') &&
                !e.toString().contains('private-error'),
          ),
        ),
      );
      expect(await models.list().toList(), isEmpty);
      await expectLater(store.openLease(input), throwsStateError);
      expect(await leases.list().toList(), isEmpty);
      expect(await input.readAsString(), 'fixture model bytes');
    },
  );

  test(
    'symlink inputs, symlink outputs, and symlink vault roots are rejected',
    () async {
      final store = await vault(copyingHelper);
      final link = await Link('${fixture.path}/source-link').create(input.path);
      await expectLater(
        store.persist(File(link.path), version: '4'),
        throwsStateError,
      );
      expect(models.existsSync(), isFalse);
      final linking = await vault(r'/bin/ln -s "$3" "$5"');
      await expectLater(linking.persist(input, version: '4'), throwsStateError);
      expect(await models.list().toList(), isEmpty);
      expect(await input.readAsString(), 'fixture model bytes');
      await models.delete();
      final foreign = await Directory('${fixture.path}/foreign').create();
      final sentinel = await File(
        '${foreign.path}/keep',
      ).writeAsString('preserved');
      await Link(models.path).create(foreign.path);
      await expectLater(store.persist(input, version: '4'), throwsStateError);
      expect(await sentinel.readAsString(), 'preserved');
    },
  );

  test(
    'nonprivate output and cancellation leave no newly owned candidates',
    () async {
      final publicOutput = await vault(
        r'/bin/cat "$3" > "$5"; /bin/chmod 644 "$5"',
      );
      await expectLater(
        publicOutput.persist(input, version: '4'),
        throwsStateError,
      );
      expect(await models.list().toList(), isEmpty);
      final store = await vault(copyingHelper);
      var checks = 0;
      await expectLater(
        store.persist(input, version: '4', current: () => checks++ == 0),
        throwsStateError,
      );
      expect(await models.list().toList(), isEmpty);
    },
  );

  test(
    'timed-out owned helper is stopped before partial directory cleanup',
    () async {
      final store = await vault(
        r'printf partial > "$5"; exec /bin/sleep 5',
        timeout: const Duration(milliseconds: 50),
      );
      await expectLater(
        store.persist(input, version: '4'),
        throwsA(predicate((e) => e.toString().contains('timed out'))),
      );
      expect(await models.list().toList(), isEmpty);
    },
  );

  test(
    'invalid versions and missing helper do not create vault files',
    () async {
      final store = await vault(copyingHelper);
      await expectLater(
        store.persist(input, version: '../outside'),
        throwsArgumentError,
      );
      expect(models.existsSync(), isFalse);
      final missing = MacModelVault(
        root: models,
        helperPath: '${fixture.path}/missing',
      );
      await expectLater(missing.persist(input, version: '4'), throwsStateError);
      expect(models.existsSync(), isFalse);
    },
  );

  test(
    'close reaps an active helper and its partial candidate before returning',
    () async {
      final store = await vault(
        r'printf partial > "$5"; printf started > "$3.started"; exec /bin/sleep 5',
      );
      final pending = store.persist(input, version: '4');
      final failed = expectLater(pending, throwsStateError);
      final marker = File('${input.path}.started');
      for (var attempt = 0; !marker.existsSync() && attempt < 200; attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(marker.existsSync(), isTrue);
      await Future.wait([
        store.close(),
        store.close(),
      ]).timeout(const Duration(seconds: 2));
      await failed;
      expect(await models.list().toList(), isEmpty);
      await expectLater(store.persist(input, version: '4'), throwsStateError);
      await expectLater(store.openLease(input), throwsStateError);
      expect(await input.readAsString(), 'fixture model bytes');
    },
  );

  test(
    'close waits for a pending start and never kills an unrelated process',
    () async {
      final executable = await helper(r'exec /bin/sleep 5');
      final started = Completer<Process>();
      final release = Completer<Process>();
      final store = MacModelVault(
        root: models,
        tempRoot: leases,
        helperPath: executable.path,
        startProcess: (path, args) async {
          final process = await Process.start(path, args);
          started.complete(process);
          return release.future;
        },
      );
      final unrelated = await Process.start('/bin/sleep', ['5']);
      var unrelatedExited = false;
      unawaited(
        unrelated.exitCode.then((_) {
          unrelatedExited = true;
        }),
      );
      try {
        final pending = store.persist(input, version: '4');
        final failed = expectLater(pending, throwsStateError);
        final owned = await started.future;
        var closed = false;
        final closing = store.close().then((_) {
          closed = true;
        });
        await Future<void>.delayed(const Duration(milliseconds: 10));
        expect(closed, isFalse);
        release.complete(owned);
        await closing.timeout(const Duration(seconds: 2));
        await failed;
        await owned.exitCode;
        expect(unrelatedExited, isFalse);
        expect(await models.list().toList(), isEmpty);
      } finally {
        unrelated.kill(ProcessSignal.sigkill);
        await unrelated.exitCode;
      }
    },
  );

  test(
    'closing a vault does not invalidate an already owned plaintext lease',
    () async {
      final store = await vault(copyingHelper);
      final lease = await store.openLease(input);
      await store.close();
      expect(await File(lease.path).readAsString(), 'fixture model bytes');
      await lease.close();
      expect(File(lease.path).existsSync(), isFalse);
    },
  );
}
