import 'package:foresight_core/desktop.dart';

// Compiling work-package-6 adapters. Feature extraction replaces these row
// projections with prepared typed view state; none grants persistence writes.
List<Map<String, Object?>> readRows(Iterable<ReadProjection> values) =>
    values.map((value) => value.toRow()).toList();

extension DesktopReadAdapter on StoreReader {
  List<Map<String, Object?>> registeredEmbedding() => [
    if (model('embedding') case final value?) value.toRow(),
  ];
  List<Map<String, Object?>> registeredSpeech() => [
    if (model('speech') case final value?) value.toRow(),
  ];
  List<Map<String, Object?>> meetingNoteRows(int id) => [
    if (meetingNote(id) case final value?) value.toRow(),
  ];
  List<Map<String, Object?>> meetingPreviewRows(int id) => [
    if (meetingPreview(id) case final value?) value.toRow(),
  ];
  List<Map<String, Object?>> meetingWorkspaceRows(int id) => [
    if (meetingWorkspace(id) case final value?) value.toRow(),
  ];
  List<Map<String, Object?>> enhancedNoteArtifacts(int id) =>
      readRows(meetingArtifacts(id, 'enhanced_notes').take(1));
  List<Map<String, Object?>> finalTranscript(int id) =>
      readRows(meetingTranscript(id, finalOnly: true));

  Future<StoredGraphLayout> loadRegisteredGraphLayout(
    List<Map<String, Object?>> sources, {
    String? labelSet,
  }) => _graph(sources, labelSet: labelSet);
  Future<StoredGraphLayout> loadGraphLayout(
    String identity,
    List<Map<String, Object?>> sources,
    int dimensions, {
    String? labelSet,
  }) => _graph(
    sources,
    identity: identity,
    dimensions: dimensions,
    labelSet: labelSet,
  );
  Future<StoredGraphLayout> _graph(
    List<Map<String, Object?>> sources, {
    String? identity,
    int? dimensions,
    String? labelSet,
  }) async {
    final result = await read(
      StoreReadQueries.graphLayout(
        sources: sources.map(SourceSummary.fromRow).toList(),
        identity: identity,
        dimensions: dimensions,
        labelSet: labelSet,
        helperIdentity: identity ?? 'registered',
      ),
    );
    if (result.error != null) throw result.error!;
    return result.value!;
  }
}
