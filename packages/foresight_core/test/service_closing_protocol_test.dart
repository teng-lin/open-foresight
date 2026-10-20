import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:foresight_core/foresight_core.dart';
import 'package:foresight_core/src/service.dart';
import 'package:foresight_test_support/hooked_service.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';

// The closing protocol (fix plan, PR 3) with production code on both sides:
// the real bin/service.dart (IsolatedApplicationService) and the real wire
// client. Assertions read the wire where they can, so each test also runs
// against an owner or client built before the protocol existed.

const closingMessage =
    'Application service is shutting down; retry after it exits.';

/// One raw request and its terminal frame, as a client that predates the
/// `reason` field reads it: newline-delimited JSON, nothing else.
Future<Map<String, dynamic>> rawRequest(
  String endpoint,
  int id,
  String method,
) async {
  final socket = await Socket.connect(
    InternetAddress(endpoint, type: InternetAddressType.unix),
    0,
  );
  try {
    socket.add(
      utf8.encode('${jsonEncode({'id': id, 'method': method, 'args': {}})}\n'),
    );
    final line = await utf8.decoder
        .bind(socket)
        .transform(const LineSplitter())
        .firstWhere((line) => (jsonDecode(line) as Map)['id'] == id);
    return jsonDecode(line) as Map<String, dynamic>;
  } finally {
    socket.destroy();
  }
}

void main() {
  late HookedServiceBuild build;
  late Map<String, String> saved;
  setUpAll(() async => build = await HookedServiceBuild.compile());
  tearDownAll(() => build.dispose());
  setUp(() {
    saved = Map.of(runtimeConfiguration.environment);
    for (final key in [
      'FORESIGHT_NATIVE',
      'FORESIGHT_INSTALL_ROOT',
      'FORESIGHT_RUNTIME_REVISION',
      'FORESIGHT_MODEL_MANIFEST',
      'FORESIGHT_SERVICE_GATES',
    ]) {
      runtimeConfiguration.environment.remove(key);
    }
    // Launched replacements inherit this configuration; run them helperless.
    runtimeConfiguration.environment['FORESIGHT_HELPER'] = '';
  });
  tearDown(() {
    runtimeConfiguration.environment
      ..clear()
      ..addAll(saved);
  });

  ProfilePaths newProfile(String prefix) {
    final directory = createTestTempDirectorySync(prefix);
    return ProfilePaths('${directory.path}/data', '${directory.path}/run');
  }

  test('an old client recognizes a closing refusal by its unchanged text (wire '
      'compatibility)', () async {
    final profile = newProfile('of-wire-');
    final owner = await HookedServiceProcess.start(
      build,
      profile,
      hold: ['close.helper_closed'],
    );
    ServiceClient? stopper;
    try {
      await owner.ready();
      stopper = await ServiceClient.connect(serviceEndpoint(profile));
      final idle = stopper.call('service.stop_if_idle');
      await owner.reached('close.helper_closed');
      final frame = await rawRequest(serviceEndpoint(profile), 7, 'status');
      expect(frame['done'], isTrue);
      final error = frame['error'] as Map;
      // v0.1.0-v0.1.2 clients match exactly these two fields.
      expect(error['code'], 'unavailable');
      expect(error['message'], closingMessage);
      // The reason is one additive field that such clients ignore.
      expect(error['reason'], 'closing');
      expect(error.keys, unorderedEquals(['code', 'message', 'reason']));
      owner.release('close.helper_closed');
      expect(await idle, {'stopped': true, 'shutdown_verified': true});
      expect(await owner.exitCode, 0, reason: owner.output);
    } finally {
      await stopper?.close();
      await owner.stop();
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}
