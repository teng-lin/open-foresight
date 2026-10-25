import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foresight_core/desktop.dart'
    show MeetingArtifact, MeetingQuestion, MeetingTask;
import 'package:open_foresight/features/meetings/ai_dialogs.dart';
import 'package:open_foresight/features/meetings/ai_panels.dart';
import 'package:open_foresight/features/meetings/assistant_widgets.dart';
import 'package:open_foresight/features/meetings/enhanced_notes_view.dart';
import 'package:open_foresight/features/meetings/collection_view.dart';

Future<void> _open(Uri _) async {}
Widget _surface(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  testWidgets('collection layout preserves narrow preview and lazy list', (
    tester,
  ) async {
    var lists = 0, headings = 0;
    Widget layout(double width) => _surface(
      Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: width,
          child: MeetingCollectionLayout(
            previewBuilder: (_) => const Text('Preview'),
            headingBuilder: (_) {
              headings++;
              return const Text('Heading');
            },
            listBuilder: (_) {
              lists++;
              return const Text('List');
            },
          ),
        ),
      ),
    );
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(layout(899));
    expect(find.text('Preview'), findsOneWidget);
    expect([lists, headings], [0, 0]);
    await tester.pumpWidget(layout(900));
    expect(find.text('Preview'), findsOneWidget);
    expect(find.text('List'), findsOneWidget);
    expect([lists, headings], [1, 1]);
  });

  testWidgets(
    'enhanced pane uses callbacks and disables repeated cancellation',
    (tester) async {
      var cancellations = 0, hides = 0, edits = 0, copies = 0, enhancements = 0;
      Widget pane(bool cancelling) => MeetingEnhancedPane(
        preview: false,
        enhancedText: 'Partial notes',
        hasArtifact: true,
        hasProgress: true,
        active: true,
        cancelRequested: cancelling,
        degraded: true,
        status: 'Working',
        hasNotes: true,
        body: const Text('Partial notes'),
        onCancel: () => cancellations++,
        onHide: () => hides++,
        onEdit: () => edits++,
        onCopy: () => copies++,
        onEnhance: () => enhancements++,
      );
      await tester.pumpWidget(_surface(pane(false)));
      expect(find.textContaining('Some notes were preserved'), findsOneWidget);
      await tester.tap(find.text('Cancel enhancement'));
      await tester.tap(find.byTooltip('Hide enhanced notes'));
      await tester.tap(find.byTooltip('Edit enhanced notes'));
      await tester.tap(find.byTooltip('Copy enhanced notes'));
      await tester.tap(find.text('Enhance notes'));
      expect(
        [cancellations, hides, edits, copies, enhancements],
        [1, 1, 1, 1, 1],
      );
      await tester.pumpWidget(_surface(pane(true)));
      expect(
        tester
            .widget<TextButton>(
              find.byKey(const ValueKey('cancel-note-enhancement')),
            )
            .onPressed,
        isNull,
      );
      expect(find.text('Cancelling…'), findsOneWidget);
    },
  );

  testWidgets(
    'questions snapshot retains queue and delegates settings and retry',
    (tester) async {
      var automatic = false, retries = 0;
      String? asked;
      final manual = ['Who owns the release?'];
      final panel = MeetingQuestionsPanel(
        automatic: true,
        detectorConfigured: false,
        queuedAnswers: 2,
        oldestQueueAgeMs: 2500,
        waiting: true,
        detectionError: 'Detection failed',
        questions: const [],
        manual: manual,
        canAnswer: true,
        onAutomaticChanged: (value) => automatic = value,
        onRetryDetection: () => retries++,
        onQuestion: (value) => asked = value,
      );
      manual.clear();
      await tester.pumpWidget(_surface(panel));
      expect(find.text('2 queued · oldest waiting 2s'), findsOneWidget);
      expect(
        find.textContaining('Waiting for the local model'),
        findsOneWidget,
      );
      await tester.tap(find.text('Retry detection'));
      await tester.tap(find.byTooltip('Answer this question'));
      tester.widget<SwitchListTile>(find.byType(SwitchListTile)).onChanged!(
        true,
      );
      expect(automatic, isTrue);
      expect(retries, 1);
      expect(asked, 'Who owns the release?');
    },
  );

  testWidgets(
    'automatic answer displays citations and delegates copy and retry',
    (tester) async {
      var retries = 0;
      String? copied, cited;
      final item = MeetingQuestion.fromRow({
        'id': 1,
        'meeting_id': 2,
        'question': 'Who?',
        'state': 'failed',
        'body': 'Alice',
        'error': 'Retry needed',
        'citations':
            '[{"kind":"document","document_id":"doc","revision":4,"citation":"S1","excerpt":"Alice"}]',
      });
      await tester.pumpWidget(
        _surface(
          MeetingAutomaticQuestion(
            item: item,
            fontSize: 16,
            openLink: _open,
            onCopy: (value) => copied = value,
            onCite: (value) => cited = value.documentId,
            onRetry: () => retries++,
          ),
        ),
      );
      expect(find.text('Automatic · Could not answer'), findsOneWidget);
      await tester.tap(find.byTooltip('Copy automatic answer'));
      await tester.tap(find.text('[S1] source revision 4'));
      await tester.tap(find.text('Try again'));
      expect(copied, 'Alice');
      expect(cited, 'doc');
      expect(retries, 1);
    },
  );

  testWidgets(
    'action snapshot delegates completion and edit without persistence',
    (tester) async {
      bool? completed;
      int? edited;
      String? copied;
      final task = MeetingTask.fromRow({
        'id': 3,
        'meeting_id': 2,
        'task': 'Ship release',
        'status': 'open',
        'stale': 1,
        'manual': 1,
        'evidence': '[{"id":"segment-1","quote":"We will ship"}]',
      });
      final tasks = [task];
      final versions = [
        MeetingArtifact.fromRow({'generated': 'Action summary'}),
      ];
      final panel = MeetingActionsPanel(
        tasks: tasks,
        versions: versions,
        progress: const SizedBox(),
        openLink: _open,
        onCopy: (value) => copied = value,
        onComplete: (value, checked) {
          expect(value.id, 3);
          completed = checked;
        },
        onEdit: (value) => edited = value.id,
      );
      tasks.clear();
      versions.clear();
      await tester.pumpWidget(_surface(panel));
      expect(find.text('Your edits are preserved'), findsOneWidget);
      expect(
        find.textContaining('Not found in the latest extraction'),
        findsOneWidget,
      );
      await tester.tap(find.byType(Checkbox));
      await tester.tap(find.byTooltip('Edit task'));
      await tester.tap(find.byTooltip('Copy Action items'));
      await tester.tap(find.text('Supporting evidence'));
      await tester.pumpAndSettle();
      expect(find.text('We will ship'), findsOneWidget);
      expect(completed, isTrue);
      expect(edited, 3);
      expect(copied, 'Action summary');
    },
  );

  testWidgets('preparation keeps warnings and disables edit during preview', (
    tester,
  ) async {
    final artifact = MeetingArtifact.fromRow({
      'generated': 'Saved brief',
      'manifest': '{"degraded":true,"reduction_clipped":true}',
    });
    var edits = 0;
    await tester.pumpWidget(
      _surface(
        MeetingPreparationPanel(
          versions: [artifact],
          active: true,
          preview: 'Streaming brief',
          progress: const SizedBox(),
          openLink: _open,
          onCopy: (_) {},
          onEdit: (_) => edits++,
        ),
      ),
    );
    expect(find.textContaining('shortened excerpts'), findsOneWidget);
    expect(find.textContaining('Some documents could not'), findsOneWidget);
    expect(find.textContaining('Streaming brief'), findsOneWidget);
    expect(
      tester
          .widget<TextButton>(
            find.widgetWithText(TextButton, 'Edit preparation'),
          )
          .onPressed,
      isNull,
    );
    expect(edits, 0);
  });

  testWidgets('task editor delegates actions and leaves controllers owned', (
    tester,
  ) async {
    final text = TextEditingController(text: 'Old task');
    final owner = TextEditingController(), due = TextEditingController();
    addTearDown(text.dispose);
    addTearDown(owner.dispose);
    addTearDown(due.dispose);
    var saves = 0, cancels = 0;
    await tester.pumpWidget(
      _surface(
        MeetingTaskEditor(
          text: text,
          owner: owner,
          due: due,
          onSave: () => saves++,
          onCancel: () => cancels++,
        ),
      ),
    );
    await tester.enterText(find.byType(TextField).first, 'Updated task');
    await tester.tap(find.text('Save'));
    await tester.tap(find.text('Cancel'));
    expect(text.text, 'Updated task');
    expect(saves, 1);
    expect(cancels, 1);
    await tester.pumpWidget(_surface(const SizedBox()));
    text.text = 'Still owned';
    expect(text.text, 'Still owned');
  });

  testWidgets(
    'source selection snapshots values and preserves 100-source limit',
    (tester) async {
      final sources = [const MeetingSourceChoice('doc', 'Local document')];
      final selected = {'doc'};
      String? changed;
      bool? checked;
      var confirmed = 0, cancelled = 0;
      final dialog = MeetingSourceSelection(
        sources: sources,
        selected: selected,
        onSelected: (id, value) {
          changed = id;
          checked = value;
        },
        onConfirm: () => confirmed++,
        onCancel: () => cancelled++,
      );
      sources.clear();
      selected.clear();
      await tester.pumpWidget(_surface(dialog));
      expect(
        tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value,
        isTrue,
      );
      await tester.tap(find.text('Local document'));
      await tester.tap(find.text('Use selected documents'));
      await tester.tap(find.text('Cancel'));
      expect(changed, 'doc');
      expect(checked, isFalse);
      expect(confirmed, 1);
      expect(cancelled, 1);
      for (final count in [0, 100, 101]) {
        await tester.pumpWidget(
          _surface(
            MeetingSourceSelection(
              sources: const [],
              selected: {for (var i = 0; i < count; i++) '$i'},
              onSelected: (_, _) {},
              onCancel: () {},
              onConfirm: () {},
            ),
          ),
        );
        expect(
          tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
          count == 100 ? isNotNull : isNull,
        );
      }
    },
  );
}
