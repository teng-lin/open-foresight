import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_foresight/gemma_download.dart';
import 'package:open_foresight/gemma_setup_view.dart';
import 'package:open_foresight/model_terms_dialog.dart';
import 'package:open_foresight/speech_models.dart';
import 'package:open_foresight/store.dart';

void main() {
  for (final model in [
    gemmaModels.last,
    embeddingGemmaModel,
    speechModels.first,
  ]) {
    testWidgets(
      '${model.name} terms require consent before first download and are remembered',
      (tester) async {
        final root = Directory.systemTemp.createTempSync('model-terms-');
        final store = Store('${root.path}/app.db');
        bool? accepted;
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) => TextButton(
                onPressed: () async =>
                    accepted = await confirmModelTerms(context, store, model),
                child: const Text('Download'),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Download'));
        await tester.pumpAndSettle();
        expect(find.text('${model.name} terms'), findsOneWidget);
        expect(accepted, isNull);
        expect(find.byType(SelectableText), findsOneWidget);
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(accepted, false);
        expect(
          store.preference('modelTerms.${model.repository}.${model.revision}'),
          isEmpty,
        );
        await tester.tap(find.text('Download'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Accept and download'));
        await tester.pumpAndSettle();
        expect(accepted, true);
        await tester.tap(find.text('Download'));
        await tester.pumpAndSettle();
        expect(find.text('${model.name} terms'), findsNothing);
        await tester.pumpWidget(const SizedBox());
        store.close();
        root.deleteSync(recursive: true);
      },
    );
  }

  testWidgets('unknown device memory disables every generation download', (
    tester,
  ) async {
    final root = Directory.systemTemp.createTempSync('model-unknown-memory-');
    final store = Store('${root.path}/app.db');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: GemmaSetupDialog(
            store: store,
            directory: root,
            library: '',
            runner: '/usr/bin/true',
            memoryGb: 0,
            installed: (_, _) => fail('Must not install with unknown RAM'),
            localSetup: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widgetList<RadioListTile<GemmaModel>>(
            find.byType(RadioListTile<GemmaModel>),
          )
          .every((tile) => tile.enabled == false),
      true,
    );
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );
    expect(
      find.textContaining('memory could not be determined'),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox());
    store.close();
    root.deleteSync(recursive: true);
  });
}
