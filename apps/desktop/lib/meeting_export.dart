import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:foresight_core/desktop.dart' show StoreReader;
import 'generated_content.dart';

enum MeetingExportPeriod {
  anytime('Anytime'),
  today('Today'),
  last7Days('Last 7 days'),
  last30Days('Last 30 days'),
  last90Days('Last 90 days'),
  custom('Custom');

  const MeetingExportPeriod(this.label);
  final String label;
}

/// Original presets subtract elapsed 24-hour days from today's local midnight.
/// Custom dates use local calendar midnights. Both include the final date.
DateTimeRange? meetingExportRange(
  MeetingExportPeriod period,
  DateTime now, {
  DateTimeRange? custom,
}) {
  if (period == MeetingExportPeriod.anytime) return null;
  final today = DateTime(now.year, now.month, now.day);
  if (period == MeetingExportPeriod.custom) {
    return custom == null
        ? null
        : DateTimeRange(
            start: DateTime(
              custom.start.year,
              custom.start.month,
              custom.start.day,
            ),
            end: DateTime(custom.end.year, custom.end.month, custom.end.day),
          );
  }
  final days = switch (period) {
    MeetingExportPeriod.last7Days => 7,
    MeetingExportPeriod.last30Days => 30,
    MeetingExportPeriod.last90Days => 90,
    _ => 1,
  };
  return DateTimeRange(
    start: today.subtract(Duration(days: days - 1)),
    end: today,
  );
}

class MeetingExportContent {
  const MeetingExportContent(this.markdown, this.count);
  final String markdown;
  final int count;
}

MeetingExportContent composeMeetingExport(
  StoreReader store, {
  DateTimeRange? range,
}) {
  final start = range?.start;
  final end = range?.end;
  final lower = start?.millisecondsSinceEpoch;
  final upper = end == null
      ? null
      : DateTime(end.year, end.month, end.day + 1).millisecondsSinceEpoch;
  final output = <String>[];
  // Acquire the original global note limit before excluding empty bodies or
  // applying date filters. Legacy NULL save times retain SQLite's DESC order.
  final notesToExport = store.exportNotes.map((note) => note.toRow());
  for (final meeting in notesToExport) {
    final date = meeting['export_date'] as int;
    if (lower != null && (date < lower || date >= upper!)) continue;
    final enhanced = (meeting['enhanced_body'] as String?)?.trim();
    final notes = enhanced == null || enhanced.isEmpty
        ? (meeting['body'] as String).trim()
        : enhanced;
    if (notes.isEmpty) continue;
    final begins = DateTime.fromMillisecondsSinceEpoch(date);
    final end = meeting['export_end'] as int?;
    final ends = end == null ? null : DateTime.fromMillisecondsSinceEpoch(end);
    final dateLine =
        '${DateFormat('MMM d, yyyy').format(begins)} ${_exportClock(begins)}'
        '${ends == null ? '' : ' - ${_exportClock(ends)}'}';
    final metadata = meeting['export_metadata'] as String?;
    final event = metadata == null
        ? null
        : jsonDecode(metadata) as Map<String, dynamic>;
    final url = event?['htmlLink'] as String?;
    final noteTitle = (meeting['title'] as String).trim();
    final associationTitle = meeting['association_title'] as String?;
    final eventTitle = event?['summary'] as String?;
    final title = noteTitle.isNotEmpty
        ? noteTitle
        : associationTitle != null && associationTitle.isNotEmpty
        ? associationTitle
        : eventTitle != null && eventTitle.isNotEmpty
        ? eventTitle
        : 'Untitled meeting';
    final linkedDate = url == null || url.isEmpty
        ? dateLine
        : '[$dateLine]($url)';
    output.add('## $title\n$linkedDate\n\n$notes\n');
  }
  // composeExportMarkdown writes three blank lines before each later item;
  // every item already ends with the newline after its trimmed note body.
  return MeetingExportContent(output.join('\n\n\n'), output.length);
}

String _exportClock(DateTime time) =>
    DateFormat('h:mma').format(time).toLowerCase();

class MeetingExportDialog extends StatefulWidget {
  const MeetingExportDialog({
    super.key,
    required this.store,
    required this.save,
    this.now,
  });
  final StoreReader store;
  final Future<bool> Function(String) save;
  final DateTime? now;

  @override
  State<MeetingExportDialog> createState() => _MeetingExportDialogState();
}

class _MeetingExportDialogState extends State<MeetingExportDialog> {
  MeetingExportPeriod period = MeetingExportPeriod.last7Days;
  late DateTimeRange custom;
  String status = '';
  bool saving = false;

  @override
  void initState() {
    super.initState();
    final now = widget.now ?? DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    custom = DateTimeRange(start: today, end: today);
  }

  Future<void> filter() async {
    var draftPeriod = period;
    var draftCustom = custom;
    final selection = await showDialog<(MeetingExportPeriod, DateTimeRange)>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, updateFilter) {
          final dates = MaterialLocalizations.of(context);
          Future<void> pickDate(bool start) async {
            final picked = await showDatePicker(
              context: context,
              initialDate: start ? draftCustom.start : draftCustom.end,
              firstDate: DateTime(1970),
              lastDate: DateTime(2200),
            );
            if (picked == null || !context.mounted) return;
            updateFilter(() {
              draftCustom = start
                  ? DateTimeRange(
                      start: picked,
                      end: picked.isAfter(draftCustom.end)
                          ? picked
                          : draftCustom.end,
                    )
                  : DateTimeRange(
                      start: picked.isBefore(draftCustom.start)
                          ? picked
                          : draftCustom.start,
                      end: picked,
                    );
            });
          }

          return AlertDialog(
            scrollable: true,
            title: const Text('Filter meeting notes'),
            content: SizedBox(
              width: 360,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  DropdownButtonFormField<MeetingExportPeriod>(
                    initialValue: draftPeriod,
                    decoration: const InputDecoration(labelText: 'Date range'),
                    items: [
                      for (final value in MeetingExportPeriod.values)
                        DropdownMenuItem(
                          value: value,
                          child: Text(value.label),
                        ),
                    ],
                    onChanged: (value) =>
                        updateFilter(() => draftPeriod = value!),
                  ),
                  if (draftPeriod == MeetingExportPeriod.custom)
                    Wrap(
                      spacing: 12,
                      children: [
                        TextButton(
                          onPressed: () => pickDate(true),
                          child: Text(
                            'Start date: ${dates.formatCompactDate(draftCustom.start)}',
                          ),
                        ),
                        TextButton(
                          onPressed: () => pickDate(false),
                          child: Text(
                            'End date: ${dates.formatCompactDate(draftCustom.end)}',
                          ),
                        ),
                      ],
                    ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () =>
                    Navigator.pop(context, (draftPeriod, draftCustom)),
                child: const Text('Apply'),
              ),
            ],
          );
        },
      ),
    );
    if (selection == null || !mounted) return;
    setState(() {
      period = selection.$1;
      custom = selection.$2;
      status = '';
    });
  }

  Future<void> perform(Future<String> Function() action) async {
    setState(() {
      saving = true;
      status = '';
    });
    try {
      final result = await action();
      if (mounted) setState(() => status = result);
    } catch (error) {
      if (mounted) setState(() => status = 'Export failed: $error');
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final range = meetingExportRange(
      period,
      widget.now ?? DateTime.now(),
      custom: custom,
    );
    final content = composeMeetingExport(widget.store, range: range);
    final canExport = !saving && content.count > 0;
    return AlertDialog(
      scrollable: true,
      title: const Text('Export meeting notes'),
      content: SizedBox(
        width: 720,
        height: 520,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextButton.icon(
              onPressed: saving ? null : filter,
              icon: const Icon(Icons.filter_list),
              label: Text('Date range: ${period.label}'),
            ),
            const SizedBox(height: 12),
            Text('${content.count} meetings'),
            const SizedBox(height: 8),
            Expanded(
              child: SingleChildScrollView(
                child: content.count == 0
                    ? const SelectableText(
                        'No meeting notes found for the selected date range.',
                        key: ValueKey('meeting-export-preview'),
                      )
                    : GeneratedContent(
                        content.markdown,
                        key: const ValueKey('meeting-export-preview'),
                      ),
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Pasting into a Google Doc? Use "Paste as markdown" to keep the formatting.',
            ),
            if (status.isNotEmpty)
              Text(status, key: const ValueKey('meeting-export-status')),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: saving ? null : () => Navigator.pop(context),
          child: const Text('Close'),
        ),
        TextButton(
          onPressed: !canExport
              ? null
              : () => perform(() async {
                  await Clipboard.setData(
                    ClipboardData(text: content.markdown),
                  );
                  return 'Copied to clipboard';
                }),
          child: const Text('Copy markdown'),
        ),
        FilledButton(
          onPressed: !canExport
              ? null
              : () => perform(
                  () async => await widget.save(content.markdown)
                      ? 'Meeting notes saved successfully'
                      : '',
                ),
          child: const Text('Download markdown'),
        ),
      ],
    );
  }
}
