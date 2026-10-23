import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../presentation/workspace_presentation.dart';
import 'workspace_tab.dart';

/// Shell presentation receives values and callbacks, never feature owners.
class WorkspaceHeader extends StatelessWidget {
  const WorkspaceHeader({
    super.key,
    required this.embeddingName,
    required this.localWords,
    required this.helperHealthy,
    required this.showHelperMonitor,
    this.recordingHeader,
    this.onRecord,
  });
  final String embeddingName;
  final int localWords;
  final bool helperHealthy;
  final VoidCallback showHelperMonitor;
  final Widget? recordingHeader;
  final VoidCallback? onRecord;
  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.fromLTRB(24, 28, recordingHeader != null ? 16 : 24, 8),
    child: LayoutBuilder(
      builder: (_, constraints) => SizedBox(
        width: constraints.maxWidth,
        child: Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 16,
          runSpacing: 12,
          children: [
            ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: math.max(200, constraints.maxWidth - 260),
              ),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Image.asset(
                        'assets/images/open-foresight-logo.png',
                        width: 24,
                        height: 24,
                      ),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text.rich(
                          TextSpan(
                            children: const [
                              TextSpan(
                                text: 'Open ',
                                style: TextStyle(fontWeight: FontWeight.w700),
                              ),
                              TextSpan(text: 'Foresight'),
                            ],
                          ),
                          style: const TextStyle(fontSize: 18),
                        ),
                      ),
                    ],
                  ),
                  if (MediaQuery.sizeOf(context).width > 1100) ...[
                    Chip(label: Text('Powered by $embeddingName')),
                    Chip(label: Text('$localWords Local output words')),
                  ],
                  SizedBox(
                    width: 32,
                    height: 28,
                    child: IconButton(
                      tooltip: 'Local helper status',
                      onPressed: showHelperMonitor,
                      padding: EdgeInsets.zero,
                      style: IconButton.styleFrom(
                        backgroundColor: Colors.white.withValues(alpha: .7),
                        foregroundColor: workspaceInk,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                      icon: Icon(
                        helperHealthy ? Icons.task_alt : Icons.info_outline,
                        size: 18,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            if (recordingHeader != null)
              recordingHeader!
            else
              FilledButton.icon(
                onPressed: onRecord,
                icon: const Icon(Icons.graphic_eq),
                label: const Text('Start transcribing'),
                style: FilledButton.styleFrom(
                  backgroundColor: workspaceInk,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 18,
                    vertical: 16,
                  ),
                ),
              ),
          ],
        ),
      ),
    ),
  );
}

class WorkspaceSidebar extends StatelessWidget {
  const WorkspaceSidebar({
    super.key,
    required this.tab,
    required this.navigate,
    required this.account,
  });
  final WorkspaceTab tab;
  final ValueChanged<WorkspaceTab> navigate;
  final Widget account;
  @override
  Widget build(BuildContext context) => SizedBox(
    width: 72 * MediaQuery.textScalerOf(context).scale(1).clamp(1, 2),
    child: Column(
      children: [
        Expanded(
          child: ListView(
            children: [
              navItem(
                WorkspaceTab.meetings,
                'Meetings',
                tab == WorkspaceTab.meetings
                    ? Icons.description
                    : Icons.description_outlined,
                context,
              ),
              navItem(
                WorkspaceTab.chat,
                'Ask',
                tab == WorkspaceTab.chat
                    ? Icons.chat_bubble
                    : Icons.chat_bubble_outline,
                context,
              ),
              navItem(
                WorkspaceTab.sources,
                'Sources',
                tab == WorkspaceTab.sources
                    ? Icons.snippet_folder
                    : Icons.snippet_folder_outlined,
                context,
              ),
              navItem(
                WorkspaceTab.stats,
                'Stats',
                tab == WorkspaceTab.stats
                    ? Icons.emoji_events
                    : Icons.emoji_events_outlined,
                context,
              ),
            ],
          ),
        ),
        navItem(
          WorkspaceTab.settings,
          'Settings',
          tab == WorkspaceTab.settings || tab == WorkspaceTab.models
              ? Icons.settings
              : Icons.settings_outlined,
          context,
        ),
        IconButton(
          tooltip: 'Help',
          onPressed: () => showDialog<void>(
            context: context,
            builder: (_) => const AlertDialog(
              title: Text('Foresight'),
              content: Text(
                'Add local knowledge sources, then ask a question with citations. Start transcribing captures microphone and system playback; live transcription updates during recording.\n\nCtrl+1–5: navigate\nCtrl+O: add file\nCtrl+N: new note\nCtrl+Shift+F: start a meeting',
              ),
            ),
          ),
          icon: const Icon(Icons.help_outline),
        ),
        account,
      ],
    ),
  );
  Widget navItem(
    WorkspaceTab destination,
    String title,
    IconData icon,
    BuildContext context,
  ) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
    child: Material(
      color:
          tab == destination ||
              destination == WorkspaceTab.settings && tab == WorkspaceTab.models
          ? workspaceBlue
          : Colors.transparent,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => navigate(destination),
        child: SizedBox(
          width: 56 * MediaQuery.textScalerOf(context).scale(1).clamp(1, 2),
          height: 54 * MediaQuery.textScalerOf(context).scale(1).clamp(1, 2),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 20,
                color: tab == destination
                    ? workspaceInk
                    : const Color(0xff45494b),
              ),
              const SizedBox(height: 4),
              Text(
                title,
                style: const TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class WorkspaceContent extends StatelessWidget {
  const WorkspaceContent({
    super.key,
    required this.tab,
    required this.meetingSelected,
    required this.busy,
    required this.error,
    required this.child,
  });
  final WorkspaceTab tab;
  final bool meetingSelected, busy;
  final String error;
  final Widget child;
  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.fromLTRB(
      tab == WorkspaceTab.chat ||
              (tab == WorkspaceTab.meetings && meetingSelected)
          ? 16
          : MediaQuery.sizeOf(context).width > 1000
          ? 56
          : 16,
      tab == WorkspaceTab.meetings && meetingSelected
          ? 12
          : tab == WorkspaceTab.chat
          ? 22
          : 34,
      MediaQuery.sizeOf(context).width > 1000
          ? (tab == WorkspaceTab.chat ||
                    (tab == WorkspaceTab.meetings && meetingSelected)
                ? 40
                : tab == WorkspaceTab.settings
                ? 88
                : 68)
          : 16,
      28,
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (busy) const LinearProgressIndicator(),
        if (error.isNotEmpty)
          Material(
            color: Theme.of(context).colorScheme.errorContainer,
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: SelectableText(error),
            ),
          ),
        Expanded(child: child),
      ],
    ),
  );
}
