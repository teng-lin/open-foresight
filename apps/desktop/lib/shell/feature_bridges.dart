import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import '../desktop_environment.dart';
import '../commands.dart';
import 'package:foresight_core/desktop.dart';
import 'ports.dart';

/// Composition defers cyclic command dependencies until the command is used.
final class PreferenceCommandBridge implements PreferenceCommands {
  const PreferenceCommandBridge(this.write);
  final Future<void> Function(String, String) write;
  @override
  Future<void> preference(String key, String value) => write(key, value);
}

final class OnboardingActivityBridge implements OnboardingActivity {
  const OnboardingActivityBridge(this.readActive);
  final bool Function() readActive;
  @override
  bool get active => readActive();
}

final class MeetingPortsBridge implements MeetingActivity, MeetingCommands {
  const MeetingPortsBridge(this.activity, this.commands);
  final MeetingActivity Function() activity;
  final MeetingCommands Function() commands;
  @override
  int? get selectedMeetingId => activity().selectedMeetingId;
  @override
  int? get previewMeetingId => activity().previewMeetingId;
  @override
  RecordingSnapshot? get recording => activity().recording;
  @override
  bool get meetingEnhancing => activity().meetingEnhancing;
  @override
  bool get systemAudioSetupReviewed => activity().systemAudioSetupReviewed;
  @override
  String get echoCancellationDescription =>
      activity().echoCancellationDescription;
  @override
  Future<void> quickStart() => commands().quickStart();
  @override
  void setSystemAudioSetupReviewed(bool reviewed) =>
      commands().setSystemAudioSetupReviewed(reviewed);
}

/// Supplies host capabilities while routing presentation updates to one owner.
final class FeatureHostBridge implements FeatureHost {
  const FeatureHostBridge(this.host, this._update);
  final FeatureHost host;
  final void Function(VoidCallback) _update;
  @override
  void update(VoidCallback action) => _update(action);
  @override
  DesktopConnection get connection => host.connection;
  @override
  BuildContext get context => host.context;
  @override
  bool get mounted => host.mounted;
  @override
  DesktopEnvironment get environment => host.environment;
  @override
  ValueListenable<int> get serviceUiRevision => host.serviceUiRevision;
  @override
  ValueListenable<List<double>> get captureVolumes => host.captureVolumes;
  @override
  TickerProvider get vsync => host.vsync;
  @override
  Future<List<AudioDevice>> Function()? get deviceLoader => host.deviceLoader;
  @override
  Future<void> Function(Uri) get sourceLinkOpener => host.sourceLinkOpener;
  @override
  AppCommands? get commands => host.commands;
}
