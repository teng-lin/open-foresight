import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foresight_core/foresight_core.dart';
import 'package:foresight_core/src/application.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:open_foresight/main.dart';
import 'package:open_foresight/generated_content.dart';
import 'desktop_connection_fixture.dart';
import 'meeting_setup_test.dart' show OfflineHelper;
import 'pump_until.dart';

class SummaryWidgetRuntime extends NativeRuntime {
  SummaryWidgetRuntime()
    : super(Platform.isMacOS ? '/usr/lib/libSystem.B.dylib' : 'libc.so.6');
  final entered = Completer<void>(), release = Completer<void>();
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
    entered.complete();
    yield {'type': 'preview', 'text': '# Overview\nDraft launch plan'};
    await release.future;
    yield {'type': 'done', 'status': 'cancelled'};
  }

  @override
  bool cancel({String? requestId}) {
    if (!release.isCompleted) release.complete();
    return true;
  }
}

void main() {
  testWidgets(
    'summary progress and streamed preview cancel back to accepted history',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 850);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final directory = createTestTempDirectorySync('summary-widget-');
      addTearDown(() => directory.deleteSync(recursive: true));
      final store = Store('${directory.path}/app.db');
      final id = store.meeting('Launch');
      store.transcript(id, 'Alice launches Friday.', true, 0, 1, 'microphone');
      store.artifact(
        id,
        'summary',
        '# Overview\nAccepted brief',
        'fixture',
        manifest: {'reduction_clipped': true},
      );
      final helper = OfflineHelper(
        '${directory.path}/sock',
        '${directory.path}/helper',
      );
      final domain = Domain(store, helper);
      final runtime = SummaryWidgetRuntime();
      await tester.pumpWidget(
        Foresight(TestDesktopConnection(domain), deviceLoader: () async => []),
      );
      final dynamic state = tester.state(find.byType(Workspace));
      state.update(() {
        state.meetingFeature.meetingId = id;
        state.meetingFeature.meetingPanel = 'Summary';
      });
      await tester.pumpAndSettle();
      expect(
        find.text(
          'This summary used shortened excerpts. Review the transcript for full context.',
        ),
        findsOneWidget,
      );
      domain.generator = runtime;
      late Future<void> work;
      await tester.runAsync(() async {
        work = domain.application.generateSummary(id).catchError((Object _) {});
      });
      await pumpUntil(tester, () => runtime.entered.isCompleted);
      // Service events coalesce through a 100 ms UI timer on the fake clock.
      await tester.pump(const Duration(milliseconds: 100));
      await pumpUntil(
        tester,
        () => find.byTooltip('Cancel summary').evaluate().isNotEmpty,
      );
      expect(find.byType(LinearProgressIndicator), findsWidgets);
      await pumpUntil(
        tester,
        () => find
            .byWidgetPredicate(
              (w) =>
                  w is GeneratedContent &&
                  w.markdown.contains('Draft launch plan'),
            )
            .evaluate()
            .isNotEmpty,
      );
      await tester.tap(find.byTooltip('Cancel summary'));
      await tester.runAsync(() async => await work);
      await tester.pumpAndSettle();
      expect(find.byTooltip('Cancel summary'), findsNothing);
      expect(find.text('Accepted brief', findRichText: true), findsOneWidget);
      expect(store.meetingArtifacts(id, 'summary'), hasLength(1));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
