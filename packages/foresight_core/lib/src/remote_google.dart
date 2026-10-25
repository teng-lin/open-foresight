import 'client_results.dart';
import 'operation_descriptors.dart';
import 'client_requests.dart';
import 'client_contract.dart';
import 'dart:async';
import 'dart:io';
import 'desktop_connection.dart';
import 'desktop_status.dart';
import 'operations.dart';
import 'client_command.dart';
import 'store_reader.dart';

/// Only the state, commands and sign-in stream consumed by account proxies.
abstract interface class RemoteGoogleOwner implements ClientCommandPort {
  Map<String, dynamic> get googleStatus;
  set googleStatus(Map<String, dynamic> value);
  StoreReader get store;
  @override
  Future<Object?> command(
    Operation operation, [
    Map<String, dynamic> args = const {},
  ]);
  Stream<Object?> googleSignIn(Operation operation);
}

class RemoteGoogleAuth implements GoogleAccount {
  final RemoteGoogleOwner domain;
  RemoteGoogleAuth(this.domain);
  @override
  bool get connected => domain.googleStatus['connected'] == true;
  @override
  String get email => domain.googleStatus['email'] as String? ?? '';
  @override
  String get displayName => domain.googleStatus['displayName'] as String? ?? '';
  @override
  String get photoUrl => domain.googleStatus['photoUrl'] as String? ?? '';
  @override
  String get account => domain.googleStatus['account'] as String? ?? '';
  @override
  String get loadError => domain.googleStatus['loadError'] as String? ?? '';
  @override
  bool get signingIn => domain.googleStatus['signingIn'] == true;
  @override
  bool get configured => domain.googleStatus['configured'] == true;
  Future<void> _accept(Future<GooglePresentation> response) async {
    domain.googleStatus = (await response).toWire();
  }

  @override
  Future<void> configure(File file) => _accept(
    googleConfigureDescriptor.send(
      domain,
      GoogleConfigureInput(path: WireField(file.path)),
    ),
  );
  @override
  Future<void> signIn(Future<void> Function(Uri) openBrowser) =>
      _signIn(openBrowser, Operation.googleSignIn);
  @override
  Future<void> addAccount(Future<void> Function(Uri) openBrowser) =>
      _signIn(openBrowser, Operation.googleAddAccount);
  @override
  List<GoogleAccountPresentation> get accounts =>
      GooglePresentation.fromWire(domain.googleStatus).accounts;
  @override
  Future<void> switchAccount(String id) => _accept(
    googleSwitchAccountDescriptor.send(
      domain,
      GoogleSwitchAccountInput(id: id),
    ),
  );
  @override
  Future<void> signOutAccount(String id) => _accept(
    googleSignOutAccountDescriptor.send(
      domain,
      GoogleSignOutAccountInput(id: id),
    ),
  );

  Future<void> _signIn(
    Future<void> Function(Uri) openBrowser,
    Operation operation,
  ) async {
    try {
      await for (final value in domain.googleSignIn(operation)) {
        final event =
            (operation == Operation.googleAddAccount
                    ? googleAddAccountDescriptor
                    : googleSignInDescriptor)
                .decodeResponse(value);
        if (event.authorizationUrl case final url?) {
          await openBrowser(Uri.parse(url));
        } else {
          domain.googleStatus = event.status!.toWire();
        }
      }
    } catch (_) {
      await _accept(
        googleCancelSignInDescriptor.send(
          domain,
          const GoogleCancelSignInInput(),
        ),
      );
      rethrow;
    }
  }

  @override
  void cancelSignIn() {
    unawaited(
      _accept(
        googleCancelSignInDescriptor.send(
          domain,
          const GoogleCancelSignInInput(),
        ),
      ),
    );
  }

  @override
  Future<void> disconnect() => _accept(
    googleDisconnectDescriptor.send(domain, const GoogleDisconnectInput()),
  );
  @override
  Future<void> close() async {}
}

class RemoteGoogleConnections implements ConnectedSources {
  final RemoteGoogleOwner domain;
  final GoogleAccount auth;
  RemoteGoogleConnections(this.domain, this.auth);
  @override
  int get lastCompletedRefreshMs =>
      domain.googleStatus['lastRefresh'] as int? ?? 0;
  @override
  Future<List<Map<String, dynamic>>> driveFiles({
    String? parent,
    String query = '',
    DateTime? modifiedAfter,
  }) async => [
    for (final file in await googleDriveFilesDescriptor.send(
      domain,
      GoogleDriveFilesInput(
        parent: WireField(parent),
        query: WireField(query),
        modifiedAfter: WireField(modifiedAfter?.toIso8601String()),
      ),
    ))
      file.toWire(),
  ];
  @override
  Future<void> importDriveFile(
    String fileId, {
    Map<String, dynamic>? metadata,
    bool preserveDeleted = false,
  }) async {
    await googleImportFileDescriptor.send(
      domain,
      GoogleImportFileInput(id: fileId),
    );
  }

  @override
  Future<void> importDriveFolder(
    String folderId, {
    bool refreshing = false,
  }) async {
    await googleImportFolderDescriptor.send(
      domain,
      GoogleImportFolderInput(id: folderId),
    );
  }

  @override
  Future<void> importLastYear() async {
    await googleImportYearDescriptor.send(domain, GoogleImportYearInput());
  }

  @override
  Future<void> syncCalendar({
    String calendarId = 'primary',
    DateTime? now,
  }) async {
    await googleCalendarDescriptor.send(domain, GoogleCalendarInput());
  }

  @override
  Future<void> refresh() async {
    await googleRefreshDescriptor.send(domain, GoogleRefreshInput());
  }

  @override
  Future<void> importAttachments(int meeting) async {
    await googleAttachmentsDescriptor.send(
      domain,
      GoogleAttachmentsInput(id: meeting),
    );
  }

  Future<void> reminders(
    DateTime now,
    Future<void> Function(String) deliver,
  ) async {} // Service timer owns delivery.
  void close() {}
}
