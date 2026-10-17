import 'desktop_connection_fixture.dart';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_foresight/domain.dart';
import 'package:open_foresight/generated_content.dart';
import 'package:open_foresight/main.dart';
import 'package:open_foresight/store.dart';
import 'meeting_setup_test.dart' show OfflineHelper;

void main() {
  const markdown = '''# Review summary

**Mira** owns the *draft*. See [S1]. 中文 notes.

- Send the draft
- Review on Tuesday

| Owner | Action |
| --- | --- |
| Mira | Draft |

> Preserve the original wording.

`local_model` stays local.
''';

  testWidgets(
    'renders headings, inline styles, lists and tables at narrow widths',
    (tester) async {
      final fonts = FontLoader('GoogleSans')
        ..addFont(rootBundle.load('assets/fonts/GoogleSans-Regular.ttf'));
      await fonts.load();
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      for (final width in [400.0, 1000.0]) {
        tester.view.physicalSize = Size(width, 850);
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(fontFamily: 'GoogleSans'),
            home: Scaffold(
              body: RepaintBoundary(
                key: ValueKey('rich-content-capture'),
                child: ColoredBox(
                  color: Colors.white,
                  child: SingleChildScrollView(
                    padding: EdgeInsets.all(20),
                    child: GeneratedContent(markdown),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byType(SelectionArea), findsOneWidget);
        expect(find.byType(Table), findsOneWidget);
        expect(find.text('Review summary', findRichText: true), findsOneWidget);
        expect(find.text('Send the draft', findRichText: true), findsOneWidget);
        final spans = tester.widgetList<RichText>(find.byType(RichText)).expand(
          (widget) {
            final result = <InlineSpan>[];
            widget.text.visitChildren((span) {
              result.add(span);
              return true;
            });
            return result;
          },
        ).whereType<TextSpan>();
        expect(
          spans.any(
            (s) => s.text == 'Mira' && s.style?.fontWeight == FontWeight.bold,
          ),
          isTrue,
        );
        expect(
          spans.any(
            (s) => s.text == 'draft' && s.style?.fontStyle == FontStyle.italic,
          ),
          isTrue,
        );
        expect(tester.takeException(), isNull);
      }
      final capture = Platform.environment['FORESIGHT_RICH_PREVIEW_CAPTURE'];
      if (capture != null) {
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(const ValueKey('rich-content-capture')),
        );
        await tester.runAsync(() async {
          final image = await boundary.toImage();
          final png = await image.toByteData(format: ui.ImageByteFormat.png);
          final file = File(capture);
          await file.parent.create(recursive: true);
          await file.writeAsBytes(png!.buffer.asUint8List());
          image.dispose();
        });
      }
    },
  );

  testWidgets(
    'images remain local placeholders and only web links open on a tap',
    (tester) async {
      final opened = <Uri>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: GeneratedContent(
              '[Safe link](https://example.com/notes)\n\n![Remote image](https://example.com/tracker.png)\n\n![Local image](file:///private/secret.png)',
              openLink: (uri) async => opened.add(uri),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(opened, isEmpty);
      expect(find.byType(Image), findsNothing);
      expect(find.text('Remote image'), findsOneWidget);
      expect(find.text('Local image'), findsOneWidget);
      final body = tester.widget<MarkdownBody>(find.byType(MarkdownBody));
      for (final link in [
        'file:///private/secret',
        'javascript:alert(1)',
        'data:text/plain,test',
        'relative/path',
      ]) {
        body.onTapLink!('unsafe', link, '');
        await tester.pump();
      }
      expect(opened, isEmpty);
      await tester.tap(find.text('Safe link', findRichText: true));
      await tester.pumpAndSettle();
      expect(opened, [Uri.parse('https://example.com/notes')]);
    },
  );

  testWidgets(
    'meeting summary displays edits, copies exact Markdown and preserves originals',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 850);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final directory = Directory.systemTemp.createTempSync('rich-meeting-');
      final store = Store('${directory.path}/app.db');
      final id = store.meeting('Rich preview fixture');
      store.artifact(id, 'summary', 'Original generated summary', 'fixture');
      store.db.execute('UPDATE artifacts SET edited=? WHERE meeting_id=?', [
        markdown,
        id,
      ]);
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData')
            copied = (call.arguments as Map)['text'] as String;
          return null;
        },
      );
      try {
        await tester.pumpWidget(
          Foresight(
            TestDesktopConnection(
              Domain(
                store,
                OfflineHelper(
                  '${directory.path}/socket',
                  '${directory.path}/helper',
                ),
              ),
            ),
            deviceLoader: () async => [],
          ),
        );
        final dynamic state = tester.state(find.byType(Workspace));
        state.update(() {
          state.meetingFeature.meetingId = id;
          state.meetingFeature.meetingPanel = 'Summary';
        });
        await tester.pumpAndSettle();
        expect(find.text('Review summary', findRichText: true), findsOneWidget);
        await tester.tap(find.byTooltip('Copy Summary'));
        await tester.pump();
        expect(copied, markdown);
        expect(
          store.rows('SELECT generated,edited FROM artifacts').single,
          containsPair('generated', 'Original generated summary'),
        );
        expect(
          store.rows('SELECT generated,edited FROM artifacts').single,
          containsPair('edited', markdown),
        );
        expect(find.byTooltip('Edit Summary'), findsOneWidget);
        await tester.tap(find.byTooltip('Edit Summary'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.byType(TextField),
          ),
          '## Edited preview\n\n**Saved**',
        );
        await tester.tap(find.text('Save edit'));
        await tester.pumpAndSettle();
        expect(find.text('Edited preview', findRichText: true), findsOneWidget);
        await tester.tap(find.byTooltip('Copy Summary'));
        await tester.pump();
        expect(copied, '## Edited preview\n\n**Saved**');
        expect(
          store.rows('SELECT generated FROM artifacts').single['generated'],
          'Original generated summary',
        );
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        );
        directory.deleteSync(recursive: true);
      }
    },
  );
}
