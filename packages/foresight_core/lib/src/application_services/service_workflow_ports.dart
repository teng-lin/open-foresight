import 'dart:async';

import 'package:clock/clock.dart';

import '../generated/transcript_index.pb.dart' as transcript;
import '../helper.dart';
import '../model_gate.dart';
import '../native.dart';
import '../store.dart';
import '../web_search.dart';

abstract interface class GenerationReadPort {
  Store get store;
  NativeRuntime? get generator;
}

/// Answer execution receives its existing persistence, retrieval and runtime
/// capabilities without retaining the service composition owner.
abstract interface class ConversationWorkspacePort
    implements GenerationReadPort {
  Helper get helper;
  bool get closed;
  bool get webSearchAvailable;
  int get workspaceGeneration;
  ModelGate get modelGate;
  void checkWorkspace(int generation);
  SearchCallbacks searchCallbacks();
}

abstract interface class MeetingGenerationPort implements GenerationReadPort {
  Clock get clock;
  int get workspaceGeneration;
  void checkWorkspace(int generation);
}

abstract interface class MeetingWorkflowPort implements MeetingGenerationPort {
  Future<void> index(String id, {bool Function()? current});
}

abstract interface class NoteEnhancementPort implements GenerationReadPort {
  Helper get helper;
  Clock get clock;
  Timer Function(Duration, void Function()) get createTimer;
  Future<NativeRuntime?> noteEnhancementService();
  Future<void> resetNoteEnhancementService();
}

abstract interface class RuntimeOperationsPort implements GenerationReadPort {
  Helper get helper;
  bool get sourcesPaused;
  bool get webSearchAvailable;
  Future<void> resume();
}

abstract interface class MeetingIndexingPort {
  Store get store;
  Helper get helper;
  bool get closed;
  bool get sourcesPaused;
  int get workspaceGeneration;
  void checkCancellations();
  Future<T> awaitCurrent<T>(Future<T> shared, bool Function()? current);
  Future<void> waitForSourceWork({bool Function()? current});
  Future<void> index(String id, {bool Function()? current});
  Future<transcript.TranscriptCursor> transcriptCursor(
    String id, {
    bool Function()? current,
  });
  Future<transcript.TranscriptDeltaResult> applyTranscriptDelta(
    transcript.TranscriptDelta delta, {
    bool Function()? current,
  });
}
