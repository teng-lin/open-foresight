import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'meeting_visuals.dart';

/// Enhanced-note presentation; drafts, requests and saves remain with the owner.
class MeetingEnhancedPane extends StatelessWidget {
  const MeetingEnhancedPane({
    super.key,
    required this.preview,
    required this.enhancedText,
    required this.hasArtifact,
    required this.hasProgress,
    required this.active,
    required this.cancelRequested,
    required this.degraded,
    required this.status,
    required this.hasNotes,
    required this.body,
    required this.onHide,
    this.onCopy,
    this.onEdit,
    this.onCancel,
    this.onEnhance,
  });
  final bool preview, hasArtifact, hasProgress, active, cancelRequested;
  final bool degraded, hasNotes;
  final String enhancedText, status;
  final Widget body;
  final VoidCallback onHide;
  final VoidCallback? onCopy, onEdit, onCancel, onEnhance;
  @override
  Widget build(BuildContext context) => Container(
    margin: EdgeInsets.fromLTRB(preview ? 24 : 0, 24, 24, 24),
    decoration: BoxDecoration(
      color: MeetingVisuals.enhancedSurface,
      borderRadius: MeetingVisuals.previewRadius,
    ),
    child: LayoutBuilder(
      builder: (_, bounds) => SingleChildScrollView(
        child: SizedBox(
          height: math.max(preview ? 160 : 260, bounds.maxHeight),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
                child: MeetingPanelHeading(
                  title: preview ? 'Enhanced notes' : 'Live enhanced notes',
                  actions: [
                    IconButton(
                      tooltip: 'Copy enhanced notes',
                      onPressed:
                          !hasArtifact && !hasProgress && enhancedText.isEmpty
                          ? null
                          : onCopy,
                      icon: const Icon(Icons.copy_outlined, size: 19),
                    ),
                    if (hasArtifact)
                      IconButton(
                        tooltip: 'Edit enhanced notes',
                        onPressed: onEdit,
                        icon: const Icon(Icons.edit_outlined, size: 18),
                      ),
                    IconButton(
                      tooltip: 'Hide enhanced notes',
                      onPressed: onHide,
                      icon: const Icon(Icons.keyboard_arrow_down, size: 20),
                    ),
                  ],
                ),
              ),
              if (degraded)
                const Padding(
                  padding: EdgeInsets.all(12),
                  child: Text(
                    'Some notes were preserved without successful enhancement. Review or regenerate these notes.',
                  ),
                ),
              if (active) ...[
                const LinearProgressIndicator(),
                TextButton(
                  key: const ValueKey('cancel-note-enhancement'),
                  onPressed: cancelRequested ? null : onCancel,
                  child: Text(
                    cancelRequested ? 'Cancelling…' : 'Cancel enhancement',
                  ),
                ),
              ],
              if (status.isNotEmpty)
                Padding(padding: const EdgeInsets.all(8), child: Text(status)),
              Expanded(child: body),
              if (hasNotes)
                TextButton.icon(
                  onPressed: onEnhance,
                  icon: const Icon(Icons.auto_awesome, size: 16),
                  label: const Text('Enhance notes'),
                ),
            ],
          ),
        ),
      ),
    ),
  );
}
