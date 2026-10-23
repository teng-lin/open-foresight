import 'dart:io';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/analysis/utilities.dart';
import '../test_support/desktop_architecture.dart';

void main() {
  final desktop = Directory('lib');
  test('desktop import closure does not reach the MCP implementation', () {
    final config = File('.dart_tool/package_config.json');
    final packages =
        (jsonDecode(config.readAsStringSync()) as Map)['packages'] as List;
    final roots = <String, Uri>{
      for (final entry in packages.cast<Map>())
        entry['name'] as String: config.uri
            .resolve('${entry['rootUri']}/')
            .resolve(entry['packageUri'] as String? ?? ''),
    };
    final pending = desktop
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('.dart'))
        .toList();
    final visited = <String>{};
    final violations = <String>[];
    while (pending.isNotEmpty) {
      final file = pending.removeLast();
      if (!visited.add(file.absolute.path)) continue;
      final unit = parseString(
        content: file.readAsStringSync(),
        path: file.path,
      ).unit;
      for (final directive in unit.directives.whereType<UriBasedDirective>()) {
        for (final uri in desktopDependencyUris(directive)) {
          if (uri.startsWith('package:mcp_dart/')) {
            violations.add('${file.path}: $uri');
          } else if (uri.startsWith('package:')) {
            final parsed = Uri.parse(uri);
            final parts = parsed.path.split('/');
            final root = roots[parts.first];
            expect(
              root,
              isNotNull,
              reason: 'Unresolved dependency in desktop closure: $uri',
            );
            pending.add(File.fromUri(root!.resolve(parts.skip(1).join('/'))));
          } else if (uri.isNotEmpty && !uri.contains(':')) {
            pending.add(File.fromUri(file.uri.resolve(uri)));
          }
        }
      }
    }
    expect(visited, contains(endsWith('/src/remote_domain.dart')));
    expect(visited, contains(endsWith('/src/application_service.dart')));
    expect(violations, isEmpty);
  });

  test('StoreReader exposes only asynchronous queries and read metadata', () {
    final file = File(
      '../../packages/foresight_core/lib/src/store_reader.dart',
    );
    final unit = parseString(
      content: file.readAsStringSync(),
      path: file.path,
    ).unit;
    final reader = unit.declarations.whereType<ClassDeclaration>().singleWhere(
      (declaration) => declaration.namePart.typeName.lexeme == 'StoreReader',
    );
    final declarations = (reader.body as BlockClassBody).members;
    final members = declarations
        .whereType<MethodDeclaration>()
        .map((member) => member.name.lexeme)
        .toSet();
    expect(members, {
      'failure',
      'workspaceEpoch',
      'dataRevision',
      'watch',
      'read',
    });
    expect(reader.toSource(), isNot(contains('dynamic')));
    expect(declarations.whereType<FieldDeclaration>(), isEmpty);
  });

  test('desktop libraries and widget methods stay within their size budgets', () {
    final violations = <String>[];
    for (final file in desktopDartFiles(desktop)) {
      violations.addAll(
        desktopSizeViolations(
          file.path.substring(desktop.path.length + 1),
          file.readAsStringSync(),
        ),
      );
    }
    expect(violations, isEmpty);
    expect(
      desktopSizeViolations(
        'oversized.dart',
        List.filled(800, '// line').join('\n'),
      ),
      isNotEmpty,
    );
    expect(
      desktopSizeViolations(
        'main.dart',
        List.filled(300, '// line').join('\n'),
      ),
      isNotEmpty,
    );
    expect(
      desktopSizeViolations(
        'view.dart',
        'Widget build() {\n${List.filled(150, 'print(1);').join('\n')}\nreturn const Text("fixture");\n}',
      ),
      isNotEmpty,
    );
  });

  test('feature imports exports and parts respect capability ownership', () {
    final violations = <String>[];
    for (final file in desktopDartFiles(desktop)) {
      violations.addAll(
        desktopArchitectureViolations(
          file.path.substring(desktop.path.length + 1),
          file.readAsStringSync(),
        ),
      );
    }
    expect(violations, isEmpty);
  });

  test('guard rejects alternate imports exports parts and query tear-offs', () {
    for (final source in [
      "import '../settings/settings_controller.dart';",
      "import 'ports.dart' if (dart.library.io) '../settings/settings_controller.dart';",
      "export 'ports.dart' if (dart.library.io) '../settings/settings_controller.dart';",
      "import 'package:open_foresight/features/chat/../settings/settings_controller.dart';",
      "import 'package:open_foresight/features/chat/%2e%2e/settings/settings_controller.dart';",
      "export 'package:open_foresight/features/settings/settings_controller.dart';",
      "part '../../application.dart';",
      "part '../settings/ports.dart';",
      "part of '../../main.dart';",
      'final read = ReadQuery.new;',
      'final read = ReadQuery<Map<String, Object?>>.new;',
      'typedef Query<T> = ReadQuery<T>; final read = Query<String>();',
      'final read = ReadQuery<String>(projection: "sources");',
      'final WorkspaceTestAccess owner = obtainOwner();',
      "export 'package:foresight_core/src/store.dart';",
    ]) {
      expect(
        desktopArchitectureViolations('features/chat/probe.dart', source),
        isNotEmpty,
        reason: source,
      );
    }
    for (final source in [
      "import '../../../packages/foresight_core/lib/src/store.dart' as writable;",
      "export '../../../packages/foresight_core/lib/src/store.dart';",
      "import 'file:///unowned/core/store.dart';",
    ]) {
      expect(
        desktopArchitectureViolations('application.dart', source),
        isNotEmpty,
        reason: source,
      );
    }
    expect(
      desktopArchitectureViolations('features/chat/probe.dart', '''
import 'package:foresight_core/desktop.dart';
import '../sources/ports.dart';
import '../../shell/ports.dart';
part 'history.dart';
final query = StoreReadQueries.sources();
'''),
      isEmpty,
    );
  });
}
