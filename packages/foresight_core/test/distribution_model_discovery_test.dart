import 'package:foresight_test_support/test_paths.dart';
import 'dart:io';
import 'package:foresight_core/src/model_setup.dart';
import 'package:foresight_core/src/store.dart';
import 'package:test/test.dart';

void main() {
  final library = Platform.environment['FORESIGHT_NATIVE_LIBRARY'];
  test(
    'owned generation discovery prefers original type order and preserves explicit registrations',
    () async {
      final root = await createTestTempDirectory('model-discovery-');
      final store = Store('${root.path}/app.db');
      try {
        for (final type in [14, 16]) {
          final file = File(
            '${root.path}/distribution-assets/models/$type/v/model.litertlm',
          );
          await file.parent.create(recursive: true);
          await file.writeAsString('fixture');
        }
        final runner = File('${root.path}/runner');
        await runner.writeAsString(
          '#!/bin/sh\n[ "\$1" = --model ] || exit 1\n[ "\$4" = --model-type ] || exit 2\n[ "\$5" = 16 ] || exit 3\nprintf \'{"worker_protocol":1,"native_stop_token_sequences":true}\\n\'\n',
        );
        expect(
          (await Process.run('/bin/chmod', ['700', runner.path])).exitCode,
          0,
        );
        final runtime = await discoverGenerationRuntime(
          store,
          library!,
          runner: runner.path,
        );
        expect(runtime, isNotNull);
        try {
          expect(
            store.model('generation')!['path'],
            contains('/models/16/v/model.litertlm'),
          );
          expect(store.model('generation')!['model_type'], 16);
          expect(
            await discoverGenerationRuntime(store, library, runner: '/missing'),
            isNull,
          );
        } finally {
          runtime?.close();
        }
      } finally {
        store.close();
        await root.delete(recursive: true);
      }
    },
    skip: library == null
        ? 'Requires native runtime and process supervisor'
        : false,
  );

  test(
    'no owned assets does not initialize a runtime or replace registrations',
    () async {
      final root = await createTestTempDirectory('empty-model-discovery-');
      final store = Store('${root.path}/app.db');
      try {
        expect(await discoverGenerationRuntime(store, '/missing'), isNull);
        expect(await discoverDedicatedQueryModel(store), isFalse);
        expect(store.models, isEmpty);
      } finally {
        store.close();
        await root.delete(recursive: true);
      }
    },
  );
}
