import 'dart:async';
import 'dart:io';
import 'desktop_connection.dart';
import 'google_auth.dart';
import 'operations.dart';
import 'store_reader.dart';

/// Only the state, commands and sign-in stream consumed by account proxies.
abstract interface class RemoteGoogleOwner {
  Map<String, dynamic> get googleStatus;
  set googleStatus(Map<String, dynamic> value);
  StoreReader get store;
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
  GoogleClient? get client =>
      domain.googleStatus['configured'] == true ? GoogleClient('', '') : null;
  Future<void> _call(
    Operation operation, [
    Map<String, dynamic> a = const {},
  ]) async {
    domain.googleStatus = Map<String, dynamic>.from(
      await domain.command(operation, a) as Map,
    );
  }

  @override
  Future<void> configure(File file) =>
      _call(Operation.googleConfigure, {'path': file.path});
  @override
  Future<void> signIn(Future<void> Function(Uri) openBrowser) =>
      _signIn(openBrowser, Operation.googleSignIn);
  @override
  Future<void> addAccount(Future<void> Function(Uri) openBrowser) =>
      _signIn(openBrowser, Operation.googleAddAccount);
  @override
  List<Map<String, Object?>> get accounts =>
      (domain.googleStatus['accounts'] as List? ?? [])
          .map((value) => Map<String, Object?>.from(value as Map))
          .toList();
  @override
  Future<void> switchAccount(String id) =>
      _call(Operation.googleSwitchAccount, {'id': id});
  @override
  Future<void> signOutAccount(String id) =>
      _call(Operation.googleSignOutAccount, {'id': id});

  Future<void> _signIn(
    Future<void> Function(Uri) openBrowser,
    Operation operation,
  ) async {
    try {
      await for (final value in domain.googleSignIn(operation)) {
        final state = Map<String, dynamic>.from(value as Map);
        if (state['authorization_url'] is String) {
          await openBrowser(Uri.parse(state['authorization_url'] as String));
        } else {
          domain.googleStatus = state;
        }
      }
    } catch (_) {
      await _call(Operation.googleCancelSignIn);
      rethrow;
    }
  }

  @override
  void cancelSignIn() {
    unawaited(_call(Operation.googleCancelSignIn));
  }

  @override
  Future<void> disconnect() => _call(Operation.googleDisconnect);
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
  }) async =>
      (await domain.command(Operation.googleDriveFiles, {
                'parent': parent,
                'query': query,
                'modifiedAfter': modifiedAfter?.toIso8601String(),
              })
              as List)
          .map((v) => Map<String, dynamic>.from(v as Map))
          .toList();
  @override
  Future<void> importDriveFile(
    String fileId, {
    Map<String, dynamic>? metadata,
    bool preserveDeleted = false,
  }) async {
    await domain.command(Operation.googleImportFile, {'id': fileId});
  }

  @override
  Future<void> importDriveFolder(
    String folderId, {
    bool refreshing = false,
  }) async {
    await domain.command(Operation.googleImportFolder, {'id': folderId});
  }

  @override
  Future<void> importLastYear() async {
    await domain.command(Operation.googleImportYear);
  }

  @override
  Future<void> syncCalendar({
    String calendarId = 'primary',
    DateTime? now,
  }) async {
    await domain.command(Operation.googleCalendar);
  }

  @override
  Future<void> refresh() async {
    await domain.command(Operation.googleRefresh);
  }

  @override
  Future<void> importAttachments(int meeting) async {
    await domain.command(Operation.googleAttachments, {'id': meeting});
  }

  Future<void> reminders(
    DateTime now,
    Future<void> Function(String) deliver,
  ) async {} // Service timer owns delivery.
  void close() {}
}
