// A launcher process for lifecycle tests. It runs ensureService for the
// profile in FORESIGHT_DATA and FORESIGHT_RUNTIME, relayed by a fault proxy,
// and prints `refused` once a closing refusal reaches it, then
// `attached <pid>` for the owner it attached to.
import 'dart:async';
import 'dart:io';

import 'package:foresight_core/foresight_core.dart';
import 'package:foresight_core/src/service.dart';
import 'package:foresight_test_support/service_fault_proxy.dart';

Future<void> main() async {
  final profile = ProfilePaths(
    Platform.environment['FORESIGHT_DATA']!,
    Platform.environment['FORESIGHT_RUNTIME']!,
  );
  final proxy = ServiceFaultProxy();
  unawaited(
    proxy
        .seen(
          ProxyDirection.toClient,
          where: (frame) => frame.error?['reason'] == 'closing',
        )
        .then((_) => stdout.writeln('refused')),
  );
  final client = await proxy.run(
    () => ensureService(profile, startupTimeout: const Duration(seconds: 90)),
  );
  try {
    final status = await client.call('status') as Map;
    stdout.writeln('attached ${status['pid']}');
  } finally {
    await client.close();
    await proxy.close();
  }
}
