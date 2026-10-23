import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
        final unit = parseString(content: source, path: file.path).unit;
        if (unit.directives.whereType<UriBasedDirective>().any(
          (directive) => (directive.uri.stringValue ?? '').startsWith(
            'package:foresight_core/src/',
          ),
        )) {
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
