import 'operations.dart';
import 'dart:io';
import 'helper.dart';
import 'store.dart';
import 'google_auth.dart';

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

abstract interface class DesktopConnection {
  Store get store;
  Helper get helper;
  GenerationStatus? get generator;
  GenerationStatus get runtime;
  GoogleAccount get googleAuth;
  ConnectedSources get google;
  Map<String, dynamic> get capture;
  Map<String, dynamic> get googleStatus;
  bool get webSearchAvailable;
  bool get sourcesPaused;
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
