import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foresight_core/desktop.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:open_foresight/features/settings/gemma_setup_view.dart';
import 'package:open_foresight/features/settings/speech_setup_view.dart';
import '../test_support/core_fixture.dart' show Store;
import 'store_reader_fixture.dart';

void main() {
  for (final speech in [false, true]) {
    for (final actionable in [false, true]) {
      for (final cacheFailure in [false, true]) {
        testWidgets(
          '${speech ? 'speech' : 'Gemma'} setup ${cacheFailure ? 'cache' : 'download'} ${actionable ? 'shows safe RpcError' : 'suppresses arbitrary diagnostics'}',
          (tester) async {
            final root = createTestTempDirectorySync('setup-errors-');
            final store = Store('${root.path}/app.db');
            try {
              final failure = actionable
                  ? RpcError(RpcErrorCode.busy, modelDownloadBusyMessage)
                  : StateError('/private/path https://host/model?key=secret');
              final model = embeddingGemmaModel;
              store.setPreference(
                'modelTerms.${model.repository}.${model.revision}',
                'accepted',
              );
              final Widget dialog = speech
                  ? SpeechSetupDialog(
                      store: fixtureReader(store),
                      directory: root,
                      runner: '/usr/bin/true',
                      findLocalModel: (_, _, {registration}) async {
                        if (cacheFailure) throw failure;
                        return null;
                      },
                      savePreference: (key, value) async =>
                          store.setPreference(key, value),
                      createDownload: () => throw failure,
                      installed: () {},
                    )
                  : GemmaSetupDialog(
                      store: fixtureReader(store),
                      directory: Directory('${root.path}/gemma4'),
                      library: '',
                      runner: '/usr/bin/true',
                      memoryGb: 16,
                      needsEmbedding: true,
                      needsGeneration: false,
                      findLocalModel: (_, _, {registration}) async {
                        if (cacheFailure) throw failure;
                        return null;
                      },
                      savePreference: (key, value) async =>
                          store.setPreference(key, value),
                      createDownload: () => throw failure,
                      installed: (_, _) {},
                      localSetup: () {},
                    );
              await tester.pumpWidget(
                MaterialApp(home: Scaffold(body: dialog)),
              );
              await tester.pumpAndSettle();
              if (!cacheFailure) {
                await tester.tap(
                  find.widgetWithText(
                    FilledButton,
                    speech ? 'Continue' : 'Download EmbeddingGemma 2',
                  ),
                );
              }
              await tester.pumpAndSettle();
              expect(
                find.text(
                  actionable
                      ? modelDownloadBusyMessage
                      : modelSetupFailureMessage(failure),
                ),
                findsOneWidget,
              );
              expect(find.textContaining('secret'), findsNothing);
              expect(find.textContaining('/private/path'), findsNothing);
            } finally {
              await tester.pumpWidget(const SizedBox());
              store.close();
            }
          },
        );
      }
    }
  }
}
