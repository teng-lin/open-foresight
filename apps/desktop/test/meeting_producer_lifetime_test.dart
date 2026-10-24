import 'package:foresight_test_support/google_connections.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import '../test_support/core_fixture.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:open_foresight/main.dart';
import 'package:open_foresight/generated_content.dart';
import 'desktop_connection_fixture.dart';
import 'meeting_setup_test.dart' show OfflineHelper;
import 'pump_until.dart';

class _HeldMeetingProducer extends NativeRuntime {
  _HeldMeetingProducer(this.kind)
    : super(Platform.isMacOS ? '/usr/lib/libSystem.B.dylib' : 'libc.so.6');
  final String kind;
  final entered = Completer<void>(), release = Completer<void>();
  int cancellations = 0;
  @override
  bool get generating => false;
  @override
  Map<String, dynamic> get effectiveState => {'state': 'ready'};
  @override
  Stream<Map<String, dynamic>> generateSummary(
    String id,
    String prompt, {
    required String systemPrompt,
    int maxOutputTokens = 1024,
  }) async* {
    if (!entered.isCompleted) entered.complete();
    yield {
      'type': 'preview',
      'text': '# Overview\nHELD PREVIEW FOR ORIGINAL MEETING',
    };
    await release.future;
    var body = '# Overview\nLATE GENERATED BODY';
    if (kind == 'actions') {
      final evidence =
          ((jsonDecode(prompt) as Map)['evidence'] as List).first as Map;
      body = jsonEncode({
        'tasks': [
          {
            'task': 'Ship release',
            'owner': 'Alice',
            'due': 'Friday',
            'state': 'open',
            'evidence': [
              {'id': evidence['id'], 'quote': 'Alice will ship Friday.'},
            ],
          },
        ],
      });
    }
    yield {'type': 'delta', 'text': body};
    yield {'type': 'done', 'status': 'completed'};
  }

  @override
  bool cancel({String? requestId}) {
    cancellations++;
    // Deliberately keep the producer held: cancellation must not substitute for
    // actual settlement or allow a late terminal event to accept stale output.
    return true;
  }

  @override
  void close() {}
}

class _IndexingFixtureDomain extends AdapterDomain {
  _IndexingFixtureDomain(super.store, super.helper);
  @override
  Future<void> index(String id, {bool Function()? current}) async {
    if (current?.call() ?? true) store.state(id, 'indexed');
  }
}

void main() {
  for (final kind in ['summary', 'actions', 'preparation']) {
    for (final boundary in ['selection', 'clear', 'session', 'dispose']) {
      testWidgets(
        '$kind holds late producer across $boundary without replacing accepted data',
        (tester) async {
          await tester.binding.setSurfaceSize(const Size(1440, 1000));
          addTearDown(() => tester.binding.setSurfaceSize(null));
          final root = createTestTempDirectorySync('meeting-producer-');
          final path = '${root.path}/app.db';
          final store = Store(path);
          final original = store.meeting('Original meeting');
          final other = store.meeting('Other meeting');
          store.transcript(
            original,
            'Alice will ship Friday.',
            true,
            0,
            1,
            'microphone',
          );
          store.artifact(original, kind, 'ACCEPTED ORIGINAL $kind', 'fixture');
          store.artifact(other, kind, 'ACCEPTED OTHER $kind', 'fixture');
          final document = store.importText(
            'Local preparation',
            'Existing local agenda. ' * 16,
            'text/plain',
            'fixture',
          );
          if (kind == 'actions') {
            store.db.execute(
              "INSERT INTO meeting_tasks(meeting_id,task_key,task,owner,due,status,evidence,input_revision,manual) VALUES(?,'manual','Manual accepted task','Owner','Friday','completed','[]',1,1)",
              [original],
            );
          }
          final domain = _IndexingFixtureDomain(
            store,
            OfflineHelper('${root.path}/socket', '${root.path}/helper'),
          );
          final app = Application(domain);
          final connection = TestDesktopConnection(app);
          final runtime = _HeldMeetingProducer(kind);
          await tester.pumpWidget(
            Foresight(connection, deviceLoader: () async => []),
          );
          final shell =
              tester.state(find.byType(Workspace)) as WorkspaceTestAccess;
          final panel = {
            'summary': 'Summary',
            'actions': 'Action items',
            'preparation': 'Preparation',
          }[kind]!;
          shell.update(() {
            shell.meetingFeature.meetingId = original;
            shell.meetingFeature.meetingPanel = panel;
          });
          await tester.pumpAndSettle();
          domain.generator = runtime;
          var settled = false;
          Object? failure;
          await tester.runAsync(() async {
            final work = switch (kind) {
              'summary' => app.generateSummary(
                original,
                requestId: 'held-$kind',
              ),
              'actions' => app.generateActions(
                original,
                requestId: 'held-$kind',
              ),
              _ => app.prepareMeeting(original, [
                document,
              ], requestId: 'held-$kind'),
            };
            unawaited(
              work.then<void>(
                (_) {
                  settled = true;
                },
                onError: (Object error) {
                  failure = error;
                  settled = true;
                },
              ),
            );
          });
          await pumpUntil(tester, () => runtime.entered.isCompleted || settled);
          expect(
            failure,
            isNull,
            reason: 'The producer starts before the retirement boundary',
          );
          await tester.pump(const Duration(milliseconds: 100));
          expect(settled, isFalse);
          if (boundary == 'clear') {
            await tester.runAsync(
              () => app.call(Operation.workspaceClear.wire, {}),
            );
            await tester.pump(const Duration(milliseconds: 100));
            final replacement = store.meeting('Reused meeting ID');
            expect(replacement, original);
            store.artifact(
              replacement,
              kind,
              'ACCEPTED REPLACEMENT $kind',
              'fixture',
            );
            shell.update(() {
              shell.meetingFeature.meetingId = replacement;
              shell.meetingFeature.meetingPanel = panel;
            });
          } else if (boundary == 'dispose') {
            await tester.pumpWidget(const SizedBox.shrink());
          } else {
            if (boundary == 'session') {
              final epoch = connection.workspaceEpoch;
              final generation = connection.clientSessionGeneration;
              connection.replaceClientSessionForTesting();
              expect(connection.workspaceEpoch, epoch);
              expect(
                connection.clientSessionGeneration,
                isNot(same(generation)),
              );
            }
            shell.update(() => shell.meetingFeature.meetingId = other);
            if (kind == 'summary') {
              expect(app.cancelSummaryRequest('held-$kind'), isTrue);
            } else {
              expect(app.cancelMeetingWorkflowRequest('held-$kind'), isTrue);
            }
          }
          await tester.pump(const Duration(milliseconds: 100));
          expect(
            settled,
            isFalse,
            reason: 'A cancel signal does not settle the held producer',
          );
          expect(
            find.byWidgetPredicate(
              (widget) =>
                  widget is GeneratedContent &&
                  widget.markdown.contains('HELD PREVIEW'),
            ),
            findsNothing,
          );
          runtime.release.complete();
          await pumpUntil(tester, () => settled);
          expect(
            failure,
            isA<RpcError>().having(
              (error) => error.code,
              'code',
              RpcErrorCode.cancelled,
            ),
          );
          if (boundary != 'dispose') {
            await tester.pumpWidget(const SizedBox.shrink());
          }
          var closed = false;
          unawaited(
            connection.closed.then<void>((_) {
              closed = true;
            }),
          );
          await pumpUntil(tester, () => closed);
          final reopened = Store(path);
          try {
            expect(
              reopened.meetingArtifacts(original, kind).single['generated'],
              boundary == 'clear'
                  ? 'ACCEPTED REPLACEMENT $kind'
                  : 'ACCEPTED ORIGINAL $kind',
            );
            if (kind == 'actions' && boundary != 'clear') {
              expect(
                reopened
                    .rows(
                      'SELECT task,owner,due,status,manual FROM meeting_tasks',
                    )
                    .single,
                {
                  'task': 'Manual accepted task',
                  'owner': 'Owner',
                  'due': 'Friday',
                  'status': 'completed',
                  'manual': 1,
                },
              );
            }
          } finally {
            reopened.close();
          }
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
