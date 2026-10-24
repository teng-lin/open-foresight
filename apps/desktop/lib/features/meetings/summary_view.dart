import 'package:flutter/material.dart';
import 'package:foresight_core/desktop.dart';
import '../../generated_content.dart';

/// A presentation snapshot and callbacks, independent of meeting state owners.
class MeetingSummaryPanel extends StatelessWidget {
  final List<MeetingArtifact> versions;
  final MeetingRunPresentation? summary;
  final int revision;
  final double fontSize;
  final Future<void> Function(Uri) openLink;
  final VoidCallback? onGenerate;
  final VoidCallback onCancel;
  final ValueChanged<MeetingArtifact> onEdit;
  final ValueChanged<String> onCopy;
  MeetingSummaryPanel({
    super.key,
    required List<MeetingArtifact> versions,
    required this.summary,
    required this.revision,
    required this.fontSize,
    required this.openLink,
    this.onGenerate,
    required this.onCancel,
    required this.onEdit,
    required this.onCopy,
  }) : versions = List.unmodifiable(versions);

  @override
  Widget build(BuildContext context) {
    const title = 'Summary';
    final artifact = versions.firstOrNull;
    final active = summary?.active == true;
    final preview = summary?.preview ?? '';
    final manifest = artifact?.manifest;
    final clipped = manifest != null && manifest['reduction_clipped'] == true;
    return Column(
      children: [
        _meetingSummaryHeading(
          context,
          title: title,
          active: active,
          artifact: artifact,
        ),
        if (active) ...[
          LinearProgressIndicator(
            value: (summary?.total ?? 0) > 0
                ? ((summary?.completed ?? 0) / summary!.total).clamp(0.0, 1.0)
                : null,
          ),
          Padding(
            padding: const EdgeInsets.all(8),
            child: Text(switch (summary?.phase) {
              'mapping' =>
                'Summarizing transcript ${summary?.completed}/${summary?.total}',
              'reducing' => 'Combining meeting topics…',
              'updating' => 'Updating the meeting brief…',
              'summarizing' => 'Writing the meeting brief…',
              _ => 'Preparing the meeting summary…',
            }),
          ),
        ],
        Expanded(
          child: active && preview.isNotEmpty
              ? SingleChildScrollView(
                  padding: const EdgeInsets.all(20),
                  child: GeneratedContent(
                    preview,
                    openLink: openLink,
                    fontSize: fontSize,
                  ),
                )
              : artifact == null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      'Generate ${title.toLowerCase()} from the meeting transcript.',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Color(0xff87a8b7),
                        fontSize: 17,
                      ),
                    ),
                  ),
                )
              : SingleChildScrollView(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (artifact.inputRevision < revision)
                        const Text('Out of date — regenerate'),
                      if (clipped)
                        const Text(
                          'This summary used shortened excerpts. Review the transcript for full context.',
                        ),
                      GeneratedContent(
                        artifact.body,
                        openLink: openLink,
                        fontSize: fontSize,
                      ),
                      if (versions.length > 1)
                        ExpansionTile(
                          title: const Text('Previous versions'),
                          children: [
                            for (final previous in versions.skip(1))
                              ListTile(
                                title: GeneratedContent(
                                  previous.body,
                                  openLink: openLink,
                                ),
                                trailing: IconButton(
                                  tooltip: 'Edit previous version',
                                  onPressed: () => onEdit(previous),
                                  icon: const Icon(Icons.edit_outlined),
                                ),
                              ),
                          ],
                        ),
                    ],
                  ),
                ),
        ),
      ],
    );
  }

  Widget _meetingSummaryHeading(
    BuildContext context, {
    required String title,
    required bool active,
    MeetingArtifact? artifact,
  }) => Padding(
    padding: const EdgeInsets.all(16),
    child: Row(
      children: [
        Expanded(
          child: Text(title, style: Theme.of(context).textTheme.titleLarge),
        ),
        IconButton(
          tooltip: 'Generate $title',
          onPressed: onGenerate,
          icon: const Icon(Icons.auto_awesome),
        ),
        if (active)
          IconButton(
            tooltip: 'Cancel summary',
            onPressed: onCancel,
            icon: const Icon(Icons.stop_circle_outlined),
          ),
        if (artifact != null)
          IconButton(
            tooltip: 'Copy $title',
            onPressed: () => onCopy(artifact.body),
            icon: const Icon(Icons.copy_outlined),
          ),
        if (artifact != null)
          IconButton(
            tooltip: 'Edit $title',
            onPressed: active ? null : () => onEdit(artifact),
            icon: const Icon(Icons.edit_outlined),
          ),
      ],
    ),
  );
}
