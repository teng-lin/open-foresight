import 'dart:async';

import 'package:clock/clock.dart';

import '../generation_runtime_slot.dart';
import '../helper.dart';
import '../native.dart';
import '../platform_services.dart' show RuntimeConfiguration;
import '../store.dart';

/// The owning service's immutable runtime snapshot, captured once at its
/// composition boundary and never re-read from process-wide configuration.
abstract interface class RuntimeConfigurationPort {
  RuntimeConfiguration get configuration;
}

/// Capture owns timers and recording resources; workspace state only revokes
/// stale callbacks. It does not need generation or helper mutation authority.
abstract interface class RecordingWorkspace
    implements RuntimeConfigurationPort {
  Store get store;
  Clock get clock;
  Timer Function(Duration, void Function()) get createTimer;
  int get workspaceGeneration;
  bool get closed;
}

/// A summary borrows the currently installed generation and checks its epoch;
/// generation adoption and retirement remain with their dedicated owner.
abstract interface class SummaryWorkspace {
  Store get store;
  Clock get clock;
  int get workspaceGeneration;
  NativeRuntime? get generator;
  void checkWorkspace(int generation);
  Future<void> index(String id, {bool Function()? current});
}

/// Registration adopts through the one runtime slot and uses the helper only
/// for embedding configuration. Other workspace controllers stay separate.
abstract interface class ModelWorkspace implements RuntimeConfigurationPort {
  Store get store;
  Helper get helper;
  int get workspaceGeneration;
  GenerationRuntimeReplacement<NativeRuntime> get generationRuntimes;
  void schedulePendingSources();
}
