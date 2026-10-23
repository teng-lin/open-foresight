import 'agent_access.dart';
import 'operation_descriptor.dart';
import 'operation_requests.dart';
import 'rpc_error.dart';
import 'persistence/content_history.dart';
import 'dart:convert';

/// Capability admission applies before every dispatch, including bootstrap and
/// installer requests which deliberately do not create an application lease.
void enforceOperationCapability(
  AgentAccessGate access,
  Object client,
  OperationRequest request, {
  required bool verifiedDesktop,
  required bool desktopPinned,
}) {
  switch (request.operation.descriptor.capability) {
    case CapabilityPolicy.ordinary:
      return;
    case CapabilityPolicy.hostedRecording:
      if (!access.hasVisibleHost) {
        throw RpcError(
          RpcErrorCode.denied,
          'Recording requires an open desktop indicator',
          reason: RpcErrorReason.needsDesktop,
        );
      }
      return; // Also rechecked after asynchronous helper readiness.
    case CapabilityPolicy.desktopToken:
      if (!verifiedDesktop) {
        throw RpcError(
          RpcErrorCode.denied,
          'Only the verified desktop process can attach',
        );
      }
      if (request is SecurityAttachDesktopRequest &&
          verifiedDesktop &&
          request.token.isNotEmpty &&
          request.token == access.desktopToken) {
        return;
      }
      throw RpcError(RpcErrorCode.denied, 'Invalid desktop capability');
    case CapabilityPolicy.approvalHost:
      if (access.isHost(client) &&
          (access.hasVisibleHost ||
              request is SecurityDetachDesktopRequest ||
              request is SecurityDesktopVisibilityRequest)) {
        return;
      }
      throw RpcError(RpcErrorCode.denied, switch (request) {
        SecurityDecideRequest() =>
          'Only the visible desktop can approve requests',
        SecurityAllowImportRootRequest() =>
          'Only the desktop can select import folders',
        SecurityDesktopVisibilityRequest() =>
          'Only the desktop host can report window visibility',
        _ => 'Not the desktop approval connection',
      });
    case CapabilityPolicy.profileOwner:
      if (request is ServiceStopIfIdleRequest &&
          request.token != null &&
          request.token!.isNotEmpty &&
          request.token == access.desktopToken) {
        if (desktopPinned || access.hasHost) {
          throw RpcError(
            RpcErrorCode.busy,
            'Close the desktop before upgrading the application',
          );
        }
        return;
      }
  }
  throw RpcError(
    RpcErrorCode.denied,
    'Operation requires its declared owner capability',
  );
}

/// Bind an approval to the exact content about to be replaced. A later writer
/// invalidates it before dispatch instead of inheriting consent for new bytes.
String? replacementSnapshot(ContentHistory history, OperationRequest request) {
  final rows = switch (request) {
    NotesSaveRequest(:final id?) => history.row('notes', id),
    ArtifactsEditRequest(:final id) => history.row('artifacts', id),
    MeetingsNotesRequest(:final id) => history.row('meeting_notes', id),
    MeetingsEditTaskRequest(:final id) => history.row('meeting_tasks', id),
    MeetingsPrepareRequest(:final id) => history.meetingArtifacts(
      id,
      'preparation',
    ),
    MeetingsGenerateRequest(:final id, :final kind) => history.meetingArtifacts(
      id,
      kind,
    ),
    MeetingsEnhanceRequest(:final id) => [
      ...history
          .row('meeting_notes', id)
          .where((row) => row['enhanced_body'] != null),
      ...history.meetingArtifacts(id, 'enhanced_notes'),
    ],
    _ => <Map<String, Object?>>[],
  };
  return rows.isEmpty ? null : jsonEncode(rows);
}
