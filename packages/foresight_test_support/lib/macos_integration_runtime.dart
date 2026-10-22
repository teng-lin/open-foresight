import 'dart:convert';
import 'dart:io';

const _fixtureKey = 'FORESIGHT_TEST_RUNTIME_FIXTURE';
const _fixtureValue = 'flutter-debug-integration-v1';
const _runtimePaths = {
  'FORESIGHT_NATIVE',
  'FORESIGHT_SQLITE_LIBRARY',
  'FORESIGHT_HELPER',
  'FORESIGHT_SERVICE',
  'FORESIGHT_MODEL_WORKER',
};

/// Prepare only the disposable Flutter Debug integration-test application.
/// Call before the first sealed runtime lookup; production code is unchanged.
File? prepareMacosIntegrationRuntime({
  required void Function(void Function()) registerTearDown,
  String? executable,
  Map<String, String>? environment,
  bool? isMacOS,
}) {
  if (!(isMacOS ?? Platform.isMacOS)) return null;
  final path = executable ?? Platform.resolvedExecutable;
  final marker = path.lastIndexOf('.app/Contents/MacOS/');
  if (marker < 0) return null;
  final application = path.substring(0, marker + 4);
  if (!application.contains('/build/macos/Build/Products/Debug/') ||
      FileSystemEntity.typeSync(application, followLinks: false) !=
          FileSystemEntityType.directory) {
    throw StateError('Runtime fixtures require a Flutter Debug test bundle.');
  }
  if (FileSystemEntity.typeSync('$application/Contents', followLinks: false) !=
      FileSystemEntityType.directory) {
    throw StateError('Test bundle contents must be a regular directory.');
  }
  final resources = Directory('$application/Contents/Resources');
  final resourceType = FileSystemEntity.typeSync(
    resources.path,
    followLinks: false,
  );
  if (resourceType != FileSystemEntityType.notFound &&
      resourceType != FileSystemEntityType.directory) {
    throw StateError('Test bundle resources must be a regular directory.');
  }
  final manifest = File('${resources.path}/runtime.json');
  final manifestType = FileSystemEntity.typeSync(
    manifest.path,
    followLinks: false,
  );
  if (manifestType != FileSystemEntityType.notFound) {
    if (manifestType != FileSystemEntityType.file) {
      throw StateError('Refusing to replace a nonfixture runtime manifest.');
    }
    final dynamic previous;
    try {
      previous = jsonDecode(manifest.readAsStringSync());
    } on FormatException {
      throw StateError('Refusing to replace a nonfixture runtime manifest.');
    }
    if (previous is! Map || previous[_fixtureKey] != _fixtureValue) {
      throw StateError('Refusing to replace a nonfixture runtime manifest.');
    }
  }
  final values = environment ?? Platform.environment;
  final entries = <String, String>{_fixtureKey: _fixtureValue};
  for (final key in _runtimePaths) {
    final value = values[key];
    if (value == null || value.isEmpty) continue;
    if (!value.startsWith('/') || !File(value).existsSync()) {
      throw StateError(
        'Test runtime $key must name an existing absolute file.',
      );
    }
    entries[key] = value;
  }
  for (final key in ['FORESIGHT_NATIVE', 'FORESIGHT_SQLITE_LIBRARY']) {
    if (!entries.containsKey(key)) {
      throw StateError('The integration test must supply $key.');
    }
  }
  final content = '${jsonEncode(entries)}\n';
  resources.createSync(recursive: true);
  manifest.writeAsStringSync(content);
  registerTearDown(() {
    if (FileSystemEntity.typeSync(manifest.path, followLinks: false) ==
            FileSystemEntityType.file &&
        manifest.readAsStringSync() == content) {
      manifest.deleteSync();
    }
  });
  return manifest;
}
