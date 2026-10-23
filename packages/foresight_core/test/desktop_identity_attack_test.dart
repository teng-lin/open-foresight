import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:foresight_core/foresight_core.dart';
import 'package:foresight_core/src/service.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';

void main() {
  test(
    'a same-user process cannot take the approval host with its readable token',
    () async {
      final root = createTestTempDirectorySync('desktop-attack-');
      final profile = ProfilePaths('${root.path}/d', '${root.path}/r');
      final saved = Map.of(runtimeConfiguration.environment);
      runtimeConfiguration.environment['FORESIGHT_HELPER'] = '';
      final service = await IsolatedApplicationService.start(profile);
      addTearDown(() async {
        await service.close();
        runtimeConfiguration.environment
          ..clear()
          ..addAll(saved);
      });
      final attack = File('${root.path}/attack.dart')
        ..writeAsStringSync(r'''
import 'dart:io';
import 'dart:convert';
import 'package:foresight_core/src/service.dart';
Future<void> main(List<String> args) async {
  final client = await ServiceClient.connect(args[0]);
  final results = <String, Object?>{};
  final token = File('${args[1]}/.desktop-capability').readAsStringSync();
  final calls = <String, Map<String, dynamic>>{
    'security.attach_desktop': {'token': token},
    'security.allow_import_root': {'path': '/'},
    'preferences.set': {'key': 'importRoots', 'value': '["/"]'},
    'meetings.start': {'id': 999},
    'workspace.clear': {},
    'models.generation': {'path': '/missing-fixture', 'runtime': '/outside-installation'},
  };
  try {
    for (final entry in calls.entries) {
      try {
        await client.call(entry.key, entry.value).timeout(const Duration(seconds: 3));
        results[entry.key] = 'accepted';
      } catch (error) {
        results[entry.key] = error.toString();
      }
    }
    print(jsonEncode(results));
  } finally {
    await client.close();
  }
}
''');
      final packages = (await Isolate.packageConfig)!.toFilePath();
      final result = await Process.run(Platform.resolvedExecutable, [
        '--packages=$packages',
        attack.path,
        serviceEndpoint(profile),
        profile.data,
      ]);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      final outcomes = jsonDecode(result.stdout.toString().trim()) as Map;
      expect(
        outcomes['security.attach_desktop'],
        contains('verified desktop'),
        reason: outcomes.toString(),
      );
      expect(outcomes.values, everyElement(isNot('accepted')));
    },
  );
}
