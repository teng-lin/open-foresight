import 'dart:io';
import 'package:foresight_core/src/platform_services.dart';
import 'package:foresight_core/src/profile_paths.dart';
import 'package:foresight_core/src/service.dart';
import 'package:foresight_core/src/store.dart';
import 'package:test/test.dart';

void main() {
  late Directory directory;
  late String database;
  setUp(() async {
    directory = await createPrivateTempDirectory(
      Directory.systemTemp,
      'integrity-',
    );
    database = '${directory.path}/app.db';
  });
  tearDown(() => directory.deleteSync(recursive: true));

  test('same-size stored model tampering is refused on reopening', () async {
    final file = File('${directory.path}/model')
      ..writeAsStringSync('trusted bytes');
    var store = Store(database);
    addTearDown(store.close);
    await store.register('generation', file.path, '/bin/true');
    await store.verifyRegisteredModels();
    store.close();
    file.writeAsStringSync('changed bytes');
    store = Store(database);
    addTearDown(store.close);
    await expectLater(store.verifyRegisteredModels(), throwsStateError);
  });

  test(
    'service startup checks stored bytes before creating model workers',
    () async {
      final file = File('${directory.path}/model')
        ..writeAsStringSync('trusted bytes');
      final store = Store('${directory.path}/application.db');
      addTearDown(store.close);
      await store.register('generation', file.path, '/bin/true');
      store.close();
      file.writeAsStringSync('changed bytes');
      final service = await ApplicationService.start(
        ProfilePaths(directory.path, directory.path),
      );
      addTearDown(service.close);
      expect(service.domain.store.model('generation'), isNull);
      expect(
        service.domain.store.preference('modelIntegrityError.generation'),
        contains('Set up the model again'),
      );
      expect(file.readAsStringSync(), 'changed bytes');
      expect(
        File('${directory.path}/.application-endpoint.json').existsSync(),
        isTrue,
      );
      file.writeAsStringSync('verified replacement');
      await service.domain.store.register('generation', file.path, '/bin/true');
      await service.domain.store.verifyRegisteredModels();
      expect(service.domain.store.model('generation'), isNotNull);
      expect(
        service.domain.store.preference('modelIntegrityError.generation'),
        isEmpty,
      );
    },
  );

  test('directory model manifest is rehashed at startup', () async {
    final model = Directory('${directory.path}/model')..createSync();
    final file = File('${model.path}/weights')..writeAsStringSync('trusted');
    final store = Store(database);
    addTearDown(store.close);
    await store.register(
      'generation',
      model.path,
      '/bin/true',
      backend: 'llama_cpp',
    );
    await store.verifyRegisteredModels();
    file.writeAsStringSync('changed');
    await expectLater(store.verifyRegisteredModels(), throwsStateError);
  });
}
