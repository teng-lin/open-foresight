import 'dart:convert';
import 'store.dart';
import 'summary_generator.dart';

class AnswerSourceScope {
  AnswerSourceScope(this.mode, this.ids);
  final String mode;
  final Set<String>? ids;
  String get identity => summaryDigest(
    jsonEncode([mode, ids == null ? null : (ids!.toList()..sort())]),
  );
  static AnswerSourceScope read(
    Store store,
    String conversation, {
    int? meeting,
    bool automatic = false,
  }) {
    final key = automatic
        ? 'proactiveScope.$meeting'
        : 'answerScope.$conversation';
    final mode = store.preference(key, automatic ? 'meeting' : 'workspace');
    if (mode == 'workspace') return AnswerSourceScope(mode, null);
    if (mode == 'meeting' && meeting != null) {
      return AnswerSourceScope(mode, {
        'meeting-$meeting',
        'meeting-summary-$meeting',
        'meeting-actions-$meeting',
        'meeting-enhanced_notes-$meeting',
        'meeting-preparation-$meeting',
      });
    }
    if (mode == 'selected') {
      final decoded = jsonDecode(
        store.preference('answerSources.$conversation', '[]'),
      );
      if (decoded is! List ||
          decoded.length > 100 ||
          decoded.any((id) => id is! String)) {
        throw StateError('Invalid selected answer sources');
      }
      return AnswerSourceScope(mode, decoded.cast<String>().toSet());
    }
    throw StateError('Invalid answer source scope');
  }
}
