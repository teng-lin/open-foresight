import 'desktop_read_models.dart' show AnswerScopeSnapshot;
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
    final key = automatic
        ? 'proactiveScope.$meeting'
        : 'answerScope.$conversation';
    final mode = store.preference(key, automatic ? 'meeting' : 'workspace');
    final scope = AnswerScopeSnapshot.fromPreferences(
      mode: mode,
      selectedJson: mode == 'selected'
          ? store.preference('answerSources.$conversation', '[]')
          : '[]',
      meeting: meeting,
    );
    return AnswerSourceScope(scope.mode, scope.ids?.toSet());
  }
}
