import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:foresight_core/foresight_core.dart';
import 'package:foresight_core/src/application.dart';
import 'package:foresight_core/src/reference_note_enhancement_chunking.dart';
import 'package:foresight_test_support/google_connections.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';

class StalledNotesRuntime extends NativeRuntime {
  StalledNotesRuntime()
    : super(Platform.isMacOS ? '/usr/lib/libSystem.B.dylib' : 'libc.so.6');
  final entered = Completer<void>(), release = Completer<void>();
  final cancelled = <String>[];
  String? active;
  bool fail = false;
  @override
  bool get loaded => true;
  @override
  bool get generating => false;
  @override
  Map<String, dynamic> get effectiveState => {'state': 'ready'};
  @override
  Stream<Map<String, dynamic>> generateConversation(
    String id,
    String prompt, {
    int? maxOutputTokens = 1024,
    int? maxInputTokens,
    List<List<int>> stopTokenIds = const [],
    Duration timeout = const Duration(minutes: 5),
  }) async* {
    active = id;
    entered.complete();
    await release.future;
    if (fail) {
      yield {'type': 'done', 'status': 'failed'};
    } else {
      yield {'type': 'delta', 'text': '- Enhanced note'};
      yield {'type': 'done', 'status': 'completed'};
    }
    active = null;
  }

  @override
  bool cancel({String? requestId}) {
    if (requestId != active) return false;
    cancelled.add(requestId!);
    if (!release.isCompleted) release.complete();
    return true;
  }
}

void main() {
  late Directory root;
  late Store store;
  late Helper helper;
  late AdapterDomain domain;
  late Application app;
  late StalledNotesRuntime runtime;
  late int id;
  setUp(() {
    root = createTestTempDirectorySync('note-safety-');
    store = Store('${root.path}/app.db');
    helper = Helper(
      '${root.path}/helper.sock',
      '${root.path}/rag',
      manageProcess: false,
    );
    domain = AdapterDomain(store, helper);
    runtime = StalledNotesRuntime();
    domain.generator = runtime;
    app = Application(domain);
    store.setPreference('liveEnhance', 'false');
    id = store.meeting('Notes');
    store.saveMeetingNotes(id, 'Raw note');
    store.transcript(id, 'The release ships Friday.', true, 0, 1, 'microphone');
    store.artifact(id, 'enhanced_notes', '- Accepted note', 'fixture');
    addTearDown(() async {
      if (!runtime.release.isCompleted) runtime.release.complete();
      await app.close();
      domain.close();
      runtime.close();
      await helper.close();
      store.close();
      if (root.existsSync()) root.deleteSync(recursive: true);
    });
  });
  test('foreground actions preempt a stalled live Notes child', () async {
    final work = app.enhanceNotes(
      id,
      requestId: 'live',
      isLive: true,
      forceRegenerate: true,
    );
    await runtime.entered.future;
    // Subsequent action generation intentionally fails in this one-shot Notes
    // fixture; reaching its completion proves the Notes owner was joined.
    await expectLater(
      app.generateActions(id).timeout(const Duration(seconds: 2)),
      throwsA(anything),
    );
    await work;
    expect(runtime.cancelled, contains('live-batch-1'));
    expect(app.activeEnhancements, 0);
    expect(store.meetingEnhancedNotes(id), '- Accepted note');
  });
  test('public parent cancellation interrupts a stalled Notes child', () async {
    final work = app.enhanceNotes(id, requestId: 'parent');
    await runtime.entered.future;
    expect(app.cancelMeetingWorkflowRequest('other'), isFalse);
    expect(runtime.cancelled, isEmpty);
    expect(app.cancelMeetingWorkflowRequest('parent'), isTrue);
    await work.timeout(const Duration(seconds: 2));
    expect(runtime.cancelled, contains('parent-batch-1'));
    expect(store.meetingArtifacts(id, 'enhanced_notes'), hasLength(1));
    expect(store.meetingEnhancedNotes(id), '- Accepted note');
  });
  test(
    'raw edits during a stalled batch cancel it and preserve accepted output',
    () async {
      final work = app.enhanceNotes(id);
      await runtime.entered.future;
      store.saveMeetingNotes(id, 'New handwritten correction');
      await work.timeout(const Duration(seconds: 2));
      expect(runtime.cancelled, isNotEmpty);
      expect(store.meetingEnhancedNotes(id), '- Accepted note');
      expect(
        store.rows('SELECT body FROM meeting_notes').single['body'],
        'New handwritten correction',
      );
    },
  );
  test(
    'failed batches disclose fallback provenance rather than claiming full enhancement',
    () async {
      runtime.fail = true;
      final work = app.enhanceNotes(id);
      await runtime.entered.future;
      runtime.release.complete();
      await work;
      final artifact = store.meetingArtifacts(id, 'enhanced_notes').first;
      final manifest = jsonDecode(artifact['manifest'] as String) as Map;
      expect(manifest['degraded'], isTrue);
      expect(manifest['failed_batches'], isNotEmpty);
    },
  );
  test(
    'final full-history chunking retains early decisions beyond live retention',
    () {
      final text = List.generate(20000, (i) => 'word$i').join(' ');
      final reference = chunkNoteEnhancementTranscript(text),
          full = chunkNoteEnhancementTranscript(text, maxChunks: null);
      expect(reference, hasLength(50));
      expect(reference.first, isNot(contains('word0 ')));
      expect(full.length, greaterThan(50));
      expect(full.first, startsWith('word0 '));
      expect(full.last, endsWith('word19999'));
    },
  );
}
