import 'package:open_foresight/shell/workspace_tab.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foresight_core/foresight_core.dart';
import 'package:foresight_core/desktop.dart' show SourceSummary;
import 'package:foresight_core/remote.dart'
    show StoreReader, RpcError, RpcErrorCode;
import 'package:foresight_core/src/application.dart';
import 'package:foresight_core/src/generated/helper_control.pb.dart' as control;
import 'package:foresight_core/src/read_coordinator.dart';
import 'package:foresight_core/src/sqlite_read_session.dart';
import 'package:foresight_core/src/sqlite_store_reader.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:open_foresight/main.dart';
import 'package:open_foresight/features/integrations/desktop_settings.dart';
import 'controller_fixture.dart' show ControllerConnection;
import 'meeting_setup_test.dart' show OfflineHelper;
import 'pump_until.dart';

class _HeldGraphRead implements ReadWorker {
  _HeldGraphRead(Store store, this.heldRead, this.failure)
    : session = SqliteReadSession.borrow(store);
  final SqliteReadSession session;
  final int heldRead;
  final RpcError? failure;
  final entered = Completer<void>(), release = Completer<void>();
  int reads = 0;
  bool rejectFollowing = true;
  Completer<void>? followingEntered, followingRelease;

  @override
  Future<ReadWorkerReply> read(ReadWorkerRequest request) async {
    final reply = session.query(request.projection, request.arguments);
    if (request.projection != 'graph_layout') return reply;
    reads++;
    if (reads == heldRead) {
      entered.complete();
      await release.future;
      if (failure != null) throw failure!;
    } else if (reads > heldRead && rejectFollowing && failure != null) {
      throw failure!;
    }
    if (reads > heldRead && followingRelease != null) {
      if (!followingEntered!.isCompleted) followingEntered!.complete();
      await followingRelease!.future;
    }
    return reply;
  }

  @override
  Future<void> close() async => session.close();
}

class _GraphConnection extends ControllerConnection {
  _GraphConnection(super.application, this.reader);
  final SqliteStoreReader reader;
  Future<void>? _closingReader;
  @override
  StoreReader get store => reader;
  @override
  Future<void> initialize() async {}
  @override
  void close() {
    _closingReader ??= () async {
      // Join the real held worker before its borrowed writer is disposed.
      await reader.close();
      super.close();
      await super.closed;
    }();
  }

  @override
  Future<void> get closed => _closingReader ?? Future<void>.value();
}

class _GraphFixture {
  _GraphFixture(
    this.store,
    this.worker,
    this.connection,
    this.shell,
    this.points,
  );
  final Store store;
  final _HeldGraphRead worker;
  final _GraphConnection connection;
  final dynamic shell;
  final Map<String, GraphPoint> points;
  dynamic get feature => shell.sourceFeature;

  static Future<_GraphFixture> mount(
    WidgetTester tester,
    String branch,
    int heldRead,
    RpcError? failure,
  ) async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(DesktopSettings.channel, (call) async {
      expect(call.method, 'login.get');
      return true;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(DesktopSettings.channel, null),
    );
    final root = createTestTempDirectorySync('graph-read-retry-');
    final store = Store('${root.path}/app.db');
    final a = store.importText('Apollo', 'Launch', 'text/plain', 'fixture:a');
    final b = store.importText('Borealis', 'Budget', 'text/plain', 'fixture:b');
    for (final id in [a, b]) store.state(id, 'indexed');
    store.db.execute(
      'INSERT INTO models(kind,path,digest,runtime) VALUES(?,?,?,?)',
      ['embedding', '/fixture', 'digest', '/fixture'],
    );
    store.putDocumentLabel(
      DocumentLabel(a, 'Planning', 'user_defined', '#0EBC5F'),
    );
    final identity = jsonEncode([
      graphLayoutAlgorithmVersion,
      'digest',
      'tokenizer',
      'fixture',
      'cpu',
      3,
    ]);
    final points = {
      a: const GraphPoint(.25, .5, -.1),
      b: const GraphPoint(-.25, -.5, .1),
    };
    expect(
      store.saveGraphLayout(
        identity,
        store.sources,
        {
          a: [1.0, 0.0, 0.0],
          b: [.8, .6, 0.0],
        },
        points,
        labelSet: store.graphLabelSet(),
      ),
      true,
    );
    final helper = OfflineHelper('${root.path}/socket', '${root.path}/helper');
    if (branch == 'ready') {
      helper.snapshot = control.State(
        pipeline: 'ready',
        instanceId: 'original-helper',
        model: control.ModelIdentity(
          modelDigest: 'digest',
          tokenizerDigest: 'tokenizer',
          preprocessing: 'fixture',
          backend: 'cpu',
          dimensions: 3,
        ),
      );
    }
    final worker = _HeldGraphRead(store, heldRead, failure);
    final reader = SqliteStoreReader.borrow(store, worker: worker);
    final connection = _GraphConnection(
      Application(Domain(store, helper)),
      reader,
    );
    await tester.binding.setSurfaceSize(const Size(1440, 1000));
    await tester.pumpWidget(
      Foresight(connection, deviceLoader: () async => []),
    );
    await tester.pumpAndSettle();
    final dynamic shell = tester.state(find.byType(Workspace));
    final fixture = _GraphFixture(store, worker, connection, shell, points);
    addTearDown(() async {
      if (!worker.release.isCompleted) worker.release.complete();
      if (worker.followingRelease case final held? when !held.isCompleted) {
        held.complete();
      }
      await tester.pumpWidget(const SizedBox.shrink());
      var closed = false;
      unawaited(connection.closed.then<void>((_) => closed = true));
      await pumpUntil(tester, () => closed);
      await tester.binding.setSurfaceSize(null);
    });
    // Initial statistics and the Mac login-item reply can each rebuild the
    // workspace. Settle their publications and the statistics 100 ms relay
    // before measuring graph-only error rebuilds.
    shell.settingsFeature.localWords();
    await pumpUntil(
      tester,
      () =>
          shell.onboardingFeature.ready &&
          shell.settingsFeature.sourceCount == 2 &&
          (!Platform.isMacOS ||
              shell.integrationFeature.desktopSettings.openAtLogin),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();
    expect(shell.serviceUiTimer, isNull);
    shell.update(() {
      shell.navigate(WorkspaceTab.sources);
      shell.sourceFeature.graphAnimationPaused = true;
      shell.sourceFeature.graphView = true;
    });
    await pumpUntil(tester, () => worker.entered.isCompleted);
    return fixture;
  }

  void expectGeometry() {
    final actual = feature.graphPoints as Map<String, GraphPoint>;
    expect(actual.keys, unorderedEquals(points.keys));
    for (final id in points.keys) {
      expect(
        [actual[id]!.x, actual[id]!.y, actual[id]!.z],
        [points[id]!.x, points[id]!.y, points[id]!.z],
      );
    }
    expect(store.documentLabels.single.name, 'Planning');
    expect(store.documentLabels.single.colorHex, '#0EBC5F');
  }
}

void main() {
  for (final changed in ['model', 'instance', 'generation']) {
    for (final failed in [false, true]) {
      testWidgets(
        'ready read rejects a changed helper $changed ${failed ? "error" : "completion"}',
        (tester) async {
          final f = await _GraphFixture.mount(
            tester,
            'ready',
            1,
            failed ? RpcError(RpcErrorCode.busy, 'Retired helper error') : null,
          );
          f.shell.update(() {
            f.feature.graphView = false;
            f.feature.graphPoints = <String, GraphPoint>{
              'replacement': const GraphPoint(7, 8, 9),
            };
            f.feature.graphLayoutError = 'Replacement helper message';
          });
          final snapshot = f.connection.domain.helper.snapshot!;
          switch (changed) {
            case 'model':
              snapshot.model.path = '/replacement/model';
            case 'instance':
              snapshot.instanceId = 'replacement-helper';
            case 'generation':
              snapshot.activeGeneration += 1;
          }
          f.worker.release.complete();
          await tester.pumpAndSettle();
          expect((f.feature.graphPoints as Map).keys, ['replacement']);
          expect(f.feature.graphLayoutError, 'Replacement helper message');
          expect(f.connection.graphRequests, isEmpty);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
  for (final branch in ['cached', 'ready']) {
    testWidgets(
      '$branch deferred failure reset cannot clear a replacement request with the same key',
      (tester) async {
        final f = await _GraphFixture.mount(
          tester,
          branch,
          1,
          RpcError(RpcErrorCode.busy, 'First request failed'),
        );
        final key = f.feature.graphLayoutKey;
        f.worker.release.complete();
        // Settle only microtasks: the failed request queued its error render and
        // deferred key reset, but that frame has not run yet.
        await tester.idle();
        expect(f.feature.graphLayoutError, 'First request failed');
        expect(f.feature.graphLayoutKey, key);
        f.worker.rejectFollowing = false;
        f.worker.followingEntered = Completer<void>();
        f.worker.followingRelease = Completer<void>();
        // An independent explicit invalidation admits a same-input replacement
        // before the old request's deferred cleanup runs.
        f.feature.graphLayoutKey = '';
        f.feature.scheduleGraphLayout(
          f.store.sourceSummaries.map(SourceSummary.fromRow).toList(),
        );
        await tester.pump();
        expect(f.feature.graphLayoutKey, key);
        await pumpUntil(tester, () => f.worker.followingEntered!.isCompleted);
        expect(f.feature.graphLayoutKey, key);
        f.worker.followingRelease!.complete();
        await pumpUntil(
          tester,
          () =>
              f.feature.graphPoints.length == 2 &&
              !f.feature.graphOrganizing &&
              f.feature.graphLayoutError.isEmpty,
        );
        f.expectGeometry();
        expect(tester.takeException(), isNull);
      },
    );
  }
  for (final (branch, heldRead) in [
    ('cached', 1),
    ('cached', 2),
    ('ready', 1),
  ]) {
    for (final code in [RpcErrorCode.busy, RpcErrorCode.internal]) {
      testWidgets(
        '$branch read $heldRead handles $code without a retry loop and recovers unchanged inputs',
        (tester) async {
          final failure = RpcError(code, 'Held graph read failed');
          final f = await _GraphFixture.mount(
            tester,
            branch,
            heldRead,
            failure,
          );
          final key = f.feature.graphLayoutKey;
          final revision = f.shell.serviceUiRevision.value;
          f.worker.release.complete();
          await pumpUntil(tester, () => f.feature.graphLayoutError.isNotEmpty);
          await tester.pump();
          for (var frame = 0; frame < 5; frame++) await tester.pump();
          expect(
            f.worker.reads,
            heldRead,
            reason: 'Rendering the error does not retry it',
          );
          expect(f.feature.graphOrganizing, false);
          expect(f.feature.graphLayoutError, failure.message);
          expect(f.shell.serviceUiRevision.value, revision);
          expect(tester.takeException(), isNull);
          // A separate refresh retries the exact same model/documents/labels.
          f.connection.domain.helper.changed?.call();
          expect(f.shell.serviceUiTimer, isNotNull);
          expect(f.worker.reads, heldRead);
          await tester.pump(const Duration(milliseconds: 100));
          await pumpUntil(tester, () => f.worker.reads == heldRead + 1);
          await tester.pump();
          await tester.pump();
          for (var frame = 0; frame < 5; frame++) await tester.pump();
          expect(
            f.worker.reads,
            heldRead + 1,
            reason: 'Repeated failures remain bounded',
          );
          f.worker.rejectFollowing = false;
          f.connection.domain.helper.changed?.call();
          await tester.pump(const Duration(milliseconds: 100));
          await pumpUntil(
            tester,
            () =>
                f.feature.graphPoints.length == 2 &&
                !f.feature.graphOrganizing &&
                f.feature.graphLayoutError.isEmpty,
          );
          expect(f.feature.graphLayoutKey, key);
          f.expectGeometry();
          expect(
            f.connection.graphRequests,
            isEmpty,
            reason: 'The complete saved layout needs no new embeddings',
          );
          expect(tester.takeException(), isNull);
        },
      );
    }
    for (final boundary in ['session', 'dispose']) {
      for (final failed in [false, true]) {
        testWidgets(
          '$branch read $heldRead rejects retired $boundary ${failed ? "error" : "completion"}',
          (tester) async {
            final f = await _GraphFixture.mount(
              tester,
              branch,
              heldRead,
              failed
                  ? RpcError(RpcErrorCode.busy, 'Retired graph error')
                  : null,
            );
            final retired = f.feature;
            if (boundary == 'session') {
              f.shell.update(() {
                retired.graphView = false;
                retired.graphPoints = <String, GraphPoint>{
                  'replacement': const GraphPoint(7, 8, 9),
                };
                retired.graphLayoutError = 'Replacement owner message';
              });
              final epoch = f.connection.workspaceEpoch;
              f.connection.replaceClientSessionForTesting();
              await tester.pump(const Duration(milliseconds: 100));
              expect(f.connection.workspaceEpoch, epoch);
            } else {
              await tester.pumpWidget(const SizedBox.shrink());
            }
            f.worker.release.complete();
            await tester.pumpAndSettle();
            expect(
              f.worker.reads,
              heldRead,
              reason: 'A retired first read cannot begin the second read',
            );
            if (boundary == 'session') {
              expect((retired.graphPoints as Map).keys, ['replacement']);
              expect(retired.graphLayoutError, 'Replacement owner message');
            }
            expect(tester.takeException(), isNull);
          },
        );
      }
    }
  }
}
