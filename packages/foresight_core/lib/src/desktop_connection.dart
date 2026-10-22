import 'operations.dart';
import 'dart:io';
import 'helper_status.dart';
import 'store_reader.dart';
import 'google_auth.dart';
import 'desktop_status.dart';

/// Additive typed access during the feature migration. Extensions keep existing
/// connection implementations and test doubles source compatible.
extension DesktopPresentation on DesktopConnection {
  CapturePresentation get capturePresentation =>
      CapturePresentation.fromWire(capture);
  GooglePresentation get googlePresentation =>
      GooglePresentation.fromWire(googleStatus);
}

extension GenerationPresentationValue on GenerationStatus {
  GenerationPresentation get presentation =>
      GenerationPresentation.fromWire(effectiveState);
}

/// Capabilities exposed to a desktop. Worker mutation and credentials stay in
/// the application service; proxies only implement these client operations.
abstract interface class GenerationStatus {
  Map<String, dynamic> get effectiveState;
  bool get generating;
  bool cancel({String? requestId});
  void close();
}

abstract interface class RecordingStatus {
  bool get finishing;
  bool get paused;
  Map<String, dynamic> get echoCancellationState;
  List<int> get sampleCounts;
  List<double> get peakVolumes;
  List<double> get currentVolumes;
  DateTime get lastAudioActivity;
  void dispose();
}

abstract interface class GoogleAccount {
  bool get connected;
  String get email;
  String get displayName;
  String get photoUrl;
  List<Map<String, Object?>> get accounts;
  Future<void> addAccount(Future<void> Function(Uri) openBrowser);
  Future<void> switchAccount(String id);
  Future<void> signOutAccount(String id);
  String get account;
  String get loadError;
  bool get signingIn;
  GoogleClient? get client;
  Future<void> configure(File file);
  Future<void> signIn(Future<void> Function(Uri) openBrowser);
  void cancelSignIn();
  Future<void> disconnect();
  Future<void> close();
}

abstract interface class ConnectedSources {
  int get lastCompletedRefreshMs;
  Future<List<Map<String, dynamic>>> driveFiles({
    String? parent,
    String query = '',
    DateTime? modifiedAfter,
  });
  Future<void> importDriveFile(
    String fileId, {
    Map<String, dynamic>? metadata,
    bool preserveDeleted = false,
  });
  Future<void> importDriveFolder(String folderId, {bool refreshing = false});
  Future<void> importLastYear();
  Future<void> syncCalendar({String calendarId = 'primary', DateTime? now});
  Future<void> refresh();
  Future<void> importAttachments(int meeting);
  List<Map<String, dynamic>> attachments(int meeting);
}

/// Optional high-frequency telemetry, independent of workspace changes.
abstract interface class CaptureLevelEvents {
  Stream<List<double>> get captureLevels;
}

abstract interface class DesktopConnection {
  StoreReader get store;
  HelperStatus get helper;
  DesktopModelAssets get modelAssets;
  Stream<void> get changes;

  /// Opaque identity of the currently adopted application-client session.
  /// Compare captured tokens with identical(). Every actual client adoption
  /// changes this token, even at the same endpoint and workspace epoch, and
  /// notifies [changes]. Ordinary data/status changes retain it. This is not a
  /// SQLite revision, connectivity guarantee or mutation authorization; callers
  /// also retain their own lifetime, workspace and request checks.
  Object get clientSessionGeneration;

  /// Prepare connection presentation/lifecycle. Completion does not certify
  /// helper readiness, which remains part of [helper]'s reported state.
  Future<void> initialize();
  Future<void> get closed;
  GenerationStatus? get generator;
  GenerationStatus get runtime;
  GoogleAccount get googleAuth;
  ConnectedSources get google;
  Map<String, dynamic> get capture;
  Map<String, dynamic> get googleStatus;
  bool get webSearchAvailable;
  bool get sourcesPaused;

  /// The workspace the desktop's views and the IDs they hold belong to.
  /// [command] sends it with edits by ID, so after a clear they fail instead
  /// of changing an unrelated item that reuses the ID.
  String? get workspaceEpoch;

  /// The service reports a cleared workspace that the views still predate.
  bool get workspaceReplaced;

  /// Moves [workspaceEpoch] to the service's current workspace. Call it only
  /// after dropping every view and draft that holds an ID from before.
  void adoptWorkspace();
  Future<Object?> command(
    Operation operation, [
    Map<String, dynamic> args = const {},
  ]);
  Future<Object?> commandCurrent(
    Operation operation,
    Map<String, dynamic> args,
    bool Function() current,
  );
  Future<void> index(String id);
  Future<void> delete(String id);
  Future<void> resume();
  void pauseSources();
  void resumeSources();
  Future<void> waitForSourceWork();
  Stream<String> askInConversation(
    String question,
    String conversation, {
    String? requestId,
    int? meetingId,
    bool Function()? current,
  });
  Stream<String> askWithWebInConversation(
    String question,
    String conversation, {
    String? requestId,
    int? meetingId,
    bool Function()? current,
  });
  Future<Map<String, List<double>>> graphEmbeddings(
    List<Map<String, Object?>> sources,
  );
  Future<void> enableDesktopApprovals(
    void Function(Map<String, dynamic>) events,
  );
  Future<void> disableDesktopApprovals();
  void close();
}

/// Only actual model download destinations, never database/profile identities.
final class DesktopModelAssets {
  final Directory generation, speech;
  const DesktopModelAssets({required this.generation, required this.speech});
}
