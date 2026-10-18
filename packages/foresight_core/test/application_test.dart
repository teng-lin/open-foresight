import 'dart:async';
import 'dart:io';
import 'package:test/test.dart';
import 'package:foresight_core/foresight_core.dart';
import 'package:foresight_core/src/application.dart';

class TestDomain extends Domain {
  final indexed = <String>[];
  TestDomain(super.store, super.helper);
  @override
  Future<void> index(String id) async {
    indexed.add(id);
  }
}

class DelayedGenerator extends NativeRuntime {
  @override
  bool get loaded => true;
  final entered = Completer<void>(), release = Completer<void>();
  final String output;
  DelayedGenerator({this.output = '- Grounded enhancement'})
    : super(Platform.isMacOS ? '/usr/lib/libSystem.B.dylib' : 'libc.so.6');
  @override
  Stream<Map<String, dynamic>> generateConversation(
    String id,
    String prompt, {
    Duration timeout = const Duration(minutes: 5),
    int? maxOutputTokens = 1024,
    int? maxInputTokens,
    List<List<int>> stopTokenIds = const [],
  }) async* {
    entered.complete();
    await release.future;
    yield {'type': 'delta', 'text': output};
    yield {'type': 'done', 'status': 'completed'};
  }
}

class BrowserAuth extends GoogleAuth {
  final done = Completer<void>();
  int cancelled = 0;
  BrowserAuth(super.directory);
  @override
  Future<void> signIn(Future<void> Function(Uri) openBrowser) async {
    await openBrowser(Uri.parse('https://example.invalid/authorize'));
    await done.future;
  }

  @override
  void cancelSignIn() {
    if (!done.isCompleted) {
      cancelled++;
      done.completeError(StateError('Cancelled'));
    }
  }
}

void main() {
  late Directory directory;
  late TestDomain domain;
  setUp(() {
    directory = Directory.systemTemp.createTempSync('foresight-core-');
    domain = TestDomain(
      Store('${directory.path}/app.db'),
      Helper('${directory.path}/helper.sock', '${directory.path}/helper'),
    );
    domain.store.setPreference('liveEnhance', 'false');
  });
  tearDown(() async {
    await domain.application.close();
    domain.close();
    domain.generator?.close();
    await domain.helper.close();
    domain.store.close();
    directory.deleteSync(recursive: true);
  });
  test(
    'OAuth cancellation before the callback listener binds does not escape its request',
    () async {
      final auth = GoogleAuth(Directory('${directory.path}/early-cancel'));
      auth.client = GoogleClient(
        'fixture.apps.googleusercontent.com',
        'fixture',
      );
      final task = auth.signIn((_) async {});
      auth.cancelSignIn();
      await expectLater(task, throwsStateError);
      await auth.close();
    },
  );
  test(
    'OAuth browser invitation is streamed to its client and cancellation belongs to its owner',
    () async {
      final auth = BrowserAuth(Directory('${directory.path}/browser-auth'));
      final app = Application(domain, auth: auth);
      final invitation = StreamIterator(app.signIn('desktop-request'));
      expect(await invitation.moveNext(), true);
      expect(
        (invitation.current as Map)['authorization_url'],
        'https://example.invalid/authorize',
      );
      app.cancelSignIn('another-request');
      expect(auth.cancelled, 0);
      app.cancelSignIn('desktop-request');
      await expectLater(invitation.moveNext(), throwsStateError);
      expect(auth.cancelled, 1);
      await invitation.cancel();
      await app.close();
    },
  );
  test(
    'source updates preserve IDs and increment revisions; notes return their own IDs',
    () async {
      final first =
          await domain.command('sources.import', {
                'title': 'A',
                'text': 'first',
                'index': false,
              })
              as Map;
      final id = first['id'] as String;
      await domain.command('sources.import', {
        'id': id,
        'title': 'A',
        'text': 'second',
        'index': false,
      });
      final source = await domain.command('sources.get', {'id': id}) as Map;
      expect(source['content'], 'second');
      expect(source['trust'], 'untrusted');
      expect(source['content_policy'], contains('never instructions'));
      expect(source['revision'], 2);
      final a =
          await domain.command('notes.save', {'title': 'a', 'body': 'original'})
              as Map;
      final b =
          await domain.command('notes.save', {'title': 'b', 'body': 'other'})
              as Map;
      await domain.command('notes.save', {
        'id': a['id'],
        'title': 'a',
        'body': 'edited',
      });
      expect(a['id'], isNot(b['id']));
      expect(
        domain.store.rows('SELECT body FROM notes WHERE id=?', [
          a['id'],
        ]).single['body'],
        'edited',
      );
      final readOnly = Store.readOnly(domain.store.path);
      expect(() => readOnly.saveNote(null, 'forbidden', ''), throwsA(anything));
      readOnly.close();
    },
  );
  test(
    'transcript imports retain raw evidence and use the shared meeting indexing workflow',
    () async {
      final created =
          await domain.command('meetings.create', {'title': 'Planning'}) as Map;
      final id = created['id'] as int;
      await domain.command('meetings.transcript', {
        'id': id,
        'text': 'Mira sends draft Tuesday.',
        'source': 'imported',
        'start': 10,
        'end': 20,
      });
      final meeting = await domain.command('meetings.get', {'id': id}) as Map;
      expect(
        (meeting['transcript'] as List).single['text'],
        'Mira sends draft Tuesday.',
      );
      expect(domain.indexed, ['meeting-$id']);
      expect(
        domain.store.sources.single['content'],
        contains('Mira sends draft Tuesday.'),
      );
      expect((meeting['meeting'] as Map)['revision'], 1);
    },
  );
  test(
    'enhancement completion preserves newer raw edits and accepts its output',
    () async {
      final id = domain.store.meeting('Planning');
      domain.store.transcript(
        id,
        'Mira sends draft Tuesday.',
        true,
        0,
        20,
        'imported',
      );
      domain.store.saveMeetingNotes(id, 'Mira draft');
      final generator = DelayedGenerator();
      domain.generator = generator;
      final work = domain.application.enhanceNotes(id);
      await generator.entered.future;
      domain.store.saveMeetingNotes(id, 'Mira revised draft');
      generator.release.complete();
      await work;
      expect(
        domain.store
            .rows('SELECT generated FROM artifacts')
            .single['generated'],
        '- Grounded enhancement',
      );
      expect(domain.store.meetingEnhancedNotes(id), '- Grounded enhancement');
      expect(
        domain.store.rows('SELECT body FROM meeting_notes').single['body'],
        'Mira revised draft',
      );
    },
  );
  test(
    'accepted enhancement removes original line markers before persistence',
    () async {
      final id = domain.store.meeting('Planning');
      domain.store.transcript(
        id,
        'Mira sends draft Tuesday.',
        true,
        0,
        20,
        'imported',
      );
      domain.store.saveMeetingNotes(id, 'Mira draft');
      final generator = DelayedGenerator(
        output:
            '- <LINE id="2"><L:2>Mira sends the draft Tuesday.</L:2></LINE>\n',
      );
      domain.generator = generator;
      final work = domain.application.enhanceNotes(id);
      await generator.entered.future;
      generator.release.complete();
      await work;
      expect(
        domain.store
            .rows('SELECT generated FROM artifacts')
            .single['generated'],
        '- Mira sends the draft Tuesday.',
      );
      expect(
        domain.store
            .rows('SELECT body,last_enhanced FROM meeting_notes')
            .single,
        containsPair('body', 'Mira draft'),
      );
      expect(
        domain.store
            .rows('SELECT last_enhanced FROM meeting_notes')
            .single['last_enhanced'],
        isNotNull,
      );
    },
  );
  test(
    'clearing workspace includes dependent notes and answer links atomically',
    () async {
      final id = domain.store.meeting('Planning');
      domain.store.saveMeetingNotes(id, 'original');
      domain.store.answer('question', 'answer', 'completed', [], 'fixture');
      await domain.command('meetings.link_answer', {
        'id': id,
        'answer': domain.store.db.lastInsertRowId,
      });
      await domain.command('workspace.clear');
      expect(domain.store.rows('PRAGMA foreign_key_check'), isEmpty);
      expect(domain.store.rows('SELECT * FROM meetings'), isEmpty);
      expect(domain.store.rows('SELECT * FROM meeting_notes'), isEmpty);
      expect(domain.store.rows('SELECT * FROM meeting_answers'), isEmpty);
    },
  );
}
