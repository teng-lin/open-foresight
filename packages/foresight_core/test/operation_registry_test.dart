import 'sql_support_test_bootstrap.dart';
import 'package:foresight_test_support/desktop_identity.dart';
import 'package:foresight_core/src/mcp/rpc_tools.dart';
import 'package:foresight_core/src/service.dart';
import 'package:foresight_core/src/platform_services.dart';
import 'package:foresight_core/src/profile_paths.dart';
import 'package:foresight_core/src/operation_descriptor.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'dart:convert';
import 'dart:io';
import 'package:foresight_core/src/operations.dart';
import 'package:foresight_core/src/rpc_error.dart';
import 'package:test/test.dart';

Iterable<RegExpMatch> rawRpcCalls(
  String source, {
  bool desktop = false,
}) => RegExp(
  desktop
      ? r"""\.command(?:Current)?\(\s*['"]([^'"]+)['"]"""
      : r"""\.(?:call|stream|command|commandCurrent)\(\s*['"]([^'"]+)['"]""",
).allMatches(source);

void main() {
  bootstrapSqlSupportFixture();
  test('wire names and MCP tool names are unique and round-trip', () {
    expect(
      Operation.values.map((operation) => operation.wire).toSet(),
      hasLength(Operation.values.length),
    );
    expect(
      rpcTools.map((tool) => tool.name).toSet(),
      hasLength(rpcTools.length),
    );
    for (final operation in Operation.values) {
      expect(Operation.parse(operation.wire), operation);
    }
    expect(
      () => Operation.parse('typo.operation'),
      throwsA(
        isA<RpcError>().having(
          (error) => error.code,
          'code',
          RpcErrorCode.notFound,
        ),
      ),
    );
  });

  test('ID tools take the workspace epoch and keyed tools explain retries', () {
    for (final tool in rpcTools) {
      final keyed = tool.operation.acceptsIdempotencyKey;
      expect(
        tool.properties.containsKey('workspace_epoch'),
        tool.properties.containsKey('id') || keyed,
        reason: tool.name,
      );
      expect(
        tool.properties.containsKey('idempotency_key'),
        keyed,
        reason: tool.name,
      );
      expect(
        tool.description.contains(
          'If a call fails with reason outcomeUnknown, retry with the same idempotency_key.',
        ),
        keyed,
        reason: tool.name,
      );
      expect(tool.required, isNot(contains('workspace_epoch')));
      expect(tool.required, isNot(contains('idempotency_key')));
    }
    expect(
      rpcTools
          .where((tool) => tool.operation.acceptsIdempotencyKey)
          .map((tool) => tool.operation)
          .toSet(),
      Operation.values.where((value) => value.acceptsIdempotencyKey).toSet(),
    );
  });

  test(
    'remote facades and service reference registry operation identities',
    () {
      for (final name in [
        'remote_domain.dart',
        ...Directory('lib/src')
            .listSync()
            .whereType<File>()
            .where(
              (file) =>
                  file.path.split('/').last.startsWith('service') &&
                  file.path.endsWith('.dart'),
            )
            .map((file) => file.path.split('/').last),
        'application_service.dart',
        ...Directory('lib/src/application_services')
            .listSync(recursive: true)
            .whereType<File>()
            .where((file) => file.path.endsWith('.dart'))
            .map((file) => file.path.substring('lib/src/'.length)),
        'application.dart',
      ]) {
        final source = File('lib/src/$name').readAsStringSync();
        expect(
          rawRpcCalls(source),
          isEmpty,
          reason: '$name contains an unregistered RPC literal',
        );
        for (final operation in Operation.values.where(
          (value) => value.wire.contains('.'),
        )) {
          expect(
            [
              "'",
              '"',
            ].any((quote) => source.contains('$quote${operation.wire}$quote')),
            isFalse,
            reason: '$name duplicates ${operation.wire} outside the registry',
          );
        }
      }
    },
  );

  test('desktop and repository service probes use typed operation names', () {
    for (final path in ['../../apps/desktop/lib', '../../tests/service']) {
      final files = Directory(path)
          .listSync(recursive: true)
          .whereType<File>()
          .where((file) => file.path.endsWith('.dart'))
          .toList();
      expect(files, isNotEmpty, reason: path);
      for (final file in files) {
        expect(
          rawRpcCalls(file.readAsStringSync(), desktop: true),
          isEmpty,
          reason: '${file.path} contains a raw desktop RPC name',
        );
      }
    }
  });

  test('CLI and MCP use the registered application wire identities', () {
    for (final path in ['bin/service.dart', 'bin/mcp.dart']) {
      expect(rawRpcCalls(File(path).readAsStringSync()), isEmpty, reason: path);
    }
  });

  test('raw RPC guard rejects known, stale and unknown operation fixtures', () {
    for (final source in [
      "desktop.command('notes.save', {});",
      'desktop.command("notes.save.v0", {});',
      "desktop.commandCurrent(\n  'unknown.operation', {}, current);",
    ]) {
      expect(rawRpcCalls(source, desktop: true), hasLength(1), reason: source);
    }
    expect(
      rawRpcCalls('desktop.command(Operation.notesSave, {});', desktop: true),
      isEmpty,
    );
  });

  test(
    'desktop command API rejects stale and unknown wire strings at compile time',
    () async {
      final directory = createTestTempDirectorySync('invalid-desktop-command-');
      // Give the out-of-tree compile fixture the same package resolution as
      // this package, while keeping every disposable file under the test root.
      final config = File('.dart_tool/package_config.json').absolute;
      final packages =
          jsonDecode(config.readAsStringSync()) as Map<String, dynamic>;
      for (final package in packages['packages'] as List) {
        package['rootUri'] = config.uri
            .resolve(package['rootUri'] as String)
            .toString();
      }
      Directory('${directory.path}/.dart_tool').createSync();
      File(
        '${directory.path}/.dart_tool/package_config.json',
      ).writeAsStringSync(jsonEncode(packages));
      final fixture = File('${directory.path}/invalid_commands.dart')
        ..writeAsStringSync(r'''import 'package:foresight_core/remote.dart';
void invalidCommands(DesktopConnection desktop) {
  desktop.command('notes.save.v0');
  desktop.commandCurrent('unknown.operation', {}, () => true);
}
''');
      final process = await Process.start(Platform.resolvedExecutable, [
        'analyze',
        '--format=machine',
        fixture.path,
      ]);
      var running = true;
      final exited = process.exitCode.whenComplete(() => running = false);
      final stdout = process.stdout.transform(utf8.decoder).join();
      final stderr = process.stderr.transform(utf8.decoder).join();
      addTearDown(() async {
        if (running) process.kill(ProcessSignal.sigkill);
        await exited;
        await Future.wait([stdout, stderr]);
      });
      final exitCode = await exited.timeout(const Duration(seconds: 30));
      final output = '${await stdout}\n${await stderr}';
      expect(exitCode, isNot(0), reason: output);
      expect(
        RegExp('ARGUMENT_TYPE_NOT_ASSIGNABLE').allMatches(output),
        hasLength(2),
        reason: output,
      );
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'actual service and application registries partition every operation',
    () async {
      final root = createTestTempDirectorySync('dispatch-owners-');
      final original = runtimeConfiguration.environment['FORESIGHT_HELPER'];
      runtimeConfiguration.environment['FORESIGHT_HELPER'] = '';
      ApplicationService? service;
      try {
        service = await ApplicationService.start(
          ProfilePaths('${root.path}/d', '${root.path}/r'),
          desktopPeerVerifier: trustInProcessDesktop,
        );
        final application = service.application.registeredOperations;
        final transport = service.registeredOperations;
        expect(application.intersection(transport), isEmpty);
        expect({...application, ...transport}, Operation.values.toSet());
        expect(
          application.every(
            (operation) =>
                operation.descriptor.scope == OperationScope.application,
          ),
          isTrue,
        );
        expect(
          transport.every(
            (operation) => operation.descriptor.scope == OperationScope.service,
          ),
          isTrue,
        );
        expect(() => application.clear(), throwsUnsupportedError);
        expect(() => transport.clear(), throwsUnsupportedError);
      } finally {
        await service?.close();
        if (original == null) {
          runtimeConfiguration.environment.remove('FORESIGHT_HELPER');
        } else {
          runtimeConfiguration.environment['FORESIGHT_HELPER'] = original;
        }
      }
    },
  );
  test('helper account wire identity has one definition', () {
    final literals = <String>[];
    for (final file in Directory(
      'lib',
    ).listSync(recursive: true).whereType<File>()) {
      if (file.path.endsWith('.dart') &&
          file.readAsStringSync().contains("'local_user'")) {
        literals.add(file.path);
      }
    }
    expect(literals, ['lib/src/helper.dart']);
  });
}
