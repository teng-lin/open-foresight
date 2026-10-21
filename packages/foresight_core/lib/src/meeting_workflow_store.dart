import 'meeting_actions.dart';
import 'store.dart';

/// Compatibility facade: SQL and transaction ownership live in MeetingStore.
extension MeetingWorkflowStore on Store {
  List<Map<String, Object?>> meetingTasks(int meeting) =>
      meetingStore.meetingTasks(meeting);
  T workflowTransaction<T>(T Function() write) =>
      meetingStore.workflowTransaction(write);
  String saveMeetingTasks(
    int meeting,
    List<MeetingAction> tasks,
    String model,
    int revision,
    Map<String, Object?> manifest,
  ) => meetingStore.saveMeetingTasks(meeting, tasks, model, revision, manifest);
  void editMeetingTask(
    int id, {
    String? task,
    String? owner,
    String? due,
    String? status,
    bool editDetails = false,
  }) => meetingStore.editMeetingTask(
    id,
    task: task,
    owner: owner,
    due: due,
    status: status,
    editDetails: editDetails,
  );
  String saveWorkflowArtifact(
    int meeting,
    String kind,
    String body,
    String model,
    int revision,
    Map<String, Object?> manifest,
  ) => meetingStore.saveWorkflowArtifact(
    meeting,
    kind,
    body,
    model,
    revision,
    manifest,
  );
  String? refreshArtifactSource(int artifactId) =>
      meetingStore.refreshArtifactSource(artifactId);
}
