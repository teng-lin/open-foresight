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
        'features/sources/source_tiles.dart',
        'features/sources/note_widgets.dart',
        'features/sources/graph_widgets.dart',
        'features/sources/source_collection.dart',
      ]) {
        final pending = [File('${desktop.path}/$renderer')];
        final visited = <String>{};
        while (pending.isNotEmpty) {
          final file = pending.removeLast();
          if (!visited.add(file.absolute.path)) continue;
          final unit = read(file).unit;
          expect(
            unit.directives.whereType<PartOfDirective>(),
            isEmpty,
            reason: '$renderer must be an independent logical library',
          );
          for (final uri in _dependencies(unit)) {
            expect(
              uri.endsWith('_controller.dart') ||
                  uri.endsWith('/read_model.dart') ||
                  uri == 'read_model.dart',
              isFalse,
              reason: '$renderer -> ${file.path}: $uri',
            );
            if (uri.startsWith('package:open_foresight/')) {
              pending.add(
                File('${desktop.path}/${uri.split('/').skip(1).join('/')}'),
              );
            } else if (!uri.contains(':')) {
              pending.add(File.fromUri(file.uri.resolve(uri)));
            }
          }
        }
      }
    },
  );
}
