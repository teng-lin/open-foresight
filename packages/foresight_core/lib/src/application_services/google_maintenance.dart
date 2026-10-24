import 'dart:async';
import 'dart:io';

import '../domain.dart';
import '../google_auth.dart';
import '../google_connections.dart';
import '../operation_registry.dart';
import '../operation_requests.dart';
import '../operations.dart';
import '../persistence/meeting_queries.dart';
import '../platform_services.dart';
import '../rpc_error.dart';
import 'workspace_admin.dart';

/// Account/network maintenance has its own owner. It does not reserve the model
/// or pin service idle exit merely because a network request or timer exists.
final class GoogleMaintenance implements WorkspaceAccountCleanup {
  GoogleMaintenance({
    required this.domain,
    required this.auth,
    required this.meetings,
    required this.changed,
  });

  final Domain domain;
  final GoogleAuth auth;
  final MeetingQueries meetings;
  final void Function() changed;
  GoogleConnections? _connections;
  Timer? _timer;
  bool _closed = false, _started = false, _busy = false;
  String? _signInOwner;
  Future<void>? _closing;

  bool get busy => _busy;
  GoogleConnections get connections =>
      _connections ??
      (throw StateError('Google maintenance is not initialized'));

  /// Composition calls this explicitly; reading status never initializes tables
  /// or repairs data. Historical repair belongs to the ordered Store migration.
  void initialize() {
    if (_closed) throw StateError('Google maintenance is closed');
    _connections ??= GoogleConnections(domain, auth);
  }

  Map<String, Object?> get state => {
    'connected': auth.connected,
    'syncing': _busy || (_connections?.syncing ?? false),
    'email': auth.email,
    'displayName': auth.displayName,
    'photoUrl': auth.photoUrl,
    'accounts': [
      for (final account in auth.accounts)
        {
          'id': account.id,
          'email': account.email,
          'displayName': account.displayName,
          'photoUrl': account.photoUrl,
          'current': account.current,
        },
    ],
    'account': auth.account,
    'configured': auth.configured,
    'provider': auth.viaGranola ? 'granola' : 'google',
    'driveAvailable': !auth.viaGranola,
    'signingIn': auth.signingIn,
    'loadError': auth.loadError,
    'lastRefresh': _connections?.lastCompletedRefreshMs ?? 0,
  };

  void _notify() {
    if (!_closed) changed();
  }

  void start() {
    initialize();
    if (_started) return;
    _started = true;
    unawaited(restoreProfile());
    _timer = Timer.periodic(
      const Duration(minutes: 1),
      (_) => unawaited(maintain()),
    );
  }

  Future<void> restoreProfile() async {
    try {
      await auth.retryCredentialCleanup();
      if (auth.loadError.startsWith('Google credential cleanup failed')) {
        auth.loadError = '';
        _notify();
      }
    } catch (_) {
      auth.loadError =
          'Google credential cleanup failed; will retry automatically';
      stderr.writeln(auth.loadError);
      _notify();
    }
    try {
      final previousName = auth.displayName, previousPhoto = auth.photoUrl;
      await auth.refreshProfile();
      if (previousName != auth.displayName || previousPhoto != auth.photoUrl) {
        _notify();
      }
    } catch (_) {
      stderr.writeln('Google profile could not be refreshed; will retry.');
    }
  }

  Future<void> maintain() async {
    if (_closed || _busy) return;
    _busy = true;
    try {
      await restoreProfile();
      if (!auth.connected) return;
      await connections.reminders(domain.clock.now(), (message) async {
        await platformNotification('Open Foresight', message);
      });
      final minutes = auth.viaGranola
          ? int.tryParse(
                  domain.store.preference(
                    'granolaCalendarRefreshMinutes',
                    '10',
                  ),
                ) ??
                10
          : (int.tryParse(domain.store.preference('googleRefreshHours', '4')) ??
                    4) *
                60;
      if (!domain.sourcesPaused &&
          domain.clock.now().millisecondsSinceEpoch -
                  connections.lastCompletedRefreshMs >=
              minutes * 60000) {
        await connections.refresh();
      }
      _notify();
    } catch (error) {
      stderr.writeln('Google maintenance: $error');
    } finally {
      _busy = false;
      _notify();
    }
  }

  Stream<Object?> signIn(String owner, {bool addAccount = false}) async* {
    if (_signInOwner != null) {
      throw RpcError(RpcErrorCode.busy, 'Google sign-in is already open');
    }
    _signInOwner = owner;
    final invitation = Completer<Uri>();
    final signedIn = (addAccount ? auth.addAccount : auth.signIn)((uri) async {
      invitation.complete(uri);
      _notify();
    });
    unawaited(
      signedIn.catchError((Object error, StackTrace stack) {
        if (!invitation.isCompleted) invitation.completeError(error, stack);
      }),
    );
    try {
      yield {'authorization_url': (await invitation.future).toString()};
      await signedIn;
      yield state;
    } finally {
      cancelSignIn(owner);
      await signedIn.catchError((Object _) {});
      if (_signInOwner == owner) _signInOwner = null;
      _notify();
    }
  }

  void cancelSignIn(String owner) {
    if (_signInOwner == owner) auth.cancelSignIn();
  }

  @override
  void forgetWorkspaceAccounts() {
    _connections?.close();
    _connections = null;
    // Forget clears local credentials synchronously. Remote revocation does not
    // hold workspace admission, but failures remain observed and actionable.
    unawaited(
      Future<void>.sync(auth.forget).catchError((Object error) {
        stderr.writeln('Google credential cleanup: $error');
        auth.loadError =
            'Google credential cleanup failed; will retry automatically';
        _notify();
      }),
    );
    initialize();
  }

  /// Stop scheduling before the other application owners drain. Authorization
  /// closes later at the original shutdown boundary, through [close].
  void stop() {
    if (_closed) return;
    _closed = true;
    _timer?.cancel();
    _connections?.close();
  }

  Future<void> close() => _closing ??= Future.sync(() {
    stop();
    return auth.close();
  });

  List<OperationHandler> get handlers => [
    TypedOperationHandler<GoogleStatusRequest>(
      Operation.googleStatus,
      (request, {current}) => state,
    ),
    TypedOperationHandler<GoogleConfigureRequest>(Operation.googleConfigure, (
      request, {
      current,
    }) async {
      if (request.provider == 'granola') {
        await auth.configureGranola();
      } else if (request.provider == 'google') {
        await auth.configureGoogle();
      } else {
        await auth.configure(File(request.path!));
      }
      return state;
    }),
    TypedOperationHandler<GoogleCompleteSignInRequest>(
      Operation.googleCompleteSignIn,
      (request, {current}) {
        final uri = Uri.tryParse(request.url);
        if (uri == null) throw StateError('Invalid calendar sign-in return.');
        auth.completeGranolaSignIn(uri, manual: request.manual);
        return state;
      },
    ),
    TypedOperationHandler<GoogleCancelSignInRequest>(
      Operation.googleCancelSignIn,
      (request, {current}) {
        auth.cancelSignIn();
        return state;
      },
    ),
    TypedOperationHandler<GoogleSwitchAccountRequest>(
      Operation.googleSwitchAccount,
      (request, {current}) async {
        await auth.switchAccount(request.id);
        unawaited(restoreProfile());
        return state;
      },
    ),
    TypedOperationHandler<GoogleSignOutAccountRequest>(
      Operation.googleSignOutAccount,
      (request, {current}) async {
        await auth.signOutAccount(request.id);
        return state;
      },
    ),
    TypedOperationHandler<GoogleDisconnectRequest>(Operation.googleDisconnect, (
      request, {
      current,
    }) async {
      await auth.disconnect();
      return state;
    }),
    TypedOperationHandler<GoogleDriveFilesRequest>(
      Operation.googleDriveFiles,
      (request, {current}) => connections.driveFiles(
        parent: request.parent,
        query: request.query,
        modifiedAfter: request.modifiedAfter,
      ),
    ),
    TypedOperationHandler<GoogleImportFileRequest>(
      Operation.googleImportFile,
      (request, {current}) =>
          connections.importDriveFile(request.id, current: current),
    ),
    TypedOperationHandler<GoogleImportFolderRequest>(
      Operation.googleImportFolder,
      (request, {current}) =>
          connections.importDriveFolder(request.id, current: current),
    ),
    TypedOperationHandler<GoogleImportYearRequest>(
      Operation.googleImportYear,
      (request, {current}) => connections.importLastYear(current: current),
    ),
    TypedOperationHandler<GoogleRefreshRequest>(Operation.googleRefresh, (
      request, {
      current,
    }) async {
      await connections.refresh(current: current);
      return state;
    }),
    TypedOperationHandler<GoogleCalendarRequest>(
      Operation.googleCalendar,
      (request, {current}) => connections.syncCalendar(),
    ),
    TypedOperationHandler<GoogleAttachmentsRequest>(
      Operation.googleAttachments,
      (request, {current}) {
        if (meetings.revision(request.id) == null) {
          throw RpcError(
            RpcErrorCode.notFound,
            'Meeting not found: ${request.id}',
          );
        }
        return connections.importAttachments(request.id, current: current);
      },
    ),
  ];
}
