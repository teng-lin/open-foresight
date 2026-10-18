import 'desktop_connection_fixture.dart';
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_foresight/domain.dart';
import 'package:open_foresight/main.dart';
import 'package:open_foresight/store.dart';
import 'package:open_foresight/graph_rendering.dart';
import 'package:open_foresight/generated/helper_control.pb.dart' as control;
import 'meeting_setup_test.dart' show OfflineHelper;

class SourceReadCountingStore extends Store {
  int sourceReads = 0;
  int bodyReads = 0;
  @override
  List<Map<String, Object?>> get sources {
    bodyReads++;
    return super.sources;
  }

  SourceReadCountingStore(super.path);
  @override
  List<Map<String, Object?>> rows(String sql, [List<Object?> args = const []]) {
    if (sql.toLowerCase().contains('from sources')) sourceReads++;
    return super.rows(sql, args);
  }
}

class GraphDomain extends Domain {
  final requests = <Completer<Map<String, List<double>>>>[];
  GraphDomain(super.store, super.helper);
  @override
  Future<Map<String, List<double>>> graphEmbeddings(
    List<Map<String, Object?>> sources,
  ) {
    final request = Completer<Map<String, List<double>>>();
    requests.add(request);
    return request.future;
  }
}

void main() {
  testWidgets('steady graph animation does not reread large source bodies', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final temp = Directory.systemTemp.createTempSync(
      'foresight-graph-source-reads-',
    );
    addTearDown(() {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    });
    final store = SourceReadCountingStore('${temp.path}/app.db');
    final body = 'Independent source body search needle. '.padRight(
      64 * 1024,
      'x',
    );
    for (var i = 0; i < 250; i++) {
      store.importText('Document $i', body, 'text/plain', 'fixture:$i');
    }
    final helper = OfflineHelper('${temp.path}/socket', '${temp.path}/helper');
    await tester.pumpWidget(
      Foresight(
        TestDesktopConnection(Domain(store, helper)),
        deviceLoader: () async => [],
      ),
    );
    await tester.tap(find.text('Sources'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Graph view'));
    await tester.pump();
    await tester.pump();
    final dynamic state = tester.state(find.byType(Workspace));
    final before = store.sourceReads;
    final frameBefore = state.sourceFeature.graphMotionFrames.value as int;
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(state.sourceFeature.graphMotionFrames.value - frameBefore, 10);
    expect(
      store.sourceReads - before,
      0,
      reason: 'Projection-only frames must reuse the source snapshot',
    );
    final helpBefore = tester.widget(find.byTooltip('Help'));
    final bodiesBefore = store.bodyReads;
    final revisionBefore = state.serviceUiRevision.value as int;
    for (var i = 0; i < 20; i++) {
      helper.changed?.call();
    }
    await tester.pump(const Duration(milliseconds: 100));
    expect(state.serviceUiRevision.value, revisionBefore + 1);
    expect(
      identical(tester.widget(find.byTooltip('Help')), helpBefore),
      true,
      reason:
          'Service events update the active panel and header without rebuilding navigation',
    );
    expect(
      store.bodyReads,
      bodiesBefore,
      reason: 'Service events must not load document bodies on the UI isolate',
    );
    await tester.tap(find.byTooltip('Pause graph animation'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'body search needle');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('source-graph-canvas')), findsOneWidget);
    expect(find.text('No sources match the current filters.'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    temp.deleteSync(recursive: true);
  });
  testWidgets(
    'graph motion pauses, resumes without catch-up, and suspends offscreen or during drag',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final temp = Directory.systemTemp.createTempSync(
        'foresight-graph-motion-',
      );
      addTearDown(() {
        if (temp.existsSync()) temp.deleteSync(recursive: true);
      });
      final store = Store('${temp.path}/app.db');
      store.importText('Apollo', 'Launch', 'text/plain', 'fixture:a');
      store.importText('Borealis', 'Budget', 'text/plain', 'fixture:b');
      final helper = OfflineHelper(
        '${temp.path}/socket',
        '${temp.path}/helper',
      );
      final domain = Domain(store, helper);
      await tester.pumpWidget(
        Foresight(TestDesktopConnection(domain), deviceLoader: () async => []),
      );
      await tester.tap(find.text('Sources'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Graph view'));
      await tester.pump();
      await tester.pump();
      final dynamic state = tester.state(find.byType(Workspace));
      expect(state.sourceFeature.graphMotionTicker.isActive, true);
      final initial = state.sourceFeature.graphYaw as double;
      await tester.pump(const Duration(seconds: 1));
      expect(state.sourceFeature.graphYaw, greaterThan(initial));
      await tester.tap(find.byTooltip('Pause graph animation'));
      await tester.pumpAndSettle();
      for (
        final pollingClock = Stopwatch()..start();
        pollingClock.elapsed < const Duration(seconds: 5) &&
            state.sourceFeature.graphOrganizing;
      ) {
        await tester.runAsync(() => Future<void>(() {}));
        await tester.pump();
      }
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Zoom in'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(state.sourceFeature.graphCameraController.isAnimating, true);
      await tester.pump(const Duration(milliseconds: 51));
      expect(state.sourceFeature.graphCameraController.isAnimating, false);
      await tester.tap(find.byTooltip('Fit graph'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(state.sourceFeature.graphCameraController.isAnimating, true);
      await tester.pump(const Duration(milliseconds: 51));
      expect(state.sourceFeature.graphCameraController.isAnimating, false);
      final paused = state.sourceFeature.graphYaw as double;
      final sourcePaused = domain.sourcesPaused;
      await tester.pump(const Duration(seconds: 5));
      expect(state.sourceFeature.graphYaw, paused);
      expect(state.sourceFeature.graphMotionTicker.isActive, false);
      expect(domain.sourcesPaused, sourcePaused);
      await tester.tap(find.byTooltip('Resume graph animation'));
      await tester.pump();
      await tester.pump();
      expect(state.sourceFeature.graphYaw, paused);
      await tester.pump(const Duration(seconds: 1));
      expect(state.sourceFeature.graphYaw - paused, closeTo(.025, 1e-6));
      expect(
        state.sourceFeature.graphPitch,
        closeTo(.4 + .08 * math.sin(state.sourceFeature.graphYaw * .4), 1e-10),
      );
      final canvas = find.byKey(const ValueKey('source-graph-canvas'));
      final drag = await tester.startGesture(
        tester.getTopLeft(canvas) + const Offset(120, 80),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump();
      await drag.moveBy(const Offset(40, 20));
      await tester.pump();
      final manualYaw = state.sourceFeature.graphYaw as double;
      final manualPitch = state.sourceFeature.graphPitch as double;
      await tester.pump(const Duration(seconds: 3));
      expect(state.sourceFeature.graphYaw, manualYaw);
      expect(state.sourceFeature.graphMotionTicker.isActive, false);
      await drag.up();
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(state.sourceFeature.graphYaw, greaterThan(manualYaw));
      expect(state.sourceFeature.graphPitch, manualPitch);
      await tester.tap(find.text('Meetings').first);
      await tester.pumpAndSettle();
      final hidden = state.sourceFeature.graphYaw as double;
      await tester.pump(const Duration(seconds: 20));
      expect(state.sourceFeature.graphYaw, hidden);
      expect(state.sourceFeature.graphMotionTicker.isActive, false);
      await tester.tap(find.text('Sources'));
      await tester.pump();
      await tester.pump();
      expect(state.sourceFeature.graphYaw, hidden);
      await tester.pump(const Duration(seconds: 1));
      expect(state.sourceFeature.graphYaw - hidden, closeTo(.025, 1e-6));
      await tester.enterText(find.byType(TextField), 'missing source');
      await tester.pump();
      await tester.pump();
      expect(state.sourceFeature.graphMotionTicker.isActive, true);
      expect(find.byKey(const ValueKey('source-graph-canvas')), findsOneWidget);
      await tester.enterText(find.byType(TextField), '');
      await tester.pump();
      await tester.pump();
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      await tester.pumpAndSettle();
      expect(state.sourceFeature.graphMotionTicker.isActive, false);
      final reduced = state.sourceFeature.graphYaw as double;
      await tester.pump(const Duration(seconds: 5));
      expect(state.sourceFeature.graphYaw, reduced);
      expect(
        tester
            .widget<IconButton>(
              find.byWidgetPredicate(
                (widget) =>
                    widget is IconButton &&
                    widget.tooltip ==
                        'Graph animation is disabled by reduced motion',
              ),
            )
            .onPressed,
        isNull,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      temp.deleteSync(recursive: true);
    },
  );
  testWidgets(
    'changed sources discard stale layout and filtering retains positions',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final temp = Directory.systemTemp.createTempSync(
        'foresight-graph-workflow-',
      );
      addTearDown(() {
        if (temp.existsSync()) temp.deleteSync(recursive: true);
      });
      final store = SourceReadCountingStore('${temp.path}/app.db');
      final a = store.importText('Apollo', 'Launch', 'text/plain', 'fixture:a');
      final b = store.importText(
        'Borealis',
        'Budget',
        'text/plain',
        'fixture:b',
      );
      for (final id in [a, b]) {
        store.state(id, 'indexed');
      }
      final helper = OfflineHelper(
        '${temp.path}/socket',
        '${temp.path}/helper',
      );
      helper.snapshot = control.State(
        pipeline: 'ready',
        model: control.ModelIdentity(modelDigest: 'fixture', dimensions: 3),
      );
      final domain = GraphDomain(store, helper);
      await tester.pumpWidget(
        Foresight(TestDesktopConnection(domain), deviceLoader: () async => []),
      );
      await tester.tap(find.text('Sources'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Graph view'));
      await tester.pump();
      await tester.tap(find.byTooltip('Pause graph animation'));
      await tester.pumpAndSettle();
      expect(domain.requests.length, 1);
      final dynamic state = tester.state(find.byType(Workspace));
      final c = store.importText(
        'Comet',
        'Astronomy',
        'text/plain',
        'fixture:c',
      );
      store.state(c, 'indexed');
      state.update(() {});
      await tester.pumpAndSettle();
      expect(domain.requests.length, 2);
      domain.requests[1].complete({
        a: [1, 0, 0],
        b: [1, 0, 0],
        c: [0, 1, 0],
      });
      for (
        final pollingClock = Stopwatch()..start();
        pollingClock.elapsed < const Duration(seconds: 5) &&
            state.sourceFeature.graphPoints.length != 3;
      ) {
        await tester.runAsync(() => Future<void>(() {}));
        await tester.pump();
      }
      expect(
        state.sourceFeature.graphLayoutError,
        isEmpty,
        reason: 'Layout computation must complete',
      );
      expect(state.sourceFeature.graphPoints.length, 3);
      expect(state.sourceFeature.graphEdges.length, 1);
      expect(
        {
          state.sourceFeature.graphEdges.single.source,
          state.sourceFeature.graphEdges.single.target,
        },
        {a, b},
        reason: 'Unlabelled semantic peers connect; orthogonal Comet does not',
      );
      final preparedEdges = state.sourceFeature.graphEdges;
      // Commit the completed scene before measuring projection-only frames.
      await tester.pumpAndSettle();
      final readyReads = store.sourceReads;
      for (var i = 0; i < 10; i++) {
        state.sourceFeature.graphYaw += .01;
        state.sourceFeature.graphMotionFrames.value++;
        await tester.pump();
      }
      expect(
        store.sourceReads - readyReads,
        0,
        reason:
            'Ready-model projection frames must reuse the source/model snapshot',
      );
      expect(identical(state.sourceFeature.graphEdges, preparedEdges), true);
      final apollo = find.byKey(ValueKey('graph-node-$a'));
      state.update(() {
        state.sourceFeature.graphYaw = 0.0;
        state.sourceFeature.graphPitch = 0.0;
        // Force layout separates identical embeddings; explicitly overlap the
        // fixture to retain the independent equal-depth hit-selection check.
        state.sourceFeature.graphPoints[b] = state.sourceFeature.graphPoints[a];
      });
      await tester.pumpAndSettle();
      final originalPosition = tester.getTopLeft(apollo);
      final initialX =
          state.sourceFeature.graphTransform.value.storage[12] as double;
      final initialY =
          state.sourceFeature.graphTransform.value.storage[13] as double;
      final canvas = find.byKey(const ValueKey('source-graph-canvas'));
      final emptyPoint = tester.getTopLeft(canvas) + const Offset(120, 80);
      final rotating = await tester.startGesture(
        emptyPoint,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump();
      await rotating.moveBy(const Offset(80, 40));
      await tester.pump();
      await rotating.up();
      await tester.pumpAndSettle();
      expect(state.sourceFeature.graphYaw, closeTo(.4, 1e-10));
      expect(state.sourceFeature.graphPitch, closeTo(.2, 1e-10));
      expect(state.sourceFeature.graphMousePointer, isNull);
      expect(tester.getTopLeft(apollo), isNot(originalPosition));
      expect(state.sourceFeature.graphTransform.value.storage[12], initialX);
      expect(find.text('Choose source'), findsNothing);
      final panning = await tester.startGesture(
        emptyPoint,
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await tester.pump();
      await panning.moveBy(const Offset(55, -30));
      await tester.pump();
      await panning.up();
      await tester.pumpAndSettle();
      expect(state.sourceFeature.graphYaw, closeTo(.4, 1e-10));
      expect(
        state.sourceFeature.graphTransform.value.storage[12],
        closeTo(initialX + 55, 1e-10),
      );
      expect(
        state.sourceFeature.graphTransform.value.storage[13],
        closeTo(initialY - 30, 1e-10),
      );
      await tester.tap(find.byTooltip('Fit graph'));
      await tester.pumpAndSettle();
      final panelBounds = tester.getRect(
        find.byKey(const ValueKey('source-graph-canvas')),
      );
      for (final id in [a, b, c]) {
        expect(
          panelBounds.contains(
            tester.getCenter(find.byKey(ValueKey('graph-node-$id'))),
          ),
          true,
        );
      }
      final fittedX = state.sourceFeature.graphTransform.value.storage[12];
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      final modified = await tester.startGesture(
        emptyPoint,
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await tester.pump();
      await modified.moveBy(const Offset(20, 0));
      await tester.pump();
      await modified.up();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(state.sourceFeature.graphYaw, closeTo(.5, 1e-10));
      expect(state.sourceFeature.graphTransform.value.storage[12], fittedX);
      final clamped = await tester.startGesture(
        emptyPoint,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump();
      await clamped.moveBy(const Offset(0, 100000));
      await tester.pump();
      await clamped.cancel();
      await tester.pumpAndSettle();
      expect(
        state.sourceFeature.graphPitch,
        closeTo(1.5707963267948966, 1e-10),
      );
      expect(state.sourceFeature.graphMousePointer, isNull);
      expect(domain.requests.length, 2);
      state.update(() {
        state.sourceFeature.graphYaw = 0.0;
        state.sourceFeature.graphPitch = 0.0;
      });
      await tester.pumpAndSettle();
      final before = tester.getCenter(apollo);
      expect(tester.getCenter(find.byKey(ValueKey('graph-node-$b'))), before);
      await tester.tapAt(
        tester.getCenter(find.byKey(ValueKey('graph-node-$b'))),
      );
      await tester.pumpAndSettle();
      expect(find.text('Choose source'), findsNothing);
      expect(
        state.sourceFeature.graphSelectedDocument,
        a,
        reason: 'Equal-depth hits keep the first candidate',
      );
      expect(find.byKey(const ValueKey('graph-inspector')), findsOneWidget);
      expect(find.text('Apollo · revision 1'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('graph-inspector-close')));
      await tester.pumpAndSettle();
      domain.requests[0].complete({
        a: [-1, 0, 0],
        b: [1, 0, 0],
      });
      await tester.pumpAndSettle();
      expect(state.sourceFeature.graphPoints.length, 3);
      await tester.enterText(find.byType(TextField), 'Apollo');
      await tester.pumpAndSettle();
      expect((tester.getCenter(apollo) - before).distance, closeTo(0, 1e-8));
      expect(find.byKey(ValueKey('graph-node-$b')), findsOneWidget);
      expect(
        (tester
                    .widget<CustomPaint>(
                      find.byKey(ValueKey('graph-node-paint-$b')),
                    )
                    .painter
                as GraphNodePainter)
            .dimmed,
        true,
      );
      expect(domain.requests.length, 2);
      await tester.tapAt(tester.getCenter(apollo));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('graph-inspector')), findsOneWidget);
      expect(state.sourceFeature.graphSelectedDocument, a);
      expect(find.text('Apollo · revision 1'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      temp.deleteSync(recursive: true);
    },
  );
}
