import 'package:flutter/material.dart';
import 'package:foresight_core/desktop.dart';
import '../../presentation/workspace_presentation.dart';
import 'meeting_visuals.dart';

String meetingClockLabel(int milliseconds) {
  final date = DateTime.fromMillisecondsSinceEpoch(milliseconds).toLocal();
  return '${date.hour % 12 == 0 ? 12 : date.hour % 12}:${date.minute.toString().padLeft(2, '0')} ${date.hour < 12 ? 'AM' : 'PM'}';
}

int meetingStartMilliseconds(MeetingDetails meeting) =>
    (meeting.starts ?? meeting.created ?? 0);

int meetingEndMilliseconds(MeetingDetails meeting) =>
    (meeting.ends ??
    meetingStartMilliseconds(meeting) +
        (meeting.durationMs ?? const Duration(minutes: 30).inMilliseconds));

String meetingDayLabel(int timestamp) {
  if (timestamp == 0) return 'Saved meetings';
  final date = DateTime.fromMillisecondsSinceEpoch(timestamp).toLocal();
  final now = DateTime.now();
  if (date.year == now.year && date.month == now.month && date.day == now.day)
    return 'Today';
  return '${['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'][date.weekday - 1]}, ${['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'][date.month - 1]} ${date.day}';
}

final class MeetingTimelineEntry {
  const MeetingTimelineEntry({
    required this.meeting,
    required this.dayLabel,
    required this.attachmentCount,
    required this.selected,
    required this.canRecord,
  });
  final MeetingCollectionEntry meeting;
  final String dayLabel;
  final int attachmentCount;
  final bool selected, canRecord;
}

class MeetingTimeline extends StatelessWidget {
  MeetingTimeline({
    super.key,
    required List<MeetingTimelineEntry> entries,
    required this.now,
    required this.nowClock,
    required this.nowKey,
    required this.search,
    this.heading,
    required this.onNow,
    required this.onOpen,
    required this.onRecord,
  }) : entries = List.unmodifiable(entries);
  final List<MeetingTimelineEntry> entries;
  final int now;
  final String nowClock;
  final GlobalKey nowKey;
  final Widget search;
  final Widget? heading;
  final VoidCallback onNow;
  final ValueChanged<int> onOpen, onRecord;
  @override
  Widget build(BuildContext context) {
    var insertedNow = false;
    Widget nowMarker() => Padding(
      key: nowKey,
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Row(
        children: [
          const Expanded(child: Divider(color: Color(0xff8cb2c9))),
          const SizedBox(width: 12),
          Chip(
            backgroundColor: workspaceBlue,
            label: Text(
              '●  Now · $nowClock',
              style: const TextStyle(
                color: workspaceInk,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(width: 12),
          const Expanded(child: Divider(color: Color(0xff8cb2c9))),
        ],
      ),
    );
    final widgets = <Widget>[];
    String? previousDay;
    for (final entry in entries) {
      final meeting = entry.meeting;
      if (!insertedNow && meetingStartMilliseconds(meeting) > now) {
        widgets.add(nowMarker());
        insertedNow = true;
      }
      final day = entry.dayLabel;
      if (day != previousDay) {
        widgets.add(
          Padding(
            padding: const EdgeInsets.only(top: 12, bottom: 16),
            child: Text(day, style: MeetingVisuals.dateHeading),
          ),
        );
        previousDay = day;
      }
      widgets.add(
        Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: MeetingCollectionTile(
            entry: entry,
            onOpen: () => onOpen(meeting.id),
            onRecord: () => onRecord(meeting.id),
          ),
        ),
      );
    }
    if (!insertedNow && entries.isNotEmpty) widgets.add(nowMarker());
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (heading != null) heading!,
        search,
        const SizedBox(height: 16),
        OutlinedButton.icon(
          onPressed: onNow,
          icon: const Icon(Icons.schedule, size: 18),
          label: const Text('Now'),
        ),
        const SizedBox(height: 24),
        Expanded(
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (entries.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(40),
                    child: Text(
                      'No meetings yet. Start transcribing or create a new meeting.',
                    ),
                  ),
                ...widgets,
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class MeetingCollectionTile extends StatelessWidget {
  const MeetingCollectionTile({
    super.key,
    required this.entry,
    required this.onOpen,
    required this.onRecord,
  });
  final MeetingTimelineEntry entry;
  final VoidCallback onOpen, onRecord;
  @override
  Widget build(BuildContext context) {
    final meeting = entry.meeting;
    final start = meetingStartMilliseconds(meeting);
    final end = meetingEndMilliseconds(meeting);
    final attachmentCount = entry.attachmentCount;
    final state = meeting.state;
    final active = state == 'recording' || state == 'transcribing';
    return Card(
      margin: EdgeInsets.zero,
      shape: const RoundedRectangleBorder(
        borderRadius: MeetingVisuals.previewRadius,
      ),
      color: entry.selected ? const Color(0xffd2deee) : Colors.white,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final narrow = constraints.maxWidth < 650;
          final details = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                meeting.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: MeetingVisuals.listTitle,
              ),
              if (narrow && start > 0)
                Text(
                  '${meetingClockLabel(start)} – ${meetingClockLabel(end)}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              if (meeting.hasTranscript)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xfff3e5f9),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.graphic_eq,
                          size: 12,
                          color: Color(0xff7b2cbf),
                        ),
                        SizedBox(width: 4),
                        Text(
                          'Transcript',
                          style: TextStyle(
                            fontSize: 11,
                            color: Color(0xff7b2cbf),
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              if (meeting.calendarStatus != null &&
                  meeting.calendarStatus != 'confirmed')
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    'Calendar ${meeting.calendarStatus}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              if (active || state == 'failed' || state == 'interrupted')
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    state,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
            ],
          );
          return InkWell(
            onTap: onOpen,
            borderRadius: BorderRadius.circular(16),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
              child: Row(
                children: [
                  if (!narrow && start > 0)
                    SizedBox(
                      width: 155,
                      child: Text(
                        '${meetingClockLabel(start)} – ${meetingClockLabel(end)}',
                        style: MeetingVisuals.metadata,
                      ),
                    ),
                  Expanded(child: details),
                  const SizedBox(width: 8),
                  OutlinedButton(
                    onPressed: onOpen,
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      minimumSize: const Size(40, 28),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.attach_file, size: 14),
                        Text(
                          '$attachmentCount',
                          style: MeetingVisuals.metadata,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed: entry.canRecord ? onRecord : null,
                    icon: const Icon(Icons.graphic_eq, size: 18),
                    label: const Text('Start'),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class MeetingPreviewCard extends StatelessWidget {
  const MeetingPreviewCard({
    super.key,
    required this.title,
    required this.metadata,
    required this.selectedTab,
    required this.content,
    required this.onExpand,
    required this.onClose,
    required this.onTab,
  });
  final String title, metadata, selectedTab;
  final Widget content;
  final VoidCallback onExpand, onClose;
  final ValueChanged<String> onTab;
  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('meeting-preview'),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: MeetingVisuals.previewRadius,
      ),
      child: Column(
        children: [
          Container(
            color: const Color(0xffdfebfb),
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(child: Text(title, style: MeetingVisuals.title)),
                    IconButton(
                      tooltip: 'Expand meeting',
                      onPressed: onExpand,
                      icon: const Icon(Icons.open_in_full, size: 18),
                    ),
                    IconButton(
                      tooltip: 'Close meeting preview',
                      onPressed: onClose,
                      icon: const Icon(Icons.close, size: 18),
                    ),
                  ],
                ),
                Text(metadata, style: MeetingVisuals.metadata),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Wrap(
              spacing: 8,
              children: [
                for (final tab in ['Notes', 'AI summary', 'Transcript'])
                  TextButton(
                    onPressed: () => onTab(tab),
                    style: TextButton.styleFrom(
                      backgroundColor: selectedTab == tab
                          ? workspaceBlue
                          : Colors.transparent,
                      foregroundColor: selectedTab == tab
                          ? workspaceInk
                          : const Color(0xff50555b),
                    ),
                    child: Text(tab),
                  ),
              ],
            ),
          ),
          Expanded(child: content),
        ],
      ),
    );
  }
}
