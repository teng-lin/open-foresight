export '../features/settings/ports.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:foresight_core/desktop.dart';

import '../commands.dart';
import '../desktop_environment.dart';
import 'workspace_tab.dart';

export '../features/integrations/ports.dart';
export '../features/sources/ports.dart';

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
