import 'dart:io';
import 'package:foresight_core/src/operations.dart';
import 'package:foresight_core/src/rpc_error.dart';
import 'package:test/test.dart';

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
      for (final name in ['remote_domain.dart', 'service.dart']) {
        final source = File('lib/src/$name').readAsStringSync();
        expect(
          RegExp(r"\.(?:call|stream|command)\(\s*'[^']+'").allMatches(source),
          isEmpty,
          reason: '$name contains an unregistered RPC literal',
        );
      }
    },
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
