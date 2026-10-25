import 'dart:async';

import 'package:clock/clock.dart';

import '../generation_runtime_slot.dart';
import '../helper.dart';
import '../native.dart';
import '../store.dart';

/// Capture owns timers and recording resources; workspace state only revokes
/// stale callbacks. It does not need generation or helper mutation authority.
abstract interface class RecordingWorkspace {
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
abstract interface class ModelWorkspace {
  Store get store;
  Helper get helper;
  int get workspaceGeneration;
  GenerationRuntimeReplacement<NativeRuntime> get generationRuntimes;
  void schedulePendingSources();
}
