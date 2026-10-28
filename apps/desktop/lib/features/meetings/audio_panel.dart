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
    this.recording = false,
    this.problem,
    this.onRetry,
  });
  final AudioMeetingReadPage? page;
  final List<AudioSessionPresentation> sessions;
  final MeetingAudioPlayerActions actions;
  final VoidCallback onMore;
  final VoidCallback? onRetry;
  final bool hasMore, loading, recording;
  final String? problem;
  @override
  State<MeetingAudioPanel> createState() => _MeetingAudioPanelState();
}

class _MeetingAudioPanelState extends State<MeetingAudioPanel> {
  String? _selected;
  bool _expanded = false;
  @override
  Widget build(BuildContext context) {
    final page = widget.page;
    if (!widget.recording &&
        (page == null || page.meeting.sessionCount == 0) &&
        widget.sessions.isEmpty &&
        widget.problem == null) {
      return const SizedBox.shrink();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        TextButton.icon(
          key: const ValueKey('toggle-meeting-audio'),
          onPressed: () => setState(() => _expanded = !_expanded),
          icon: Icon(_expanded ? Icons.expand_less : Icons.headphones_outlined),
          label: Text(_expanded ? 'Hide recording' : 'Show recording'),
        ),
        if (_expanded) _content(),
      ],
    );
  }

  Widget _content() {
    final page = widget.page;
    // Live capture is authoritative while saved-audio reads catch up. Even
    // when explicitly expanded, live audio presents only the playback bar.
    final capturing =
        widget.recording ||
        (page != null &&
            page.meeting.physicalState != MeetingAudioPhysicalState.idle);
    if (capturing && widget.problem != null) return const SizedBox.shrink();
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
    if (sessions.isEmpty) {
      return capturing
          ? const SizedBox.shrink()
          : const Text('Loading recordings…');
    }
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
        if (!capturing && page.serviceError.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(page.serviceError),
          ),
        if (!capturing && (sessions.length > 1 || widget.hasMore))
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
          playbackOnly: capturing,
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
