import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:foresight_core/desktop.dart';

import '../commands.dart';
import '../desktop_environment.dart';
import 'workspace_tab.dart';

/// Host capabilities shared by features, without access to other controllers.
/// [update] preserves the shell rebuild bridge while feature readers migrate.
abstract interface class FeatureHost {
  DesktopConnection get connection;
  BuildContext get context;
  bool get mounted;
  DesktopEnvironment get environment;
  ValueListenable<int> get serviceUiRevision;
  ValueListenable<List<double>> get captureVolumes;
  TickerProvider get vsync;
  Future<List<AudioDevice>> Function()? get deviceLoader;
  Future<void> Function(Uri) get sourceLinkOpener;
  AppCommands? get commands;
  void update(VoidCallback action);
}

abstract interface class WorkspaceNavigation {
  WorkspaceTab get selectedTab;
  void navigate(WorkspaceTab destination);
}

/// One workspace-wide gate, retaining nested operation and failure semantics.
abstract interface class OperationGate {
  bool get busy;
  String get error;
  void setError(String message);
  Future<void> run(Future<void> Function() action);
  void reportAsyncError(Object failure);
}

abstract interface class WorkspaceDialogs {
  bool rowsAreCurrent();

  /// Completes after the departing route has unmounted, so its caller can
  /// release input controllers without a live route retaining them.
  Future<T?> showInputDialog<T>({required WidgetBuilder builder});
}

abstract interface class WorkspaceLifecycle {
  bool get clearingWorkspace;
  void setClearingWorkspace(bool value);
  void resetWorkspaceViews();
  void serviceChanged();
}

abstract interface class PreferenceCommands {
  Future<void> preference(String key, String value);
}

// Outward feature contracts live here until their owner's 7B move. Dependants
// receive each required port separately; the host is not a feature locator.
abstract interface class MeetingActivity {
  int? get selectedMeetingId;
  int? get previewMeetingId;
  RecordingSnapshot? get recording;
  bool get meetingEnhancing;
  bool get systemAudioSetupReviewed;
  String get echoCancellationDescription;
}

abstract interface class MeetingCommands {
  Future<void> quickStart();
  void setSystemAudioSetupReviewed(bool reviewed);
}

abstract interface class OnboardingActivity {
  bool get active;
}

abstract interface class SettingsCommands implements PreferenceCommands {
  Future<void> chooseSpeech();
  Future<void> chooseGemma({bool firstRun = false, bool embeddingOnly = false});
  void showModelSetup(String kind);
  Widget gemmaSetup({
    bool firstRun = false,
    bool embeddingOnly = false,
    VoidCallback? onDone,
  });
  Widget speechSetup({VoidCallback? onDone});
}

abstract interface class ChatActivity {
  bool get asking;
  double get answerFontSize;
}

abstract interface class ChatCommands {
  void setAnswerFontSize(double value);
  void setQuestion(int? meetingScope, String text);
  Future<void> askQuestion({int? meetingScope});
  void citation(Map<String, Object?> citation);
  Widget chat({int? meetingScope, bool compact = false});
}

abstract interface class SourceCommands {
  Future<void> source(Map<String, Object?> source);
  Future<void> findLocalFiles({List<String>? roots});
  Future<void> import();
  Future<void> importFolder();
  Future<void> importUrl();
}

abstract interface class IntegrationCommands {
  Future<void> connectGoogle({bool addAccount = false});
  Future<void> connectGranolaCalendar();
  Future<void> disconnectGoogle();
  Future<void> addGoogleAccount();
  Future<void> switchGoogleAccount(String id);
  Future<void> signOutGoogleAccount(String id);
  void cancelGoogleSignIn();
  Future<void> refreshGoogle();
  Future<void> syncCalendar();
  Future<void> importLastYear();
  Future<void> chooseDrive({bool folder = false});
  Future<bool> ensureRecordingAccess();
  Future<bool> setupSystemAudioAccess({bool forRecording = false});
  Future<void> requestMicrophoneAccess();
  Future<void> refreshCaptureCapabilities();
  Future<void> refreshAudioDevices();
  Future<void> setNotifications(bool value);
  Future<void> setMeetingReminders(bool value);
  Future<void> setOpenAtLogin(bool value);
  Future<void> enableGlobalShortcuts();
  Future<void> disableGlobalShortcuts();
  Future<void> changeQuickShortcut();
  Future<void> notify(String message);
  Widget deviceChoice(bool playback);
}

/// Account facts use the immutable public status value, rather than exposing
/// the account client or connected-sources writer to another feature.
abstract interface class IntegrationActivity {
  GooglePresentation get googlePresentation;
  bool get driveAvailable;
  bool get googleSyncing;
  bool get granolaCalendar;
  int get lastCompletedRefreshMilliseconds;
  bool get openAtLogin;
  bool get notifications;
  bool get microphoneAuthorized;
  bool get systemAudioSetupComplete;
  String get googleState;
  String googleSyncStatus();
  String get loginState;
  String get globalShortcutState;
  String get audioDeviceState;
  String get notificationState;
  String get microphoneAccessLabel;
  String get systemAudioAccessLabel;
  String get captureCapabilityError;
}
