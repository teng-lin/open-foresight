import 'desktop_connection_fixture.dart';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_foresight/domain.dart';
import 'package:open_foresight/main.dart';
import 'package:open_foresight/generated_content.dart';
import 'package:open_foresight/store.dart';

import 'meeting_setup_test.dart' show OfflineHelper;

void main() {
  testWidgets('meeting list, preview and detail share visual roles and scale', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final fonts = FontLoader('GoogleSans');
    for (final weight in ['Regular', 'Medium', 'Bold']) {
      fonts.addFont(rootBundle.load('assets/fonts/GoogleSans-$weight.ttf'));
    }
    await fonts.load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    final directory = Directory.systemTemp.createTempSync('meeting-visual-');
    final store = Store('${directory.path}/app.db');
    final id = store.meeting('Product review');
    store.meeting('Planning session');
    store.artifact(
      id,
      'enhanced_notes',
      '## Decisions\n\nKeep the review focused on customer feedback.\n\n- Mira will send the revised draft on Tuesday.\n- Review the launch checklist together.',
      'fixture',
    );
    store.artifact(
      id,
      'summary',
      'The team agreed to review the revised draft on Tuesday.',
      'fixture',
    );
    final domain = Domain(
      store,
      OfflineHelper('${directory.path}/socket', '${directory.path}/helper'),
    );
    final captureKey = GlobalKey();
    Future<void> capture(String name) async {
      final path = Platform.environment['FORESIGHT_MEETING_VISUALS'];
      if (path == null) return;
      final boundary =
          captureKey.currentContext!.findRenderObject()
              as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final image = await boundary.toImage();
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        await Directory(path).create(recursive: true);
        await File('$path/$name.png').writeAsBytes(png!.buffer.asUint8List());
        image.dispose();
      });
    }

    try {
      await tester.pumpWidget(
        RepaintBoundary(
          key: captureKey,
          child: Foresight(
            TestDesktopConnection(domain),
            deviceLoader: () async => [],
          ),
        ),
      );
      await tester.pumpAndSettle();
      await capture('01-list');
      await tester.tap(find.text('Product review'));
      await tester.pumpAndSettle();
      final previewTitle = tester.widget<Text>(
        find.text('Product review').last,
      );
      final previewEditor = tester.widget<TextField>(
        find.byKey(const ValueKey('meeting-notes-editor')),
      );
      final previewControl = DefaultTextStyle.of(
        tester.element(find.widgetWithText(TextButton, 'Notes').first),
      );
      // Both contexts must use the same hierarchy, rather than growing text
      // when a meeting is expanded or falling back to Material's role sizes.
      expect(previewTitle.style!.fontSize, 20);
      expect(previewEditor.style!.fontSize, 15);
      expect(previewControl.style.fontSize, lessThan(20));
      expect(
        tester.getTopLeft(find.textContaining('Enter your notes here.')).dy,
        greaterThanOrEqualTo(
          tester
              .getTopLeft(find.byKey(const ValueKey('meeting-notes-editor')))
              .dy,
        ),
      );
      await capture('02-preview-empty');
      await tester.enterText(
        find.byKey(const ValueKey('meeting-notes-editor')),
        'Product review\n\nReview the customer feedback and agree on next steps.\n\n• Mira: revised draft on Tuesday\n• Team: confirm the launch checklist',
      );
      await tester.pump(const Duration(seconds: 1));
      await capture('02-preview');
      await tester.tap(find.byTooltip('Expand meeting'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<Text>(find.text('Product review')).style,
        previewTitle.style,
      );
      expect(
        tester
            .widget<TextField>(
              find.byKey(const ValueKey('meeting-notes-editor')),
            )
            .style,
        previewEditor.style,
      );
      expect(find.text('Live enhanced notes'), findsOneWidget);
      expect(tester.takeException(), isNull);
      for (final tab in ['Chat', 'Live Q&A', 'Summary']) {
        final label = find.widgetWithText(TextButton, tab).first;
        final paragraph = tester.renderObject<RenderParagraph>(
          find.descendant(of: label, matching: find.text(tab)),
        );
        expect(paragraph.didExceedMaxLines, isFalse);
      }
      await capture('03-detail');
      final dynamic state = tester.state(find.byType(Workspace));
      state.update(() {
        state.chatFeature.answerFontSize = 21.0;
        state.meetingFeature.meetingPanel = 'Summary';
      });
      await tester.pumpAndSettle();
      expect(
        tester
            .widgetList<GeneratedContent>(find.byType(GeneratedContent))
            .where((content) => content.markdown.contains('The team agreed'))
            .single
            .fontSize,
        21,
      );
      state.update(() => state.meetingFeature.meetingPanel = 'Chat');
      await tester.pumpAndSettle();

      tester.view.physicalSize = const Size(700, 800);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await capture('04-detail-narrow');
      await tester.tap(find.byTooltip('All meetings'));
      await tester.pumpAndSettle();
      await capture('05-preview-narrow');
      expect(tester.takeException(), isNull);

      // Host accessibility scaling must still enlarge the effective text.
      tester.platformDispatcher.textScaleFactorTestValue = 1.4;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpAndSettle();
      final editorContext = tester.element(
        find.byKey(const ValueKey('meeting-notes-editor')),
      );
      expect(MediaQuery.textScalerOf(editorContext).scale(15), 21);
      expect(tester.takeException(), isNull);
      await capture('06-preview-scaled');
      await tester.enterText(
        find.byKey(const ValueKey('meeting-notes-editor')),
        '',
      );
      await tester.pump();
      expect(
        tester.getTopLeft(find.textContaining('Enter your notes here.')).dy,
        greaterThanOrEqualTo(
          tester
              .getTopLeft(find.byKey(const ValueKey('meeting-notes-editor')))
              .dy,
        ),
      );
      await capture('07-preview-scaled-empty');
      expect(
        store.rows('SELECT title FROM meetings WHERE id=?', [
          id,
        ]).single['title'],
        'Product review',
      );
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      directory.deleteSync(recursive: true);
    }
  });
}
