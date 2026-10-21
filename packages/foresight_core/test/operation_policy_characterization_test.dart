import 'dart:convert';
import 'dart:io';

import 'package:foresight_core/src/operations.dart';
import 'package:test/test.dart';

void main() {
  test(
    'reviewed operation and MCP policies retain their frozen wire contract',
    () {
      // Captured from reviewed main c28a1561 before descriptor extraction. This
      // fixture protects policy and tool exposure independently of how they are
      // implemented; updating it requires an intentional contract change.
      final expected = jsonDecode(
        File('test/fixtures/operation_policy_baseline.json').readAsStringSync(),
      );
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
