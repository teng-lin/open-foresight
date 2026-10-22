import 'package:sqlite3/sqlite3.dart';
import 'read_schema_guard.dart';

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

class OutputStatistics {
  final Database db;
  final int supportedVersion;
  final String Function() _dataRevision;
  OutputStatistics(
    this.db, {
    required this.supportedVersion,
    required String Function() dataRevision,
  }) : _dataRevision = dataRevision;
  List<Map<String, Object?>> _rows(String sql) =>
      db.select(sql).map((row) => Map<String, Object?>.from(row)).toList();
  String? _outputStatsRevision;
  int _localOutputWords = 0;
  List<({int? created, int words})> _outputWordCounts = [];

  void _refreshOutputStats() {
    final revision = _dataRevision();
    readSnapshot(db, () {
      if (_outputStatsRevision == revision) return;
      int words(String text) => RegExp(r'\S+').allMatches(text).length;
      _outputWordCounts = [
        for (final row in _rows(
          "SELECT body,created FROM answers WHERE status='completed'",
        ))
          (created: row['created'] as int, words: words(row['body'] as String)),
        for (final row in _rows('SELECT generated,created FROM artifacts'))
          (
            created: row['created'] as int?,
            words: words(row['generated'] as String),
          ),
      ];
      _localOutputWords = _outputWordCounts.fold<int>(
        0,
        (sum, row) => sum + row.words,
      );
      _outputStatsRevision = revision;
    }, supportedVersion: supportedVersion);
  }

  /// Saved text has no tokenizer usage metadata. Report words honestly and cache
  /// the scan across builds until the WAL snapshot or this connection changes.
  int get localOutputWords {
    _refreshOutputStats();
    return _localOutputWords;
  }

  List<int> weeklyOutputWords(DateTime now, {List<int>? weekStarts}) {
    final starts =
        weekStarts ??
        [
          for (var i = 0; i < 5; i++)
            outputWeekStart(now, weeksAgo: 4 - i).millisecondsSinceEpoch,
        ];
    return weeklyOutputWordsAt(
      cutoffMilliseconds: now.millisecondsSinceEpoch,
      weekStarts: starts,
    );
  }

  List<int> weeklyOutputWordsAt({
    required int cutoffMilliseconds,
    required List<int> weekStarts,
  }) {
    _refreshOutputStats();
    final weekly = List<int>.filled(weekStarts.length, 0);
    for (final row in _outputWordCounts) {
      final created = row.created;
      if (created == null || created > cutoffMilliseconds) continue;
      for (var i = weekStarts.length - 1; i >= 0; i--) {
        if (created >= weekStarts[i]) {
          weekly[i] += row.words;
          break;
        }
      }
    }
    return weekly;
  }

  List<int> weeklyAnswerWords(DateTime now) => weeklyOutputWords(now);
}
