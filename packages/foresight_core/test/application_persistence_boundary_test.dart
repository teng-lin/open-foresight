import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:test/test.dart';

/// Business owners use named persistence methods and immutable projections.
/// Store's connection lifecycle, migrations and read implementations own SQL.
class BusinessPersistenceBoundary extends RecursiveAstVisitor<void> {
  BusinessPersistenceBoundary(this.path, this.violations);
  final String path;
  final List<String> violations;
  static final sql = RegExp(
    r'\b(?:SELECT\b[\s\S]*\bFROM\b|INSERT\s+(?:OR\s+\w+\s+)?INTO\b|UPDATE\s+\w+\s+SET\b|DELETE\s+FROM\b|CREATE\s+TABLE\b|PRAGMA\s+\w+|VACUUM\b)',
    caseSensitive: false,
  );

  void reject(AstNode node, String reason) =>
      violations.add('$path:${node.offset}: $reason');

  @override
  void visitSimpleStringLiteral(SimpleStringLiteral node) {
    if (sql.hasMatch(node.value)) reject(node, 'SQL belongs to persistence');
    super.visitSimpleStringLiteral(node);
  }

  @override
  void visitStringInterpolation(StringInterpolation node) {
    if (sql.hasMatch(node.toSource())) {
      reject(node, 'SQL belongs to persistence');
    }
    super.visitStringInterpolation(node);
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    if (node.methodName.name == 'rows') {
      reject(node, 'business owners require a named typed query');
    }
    super.visitMethodInvocation(node);
  }

  @override
  void visitPrefixedIdentifier(PrefixedIdentifier node) {
    if (node.identifier.name == 'db') {
      reject(node, 'raw database access belongs to persistence');
    }
    super.visitPrefixedIdentifier(node);
  }

  @override
  void visitPropertyAccess(PropertyAccess node) {
    if (node.propertyName.name == 'db') {
      reject(node, 'raw database access belongs to persistence');
    }
    super.visitPropertyAccess(node);
  }
}

void main() {
  test('application business owners cannot bypass typed persistence', () {
    final files = <File>[
      for (final name in [
        'application.dart',
        'application_service.dart',
        'domain.dart',
        'google_connections.dart',
        'model_setup.dart',
        'proactive_questions.dart',
        'conversation_answer.dart',
        'answer_retrieval_phase.dart',
        'answer_prompt_phase.dart',
        'answer_generation_phase.dart',
      ])
        File('lib/src/$name'),
      ...Directory('lib/src/application_services')
          .listSync(recursive: true)
          .whereType<File>()
          .where((file) => file.path.endsWith('.dart')),
    ];
    final violations = <String>[];
    for (final file in files) {
      final result = parseString(
        content: file.readAsStringSync(),
        path: file.path,
      );
      expect(result.errors, isEmpty, reason: file.path);
      result.unit.accept(BusinessPersistenceBoundary(file.path, violations));
    }
    expect(violations, isEmpty, reason: violations.join('\n'));
  });
}
