import '../operations.dart';
import 'request_context.dart';
import '../operation_argument_schema.dart';

class GoogleStatusRequest extends OperationRequest {
  GoogleStatusRequest._(super.context);
  @override
  Operation get operation => Operation.googleStatus;
  factory GoogleStatusRequest.decode(OperationRequestContext context) {
    return GoogleStatusRequest._(context);
  }
}

class GoogleConfigureRequest extends OperationRequest {
  GoogleConfigureRequest._(
    super.context,
    this.provider,
    this.path,
    this.checkOnly,
  );
  final String? provider;
  final String? path;
  final bool checkOnly;
  @override
  Operation get operation => Operation.googleConfigure;
  factory GoogleConfigureRequest.decode(OperationRequestContext context) {
    final values = Operation.googleConfigure.descriptor.arguments.decode(
      context.rawArguments,
    );
    final provider = values.value<String?>('provider');
    final path = values.value<String?>('path');
    final checkOnly = values.value<bool>('checkOnly');
    if (provider != null && provider != 'google' && provider != 'granola') {
      invalidArgument('provider', 'must be google or granola');
    }
    if (provider == null && path == null) {
      invalidArgument('path', 'is required unless provider is specified');
    }
    if (provider != null && path != null) {
      invalidArgument('path', 'cannot be combined with provider');
    }
    if (checkOnly && provider != 'google') {
      invalidArgument('checkOnly', 'requires provider google');
    }
    return GoogleConfigureRequest._(
      context,
      values.value<String?>("provider"),
      values.value<String?>("path"),
      checkOnly,
    );
  }
}

class GoogleCompleteSignInRequest extends OperationRequest {
  GoogleCompleteSignInRequest._(super.context, this.url, this.manual);
  final String url;
  final bool manual;
  @override
  Operation get operation => Operation.googleCompleteSignIn;
  factory GoogleCompleteSignInRequest.decode(OperationRequestContext context) {
    final values = Operation.googleCompleteSignIn.descriptor.arguments.decode(
      context.rawArguments,
    );
    return GoogleCompleteSignInRequest._(
      context,
      values.value<String>("url"),
      values.value<bool>("manual"),
    );
  }
}

class GoogleCancelSignInRequest extends OperationRequest {
  GoogleCancelSignInRequest._(super.context);
  @override
  Operation get operation => Operation.googleCancelSignIn;
  factory GoogleCancelSignInRequest.decode(OperationRequestContext context) {
    return GoogleCancelSignInRequest._(context);
  }
}

class GoogleDisconnectRequest extends OperationRequest {
  GoogleDisconnectRequest._(super.context);
  @override
  Operation get operation => Operation.googleDisconnect;
  factory GoogleDisconnectRequest.decode(OperationRequestContext context) {
    return GoogleDisconnectRequest._(context);
  }
}

class GoogleSwitchAccountRequest extends OperationRequest {
  GoogleSwitchAccountRequest._(super.context, this.id);
  final String id;
  @override
  Operation get operation => Operation.googleSwitchAccount;
  factory GoogleSwitchAccountRequest.decode(OperationRequestContext context) {
    final values = Operation.googleSwitchAccount.descriptor.arguments.decode(
      context.rawArguments,
    );
    return GoogleSwitchAccountRequest._(context, values.value<String>("id"));
  }
}

class GoogleSignOutAccountRequest extends OperationRequest {
  GoogleSignOutAccountRequest._(super.context, this.id);
  final String id;
  @override
  Operation get operation => Operation.googleSignOutAccount;
  factory GoogleSignOutAccountRequest.decode(OperationRequestContext context) {
    final values = Operation.googleSignOutAccount.descriptor.arguments.decode(
      context.rawArguments,
    );
    return GoogleSignOutAccountRequest._(context, values.value<String>("id"));
  }
}

class GoogleDriveFilesRequest extends OperationRequest {
  GoogleDriveFilesRequest._(
    super.context,
    this.parent,
    this.query,
    this.modifiedAfter,
  );
  final String? parent;
  final String query;
  final DateTime? modifiedAfter;
  @override
  Operation get operation => Operation.googleDriveFiles;
  factory GoogleDriveFilesRequest.decode(OperationRequestContext context) {
    final values = Operation.googleDriveFiles.descriptor.arguments.decode(
      context.rawArguments,
    );
    return GoogleDriveFilesRequest._(
      context,
      values.value<String?>("parent"),
      values.value<String>("query"),
      values.value<DateTime?>("modifiedAfter"),
    );
  }
}

class GoogleImportFileRequest extends OperationRequest {
  GoogleImportFileRequest._(super.context, this.id);
  final String id;
  @override
  Operation get operation => Operation.googleImportFile;
  factory GoogleImportFileRequest.decode(OperationRequestContext context) {
    final values = Operation.googleImportFile.descriptor.arguments.decode(
      context.rawArguments,
    );
    return GoogleImportFileRequest._(context, values.value<String>("id"));
  }
}

class GoogleImportFolderRequest extends OperationRequest {
  GoogleImportFolderRequest._(super.context, this.id);
  final String id;
  @override
  Operation get operation => Operation.googleImportFolder;
  factory GoogleImportFolderRequest.decode(OperationRequestContext context) {
    final values = Operation.googleImportFolder.descriptor.arguments.decode(
      context.rawArguments,
    );
    return GoogleImportFolderRequest._(context, values.value<String>("id"));
  }
}

class GoogleImportYearRequest extends OperationRequest {
  GoogleImportYearRequest._(super.context);
  @override
  Operation get operation => Operation.googleImportYear;
  factory GoogleImportYearRequest.decode(OperationRequestContext context) {
    return GoogleImportYearRequest._(context);
  }
}

class GoogleRefreshRequest extends OperationRequest {
  GoogleRefreshRequest._(super.context);
  @override
  Operation get operation => Operation.googleRefresh;
  factory GoogleRefreshRequest.decode(OperationRequestContext context) {
    return GoogleRefreshRequest._(context);
  }
}

class GoogleCalendarRequest extends OperationRequest {
  GoogleCalendarRequest._(super.context);
  @override
  Operation get operation => Operation.googleCalendar;
  factory GoogleCalendarRequest.decode(OperationRequestContext context) {
    return GoogleCalendarRequest._(context);
  }
}

class GoogleAttachmentsRequest extends OperationRequest {
  GoogleAttachmentsRequest._(super.context, this.id);
  final int id;
  @override
  Operation get operation => Operation.googleAttachments;
  factory GoogleAttachmentsRequest.decode(OperationRequestContext context) {
    final values = Operation.googleAttachments.descriptor.arguments.decode(
      context.rawArguments,
    );
    return GoogleAttachmentsRequest._(context, values.value<int>("id"));
  }
}

class GoogleSignInRequest extends OperationRequest {
  GoogleSignInRequest._(super.context);
  @override
  Operation get operation => Operation.googleSignIn;
  factory GoogleSignInRequest.decode(OperationRequestContext context) {
    return GoogleSignInRequest._(context);
  }
}

class GoogleAddAccountRequest extends OperationRequest {
  GoogleAddAccountRequest._(super.context);
  @override
  Operation get operation => Operation.googleAddAccount;
  factory GoogleAddAccountRequest.decode(OperationRequestContext context) {
    return GoogleAddAccountRequest._(context);
  }
}
