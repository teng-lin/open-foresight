import 'package:foresight_test_support/poll.dart';
import 'dart:async';
import 'dart:io';

import 'package:foresight_core/src/dedicated_query_runtime.dart';
import 'package:foresight_core/src/encrypted_query_runtime.dart';
import 'package:foresight_core/src/model_vault.dart';
import 'package:test/test.dart';

class FixtureRuntime implements QueryCompletionRuntime {
  FixtureRuntime(this.model);
  final String model;
  final calls = <String>[];
  final cancellations = <String>[];
  Completer<String>? pending;
  final called = Completer<void>();
  final closing = Completer<void>();
  Completer<void>? closeGate;
  bool closed = false;
  bool failClose = false;
  @override
  Future<String> complete(String prompt, String requestId) {
    expect(File(model).existsSync(), isTrue);
    calls.add(requestId);
    if (!called.isCompleted) called.complete();
    return pending?.future ?? Future.value(' What is the deadline? ');
  }

  @override
  void cancel(String requestId) {
    cancellations.add(requestId);
    if (pending != null && !pending!.isCompleted) {
      pending!.completeError(StateError('Fixture request cancelled'));
    }
  }

  @override
  Future<void> close() async {
    if (closed) return;
    expect(File(model).existsSync(), isTrue);
    if (failClose) throw StateError('Fixture worker shutdown failed');
    if (!closing.isCompleted) closing.complete();
    await closeGate?.future;
    if (pending != null && !pending!.isCompleted) {
      pending!.completeError(StateError('Fixture runtime closed'));
    }
    closed = true;
  }
}

void main() {
  late Directory fixture;
  late Directory leases;
  late File encrypted;
  late File helper;
  late EncryptedDedicatedQueryRuntime runtime;
  late List<FixtureRuntime> workers;
  late int vaults;
  Future<void> helperBody(String body) async {
    await helper.writeAsString('#!/bin/sh\nset -eu\numask 077\n$body\n');
    expect((await Process.run('/bin/chmod', ['700', helper.path])).exitCode, 0);
  }

  Future<void> started() async {
    final marker = File('${encrypted.path}.started');
    await eventually(marker.existsSync);
    expect(marker.existsSync(), isTrue);
  }

  // The fixture helper copies bytes and never accesses Keychain. Swift crypto
  // correctness is validated separately; these tests check lifetime ownership.
  const copying = r'/bin/cat "$3" > "$5"';
  const blocking =
      r'printf partial > "$5"; printf started > "$3.started"; exec /bin/sleep 5';

  setUp(() async {
    fixture = await Directory.systemTemp.createTemp('encrypted-query-test-');
    leases = await Directory('${fixture.path}/leases').create();
    encrypted = await File(
      '${fixture.path}/encrypted',
    ).writeAsString('fixture model');
    helper = File('${fixture.path}/helper');
    await helperBody(copying);
    workers = [];
    vaults = 0;
    runtime = EncryptedDedicatedQueryRuntime(
      python: 'bundled-python',
      worker: 'bundled-worker',
      encryptedModel: encrypted.path,
      vaultRoot: Directory('${fixture.path}/vault'),
      vaultFactory: (root) {
        vaults++;
        return MacModelVault(
          root: root,
          helperPath: helper.path,
          tempRoot: leases,
        );
      },
      runtimeFactory: (python, worker, path) {
        expect(python, 'bundled-python');
        expect(worker, 'bundled-worker');
        final result = FixtureRuntime(path);
        workers.add(result);
        return result;
      },
    );
  });
  tearDown(() async {
    for (final worker in workers) {
      if (worker.closeGate != null && !worker.closeGate!.isCompleted)
        worker.closeGate!.complete();
    }
    await runtime.close();
    await fixture.delete(recursive: true);
  });

  test('one decrypted lease and worker are retained across requests', () async {
    expect(await runtime.complete('one', '1'), ' What is the deadline? ');
    final path = workers.single.model;
    expect(path, isNot(encrypted.path));
    expect(await File(path).readAsString(), 'fixture model');
    expect(await runtime.complete('two', '2'), ' What is the deadline? ');
    expect(vaults, 1);
    expect(workers.single.calls, ['1', '2']);
    await runtime.close();
    expect(File(path).existsSync(), isFalse);
    expect(encrypted.existsSync(), isTrue);
    await expectLater(runtime.complete('closed', '3'), throwsStateError);
  });

  test(
    'concurrent completion rejects and wrong-owner cancellation is ignored',
    () async {
      await runtime.complete('initialize', 'init');
      final worker = workers.single;
      worker.pending = Completer<String>();
      final pending = runtime.complete('active', 'owned');
      await eventually(() => worker.calls.contains('owned'));
      await expectLater(runtime.complete('other', 'other'), throwsStateError);
      runtime.cancel('other');
      expect(worker.cancellations, isEmpty);
      worker.pending!.complete('raw');
      expect(await pending, 'raw');
    },
  );

  test(
    'active cancellation delegates only owned ID and keeps the plaintext lease',
    () async {
      await runtime.complete('initialize', 'init');
      final worker = workers.single;
      worker.pending = Completer<String>();
      final pending = runtime.complete('active', 'owned');
      final failed = expectLater(pending, throwsStateError);
      await eventually(() => worker.calls.contains('owned'));
      runtime.cancel('owned');
      await failed;
      expect(worker.cancellations, ['owned']);
      expect(File(worker.model).existsSync(), isTrue);
      worker.pending = null;
      expect(
        await runtime.complete('again', 'next'),
        ' What is the deadline? ',
      );
      expect(vaults, 1);
    },
  );

  test(
    'startup cancellation kills only its decrypt helper and a later request retries',
    () async {
      await helperBody(blocking);
      final pending = runtime.complete('first', 'owned');
      final failed = expectLater(pending, throwsStateError);
      await started();
      runtime.cancel('other');
      expect(workers, isEmpty);
      expect(await leases.list().toList(), hasLength(1));
      runtime.cancel('owned');
      await failed.timeout(const Duration(seconds: 2));
      expect(await leases.list().toList(), isEmpty);
      expect(workers, isEmpty);
      await helperBody(copying);
      expect(
        await runtime.complete('retry', 'next'),
        ' What is the deadline? ',
      );
      expect(vaults, 2);
    },
  );

  test(
    'close reaps worker before plaintext removal and is idempotent',
    () async {
      await runtime.complete('initialize', 'init');
      final worker = workers.single;
      worker.pending = Completer<String>();
      final pending = runtime.complete('active', 'owned');
      final failed = expectLater(pending, throwsStateError);
      await eventually(() => worker.calls.contains('owned'));
      worker.closeGate = Completer<void>();
      final closing = runtime.close();
      await worker.closing.future;
      expect(File(worker.model).existsSync(), isTrue);
      worker.closeGate!.complete();
      await closing;
      await failed;
      expect(worker.closed, isTrue);
      expect(File(worker.model).existsSync(), isFalse);
      await runtime.close();
    },
  );

  test(
    'close during decryption prevents worker adoption and cleans its partial lease',
    () async {
      await helperBody(blocking);
      final pending = runtime.complete('first', 'owned');
      final failed = expectLater(pending, throwsStateError);
      await started();
      await runtime.close().timeout(const Duration(seconds: 2));
      await failed;
      expect(workers, isEmpty);
      expect(await leases.list().toList(), isEmpty);
    },
  );

  test(
    'runtime-construction failure removes its lease and permits clean startup retry',
    () async {
      await runtime.close();
      var fail = true;
      runtime = EncryptedDedicatedQueryRuntime(
        python: 'bundled-python',
        worker: 'bundled-worker',
        encryptedModel: encrypted.path,
        vaultRoot: Directory('${fixture.path}/vault'),
        vaultFactory: (root) => MacModelVault(
          root: root,
          helperPath: helper.path,
          tempRoot: leases,
        ),
        runtimeFactory: (_, _, path) {
          if (fail) throw StateError('Fixture runtime failed');
          final result = FixtureRuntime(path);
          workers.add(result);
          return result;
        },
      );
      await expectLater(runtime.complete('first', '1'), throwsStateError);
      expect(await leases.list().toList(), isEmpty);
      fail = false;
      expect(await runtime.complete('retry', '2'), ' What is the deadline? ');
      expect(File(workers.single.model).existsSync(), isTrue);
    },
  );

  test(
    'failed worker shutdown preserves plaintext and close can retry cleanup',
    () async {
      await runtime.complete('initialize', 'init');
      final worker = workers.single;
      worker.failClose = true;
      await expectLater(runtime.close(), throwsStateError);
      expect(File(worker.model).existsSync(), isTrue);
      await expectLater(runtime.complete('closed', '2'), throwsStateError);
      worker.failClose = false;
      await runtime.close();
      expect(File(worker.model).existsSync(), isFalse);
    },
  );
}
