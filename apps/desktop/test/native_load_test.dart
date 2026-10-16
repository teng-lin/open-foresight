import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_foresight/native.dart';

void main() {
  test(
    'native probe gates readiness and late load adoption is cancelled by close',
    () async {
      final native = NativeRuntime(Platform.environment['FORESIGHT_NATIVE']!);
      final model = Platform.environment['FORESIGHT_GENERATION_MODEL']!;
      final runner = Platform.environment['FORESIGHT_GENERATION_RUNNER']!;
      await expectLater(native.load('/bin/false', model), throwsStateError);
      expect(native.effectiveState['state'], 'failed');
      final pending = native.load(runner, model);
      expect(native.effectiveState['state'], 'loading');
      native.close();
      await expectLater(pending, throwsStateError);
      expect(native.effectiveState['state'], 'unconfigured');
      await native.load(runner, model);
      expect(native.effectiveState['state'], 'ready');
      native.close();
    },
    skip: Platform.environment['FORESIGHT_INTEGRATION'] != '1',
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
