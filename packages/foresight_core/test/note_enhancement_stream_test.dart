import 'dart:async';
import 'dart:io';
import 'package:foresight_core/foresight_core.dart';
import 'package:test/test.dart';

class ControlledNoteGenerator extends NativeRuntime {
  ControlledNoteGenerator()
    : super(Platform.isMacOS ? '/usr/lib/libSystem.B.dylib' : 'libc.so.6');
  final entered = Completer<void>();
  final events = StreamController<Map<String, dynamic>>();
  var cancelled = false;
  @override
  Stream<Map<String, dynamic>> generate(
    String id,
    String prompt, {
    String systemPrompt = '',
    Map<String, dynamic>? responseSchema,
    Duration timeout = const Duration(minutes: 5),
    int maxOutputTokens = 256,
  }) async* {
    entered.complete();
    try {
      await for (final event in events.stream) {
        yield event;
        if (event['type'] == 'done') break;
      }
    } finally {
      cancelled = true;
    }
  }
}

void main() {
  late Directory directory;
  late Domain domain;
  late ControlledNoteGenerator generator;
  late int id;
  setUp(() {
    directory = Directory.systemTemp.createTempSync('note-stream-');
    domain = Domain(
      Store('${directory.path}/app.db'),
      Helper('${directory.path}/sock', '${directory.path}/helper'),
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
    generator.events.add({'type': 'delta', 'text': text});
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }

  test(
    'initial raw copy is visible and saved before the first stream event',
    () async {
      final work = domain.application.enhanceNotes(id);
      await generator.entered.future;
      expect(progress()['body'], 'Raw notes');
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      expect(domain.store.meetingEnhancedNotes(id), 'Raw notes');
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
      await Future<void>.delayed(const Duration(milliseconds: 1100));
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
      expect(progress()['body'], 'Raw notes');
      await emit('<L:1>- First</L:1>');
      expect(progress()['body'], '- First');
      expect(domain.store.meetingEnhancedNotes(id), contains('- Prior'));
      await Future<void>.delayed(const Duration(milliseconds: 1100));
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
      await Future<void>.delayed(const Duration(milliseconds: 1100));
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
      await Future<void>.delayed(const Duration(milliseconds: 1100));
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
      await Future<void>.delayed(const Duration(milliseconds: 1100));
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
      await emit(' ignored after close');
      await work;
      await Future<void>.delayed(const Duration(milliseconds: 1100));
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
