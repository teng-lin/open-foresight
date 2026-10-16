import 'dart:convert';
import 'dart:io';
import 'package:foresight_core/src/dedicated_query_runtime.dart';
import 'package:foresight_core/src/reference_query_detector.dart';
import 'package:test/test.dart';

void main() {
  final env = Platform.environment;
  test(
    'dedicated original weights complete through the owned Dart runtime',
    () async {
      final runtime = DedicatedQueryRuntime(
        python: env['FORESIGHT_QUERY_PYTHON']!,
        worker: env['FORESIGHT_QUERY_WORKER']!,
        model: env['FORESIGHT_QUERY_MODEL']!,
      );
      final detector = ReferenceQueryDetector(runtime.complete);
      final report = <String, dynamic>{
        'backend': dedicatedQueryBackend,
        'original_gpu_parity_verified': false,
      };
      try {
        final positive = await detector.detect(
          'The launch is scheduled for Friday. What risks could delay it?',
          'actual-positive',
        );
        final negative = await detector.detect(
          'The meeting starts at three.',
          'actual-negative',
        );
        expect(positive, ['What risks could delay the launch?']);
        expect(negative, isEmpty);
        report['positive'] = positive;
        report['negative'] = negative;
      } finally {
        await runtime.close();
      }
      report['closed'] = true;
      final path = env['FORESIGHT_QUERY_MODEL_REPORT'];
      if (path != null) {
        File(
          path,
        ).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(report));
      }
    },
    skip: env['FORESIGHT_QUERY_MODEL_TEST'] != '1'
        ? 'Set dedicated model, worker and Python paths to run original weights'
        : false,
  );
}
