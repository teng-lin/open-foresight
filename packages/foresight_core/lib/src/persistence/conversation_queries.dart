import 'answer_passage_queries.dart';
import '../store.dart';
import '../read_models.dart';
import '../reference_chat_history.dart';
import 'dart:convert';
import 'read_schema_guard.dart';

typedef ConversationCheckpoint = ({
  int throughAnswerId,
  String messages,
  String? tokenCounts,
});

/// Conversation persistence shares the service writer; no phase owns SQL or
/// a separate transaction. The answer, scope, checkpoint and meeting link
/// commit together in the existing savepoint.
class ConversationQueries {
  ConversationQueries(this._store);
  final Store _store;
  List<Map<String, Object?>> _rows(
    String sql, [
    List<Object?> args = const [],
  ]) => readSnapshot(
    _store.db,
    () => _store.rows(sql, args),
    supportedVersion: Store.schemaVersion,
  );
  String get path => _store.path;
  int? savedAnswerId(String request) =>
      _rows(
            'SELECT id FROM answers WHERE request_id=? ORDER BY id DESC LIMIT 1',
            [request],
          ).firstOrNull?['id']
          as int?;
  ModelRegistration? model(String kind) => _store.sourceQueries.model(kind);
  List<SourceSummary> get sourceSummaries => _store.sourceQueries.summaries();
  bool meetingExists(int id) =>
      _rows('SELECT id FROM meetings WHERE id=?', [id]).isNotEmpty;
  String? previousQuestion(
    String conversation, {
    required bool privateScope,
    required String scopeIdentity,
  }) =>
      _rows(
            "SELECT question FROM answers WHERE conversation=? ${privateScope ? "AND EXISTS(SELECT 1 FROM answer_metadata WHERE answer_id=answers.id AND scope_identity=?)" : ''} ORDER BY id DESC LIMIT 1",
            [conversation, if (privateScope) scopeIdentity],
          ).firstOrNull?['question']
          as String?;
  bool sourceIsCurrent(String id, Object? revision) {
    final live = _rows(
      'SELECT revision,deleted,state FROM sources WHERE id=?',
      [id],
    );
    return live.isNotEmpty &&
        live.first['deleted'] == 0 &&
        live.first['revision'] == revision &&
        live.first['state'] == 'indexed';
  }

  List<ConversationCheckpoint> checkpoint(
    String memoryKey,
    String conversation,
  ) =>
      _rows(
            "SELECT through_answer_id,messages,token_counts FROM conversation_memory WHERE conversation=? "
            "AND EXISTS(SELECT 1 FROM answers WHERE id=through_answer_id AND conversation=? "
            "AND EXISTS(SELECT 1 FROM answer_metadata WHERE answer_id=answers.id AND web_answer=1))",
            [memoryKey, conversation],
          )
          .map(
            (row) => (
              throughAnswerId: row['through_answer_id'] as int,
              messages: row['messages'] as String,
              tokenCounts: row['token_counts'] as String?,
            ),
          )
          .toList();
  List<SavedAnswer> history(
    String conversation, {
    required bool web,
    required int through,
    required bool privateScope,
    required String scopeIdentity,
  }) =>
      (web
              ? _rows(
                  "SELECT id,question,body,model_response FROM answers WHERE conversation=? AND status='completed' AND id>? "
                  "AND EXISTS(SELECT 1 FROM answer_metadata WHERE answer_id=answers.id AND web_answer=1) ${privateScope ? "AND EXISTS(SELECT 1 FROM answer_metadata WHERE answer_id=answers.id AND scope_identity=?)" : ''} ORDER BY id",
                  [conversation, through, if (privateScope) scopeIdentity],
                )
              : _rows(
                  "SELECT question,body,model_response FROM answers WHERE conversation=? AND status='completed' ${privateScope ? "AND EXISTS(SELECT 1 FROM answer_metadata WHERE answer_id=answers.id AND scope_identity=?)" : ''} ORDER BY id DESC LIMIT 4",
                  [conversation, if (privateScope) scopeIdentity],
                ).reversed.toList())
          .map(SavedAnswer.fromRow)
          .toList();
  String get generationDigest =>
      _rows(
            "SELECT digest FROM models WHERE kind='generation'",
          ).firstOrNull?['digest']
          as String? ??
      'unknown';

  List<Map<String, Object?>> answerPassages(
    String question,
    Map<String, Object?> revisions,
    List<Map<String, Object?>> semantic,
  ) => readAnswerPassages(
    _store.db,
    question,
    revisions,
    semantic,
    supportedVersion: Store.schemaVersion,
  );

  void save(
    String question,
    String body,
    String status,
    List<Map<String, Object?>> citations,
    String model, {
    required String conversation,
    required String scopeIdentity,
    required bool privateScope,
    required String memoryKey,
    String? requestId,
    int? meetingId,
    Map<String, dynamic>? modelResponse,
    List<Map<String, dynamic>>? memoryMessages,
    List<int>? memoryTokenCounts,
    int? historyThroughAnswerId,
  }) {
    _store.db.execute('SAVEPOINT persist_conversation_answer');
    try {
      _store.answer(
        question,
        body,
        status,
        citations,
        model,
        conversation: conversation,
        requestId: requestId,
        modelResponse: modelResponse,
      );
      // Capture before checkpoint writes can change lastInsertRowId.
      final answerId = _store.db.lastInsertRowId;
      _store.setPreference('answerScope.v1.$answerId', scopeIdentity);
      if (memoryMessages != null) {
        _store.setPreference('webAnswer.v1.$answerId', 'true');
        // A completed turn may have arrived while this request was generating.
        // Keep it between the replayed snapshot and this request's own pair.
        final intervening = referenceChatHistory(
          _store.rows(
            "SELECT question,body,model_response FROM answers WHERE conversation=? AND status='completed' AND id>? AND id<? "
            "AND EXISTS(SELECT 1 FROM answer_metadata WHERE answer_id=answers.id AND web_answer=1) ${privateScope ? "AND EXISTS(SELECT 1 FROM answer_metadata WHERE answer_id=answers.id AND scope_identity=?)" : ''} ORDER BY id",
            [
              conversation,
              historyThroughAnswerId!,
              answerId,
              if (privateScope) scopeIdentity,
            ],
          ),
        );
        final committedMessages = [
          ...memoryMessages.take(memoryMessages.length - 2),
          ...intervening,
          ...memoryMessages.skip(memoryMessages.length - 2),
        ];
        _store.db.execute(
          'INSERT INTO conversation_memory(conversation,through_answer_id,messages,token_counts) VALUES(?,?,?,?) '
          'ON CONFLICT(conversation) DO UPDATE SET through_answer_id=excluded.through_answer_id,messages=excluded.messages,token_counts=excluded.token_counts',
          [
            memoryKey,
            answerId,
            jsonEncode(committedMessages),
            jsonEncode([
              ...memoryTokenCounts!.take(memoryTokenCounts.length - 2),
              ...List<int?>.filled(intervening.length, null),
              ...memoryTokenCounts.skip(memoryTokenCounts.length - 2),
            ]),
          ],
        );
      }
      if (meetingId != null) {
        _store.db.execute(
          'INSERT INTO meeting_answers(meeting_id,answer_id) VALUES(?,?)',
          [meetingId, answerId],
        );
      }
      _store.db.execute('RELEASE persist_conversation_answer');
    } catch (_) {
      _store.db.execute('ROLLBACK TO persist_conversation_answer');
      _store.db.execute('RELEASE persist_conversation_answer');
      rethrow;
    }
  }
}
