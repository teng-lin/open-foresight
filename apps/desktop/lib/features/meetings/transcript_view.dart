import 'package:flutter/material.dart';
import 'package:foresight_core/desktop.dart';
import 'speaker_naming.dart';

/// A transcript snapshot with effects supplied by its meeting owner.
class MeetingTranscriptPanel extends StatelessWidget {
  MeetingTranscriptPanel({
    super.key,
    required this.id,
    required List<TranscriptSegment> rows,
    required Map<String, String> provisional,
    required this.questions,
    required this.showProvisional,
    required this.hasAttachments,
    required this.canAnswer,
    required this.onImportTranscript,
    required this.onImportAttachments,
    required this.onCopy,
    required this.onQuestion,
    this.onListen,
    this.naming,
    this.onCorrectSpeaker,
    this.onMarkUnnamed,
    this.onResetSpeaker,
    this.onRenameParticipant,
  }) : rows = List.unmodifiable(rows),
       provisional = Map.unmodifiable(provisional);
  final int id;
  final List<TranscriptSegment> rows;
  final Map<String, String> provisional;
  final bool questions, showProvisional, hasAttachments, canAnswer;
  final VoidCallback? onImportTranscript, onImportAttachments;
  final ValueChanged<int>? onListen;

  /// Naming availability, shown apart from recording health; null when unknown.
  final SpeakerNamingStatus? naming;

  /// Speaker corrections for a segment (by transcript id) and for a
  /// participant (by participant id). Null hides the matching menu item.
  final ValueChanged<TranscriptSegment>? onCorrectSpeaker,
      onMarkUnnamed,
      onResetSpeaker;
  final ValueChanged<TranscriptSegment>? onRenameParticipant;
  final ValueChanged<String> onCopy, onQuestion;

  List<ContextMenuButtonItem> _speakerItems(
    TranscriptSegment? segment,
    bool enabled,
  ) {
    if (segment == null || !enabled) return const [];
    ContextMenuButtonItem item(
      String label,
      ValueChanged<TranscriptSegment>? action,
    ) => ContextMenuButtonItem(
      label: label,
      onPressed: () {
        ContextMenuController.removeAny();
        action!(segment);
      },
    );
    return [
      if (onCorrectSpeaker != null) item('Correct speaker…', onCorrectSpeaker),
      if (onMarkUnnamed != null)
        item('Mark as not a named speaker', onMarkUnnamed),
      if (onResetSpeaker != null && segment.attributionState != null)
        item('Clear speaker name', onResetSpeaker),
      if (onRenameParticipant != null && segment.participantId != null)
        item('Rename participant…', onRenameParticipant),
    ];
  }

  Widget _header(BuildContext context) => Padding(
    padding: const EdgeInsets.all(12),
    child: Row(
      children: [
        Expanded(
          child: Text(
            'Transcript',
            style: Theme.of(context).textTheme.titleLarge,
          ),
        ),
        if (naming case final status?)
          Tooltip(
            message: status.detail,
            child: Chip(
              key: const ValueKey('speaker-naming-status'),
              label: Text(status.label),
              visualDensity: VisualDensity.compact,
            ),
          ),
        IconButton(
          tooltip: 'Import transcript',
          onPressed: onImportTranscript,
          icon: const Icon(Icons.file_upload_outlined),
        ),
        if (hasAttachments)
          IconButton(
            tooltip: 'Import meeting attachments',
            onPressed: onImportAttachments,
            icon: const Icon(Icons.attach_file),
          ),
        IconButton(
          tooltip: 'Copy full transcript',
          onPressed: rows.isEmpty
              ? null
              : () => onCopy(
                  AttributedTranscript.lines(
                    rows,
                    TranscriptFormatMode.export,
                  ).map((line) => line.text).join('\n\n'),
                ),
          icon: const Icon(Icons.copy_all),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final displayed = questions
        ? rows.where((t) => t.text.contains('?')).toList()
        : rows;
    return Column(
      children: [
        if (!questions) _header(context),
        Expanded(
          child: displayed.isEmpty && (questions || provisional.isEmpty)
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      questions
                          ? 'Questions from the live transcript will appear here.'
                          : 'Your live transcript will appear here.',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Color(0xff87a8b7),
                        fontSize: 17,
                      ),
                    ),
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    if (!questions && rows.isNotEmpty)
                      SelectableText.rich(
                        key: ValueKey('meeting-transcript-$id'),
                        TextSpan(
                          children: [
                            for (
                              var index = 0;
                              index < rows.length;
                              index++
                            ) ...[
                              TextSpan(
                                text: '${_speakerLabel(rows[index])}\n',
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                              TextSpan(text: rows[index].text),
                              if (index < rows.length - 1)
                                const TextSpan(text: '\n\n'),
                            ],
                          ],
                        ),
                        style: Theme.of(context).textTheme.bodyLarge,
                        contextMenuBuilder: (context, state) {
                          final selection = state.textEditingValue.selection;
                          final row = _selectedTranscript(
                            rows,
                            selection.start,
                          );
                          final segment = row == null
                              ? null
                              : rows.firstWhere((entry) => entry.id == row);
                          final inRow =
                              segment != null && !selection.isCollapsed;
                          return AdaptiveTextSelectionToolbar.buttonItems(
                            anchors: state.contextMenuAnchors,
                            buttonItems: [
                              ...state.contextMenuButtonItems,
                              if (onListen != null &&
                                  row != null &&
                                  !selection.isCollapsed)
                                ContextMenuButtonItem(
                                  label: 'Listen to this section',
                                  onPressed: () {
                                    ContextMenuController.removeAny();
                                    onListen!(row);
                                  },
                                ),
                              ..._speakerItems(segment, inRow),
                            ],
                          );
                        },
                      ),
                    if (questions)
                      for (final t in displayed)
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: SelectableText(t.text),
                          subtitle: Text(_speakerLabel(t)),
                          trailing: questions
                              ? IconButton(
                                  tooltip: 'Answer this question',
                                  onPressed: canAnswer
                                      ? () => onQuestion(t.text)
                                      : null,
                                  icon: const Icon(Icons.arrow_upward),
                                )
                              : null,
                        ),
                    if (!questions && showProvisional)
                      for (final entry in provisional.entries.where(
                        (e) => e.value.isNotEmpty,
                      ))
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text(
                            entry.value,
                            style: const TextStyle(color: Color(0xff818995)),
                          ),
                          subtitle: Text(
                            '${MeetingSpeaker.fromSource(entry.key).label} · Live',
                          ),
                        ),
                  ],
                ),
        ),
      ],
    );
  }
}

/// A supported participant name, else the legacy audio-channel label.
String _speakerLabel(TranscriptSegment row) =>
    AttributedTranscript.line(row, TranscriptFormatMode.display).label;

// The selected text chooses a transcript identity only. The service resolves
// that identity's immutable audio link; UI text offsets never become timestamps.
int? _selectedTranscript(List<TranscriptSegment> rows, int offset) {
  if (offset < 0) return null;
  var position = 0;
  for (final row in rows) {
    position += _speakerLabel(row).length + 1;
    if (offset < position + row.text.length) return row.id;
    position += row.text.length + 2;
  }
  return null;
}
