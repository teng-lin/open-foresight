import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../presentation/workspace_presentation.dart';
import 'meeting_visuals.dart';

class _MeetingRenameButton extends StatelessWidget {
  const _MeetingRenameButton(this.onRename);
  final VoidCallback? onRename;
  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: 'Rename meeting',
      iconSize: 18,
      padding: const EdgeInsets.all(4),
      constraints: const BoxConstraints.tightFor(width: 32, height: 26),
      style: IconButton.styleFrom(
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      icon: const Icon(Icons.edit_outlined),
      onPressed: onRename,
    );
  }
}

class ImmersiveMeetingWorkspace extends StatelessWidget {
  const ImmersiveMeetingWorkspace({
    super.key,
    required this.workspace,
    this.recordingHeader,
    required this.onExit,
  });
  final Widget workspace;
  final Widget? recordingHeader;
  final VoidCallback onExit;
  @override
  Widget build(BuildContext context) => CallbackShortcuts(
    bindings: {const SingleActivator(LogicalKeyboardKey.escape): onExit},
    child: Focus(
      autofocus: true,
      child: Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                SizedBox(
                  width: double.infinity,
                  child: Wrap(
                    alignment: WrapAlignment.spaceBetween,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 12,
                    runSpacing: 8,
                    children: [
                      TextButton.icon(
                        onPressed: onExit,
                        icon: const Icon(Icons.fullscreen_exit),
                        label: const Text('Exit Immersive View'),
                      ),
                      if (recordingHeader != null) recordingHeader!,
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                Expanded(child: MeetingStyleScope(child: workspace)),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

class MeetingWorkspacePanel extends StatelessWidget {
  const MeetingWorkspacePanel({
    super.key,
    required this.header,
    this.speechProblem,
    this.audio,
    required this.sidecarVisible,
    required this.assistantFallback,
    required this.sidecarWidth,
    required this.assistantMinWidth,
    required this.onAssistantWidth,
    required this.onSidecarWidth,
    required this.onSetupSpeech,
    required this.onHideAssistant,
    required this.onOpenAssistant,
    required this.notesBuilder,
    required this.assistantBuilder,
  });
  final Widget header;
  final Widget? audio;
  final String? speechProblem;
  final bool sidecarVisible, assistantFallback;
  final double sidecarWidth, assistantMinWidth;
  final ValueChanged<bool> onAssistantWidth;
  final ValueChanged<double> onSidecarWidth;
  final VoidCallback onSetupSpeech, onHideAssistant;
  final ValueChanged<BuildContext> onOpenAssistant;
  final Widget Function(bool large, Widget assistantToggle) notesBuilder;
  final Widget Function() assistantBuilder;
  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (workspaceContext, constraints) {
        final wide = constraints.maxWidth >= assistantMinWidth;
        onAssistantWidth(wide);
        final showAssistant = sidecarVisible && (wide || assistantFallback);
        return CustomScrollView(
          slivers: [
            SliverToBoxAdapter(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  header,
                  if (audio != null)
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        maxHeight: constraints.maxHeight * .4,
                      ),
                      child: SingleChildScrollView(child: audio!),
                    ),
                  if (speechProblem != null)
                    ListTile(
                      dense: true,
                      leading: const Icon(Icons.info_outline),
                      title: Text(speechProblem!),
                      trailing: TextButton(
                        onPressed: onSetupSpeech,
                        child: const Text('Set up speech'),
                      ),
                    ),
                  const SizedBox(height: 16),
                ],
              ),
            ),
            SliverLayoutBuilder(
              builder: (_, viewport) => SliverToBoxAdapter(
                // Audio and wrapped toolbars must not consume the editor's
                // entire viewport. Short windows scroll the workspace instead
                // of giving its fixed note controls a negative body height.
                child: SizedBox(
                  height: math.max(
                    320,
                    viewport.viewportMainAxisExtent -
                        viewport.precedingScrollExtent,
                  ),
                  child: LayoutBuilder(
                    builder: (_, size) {
                      final showSidecar = showAssistant && wide;
                      final sideWidth = sidecarWidth
                          .clamp(280.0, math.max(280.0, size.maxWidth / 2))
                          .toDouble();
                      final notesWidth = showSidecar
                          ? size.maxWidth - sideWidth - 16
                          : size.maxWidth;
                      final editor = notesBuilder(
                        notesWidth >= 640,
                        SizedBox(
                          width: 40,
                          child: IconButton(
                            key: const ValueKey('meeting-assistant-toggle'),
                            tooltip: showAssistant
                                ? 'Hide assistant'
                                : 'Open assistant',
                            isSelected: showAssistant,
                            style: IconButton.styleFrom(
                              backgroundColor: showAssistant
                                  ? workspaceBlue
                                  : null,
                              foregroundColor: workspaceInk,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8),
                              ),
                            ),
                            onPressed: showAssistant
                                ? onHideAssistant
                                : () => onOpenAssistant(workspaceContext),
                            icon: const Icon(Icons.view_sidebar_outlined),
                          ),
                        ),
                      );
                      if (showAssistant && !wide) return assistantBuilder();
                      return Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(flex: 7, child: editor),
                          if (showSidecar) ...[
                            MouseRegion(
                              cursor: SystemMouseCursors.resizeColumn,
                              child: GestureDetector(
                                key: const ValueKey('meeting-sidecar-resize'),
                                behavior: HitTestBehavior.opaque,
                                onHorizontalDragUpdate: (drag) =>
                                    onSidecarWidth(
                                      (sideWidth - drag.delta.dx)
                                          .clamp(
                                            280.0,
                                            math.max(280.0, size.maxWidth / 2),
                                          )
                                          .toDouble(),
                                    ),
                                child: SizedBox(
                                  width: 16,
                                  child: Center(
                                    child: Container(
                                      width: 4,
                                      height: 48,
                                      decoration: BoxDecoration(
                                        color: const Color(0xffd6dae1),
                                        borderRadius: BorderRadius.circular(2),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            SizedBox(
                              width: sideWidth,
                              child: assistantBuilder(),
                            ),
                          ],
                        ],
                      );
                    },
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class MeetingWorkspaceHeader extends StatelessWidget {
  const MeetingWorkspaceHeader({
    super.key,
    required this.title,
    required this.dateText,
    required this.timeText,
    required this.onBack,
    this.onRename,
  });
  final String title, dateText, timeText;
  final VoidCallback onBack;
  final VoidCallback? onRename;
  @override
  Widget build(BuildContext context) => Row(
    children: [
      IconButton.filledTonal(
        tooltip: 'All meetings',
        onPressed: onBack,
        style: IconButton.styleFrom(backgroundColor: Colors.white),
        icon: const Icon(Icons.arrow_back),
      ),
      const SizedBox(width: 8),
      const CircleAvatar(
        backgroundColor: Color(0xffdce1ea),
        child: Icon(Icons.calendar_today, color: Color(0xff555b62)),
      ),
      const SizedBox(width: 14),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Flexible(child: Text(title, style: MeetingVisuals.title)),
                _MeetingRenameButton(onRename),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                MeetingMetadataBadge(dateText),
                MeetingMetadataBadge(timeText),
              ],
            ),
          ],
        ),
      ),
    ],
  );
}

class MeetingReadStatus extends StatelessWidget {
  const MeetingReadStatus({super.key, required this.loaded});
  final bool loaded;
  @override
  Widget build(BuildContext context) => Center(
    child: Text(loaded ? 'Meeting no longer exists.' : 'Loading meeting…'),
  );
}
