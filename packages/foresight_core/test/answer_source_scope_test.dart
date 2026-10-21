import 'dart:io';
import 'package:foresight_core/src/answer_source_scope.dart';
import 'package:foresight_core/foresight_core.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late Store store;
  setUp(() {
    root = createTestTempDirectorySync('answer-scope-');
    store = Store('${root.path}/app.db');
  });
  tearDown(() {
    store.close();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });
  test(
    'automatic meeting scope is explicit and selected scope never widens',
    () {
      final scope = AnswerSourceScope.read(
        store,
        'meeting:1',
        meeting: 1,
        automatic: true,
      );
      expect(scope.ids, contains('meeting-1'));
      expect(scope.ids, isNot(contains('unrelated')));
      expect(AnswerSourceScope.read(store, 'desktop').ids, isNull);
      store.setPreference('proactiveScope.1', 'selected');
      expect(
        AnswerSourceScope.read(
          store,
          'meeting:1',
          meeting: 1,
          automatic: true,
        ).ids,
        isEmpty,
      );
      store.setPreference('answerSources.meeting:1', '["chosen"]');
      final selected = AnswerSourceScope.read(
        store,
        'meeting:1',
        meeting: 1,
        automatic: true,
      );
      expect(selected.ids, {'chosen'});
      expect(selected.identity, isNot(scope.identity));
      store.setPreference('answerSources.meeting:1', '[123]');
      expect(
        () => AnswerSourceScope.read(
          store,
          'meeting:1',
          meeting: 1,
          automatic: true,
        ),
        throwsStateError,
      );
    },
  );
  test('invalid scope does not fall back to workspace', () {
    store.setPreference('answerScope.desktop', 'invalid');
    expect(() => AnswerSourceScope.read(store, 'desktop'), throwsStateError);
  });
}
