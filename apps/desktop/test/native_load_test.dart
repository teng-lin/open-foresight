import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import '../test_support/core_fixture.dart';

void main() {
  test(
    'native probe gates readiness and late load adoption is cancelled by close',
    () async {
      final native = NativeRuntime(Platform.environment['FORESIGHT_NATIVE']!);
      final model = Platform.environment['FORESIGHT_GENERATION_MODEL']!;
      final runner = Platform.environment['FORESIGHT_GENERATION_RUNNER']!;
      final backend =
          Platform.environment['FORESIGHT_GENERATION_BACKEND'] ?? 'litert_lm';
      await expectLater(
        native.load(runner, '$model.missing-fixture', backend: backend),
        throwsStateError,
      );
      expect(native.effectiveState['state'], 'failed');
      final pending = native.load(runner, model, backend: backend);
      expect(native.effectiveState['state'], 'loading');
      native.close();
      await expectLater(
        pending,
        throwsA(
          isA<RpcError>().having(
            (error) => error.code,
            'code',
            RpcErrorCode.cancelled,
          ),
        ),
      );
      expect(native.effectiveState['state'], 'unconfigured');
      await native.load(runner, model, backend: backend);
      expect(native.effectiveState['state'], 'ready');
      native.close();
    },
    skip: Platform.environment['FORESIGHT_INTEGRATION'] != '1',
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
