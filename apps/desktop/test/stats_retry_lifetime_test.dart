import 'package:open_foresight/features/settings/settings_controller.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foresight_core/remote.dart';
import '../test_support/core_fixture.dart';

import 'package:foresight_test_support/test_paths.dart';
import 'package:open_foresight/main.dart';

import 'controller_fixture.dart';
import 'meeting_setup_test.dart' show OfflineHelper;

// Gate only the public typed Stats read; all other projections use the real
// fixture reader. This exposes replies that outlive the desktop client session.
class _StatsReader implements StoreReader {
  final StoreReader delegate;
  final requests = <StreamController<ReadResult<OutputStats>>>[];
  final queries = <ReadQuery<Object?>>[];
  String? epoch;
  _StatsReader(this.delegate);

  void succeed(int index, int words) => requests[index].add(
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
  Future<ReadResult<T>> read<T>(ReadQuery<T> query) => delegate.read(query);

  @override
  Stream<ReadResult<T>> watch<T>(ReadQuery<T> query) {
    if (query.projection != 'output_stats') return delegate.watch(query);
    final reply = StreamController<ReadResult<OutputStats>>.broadcast(
      sync: true,
    );
    queries.add(query);
    requests.add(reply);
    return reply.stream.map((result) => result.asType<T>());
  }

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
    SettingsController feature,
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
  final shell = tester.state(find.byType(Workspace)) as WorkspaceTestAccess;
  expect(reader.requests, hasLength(1));
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    for (final reply in reader.requests) {
      await reply.close();
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
      'Stats retains same-input ${timeout ? 'timeout' : 'failure'} values without a rebuild loop and recovers on its watch',
      (tester) async {
        final f = await _mount(tester);
        f.reader.succeed(0, 17);
        await tester.pumpAndSettle();
        void expectValues(int words) {
          expect(f.feature.localOutputCount, words);
          expect(f.feature.localOutputWeekly, [0, 0, 0, 0, words]);
          expect(
            [
              f.feature.recordedMeetings,
              f.feature.sourceCount,
              f.feature.completedAnswers,
            ],
            [2, 3, 4],
          );
        }

        expectValues(17);
        f.store.setPreference('stats.retry.fixture', 'refresh');
        f.connection.application.changed();
        await tester.pumpAndSettle();
        final revision = f.reader.dataRevision;
        final key = f.reader.queries.single.key;
        expect(
          f.reader.requests,
          hasLength(1),
          reason: 'data refresh preserves the stable watch',
        );
        if (timeout) {
          f.reader.requests[0].addError(
            TimeoutException('transient Stats timeout'),
          );
        } else {
          f.reader.requests[0].add(
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
          hasLength(1),
          reason: 'failure must not admit another query from a rebuild',
        );
        expectValues(17);
        expect(f.feature.localWords(), 17);
        await tester.pumpAndSettle();
        expect(
          f.reader.requests,
          hasLength(1),
          reason: 'a display getter never schedules reads',
        );
        expect(f.reader.dataRevision, revision);
        expect(f.reader.queries.single.key, key);
        // A successful later dispatch of the same watch recovers all metrics.
        f.reader.succeed(0, 23);
        await tester.pumpAndSettle();
        expectValues(23);
        f.feature.localWords();
        expect(
          f.reader.requests,
          hasLength(1),
          reason: 'successful values remain cached',
        );
      },
    );
  }

  for (final boundary in ['client', 'epoch', 'disposal']) {
    for (final failure in [false, true]) {
      testWidgets(
        'retired Stats ${failure ? 'error' : 'success'} after $boundary cannot publish or replace a newer query',
        (tester) async {
          final f = await _mount(tester);
          final revision = f.reader.dataRevision;
          final key = f.reader.queries.single.key;
          switch (boundary) {
            case 'client':
              f.connection.replaceClientSessionForTesting();
            case 'epoch':
              f.reader.epoch = 'replacement-workspace';
              f.connection.adoptWorkspace();
              f.connection.application.changed();
            case 'disposal':
              await tester.pumpWidget(const SizedBox());
          }
          await tester.pumpAndSettle();
          if (boundary != 'disposal') {
            expect(f.reader.requests, hasLength(2));
            f.reader.succeed(1, 31);
            await tester.pumpAndSettle();
            expect(f.feature.localOutputCount, 31);
          }
          if (failure) {
            f.reader.requests[0].addError(StateError('retired Stats error'));
          } else {
            f.reader.succeed(0, 999);
          }
          await tester.pumpAndSettle();
          expect(f.feature.localOutputCount, boundary == 'disposal' ? 0 : 31);
          expect(f.reader.queries.last.key, key);
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
