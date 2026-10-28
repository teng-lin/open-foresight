part of 'meetings_controller.dart';

/// Speaker corrections on saved transcript rows. Each action is bound to the
/// rendered workspace identity, so a view that has since changed is refused.
extension _TranscriptActions on MeetingsController {
  ClientEnvelope _envelope(FeatureRequestIdentity identity) =>
      ClientEnvelope(workspaceEpoch: WireField(identity.workspaceEpoch));

  Future<void> _nameDialog({
    required int meeting,
    required String title,
    required String initial,
    required Future<void> Function(
      String name,
      FeatureRequestIdentity identity,
      bool Function() current,
    )
    save,
  }) async {
    final identity = _reads.presentationIdentity;
    if (identity == null) return;
    bool current() => _meetingActionCurrent(meeting, identity);
    if (!current() || !_dialogs.rowsAreCurrent()) return;
    final controller = TextEditingController(text: initial);
    try {
      await _dialogs.showInputDialog<bool>(
        builder: (context) => ServiceEditDialog(
          title: title,
          controller: controller,
          saveLabel: 'Save',
          height: 90,
          maxLines: 1,
          onSave: () async {
            if (!current()) {
              throw StateError(
                'The meeting view changed. Close this editor and try again.',
              );
            }
            final name = controller.text.trim();
            if (name.isEmpty) {
              throw StateError(
                'Enter a name. To remove a name, use Reset speaker.',
              );
            }
            await save(name, identity, current);
          },
        ),
      );
    } finally {
      controller.dispose();
    }
  }

  Future<void> _correctSpeaker(int meeting, TranscriptSegment row) =>
      _nameDialog(
        meeting: meeting,
        title: 'Correct speaker',
        initial: row.participantName ?? '',
        save: (name, identity, current) =>
            meetingsAttributeDescriptor.sendCurrent(
              d,
              MeetingsAttributeInput(
                id: row.id,
                name: WireField(name),
                envelope: _envelope(identity),
              ),
              current,
            ),
      );

  Future<void> _renameParticipant(int meeting, TranscriptSegment row) {
    final participant = row.participantId;
    if (participant == null) return Future.value();
    return _nameDialog(
      meeting: meeting,
      title: 'Rename participant',
      initial: row.participantName ?? '',
      save: (name, identity, current) =>
          meetingsRenameParticipantDescriptor.sendCurrent(
            d,
            MeetingsRenameParticipantInput(
              id: participant,
              name: name,
              envelope: _envelope(identity),
            ),
            current,
          ),
    );
  }

  Future<void> _markSpeakerUnnamed(int meeting, TranscriptSegment row) async {
    final identity = _reads.presentationIdentity;
    if (identity == null) return;
    bool current() => _meetingActionCurrent(meeting, identity);
    if (!current()) return;
    await meetingsAttributeDescriptor.sendCurrent(
      d,
      MeetingsAttributeInput(id: row.id, envelope: _envelope(identity)),
      current,
    );
  }

  Future<void> _resetSpeaker(int meeting, TranscriptSegment row) async {
    final identity = _reads.presentationIdentity;
    if (identity == null) return;
    bool current() => _meetingActionCurrent(meeting, identity);
    if (!current()) return;
    await meetingsResetAttributionDescriptor.sendCurrent(
      d,
      MeetingsResetAttributionInput(id: row.id, envelope: _envelope(identity)),
      current,
    );
  }
}
