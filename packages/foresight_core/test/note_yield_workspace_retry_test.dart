import 'sql_support_test_bootstrap.dart';
import 'dart:async';
import 'dart:io';
import 'package:foresight_core/foresight_core.dart';
import 'package:foresight_core/src/application.dart';
import 'package:foresight_core/src/rpc_error.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';

class HeldNotesRuntime extends NativeRuntime {
  HeldNotesRuntime()
    : super(Platform.isMacOS ? '/usr/lib/libSystem.B.dylib' : 'libc.so.6');
  final entered = Completer<void>(), release = Completer<void>();
  final cancelled = <String>[];
  @override
  bool get generating => false;
  @override
  bool get loaded => true;
  @override
  Map<String, dynamic> get effectiveState => {
    'state': 'ready',
    'context_length': 4096,
  };
  @override
  Stream<Map<String, dynamic>> generateConversation(
    String id,
    String prompt, {
    int? maxOutputTokens = 1024,
    int? maxInputTokens,
    List<List<int>> stopTokenIds = const [],
    Duration timeout = const Duration(minutes: 5),
  }) async* {
    entered.complete();
    await release.future;
    yield {'type': 'delta', 'text': '- Late accepted note'};
    yield {'type': 'done', 'status': 'completed'};
  }

  @override
  Stream<Map<String, dynamic>> generateSummary(
    String id,
    String prompt, {
    required String systemPrompt,
    int maxOutputTokens = 1024,
  }) async* {
    yield {'type': 'done', 'status': 'failed'};
  }

  @override
  bool cancel({String? requestId}) {
    if (requestId != null) cancelled.add(requestId);
    return true;
  }
}

void main() {
  bootstrapSqlSupportFixture();
  for (final cleared in [false, true]) {
    test(
      'yielded live Notes ${cleared ? "retires retry after clear and ID reuse" : "retains retry in the same workspace"}',
      () async {
        final directory = createTestTempDirectorySync('notes-retry-');
        final store = Store('${directory.path}/app.db');
        final helper = Helper(
          '${directory.path}/helper.sock',
          '${directory.path}/helper',
          manageProcess: false,
        );
        final timers = <({Duration duration, Timer timer})>[];
        final domain = Domain(
          store,
          helper,
          createTimer: (duration, callback) {
            final timer = Timer(const Duration(days: 1), () {});
            timers.add((duration: duration, timer: timer));
            return timer;
          },
        );
        final runtime = HeldNotesRuntime();
        domain.generator = runtime;
        final app = Application(domain);
        addTearDown(() async {
          if (!runtime.release.isCompleted) runtime.release.complete();
          for (final t in timers) {
            t.timer.cancel();
          }
          await app.close();
          domain.close();
          runtime.close();
          await helper.close();
          store.close();
          directory.deleteSync(recursive: true);
        });
        final id = store.meeting('Notes');
        store.saveMeetingNotes(id, 'Raw note');
        store.transcript(
          id,
          'Alice will ship Friday.',
          true,
          0,
          1,
          'microphone',
        );
        final work = app.enhanceNotes(
          id,
          isLive: true,
          forceRegenerate: true,
          requestId: 'live',
        );
        await runtime.entered.future;
        final foreground = app.call('meetings.generate', {
          'id': id,
          'kind': 'summary',
        });
        // The foreground fixture emits failed after the old live owner settles.
        final rejected = expectLater(
          foreground,
          cleared
              ? throwsA(
                  isA<RpcError>().having(
                    (e) => e.code,
                    'code',
                    RpcErrorCode.cancelled,
                  ),
                )
              : throwsStateError,
        );
        await Future<void>.delayed(Duration.zero);
        if (cleared) {
          await app.call('workspace.clear', {});
          expect(store.meeting('Replacement'), id);
          store.saveMeetingNotes(id, 'Replacement raw note');
          store.transcript(
            id,
            'Replacement transcript.',
            true,
            0,
            1,
            'microphone',
          );
        }
        final count = timers.length;
        runtime.release.complete();
        await work;
        await rejected;
        final retries = timers
            .skip(count)
            .where((t) => t.duration == const Duration(seconds: 3));
        expect(retries, cleared ? isEmpty : hasLength(1));
        expect(store.meetingArtifacts(id, 'enhanced_notes'), isEmpty);
      },
    );
  }
}
