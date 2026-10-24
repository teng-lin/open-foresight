import '../read_models.dart';

AnswerScopeSnapshot readAnswerScope(
  String Function(String key, [String fallback]) preference,
  String conversation, {
  int? meeting,
  bool automatic = false,
}) {
  final key = automatic
      ? 'proactiveScope.$meeting'
      : 'answerScope.$conversation';
  final mode = preference(key, automatic ? 'meeting' : 'workspace');
  return AnswerScopeSnapshot.fromPreferences(
    mode: mode,
    selectedJson: mode == 'selected'
        ? preference('answerSources.$conversation', '[]')
        : '[]',
    meeting: meeting,
  );
}
