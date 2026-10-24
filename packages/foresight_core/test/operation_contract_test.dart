import 'package:foresight_core/src/mcp/rpc_tools.dart';
import 'dart:convert';
import 'dart:io';

import 'package:foresight_core/src/application.dart' as legacy;
import 'package:foresight_core/src/operation_argument_schema.dart';
import 'package:foresight_core/src/operation_descriptor.dart';
import 'package:foresight_core/src/operation_requests.dart';
import 'package:foresight_core/src/mcp/operation_tool_projection.dart';
import 'package:foresight_core/src/operations.dart';
import 'package:foresight_core/src/request_fingerprint.dart';
import 'package:foresight_core/src/rpc_error.dart';
import 'package:test/test.dart';

Matcher get invalid => isA<RpcError>().having(
  (error) => error.code,
  'code',
  RpcErrorCode.invalidArgument,
);

Map<String, dynamic> minimal(Operation operation) {
  final result = <String, dynamic>{};
  for (final field in operation.descriptor.arguments.fields) {
    if (!field.required) continue;
    result[field.name] = switch (field.kind) {
      ArgumentKind.string => field.choices?.first ?? 'value',
      ArgumentKind.integer => field.minimum ?? 1,
      ArgumentKind.dateTime => '2026-10-21T12:00:00Z',
      ArgumentKind.strings => ['source'],
      ArgumentKind.graphSources => [
        <String, dynamic>{'id': 'source'},
      ],
      ArgumentKind.vectors || ArgumentKind.points => <String, dynamic>{},
      ArgumentKind.clusters => <Object?>[],
      ArgumentKind.trueSwitch || ArgumentKind.falseSwitch => true,
    };
  }
  if (operation == Operation.googleConfigure) result['path'] = 'credentials';
  return result;
}

void main() {
  test('policies retain the baseline with replacement consent', () {
    final baseline =
        jsonDecode(
              File(
                'test/fixtures/operation_policy_baseline.json',
              ).readAsStringSync(),
            )
            as Map;
    // Preserve the historical fixture and assert the deliberate P0.3 change.
    for (final method in [
      'notes.save',
      'artifacts.edit',
      'meetings.notes',
      'meetings.edit_task',
      'meetings.prepare',
      'meetings.enhance',
      'meetings.generate',
    ]) {
      baseline[method]['approval'] = true;
      baseline[method]['approval_web_search'] = true;
    }
    baseline['meetings.rename'] = {
      'requires_helper': false,
      'approval': true,
      'approval_web_search': true,
      'notifies_changes': true,
      'workspace_epoch': true,
      'idempotency_key': false,
      'tools': <Object?>[],
    };
    expect(Operation.values, hasLength(85));
    for (final operation in Operation.values) {
      final old = baseline[operation.wire] as Map;
      final descriptor = operation.descriptor;
      expect(
        descriptor.requiresHelper,
        old['requires_helper'],
        reason: operation.wire,
      );
      expect(
        descriptor.requiresApproval(webSearch: false),
        old['approval'],
        reason: operation.wire,
      );
      expect(
        descriptor.requiresApproval(webSearch: true),
        old['approval_web_search'],
        reason: operation.wire,
      );
      expect(
        descriptor.notifiesChanges,
        old['notifies_changes'],
        reason: operation.wire,
      );
      expect(
        descriptor.carriesWorkspaceEpoch,
        old['workspace_epoch'],
        reason: operation.wire,
      );
      expect(
        descriptor.acceptsIdempotencyKey,
        old['idempotency_key'],
        reason: operation.wire,
      );
      expect(descriptor.requiresHelper, operation.requiresHelper);
      expect(
        descriptor.requiresApproval(webSearch: false),
        operation.requiresApproval(),
      );
      expect(
        descriptor.requiresApproval(webSearch: true),
        operation.requiresApproval(webSearch: true),
      );
      expect(descriptor.notifiesChanges, operation.notifiesChanges);
      expect(descriptor.carriesWorkspaceEpoch, operation.carriesWorkspaceEpoch);
      expect(descriptor.acceptsIdempotencyKey, operation.acceptsIdempotencyKey);
    }
  });

  test(
    'MCP schemas project the same 32 closed subsets of service arguments',
    () {
      expect(operationToolProjections, hasLength(32));
      for (final tool in rpcTools) {
        final projection = operationToolProjections.singleWhere(
          (p) => p.name == tool.name,
        );
        expect(projection.operation, tool.operation);
        expect(
          projection.schema.toJson(),
          tool.schema.toJson(),
          reason: tool.name,
        );
      }
    },
  );

  test(
    'service ownership and lifetime policies keep separate ledgers explicit',
    () {
      expect(Operation.status.descriptor.createsLease, isTrue);
      expect(Operation.status.descriptor.stampsAgentActivity, isFalse);
      expect(Operation.status.descriptor.leaseBusy, isFalse);
      for (final operation in [
        Operation.securityAttachDesktop,
        Operation.securityDetachDesktop,
        Operation.securityDecide,
        Operation.securityAllowImportRoot,
        Operation.serviceStopIfIdle,
      ]) {
        expect(operation.descriptor.scope, OperationScope.service);
        expect(operation.descriptor.createsLease, isFalse);
        expect(operation.descriptor.stampsAgentActivity, isFalse);
        expect(operation.descriptor.leaseBusy, isTrue);
      }
      expect(
        Operation.answerStream.descriptor.response,
        ResponseShape.answerStream,
      );
      expect(
        Operation.googleSignIn.descriptor.response,
        ResponseShape.signInStream,
      );
      expect(
        Operation.googleAddAccount.descriptor.response,
        ResponseShape.signInStream,
      );
      expect(
        Operation.meetingsCancelGeneration.descriptor.requiresHelper,
        isFalse,
      );
      expect(
        Operation.meetingsCancelSummary.descriptor.requiresHelper,
        isFalse,
      );
      expect(Operation.meetingsCancelEnhance.descriptor.requiresHelper, isTrue);
      expect(
        Operation.sourcesImport.descriptor.approval,
        ApprovalPolicy.desktop,
      );
    },
  );

  for (final operation in Operation.values) {
    test('${operation.wire} decodes a typed immutable request', () {
      final raw = {
        ...minimal(operation),
        'additive_field': <String, dynamic>{
          'nested': [1, null, 1.0],
        },
      };
      final request = decodeOperationRequest(operation, raw);
      expect(request.operation, operation);
      expect(
        request.runtimeType.toString(),
        '${operation.name[0].toUpperCase()}${operation.name.substring(1)}Request',
      );
      expect(
        request.context.rawArgumentsDigest,
        legacy.requestArgumentsDigest(raw),
      );
      expect(request.context.rawArgumentsDigest, requestArgumentsDigest(raw));
      (raw['additive_field'] as Map)['nested'] = 'mutated';
      expect((request.rawArguments['additive_field'] as Map)['nested'], [
        1,
        null,
        1.0,
      ]);
      expect(
        () => request.rawArguments['other'] = true,
        throwsUnsupportedError,
      );
      expect(
        () => (request.rawArguments['additive_field'] as Map)['nested'] = null,
        throwsUnsupportedError,
      );
    });
    test(
      '${operation.wire} rejects malformed declared fields before admission',
      () {
        for (final field in operation.descriptor.arguments.fields) {
          if ([
            ArgumentKind.trueSwitch,
            ArgumentKind.falseSwitch,
          ].contains(field.kind)) {
            continue;
          }
          final raw = {
            ...minimal(operation),
            field.name: field.kind == ArgumentKind.integer ? 'bad' : 42,
          };
          expect(
            () => decodeOperationRequest(operation, raw),
            throwsA(invalid),
            reason: field.name,
          );
        }
      },
    );
  }

  test('envelope errors are stable invalidArgument and never TypeError', () {
    for (final field in [
      'requestId',
      'conversation',
      'workspace_epoch',
      'idempotency_key',
    ]) {
      expect(
        () => decodeOperationRequest(Operation.notesSave, {
          'title': 't',
          'body': 'b',
          field: 42,
        }),
        throwsA(invalid),
      );
    }
    for (final key in ['', 'x' * 257]) {
      expect(
        () => decodeOperationRequest(Operation.notesSave, {
          'title': 't',
          'body': 'b',
          'idempotency_key': key,
        }),
        throwsA(invalid),
      );
    }
    expect(
      () =>
          decodeOperationRequest(Operation.status, {'idempotency_key': 'key'}),
      throwsA(invalid),
    );
    expect(
      () => decodeOperationRequest(Operation.status, {'extra': double.nan}),
      throwsA(invalid),
    );
    expect(
      () => decodeOperationRequest(Operation.status, {
        'extra': <Object, Object>{1: 'bad'},
      }),
      throwsA(invalid),
    );
    expect(
      () => decodeOperationRequest(Operation.status, {'extra': Object()}),
      throwsA(invalid),
    );
  });

  test(
    'raw identity precedes defaults and preserves unknown fields and numbers',
    () {
      final base = {'title': 't', 'text': 'body'};
      final missing =
          decodeOperationRequest(Operation.sourcesImport, base)
              as SourcesImportRequest;
      final explicit =
          decodeOperationRequest(Operation.sourcesImport, {
                ...base,
                'mime': 'text/plain',
              })
              as SourcesImportRequest;
      expect(missing.mime, explicit.mime);
      expect(
        missing.context.rawArgumentsDigest,
        isNot(explicit.context.rawArgumentsDigest),
      );
      expect(
        missing.context.rawArgumentsDigest,
        decodeOperationRequest(Operation.sourcesImport, {
          ...base,
          'mime': null,
        }).context.rawArgumentsDigest,
      );
      expect(
        decodeOperationRequest(Operation.status, {
          'extra': 1,
        }).context.rawArgumentsDigest,
        isNot(
          decodeOperationRequest(Operation.status, {
            'extra': 1.0,
          }).context.rawArgumentsDigest,
        ),
      );
      final keyed = decodeOperationRequest(Operation.notesSave, {
        'title': 't',
        'body': 'b',
        'requestId': 'request',
        'conversation': 'chat',
        'workspace_epoch': 'epoch',
        'idempotency_key': 'key',
      });
      expect(keyed.context.requestId, 'request');
      expect(keyed.context.conversation, 'chat');
      expect(keyed.context.workspaceEpoch, 'epoch');
      expect(keyed.context.idempotencyKey, 'key');
      expect(
        keyed.context.rawArgumentsDigest,
        legacy.requestArgumentsDigest({'title': 't', 'body': 'b'}),
      );
    },
  );

  test(
    'task editing preserves absent, null and explicitly supplied details',
    () {
      final absent =
          decodeOperationRequest(Operation.meetingsEditTask, {
                'id': 1,
                'status': 'completed',
              })
              as MeetingsEditTaskRequest;
      expect(absent.editsDetails, isFalse);
      final clear =
          decodeOperationRequest(Operation.meetingsEditTask, {
                'id': 1,
                'task': null,
                'owner': null,
                'due': null,
              })
              as MeetingsEditTaskRequest;
      expect(
        clear.hasTask && clear.hasOwner && clear.hasDue && clear.editsDetails,
        isTrue,
      );
      expect([clear.task, clear.owner, clear.due], everyElement(isNull));
      final edit =
          decodeOperationRequest(Operation.meetingsEditTask, {
                'id': 1,
                'task': 'follow up',
                'owner': 'Alex',
                'due': 'Friday',
              })
              as MeetingsEditTaskRequest;
      expect(
        [edit.task, edit.owner, edit.due],
        ['follow up', 'Alex', 'Friday'],
      );
    },
  );

  test('legacy boolean switches retain == true and != false behavior', () {
    final request =
        decodeOperationRequest(Operation.sourcesImport, {
              'title': 't',
              'text': 'b',
              'locallyEdited': 'yes',
              'index': 0,
            })
            as SourcesImportRequest;
    expect(request.locallyEdited, isFalse);
    expect(request.index, isTrue);
    final explicit =
        decodeOperationRequest(Operation.sourcesImport, {
              'title': 't',
              'text': 'b',
              'locallyEdited': true,
              'index': false,
            })
            as SourcesImportRequest;
    expect(explicit.locallyEdited, isTrue);
    expect(explicit.index, isFalse);
  });

  test(
    'conditional arguments and bounded preparation inputs are validated',
    () {
      expect(
        () => decodeOperationRequest(Operation.googleConfigure, {}),
        throwsA(invalid),
      );
      expect(
        (decodeOperationRequest(Operation.googleConfigure, {
                  'provider': 'granola',
                })
                as GoogleConfigureRequest)
            .path,
        isNull,
      );
      expect(
        (decodeOperationRequest(Operation.googleConfigure, {
                  'provider': 'google',
                })
                as GoogleConfigureRequest)
            .path,
        isNull,
      );
      for (final args in [
        {'provider': 'unknown'},
        {'provider': 'unknown', 'path': 'credentials'},
        {'provider': 'google', 'path': 'credentials'},
        {'provider': 'granola', 'path': 'credentials'},
      ]) {
        expect(
          () => decodeOperationRequest(Operation.googleConfigure, args),
          throwsA(invalid),
        );
      }
      expect(
        () => decodeOperationRequest(Operation.modelsRegister, {
          'kind': 'query-detection',
          'path': 'model',
          'backend': 'raw_query_jsonl_v1',
        }),
        throwsA(invalid),
      );
      for (final sources in [
        <String>[],
        ['duplicate', 'duplicate'],
        List.filled(101, 'source'),
      ]) {
        expect(
          () => decodeOperationRequest(Operation.meetingsPrepare, {
            'id': 1,
            'source_ids': sources,
          }),
          throwsA(invalid),
        );
      }
      expect(
        () => decodeOperationRequest(Operation.sourcesSearch, {
          'query': 'q',
          'limit': 101,
        }),
        throwsA(invalid),
      );
      expect(
        () => decodeOperationRequest(Operation.googleDriveFiles, {
          'modifiedAfter': 'invalid',
        }),
        throwsA(invalid),
      );
      expect(
        (decodeOperationRequest(Operation.googleDriveFiles, {
                  'modifiedAfter': '2026-10-21T12:00:00Z',
                })
                as GoogleDriveFilesRequest)
            .modifiedAfter,
        DateTime.utc(2026, 10, 21, 12),
      );
    },
  );

  test(
    'legacy artifact aliases and private kinds stay accepted by service decoder',
    () {
      for (final kind in [
        'summary',
        'actions',
        'action_items',
        'questions',
        'enhanced_notes',
      ]) {
        expect(
          (decodeOperationRequest(Operation.meetingsGenerate, {
                    'id': 1,
                    'kind': kind,
                  })
                  as MeetingsGenerateRequest)
              .kind,
          kind,
        );
      }
      expect(
        (decodeOperationRequest(Operation.meetingsCancelGeneration, {'id': 1})
                as MeetingsCancelGenerationRequest)
            .kind,
        isNull,
      );
      final cancel =
          decodeOperationRequest(Operation.meetingsCancelEnhance, {
                'id': 1,
                'request_id': 'target',
                'requestId': 'cancel',
              })
              as MeetingsCancelEnhanceRequest;
      expect(cancel.targetRequestId, 'target');
      expect(cancel.context.requestId, 'cancel');
    },
  );

  test(
    'nested graph inputs are typed and immutable, malformed entries are rejected',
    () {
      final graph =
          decodeOperationRequest(Operation.graphSave, {
                'identity': 'model',
                'sources': [
                  {'id': 's', 'revision': 2, 'content': 'body'},
                ],
                'vectors': {
                  's': [1, 2.0],
                },
                'points': {
                  's': [1, 2, 3],
                },
                'clusters': [
                  {
                    'label': 'c',
                    'center_proj_x': 1,
                    'center_proj_y': 2,
                    'radius': 3,
                  },
                ],
              })
              as GraphSaveRequest;
      expect(graph.sources.single.id, 's');
      expect(graph.sources.single.revision, 2);
      expect(graph.vectors['s'], [1.0, 2.0]);
      expect(graph.points['s']!.x, 1.0);
      expect(graph.clusters.single.radius, 3.0);
      expect(() => graph.sources.clear(), throwsUnsupportedError);
      expect(
        () => graph.sources.single.projection['id'] = 'changed',
        throwsUnsupportedError,
      );
      expect(() => graph.vectors['s']!.add(3), throwsUnsupportedError);
      for (final bad in [
        {
          'sources': [
            {'id': 1},
          ],
        },
        {
          'vectors': {
            's': ['bad'],
          },
        },
        {
          'points': {
            's': [1, 2],
          },
        },
        {
          'clusters': [
            {'label': 3},
          ],
        },
      ]) {
        expect(
          () => decodeOperationRequest(Operation.graphSave, {
            ...minimal(Operation.graphSave),
            ...bad,
          }),
          throwsA(invalid),
        );
      }
    },
  );
}
