import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:foresight_core/foresight_core.dart';
import 'package:foresight_core/src/dedicated_query_runtime.dart';
import 'package:foresight_core/src/portable_query_setup.dart';
import 'package:foresight_core/src/reference_query_detector.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';

void main() {
  test(
    'portable dedicated worker validates model bytes and raw protocol before registration',
    () async {
      final root = createTestTempDirectorySync('portable-query-');
      final store = Store('${root.path}/app.db');
      final model = File('${root.path}/model')
        ..writeAsStringSync('controlled dedicated model');
      final worker = File('${root.path}/worker')
        ..writeAsStringSync('''#!/usr/bin/env python3
import json,sys
assert sys.argv[1]=='--model'
print(json.dumps({'type':'ready'}),flush=True)
for line in sys.stdin:
 request=json.loads(line)
 assert request['prompt'].startswith(' <ctrl1>')
 assert request['max_output_tokens']==512
 print(json.dumps({'type':'result','id':request['id'],'text':'什么时候发布？Who owns launch?'}),flush=True)
''');
      await Process.run('chmod', ['700', worker.path]);
      try {
        final digest = sha256.convert(model.readAsBytesSync()).toString();
        for (final paths in [
          (root.path, worker.path),
          (model.path, root.path),
        ]) {
          await expectLater(
            configurePortableQuery(store, paths.$1, paths.$2, digest),
            throwsStateError,
          );
          expect(store.model(dedicatedQueryModelKind), isNull);
        }
        await Process.run('chmod', ['600', worker.path]);
        await expectLater(
          configurePortableQuery(store, model.path, worker.path, digest),
          throwsStateError,
        );
        expect(store.model(dedicatedQueryModelKind), isNull);
        await Process.run('chmod', ['700', worker.path]);
        await expectLater(
          configurePortableQuery(store, model.path, worker.path, '0' * 64),
          throwsStateError,
        );
        expect(store.model(dedicatedQueryModelKind), isNull);
        await configurePortableQuery(store, model.path, worker.path, digest);
        expect(
          store.model(dedicatedQueryModelKind)?['backend'],
          portableQueryBackend,
        );
        final runtime = DedicatedQueryRuntime(
          python: worker.path,
          worker: worker.path,
          model: model.path,
        );
        try {
          expect(runtime.ready, isFalse);
          final questions = await ReferenceQueryDetector(
            runtime.complete,
            preserveUnicode: true,
          ).detect('launch context', 'request');
          expect(questions, ['Who owns launch?', '什么时候发布？']);
          expect(runtime.ready, isTrue);
          runtime.cancel('non-owner');
          expect(runtime.ready, isTrue);
        } finally {
          await runtime.close();
          expect(runtime.ready, isFalse);
        }
        worker.writeAsStringSync(
          '#!/usr/bin/env python3\nprint("not the dedicated protocol",flush=True)\n',
        );
        await expectLater(
          configurePortableQuery(store, model.path, worker.path, digest),
          throwsA(anything),
        );
        expect(store.model(dedicatedQueryModelKind)?['digest'], digest);
      } finally {
        store.close();
        root.deleteSync(recursive: true);
      }
    },
  );
  test('Unicode parser and ASCII compatibility remain distinct', () {
    expect(parseUnicodeQueryOutput(' <ctrl1>发布日期？发布日期？\u0000>> ignored?'), [
      '发布日期？',
    ]);
    expect(parseReferenceQueryOutput('发布日期？'), isEmpty);
    expect(parseUnicodeQueryOutput('كيف نطلق؟'), ['كيف نطلق؟']);
  });
}
