import 'dart:convert';

import 'package:foresight_core/src/rpc_error.dart';
import 'package:grpc/grpc.dart';
import 'package:test/test.dart';

void main() {
  test(
    'caller validation and ordinary StateError mapping retain stable wire codes',
    () {
      for (final failure in [
        ArgumentError('invalid value'),
        const FormatException('invalid format'),
      ]) {
        expect(RpcError.from(failure).code, RpcErrorCode.invalidArgument);
      }
      final execution = RpcError.from(StateError('execution failed'));
      expect(execution.toJson(), {
        'code': 'internal',
        'message': 'execution failed',
      });
      expect(execution.toString(), 'execution failed');
    },
  );

  test('unexpected TypeError in typed execution is an internal failure', () {
    final Object value = 42;
    late final Object failure;
    try {
      value as String;
      fail('Expected a TypeError');
    } catch (error) {
      failure = error;
    }
    expect(failure, isA<TypeError>());
    expect(RpcError.from(failure).code, RpcErrorCode.internal);
  });

  test('helper conversion preserves every supported error category', () {
    final cases = <int, RpcErrorCode>{
      StatusCode.cancelled: RpcErrorCode.cancelled,
      StatusCode.invalidArgument: RpcErrorCode.invalidArgument,
      StatusCode.notFound: RpcErrorCode.notFound,
      StatusCode.resourceExhausted: RpcErrorCode.busy,
      StatusCode.unavailable: RpcErrorCode.unavailable,
      StatusCode.permissionDenied: RpcErrorCode.denied,
      StatusCode.internal: RpcErrorCode.internal,
      StatusCode.unknown: RpcErrorCode.internal,
    };
    for (final entry in cases.entries) {
      final converted = RpcError.from(
        GrpcError.custom(entry.key, 'helper failure'),
      );
      expect(converted.code, entry.value);
      expect(converted.message, 'helper failure');
      expect(converted.reason, isNull);
      expect(jsonDecode(jsonEncode(converted.toJson())), {
        'code': entry.value.name,
        'message': 'helper failure',
      });
    }
  });

  test('an existing structured error retains identity and optional reason', () {
    final error = RpcError(
      RpcErrorCode.unavailable,
      serviceClosingMessage,
      reason: RpcErrorReason.closing,
    );
    expect(error, isA<Exception>());
    expect(error, isNot(isA<StateError>()));
    expect(RpcError.from(error), same(error));
    expect(isClosingRefusal(error), isTrue);
    expect(error.toJson().keys, unorderedEquals(['code', 'message', 'reason']));
    expect(error.toJson().containsKey('stack'), isFalse);
  });
}
