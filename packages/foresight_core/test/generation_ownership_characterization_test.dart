import 'sql_support_test_bootstrap.dart';
import 'dart:async';
import 'dart:io';

import 'package:foresight_core/foresight_core.dart';
import 'package:foresight_core/src/application.dart';
import 'package:foresight_core/src/rpc_error.dart';
import 'package:foresight_test_support/google_connections.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';

/// Cancellation acknowledges the request while the native stream still owns
/// resources. Its explicit release models cleanup that has not settled yet.
class DrainingGenerationRuntime extends NativeRuntime {
  DrainingGenerationRuntime()
    : super(Platform.isMacOS ? '/usr/lib/libSystem.B.dylib' : 'libc.so.6');

  final entered = Completer<void>(), release = Completer<void>();
  final cancelled = <String>[];

  @override
  bool get loaded => true;
  @override
  bool get generating => false;
  @override
  Map<String, dynamic> get effectiveState => {
    'state': 'ready',
    'context_length': 4096,
  };

  Stream<Map<String, dynamic>> _drain(String id) async* {
    entered.complete();
    await release.future;
    yield {
      'type': 'delta',
      'text': 'A cancelled result must never be accepted.',
    };
    yield {'type': 'done', 'status': 'completed'};
  }

  @override
  Stream<Map<String, dynamic>> generateSummary(
    String id,
    String prompt, {
    required String systemPrompt,
    int maxOutputTokens = 1024,
  }) => _drain(id);

  @override
  Stream<Map<String, dynamic>> generateConversation(
    String id,
    String prompt, {
    int? maxOutputTokens = 1024,
    int? maxInputTokens,
    List<List<int>> stopTokenIds = const [],
    Duration timeout = const Duration(minutes: 5),
  }) => _drain(id);

  @override
  bool cancel({String? requestId}) {
    if (requestId == null) return false;
    cancelled.add(requestId);
    return true;
  }
}

void main() {
  bootstrapSqlSupportFixture();
  for (final kind in ['summary', 'actions', 'enhanced_notes']) {
    for (final mode in ['cancel', 'clear', 'close']) {
      test(
        '$kind reserves generation through $mode until child cleanup settles',
        () async {
          final directory = createTestTempDirectorySync('generation-owner-');
          final store = Store('${directory.path}/app.db');
          final helper = Helper(
            '${directory.path}/helper.sock',
            '${directory.path}/helper',
            manageProcess: false,
          );
          final domain = AdapterDomain(store, helper);
          final runtime = DrainingGenerationRuntime();
          domain.generator = runtime;
          final app = Application(domain);
          store.setPreference('liveEnhance', 'false');
          final meeting = store.meeting('Ownership');
          store.saveMeetingNotes(meeting, 'Original note');
          store.transcript(
            meeting,
            'Alice will ship Friday.',
            true,
            0,
            1,
            'microphone',
          );
          addTearDown(() async {
            if (!runtime.release.isCompleted) runtime.release.complete();
            await app.close();
            domain.close();
            runtime.close();
            await helper.close();
            store.close();
            directory.deleteSync(recursive: true);
          });

          final work = switch (kind) {
            'summary' => app.generateSummary(meeting, requestId: 'parent'),
            'actions' => app.generateActions(meeting, requestId: 'parent'),
            _ => app.enhanceNotes(meeting, requestId: 'parent'),
          };
          final settled = kind == 'enhanced_notes'
              ? expectLater(work, completes)
              : expectLater(
                  work,
                  throwsA(
                    isA<RpcError>().having(
                      (error) => error.code,
                      'code',
                      RpcErrorCode.cancelled,
                    ),
                  ),
                );
          await runtime.entered.future;
          expect(app.generationReserved, isTrue);
          expect(app.backgroundBusy, isTrue);
          final cancel = kind == 'summary'
              ? app.cancelSummaryRequest
              : app.cancelMeetingWorkflowRequest;
          expect(cancel('peer'), isFalse);
          expect(runtime.cancelled, isEmpty);
          expect(cancel('parent'), isTrue);
          expect(runtime.cancelled, everyElement(startsWith('parent-')));
          expect(runtime.cancelled, isNotEmpty);

          Future<void>? closing;
          var closed = false;
          if (mode == 'clear') {
            await app.call('workspace.clear', {});
            expect(store.meeting('Replacement'), meeting);
            store.saveMeetingNotes(meeting, 'Replacement note');
            expect(app.captureState['meeting_summaries'], isEmpty);
            expect(app.captureState['meeting_workflows'], isEmpty);
            expect(app.captureState['note_enhancements'], isEmpty);
          } else if (mode == 'close') {
            closing = app.close().then((_) => closed = true);
            await Future<void>.delayed(Duration.zero);
            expect(closed, isFalse);
          }

          // Native cancellation has acknowledged but its stream has not settled.
          // Another owner must not take generation in this interval.
          expect(app.generationReserved, isTrue);
          expect(app.backgroundBusy, isTrue);
          await expectLater(
            app.generateSummary(meeting, requestId: 'peer'),
            throwsA(
              isA<RpcError>().having(
                (error) => error.code,
                'code',
                mode == 'close' ? RpcErrorCode.unavailable : RpcErrorCode.busy,
              ),
            ),
          );
          expect(store.meetingArtifacts(meeting, kind), isEmpty);

          runtime.release.complete();
          await settled;
          await closing;
          if (mode == 'close') expect(closed, isTrue);
          if (mode == 'clear') {
            expect(
              store.rows('SELECT body FROM meeting_notes WHERE meeting_id=?', [
                meeting,
              ]).single['body'],
              'Replacement note',
            );
          }
          expect(app.generationReserved, isFalse);
          expect(app.backgroundBusy, isFalse);
          expect(store.meetingArtifacts(meeting, kind), isEmpty);
        },
      );
    }
  }
}
