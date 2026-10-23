import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:foresight_core/desktop.dart';
import '../features/chat/chat_controller.dart';
import '../features/integrations/integrations_controller.dart';
import '../features/meetings/meetings_controller.dart';
import '../features/onboarding/onboarding_controller.dart';
import '../features/settings/settings_controller.dart';
import '../features/sources/sources_controller.dart';
import 'feature_bridges.dart';
import 'ports.dart';
import 'workspace_tab.dart';

/// Typed access for workflow fixtures while features retain their public ports.
/// Production composition never discovers features through this interface.
@visibleForTesting
abstract interface class WorkspaceTestAccess
    implements
        FeatureHost,
        WorkspaceNavigation,
        OperationGate,
        WorkspaceLifecycle {
  DesktopConnection get d;
  SourcesController get sourceFeature;
  MeetingsController get meetingFeature;
  ChatController get chatFeature;
  SettingsController get settingsFeature;
  IntegrationsController get integrationFeature;
  OnboardingController get onboardingFeature;
  MeetingPortsBridge get meetingPorts;
  PreferenceCommands get preferenceCommands;
  OnboardingActivity get onboardingActivity;
  WorkspaceTab get tab;
  set tab(WorkspaceTab value);
  set busy(bool value);
  set error(String value);
  Timer? get serviceUiTimer;
  @override
  ValueNotifier<int> get serviceUiRevision;
}
