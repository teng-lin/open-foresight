import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'platform_services.dart';
import 'service_diagnostics.dart';

/// Whether lifecycle gates are active. Only a build compiled with
/// -DFORESIGHT_ENABLE_TEST_HOOKS=true keeps FORESIGHT_SERVICE_GATES in its
/// runtime configuration. Callers check this before awaiting [serviceGate],
/// so production code gains no await at a gate point.
bool get serviceGatesEnabled =>
    runtimeConfiguration['FORESIGHT_SERVICE_GATES'] != null;

final _serviceGateNames = RegExp(r'^[A-Za-z0-9_.-]+$');

/// A named point where lifecycle tests can hold the service, in both the
/// frontend and the worker isolate. With FORESIGHT_SERVICE_GATES naming a
/// directory, it publishes `<point>.reached` (this pid) there. If the test
/// armed the point with `<point>.hold`, it then waits for `<point>.release`
/// or `release-all`. Polling only delays a release; the test decides the
/// order. A `<point>.crash` file instead makes the calling isolate fail with
/// an uncaught error, as a fatal fault would, without any cleanup. Without
/// the key it returns at once.
Future<void> serviceGate(String point) async {
  final directory = runtimeConfiguration['FORESIGHT_SERVICE_GATES'];
  if (directory == null) return;
  if (!_serviceGateNames.hasMatch(point)) {
    throw ArgumentError.value(point, 'point');
  }
  try {
    final staging = File('$directory/.$point.$pid.${Random().nextInt(1 << 32)}')
      ..writeAsStringSync('$pid', flush: true);
    staging.renameSync('$directory/$point.reached');
    if (File('$directory/$point.crash').existsSync()) {
      traceServiceTransport(() => 'gate crash $point');
      // The root zone is outside the worker's guarded zone, so the isolate
      // dies and its owner sees only an error and an exit.
      Zone.root.run(
        () => Timer.run(() => throw StateError('Service gate $point crashed')),
      );
      await Completer<void>().future;
    }
    if (!File('$directory/$point.hold').existsSync()) return;
    traceServiceTransport(() => 'gate held $point');
    while (!File('$directory/$point.release').existsSync() &&
        !File('$directory/release-all').existsSync()) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  } on FileSystemException catch (error) {
    // A missing .reached file tells the test; shutdown itself must go on.
    stderr.writeln('Service gate $point: $error');
  }
}
