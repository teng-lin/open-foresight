import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'agent_access.dart';
import 'operations.dart';
import 'operation_descriptor.dart';
import 'operation_registry.dart';
import 'operation_requests.dart';
import 'rpc_error.dart';
import 'service_lifetime.dart';

/// Per-request transport state; never retained by the dispatch metadata.
class ServiceRequestContext {
  const ServiceRequestContext(
    this.client,
    this.id, [
    this.lease,
    this.verifiedDesktop = false,
  ]);
  final Socket client;
  final int id;
  final ServiceRequestLease? lease;
  final bool verifiedDesktop;
}

/// Concrete service-only handler ownership. Request transport state is bound
/// per invocation; construction for ownership inspection has no side effects.
class ServiceOperationHandlers {
  ServiceOperationHandlers({
    required this.access,
    required this.desktopClients,
    required this.onAttached,
    required this.onDetached,
    required this.stopRecording,
    required this.preference,
    required this.setPreference,
    required this.stopIfIdle,
    required this.answerResults,
    required this.signInResults,
  });
  final AgentAccessGate access;
  final Set<Socket> desktopClients;
  final void Function() onAttached, onDetached;
  final Future<void> Function() stopRecording;
  final String Function(String key, String fallback) preference;
  final void Function(String key, String value) setPreference;
  final Future<void> Function(Socket, int, ServiceStopIfIdleRequest) stopIfIdle;
  final Stream<Object?> Function(AnswerStreamRequest, ServiceRequestLease)
  answerResults;
  final Stream<Object?> Function(
    ServiceRequestLease, {
    required bool addAccount,
  })
  signInResults;
  OperationRegistry registry([ServiceRequestContext? context]) =>
      OperationRegistry(OperationScope.service, [
        TypedOperationHandler<SecurityAttachDesktopRequest>(
          Operation.securityAttachDesktop,
          (request, {current}) {
            final client = context!.client;
            access.attach(
              client,
              request.token,
              verifiedDesktop: context.verifiedDesktop,
              visible: request.visible,
            );
            desktopClients.add(client);
            onAttached();
            return true;
          },
        ),
        TypedOperationHandler<SecurityDesktopVisibilityRequest>(
          Operation.securityDesktopVisibility,
          (request, {current}) {
            access.setVisible(context!.client, request.visible);
            if (!request.visible) {
              unawaited(
                stopRecording().catchError((Object error) {
                  stderr.writeln('Stop recording after desktop hidden: $error');
                }),
              );
            }
            return true;
          },
        ),
        TypedOperationHandler<SecurityDetachDesktopRequest>(
          Operation.securityDetachDesktop,
          (request, {current}) {
            final client = context!.client;
            if (!access.isHost(client)) {
              throw RpcError(
                RpcErrorCode.denied,
                'Not the desktop approval connection',
              );
            }
            access.detach(client);
            onDetached();
            unawaited(
              stopRecording().catchError((Object error) {
                stderr.writeln('Stop recording on desktop detach: $error');
              }),
            );
            return true;
          },
        ),
        TypedOperationHandler<SecurityDecideRequest>(Operation.securityDecide, (
          request, {
          current,
        }) {
          access.decide(context!.client, request.approvalId, request.allow);
          return true;
        }),
        TypedOperationHandler<SecurityAllowImportRootRequest>(
          Operation.securityAllowImportRoot,
          (request, {current}) {
            if (!access.isHost(context!.client)) {
              throw RpcError(
                RpcErrorCode.denied,
                'Only the desktop can select import folders',
              );
            }
            final root = Directory(request.path).resolveSymbolicLinksSync();
            final roots = (jsonDecode(preference('importRoots', '[]')) as List)
                .cast<String>();
            setPreference('importRoots', jsonEncode({...roots, root}.toList()));
            return true;
          },
        ),
        TypedOperationHandler<ServiceStopIfIdleRequest>(
          Operation.serviceStopIfIdle,
          (request, {current}) =>
              stopIfIdle(context!.client, context.id, request),
        ),
        TypedOperationHandler<AnswerStreamRequest>(
          Operation.answerStream,
          (request, {current}) => answerResults(request, context!.lease!),
        ),
        TypedOperationHandler<GoogleSignInRequest>(
          Operation.googleSignIn,
          (request, {current}) =>
              signInResults(context!.lease!, addAccount: false),
        ),
        TypedOperationHandler<GoogleAddAccountRequest>(
          Operation.googleAddAccount,
          (request, {current}) =>
              signInResults(context!.lease!, addAccount: true),
        ),
      ]);
}
