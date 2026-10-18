import 'package:foresight_test_support/test_paths.dart';
import 'dart:async';
import 'dart:io';
import 'package:foresight_core/src/model_acquisition.dart';
import 'package:foresight_core/src/model_asset_lifecycle.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late List<OnDeviceModelMetadata> metadata;
  late ModelAssetLifecycle catalog;
  OnDeviceModelMetadata model(int type, String name, [String version = '']) =>
      OnDeviceModelMetadata(modelType: type, name: name, version: version);
  Future<File> write(String relative, [String content = 'asset']) async {
    final file = File('${root.path}/$relative');
    await file.parent.create(recursive: true);
    return file.writeAsString(content);
  }

  setUp(() async {
    // The original full-path contains predicate also includes ancestor names.
    do {
      root = await shortTestTempRoot.createTemp('model-assets-');
      if (root.path.contains('4')) await root.delete();
    } while (root.path.contains('4'));
    metadata = [];
    catalog = ModelAssetLifecycle(
      root: root,
      fetch: () async =>
          ForesightSharedConfig(onDeviceModelMetadatas: metadata),
    );
  });
  tearDown(() async {
    await catalog.close();
    await root.delete(recursive: true);
  });

  test(
    'refresh retains server order and emits installed files after cleanup',
    () async {
      metadata = [
        model(4, 'new', '2'),
        model(4, 'old'),
        model(14, 'gemma', '3'),
      ];
      final existing = await write('models/4/1.0/old');
      final stale = await write('models/2/old/stale');
      final events = <ModelAsset>[];
      final sub = catalog.updates.listen((asset) {
        expect(stale.existsSync(), isFalse);
        events.add(asset);
      });
      await catalog.refresh();
      await Future<void>.delayed(Duration.zero);
      expect(catalog.assets.map((a) => a.metadata.name), [
        'new',
        'old',
        'gemma',
      ]);
      expect(catalog.model(4)!.metadata.name, 'new');
      expect(await catalog.localPath(4), existing.path);
      expect(events.map((a) => a.path), [existing.path]);
      await sub.cancel();
    },
  );
  test(
    'missing latest protects old files with broad decimal contains',
    () async {
      metadata = [model(4, 'new', '2')];
      final old = await write('models/4/1.0/old');
      final broad = await write('models/2/old/unrelated4suffix');
      final removed = await write('models/2/old/stale');
      await catalog.refresh();
      expect(await old.exists(), isTrue);
      expect(await broad.exists(), isTrue);
      expect(await removed.exists(), isFalse);
      await write('models/4/2/new');
      await catalog.refresh();
      expect(await old.exists(), isFalse);
      expect(await broad.exists(), isFalse);
    },
  );
  test(
    'recursive fallback excludes temporary suffixes and directory links',
    () async {
      final downloading = await write('models/4/v/a.downloading');
      await write('models/4/v/b.tmp');
      final usable = await write('models/4/v/usable');
      final outside = await Directory.systemTemp.createTemp('external-models-');
      try {
        await File('${outside.path}/external').writeAsString('keep');
        await Link('${root.path}/models/4/link').create(outside.path);
        expect(await catalog.localPath(4), usable.path);
        await catalog.refresh();
        expect(await downloading.exists(), isTrue);
        expect(await File('${outside.path}/external').readAsString(), 'keep');
      } finally {
        await outside.delete(recursive: true);
      }
    },
  );
  test('cleanup preserves active registrations and imported assets', () async {
    final active = await write('models/4/old/active');
    final imported = await write('imports/user-model');
    final stale = await write('models/4/old/obsolete');
    await catalog.close();
    catalog = ModelAssetLifecycle(
      root: root,
      fetch: () async => ForesightSharedConfig(),
      protectedPaths: () => [active.path, imported.path],
    );
    await catalog.refresh();
    expect(await active.exists(), isTrue);
    expect(await imported.exists(), isTrue);
    expect(await stale.exists(), isFalse);
  });
  test(
    'invalid metadata and symlink ancestors cannot escape the catalog',
    () async {
      for (final value in ['', '..', '../escape', '/absolute', 'bad\\name']) {
        expect(() => catalog.pathFor(model(4, value)), throwsFormatException);
        expect(
          () => catalog.pathFor(
            model(4, 'valid', value.isEmpty ? '../v' : value),
          ),
          throwsFormatException,
        );
      }
      final outside = await Directory.systemTemp.createTemp('outside-assets-');
      try {
        final keep = File('${outside.path}/keep');
        await keep.writeAsString('keep');
        await Link('${root.path}/models').create(outside.path);
        await catalog.refresh();
        expect(await keep.readAsString(), 'keep');
        expect(await catalog.localPath(4), isNull);
        await expectLater(
          catalog.publish(model(4, 'new'), keep, (_) async {}),
          throwsStateError,
        );
      } finally {
        await outside.delete(recursive: true);
      }
    },
  );
  test(
    'refresh shares a pending request and retries a failed request',
    () async {
      await catalog.close();
      final pending = Completer<ForesightSharedConfig>();
      var calls = 0;
      catalog = ModelAssetLifecycle(
        root: root,
        fetch: () {
          calls++;
          return calls == 1
              ? pending.future
              : Future.value(ForesightSharedConfig());
        },
      );
      final first = catalog.refresh(), second = catalog.refresh();
      expect(identical(first, second), isTrue);
      final failures = [
        expectLater(first, throwsStateError),
        expectLater(second, throwsStateError),
      ];
      pending.completeError(StateError('offline'));
      await Future.wait(failures);
      await catalog.refresh();
      expect(calls, 2);
    },
  );
  test(
    'listing failures propagate but individual delete failures continue',
    () async {
      await write('models/4/v/one');
      await write('models/4/v/two');
      await catalog.close();
      var deletes = 0;
      final warnings = <Object>[];
      catalog = ModelAssetLifecycle(
        root: root,
        fetch: () async => ForesightSharedConfig(),
        deleteFile: (_) async {
          deletes++;
          throw FileSystemException('busy');
        },
        onWarning: warnings.add,
      );
      await catalog.refresh();
      expect(deletes, 2);
      expect(warnings, hasLength(2));
      await catalog.close();
      catalog = ModelAssetLifecycle(
        root: root,
        fetch: () async => ForesightSharedConfig(),
        listFiles: (_) => Stream.error(FileSystemException('cannot list')),
      );
      await expectLater(catalog.refresh(), throwsA(isA<FileSystemException>()));
    },
  );
  test('failed adoption restores previous file', () async {
    final old = await write('models/4/1.0/model', 'previous');
    final candidate = await write('candidates/new', 'candidate');
    await expectLater(
      catalog.publish(model(4, 'model'), candidate, (file) async {
        expect(await file.readAsString(), 'candidate');
        throw StateError('readiness rejected');
      }),
      throwsStateError,
    );
    expect(await old.readAsString(), 'previous');
    expect(await candidate.exists(), isFalse);
    expect(
      await root
          .list()
          .where((f) => f.path.contains('.model-adoption-'))
          .isEmpty,
      isTrue,
    );
  });
  test(
    'successful publication uses metadata layout and removes its backup',
    () async {
      await write('models/4/1.0/model', 'previous');
      final candidate = await write('candidates/new', 'accepted');
      var registered = false;
      await catalog.publish(model(4, 'model'), candidate, (file) async {
        expect(file.path, '${root.path}/models/4/1.0/model');
        expect(await file.readAsString(), 'accepted');
        registered = true;
      });
      expect(registered, isTrue);
      expect(await catalog.localPath(4), '${root.path}/models/4/1.0/model');
      expect(
        await root
            .list()
            .where((item) => item.path.contains('.model-adoption-'))
            .isEmpty,
        isTrue,
      );
    },
  );
  test(
    'failed rollback retains the previous asset backup for recovery',
    () async {
      await write('models/4/1.0/model', 'previous');
      final candidate = await write('candidates/new', 'candidate');
      await catalog.close();
      catalog = ModelAssetLifecycle(
        root: root,
        fetch: () async => ForesightSharedConfig(),
        renameFile: (file, destination) {
          if (file.path.endsWith('/previous')) {
            throw FileSystemException('restore denied');
          }
          return file.rename(destination);
        },
      );
      await expectLater(
        catalog.publish(
          model(4, 'model'),
          candidate,
          (_) async => throw StateError('rejected'),
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('Recovery files retained'),
          ),
        ),
      );
      final backups = await root
          .list()
          .where((item) => item is Directory)
          .cast<Directory>()
          .where((item) => item.path.contains('.model-adoption-'))
          .toList();
      expect(backups, hasLength(1));
      expect(
        await File('${backups.single.path}/previous').readAsString(),
        'previous',
      );
    },
  );
  test(
    'inference preference uses supported selection then original order',
    () async {
      metadata = [model(14, 'small'), model(16, 'large'), model(17, 'special')];
      await catalog.refresh();
      expect((await catalog.inferenceModel())!.metadata.modelType, 16);
      expect(
        (await catalog.inferenceModel(selectedType: 14))!.metadata.modelType,
        14,
      );
      expect(
        (await catalog.inferenceModel(selectedType: 17))!.metadata.modelType,
        16,
      );
    },
  );
}
