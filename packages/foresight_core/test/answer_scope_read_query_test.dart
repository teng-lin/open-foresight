import 'sql_support_test_bootstrap.dart';
import 'dart:convert';

import 'package:foresight_core/desktop.dart'
    show AnswerScopeSnapshot, RpcErrorCode, StoreReadQueries;
import 'package:foresight_core/src/answer_source_scope.dart';
import 'package:foresight_core/src/sqlite_read_session.dart';
import 'package:foresight_core/src/sqlite_store_reader.dart';
import 'package:foresight_core/src/store.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';

class InterleavedScopeStore extends Store {
  InterleavedScopeStore(super.path, this.afterModeRead) : super.readOnly();
  void Function()? afterModeRead;

  @override
  String preference(String key, [String fallback = '']) {
    final value = super.preference(key, fallback);
    if (key == 'answerScope.desktop') {
      final callback = afterModeRead;
      afterModeRead = null;
      callback?.call();
    }
    return value;
  }
}

void main() {
  bootstrapSqlSupportFixture();
  late Store writer;
  late SqliteStoreReader reader;
  late String path;
  setUp(() {
    final root = createTestTempDirectorySync('answer-scope-query-');
    path = '${root.path}/app.db';
    writer = Store(path);
    reader = SqliteStoreReader.open(
      path,
      profile: 'scope-fixture',
      connection: 'scope-connection',
    );
    addTearDown(() async {
      await reader.close();
      writer.close();
    });
  });

  Future<AnswerScopeSnapshot> read({
    String conversation = 'desktop',
    int? meeting,
    bool automatic = false,
  }) async {
    final result = await reader.read(
      StoreReadQueries.answerScope(
        conversation,
        meeting: meeting,
        automatic: automatic,
      ),
    );
    expect(result.error, isNull);
    expect(result.current, isTrue);
    final expected = AnswerSourceScope.read(
      writer,
      conversation,
      meeting: meeting,
      automatic: automatic,
    );
    final scope = result.value!;
    expect(scope.mode, expected.mode);
    expect(scope.ids, expected.ids);
    expect(scope.identity, expected.identity);
    final captured = AnswerScopeSnapshot.fromPreferences(
      mode: writer.preference(
        automatic ? 'proactiveScope.$meeting' : 'answerScope.$conversation',
        automatic ? 'meeting' : 'workspace',
      ),
      selectedJson: writer.preference('answerSources.$conversation', '[]'),
      meeting: meeting,
    );
    expect(captured.mode, scope.mode);
    expect(captured.ids, scope.ids);
    expect(captured.identity, scope.identity);
    return scope;
  }

  test('scope query preserves manual and automatic defaults', () async {
    final manual = await read();
    expect(manual.mode, 'workspace');
    expect(manual.ids, isNull);
    expect(
      manual.identity,
      'a7c8cc47a59d5f3d859dfcba054254f51b7913a3315f6fa41b9b1fb28b7dc7d6',
    );
    expect(
      AnswerScopeSnapshot.fromPreferences(
        mode: 'workspace',
        selectedJson: '{',
      ).identity,
      manual.identity,
    );
    final automatic = await read(
      conversation: 'meeting:7',
      meeting: 7,
      automatic: true,
    );
    expect(automatic.mode, 'meeting');
    expect(automatic.ids, {
      'meeting-7',
      'meeting-summary-7',
      'meeting-actions-7',
      'meeting-enhanced_notes-7',
      'meeting-preparation-7',
    });
    expect(automatic.identity, isNot(manual.identity));
    expect(
      automatic.identity,
      'fd21b5239e56ed8195621dc47a3a4d33dcd4445aca254672709b36dd96a115d3',
    );
    expect(
      AnswerScopeSnapshot.fromPreferences(
        mode: 'meeting',
        selectedJson: '{',
        meeting: 7,
      ).identity,
      automatic.identity,
    );
    expect(() => automatic.ids!.add('foreign'), throwsUnsupportedError);
    writer.setPreference('answerScope.meeting:7', 'workspace');
    expect((await read(conversation: 'meeting:7', meeting: 7)).ids, isNull);
    // Automatic policy uses its own key, even for the same conversation.
    expect(
      (await read(conversation: 'meeting:7', meeting: 7, automatic: true)).mode,
      'meeting',
    );
  });

  test(
    'selected empty stays private and canonical identity ignores ID order',
    () async {
      writer.setPreference('answerScope.desktop', 'selected');
      final empty = await read();
      expect(empty.mode, 'selected');
      expect(empty.ids, isNotNull);
      expect(empty.ids, isEmpty);
      expect(
        empty.identity,
        '7749cc78b57fb4512f2c51feda072f0d231612be560deeb7d9ae14f08a6684da',
      );
      writer.setPreference('answerSources.desktop', '["z","a","z"]');
      final selected = await read();
      expect(selected.ids, {'a', 'z'});
      expect(
        selected.identity,
        'cce47178702737ea721f03cd2c945822e45b6aebc6ef792caab11220231c436b',
      );
      writer.setPreference('answerSources.desktop', '["a","z"]');
      final reordered = await read();
      expect(reordered.identity, selected.identity);
      expect(reordered.identity, isNot(empty.identity));
      expect(empty.ids, isEmpty);
      expect(() => selected.ids!.remove('a'), throwsUnsupportedError);
    },
  );

  test('scope DTO copies its ID set without widening empty or null', () {
    final ids = {'original'};
    final snapshot = AnswerScopeSnapshot(mode: 'selected', ids: ids);
    ids
      ..clear()
      ..add('later');
    expect(snapshot.ids, {'original'});
    expect(
      snapshot.identity,
      AnswerSourceScope('selected', {'original'}).identity,
    );
    expect(() => snapshot.ids!.clear(), throwsUnsupportedError);
  });

  test(
    'malformed selections fail without publishing a scope or widening it',
    () async {
      writer.setPreference('answerScope.desktop', 'selected');
      for (final value in [
        '[123]',
        '{}',
        '{',
        jsonEncode(List.generate(101, (index) => 'source-$index')),
      ]) {
        writer.setPreference('answerSources.desktop', value);
        expect(
          () => AnswerSourceScope.read(writer, 'desktop'),
          throwsA(anyOf(isA<StateError>(), isA<FormatException>())),
        );
        expect(
          () => AnswerScopeSnapshot.fromPreferences(
            mode: 'selected',
            selectedJson: value,
          ),
          value == '{' ? throwsFormatException : throwsStateError,
        );
        final result = await reader.read(
          StoreReadQueries.answerScope('desktop'),
        );
        expect(result.value, isNull);
        expect(result.error!.code, RpcErrorCode.internal);
      }
      for (final mode in ['invalid', 'meeting']) {
        writer.setPreference('answerScope.desktop', mode);
        expect(
          () => AnswerSourceScope.read(writer, 'desktop'),
          throwsStateError,
        );
        expect(
          () => AnswerScopeSnapshot.fromPreferences(mode: mode),
          throwsStateError,
        );
        final result = await reader.read(
          StoreReadQueries.answerScope('desktop'),
        );
        expect(result.value, isNull);
        expect(result.error!.code, RpcErrorCode.internal);
      }
      writer.setPreference('answerScope.desktop', 'workspace');
      expect((await read()).ids, isNull);
    },
  );

  test(
    'future schema retires the scope query before reading preferences',
    () async {
      writer.db.execute('BEGIN IMMEDIATE');
      writer.db.execute('ALTER TABLE preferences RENAME TO future_preferences');
      writer.db.execute('PRAGMA user_version=${Store.schemaVersion + 1}');
      writer.db.execute('COMMIT');
      final result = await reader.read(StoreReadQueries.answerScope('desktop'));
      expect(result.value, isNull);
      expect(result.error!.code, RpcErrorCode.unavailable);
      expect(
        result.error!.message,
        contains('Update Open Foresight and reconnect'),
      );
      expect(reader.failure!.code, RpcErrorCode.unavailable);
    },
  );

  test(
    'real worker prepares canonical scope before filtering saved history',
    () async {
      writer.setPreference('answerScope.desktop', 'selected');
      writer.setPreference('answerSources.desktop', '["alpha"]');
      final first = await read();
      writer.setPreference('answerSources.desktop', '["beta"]');
      final second = await read();
      for (final scope in [first, second]) {
        writer.answer(
          'Question',
          scope.ids!.single,
          'completed',
          [],
          'fixture',
        );
        writer.setPreference(
          'answerScope.v1.${writer.db.lastInsertRowId}',
          scope.identity,
        );
      }
      final prepared = await read();
      final history = await reader.read(
        StoreReadQueries.answers(
          null,
          scope: prepared.identity,
          privateScope: prepared.ids != null,
        ),
      );
      expect(history.error, isNull);
      expect(history.value!.map((answer) => answer.body), ['beta']);
      expect(first.ids, {'alpha'});
      writer.setPreference('answerSources.desktop', '[]');
      final empty = await read();
      final emptyHistory = await reader.read(
        StoreReadQueries.answers(
          null,
          scope: empty.identity,
          privateScope: empty.ids != null,
        ),
      );
      expect(emptyHistory.value, isEmpty);
      writer.setPreference('answerScope.desktop', 'workspace');
      final workspace = await read();
      final workspaceHistory = await reader.read(
        StoreReadQueries.answers(
          null,
          scope: workspace.identity,
          privateScope: workspace.ids != null,
        ),
      );
      expect(workspaceHistory.value!.map((answer) => answer.body), [
        'alpha',
        'beta',
      ]);
    },
  );

  test(
    'scope mode, IDs and epoch share one SQLite snapshot across a commit',
    () {
      writer.setPreference('answerScope.desktop', 'selected');
      writer.setPreference('answerSources.desktop', '["before"]');
      final expected = AnswerSourceScope.read(writer, 'desktop');
      final epoch = writer.workspaceEpoch;
      final store = InterleavedScopeStore(path, () {
        writer.db.execute('BEGIN IMMEDIATE');
        writer.setPreference('answerScope.desktop', 'workspace');
        writer.setPreference('answerSources.desktop', '["after"]');
        writer.renewWorkspaceEpoch();
        writer.db.execute('COMMIT');
      });
      addTearDown(store.close);
      final session = SqliteReadSession.borrow(store);
      addTearDown(session.close);
      final reply = session.query('answer_scope', {
        'conversation': 'desktop',
        'meeting': null,
        'automatic': false,
      });
      final scope = reply.value as AnswerScopeSnapshot;
      expect(reply.epoch, epoch);
      expect(scope.mode, 'selected');
      expect(scope.ids, {'before'});
      expect(scope.identity, expected.identity);
      expect(writer.workspaceEpoch, isNot(epoch));
      expect(AnswerSourceScope.read(writer, 'desktop').ids, isNull);
      expect(store.db.autocommit, isTrue);
    },
  );
}
