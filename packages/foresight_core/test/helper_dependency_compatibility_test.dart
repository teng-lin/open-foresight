import 'dart:io';
import 'package:test/test.dart';

void main() {
  test('HTTP2 helper workaround uses its exact qualified grpc/http2 versions', () {
    const qualified = {'grpc': '4.3.1', 'http2': '2.3.1'};
    final manifest = File('pubspec.yaml').readAsStringSync();
    final lock = File('pubspec.lock').readAsStringSync();
    for (final dependency in qualified.entries) {
      expect(
        RegExp(
          '^  ${dependency.key}: ${RegExp.escape(dependency.value)}\$',
          multiLine: true,
        ).hasMatch(manifest),
        isTrue,
        reason:
            '${dependency.key} must retain the exact documented pin until EOF/write-race regressions qualify an upstream fix',
      );
      final stanza = RegExp(
        '^  ${dependency.key}:\n((?:    .*\n)+)',
        multiLine: true,
      ).firstMatch(lock)?.group(1);
      expect(
        stanza,
        isNotNull,
        reason: '${dependency.key} must exist in the actual core lockfile',
      );
      final version = RegExp(
        r'^    version: "([^"]+)"$',
        multiLine: true,
      ).firstMatch(stanza!)?.group(1);
      expect(
        version,
        dependency.value,
        reason:
            'The resolved core dependency, not an unrelated lockfile, qualifies helper_channel.dart and helper_transport.dart',
      );
    }
  });
}
