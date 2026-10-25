import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:test/test.dart';

void main() {
  test(
    'application workflows retain only their declared workspace capabilities',
    () {
      // Generation-slot ownership ports for Summary/Recording/ModelRegistry are
      // qualified with their separate native lifetime conversion.
      const ports = {
        'application_services/answer_coordinator.dart':
            'ConversationWorkspacePort',
        'application_services/automatic_answer_coordinator.dart':
            'GenerationReadPort',
        'application_services/meeting_indexer.dart': 'MeetingIndexingPort',
        'application_services/meeting_questions.dart': 'MeetingGenerationPort',
        'application_services/meeting_workflow_coordinator.dart':
            'MeetingWorkflowPort',
        'application_services/note_enhancement_coordinator.dart':
            'NoteEnhancementPort',
        'application_services/runtime_operations.dart': 'RuntimeOperationsPort',
        'application_services/source_operations.dart': 'SourceOperationsPort',
        'application_services/meeting_operations.dart': 'MeetingMutationPort',
        'application_services/workspace_admin.dart': 'WorkspaceResetPort',
        'application_services/google_maintenance.dart': 'GoogleWorkspacePort',
        'google_connections.dart': 'SourceIndexPort',
        'conversation_answer.dart': 'ConversationWorkspacePort',
      };
      for (final entry in ports.entries) {
        final file = File('lib/src/${entry.key}');
        final unit = parseString(
          content: file.readAsStringSync(),
          path: file.path,
        ).unit;
        for (final directive
            in unit.directives.whereType<UriBasedDirective>()) {
          final uri = directive.uri.stringValue ?? '';
          expect(
            uri.endsWith('/domain.dart') ||
                uri == 'domain.dart' ||
                uri.endsWith('/foresight_core.dart'),
            isFalse,
            reason: entry.key,
          );
        }
        final fields = unit.declarations
            .whereType<ClassDeclaration>()
            .expand((type) => type.body.members.whereType<FieldDeclaration>())
            .where(
              (field) => field.fields.variables.any(
                (value) => value.name.lexeme == 'domain',
              ),
            );
        expect(
          fields,
          hasLength(1),
          reason: '${entry.key} must declare one explicit dependency',
        );
        expect(
          fields.single.fields.type?.toSource(),
          entry.value,
          reason: entry.key,
        );
      }
      final workspace = File(
        'lib/src/application_services/workspace_operations.dart',
      ).readAsStringSync();
      expect(workspace, isNot(contains("import '../domain.dart'")));
      expect(workspace, contains('final Store store;'));
    },
  );
}
