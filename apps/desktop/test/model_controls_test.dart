import 'pump_until.dart';
import 'package:open_foresight/shell/workspace_tab.dart';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import '../test_support/core_fixture.dart';
import 'package:open_foresight/features/settings/gemma_setup_view.dart';

import 'package:open_foresight/features/settings/speech_setup_view.dart';
import 'controller_fixture.dart';

void main() {
  testWidgets(
    'model setup routes service commands and ignores cancelled embedding adoption',
    (tester) async {
      final f = await ControllerFixture.mount(tester);
      final settings = f.shell.settingsFeature;
      final setup = settings.gemmaSetup(firstRun: true) as GemmaSetupDialog;
      final asset = File('${f.root.path}/embedding.litertlm');
      await setup.installEmbedding!(asset, () => false);
      expect(
        f.connection.calls.where((c) => c.$1 == Operation.modelsEmbedding),
        isEmpty,
      );
      expect(settings.embeddingGpu, false);
      await setup.installEmbedding!(asset, () => true);
      expect(f.connection.calls.last.$1, Operation.modelsEmbedding);
      expect(f.connection.calls.last.$2, {
        'path': asset.path,
        'gpu': true,
        'digest': embeddingGemmaModel.digest,
      });
      expect(settings.embeddingGpu, true);
      expect(settings.modelState, contains('ready for local source search'));
      final runtime = await setup.installGeneration!(
        '/models/gemma.litertlm',
        '/bin/runner',
        () => true,
      );
      expect(runtime, same(f.connection.status));
      expect(f.connection.calls.last.$1, Operation.modelsGeneration);
      expect(f.connection.calls.last.$2, {
        'path': '/models/gemma.litertlm',
        'runtime': '/bin/runner',
        'backend': 'litert_lm',
      });
      f.shell.error = 'previous error';
      setup.installed(runtime, gemmaModels.last);
      expect(f.shell.error, isEmpty);
      expect(settings.modelState, '${gemmaModels.last.name} ready');
      setup.localSetup();
      expect(f.shell.tab, WorkspaceTab.models);
      final speech = settings.speechSetup() as SpeechSetupDialog;
      await speech.installSpeech!(
        File('/models/speech.bin'),
        '/bin/whisper',
        'fixture-digest',
        () => true,
      );
      expect(f.connection.calls.last.$1, Operation.modelsSpeech);
      expect(f.connection.calls.last.$2, {
        'path': '/models/speech.bin',
        'runtime': '/bin/whisper',
        'digest': 'fixture-digest',
      });
      speech.installed();
      expect(settings.modelState, contains('automatic language detection'));
      await tester.pumpAndSettle();
    },
  );
  testWidgets(
    'known and custom model names are shown without reading model bytes',
    (tester) async {
      final f = await ControllerFixture.mount(tester);
      final settings = f.shell.settingsFeature;
      expect(settings.speechModelName(), 'Select a transcription model');
      expect(settings.generationName(), 'Choose a local model');
      for (final (kind, path, digest, expected) in [
        (
          'speech',
          '/models/tiny.bin',
          speechModels.first.digest,
          speechModels.first.name,
        ),
        (
          'speech',
          '/models/custom.en.bin',
          'custom',
          'custom.en.bin (English only)',
        ),
        ('speech', '/models/custom.bin', 'custom', 'custom.bin'),
        (
          'generation',
          '/models/gemma.litertlm',
          gemmaModels.first.digest,
          gemmaModels.first.name,
        ),
        ('generation', '/models/custom.litertlm', 'custom', 'custom.litertlm'),
      ]) {
        f.store.db.execute(
          'INSERT OR REPLACE INTO models(kind,path,digest,runtime,backend) VALUES(?,?,?,?,?)',
          [kind, path, digest, '', 'fixture'],
        );
        f.connection.application.changed();
        await pumpUntil(
          tester,
          () =>
              (kind == 'speech'
                  ? settings.speechModelName()
                  : settings.generationName()) ==
              expected,
        );
        expect(
          kind == 'speech'
              ? settings.speechModelName()
              : settings.generationName(),
          expected,
        );
      }
      expect(settings.helperEmbeddingHealthy, false);
    },
  );
  testWidgets(
    'local model form registers each model kind and retains failed input for retry',
    (tester) async {
      final f = await ControllerFixture.mount(tester);
      final settings = f.shell.settingsFeature;
      f.shell.update(() => f.shell.navigate(WorkspaceTab.models));
      await tester.pumpAndSettle();
      Future<void> select(String kind) async {
        await tester.tap(find.byType(DropdownButton<String>));
        await tester.pumpAndSettle();
        await tester.tap(
          find
              .text(kind == 'query-detection' ? 'Automatic questions' : kind)
              .last,
        );
        await tester.pumpAndSettle();
        await tester.enterText(
          find.widgetWithText(TextField, 'Model file'),
          '/models/$kind.bin',
        );
        if (kind == 'generation' || kind == 'speech') {
          await tester.enterText(
            find.widgetWithText(
              TextField,
              'Generation / speech runner executable',
            ),
            '/bin/runner',
          );
        }
      }

      for (final kind in [
        'embedding',
        'generation',
        'speech',
        'query-detection',
      ]) {
        await select(kind);
        final button = find.text(
          kind == 'query-detection' ? 'Verify and import' : 'Register and load',
        );
        await tester.ensureVisible(button);
        await tester.tap(button);
        await tester.pumpAndSettle();
        final call = f.connection.calls.last;
        expect(
          call.$1,
          kind == 'embedding'
              ? Operation.modelsEmbedding
              : kind == 'generation'
              ? Operation.modelsGeneration
              : Operation.modelsRegister,
        );
        expect(call.$2['path'], '/models/$kind.bin');
        expect(
          call.$2['runtime'],
          kind == 'query-detection' || kind == 'embedding' ? '' : '/bin/runner',
        );
        if (kind == 'query-detection')
          expect(call.$2['backend'], 'legacy_query_cpu');
        expect(
          settings.modelState,
          kind == 'query-detection'
              ? 'Automatic question model ready'
              : '$kind ready',
        );
      }
      f.connection.failures[Operation.modelsRegister] = StateError(
        'Unsupported model',
      );
      await tester.tap(find.text('Verify and import'));
      await tester.pumpAndSettle();
      expect(find.text('Unsupported model'), findsOneWidget);
      expect(settings.modelPath.text, '/models/query-detection.bin');
      f.connection.failures.clear();
      await tester.tap(find.text('Verify and import'));
      await tester.pumpAndSettle();
      expect(f.shell.error, isEmpty);
      f.shell.update(() => settings.queryModelDownloading = true);
      await tester.pumpAndSettle();
      f.connection.failures[Operation.modelsCancelQueryAcquisition] =
          StateError('cancel failed');
      await tester.tap(find.text('Cancel download'));
      await tester.pumpAndSettle();
      expect(f.shell.error, contains('cancel failed'));
    },
  );
  testWidgets(
    'helper monitor reload closes its dialog and requests service resume',
    (tester) async {
      final f = await ControllerFixture.mount(tester);
      f.shell.settingsFeature.showHelperMonitor();
      await tester.pumpAndSettle();
      expect(find.text('Local helper'), findsOneWidget);
      await tester.tap(find.text('Reload models'));
      await tester.pumpAndSettle();
      expect(find.text('Local helper'), findsNothing);
      expect(f.connection.resumes, 1);
      final pending = f.shell.settingsFeature.chooseGemma(
        firstRun: true,
        embeddingOnly: true,
      );
      await tester.pumpAndSettle();
      expect(find.byType(GemmaSetupDialog), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      await pending;
    },
  );
}
