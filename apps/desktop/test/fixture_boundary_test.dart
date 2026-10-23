import '../test_support/desktop_architecture.dart';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('fixture boundary checks every actual dependency URI', () {
    for (final source in [
      "import '../test_support/core_fixture.dart' if (dart.library.io) 'package:foresight_core/src/store.dart';",
      "export '../test_support/core_fixture.dart' if (dart.library.io) 'package:foresight_core/src/store.dart';",
      "import '../../../packages/foresight_core/lib/src/store.dart';",
      "import 'package:foresight_core/src/../src/store.dart';",
    ]) {
      expect(
        fixtureImportsCoreImplementation('test/probe.dart', source),
        isTrue,
        reason: source,
      );
    }
    expect(
      fixtureImportsCoreImplementation(
        'test/probe.dart',
        'final sample = "import \'package:foresight_core/src/store.dart\';";',
      ),
      isFalse,
    );
  });

  test('desktop fixtures share one deliberate core implementation boundary', () {
    final violations = <String>[];
    for (final directory in ['test', 'integration_test', 'test_support']) {
      for (final file in Directory(
        directory,
      ).listSync(recursive: true).whereType<File>()) {
        if (!file.path.endsWith('.dart') ||
            file.path == 'test_support/core_fixture.dart')
          continue;
        final source = file.readAsStringSync();
        if (fixtureImportsCoreImplementation(file.path, source)) {
          violations.add(file.path);
        }
        // The only deliberate runtime writer probe attacks the connected facade.
        // Every Workspace, owner and painter access has a static interface.
        if (RegExp(r'\bas\s+dynamic\b').hasMatch(source) &&
            file.path != 'integration_test/service_mcp_test.dart') {
          violations.add('${file.path}: dynamic inspection');
        }
      }
    }
    expect(violations, isEmpty);
    expect(
      File('analysis_options.yaml').readAsStringSync(),
      contains('avoid_dynamic_calls: true'),
    );
  });
}
