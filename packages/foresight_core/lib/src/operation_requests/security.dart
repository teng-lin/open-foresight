import '../operations.dart';
import 'request_context.dart';

class SecurityAttachDesktopRequest extends OperationRequest {
  SecurityAttachDesktopRequest._(super.context, this.token, this.visible);
  final String token;
  final bool visible;
  @override
  Operation get operation => Operation.securityAttachDesktop;
  factory SecurityAttachDesktopRequest.decode(OperationRequestContext context) {
    final values = Operation.securityAttachDesktop.descriptor.arguments.decode(
      context.rawArguments,
    );
    return SecurityAttachDesktopRequest._(
      context,
      values.value<String>("token"),
      values.value<bool>('visible'),
    );
  }
}

class SecurityDetachDesktopRequest extends OperationRequest {
  SecurityDetachDesktopRequest._(super.context);
  @override
  Operation get operation => Operation.securityDetachDesktop;
  factory SecurityDetachDesktopRequest.decode(OperationRequestContext context) {
    return SecurityDetachDesktopRequest._(context);
  }
}

class SecurityDesktopVisibilityRequest extends OperationRequest {
  SecurityDesktopVisibilityRequest._(super.context, this.visible);
  final bool visible;
  @override
  Operation get operation => Operation.securityDesktopVisibility;
  factory SecurityDesktopVisibilityRequest.decode(
    OperationRequestContext context,
  ) {
    final values = Operation.securityDesktopVisibility.descriptor.arguments
        .decode(context.rawArguments);
    return SecurityDesktopVisibilityRequest._(
      context,
      values.value<bool>('visible'),
    );
  }
}

class SecurityDecideRequest extends OperationRequest {
  SecurityDecideRequest._(super.context, this.approvalId, this.allow);
  final String approvalId;
  final bool allow;
  @override
  Operation get operation => Operation.securityDecide;
  factory SecurityDecideRequest.decode(OperationRequestContext context) {
    final values = Operation.securityDecide.descriptor.arguments.decode(
      context.rawArguments,
    );
    return SecurityDecideRequest._(
      context,
      values.value<String>("approval_id"),
      values.value<bool>("allow"),
    );
  }
}

class SecurityAllowImportRootRequest extends OperationRequest {
  SecurityAllowImportRootRequest._(super.context, this.path);
  final String path;
  @override
  Operation get operation => Operation.securityAllowImportRoot;
  factory SecurityAllowImportRootRequest.decode(
    OperationRequestContext context,
  ) {
    final values = Operation.securityAllowImportRoot.descriptor.arguments
        .decode(context.rawArguments);
    return SecurityAllowImportRootRequest._(
      context,
      values.value<String>("path"),
    );
  }
}
