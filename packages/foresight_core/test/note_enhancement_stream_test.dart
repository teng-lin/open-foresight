import 'package:foresight_core/src/application.dart';
import 'dart:async';
import 'dart:io';
import 'package:fake_async/fake_async.dart';
import 'package:foresight_core/foresight_core.dart';
import 'package:test/test.dart';

class ControlledNoteGenerator extends NativeRuntime {
  @override
  bool get loaded => true;
  ControlledNoteGenerator()
    : super(Platform.isMacOS ? '/usr/lib/libSystem.B.dylib' : 'libc.so.6');
  final entered = Completer<void>();
  final events = StreamController<Map<String, dynamic>>();
  final prompts = <String>[];
  final inputLimits = <int?>[];
  final outputLimits = <int?>[];
  var cancelled = false;
  @override
  Stream<Map<String, dynamic>> generateConversation(
    String id,
    String prompt, {
    int? maxOutputTokens = 1024,
    int? maxInputTokens,
    List<List<int>> stopTokenIds = const [],
    Duration timeout = const Duration(minutes: 5),
  }) async* {
    prompts.add(prompt);
    inputLimits.add(maxInputTokens);
    outputLimits.add(maxOutputTokens);
    entered.complete();
    final response = StringBuffer();
    try {
      await for (final event in events.stream) {
        if (event['type'] == 'delta') {
          response.write(event['text'] as String);
          yield {'type': 'preview', 'text': response.toString()};
        } else if (event['type'] == 'done') {
          // Native plain conversations report cumulative previews and then
          // repeat the authoritative complete response in the final delta.
          yield {'type': 'delta', 'text': response.toString()};
          yield event;
          break;
        } else {
          yield event;
        }
      }
    } finally {
      cancelled = true;
    }
  }
}

class BatchedNoteGenerator extends ControlledNoteGenerator {
  BatchedNoteGenerator() {
    events.stream.listen((_) {});
  }
  final responses = [
    '- Enhanced one\n- Enhanced two\n- Enhanced three\n- Enhanced four',
    '- Enhanced five\n- Enhanced six',
  ];

  @override
  Stream<Map<String, dynamic>> generateConversation(
    String id,
    String prompt, {
    int? maxOutputTokens = 1024,
    int? maxInputTokens,
    List<List<int>> stopTokenIds = const [],
    Duration timeout = const Duration(minutes: 5),
  }) async* {
    final response = responses[prompts.length];
    prompts.add(prompt);
    inputLimits.add(maxInputTokens);
    outputLimits.add(maxOutputTokens);
    yield {'type': 'preview', 'text': response.split('\n').first};
    yield {'type': 'preview', 'text': response};
    yield {'type': 'delta', 'text': response};
    yield {'type': 'done', 'status': 'completed'};
  }
}

class QueuedNoteGenerator extends ControlledNoteGenerator {
  QueuedNoteGenerator() {
    events.stream.listen((_) {});
  }
  final releaseFirst = Completer<void>();
  final secondDone = Completer<void>();

  @override
  Stream<Map<String, dynamic>> generateConversation(
    String id,
    String prompt, {
    int? maxOutputTokens = 1024,
    int? maxInputTokens,
    List<List<int>> stopTokenIds = const [],
    Duration timeout = const Duration(minutes: 5),
  }) async* {
    prompts.add(prompt);
    if (prompts.length == 1) {
      entered.complete();
      await releaseFirst.future;
      yield {'type': 'delta', 'text': '- First accepted'};
    } else {
      yield {'type': 'delta', 'text': '- Third updated'};
    }
    yield {'type': 'done', 'status': 'completed'};
    if (prompts.length == 2) secondDone.complete();
  }
}

void main() {
  late Directory directory;
  late Domain domain;
  late FakeAsync time;
  late ControlledNoteGenerator generator;
  late int id;
  setUp(() {
    time = FakeAsync();
    directory = Directory.systemTemp.createTempSync('note-stream-');
    domain = Domain(
      Store('${directory.path}/app.db'),
      Helper('${directory.path}/sock', '${directory.path}/helper'),
      clock: time.getClock(DateTime.utc(2026)),
      createTimer: (duration, callback) =>
          time.run((_) => Timer(duration, callback)),
    );
    domain.store.setPreference('liveEnhance', 'false');
    id = domain.store.meeting('Meeting');
    domain.store.saveMeetingNotes(id, 'Raw notes', lastManualEdit: 200);
    domain.store.transcript(id, 'Transcript evidence', true, 0, 20, 'imported');
    domain.store.artifact(
      id,
      'enhanced_notes',
      '# Heading\n- Prior\n\nPlain prose\n💡 Retained\n# Potential Important Topics Not In Notes\n- Excluded',
      'fixture',
    );
    domain.store.db.execute(
      'UPDATE meeting_notes SET last_enhanced=100,timestamp=50',
    );
    generator = ControlledNoteGenerator();
    domain.generator = generator;
  });
  tearDown(() async {
    await domain.application.close();
    domain.close();
    generator.close();
    await generator.events.close();
    await domain.helper.close();
    domain.store.close();
    directory.deleteSync(recursive: true);
  });
  Map progress() =>
      (domain.application.captureState['note_enhancements'] as Map)['$id']
          as Map;
  Future<void> emit(String text) async {
    final changed = domain.application.changes.stream.first;
    generator.events.add({'type': 'delta', 'text': text});
    await changed;
  }

  test(
    'shorthand reordering immediately reorders the draft and debounces persistence',
    () async {
      generator.events.stream.listen((_) {});
      domain.store.saveMeetingNotes(id, 'First raw\nSecond raw');
      domain.store.artifact(
        id,
        'enhanced_notes',
        '- First enhanced\n\n- Second enhanced',
        'fixture',
      );
      await domain.command('meetings.notes', {
        'id': id,
        'body': 'Second raw\nFirst raw',
        'last_manual_edit': 333,
      });
      expect(progress()['body'], '- Second enhanced\n\n- First enhanced');
      expect(
        domain.store.meetingEnhancedNotes(id),
        '- First enhanced\n\n- Second enhanced',
      );
      time.elapse(const Duration(seconds: 1));
      expect(
        domain.store.meetingEnhancedNotes(id),
        '- Second enhanced\n\n- First enhanced',
      );
      expect(
        domain.store
            .rows('SELECT last_manual_edit FROM meeting_notes')
            .single['last_manual_edit'],
        333,
      );
    },
  );

  test(
    'editing the current enhancement invalidates the prior used by generation',
    () async {
      final artifact = domain.store
          .rows('SELECT id FROM artifacts ORDER BY id DESC')
          .first['id'];
      await domain.command('artifacts.edit', {
        'id': artifact,
        'text': '- Manually changed',
      });
      final work = domain.application.enhanceNotes(id);
      await generator.entered.future;
      expect(
        generator.prompts.single,
        isNot(contains('<previous_enhanced_notes>')),
      );
      await domain.command('meetings.cancel_enhance', {
        'id': id,
        'request_id': progress()['request_id'],
      });
      await emit('cancel observation');
      await work;
      expect(progress()['body'], '- Manually changed');
    },
  );

  test(
    'cancellation rebuilds associations from raw edits made during generation',
    () async {
      domain.store.saveMeetingNotes(id, 'First raw\nSecond raw');
      domain.store.artifact(
        id,
        'enhanced_notes',
        '- First enhanced\n\n- Second enhanced',
        'fixture',
      );
      final work = domain.application.enhanceNotes(id);
      await generator.entered.future;
      await domain.command('meetings.notes', {
        'id': id,
        'body': 'Updated first\nUpdated second',
      });
      await domain.command('meetings.cancel_enhance', {
        'id': id,
        'request_id': progress()['request_id'],
      });
      await emit('cancel observation');
      await work;
      await domain.command('meetings.notes', {
        'id': id,
        'body': 'Updated second\nUpdated first',
      });
      expect(progress()['body'], '- Second enhanced\n\n- First enhanced');
    },
  );

  test(
    'targeted requests during generation replace the pending target set',
    () async {
      final unused = generator.events.stream.listen((_) {});
      await generator.events.close();
      await unused.cancel();
      generator.close();
      final queued = QueuedNoteGenerator();
      generator = queued;
      domain.generator = queued;
      domain.store.setPreference('liveEnhance', 'true');
      domain.store.saveMeetingNotes(id, 'First raw');
      domain.store.saveMeetingEnhancedDraft(id, '');
      final first = domain.application.enhanceNotes(id, isLive: true);
      await queued.entered.future;
      domain.store.saveMeetingNotes(id, 'First raw\nSecond raw\nThird raw');
      await domain.application.enhanceNotes(
        id,
        isLive: true,
        deferWhenBusy: true,
        targetBulletIndices: {1},
      );
      await domain.application.enhanceNotes(
        id,
        isLive: true,
        deferWhenBusy: true,
        targetBulletIndices: {2},
      );
      queued.releaseFirst.complete();
      await first;
      await queued.secondDone.future;
      if ((domain.application.captureState['note_enhancements'] as Map)
          .isNotEmpty) {
        await domain.application.changes.stream
            .firstWhere(
              (_) =>
                  (domain.application.captureState['note_enhancements'] as Map)
                      .isEmpty,
            )
            .timeout(const Duration(seconds: 5));
      }
      expect(queued.prompts, hasLength(2));
      expect(queued.prompts.last, contains('Third raw'));
      expect(queued.prompts.last, isNot(contains('First raw')));
      expect(
        domain.store.meetingEnhancedNotes(id),
        '- First accepted\n\nSecond raw\n\n- Third updated',
      );
    },
  );

  test(
    'manual enhancement can update notes already written in enhanced form',
    () async {
      domain.store.saveMeetingNotes(id, '- **Owner:** Mira');
      final work = domain.application.enhanceNotes(id);
      await generator.entered.future;
      expect(generator.prompts.single, contains('- **Owner:** Mira'));
      await emit('- **Owner:** Mira sends the draft.');
      generator.events.add({'type': 'done', 'status': 'completed'});
      await work;
      expect(
        domain.store.meetingEnhancedNotes(id),
        '- **Owner:** Mira sends the draft.',
      );
    },
  );

  test(
    'six notes use two grounded conversations and persist one ordered enhancement',
    () async {
      final unusedEvents = generator.events.stream.listen((_) {});
      await generator.events.close();
      await unusedEvents.cancel();
      generator.close();
      final batched = BatchedNoteGenerator();
      generator = batched;
      domain.generator = generator;
      final raw = [
        'one',
        'two',
        'three',
        'four',
        'five',
        'six',
      ].map((word) => 'Raw $word').join('\n');
      domain.store.saveMeetingNotes(id, raw, lastManualEdit: 300);

      await domain.application.enhanceNotes(id);

      expect(batched.prompts, hasLength(2));
      expect(batched.prompts.first, contains('Raw one'));
      expect(batched.prompts.first, contains('Raw four'));
      expect(batched.prompts.first, isNot(contains('Raw five')));
      expect(batched.prompts.last, contains('Raw five'));
      expect(batched.prompts.last, contains('Raw six'));
      expect(batched.prompts.last, isNot(contains('Raw one')));
      for (final prompt in batched.prompts) {
        expect(prompt, contains('<relevant_excerpts>'));
        expect(prompt, contains('Transcript evidence'));
        expect(prompt, contains('<shorthand_notes>'));
      }
      expect(batched.inputLimits, [2048, 2048]);
      expect(batched.outputLimits, [null, null]);
      final body = domain.store.meetingEnhancedNotes(id);
      expect(body.split('\n').where((line) => line.isNotEmpty).toList(), [
        '- Enhanced one',
        '- Enhanced two',
        '- Enhanced three',
        '- Enhanced four',
        '- Enhanced five',
        '- Enhanced six',
      ]);
      final artifacts = domain.store.rows(
        'SELECT generated FROM artifacts ORDER BY id',
      );
      expect(artifacts, hasLength(2));
      expect(artifacts.last['generated'], body);
      final stored = domain.store.rows('SELECT * FROM meeting_notes').single;
      expect(stored['body'], raw);
      expect(stored['last_manual_edit'], 300);
      expect(stored['last_enhanced'], greaterThan(100));
      expect(domain.application.captureState['note_enhancements'], isEmpty);
    },
  );

  test(
    'initial raw copy precedes the producer prior-map preview and draft save',
    () async {
      final work = domain.application.enhanceNotes(id);
      expect(progress()['body'], 'Raw notes');
      await generator.entered.future;
      expect(progress()['body'], '- Prior');
      time.elapse(const Duration(seconds: 1));
      expect(domain.store.meetingEnhancedNotes(id), '- Prior');
      expect(
        domain.store
            .rows('SELECT last_enhanced,last_manual_edit FROM meeting_notes')
            .single,
        {'last_enhanced': 100, 'last_manual_edit': 200},
      );
      await domain.command('meetings.cancel_enhance', {
        'id': id,
        'request_id': progress()['request_id'],
      });
      await emit('unread event');
      await work;
      expect(progress()['body'], '- Prior\n\n💡 Retained');
    },
  );

  test(
    'immediate restart keeps pending cancellation restoration as the baseline',
    () async {
      final first = domain.application.enhanceNotes(id);
      await generator.entered.future;
      await emit('- Persisted partial');
      time.elapse(const Duration(seconds: 1));
      final firstRequest = progress()['request_id'];
      await domain.command('meetings.cancel_enhance', {
        'id': id,
        'request_id': firstRequest,
      });
      await emit('unread');
      await first;
      await generator.events.close();
      generator.close();
      generator = ControlledNoteGenerator();
      domain.generator = generator;
      final second = domain.application.enhanceNotes(id);
      await generator.entered.future;
      expect(
        await domain.command('meetings.cancel_enhance', {
          'id': id,
          'request_id': firstRequest,
        }),
        isFalse,
      );
      await domain.command('meetings.cancel_enhance', {
        'id': id,
        'request_id': progress()['request_id'],
      });
      await emit('unread');
      await second;
      expect(progress()['body'], '- Prior\n\n💡 Retained');
    },
  );

  test(
    'partial output debounces into current notes without per-token artifacts',
    () async {
      final work = domain.application.enhanceNotes(id);
      await generator.entered.future;
      expect(progress()['body'], '- Prior');
      await emit('- First');
      expect(generator.prompts.single, contains('<relevant_excerpts>'));
      expect(generator.prompts.single, contains('Transcript evidence'));
      expect(generator.prompts.single, contains('<shorthand_notes>'));
      expect(generator.prompts.single, contains('Raw notes'));
      expect(generator.prompts.single, contains('<previous_enhanced>'));
      expect(generator.inputLimits, [2048]);
      expect(generator.outputLimits, [null]);
      expect(progress()['body'], '- First');
      expect(domain.store.meetingEnhancedNotes(id), contains('- Prior'));
      time.elapse(const Duration(seconds: 1));
      expect(domain.store.meetingEnhancedNotes(id), '- First');
      expect(
        domain.store
            .rows('SELECT last_enhanced,last_manual_edit FROM meeting_notes')
            .single,
        {'last_enhanced': 100, 'last_manual_edit': 200},
      );
      expect(domain.store.rows('SELECT * FROM artifacts'), hasLength(1));
      await emit(' continued');
      generator.events.add({'type': 'done', 'status': 'completed'});
      await work;
      expect(domain.store.meetingEnhancedNotes(id), '- First continued');
      expect(domain.store.rows('SELECT * FROM artifacts'), hasLength(2));
      expect(
        domain.store
            .rows('SELECT body,revision,last_manual_edit FROM meeting_notes')
            .single,
        {'body': 'Raw notes', 'revision': 1, 'last_manual_edit': 200},
      );
      expect(
        domain.store
            .rows('SELECT last_enhanced FROM meeting_notes')
            .single['last_enhanced'],
        greaterThan(100),
      );
      expect(domain.application.captureState['note_enhancements'], isEmpty);
    },
  );

  test(
    'current manual edits cancel stale draft saves while historical edits leave progress alone',
    () async {
      final historical = domain.store
          .rows('SELECT id FROM artifacts')
          .single['id'];
      domain.store.artifact(
        id,
        'enhanced_notes',
        '- Current baseline',
        'fixture',
      );
      final current = domain.store.db.lastInsertRowId;
      final work = domain.application.enhanceNotes(id);
      await generator.entered.future;
      await emit('- Partial');
      await domain.command('artifacts.edit', {
        'id': historical,
        'text': 'Historical edit',
        'last_manual_edit': 666,
      });
      expect(progress()['body'], '- Partial');
      await domain.command('artifacts.edit', {
        'id': current,
        'text': '- Manual',
        'last_manual_edit': 777,
      });
      expect(progress()['body'], '- Manual');
      time.elapse(const Duration(seconds: 1));
      expect(domain.store.meetingEnhancedNotes(id), '- Manual');
      expect(
        domain.store
            .rows('SELECT last_manual_edit FROM meeting_notes')
            .single['last_manual_edit'],
        777,
      );
      await emit(' next');
      generator.events.add({'type': 'done', 'status': 'completed'});
      await work;
      expect(domain.store.meetingEnhancedNotes(id), '- Partial next');
      expect(
        domain.store
            .rows('SELECT last_manual_edit FROM meeting_notes')
            .single['last_manual_edit'],
        777,
      );
    },
  );

  test(
    'owned cancel restores extracted formatted prior notes on next event and saves after one second',
    () async {
      final work = domain.application.enhanceNotes(id);
      await generator.entered.future;
      await emit('- Partial');
      time.elapse(const Duration(seconds: 1));
      final request = progress()['request_id'];
      expect(
        await domain.command('meetings.cancel_enhance', {
          'id': id,
          'request_id': 'stale',
        }),
        isFalse,
      );
      expect(progress()['cancel_requested'], isFalse);
      expect(
        await domain.command('meetings.cancel_enhance', {
          'id': id,
          'request_id': request,
        }),
        isTrue,
      );
      expect(progress()['active'], isTrue);
      await emit(' ignored after cancellation');
      await work;
      expect(generator.cancelled, isTrue);
      expect(progress()['active'], isFalse);
      expect(progress()['body'], '- Prior\n\n💡 Retained');
      expect(domain.store.meetingEnhancedNotes(id), '- Partial');
      time.elapse(const Duration(seconds: 1));
      expect(domain.store.meetingEnhancedNotes(id), '- Prior\n\n💡 Retained');
      expect(
        domain.store
            .rows('SELECT last_enhanced,last_manual_edit FROM meeting_notes')
            .single,
        {'last_enhanced': 100, 'last_manual_edit': 200},
      );
      expect(domain.store.rows('SELECT * FROM artifacts'), hasLength(1));
      expect(domain.application.captureState['note_enhancements'], isEmpty);
    },
  );

  test(
    'close cancels pending programmatic saves without a final autosave',
    () async {
      final work = domain.application.enhanceNotes(id);
      await generator.entered.future;
      await emit('- Unsaved partial');
      await domain.application.close();
      generator.events.add({'type': 'delta', 'text': ' ignored after close'});
      await work;
      time.elapse(const Duration(seconds: 1));
      expect(domain.store.meetingEnhancedNotes(id), contains('- Prior'));
      expect(
        domain.store
            .rows('SELECT timestamp FROM meeting_notes')
            .single['timestamp'],
        50,
      );
      expect(domain.store.rows('SELECT * FROM artifacts'), hasLength(1));
    },
  );
}
