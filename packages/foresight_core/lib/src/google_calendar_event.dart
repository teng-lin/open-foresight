import 'dart:convert';
import 'dart:typed_data';
import 'web_import.dart';

DateTime? googleCalendarEventTime(Object? value) {
  if (value is! Map) return null;
  return DateTime.tryParse(
    (value['dateTime'] ?? value['date'])?.toString() ?? '',
  );
}

/// Validated remote calendar data; SQL and meeting identity stay in persistence.
final class GoogleCalendarUpdate {
  final String key, account, calendar, title, status, metadata;
  final Object? eventId;
  final int? starts, ends;
  const GoogleCalendarUpdate({
    required this.key,
    required this.account,
    required this.calendar,
    required this.eventId,
    required this.title,
    required this.status,
    required this.metadata,
    this.starts,
    this.ends,
  });

  factory GoogleCalendarUpdate.fromEvent(
    String key,
    String account,
    String calendar,
    Map<String, dynamic> event,
  ) {
    final cancelled = event['status'] == 'cancelled';
    final starts = cancelled
        ? null
        : googleCalendarEventTime(event['start'])?.millisecondsSinceEpoch;
    final ends = cancelled
        ? null
        : googleCalendarEventTime(event['end'])?.millisecondsSinceEpoch;
    final valid = !cancelled && starts != null && ends != null;
    return GoogleCalendarUpdate(
      key: key,
      account: account,
      calendar: calendar,
      eventId: event['id'],
      starts: starts,
      ends: ends,
      title: valid ? event['summary'] as String? ?? '[Untitled meeting]' : '',
      status: cancelled
          ? 'cancelled'
          : valid
          ? event['status'] as String? ?? 'confirmed'
          : 'confirmed',
      metadata: valid ? jsonEncode(event) : '',
    );
  }
}

/// A bounded linear scan avoids regex backtracking on untrusted invitations.
Future<String> calendarDescriptionText(String description) async {
  final text = description.length > 256 * 1024
      ? description.substring(0, 256 * 1024)
      : description;
  try {
    // A stricter invitation cap rejects pathological markup before parser startup.
    if ('<'.allMatches(text).length > 4096) {
      throw StateError('Too much invitation markup');
    }
    return await parseWebPage(
      Uint8List.fromList(utf8.encode(text)),
      mimeType: 'text/html',
    );
  } catch (_) {
    // Fall back to a bounded linear scan, never an unbounded regular expression.
  }
  final output = StringBuffer();
  var inTag = false;
  for (final unit in text.codeUnits) {
    if (unit == 60) {
      if (!inTag) output.write(' ');
      inTag = true;
    } else if (unit == 62 && inTag) {
      inTag = false;
    } else if (!inTag) {
      output.writeCharCode(unit);
    }
  }
  return output.toString();
}
