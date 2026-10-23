import 'package:flutter/widgets.dart';
import 'package:foresight_core/desktop.dart';

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
  Future<void> importMeetingAttachments(int meeting);
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

/// Outward capabilities supplied by Integrations, without its mutable clients.
abstract interface class IntegrationsPort
    implements IntegrationCommands, IntegrationActivity {}
