import 'package:clock/clock.dart';

import '../helper.dart';
import '../store.dart';

/// Source work shares the service's existing queue and cancellation owner.
abstract interface class SourceIndexPort {
  Store get store;
  Future<T> awaitCurrent<T>(Future<T> shared, bool Function()? current);
  Future<void> index(String id, {bool Function()? current});
  Future<void> delete(String id);
  Future<void> waitForSourceWork({bool Function()? current});
}

abstract interface class SourceOperationsPort implements SourceIndexPort {
  Helper get helper;
  bool get closed;
  int get workspaceGeneration;
  void checkWorkspace(int generation);
  void pauseSources();
  void resumeSources();
  Future<Map<String, List<double>>> graphEmbeddings(
    List<Map<String, Object?>> sources,
  );
}

abstract interface class GoogleWorkspacePort implements SourceIndexPort {
  Clock get clock;
  bool get sourcesPaused;
}

abstract interface class MeetingMutationPort {
  Store get store;
  Future<T> awaitCurrent<T>(Future<T> shared, bool Function()? current);
}

abstract interface class WorkspaceResetPort {
  void invalidateWorkspace();
  void cleanupClearedSources(List<String> sourceIds);
}
