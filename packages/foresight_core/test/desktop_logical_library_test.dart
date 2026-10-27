import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:test/test.dart';

bool _decision(AstNode node) =>
    node is IfStatement ||
    node is IfElement ||
    node is ConditionalExpression ||
    node is ForStatement ||
    node is ForElement ||
    node is WhileStatement ||
    node is DoStatement ||
    node is CatchClause ||
    node is SwitchExpressionCase ||
    (node is SwitchMember && node is! SwitchDefault) ||
    (node is BinaryExpression && {'&&', '||'}.contains(node.operator.lexeme));

int _decisions(AstNode node) =>
    (_decision(node) ? 1 : 0) +
    node.childEntities.whereType<AstNode>().fold<int>(
      0,
      (sum, child) => sum + _decisions(child),
    );

Iterable<String> _dependencies(CompilationUnit unit) sync* {
  for (final directive in unit.directives.whereType<UriBasedDirective>()) {
    yield directive.uri.stringValue ?? '';
    if (directive is ImportDirective) {
      for (final configuration in directive.configurations) {
        yield configuration.uri.stringValue ?? '';
      }
    } else if (directive is ExportDirective) {
      for (final configuration in directive.configurations) {
        yield configuration.uri.stringValue ?? '';
      }
    }
  }
}

Iterable<AstNode> _nodes(AstNode node) sync* {
  yield node;
  for (final child in node.childEntities.whereType<AstNode>()) {
    yield* _nodes(child);
  }
}

List<String> _rendererViolations(
  File entry,
  Directory desktop,
  String Function(File) source,
) {
  final pending = [entry], visited = <String>{}, violations = <String>[];
  while (pending.isNotEmpty) {
    final file = pending.removeLast();
    if (!visited.add(file.absolute.path)) continue;
    final unit = parseString(content: source(file), path: file.path).unit;
    if (unit.directives.any((node) => node is PartOfDirective)) {
      violations.add('${file.path}: part of an owner');
    }
    for (final name in _nodes(unit).map(
      (node) => switch (node) {
        SimpleIdentifier() => node.name,
        NamedType() => node.name.lexeme,
        _ => '',
      },
    )) {
      if (const {
            'Domain',
            'Store',
            'StoreReader',
            'StoreReadQueries',
            'NativeRuntime',
            'DesktopConnection',
            'RemoteDomain',
            'Operation',
            'OperationDescriptor',
            'ClientEnvelope',
            'WireField',
            'MeetingReadModel',
            'FeatureHost',
            'command',
            'commandCurrent',
            'send',
            'sendCurrent',
            'sendKeyed',
          }.contains(name) ||
          name.endsWith('Descriptor')) {
        violations.add('${file.path}: business capability $name');
      }
    }
    for (final uri in _dependencies(unit)) {
      if (uri.endsWith('_controller.dart') ||
          const {
            'read_model.dart',
            'domain.dart',
            'store.dart',
            'native.dart',
            'application_service.dart',
            'application.dart',
            'client_command.dart',
            'operation_descriptors.dart',
            'foresight_core.dart',
            'service_server.dart',
          }.contains(uri.split('/').last)) {
        violations.add('${file.path}: owner or business dependency $uri');
        continue;
      }
      if (uri.startsWith('package:open_foresight/')) {
        pending.add(
          File('${desktop.path}/${uri.split('/').skip(1).join('/')}'),
        );
      } else if (!uri.contains(':')) {
        pending.add(File.fromUri(file.uri.resolve(uri)));
      }
    }
  }
  return violations;
}

void main() {
  final desktop = Directory('../../apps/desktop/lib').absolute;
  final cache = <String, ({String source, CompilationUnit unit})>{};
  ({String source, CompilationUnit unit}) read(File file) =>
      cache.putIfAbsent(file.absolute.path, () {
        final source = file.readAsStringSync();
        return (
          source: source,
          unit: parseString(content: source, path: file.path).unit,
        );
      });

  test(
    'logical desktop library size and decision ratchets include every part',
    () {
      // Measured residual owners, including all their parts. These are logical
      // library ceilings, unrelated to the user's waived PR file-count limit.
      const owners = <String, ({int lines, int decisions})>{
        'features/meetings/meetings_controller.dart': (
          lines: 3000,
          decisions: 425,
        ),
        'features/sources/sources_controller.dart': (
          lines: 3000,
          decisions: 400,
        ),
        'features/settings/settings_controller.dart': (
          lines: 2000,
          decisions: 200,
        ),
      };
      final roots = <String>{};
      for (final file in desktop.listSync(recursive: true).whereType<File>()) {
        if (!file.path.endsWith('.dart')) continue;
        if (read(file).unit.directives.any((node) => node is PartOfDirective)) {
          continue;
        }
        final relative = file.path.substring(desktop.path.length + 1);
        roots.add(relative);
        final pending = [file], visited = <String>{};
        var lines = 0, decisions = 0;
        while (pending.isNotEmpty) {
          final part = pending.removeLast();
          if (!visited.add(part.absolute.path)) continue;
          final unit = read(part);
          lines += const LineSplitter().convert(unit.source).length;
          decisions += _decisions(unit.unit);
          for (final directive
              in unit.unit.directives.whereType<PartDirective>()) {
            pending.add(
              File.fromUri(part.uri.resolve(directive.uri.stringValue!)),
            );
          }
        }
        final limit = owners[relative] ?? (lines: 1000, decisions: 200);
        final evidence =
            '$relative: $lines lines, $decisions decision nodes, '
            '${visited.length - 1} parts. Extract a logical library; adding parts '
            'does not reduce this owner.';
        expect(lines, lessThanOrEqualTo(limit.lines), reason: evidence);
        expect(decisions, lessThanOrEqualTo(limit.decisions), reason: evidence);
      }
      expect(
        roots,
        containsAll(owners.keys),
        reason: 'Remove stale owner exceptions',
      );
    },
  );

  test(
    'extracted renderers have no transitive controller or read-model dependency',
    () {
      for (final renderer in [
        'features/meetings/recording_view.dart',
        'features/meetings/summary_view.dart',
        'features/meetings/collection_view.dart',
        'features/meetings/workspace_view.dart',
        'features/meetings/transcript_view.dart',
        'features/meetings/notes_widgets.dart',
        'features/meetings/enhanced_notes_view.dart',
        'features/meetings/assistant_widgets.dart',
        'features/meetings/ai_panels.dart',
        'features/meetings/ai_dialogs.dart',
        'features/sources/source_tiles.dart',
        'features/sources/note_widgets.dart',
        'features/sources/graph_widgets.dart',
        'features/sources/source_collection.dart',
      ]) {
        expect(
          _rendererViolations(
            File('${desktop.path}/$renderer'),
            desktop,
            (file) => read(file).source,
          ),
          isEmpty,
          reason: renderer,
        );
      }
    },
  );

  test('renderer guard rejects transitive owner and business shortcuts', () {
    final fixtures = <String, String>{
      '/fixture/entry.dart': "export 'nested.dart';",
      '/fixture/nested.dart': "export 'read_model.dart';",
    };
    List<String> violations() => _rendererViolations(
      File('/fixture/entry.dart'),
      Directory('/fixture'),
      (file) => fixtures[file.path]!,
    );
    expect(violations(), contains(contains('read_model.dart')));
    fixtures['/fixture/nested.dart'] =
        "import 'safe.dart' if (dart.library.io) 'meetings_controller.dart';";
    fixtures['/fixture/safe.dart'] = 'void render() {}';
    expect(violations(), contains(contains('meetings_controller.dart')));
    fixtures['/fixture/nested.dart'] = "part of 'meetings_controller.dart';";
    expect(violations(), contains(contains('part of an owner')));
    fixtures['/fixture/nested.dart'] =
        "import 'package:foresight_core/service_server.dart';";
    expect(violations(), contains(contains('service_server.dart')));
    fixtures['/fixture/nested.dart'] =
        "import 'package:foresight_core/desktop.dart'; "
        'void action(DesktopConnection connection) { '
        'meetingsGenerateDescriptor.send(connection, null); }';
    expect(
      violations(),
      contains(contains('business capability DesktopConnection')),
    );
    expect(
      violations(),
      contains(contains('business capability meetingsGenerateDescriptor')),
    );
    expect(violations(), contains(contains('business capability send')));
    fixtures['/fixture/nested.dart'] =
        'void build(String snapshot, void Function() onRetry) { onRetry(); }';
    expect(violations(), isEmpty);
  });
}
