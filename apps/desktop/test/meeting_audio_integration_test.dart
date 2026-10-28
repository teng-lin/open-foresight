import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foresight_core/desktop.dart';
import 'package:open_foresight/feature_request_identity.dart';
import 'package:open_foresight/features/meetings/audio_client_actions.dart';
import 'package:open_foresight/features/meetings/audio_panel.dart';
import 'package:open_foresight/features/meetings/audio_read_model.dart';
import 'package:open_foresight/features/meetings/transcript_view.dart';

final class Reader implements StoreReader {
  @override
  String workspaceEpoch = 'epoch';
  @override
  String dataRevision = '1';
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected read');
}

final class Connection implements DesktopConnection {
  @override
  final store = Reader();
  @override
  String? workspaceEpoch = 'epoch';
  @override
  Object clientSessionGeneration = Object();
  final calls = <(Operation, Map<String, dynamic>)>[];
  late Future<Object?> Function(Operation, Map<String, dynamic>) reply;
  @override
  Future<Object?> commandCurrent(
    Operation op,
    Map<String, dynamic> args,
    bool Function() current,
  ) async {
    if (!current()) throw RpcError(RpcErrorCode.cancelled, 'stale');
    calls.add((op, args));
    final value = await reply(op, args);
    if (!current()) throw RpcError(RpcErrorCode.cancelled, 'stale');
    return value;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected connection call');
}

AudioSessionPresentation session(String id) => AudioSessionPresentation(
  id: id,
  startedWallMs: 1,
  durationUs: 1000000,
  availability: MeetingAudioAvailability.available,
  retainedBytes: 10,
  stagingBytes: 0,
  hasGaps: false,
  sources: const [],
  compression: const AudioWorkPresentation(),
  export: const AudioWorkPresentation(),
  canExport: true,
  playbackSupported: true,
);
AudioMeetingReadPage page(
  int id, {
  List<AudioSessionPresentation> sessions = const [],
  String? next,
  bool supported = true,
  String serviceError = '',
  MeetingAudioPhysicalState physical = MeetingAudioPhysicalState.idle,
  int? estimatedRemainingRecordingUs,
}) => AudioMeetingReadPage(
  meeting: AudioMeetingPresentation(
    meetingId: id,
    physicalState: physical,
    estimatedRemainingRecordingUs: estimatedRemainingRecordingUs,
    sessionCount: 2,
    durationUs: 1000000,
    availability: MeetingAudioAvailability.available,
    retainedBytes: 10,
    stagingBytes: 0,
    sources: const [],
    compression: const AudioWorkPresentation(),
  ),
  sessions: sessions,
  nextAfterId: next,
  supported: supported,
  serviceError: serviceError,
);
Future<void> turn() => Future<void>(() {});
MeetingAudioClientActions actions(
  Connection c, {
  Future<AudioExportSelection?> Function(MeetingAudioExportFormat)? select,
}) => MeetingAudioClientActions(
  connection: () => c,
  identity: FeatureRequestIdentity.capture(c),
  alive: () => true,
  chooseDestination:
      select ??
      (_) async =>
          const AudioExportSelection('/chosen/audio.mp3', overwrite: true),
  changed: () async {},
);

void main() {
  testWidgets(
    'expanded live playback hides activity through every capture phase',
    (tester) async {
      final c = Connection();
      Future<void> show(MeetingAudioPhysicalState physical) =>
          tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: Column(
                  children: [
                    MeetingAudioPanel(
                      page: page(
                        1,
                        sessions: [session('active')],
                        physical: physical,
                        estimatedRemainingRecordingUs: 5400000000,
                      ),
                      sessions: [session('active')],
                      actions: actions(c),
                      onMore: () {},
                      hasMore: false,
                      loading: false,
                    ),
                    const Text(
                      'Meeting notes',
                      key: ValueKey('notes-position'),
                    ),
                  ],
                ),
              ),
            ),
          );
      await show(MeetingAudioPhysicalState.starting);
      expect(find.byType(Slider), findsNothing);
      await tester.tap(find.text('Show recording'));
      await tester.pump();
      final notes = tester.getTopLeft(
        find.byKey(const ValueKey('notes-position')),
      );
      for (final phase in MeetingAudioPhysicalState.values.where(
        (phase) => phase != MeetingAudioPhysicalState.idle,
      )) {
        await show(phase);
        expect(find.byType(Slider), findsOneWidget);
        expect(find.text('Hide recording'), findsOneWidget);
        expect(find.text('Recording'), findsNothing);
        expect(find.textContaining('Recording storage'), findsNothing);
        expect(
          find.textContaining('Estimated recording time remaining'),
          findsNothing,
        );
        expect(
          tester.getTopLeft(find.byKey(const ValueKey('notes-position'))),
          notes,
        );
      }
      await show(MeetingAudioPhysicalState.idle);
      expect(find.text('Saved recording'), findsOneWidget);
      expect(find.byTooltip('Play audio'), findsOneWidget);
      expect(c.calls, isEmpty);
    },
  );

  testWidgets(
    'live capture hides stale audio pages and transient read problems',
    (tester) async {
      final c = Connection();
      for (final current in <AudioMeetingReadPage?>[
        null,
        page(1, sessions: [session('stale')]),
        page(1, supported: false),
      ]) {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: MeetingAudioPanel(
                recording: true,
                page: current,
                sessions: [session('stale')],
                actions: actions(c),
                onMore: () {},
                hasMore: true,
                loading: true,
                problem: 'Recording audio could not be loaded.',
                onRetry: () {},
              ),
            ),
          ),
        );
        expect(find.text('Recording audio could not be loaded.'), findsNothing);
        expect(find.text('Retry'), findsNothing);
        expect(find.byType(Slider), findsNothing);
        expect(
          find.textContaining('unavailable in this app session'),
          findsNothing,
        );
        expect(find.text('Keep remaining originals'), findsNothing);
      }
      expect(c.calls, isEmpty);
    },
  );

  testWidgets('saved playback starts collapsed and can be shown or hidden', (
    tester,
  ) async {
    final c = Connection()..reply = (_, _) async => null;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MeetingAudioPanel(
            page: page(1, sessions: [session('saved')]),
            sessions: [session('saved')],
            actions: actions(c),
            onMore: () {},
            hasMore: false,
            loading: false,
          ),
        ),
      ),
    );
    expect(find.text('Show recording'), findsOneWidget);
    expect(find.byType(Slider), findsNothing);
    expect(find.textContaining('Recording storage'), findsNothing);
    await tester.tap(find.text('Show recording'));
    await tester.pump();
    expect(find.text('Hide recording'), findsOneWidget);
    expect(find.byType(Slider), findsOneWidget);
    expect(find.text('Keep remaining originals'), findsNothing);
    await tester.tap(find.byTooltip('Play audio'));
    await tester.pump();
    expect(c.calls.single.$1, Operation.recordingsPlay);
    await tester.tap(find.text('Hide recording'));
    await tester.pump();
    expect(find.byType(Slider), findsNothing);
    expect(find.text('Show recording'), findsOneWidget);
  });

  test(
    'delete and retention commands preserve the selected request identity',
    () async {
      final c = Connection();
      c.reply = (_, _) async => null;
      final a = actions(c);
      await a.setRetainLossless('recording-a', false);
      await a.deleteRecording('recording-b');
      await a.retryTranscription('recording-c');
      await a.retryCompression('recording-d');
      expect(c.calls.map((x) => x.$1), [
        Operation.recordingsSetRetainLossless,
        Operation.recordingsDelete,
        Operation.recordingsRetryTranscription,
        Operation.recordingsRetryCompression,
      ]);
      expect(c.calls.first.$2, {
        'session_id': 'recording-a',
        'retain_lossless': false,
        'workspace_epoch': 'epoch',
      });
      c.clientSessionGeneration = Object();
      await expectLater(
        a.deleteRecording('recording-a'),
        throwsA(isA<RpcError>()),
      );
      expect(c.calls, hasLength(4));
    },
  );
  test(
    'overwrite needs explicit consent and every native chooser boundary is fenced',
    () async {
      var live = true, confirmed = 0;
      Future<AudioExportSelection?> choose({
        required bool existing,
        required bool approve,
      }) => selectAudioExportDestination(
        choosePath: () async => '/chosen/file',
        exists: (_) async => existing,
        confirmOverwrite: () async {
          confirmed++;
          return approve;
        },
        current: () => live,
      );
      expect((await choose(existing: false, approve: false))!.overwrite, false);
      expect(confirmed, 0);
      expect(await choose(existing: true, approve: false), isNull);
      expect(confirmed, 1);
      expect((await choose(existing: true, approve: true))!.overwrite, true);
      expect(confirmed, 2);
      final stale = await selectAudioExportDestination(
        choosePath: () async => '/chosen/file',
        exists: (_) async {
          live = false;
          return true;
        },
        confirmOverwrite: () async {
          confirmed++;
          return true;
        },
        current: () => live,
      );
      expect(stale, isNull);
      expect(confirmed, 2);
    },
  );

  test(
    'late selection and replaced client reads never publish into the new meeting',
    () async {
      final c = Connection();
      final first = Completer<Object?>();
      final second = Completer<Object?>();
      c.reply = (op, args) =>
          args['meeting_id'] == 1 ? first.future : second.future;
      final model = MeetingAudioReadModel(connection: () => c, changed: () {});
      model.bind(1);
      model.bind(2);
      first.complete(page(1).toMap());
      await turn();
      expect(model.page, isNull);
      second.complete(page(2).toMap());
      await turn();
      expect(model.page!.meeting.meetingId, 2);
      final old = Completer<Object?>();
      c.reply = (op, args) => old.future;
      final pending = model.refresh();
      c.clientSessionGeneration = Object();
      old.complete(page(1).toMap());
      await pending;
      expect(model.page!.meeting.meetingId, 2);
      model.dispose();
    },
  );
  test(
    'session pages stay paginated and refresh their loaded ranges',
    () async {
      final c = Connection();
      c.reply = (op, args) async => args['after_session_id'] == ''
          ? page(1, sessions: [session('a')], next: 'a').toMap()
          : page(1, sessions: [session('b')]).toMap();
      final model = MeetingAudioReadModel(connection: () => c, changed: () {});
      model.bind(1);
      await turn();
      await model.loadMore();
      expect(model.sessions.map((s) => s.id), ['a', 'b']);
      await model.refresh();
      expect(c.calls.map((c) => c.$2['after_session_id']), ['', 'a', '', 'a']);
      expect(c.calls.every((c) => c.$2['workspace_epoch'] == 'epoch'), true);
      model.dispose();
    },
  );
  test(
    'native save selection and explicit choices become a bounded output grant',
    () async {
      final c = Connection();
      c.reply = (op, args) async =>
          op == Operation.recordingsAuthorizeExportDestination
          ? {'token': 'one-use'}
          : {'jobId': 'job'};
      await actions(
        c,
      ).export('session', MeetingAudioExportFormat.mp3, allowIncomplete: true);
      expect(c.calls.map((c) => c.$1), [
        Operation.recordingsAuthorizeExportDestination,
        Operation.recordingsExport,
      ]);
      expect(
        c.calls.first.$2,
        containsPair('output_path', '/chosen/audio.mp3'),
      );
      expect(c.calls.last.$2, containsPair('destination_token', 'one-use'));
      expect(c.calls.last.$2.containsKey('output_path'), false);
      expect(
        c.calls.every(
          (c) =>
              c.$2['allow_incomplete'] == true &&
              c.$2['overwrite'] == true &&
              c.$2['format'] == 'mp3' &&
              c.$2['workspace_epoch'] == 'epoch',
        ),
        true,
      );
      final selection = Completer<AudioExportSelection?>();
      final stale = actions(c, select: (_) => selection.future);
      final pending = stale.export(
        'session',
        MeetingAudioExportFormat.mp3,
        allowIncomplete: false,
      );
      c.clientSessionGeneration = Object();
      selection.complete(
        const AudioExportSelection('/other', overwrite: false),
      );
      await pending;
      expect(c.calls.length, 2);
    },
  );
  test(
    'transcript listen resolves identity then service revalidates link, never UI offset',
    () async {
      final c = Connection();
      c.reply = (op, args) async => op == Operation.recordingsTranscriptTarget
          ? const AudioTranscriptSeekTarget(
              transcriptId: 7,
              sessionId: 's',
              playbackUs: 123,
            ).toMap()
          : null;
      await actions(c).listenToTranscript(7);
      expect(c.calls.last.$1, Operation.recordingsSeekTranscript);
      expect(c.calls.last.$2, containsPair('transcript_id', 7));
      expect(c.calls.last.$2.containsKey('playback_us'), false);
    },
  );
  testWidgets(
    'unsupported adapter is explicit while supported silent audio offers real commands',
    (tester) async {
      final c = Connection()..reply = (op, args) async => null;
      Future<void> show(bool supported) => tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MeetingAudioPanel(
              page: page(1, sessions: [session('s')], supported: supported),
              sessions: [session('s')],
              actions: actions(c),
              onMore: () {},
              hasMore: false,
              loading: false,
            ),
          ),
        ),
      );
      await show(false);
      await tester.tap(find.text('Show recording'));
      await tester.pump();
      expect(
        find.textContaining('unavailable in this app session'),
        findsOneWidget,
      );
      expect(find.byTooltip('Play audio'), findsNothing);
      await show(true);
      await tester.tap(find.byTooltip('Play audio'));
      await tester.pump();
      expect(c.calls.single.$1, Operation.recordingsPlay);
    },
  );
  testWidgets('saved audio fault remains visible with recording controls', (
    tester,
  ) async {
    final c = Connection()..reply = (op, args) async => null;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MeetingAudioPanel(
            page: page(
              1,
              sessions: [session('s')],
              serviceError: 'Audio worker requires restart',
            ),
            sessions: [session('s')],
            actions: actions(c),
            onMore: () {},
            hasMore: false,
            loading: false,
          ),
        ),
      ),
    );
    expect(find.text('Audio worker requires restart'), findsNothing);
    await tester.tap(find.text('Show recording'));
    await tester.pump();
    expect(find.text('Audio worker requires restart'), findsOneWidget);
    expect(find.byTooltip('Play audio'), findsOneWidget);
    await tester.pump();
    expect(find.text('Audio worker requires restart'), findsOneWidget);
  });
  testWidgets(
    'selected transcript section offers listening while retaining full text selection',
    (tester) async {
      int? heard;
      final rows = [
        TranscriptSegment.fromRow({
          'id': 7,
          'source': 'microphone',
          'text': 'First words',
          'final': 1,
        }),
        TranscriptSegment.fromRow({
          'id': 8,
          'source': 'playback',
          'text': 'Second words',
          'final': 1,
        }),
      ];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MeetingTranscriptPanel(
              id: 1,
              rows: rows,
              provisional: const {},
              questions: false,
              showProvisional: false,
              hasAttachments: false,
              canAnswer: false,
              onImportTranscript: null,
              onImportAttachments: null,
              onCopy: (_) {},
              onQuestion: (_) {},
              onListen: (id) => heard = id,
            ),
          ),
        ),
      );
      final field = tester.widget<EditableText>(find.byType(EditableText));
      field.focusNode.requestFocus();
      await tester.pump();
      field.controller.selection = TextSelection(
        baseOffset: field.controller.text.indexOf('Second'),
        extentOffset: field.controller.text.length,
      );
      await tester.pump();
      final state = tester.state<EditableTextState>(find.byType(EditableText));
      state.showToolbar();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Listen to this section'));
      await tester.pump();
      expect(heard, 8);
      expect(field.controller.text, contains('First words'));
      expect(field.controller.text, contains('Second words'));
    },
  );
}
