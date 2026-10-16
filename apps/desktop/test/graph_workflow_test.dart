import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foresight/domain.dart';
import 'package:foresight/main.dart';
import 'package:foresight/store.dart';
import 'package:foresight/graph_rendering.dart';
import 'package:foresight/generated/helper_control.pb.dart' as control;
import 'meeting_setup_test.dart' show OfflineHelper;

class SourceReadCountingStore extends Store {
  int sourceReads = 0;
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
      Foresight(Domain(store, helper), deviceLoader: () async => []),
    );
    await tester.tap(find.text('Sources'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Graph view'));
    await tester.pump();
    await tester.pump();
    final dynamic state = tester.state(find.byType(Workspace));
    final before = store.sourceReads;
    final frameBefore = state.graphMotionFrames.value as int;
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(state.graphMotionFrames.value - frameBefore, 10);
    expect(
      store.sourceReads - before,
      0,
      reason: 'Projection-only frames must reuse the source snapshot',
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
      final store = Store('${temp.path}/app.db');
      store.importText('Apollo', 'Launch', 'text/plain', 'fixture:a');
      store.importText('Borealis', 'Budget', 'text/plain', 'fixture:b');
      final helper = OfflineHelper(
        '${temp.path}/socket',
        '${temp.path}/helper',
      );
      final domain = Domain(store, helper);
      await tester.pumpWidget(Foresight(domain, deviceLoader: () async => []));
      await tester.tap(find.text('Sources'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Graph view'));
      await tester.pump();
      await tester.pump();
      final dynamic state = tester.state(find.byType(Workspace));
      expect(state.graphMotionTicker.isActive, true);
      final initial = state.graphYaw as double;
      await tester.pump(const Duration(seconds: 1));
      expect(state.graphYaw, greaterThan(initial));
      await tester.tap(find.byTooltip('Pause graph animation'));
      await tester.pumpAndSettle();
      final paused = state.graphYaw as double;
      final sourcePaused = domain.sourcesPaused;
      await tester.pump(const Duration(seconds: 5));
      expect(state.graphYaw, paused);
      expect(state.graphMotionTicker.isActive, false);
      expect(domain.sourcesPaused, sourcePaused);
      await tester.tap(find.byTooltip('Resume graph animation'));
      await tester.pump();
      await tester.pump();
      expect(state.graphYaw, paused);
      await tester.pump(const Duration(seconds: 1));
      expect(state.graphYaw - paused, closeTo(.025, 1e-6));
      expect(
        state.graphPitch,
        closeTo(.4 + .08 * math.sin(state.graphYaw * .4), 1e-10),
      );
      final canvas = find.byKey(const ValueKey('source-graph-canvas'));
      final drag = await tester.startGesture(
        tester.getTopLeft(canvas) + const Offset(120, 80),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump();
      await drag.moveBy(const Offset(40, 20));
      await tester.pump();
      final manualYaw = state.graphYaw as double;
      final manualPitch = state.graphPitch as double;
      await tester.pump(const Duration(seconds: 3));
      expect(state.graphYaw, manualYaw);
      expect(state.graphMotionTicker.isActive, false);
      await drag.up();
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(state.graphYaw, greaterThan(manualYaw));
      expect(state.graphPitch, manualPitch);
      await tester.tap(find.text('Meetings').first);
      await tester.pumpAndSettle();
      final hidden = state.graphYaw as double;
      await tester.pump(const Duration(seconds: 20));
      expect(state.graphYaw, hidden);
      expect(state.graphMotionTicker.isActive, false);
      await tester.tap(find.text('Sources'));
      await tester.pump();
      await tester.pump();
      expect(state.graphYaw, hidden);
      await tester.pump(const Duration(seconds: 1));
      expect(state.graphYaw - hidden, closeTo(.025, 1e-6));
      await tester.enterText(find.byType(TextField), 'missing source');
      await tester.pump();
      await tester.pump();
      expect(state.graphMotionTicker.isActive, true);
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
      expect(state.graphMotionTicker.isActive, false);
      final reduced = state.graphYaw as double;
      await tester.pump(const Duration(seconds: 5));
      expect(state.graphYaw, reduced);
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
      await tester.pumpWidget(Foresight(domain, deviceLoader: () async => []));
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
      for (var i = 0; i < 100 && state.graphPoints.length != 3; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }
      expect(
        state.graphLayoutError,
        isEmpty,
        reason: 'Layout computation must complete',
      );
      expect(state.graphPoints.length, 3);
      expect(state.graphEdges.length, 1);
      expect(
        {state.graphEdges.single.source, state.graphEdges.single.target},
        {a, b},
        reason: 'Unlabelled semantic peers connect; orthogonal Comet does not',
      );
      final preparedEdges = state.graphEdges;
      // Commit the completed scene before measuring projection-only frames.
      await tester.pumpAndSettle();
      final readyReads = store.sourceReads;
      for (var i = 0; i < 10; i++) {
        state.graphYaw += .01;
        state.graphMotionFrames.value++;
        await tester.pump();
      }
      expect(
        store.sourceReads - readyReads,
        0,
        reason:
            'Ready-model projection frames must reuse the source/model snapshot',
      );
      expect(identical(state.graphEdges, preparedEdges), true);
      final apollo = find.byKey(ValueKey('graph-node-$a'));
      state.update(() {
        state.graphYaw = 0.0;
        state.graphPitch = 0.0;
        // Force layout separates identical embeddings; explicitly overlap the
        // fixture to retain the independent equal-depth hit-selection check.
        state.graphPoints[b] = state.graphPoints[a];
      });
      await tester.pumpAndSettle();
      final originalPosition = tester.getTopLeft(apollo);
      final initialX = state.graphTransform.value.storage[12] as double;
      final initialY = state.graphTransform.value.storage[13] as double;
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
      expect(state.graphYaw, closeTo(.4, 1e-10));
      expect(state.graphPitch, closeTo(.2, 1e-10));
      expect(state.graphMousePointer, isNull);
      expect(tester.getTopLeft(apollo), isNot(originalPosition));
      expect(state.graphTransform.value.storage[12], initialX);
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
      expect(state.graphYaw, closeTo(.4, 1e-10));
      expect(
        state.graphTransform.value.storage[12],
        closeTo(initialX + 55, 1e-10),
      );
      expect(
        state.graphTransform.value.storage[13],
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
      final fittedX = state.graphTransform.value.storage[12];
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
      expect(state.graphYaw, closeTo(.5, 1e-10));
      expect(state.graphTransform.value.storage[12], fittedX);
      final clamped = await tester.startGesture(
        emptyPoint,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump();
      await clamped.moveBy(const Offset(0, 100000));
      await tester.pump();
      await clamped.cancel();
      await tester.pumpAndSettle();
      expect(state.graphPitch, closeTo(1.5707963267948966, 1e-10));
      expect(state.graphMousePointer, isNull);
      expect(domain.requests.length, 2);
      state.update(() {
        state.graphYaw = 0.0;
        state.graphPitch = 0.0;
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
        state.graphSelectedDocument,
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
      expect(state.graphPoints.length, 3);
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
      expect(state.graphSelectedDocument, a);
      expect(find.text('Apollo · revision 1'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      temp.deleteSync(recursive: true);
    },
  );
}
