import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foresight_core/foresight_core.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:open_foresight/main.dart';
import 'desktop_connection_fixture.dart';
import 'meeting_setup_test.dart' show OfflineHelper;
import 'pump_until.dart';

class _WorkflowViewRuntime extends NativeRuntime {
  _WorkflowViewRuntime()
    : super(Platform.isMacOS ? '/usr/lib/libSystem.B.dylib' : 'libc.so.6');
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
    final evidence =
        ((jsonDecode(prompt) as Map)['evidence'] as List).first as Map;
    yield {
      'type': 'delta',
      'text': jsonEncode({
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
      }),
    };
    yield {'type': 'done', 'status': 'completed'};
  }

  @override
  bool cancel({String? requestId}) => true;
}

class _WorkflowViewDomain extends Domain {
  _WorkflowViewDomain(super.store, super.helper);
  @override
  Future<void> index(String id, {bool Function()? current}) async {
    store.state(id, 'indexed');
  }
}

void main() {
  testWidgets(
    'task completion and local-document preparation use service operations',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final root = createTestTempDirectorySync('ai-views-');
      final store = Store('${root.path}/app.db');
      final meeting = store.meeting('Launch');
      store.transcript(
        meeting,
        'Alice will ship Friday.',
        true,
        0,
        1,
        'microphone',
      );
      store.importText(
        'Design attachment',
        'Launch checklist and review agenda.',
        'text/plain',
        'fixture',
      );
      final helper = OfflineHelper('${root.path}/sock', '${root.path}/helper');
      final domain = _WorkflowViewDomain(store, helper);
      addTearDown(() {
        domain.close();
        domain.generator?.close();
        store.close();
        if (root.existsSync()) root.deleteSync(recursive: true);
      });
      await tester.pumpWidget(
        Foresight(TestDesktopConnection(domain), deviceLoader: () async => []),
      );
      final dynamic state = tester.state(find.byType(Workspace));
      state.update(() {
        state.meetingFeature.meetingId = meeting;
        state.meetingFeature.meetingPanel = 'Action items';
      });
      await tester.pumpAndSettle();
      domain.generator = _WorkflowViewRuntime();
      await tester.tap(find.byTooltip('Generate Action items'));
      await tester.pump(const Duration(milliseconds: 100));
      expect(state.error, isEmpty);
      await pumpUntil(tester, () => store.meetingTasks(meeting).isNotEmpty);
      await tester.pumpAndSettle();
      expect(find.text('Ship release'), findsOneWidget);
      await tester.tap(find.byType(Checkbox).first);
      await pumpUntil(
        tester,
        () => store.meetingTasks(meeting).single['status'] == 'completed',
      );
      await tester.pumpAndSettle();
      expect(find.text('Your edits are preserved'), findsOneWidget);
      state.update(() {
        state.meetingFeature.meetingPanel = 'Preparation';
      });
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Prepare from local documents'));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(
        find.widgetWithText(CheckboxListTile, 'Design attachment'),
      );
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('Use selected documents'));
      await pumpUntil(
        tester,
        () => store.meetingArtifacts(meeting, 'preparation').isNotEmpty,
      );
      await tester.pumpAndSettle();
      expect(
        find.textContaining(
          'Launch checklist and review agenda.',
          findRichText: true,
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      var helperClosed = false;
      final closing = helper.close().then((_) => helperClosed = true);
      await pumpUntil(tester, () => helperClosed);
      await closing;
    },
  );
}
