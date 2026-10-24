part of 'meetings_controller.dart';

extension _CollectionView on MeetingsController {
  String meetingClock(int milliseconds) {
    final date = DateTime.fromMillisecondsSinceEpoch(milliseconds).toLocal();
    return '${date.hour % 12 == 0 ? 12 : date.hour % 12}:${date.minute.toString().padLeft(2, '0')} ${date.hour < 12 ? 'AM' : 'PM'}';
  }

  int meetingStart(MeetingDetails meeting) =>
      (meeting.starts ?? meeting.created ?? 0);

  int meetingEnd(MeetingDetails meeting) =>
      (meeting.ends ??
      meetingStart(meeting) +
          (meeting.durationMs ?? const Duration(minutes: 30).inMilliseconds));

  String meetingDay(int timestamp) {
    if (timestamp == 0) return 'Saved meetings';
    final date = DateTime.fromMillisecondsSinceEpoch(timestamp).toLocal();
    final now = DateTime.now();
    if (date.year == now.year && date.month == now.month && date.day == now.day)
      return 'Today';
    return '${['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'][date.weekday - 1]}, ${['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'][date.month - 1]} ${date.day}';
  }

  Widget meetingListHeading() => heading(
    'Meetings',
    actions: [
      if (!_integrations.googlePresentation.connected)
        OutlinedButton.icon(
          onPressed: _operations.busy
              ? null
              : () => _operations.run(
                  _integrations.granolaCalendar
                      ? _integrationCommands.connectGranolaCalendar
                      : _integrationCommands.connectGoogle,
                ),
          icon: const Icon(Icons.calendar_today, size: 18),
          label: const Text('Connect Calendar'),
        ),
      if (_integrations.googlePresentation.connected)
        OutlinedButton.icon(
          onPressed: _operations.busy || _integrations.googleSyncing
              ? null
              : () => _operations.run(_integrationCommands.syncCalendar),
          icon: const Icon(Icons.calendar_today, size: 18),
          label: Text(
            _integrations.lastCompletedRefreshMilliseconds == 0
                ? 'Import Calendar'
                : 'Last imported: ${timeLabel(_integrations.lastCompletedRefreshMilliseconds)}',
          ),
        ),
      OutlinedButton.icon(
        onPressed: _operations.busy
            ? null
            : () => _operations.run(exportMeetings),
        icon: const Icon(Icons.ios_share, size: 18),
        label: const Text('Export meeting notes'),
      ),
      pill(
        'New meeting',
        _operations.busy || recording != null
            ? null
            : () => _operations.run(() async {
                final epoch = d.workspaceEpoch;
                final created =
                    await newMeetingKey.run(
                          {'title': '[New Meeting]'},
                          (keyed) => d.command(Operation.meetingsCreate, {
                            ...keyed,
                            if (epoch != null) 'workspace_epoch': epoch,
                          }),
                        )
                        as Map;
                if (mounted && d.workspaceEpoch == epoch)
                  update(() => meetingId = created['id'] as int);
              }),
        icon: Icons.add,
      ),
    ],
  );

  Widget meetingList({bool showHeading = true}) {
    final rows = _reads.meetings
        .where(
          (m) => m.title.toLowerCase().contains(meetingQuery.toLowerCase()),
        )
        .toList();
    final now = DateTime.now().millisecondsSinceEpoch;
    var insertedNow = false;
    Widget nowMarker() => Padding(
      key: meetingNowKey,
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Row(
        children: [
          const Expanded(child: Divider(color: Color(0xff8cb2c9))),
          const SizedBox(width: 12),
          Chip(
            backgroundColor: workspaceBlue,
            label: Text(
              '●  Now · ${meetingClock(now)}',
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
    final entries = <Widget>[];
    String? previousDay;
    for (final meeting in rows) {
      if (!insertedNow && meetingStart(meeting) > now) {
        entries.add(nowMarker());
        insertedNow = true;
      }
      final day = meetingDay(meetingStart(meeting));
      if (day != previousDay) {
        entries.add(
          Padding(
            padding: const EdgeInsets.only(top: 12, bottom: 16),
            child: Text(day, style: MeetingVisuals.dateHeading),
          ),
        );
        previousDay = day;
      }
      entries.add(
        Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: meetingListTile(meeting),
        ),
      );
    }
    if (!insertedNow && rows.isNotEmpty) entries.add(nowMarker());
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (showHeading) meetingListHeading(),
        searchBox(
          'Search meetings',
          (value) => meetingQuery = value,
          controller: meetingSearchController,
        ),
        const SizedBox(height: 16),
        OutlinedButton.icon(
          onPressed: () {
            meetingSearchController.clear();
            update(() => meetingQuery = '');
            WidgetsBinding.instance.addPostFrameCallback((_) {
              final target = meetingNowKey.currentContext;
              if (target != null)
                // The callback intentionally schedules work owned by its controller.
                // ignore: discarded_futures
                Scrollable.ensureVisible(
                  target,
                  duration: const Duration(milliseconds: 250),
                  alignment: .5,
                );
            });
          },
          icon: const Icon(Icons.schedule, size: 18),
          label: const Text('Now'),
        ),
        const SizedBox(height: 24),
        Expanded(
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (rows.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(40),
                    child: Text(
                      'No meetings yet. Start transcribing or create a new meeting.',
                    ),
                  ),
                ...entries,
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget meetingListTile(MeetingCollectionEntry meeting) {
    final id = meeting.id;
    final start = meetingStart(meeting);
    final end = meetingEnd(meeting);
    final attachmentCount = _reads.attachments(id).length;
    final state = meeting.state;
    final active = state == 'recording' || state == 'transcribing';
    void open() => update(() {
      forgetPendingMeetingCreates();
      meetingPreviewId = id;
    });
    return Card(
      margin: EdgeInsets.zero,
      shape: const RoundedRectangleBorder(
        borderRadius: MeetingVisuals.previewRadius,
      ),
      color: meetingPreviewId == id ? const Color(0xffd2deee) : Colors.white,
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
                  '${meetingClock(start)} – ${meetingClock(end)}',
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
            onTap: open,
            borderRadius: BorderRadius.circular(16),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
              child: Row(
                children: [
                  if (!narrow && start > 0)
                    SizedBox(
                      width: 155,
                      child: Text(
                        '${meetingClock(start)} – ${meetingClock(end)}',
                        style: MeetingVisuals.metadata,
                      ),
                    ),
                  Expanded(child: details),
                  const SizedBox(width: 8),
                  OutlinedButton(
                    onPressed: open,
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
                    onPressed:
                        _operations.busy || recording != null || quickStarting
                        ? null
                        : () => recordExistingMeeting(id),
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

  Widget meetingCollection() {
    final id = meetingPreviewId;
    if (id == null) return meetingList();
    return LayoutBuilder(
      builder: (context, constraints) {
        final preview = meetingPreview(id);
        if (constraints.maxWidth < 900) return preview;
        return Column(
          children: [
            meetingListHeading(),
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(flex: 6, child: meetingList(showHeading: false)),
                  const SizedBox(width: 24),
                  Expanded(flex: 4, child: preview),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget meetingPreview(int id) {
    final meeting = _reads.meeting(id, preview: true);
    if (meeting == null)
      return Center(
        child: Text(
          _reads.meetingLoaded(id, preview: true)
              ? 'Meeting no longer exists.'
              : 'Loading meeting…',
        ),
      );
    final start = meetingStart(meeting);
    final end = meetingEnd(meeting);
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
                    Expanded(
                      child: Text(meeting.title, style: MeetingVisuals.title),
                    ),
                    IconButton(
                      tooltip: 'Expand meeting',
                      onPressed: () => update(() {
                        forgetPendingMeetingCreates();
                        meetingId = id;
                      }),
                      icon: const Icon(Icons.open_in_full, size: 18),
                    ),
                    IconButton(
                      tooltip: 'Close meeting preview',
                      onPressed: () async {
                        try {
                          await flushMeetingNotesDraft();
                        } catch (_) {
                          return;
                        }
                        if (mounted) update(() => meetingPreviewId = null);
                      },
                      icon: const Icon(Icons.close, size: 18),
                    ),
                  ],
                ),
                Text(
                  '${meetingDay(start)} · ${meetingClock(start)} – ${meetingClock(end)}',
                  style: MeetingVisuals.metadata,
                ),
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
                    onPressed: () => update(() => meetingPreviewTab = tab),
                    style: TextButton.styleFrom(
                      backgroundColor: meetingPreviewTab == tab
                          ? workspaceBlue
                          : Colors.transparent,
                      foregroundColor: meetingPreviewTab == tab
                          ? workspaceInk
                          : const Color(0xff50555b),
                    ),
                    child: Text(tab),
                  ),
              ],
            ),
          ),
          Expanded(
            child: switch (meetingPreviewTab) {
              'Transcript' => meetingTranscriptPanel(id),
              'AI summary' => meetingSummaryPanel(id),
              _ => meetingNotesEditor(id, false, preview: true),
            },
          ),
        ],
      ),
    );
  }
}
