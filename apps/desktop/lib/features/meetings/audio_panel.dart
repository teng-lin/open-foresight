import 'package:flutter/material.dart';
import 'package:foresight_core/desktop.dart';
import 'audio_player.dart';

class MeetingAudioPanel extends StatefulWidget {
  const MeetingAudioPanel({
    super.key,
    required this.page,
    required this.sessions,
    required this.actions,
    required this.onMore,
    required this.hasMore,
    required this.loading,
    this.problem,
    this.onRetry,
  });
  final AudioMeetingReadPage? page;
  final List<AudioSessionPresentation> sessions;
  final MeetingAudioPlayerActions actions;
  final VoidCallback onMore;
  final VoidCallback? onRetry;
  final bool hasMore, loading;
  final String? problem;
  @override
  State<MeetingAudioPanel> createState() => _MeetingAudioPanelState();
}

class _MeetingAudioPanelState extends State<MeetingAudioPanel> {
  String? _selected;
  @override
  Widget build(BuildContext context) {
    final page = widget.page;
    if (widget.problem case final problem?)
      return ListTile(
        title: Text(problem),
        trailing: TextButton(
          onPressed: widget.onRetry,
          child: const Text('Retry'),
        ),
      );
    if (page == null || page.meeting.sessionCount == 0)
      return const SizedBox.shrink();
    if (!page.supported)
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: Text(
          'Saved recording details are available. Audio playback is unavailable in this app session.',
        ),
      );
    final sessions = widget.sessions;
    if (sessions.isEmpty) return const Text('Loading recordings…');
    final selected =
        sessions.where((s) => s.id == _selected).firstOrNull ??
        sessions
            .where((s) => s.id == page.meeting.activeSessionId)
            .firstOrNull ??
        sessions.last;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (page.serviceError.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(page.serviceError),
          ),
        if (sessions.length > 1 || widget.hasMore)
          Row(
            children: [
              Expanded(
                child: DropdownButton<String>(
                  isExpanded: true,
                  value: selected.id,
                  items: [
                    for (final s in sessions)
                      DropdownMenuItem(
                        value: s.id,
                        child: Text(
                          'Recording · ${DateTime.fromMillisecondsSinceEpoch(s.startedWallMs).toLocal()}',
                        ),
                      ),
                  ],
                  onChanged: (id) => setState(() => _selected = id),
                ),
              ),
              if (widget.hasMore)
                TextButton(
                  onPressed: widget.loading ? null : widget.onMore,
                  child: const Text('More recordings'),
                ),
            ],
          ),
        MeetingAudioPlayer(
          key: ValueKey(selected.id),
          session: selected,
          playback: page.playbackSessionId == selected.id
              ? page.playback
              : const AudioPlaybackPresentation(),
          actions: widget.actions,
        ),
      ],
    );
  }
}
