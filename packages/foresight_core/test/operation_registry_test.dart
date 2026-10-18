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

  test(
    'remote facades and service reference registry operation identities',
    () {
      for (final name in [
        'remote_domain.dart',
        'service.dart',
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

  test('desktop command callsites use the typed operation registry', () {
    final files = Directory('../../apps/desktop/lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('.dart'))
        .toList();
    expect(files, isNotEmpty);
    for (final file in files) {
      expect(
        rawRpcCalls(file.readAsStringSync(), desktop: true),
        isEmpty,
        reason: '${file.path} contains a raw desktop RPC name',
      );
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
      rawRpcCalls('desktop.command(Operation.notes_save, {});', desktop: true),
      isEmpty,
    );
  });

  test(
    'desktop command API rejects stale and unknown wire strings at compile time',
    () async {
      final directory = Directory(
        '.dart_tool',
      ).createTempSync('invalid-desktop-command-');
      addTearDown(() => directory.deleteSync(recursive: true));
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

  test('application dispatch is exhaustive over registered operations', () {
    final source = File('lib/src/application.dart').readAsStringSync();
    final dispatch = source.substring(
      source.indexOf('switch (Operation.parse(method))'),
    );
    final cases = RegExp(
      r'case Operation\.(\w+):',
    ).allMatches(dispatch).map((match) => match[1]).toSet();
    expect(cases, Operation.values.map((operation) => operation.name).toSet());
    expect(
      dispatch.substring(0, dispatch.indexOf('} finally {')),
      isNot(contains('default:')),
    );
  });
}
