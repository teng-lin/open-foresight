import 'persistence/answer_scope_queries.dart';
import 'read_models.dart' show AnswerScopeSnapshot;
import 'store.dart';

class AnswerSourceScope {
  AnswerSourceScope(this.mode, this.ids);
  final String mode;
  final Set<String>? ids;
  String get identity => AnswerScopeSnapshot(mode: mode, ids: ids).identity;
  static AnswerSourceScope read(
    Store store,
    String conversation, {
    int? meeting,
    bool automatic = false,
  }) {
    final scope = readAnswerScope(
      store.preference,
      conversation,
      meeting: meeting,
      automatic: automatic,
    );
    return AnswerSourceScope(scope.mode, scope.ids?.toSet());
  }
}
