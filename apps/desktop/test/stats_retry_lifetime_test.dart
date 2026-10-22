import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foresight_core/remote.dart';
import 'package:foresight_core/src/application.dart';
import 'package:foresight_core/src/domain.dart';
import 'package:foresight_core/src/graph_labels.dart';
import 'package:foresight_core/src/store.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:open_foresight/main.dart';

import 'controller_fixture.dart';
import 'meeting_setup_test.dart' show OfflineHelper;

// Gate only the public typed Stats read; all other projections use the real
// fixture reader. This exposes replies that outlive the desktop client session.
class _StatsReader implements StoreReader {
  final StoreReader delegate;
  final requests = <Completer<ReadResult<OutputStats>>>[];
  String? epoch;
  _StatsReader(this.delegate);

  void succeed(int index, int words) => requests[index].complete(
    ReadResult(
      freshness: ReadFreshness.current,
      value: OutputStats(
        words: words,
        weekly: [0, 0, 0, 0, words],
        recordedMeetings: 2,
        sources: 3,
        completedAnswers: 4,
      ),
      requestTag: 'stats-$index',
      sequence: index,
    ),
  );

  @override
  Future<ReadResult<T>> read<T>(ReadQuery<T> query) {
    if (query.projection != 'output_stats') return delegate.read(query);
    final reply = Completer<ReadResult<OutputStats>>();
    requests.add(reply);
    return reply.future.then((result) => result.asType<T>());
  }

  @override
  Stream<ReadResult<T>> watch<T>(ReadQuery<T> query) => delegate.watch(query);
  @override
  RpcError? get failure => delegate.failure;
  @override
  String get workspaceEpoch => epoch ?? delegate.workspaceEpoch;
  @override
  String get dataRevision => delegate.dataRevision;
  @override
  String preference(String key, [String fallback = '']) =>
      delegate.preference(key, fallback);
  @override
  ModelRegistration? model(String kind) => delegate.model(kind);
  @override
  List<ModelRegistration> get models => delegate.models;
  @override
  List<SourceSummary> get sourceSummaries => delegate.sourceSummaries;
  @override
  SourceDocument? sourceById(String id, {bool includeDeleted = false}) =>
      delegate.sourceById(id, includeDeleted: includeDeleted);
  @override
  List<NoteSummary> get noteSummaries => delegate.noteSummaries;
  @override
  String noteBody(int id) => delegate.noteBody(id);
  @override
  Map<String, String> get googleSourceMimes => delegate.googleSourceMimes;
  @override
  List<DocumentLabel> get documentLabels => delegate.documentLabels;
  @override
  List<DocumentCluster> get documentClusters => delegate.documentClusters;
  @override
  List<String> get documentClusterNames => delegate.documentClusterNames;
  @override
  String graphLabelSet() => delegate.graphLabelSet();
  @override
  List<MeetingCollectionEntry> get meetingCollection =>
      delegate.meetingCollection;
  @override
  MeetingNoteData? meetingNote(int id) => delegate.meetingNote(id);
  @override
  MeetingDetails? meetingPreview(int id) => delegate.meetingPreview(id);
  @override
  MeetingDetails? meetingWorkspace(int id) => delegate.meetingWorkspace(id);
  @override
  int? meetingRevision(int id) => delegate.meetingRevision(id);
  @override
  List<MeetingQuestion> meetingQuestions(int id) =>
      delegate.meetingQuestions(id);
  @override
  List<TranscriptSegment> meetingTranscript(int id, {bool finalOnly = false}) =>
      delegate.meetingTranscript(id, finalOnly: finalOnly);
  @override
  List<MeetingArtifact> meetingArtifacts(int id, String kind) =>
      delegate.meetingArtifacts(id, kind);
  @override
  String meetingEnhancedNotes(int id) => delegate.meetingEnhancedNotes(id);
  @override
  List<MeetingTask> meetingTasks(int id) => delegate.meetingTasks(id);
  @override
  List<SavedAnswer> conversationAnswers(int? meeting) =>
      delegate.conversationAnswers(meeting);
  @override
  List<ExportNote> get exportNotes => delegate.exportNotes;
  @override
  List<CalendarAttachment> calendarAttachments(int meeting) =>
      delegate.calendarAttachments(meeting);
}

class _StatsConnection extends ControllerConnection {
  StoreReader? statsReader;
  _StatsConnection(super.application);
  @override
  StoreReader get store => statsReader ?? super.store;
}

Future<
  ({
    dynamic feature,
    _StatsReader reader,
    _StatsConnection connection,
    Store store,
  })
>
_mount(WidgetTester tester) async {
  final root = createTestTempDirectorySync('stats-retry-');
  final store = Store('${root.path}/app.db');
  final connection = _StatsConnection(
    Application(
      Domain(store, OfflineHelper('${root.path}/sock', '${root.path}/helper')),
    ),
  );
  final reader = _StatsReader(connection.store);
  connection.statsReader = reader;
  await tester.binding.setSurfaceSize(const Size(1400, 1000));
  await tester.pumpWidget(Foresight(connection, deviceLoader: () async => []));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Stats').first);
  await tester.pumpAndSettle();
  final dynamic shell = tester.state(find.byType(Workspace));
  expect(reader.requests, hasLength(1));
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    // Settle every gated reply after disposal so no test leaks async ownership.
    for (var i = 0; i < reader.requests.length; i++) {
      if (!reader.requests[i].isCompleted) reader.succeed(i, 0);
    }
    await tester.pumpAndSettle();
    await tester.binding.setSurfaceSize(null);
    if (root.existsSync()) root.deleteSync(recursive: true);
  });
  return (
    feature: shell.settingsFeature,
    reader: reader,
    connection: connection,
    store: store,
  );
}

void main() {
  for (final timeout in [true, false]) {
    testWidgets(
      'Stats retries same-input ${timeout ? 'timeout' : 'failure'} without a rebuild loop',
      (tester) async {
        final f = await _mount(tester);
        f.reader.succeed(0, 17);
        await tester.pumpAndSettle();
        expect(f.feature.localOutputCount, 17);
        expect(f.feature.localOutputWeekly, [0, 0, 0, 0, 17]);
        expect(
          [
            f.feature.recordedMeetings,
            f.feature.sourceCount,
            f.feature.completedAnswers,
          ],
          [2, 3, 4],
        );

        // Begin a legitimate refresh, then keep both the DB and week unchanged
        // throughout failure and recovery.
        f.store.setPreference('stats.retry.fixture', 'refresh');
        f.feature.localWords();
        expect(f.reader.requests, hasLength(2));
        final revision = f.reader.dataRevision;
        final key = f.feature.localOutputRevision;
        if (timeout) {
          f.reader.requests[1].completeError(
            TimeoutException('transient Stats timeout'),
          );
        } else {
          f.reader.requests[1].complete(
            ReadResult<OutputStats>(
              freshness: ReadFreshness.failed,
              value: null,
              error: RpcError(
                RpcErrorCode.unavailable,
                'transient Stats failure',
              ),
              requestTag: 'failed',
              sequence: 1,
            ),
          );
        }
        await tester.pumpAndSettle();
        expect(
          f.reader.requests,
          hasLength(2),
          reason: 'failure must not schedule a rebuild',
        );
        expect(f.feature.localOutputCount, 17);
        expect(f.feature.localOutputWeekly, [0, 0, 0, 0, 17]);
        expect(
          [
            f.feature.recordedMeetings,
            f.feature.sourceCount,
            f.feature.completedAnswers,
          ],
          [2, 3, 4],
        );
        expect(f.feature.localWords(), 17);
        expect(f.reader.requests, hasLength(3));
        expect(f.reader.dataRevision, revision);
        expect(f.feature.localOutputRevision, key);
        f.reader.succeed(2, 23);
        await tester.pumpAndSettle();
        expect(f.feature.localOutputCount, 23);
        expect(f.feature.localOutputWeekly, [0, 0, 0, 0, 23]);
        f.feature.localWords();
        expect(
          f.reader.requests,
          hasLength(3),
          reason: 'successful values remain cached',
        );
      },
    );
  }

  for (final boundary in ['client', 'epoch', 'disposal']) {
    for (final failure in [false, true]) {
      testWidgets(
        'retired Stats ${failure ? 'error' : 'success'} after $boundary cannot publish or clear a newer key',
        (tester) async {
          final f = await _mount(tester);
          final revision = f.reader.dataRevision;
          final key = f.feature.localOutputRevision;
          switch (boundary) {
            case 'client':
              f.connection.replaceClientSessionForTesting();
            case 'epoch':
              f.reader.epoch = 'replacement-workspace';
              f.connection.adoptWorkspace();
            case 'disposal':
              await tester.pumpWidget(const SizedBox());
          }
          if (boundary != 'disposal') {
            // Same revision/week still needs a read owned by the new identity.
            f.feature.localWords();
            expect(f.reader.requests, hasLength(2));
            f.reader.succeed(1, 31);
            await tester.pumpAndSettle();
            expect(f.feature.localOutputCount, 31);
          }
          if (failure) {
            f.reader.requests[0].completeError(
              StateError('retired Stats error'),
            );
          } else {
            f.reader.succeed(0, 999);
          }
          await tester.pumpAndSettle();
          expect(f.feature.localOutputCount, boundary == 'disposal' ? 0 : 31);
          expect(f.feature.localOutputRevision, key);
          if (boundary != 'disposal') {
            expect(f.reader.dataRevision, revision);
            f.feature.localWords();
            expect(f.reader.requests, hasLength(2));
          }
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
