import 'package:foresight_core/src/mcp/rpc_tools.dart';
import 'dart:convert';
import 'dart:io';

import 'package:foresight_core/src/operations.dart';
import 'package:test/test.dart';

void main() {
  test(
    'reviewed policies retain their contract with explicit MCP schema corrections',
    () {
      // Captured from reviewed main c28a1561 before descriptor extraction. This
      // fixture protects policy and tool exposure independently of how they are
      // implemented. Keep the historical fixture unchanged; intentional schema
      // corrections below are literal expectations independent of live metadata.
      final expected =
          jsonDecode(
                File(
                  'test/fixtures/operation_policy_baseline.json',
                ).readAsStringSync(),
              )
              as Map<String, dynamic>;
      final preparation =
          (expected['meetings.prepare']['tools'] as List).single;
      final sourceIds =
          preparation['schema']['properties']['source_ids']
              as Map<String, dynamic>;
      expect(sourceIds, {
        'type': 'array',
        'items': {'type': 'string'},
      });
      // The decoder already enforces these limits. Publish them to MCP clients
      // while retaining every frozen approval, exposure and ownership assertion.
      sourceIds.addAll({'minItems': 1, 'maxItems': 100, 'uniqueItems': true});
      // Audit P0.3 deliberately requires approval for replacements and labels
      // those MCP writers destructive. Preserve the historical fixture itself.
      for (final method in [
        'notes.save',
        'artifacts.edit',
        'meetings.notes',
        'meetings.edit_task',
        'meetings.prepare',
        'meetings.enhance',
        'meetings.generate',
      ]) {
        expected[method]['approval'] = true;
        expected[method]['approval_web_search'] = true;
        for (final tool in expected[method]['tools'] as List) {
          tool['destructive'] = true;
        }
      }
      // New desktop metadata edit; the historical fixture remains frozen.
      expected['meetings.rename'] = {
        'requires_helper': false,
        'approval': true,
        'approval_web_search': true,
        'notifies_changes': true,
        'workspace_epoch': true,
        'idempotency_key': false,
        'tools': <Object?>[],
      };
      // Explicit new desktop asset contracts; keep every historical policy
      // and exact MCP exposure comparison below, including no new tools.
      expected['models.download_asset'] = {
        'requires_helper': false,
        'approval': true,
        'approval_web_search': true,
        'notifies_changes': true,
        'workspace_epoch': false,
        'idempotency_key': false,
        'tools': <Object?>[],
      };
      expected['models.inspect_asset'] = {
        'requires_helper': false,
        'approval': false,
        'approval_web_search': false,
        'notifies_changes': false,
        'workspace_epoch': false,
        'idempotency_key': false,
        'tools': <Object?>[],
      };
      // Retained audio controls are desktop-only; none adds an MCP tool.
      // Keep the historical fixture immutable and list each new policy here.
      for (final method in [
        'recordings.read',
        'recordings.transcript_target',
        'recordings.play',
        'recordings.pause_audio',
        'recordings.seek',
        'recordings.seek_transcript',
        'recordings.authorize_export_destination',
        'recordings.export',
        'recordings.cancel_export',
        'recordings.retry_transcription',
        'recordings.retry_compression',
        'recordings.delete',
        'recordings.set_retain_lossless',
      ]) {
        expected[method] = {
          'requires_helper': false,
          'approval': false,
          'approval_web_search': false,
          'notifies_changes':
              method != 'recordings.read' &&
              method != 'recordings.transcript_target',
          'workspace_epoch': true,
          'idempotency_key': false,
          'tools': <Object?>[],
        };
      }
      final actual = <String, Object?>{};
      for (final operation in Operation.values) {
        actual[operation.wire] = {
          'requires_helper': operation.requiresHelper,
          'approval': operation.requiresApproval(),
          'approval_web_search': operation.requiresApproval(webSearch: true),
          'notifies_changes': operation.notifiesChanges,
          'workspace_epoch': operation.carriesWorkspaceEpoch,
          'idempotency_key': operation.acceptsIdempotencyKey,
          'tools': [
            for (final tool in rpcTools.where(
              (tool) => tool.operation == operation,
            ))
              {
                'name': tool.name,
                'schema': tool.schema.toJson(),
                'read_only': tool.readOnly,
                'destructive': tool.destructive,
                'open_world': tool.openWorld,
              },
          ],
        };
      }
      expect(actual, expected);
    },
  );

  test('workspace scoping preserves explicit null and caller-owned epochs', () {
    for (final operation in Operation.values) {
      for (final args in [
        <String, dynamic>{},
        <String, dynamic>{'id': null},
        <String, dynamic>{'id': 1},
        <String, dynamic>{'idempotency_key': 'create'},
        <String, dynamic>{'id': 1, 'workspace_epoch': null},
        <String, dynamic>{'id': 1, 'workspace_epoch': 'original'},
      ]) {
        final original = Map<String, dynamic>.of(args);
        final scoped = operation.scopedToWorkspace(args, 'current');
        final shouldScope =
            !args.containsKey('workspace_epoch') &&
            ((operation.carriesWorkspaceEpoch && args['id'] != null) ||
                (operation.acceptsIdempotencyKey &&
                    args['idempotency_key'] != null));
        expect(scoped, {
          ...args,
          if (shouldScope) 'workspace_epoch': 'current',
        }, reason: '${operation.wire}: $args');
        expect(args, original, reason: 'caller arguments are never mutated');
        expect(operation.scopedToWorkspace(args, null), original);
      }
    }
  });
}
