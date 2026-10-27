import 'dart:io';

import 'package:foresight_core/src/store.dart';
import 'package:foresight_core/src/persistence/application_queries.dart';
import 'package:foresight_core/src/persistence/conversation_queries.dart';
import 'package:foresight_core/src/persistence/preference_entities.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';

import 'preference_entities_test.dart' show historical, preference;
import 'sql_support_test_bootstrap.dart';

void main() {
  bootstrapSqlSupportFixture();
  late Directory directory;
  late String path;
  setUp(() {
    directory = createTestTempDirectorySync('entity-store-');
    path = '${directory.path}/application.db';
  });

  test(
    'Store migration and compatibility APIs retain scalar settings and ordered entities across reopen',
    () {
      final old = historical(path);
      preference(old, 'answerSources.meeting:7', '["b","a"]');
      preference(old, 'updateNoticeEnabled', 'false');
      old.execute('PRAGMA user_version=22');
      old.dispose();
      var store = Store(path);
      expect(
        store.migrationBackups.snapshots(supportedVersion: 23).single.schema,
        22,
      );
      expect(store.preference('answerSources.meeting:7'), '["b","a"]');
      expect(store.preference('updateNoticeEnabled'), 'false');
      store.setPreference('answerSources.meeting:7', '[]');
      store.setPreference('updateNoticeEnabled', 'true');
      expect(
        store.rows(
          "SELECT * FROM preferences WHERE key='answerSources.meeting:7'",
        ),
        isEmpty,
      );
      store.close();
      store = Store(path);
      try {
        expect(store.preference('answerSources.meeting:7'), '[]');
        expect(store.preference('updateNoticeEnabled'), 'true');
        expect(store.rows('PRAGMA foreign_key_check'), isEmpty);
      } finally {
        store.close();
      }
    },
  );

  test(
    'workspace clear erases malformed and orphan quarantine, typed entities and rollback snapshots',
    () async {
      final old = historical(path);
      preference(old, 'answerScope.v1.999', 'private orphan');
      preference(old, 'preparationSources.7', 'malformed private');
      preference(old, 'answerSources.meeting:7', '["a"]');
      preference(old, 'updateNoticeEnabled', 'false');
      old.execute('PRAGMA user_version=22');
      old.dispose();
      final store = Store(path);
      try {
        expect(
          store.migrationBackups.snapshots(supportedVersion: 23),
          hasLength(1),
        );
        expect(store.preference('answerScope.v1.999'), 'private orphan');
        WorkspacePersistence(store).clearLocalData(['a', 'b']);
        for (final table in [
          'answer_metadata',
          'conversation_scopes',
          'proactive_scopes',
          'source_selections',
          'source_selection_items',
          'legacy_preference_entities',
        ]) {
          expect(store.rows('SELECT * FROM $table'), isEmpty, reason: table);
        }
        expect(store.preference('updateNoticeEnabled'), 'false');
        final limit = DateTime.now().add(const Duration(seconds: 5));
        while (store.migrationBackups
                .snapshots(supportedVersion: 23)
                .isNotEmpty &&
            DateTime.now().isBefore(limit)) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        expect(store.migrationBackups.snapshots(supportedVersion: 23), isEmpty);
      } finally {
        store.close();
      }
    },
  );

  test(
    'answer saves and private web history/checkpoints read relational metadata',
    () {
      final store = Store(path);
      try {
        final queries = ConversationQueries(store);
        void save(String question, String scope) => queries.save(
          question,
          'response',
          'completed',
          [],
          'model',
          conversation: 'chat',
          scopeIdentity: scope,
          privateScope: true,
          memoryKey: 'chat',
        );
        save('first', 'private-a');
        final first = store.db.lastInsertRowId;
        store.setPreference('webAnswer.v1.$first', 'true');
        save('other scope', 'private-b');
        final other = store.db.lastInsertRowId;
        store.setPreference('webAnswer.v1.$other', 'true');
        save('last', 'private-a');
        final last = store.db.lastInsertRowId;
        store.setPreference('webAnswer.v1.$last', 'true');
        expect(
          queries.previousQuestion(
            'chat',
            privateScope: true,
            scopeIdentity: 'private-a',
          ),
          'last',
        );
        expect(
          queries
              .history(
                'chat',
                web: true,
                through: 0,
                privateScope: true,
                scopeIdentity: 'private-a',
              )
              .map((a) => a.question),
          ['first', 'last'],
        );
        expect(
          queries
              .history(
                'chat',
                web: false,
                through: 0,
                privateScope: true,
                scopeIdentity: 'private-b',
              )
              .map((a) => a.question),
          ['other scope'],
        );
        store.db.execute(
          "INSERT INTO conversation_memory(conversation,through_answer_id,messages,token_counts) VALUES('memory',?,'[]','[]')",
          [last],
        );
        expect(
          queries.checkpoint('memory', 'chat').single.throughAnswerId,
          last,
        );
        store.db.execute('DELETE FROM answers WHERE id=?', [last]);
        expect(queries.checkpoint('memory', 'chat'), isEmpty);
        expect(
          PreferenceEntities(store.db).read('answerScope.v1.$last'),
          isNull,
        );
        expect(
          store.rows(
            "SELECT * FROM preferences WHERE key GLOB 'answerScope.v1.*' OR key GLOB 'webAnswer.v1.*'",
          ),
          isEmpty,
        );
      } finally {
        store.close();
      }
    },
  );

  test(
    'migration snapshot restoration reaches the current schema through Store without losing invalid legacy evidence',
    () {
      final old = historical(path);
      preference(old, 'preparationSources.7', 'invalid-private');
      old.execute('PRAGMA user_version=22');
      old.dispose();
      final upgraded = Store(path);
      final snapshot = upgraded.migrationBackups
          .snapshots(supportedVersion: 23)
          .single;
      final restored = upgraded.migrationBackups.restoreCopy(
        snapshot.name,
        supportedVersion: 23,
        confirmDataLoss: true,
      );
      upgraded.close();
      final restoredStore = Store(restored);
      try {
        expect(
          restoredStore.rows('PRAGMA user_version').single.values.single,
          Store.schemaVersion,
        );
        expect(
          restoredStore.preference('preparationSources.7'),
          'invalid-private',
        );
        restoredStore.db.execute('DELETE FROM meetings WHERE id=7');
        expect(
          restoredStore.preference('preparationSources.7', 'missing'),
          'missing',
        );
      } finally {
        restoredStore.close();
      }
    },
  );
  test(
    'Store startup expiry physically removes quarantine and erases rollback copies',
    () async {
      var store = Store(path);
      store.db.execute(
        "INSERT INTO legacy_preference_entities(key,value,reason,created) VALUES('answerScope.v1.999','expired-private','orphan_answer',0)",
      );
      store.migrationBackups.create(store.db, Store.schemaVersion);
      expect(
        store.migrationBackups.snapshots(supportedVersion: Store.schemaVersion),
        hasLength(1),
      );
      store.close();
      store = Store(path);
      try {
        expect(store.rows('SELECT * FROM legacy_preference_entities'), isEmpty);
        expect(store.preference('answerScope.v1.999', 'missing'), 'missing');
        final limit = DateTime.now().add(const Duration(seconds: 5));
        while (store.migrationBackups
                .snapshots(supportedVersion: Store.schemaVersion)
                .isNotEmpty &&
            DateTime.now().isBefore(limit)) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        expect(
          store.migrationBackups.snapshots(
            supportedVersion: Store.schemaVersion,
          ),
          isEmpty,
        );
      } finally {
        store.close();
      }
    },
  );
}
