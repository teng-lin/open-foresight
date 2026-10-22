import 'package:foresight_test_support/test_paths.dart';
import 'package:foresight_core/src/application.dart';
import 'dart:convert';
import 'package:test/test.dart';
import 'package:foresight_core/src/store.dart';
import 'package:foresight_core/src/domain.dart';
import 'package:foresight_core/src/helper.dart';

void main() {
  test(
    'revisions, tombstones, answer provenance and user edits survive restart',
    () async {
      final tmp = createTestTempDirectorySync('foresight-store-');
      addTearDown(() => tmp.deleteSync(recursive: true));
      var store = Store('${tmp.path}/application.db');
      addTearDown(() => store.close());
      final helper = Helper('${tmp.path}/helper.sock', '${tmp.path}/helper');
      addTearDown(helper.close);
      var domain = Domain(store, helper);
      final id = store.importText(
        'Apollo',
        'Apollo launches in May.',
        'text/plain',
        'fixture',
      );
      store.state(id, 'indexed');
      final citation = {
        'document_id': id,
        'revision': 1,
        'citation': 'S1',
        'excerpt': 'Apollo launches in May.',
      };
      expect(domain.citationCurrent(citation), true);
      store.answer('When?', 'May [S1]', 'completed', [
        citation,
      ], 'fixture-digest');
      store.importText(
        'Apollo',
        'Apollo launches in June.',
        'text/plain',
        'fixture',
        id: id,
      );
      expect(domain.citationCurrent(citation), false);
      store.saveNote(null, 'Plan', 'My edits');
      final note = store.db.lastInsertRowId;
      store.saveNote(note, 'Plan', 'My revised edits');
      final meeting = store.meeting('Planning');
      store.transcript(meeting, 'Meet Friday', true, 0, 3000, 'microphone');
      store.artifact(meeting, 'summary', 'Generated summary', 'model');
      final artifact = store.db.lastInsertRowId;
      store.editArtifact(artifact, 'User summary');
      store.artifact(meeting, 'summary', 'Regenerated summary', 'model');
      store.close();
      store = Store('${tmp.path}/application.db');
      domain = Domain(store, helper);
      final app = Application(domain);
      addTearDown(app.close);
      expect(store.sources.single['revision'], 2);
      expect(
        store.rows('SELECT * FROM notes').single['body'],
        'My revised edits',
      );
      expect(
        store.rows('SELECT * FROM artifacts WHERE id=?', [
          artifact,
        ]).single['edited'],
        'User summary',
      );
      final saved =
          jsonDecode(
                store.rows('SELECT citations FROM answers').single['citations']
                    as String,
              )
              as List;
      expect(saved.single['revision'], 1);
      expect(saved.single['excerpt'], 'Apollo launches in May.');
      store.tombstone(id);
      expect(store.sources, isEmpty);
      expect(domain.citationCurrent({'document_id': id, 'revision': 2}), false);
    },
  );
  test(
    'insufficient-context response persists without helper or generator',
    () async {
      final tmp = createTestTempDirectorySync('foresight-domain-');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final store = Store('${tmp.path}/app.db');
      addTearDown(store.close);
      final helper = Helper('${tmp.path}/socket', '${tmp.path}/helper');
      addTearDown(helper.close);
      final app = Application(Domain(store, helper));
      addTearDown(app.close);
      final output = await app.ask('What happened?').toList();
      expect(output.single, contains('Insufficient context'));
      expect(
        store.rows('SELECT status FROM answers').single['status'],
        'insufficient_context',
      );
    },
  );
}
