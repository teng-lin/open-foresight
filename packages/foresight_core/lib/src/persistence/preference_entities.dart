import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';

enum _Kind {
  answerScope,
  webAnswer,
  conversation,
  proactive,
  selection,
  invalid,
}

final class _Key {
  const _Key(this.kind, this.owner, {this.meeting, this.answer, this.purpose});
  final _Kind kind;
  final String owner;
  final int? meeting, answer;
  final String? purpose;

  static int? integer(String text) {
    final value = int.tryParse(text);
    return value != null && '$value' == text ? value : null;
  }

  static _Key? parse(String key) {
    for (final prefix in ['answerScope.v1.', 'webAnswer.v1.']) {
      if (!key.startsWith(prefix)) continue;
      final owner = key.substring(prefix.length),
          id = integer(key.substring(prefix.length));
      return _Key(
        id == null
            ? _Kind.invalid
            : prefix == 'answerScope.v1.'
            ? _Kind.answerScope
            : _Kind.webAnswer,
        owner,
        answer: id,
      );
    }
    for (final entry in {
      'answerScope.': 'conversation',
      'answerSources.': 'answer',
      'proactiveScope.': 'proactive',
      'answerSourcesSelection.': 'picker',
      'preparationSources.': 'preparation',
    }.entries) {
      if (!key.startsWith(entry.key)) continue;
      final owner = key.substring(entry.key.length);
      if (owner.isEmpty) return const _Key(_Kind.invalid, '');
      final conversation =
          entry.value == 'conversation' || entry.value == 'answer';
      final meeting = conversation
          ? owner.startsWith('meeting:')
                ? integer(owner.substring(8))
                : null
          : integer(owner);
      if ((!conversation || owner.startsWith('meeting:')) && meeting == null) {
        return _Key(_Kind.invalid, owner);
      }
      return _Key(
        entry.value == 'conversation'
            ? _Kind.conversation
            : entry.value == 'proactive'
            ? _Kind.proactive
            : _Kind.selection,
        owner,
        meeting: meeting,
        purpose: conversation ? 'answer' : entry.value,
      );
    }
    return null;
  }
}

/// Compatibility for the public key/value command. Entity payloads live in
/// typed, owned rows; ordinary scalar keys keep their existing Store path.
final class PreferenceEntities {
  PreferenceEntities(this.db);
  final Database db;
  static const legacyRetention = Duration(days: 7);

  bool pruneLegacy() {
    db.execute(
      'DELETE FROM legacy_preference_entities WHERE key IN (SELECT key FROM legacy_preference_entities WHERE created<? ORDER BY created LIMIT 256)',
      [DateTime.now().subtract(legacyRetention).millisecondsSinceEpoch],
    );
    return db.updatedRows == 256;
  }

  String? read(String key) {
    final parsed = _Key.parse(key);
    if (parsed == null) return null;
    Object? value;
    switch (parsed.kind) {
      case _Kind.answerScope:
      case _Kind.webAnswer:
        final column = parsed.kind == _Kind.answerScope
            ? 'scope_identity'
            : 'web_answer';
        value = db.select(
          'SELECT $column AS value FROM answer_metadata WHERE answer_id=?',
          [parsed.answer],
        ).firstOrNull?['value'];
        if (value != null && parsed.kind == _Kind.webAnswer) {
          value = value == 1 ? 'true' : 'false';
        }
      case _Kind.conversation:
        value = db.select(
          'SELECT mode AS value FROM conversation_scopes WHERE conversation=?',
          [parsed.owner],
        ).firstOrNull?['value'];
      case _Kind.proactive:
        value = db.select(
          'SELECT mode AS value FROM proactive_scopes WHERE meeting_id=?',
          [parsed.meeting],
        ).firstOrNull?['value'];
      case _Kind.selection:
        if (db.select(
          'SELECT 1 FROM source_selections WHERE purpose=? AND owner=?',
          [parsed.purpose, parsed.owner],
        ).isNotEmpty) {
          value = jsonEncode([
            for (final row in db.select(
              'SELECT source_id FROM source_selection_items WHERE purpose=? AND owner=? ORDER BY position',
              [parsed.purpose, parsed.owner],
            ))
              row['source_id'],
          ]);
        }
      case _Kind.invalid:
        break;
    }
    return (value ??
            db.select(
              'SELECT value FROM legacy_preference_entities WHERE key=? AND created>=?',
              [
                key,
                DateTime.now().subtract(legacyRetention).millisecondsSinceEpoch,
              ],
            ).firstOrNull?['value'])
        as String?;
  }

  void _quarantine(
    String key,
    String value,
    _Key parsed,
    String reason, {
    int? answer,
    int? meeting,
  }) {
    var removed = false;
    switch (parsed.kind) {
      case _Kind.answerScope:
      case _Kind.webAnswer:
        final column = parsed.kind == _Kind.answerScope
            ? 'scope_identity'
            : 'web_answer';
        db.execute(
          'UPDATE answer_metadata SET $column=NULL WHERE answer_id=?',
          [parsed.answer],
        );
        removed = db.updatedRows > 0;
        db.execute(
          'DELETE FROM answer_metadata WHERE answer_id=? AND scope_identity IS NULL AND web_answer IS NULL',
          [parsed.answer],
        );
      case _Kind.conversation:
        db.execute('DELETE FROM conversation_scopes WHERE conversation=?', [
          parsed.owner,
        ]);
        removed = db.updatedRows > 0;
      case _Kind.proactive:
        db.execute('DELETE FROM proactive_scopes WHERE meeting_id=?', [
          parsed.meeting,
        ]);
        removed = db.updatedRows > 0;
      case _Kind.selection:
        db.execute(
          'DELETE FROM source_selections WHERE purpose=? AND owner=?',
          [parsed.purpose, parsed.owner],
        );
        removed = db.updatedRows > 0;
      case _Kind.invalid:
        break;
    }
    if (removed) {
      db.execute(
        "INSERT OR IGNORE INTO preferences(key,value) VALUES('internal.backupErasurePending','1')",
      );
    }
    db.execute('DELETE FROM legacy_preference_entities WHERE key=?', [key]);
    db.execute(
      'INSERT INTO legacy_preference_entities(key,value,reason,created,answer_id,meeting_id) VALUES(?,?,?,?,?,?)',
      [
        key,
        value,
        reason,
        DateTime.now().millisecondsSinceEpoch,
        answer,
        meeting,
      ],
    );
  }

  bool write(String key, String value) {
    final parsed = _Key.parse(key);
    if (parsed == null) return false;
    List<String>? selected;
    if (parsed.kind == _Kind.selection) {
      try {
        final decoded = jsonDecode(value);
        if (decoded is List && decoded.every((id) => id is String)) {
          selected = decoded.cast<String>();
        }
      } on FormatException {
        // Preserve the public key/value API; its existing reader fails closed.
      }
    }
    db.execute('SAVEPOINT write_preference_entity');
    try {
      final hasAnswer =
          parsed.answer == null ||
          db.select('SELECT 1 FROM answers WHERE id=?', [
            parsed.answer,
          ]).isNotEmpty;
      final hasMeeting =
          parsed.meeting == null ||
          db.select('SELECT 1 FROM meetings WHERE id=?', [
            parsed.meeting,
          ]).isNotEmpty;
      String? reason = parsed.kind == _Kind.invalid
          ? 'invalid_key'
          : !hasAnswer
          ? 'orphan_answer'
          : !hasMeeting
          ? 'orphan_meeting'
          : parsed.kind == _Kind.webAnswer &&
                value != 'true' &&
                value != 'false'
          ? 'invalid_web_flag'
          : parsed.kind == _Kind.selection && selected == null
          ? 'invalid_source_selection'
          : null;
      if (reason == null &&
          selected != null &&
          selected.any(
            (id) => db.select('SELECT 1 FROM sources WHERE id=?', [id]).isEmpty,
          )) {
        reason = 'missing_selected_source';
      }
      if (reason != null) {
        _quarantine(
          key,
          value,
          parsed,
          reason,
          answer: hasAnswer ? parsed.answer : null,
          meeting: hasMeeting ? parsed.meeting : null,
        );
      } else {
        switch (parsed.kind) {
          case _Kind.answerScope:
          case _Kind.webAnswer:
            final column = parsed.kind == _Kind.answerScope
                ? 'scope_identity'
                : 'web_answer';
            db.execute(
              'INSERT INTO answer_metadata(answer_id,$column) VALUES(?,?) ON CONFLICT(answer_id) DO UPDATE SET $column=excluded.$column',
              [
                parsed.answer,
                parsed.kind == _Kind.answerScope
                    ? value
                    : value == 'true'
                    ? 1
                    : 0,
              ],
            );
          case _Kind.conversation:
            db.execute(
              'INSERT INTO conversation_scopes(conversation,meeting_id,mode) VALUES(?,?,?) ON CONFLICT(conversation) DO UPDATE SET mode=excluded.mode',
              [parsed.owner, parsed.meeting, value],
            );
          case _Kind.proactive:
            db.execute(
              'INSERT INTO proactive_scopes(meeting_id,mode) VALUES(?,?) ON CONFLICT(meeting_id) DO UPDATE SET mode=excluded.mode',
              [parsed.meeting, value],
            );
          case _Kind.selection:
            final ids = selected!;
            db.execute(
              'INSERT OR IGNORE INTO source_selections(purpose,owner,meeting_id) VALUES(?,?,?)',
              [parsed.purpose, parsed.owner, parsed.meeting],
            );
            db.execute(
              'DELETE FROM source_selection_items WHERE purpose=? AND owner=?',
              [parsed.purpose, parsed.owner],
            );
            for (var position = 0; position < ids.length; position++) {
              db.execute(
                'INSERT INTO source_selection_items(purpose,owner,position,source_id) VALUES(?,?,?,?)',
                [parsed.purpose, parsed.owner, position, ids[position]],
              );
            }
          case _Kind.invalid:
            throw StateError('Unreachable invalid entity key');
        }
        db.execute('DELETE FROM legacy_preference_entities WHERE key=?', [key]);
      }
      db.execute('DELETE FROM preferences WHERE key=?', [key]);
      db.execute('RELEASE write_preference_entity');
    } catch (_) {
      if (!db.autocommit) {
        db.execute('ROLLBACK TO write_preference_entity');
        db.execute('RELEASE write_preference_entity');
      }
      rethrow;
    }
    return true;
  }
}
