import 'dart:convert';

/// One captured local Monday, including its absolute query boundary and label.
final class OutputStatsWeek {
  final int startMilliseconds, year, month, day;
  const OutputStatsWeek({
    required this.startMilliseconds,
    required this.year,
    required this.month,
    required this.day,
  });

  Map<String, Object?> toArguments() => {
    'start': startMilliseconds,
    'year': year,
    'month': month,
    'day': day,
  };

  factory OutputStatsWeek.fromArguments(Map<String, Object?> value) =>
      OutputStatsWeek(
        startMilliseconds: value['start'] as int,
        year: value['year'] as int,
        month: value['month'] as int,
        day: value['day'] as int,
      );
}

/// Stable calendar/zone scheduling identity, independent of the exact cutoff.
///
/// Capture on the caller's isolate, rather than letting the worker reinterpret
/// local dates after a timezone change. Calendar constructors preserve DST.
final class OutputStatsPeriod {
  final String zoneIdentity;
  final List<OutputStatsWeek> weeks;
  final int nextWeekMilliseconds;
  OutputStatsPeriod._({
    required this.zoneIdentity,
    required Iterable<OutputStatsWeek> weeks,
    required this.nextWeekMilliseconds,
  }) : weeks = List.unmodifiable(weeks);

  factory OutputStatsPeriod.capture(DateTime now) {
    final local = now.toLocal();
    DateTime monday(int weeksAgo) => DateTime(
      local.year,
      local.month,
      local.day - local.weekday + 1 - weeksAgo * 7,
    );
    return OutputStatsPeriod._(
      zoneIdentity: '${local.timeZoneName}:${local.timeZoneOffset.inSeconds}',
      weeks: [
        for (var i = 4; i >= 0; i--)
          () {
            final date = monday(i);
            return OutputStatsWeek(
              startMilliseconds: date.millisecondsSinceEpoch,
              year: date.year,
              month: date.month,
              day: date.day,
            );
          }(),
      ],
      nextWeekMilliseconds: monday(-1).millisecondsSinceEpoch,
    );
  }

  factory OutputStatsPeriod.fromArguments(Map<String, Object?> value) =>
      OutputStatsPeriod._(
        zoneIdentity: value['zone'] as String,
        weeks: (value['weeks'] as List).map(
          (week) => OutputStatsWeek.fromArguments(
            Map<String, Object?>.from(week as Map),
          ),
        ),
        nextWeekMilliseconds: value['next_week'] as int,
      );

  Map<String, Object?> toArguments() => {
    'zone': zoneIdentity,
    'weeks': weeks.map((week) => week.toArguments()).toList(),
    'next_week': nextWeekMilliseconds,
  };

  String get key => jsonEncode(toArguments());
}
