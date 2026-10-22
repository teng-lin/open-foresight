import 'package:foresight_core/src/platform_services.dart';
import 'package:foresight_core/src/service_diagnostics.dart';
import 'package:test/test.dart';

void main() {
  test('disabled transport tracing never formats its message', () {
    installServiceWorkerEnvironment({'FORESIGHT_SERVICE_TRACE': '0'});
    var calls = 0;
    traceServiceTransport(() {
      calls++;
      throw StateError('formatting must remain lazy');
    });
    expect(calls, 0);
  });

  test('enabled tracing formats once', () {
    installServiceWorkerEnvironment({'FORESIGHT_SERVICE_TRACE': '1'});
    var calls = 0;
    traceServiceTransport(() {
      calls++;
      return 'test enabled trace';
    });
    expect(calls, 1);
  });
}
