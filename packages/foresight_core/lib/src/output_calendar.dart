/// Calendar weeks start on Monday in the user's local timezone. Constructing
/// dates avoids treating a daylight-saving week as seven 24-hour durations.
DateTime outputWeekStart(DateTime now, {int weeksAgo = 0}) {
  final local = now.toLocal();
  return DateTime(
    local.year,
    local.month,
    local.day - local.weekday + 1 - weeksAgo * 7,
  );
}
